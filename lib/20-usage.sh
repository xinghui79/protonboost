# shellcheck shell=bash
# 全局状态跨模块共享（由主程序 source），对整个文件屏蔽未用变量提示
# shellcheck disable=SC2034
# WinRun — help texts

usage_en() {
  cat <<'EOF'
Usage:
  winrun [options] app.exe [args...]
  winrun [-p DIR] command [args...]   run a Linux program in the prefix's separate network

Options:
  --init                     initialize prefix, default ~/.proton
  -p, --prefix DIR           prefix directory, initialize if needed
  --status                   show prefix information
  --list-runner              list installed runners
  --runner PATH|ge|dw|we     use specified runner
  --install ge|dw|we         install runner to ~/.local/share/Steam/compatibilitytools.d
  --install-steam ge|dw|we   same as --install
  --install-lutris ge|dw|we  install runner for Lutris
  --download ge|dw|we        download runner only, default XDG download directory
  --list-version ge|dw|we    list available runner versions
  --version VERSION          use specific release tag, default latest
  --update                   update all installed Latest runners
  --check-update             check for available runner updates (no install)
  --doctor                   check wrapper environment and print diagnostics
  --remove ge|dw|we          remove runner from the default location
  --remove-steam ge|dw|we    remove runner from Steam, omit ge|dw|we to remove all wrapper-installed runners
  --remove-lutris ge|dw|we   remove runner from Lutris, omit ge|dw|we to remove all wrapper-installed runners
  --gs, --gamescope          run with Gamescope; use for compatibility, custom resolution/FPS, or FSR
  --mangohud                 enable MangoHud performance overlay
  --wayland                  run with Wine's Wayland driver (Proton runners, not with Gamescope)
  --netns on|off             give the prefix its own network namespace (for game accelerators), needs passt
  --debug                    write full debug log to ~/.cache/winrun/logs
  --help-full                show detailed help

Examples:
  winrun --init
  winrun /path/to/app.exe
  winrun --runner /path/to/proton /path/to/app.exe
  winrun -p /path/to/prefix /path/to/app.exe
  winrun --install we
  winrun --install-steam we
  winrun --download ge --version GE-Proton10-34
  winrun --gamescope --res 1920x1080 --fps 30 --fsr /path/to/app.exe
  winrun --debug /path/to/app.exe
  winrun --list-version we
  winrun --doctor
  winrun --update
EOF
}

usage_zh() {
  cat <<'EOF'
用法:
  winrun [选项] app.exe [参数...]
  winrun [-p 目录] 命令 [参数...]     在前置环境的独立网络里运行 Linux 程序

选项:
  --init                     初始化，默认路径 ~/.proton
  -p, --prefix 目录          指定前置环境路径，若不存在则初始化
  --status                   显示前置环境信息
  --list-runner              列出已安装的运行器
  --runner 路径|ge|dw|we     指定运行器
  --install ge|dw|we         安装运行器，默认安装至 ~/.local/share/Steam/compatibilitytools.d
  --install-steam ge|dw|we   同 --install
  --install-lutris ge|dw|we  给 Lutris 安装运行器
  --download ge|dw|we        仅下载运行器，默认下载路径为 XDG 下载目录
  --list-version ge|dw|we    列出可使用的运行器版本
  --version 版本             指定特定版本，默认 latest
  --update                   升级所有已安装的 Latest 运行器
  --check-update             检查运行器是否有可用更新（不安装）
  --doctor                   检查 wrapper 运行环境并输出诊断信息
  --remove ge|dw|we          移除默认位置中已安装的运行器
  --remove-steam ge|dw|we    移除 Steam 中指定运行器，省略 ge|dw|we 则移除全部由 wrapper 安装的运行器
  --remove-lutris ge|dw|we   移除 Lutris 中指定运行器，省略 ge|dw|we 则移除全部由 wrapper 安装的运行器
  --gs, --gamescope          用 Gamescope 运行。默认全屏；需要自定义分辨率、帧率、FSR 或遇到显示兼容问题时使用
  --mangohud                 启用 MangoHud 性能叠加层
  --wayland                  以 Wayland 运行（Proton 运行器，开 Gamescope 时不生效）
  --netns on|off             给前置环境开启独立网络命名空间（加速器用），需要 passt
  --debug                    将完整调试日志写入 ~/.cache/winrun/logs
  --help-full                显示完整说明

示例:
  winrun --init
  winrun /path/to/app.exe
  winrun --runner /path/to/proton /path/to/app.exe
  winrun -p /path/to/prefix /path/to/app.exe
  winrun --install we
  winrun --install-steam we
  winrun --download ge --version GE-Proton10-34
  winrun --gamescope --res 1920x1080 --fps 30 --fsr /path/to/app.exe
  winrun --debug /path/to/app.exe
  winrun --list-version we
  winrun --doctor
  winrun --update
EOF
}

