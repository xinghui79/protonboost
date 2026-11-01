#!/usr/bin/env bash
# WinRun 安装/卸载脚本
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
DATA_DIR="$PREFIX/share/winrun"
# 装了什么就记在这里，卸载照着删，不会漏也不会误删别的
MANIFEST="$DATA_DIR/installed-files.txt"

say() { printf '%s\n' "$*"; }
die() { printf '错误: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
用法: ./install.sh [install|uninstall|help] [PREFIX]

  install     构建 release 并安装到 PREFIX（默认 ~/.local）
  uninstall   按安装记录把装过的文件删掉
  help        显示这段说明

环境变量:
  WINRUN_NO_BUILD=1   跳过 cargo build，直接装现成的 target/release/winrun-manager

装完用 `winrun-manager` 打开；卸载跑 `./install.sh uninstall`。
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

只是安装已经编译好的二进制则用: WINRUN_NO_BUILD=1 ./install.sh
EOF
    exit 1
}

build_manager() {
    if [[ "${WINRUN_NO_BUILD:-0}" != "1" ]]; then
        require_qt
        command -v cargo >/dev/null 2>&1 \
            || die "需要 cargo 来构建（或设 WINRUN_NO_BUILD=1 用现成产物）"
        say "构建 winrun-manager（首次较慢）..."
        cargo build --release
    fi
    [[ -x target/release/winrun-manager ]] \
        || die "没有 target/release/winrun-manager，先 cargo build --release"
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

    install -Dm755 target/release/winrun-manager "$BIN_DIR/winrun-manager"
    printf '%s\n' "$BIN_DIR/winrun-manager" >> "$tmp"

    local file
    for file in desktop/*.desktop; do
        install -Dm644 "$file" "$APP_DIR/$(basename "$file")"
        printf '%s\n' "$APP_DIR/$(basename "$file")" >> "$tmp"
    done

    install -Dm644 icons/winrun.png "$ICON_PNG/winrun.png"
    printf '%s\n' "$ICON_PNG/winrun.png" >> "$tmp"
    install -Dm644 icons/winrun.svg "$ICON_SVG/winrun.svg"
    printf '%s\n' "$ICON_SVG/winrun.svg" >> "$tmp"

    install -Dm644 "$tmp" "$MANIFEST"
    refresh_caches

    say "已安装到 $PREFIX"
    timeout 3 "$BIN_DIR/winrun-manager" --version 2>/dev/null || true
    say "打开: winrun-manager      卸载: $0 uninstall"
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
            "$BIN_DIR/winrun-manager"
            "$APP_DIR/winrun-manager.desktop"
            "$APP_DIR/winrun-run.desktop"
            "$APP_DIR/winrun-settings.desktop"
            "$ICON_PNG/winrun.png"
            "$ICON_SVG/winrun.svg"
        )
    fi

    # Bash CLI 时代留下的文件名，顺手清掉
    files+=(
        "$APP_DIR/winrun-run-windows-program.desktop"
        "$APP_DIR/winrun-windows-program-configure.desktop"
        "$BIN_DIR/winrun"
        "$BIN_DIR/winrun-configure"
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
        rm -rf "$PREFIX/lib/winrun"
    fi

    refresh_caches
    say "已从 $PREFIX 移除 winrun"
}

case "$MODE" in
    install) do_install ;;
    uninstall) do_uninstall ;;
    help | --help | -h) usage ;;
    *) usage >&2; exit 1 ;;
esac
