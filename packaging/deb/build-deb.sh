#!/usr/bin/env bash
# 构建 Debian / Ubuntu 的 .deb 包（dpkg-deb 轻量方式，不需要 debhelper）
#
# 用法:
#   packaging/deb/build-deb.sh [版本号]
# 版本号缺省时读 Cargo.toml。架构自动检测：x86_64→amd64，aarch64→arm64。
# 产物输出在仓库根：protonboost_<版本>_<架构>.deb
#
# Depends 用了 alternatives（libqt6core6t64 | libqt6core6）：
# Ubuntu 24.04+/Debian 13 的 Qt6 库带 t64 后缀，Debian 12 没有，两种都兼容。
set -euo pipefail
cd "$(dirname "$0")/../.."   # 仓库根

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    VERSION="$(grep -m1 '^version' Cargo.toml | sed 's/.*"\(.*\)".*/\1/')"
fi
case "$(uname -m)" in
    x86_64)  ARCH=amd64 ;;
    aarch64) ARCH=arm64 ;;
    *) echo "错误: 不支持的架构 $(uname -m)" >&2; exit 1 ;;
esac

BIN=target/release/protonboost
if [[ ! -x "$BIN" ]]; then
    echo "没有现成的二进制，先构建（需要 Qt6 开发文件）..."
    cargo build --release
fi

WORK="$(mktemp -d)"
STAGE="$WORK/protonboost"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STAGE/DEBIAN"

# 二进制 + 资源（与 install.sh、PKGBUILD 保持同一布局）
install -Dm755 "$BIN" "$STAGE/usr/bin/protonboost"
for file in assets/applications/*.desktop; do
    install -Dm644 "$file" "$STAGE/usr/share/applications/$(basename "$file")"
done
install -Dm644 assets/icons/protonboost.png "$STAGE/usr/share/icons/hicolor/512x512/apps/protonboost.png"
install -Dm644 assets/icons/protonboost.svg "$STAGE/usr/share/icons/hicolor/scalable/apps/protonboost.svg"
install -Dm644 LICENSE "$STAGE/usr/share/doc/protonboost/copyright"

SIZE_KB="$(du -sk "$STAGE/usr" | cut -f1)"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@ARCH@/$ARCH/g" -e "s/@SIZE@/$SIZE_KB/g" \
    packaging/deb/control > "$STAGE/DEBIAN/control"
install -m755 packaging/deb/postinst "$STAGE/DEBIAN/postinst"
install -m755 packaging/deb/postrm "$STAGE/DEBIAN/postrm"

OUT="protonboost_${VERSION}_${ARCH}.deb"
dpkg-deb --root-owner-group --build "$STAGE" "$OUT"
echo "已生成 $OUT"
echo "安装: sudo apt install ./$OUT   查看内容: dpkg-deb -c $OUT"