usage_full_en() {
  cat <<'EOF'
Concepts:
  prefix   Compatibility data directory (Wine pfx at prefix/pfx)
  runner   Proton or Wine runtime for Windows executables

Run:
  winrun app.exe [args...]
  winrun -p ~/Games/game-prefix app.exe
  winrun --runner /path/to/proton app.exe

Prefix tools:
  winrun --init [-p DIR] [--runner PATH]
  winrun --winecfg [-p DIR] [--runner PATH]
  winrun --status [-p DIR] [--runner PATH]
  winrun --netns on|off [-p DIR]

Sessions:
  Programs running in the same prefix share one Wine session. A program
  started while the prefix is busy joins it at once and keeps the session's
  runner, display (X11, Wayland or Gamescope) and network. With --netns on
  the session gets its own network namespace, so the TUN adapter a game
  accelerator creates there carries the programs of that prefix only.
  A Linux program (a command, not a Windows program) given instead of an
  exe runs in that namespace as the user, e.g. "winrun steam";
  with --netns off it just runs.

Runner discovery:
  winrun --list-runner
  winrun --list-version ge|dw|we

Download only:
  winrun --download ge [-d DIR] [--version TAG]
  winrun --download dw [-d DIR] [--version TAG]

Install runner:
  winrun --install ge [-d DIR] [--version TAG]
  winrun --install dw [-d DIR] [--version TAG]
  winrun --install-steam ge|dw|we
  winrun --install-lutris ge|dw|we

Update runners:
  winrun --update
  winrun --check-update

Diagnostics:
  winrun --doctor

Remove runner:
  winrun --remove ge|dw|we
  winrun --remove-steam ge|dw|we
  winrun --remove-lutris ge|dw|we

Install targets:
  steam   ~/.local/share/Steam/compatibilitytools.d (default)
  local   ~/.local/share/proton/runners (earlier versions; still used and updated)
  lutris  ~/.local/share/lutris/runners/wine

Environment:
  WINRUN_PREFIX     prefix path
  WINRUN_RUNNER     runner path
  PROTON_LANG       zh|en
EOF
}

usage_full_zh() {
  cat <<'EOF'
概念:
  prefix   前置环境目录 (Wine 环境在 prefix/pfx)
  runner   运行器 (Proton 或 Wine)

运行:
  winrun app.exe [参数...]
  winrun -p ~/Games/game-prefix app.exe
  winrun --runner /path/to/proton app.exe

前置环境:
  winrun --init [-p 目录] [--runner 路径]
  winrun --winecfg [-p 目录] [--runner 路径]
  winrun --status [-p 目录] [--runner 路径]
  winrun --netns on|off [-p 目录]

会话:
  同一个前置环境里同时运行的程序共用一个 Wine 会话。前置环境里已有程序在运行时，
  新程序会直接加入，并沿用会话的运行器、显示方式（X11、Wayland 或 Gamescope）和网络。
  开启 --netns 后会话有独立的网络命名空间，加速器在里面建立的虚拟网卡只接管这个前置环境里的程序。
  把 exe 换成 Linux 程序（命令），它会以当前用户在这个命名空间里运行，例如 winrun steam；
  没开 --netns 时直接运行。

运行器发现:
  winrun --list-runner
  winrun --list-version ge|dw|we

只下载:
  winrun --download ge [-d 目录] [--version 标签]
  winrun --download dw [-d 目录] [--version 标签]

安装运行器:
  winrun --install ge [-d 目录] [--version 标签]
  winrun --install dw [-d 目录] [--version 标签]
  winrun --install-steam ge|dw|we
  winrun --install-lutris ge|dw|we

更新运行器:
  winrun --update
  winrun --check-update

诊断:
  winrun --doctor

移除运行器:
  winrun --remove ge|dw|we
  winrun --remove-steam ge|dw|we
  winrun --remove-lutris ge|dw|we

安装目标:
  steam   ~/.local/share/Steam/compatibilitytools.d（默认）
  local   ~/.local/share/proton/runners（旧版本的位置，照常使用和更新）
  lutris  ~/.local/share/lutris/runners/wine

环境变量:
  WINRUN_PREFIX     前置环境路径
  WINRUN_RUNNER     运行器路径
  PROTON_LANG       zh|en
EOF
}

usage() {
  if [[ "$(ui_lang)" == "zh" ]]; then
    usage_zh
  else
    usage_en
  fi
}

usage_full() {
  if [[ "$(ui_lang)" == "zh" ]]; then
    usage_full_zh
  else
    usage_full_en
  fi
}

gamescope_usage_en() {
  cat <<'EOF'
Usage:
  winrun --gamescope [gamescope options] app.exe [args...]

Gamescope options:
  --windowed             run Gamescope in a window
  --fullscreen           run Gamescope fullscreen (default)
  --res WIDTHxHEIGHT     set game render resolution, e.g. 1920x1080
  --fps FPS              limit frame rate
  --fsr                  enable FSR upscaling
  --args ARGS            append custom Gamescope arguments
  --mangohud             enable MangoHud performance overlay
  -h, --help             show this help

Example:
  winrun --gamescope --windowed --res 1920x1080 --fps 30 --fsr --mangohud game.exe
EOF
}

gamescope_usage_zh() {
  cat <<'EOF'
用法:
  winrun --gamescope [Gamescope 选项] app.exe [参数...]

Gamescope 选项:
  --windowed             窗口模式
  --fullscreen           全屏模式 (默认)
  --res 宽x高            设置游戏渲染分辨率，例如 1920x1080
  --fps 帧率             限制帧率
  --fsr                  启用 FSR 超分辨率
  --args 参数            追加自定义 Gamescope 参数
  --mangohud             启用 MangoHud 性能叠加层
  -h, --help             显示本帮助

示例:
  winrun --gamescope --windowed --res 1920x1080 --fps 30 --fsr --mangohud game.exe
EOF
}

gamescope_usage() {
  if [[ "$(ui_lang)" == "zh" ]]; then
    gamescope_usage_zh
  else
    gamescope_usage_en
  fi
}

