#!/usr/bin/env bash
# WinRun 安装/卸载脚本
# 用法: ./install.sh [install|uninstall] [PREFIX]   (默认 install ~/.local)
set -euo pipefail

MODE="${1:-install}"
PREFIX="${2:-$HOME/.local}"
BIN_DIR="$PREFIX/bin"
APP_DIR="$PREFIX/share/applications"
ICON_PNG="$PREFIX/share/icons/hicolor/512x512/apps"
ICON_SVG="$PREFIX/share/icons/hicolor/scalable/apps"

build_manager() {
    if [[ -x target/release/winrun-manager ]]; then
        return
    fi
    command -v cargo >/dev/null 2>&1 || {
        echo "需要 cargo 构建 winrun-manager（或先手动 cargo build --release）" >&2
        exit 1
    }
    echo "构建 winrun-manager（首次较慢）..."
    cargo build --release
}

case "$MODE" in
install)
    build_manager
    install -Dm755 -t "$BIN_DIR" bin/winrun
    install -Dm755 target/release/winrun-manager "$BIN_DIR/winrun-manager"
    install -d "$PREFIX/lib/winrun"
    install -m644 -t "$PREFIX/lib/winrun" lib/*.sh
    install -Dm644 -t "$APP_DIR" share/applications/*.desktop
    install -Dm644 icons/hicolor/512x512/apps/winrun.png "$ICON_PNG/winrun.png"
    install -Dm644 icons/hicolor/scalable/apps/winrun.svg "$ICON_SVG/winrun.svg"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 && gtk-update-icon-cache -qtf "$PREFIX/share/icons/hicolor" || true
    # 默认打开独立网络（本项目的使用方式）；--netns off 随时关
    "$BIN_DIR/winrun" --netns on || true
    echo "已安装到 $PREFIX — 命令: winrun / winrun-manager（Qt6 版）"
    ;;
uninstall)
    rm -f "$BIN_DIR/winrun" "$BIN_DIR/winrun-configure" "$BIN_DIR/winrun-manager"
    rm -f "$APP_DIR/winrun-manager.desktop" \
          "$APP_DIR/winrun-run-windows-program.desktop" \
          "$APP_DIR/winrun-windows-program-configure.desktop"
    rm -f "$ICON_PNG/winrun.png" "$ICON_SVG/winrun.svg"
    rm -rf "$PREFIX/lib/winrun"
    command -v update-desktop-database >/dev/null 2>&1 && update-desktop-database "$APP_DIR" || true
    echo "已从 $PREFIX 移除 winrun"
    ;;
*)
    echo "用法: $0 [install|uninstall] [PREFIX]" >&2
    exit 1
    ;;
esac
