#!/usr/bin/env bash
# ProtonBoost 安装/卸载脚本
# 用法: ./install.sh [install|uninstall|help] [PREFIX]   （默认 install ~/.local）
set -euo pipefail

# 从任何目录调用都能用（构建产物和资源都是相对项目根写的）
cd "$(dirname "$0")"

MODE="${1:-install}"
PREFIX="${2:-$HOME/.local}"

BIN_DIR="$PREFIX/bin"
APP_DIR="$PREFIX/share/applications"
ICON_PNG="$PREFIX/share/icons/hicolor/512x512/apps"
ICON_SVG="$PREFIX/share/icons/hicolor/scalable/apps"
DATA_DIR="$PREFIX/share/protonboost"
# 装了什么就记在这里，卸载照着删，不会漏也不会误删别的
MANIFEST="$DATA_DIR/installed-files.txt"

say() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

# 显式传空串时 ${2:-} 不会走默认值，后面 "$PREFIX"/* 会退化成 /*，卸载时按
# manifest 误删任意绝对路径——空 PREFIX 一律拒绝
[[ -n "$PREFIX" && "$PREFIX" != "/" ]] || die "PREFIX 不能为空或 /（用法: ./install.sh [install|uninstall] [PREFIX]）"

usage() {
    cat <<'EOF'
用法: ./install.sh [install|uninstall|help] [PREFIX]

  install     构建 release 并安装到 PREFIX（默认 ~/.local）
  uninstall   按安装记录把装过的文件删掉
  help        显示这段说明

环境变量:
  PROTONBOOST_NO_BUILD=1   跳过 cargo build，直接装现成的 target/release/protonboost

装完用 `protonboost` 打开；卸载跑 `./install.sh uninstall`。
EOF
}

# 构建需要 Qt 6 的开发文件；只安装现成二进制则不需要
require_qt() {
    if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists Qt6Core Qt6Quick Qt6Qml 2>/dev/null; then
        return 0
    fi
    if command -v qmake6 >/dev/null 2>&1; then
        return 0
    fi
    cat >&2 <<'EOF'
错误: 找不到 Qt 6 的开发文件（构建需要 Qt6Core / Qt6Quick / Qt6Qml）。

  Arch:    sudo pacman -S qt6-base qt6-declarative
  Debian:  sudo apt install qt6-base-dev qt6-declarative-dev
  Fedora:  sudo dnf install qt6-qtbase-devel qt6-qtdeclarative-devel

只是安装已经编译好的二进制则用: PROTONBOOST_NO_BUILD=1 ./install.sh
EOF
    exit 1
}

build_manager() {
    if [[ -x target/release/protonboost ]]; then
        BUILD_BIN=target/release/protonboost
    elif [[ -x protonboost ]]; then
        # 便携包 / 预编译二进制：解压即装，不需要 cargo
        BUILD_BIN=protonboost
        say "使用自带的二进制，跳过构建"
    elif [[ "${PROTONBOOST_NO_BUILD:-0}" == "1" ]]; then
        die "没有 target/release/protonboost，先 cargo build --release"
    else
        require_qt
        command -v cargo >/dev/null 2>&1 \
            || die "需要 cargo 来构建（或设 PROTONBOOST_NO_BUILD=1 用现成产物）"
        say "构建 protonboost（首次较慢）..."
        cargo build --release
        BUILD_BIN=target/release/protonboost
    fi
}

refresh_caches() {
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "$APP_DIR" >/dev/null 2>&1 || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -qtf "$PREFIX/share/icons/hicolor" >/dev/null 2>&1 || true
    fi
}

do_install() {
    build_manager

    local tmp
    tmp="$(mktemp)"
    trap 'rm -f "${tmp:-}"' EXIT

    install -Dm755 "$BUILD_BIN" "$BIN_DIR/protonboost"
    printf '%s\n' "$BIN_DIR/protonboost" >> "$tmp"

    local file
    for file in assets/applications/*.desktop; do
        install -Dm644 "$file" "$APP_DIR/$(basename "$file")"
        printf '%s\n' "$APP_DIR/$(basename "$file")" >> "$tmp"
    done

    install -Dm644 assets/icons/protonboost.png "$ICON_PNG/protonboost.png"
    printf '%s\n' "$ICON_PNG/protonboost.png" >> "$tmp"
    install -Dm644 assets/icons/protonboost.svg "$ICON_SVG/protonboost.svg"
    printf '%s\n' "$ICON_SVG/protonboost.svg" >> "$tmp"

    install -Dm644 "$tmp" "$MANIFEST"
    refresh_caches

    say "已安装到 $PREFIX"
    timeout 3 "$BIN_DIR/protonboost" --version 2>/dev/null || true
    say "打开: protonboost      卸载: $0 uninstall"
}

do_uninstall() {
    local files=()

    if [[ -f "$MANIFEST" ]]; then
        while IFS= read -r line; do
            [[ -n "$line" ]] && files+=("$line")
        done < "$MANIFEST"
    else
        # 没有安装记录（早期版本装的），退回固定列表
        files+=(
            "$BIN_DIR/protonboost"
            "$APP_DIR/protonboost.desktop"
            "$APP_DIR/protonboost-run.desktop"
            "$APP_DIR/protonboost-settings.desktop"
            "$ICON_PNG/protonboost.png"
            "$ICON_SVG/protonboost.svg"
        )
    fi

    # Bash CLI 时代留下的文件名，顺手清掉
    files+=(
        "$APP_DIR/protonboost-run-windows-program.desktop"
        "$APP_DIR/protonboost-windows-program-configure.desktop"
        "$BIN_DIR/protonboost"
        "$BIN_DIR/protonboost-configure"
    )

    local file
    for file in ${files[@]+"${files[@]}"}; do
        case "$file" in
            "$PREFIX"/*) rm -f "$file" ;;
            *) say "跳过（不在 $PREFIX 内）: $file" ;;
        esac
    done

    rm -f "$MANIFEST"
    rmdir "$DATA_DIR" 2>/dev/null || true
    # 早期版本把脚本库放在这里
    if [[ -n "$PREFIX" && "$PREFIX" != "/" ]]; then
        rm -rf "$PREFIX/lib/protonboost"
    fi

    refresh_caches
    say "已从 $PREFIX 移除 protonboost"
}

case "$MODE" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    help | --help | -h) usage ;;
    *) usage >&2; exit 1 ;;
esac
