#!/usr/bin/env bash
# 构建 GitHub Release 的全部产物（dist/ 下）：
#
#   protonboost_<版本>_<deb架构>.deb          Debian/Ubuntu
#   protonboost-<版本>-<pkgrel>-<arch>.pkg.tar.zst   Arch（pacman 官方命名）
#   protonboost-<版本>-<架构>.tar.gz          便携包（解压后 ./install.sh）
#
# 本机没有 dpkg-deb / makepkg 时也能构建：deb 用 ar 手工封包，
# pacman 包按官方格式（.PKGINFO + .MTREE + tar.zst）手工组装，产物与
# dpkg-deb / makepkg 的输出同构，pacman 与 dpkg 都能正常安装。
# 用法: packaging/build-dist.sh   （需要先有 target/release/protonboost，没有就自动构建）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(grep -m1 '^version' Cargo.toml | sed 's/.*"\(.*\)".*/\1/')"
PKGREL=1
case "$(uname -m)" in
    x86_64)  DEB_ARCH=amd64;  PAC_ARCH=x86_64;  TARBALL_ARCH=x86_64 ;;
    aarch64) DEB_ARCH=arm64;  PAC_ARCH=aarch64; TARBALL_ARCH=aarch64 ;;
    *) echo "错误: 不支持的架构 $(uname -m)" >&2; exit 1 ;;
esac

BIN=target/release/protonboost
if [[ ! -x "$BIN" ]]; then
    echo "没有现成的二进制，先构建..."
    cargo build --release
fi

DIST="$PWD/dist"
rm -rf "$DIST"
mkdir -p "$DIST"

# ── 通用安装布局 ────────────────────────────────────────────
make_tree() {
    local tree="$1"
    mkdir -p "$tree"
    install -Dm755 "$BIN" "$tree/usr/bin/protonboost"
    for file in assets/applications/*.desktop; do
        install -Dm644 "$file" "$tree/usr/share/applications/$(basename "$file")"
    done
    install -Dm644 assets/icons/protonboost.png "$tree/usr/share/icons/hicolor/512x512/apps/protonboost.png"
    install -Dm644 assets/icons/protonboost.svg "$tree/usr/share/icons/hicolor/scalable/apps/protonboost.svg"
}

# ── 1) deb：ar 手工封包（debian-binary + control.tar.gz + data.tar.gz）──
DEB_NAME="protonboost_${VERSION}_${DEB_ARCH}.deb"
{
    TREE="$DIST/deb"; mkdir -p "$TREE"
    make_tree "$TREE"
    install -Dm644 LICENSE "$TREE/usr/share/doc/protonboost/copyright"
    mkdir -p "$TREE/DEBIAN"
    SIZE_KB="$(du -sk "$TREE/usr" | cut -f1)"
    sed -e "s/@VERSION@/$VERSION/g" -e "s/@ARCH@/$DEB_ARCH/g" -e "s/@SIZE@/$SIZE_KB/g" \
        packaging/deb/control > "$TREE/DEBIAN/control"
    install -m755 packaging/deb/postinst "$TREE/DEBIAN/postinst"
    install -m755 packaging/deb/postrm "$TREE/DEBIAN/postrm"
    # md5sums（dpkg-deb 会自动生成，手工封包自己补）
    ( cd "$TREE" && find usr -type f | sort | xargs md5sum ) > "$TREE/DEBIAN/md5sums"
    ( cd "$TREE/DEBIAN" && tar czf "$DIST/control.tar.gz" control md5sums postinst postrm )
    ( cd "$TREE" && fakeroot tar czf "$DIST/data.tar.gz" usr )
    printf '2.0\n' > "$DIST/debian-binary"
    ar rc "$DIST/$DEB_NAME" "$DIST/debian-binary" "$DIST/control.tar.gz" "$DIST/data.tar.gz"
    rm -rf "$TREE" "$DIST/control.tar.gz" "$DIST/data.tar.gz" "$DIST/debian-binary"
    echo "✓ $DIST/$DEB_NAME"
}

# ── 2) pacman：.PKGINFO + .MTREE + tar.zst（makepkg 同构产物）──
PAC_NAME="protonboost-${VERSION}-${PKGREL}-${PAC_ARCH}.pkg.tar.zst"
{
    TREE="$DIST/pkg"; mkdir -p "$TREE"
    make_tree "$TREE"
    SIZE_BYTES="$(du -sb "$TREE/usr" | cut -f1)"
    cat > "$TREE/.PKGINFO" <<EOF
pkgname = protonboost
pkgver = ${VERSION}-${PKGREL}
pkgdesc = 在 Linux 上用 Proton / Wine 运行 Windows 程序（Rust + Qt 6）
url = https://github.com/xinghui79/protonboost
builddate = $(date +%s)
packager = ProtonBoost <protonboost@example.com>
size = ${SIZE_BYTES}
arch = ${PAC_ARCH}
license = MIT
depend = qt6-base
depend = qt6-declarative
depend = qt6-svg
depend = curl
depend = tar
depend = util-linux
optdepend = passt: 前缀的独立网络（netns）
optdepend = wine: 没有 Proton 时也可以用它跑程序
optdepend = icoextract: 从 exe 里抠图标的备用方案
EOF
    # .MTREE：pacman 用来校验包内容。目录必须显式 type=dir，否则继承
    # /set type=file，pacman 会把目录当成包文件、与文件系统报冲突
    ( cd "$TREE" && python3 - <<'PYEOF'
import hashlib, os

lines = ["#mtree", "/set type=file uid=0 gid=0 mode=644"]

def add(path):
    st = os.stat(path)
    if os.path.isdir(path):
        lines.append(f"./{path} type=dir time={int(st.st_mtime)} mode=755")
        return
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    entry = f"./{path} time={int(st.st_mtime)} size={st.st_size} sha256digest={h.hexdigest()}"
    if os.access(path, os.X_OK):
        entry += " mode=755"
    lines.append(entry)

for root, dirs, files in os.walk("."):
    dirs.sort()
    for name in sorted(dirs):
        add(os.path.normpath(os.path.join(root, name)))
    for name in sorted(files):
        path = os.path.normpath(os.path.join(root, name))
        if path == ".MTREE":
            continue
        add(path)
print("\n".join(lines))
PYEOF
    ) > "$TREE/.MTREE"
    ( cd "$TREE" && fakeroot tar --zstd -cf "$DIST/$PAC_NAME" .PKGINFO .MTREE usr )
    rm -rf "$TREE"
    echo "✓ $DIST/$PAC_NAME"
}

# ── 3) 便携包：解压后 ./install.sh 直接装 ──
TARBALL_NAME="protonboost-${VERSION}-${TARBALL_ARCH}.tar.gz"
{
    TREE="$DIST/portable"; mkdir -p "$TREE"
    make_tree "$TREE/usr/local" 2>/dev/null || true
    rm -rf "$TREE/usr"
    cp "$BIN" "$TREE/protonboost"
    cp install.sh README.md LICENSE "$TREE/"
    mkdir -p "$TREE/assets/applications" "$TREE/assets/icons"
    cp assets/applications/*.desktop "$TREE/assets/applications/"
    cp assets/icons/protonboost.png assets/icons/protonboost.svg "$TREE/assets/icons/"
    ( cd "$TREE" && tar czf "$DIST/$TARBALL_NAME" --owner=0 --group=0 protonboost install.sh README.md LICENSE assets )
    rm -rf "$TREE"
    echo "✓ $DIST/$TARBALL_NAME"
}

echo
echo "全部产物："
ls -lh "$DIST"
