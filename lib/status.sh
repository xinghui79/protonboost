# shellcheck shell=bash
# 全局状态跨模块共享（由主程序 source），对整个文件屏蔽未用变量提示
# shellcheck disable=SC2034
# WinRun — status and doctor

runtime_status() {
  local type="$1" runner="$2" appid runtime
  if [[ "$type" != "proton" ]]; then
    printf 'not used (wine runner)\n'
  elif [[ "$RUNTIME_ENABLED" == 0 ]]; then
    printf 'off (WINRUN_RUNTIME=0)\n'
  elif ! appid="$(required_runtime_appid "$runner")" || ! runtime_info "$appid" >/dev/null; then
    printf 'not used (the runner asks for none)\n'
  elif runner_is_old_weproton "$runner"; then
    printf 'not used (WE-Proton before release 10)\n'
  elif runtime="$(find_runtime "$appid")"; then
    printf '%s\n' "$runtime"
  else
    printf 'downloaded on first run (%s)\n' "$(runtime_info "$appid" | head -n 1)"
  fi
}

show_status() {
  local runner_type runner_path initialized install_dir download_dir lang runtime netns session
  PREFIX="$(expand_path "$PREFIX")"
  download_dir="$(expand_path "${DOWNLOAD_DIR:-$(xdg_download_dir)}")"
  install_dir="$(expand_path "${INSTALL_DIR:-$(default_install_dir)}")"
  lang="$(ui_lang)"

  runner_type="not found"
  runner_path="not found"
  if try_select_runner >/dev/null 2>&1; then
    runner_type="$RESOLVED_RUNNER_TYPE"
    runner_path="$RESOLVED_RUNNER_PATH"
  fi

  initialized="no"
  if [[ -d "$PREFIX/pfx" ]]; then
    initialized="yes"
  fi
  runtime="$(runtime_status "$runner_type" "$runner_path")"
  netns="$(netns_status_text)"
  session="$(session_status_text)"

  if [[ "$lang" == "zh" ]]; then
    [[ "$initialized" == "yes" ]] && initialized="是" || initialized="否"
    printf '前置环境:   %s\n' "$PREFIX"
    printf 'PFX:        %s\n' "$PREFIX/pfx"
    printf '已初始化:   %s\n' "$initialized"
    printf '运行器类型: %s\n' "$runner_type"
    printf '运行器:     %s\n' "$runner_path"
    printf 'Steam 运行时: %s\n' "$runtime"
    printf '独立网络:   %s\n' "$netns"
    printf '会话:       %s\n' "$session"
    printf '下载目录:   %s\n' "$download_dir"
    printf '安装目录:   %s\n' "$install_dir"
  else
    printf 'Prefix:      %s\n' "$PREFIX"
    printf 'PFX:         %s\n' "$PREFIX/pfx"
    printf 'Initialized: %s\n' "$initialized"
    printf 'Runner type: %s\n' "$runner_type"
    printf 'Runner:      %s\n' "$runner_path"
    printf 'Runtime:     %s\n' "$runtime"
    printf 'Netns:       %s\n' "$netns"
    printf 'Session:     %s\n' "$session"
    printf 'Download:    %s\n' "$download_dir"
    printf 'Install dir: %s\n' "$install_dir"
  fi
}

netns_status_text() {
  if prefix_netns_enabled; then
    [[ "$(ui_lang)" == "zh" ]] && printf '开\n' || printf 'on\n'
  else
    [[ "$(ui_lang)" == "zh" ]] && printf '关\n' || printf 'off\n'
  fi
}

session_status_text() {
  local ws keeper kind net
  ws="$(prefix_wineserver_pid || true)"
  keeper="$(session_keeper_pid "$(session_dir)" || true)"
  if [[ -z "$ws" && -z "$keeper" ]]; then
    [[ "$(ui_lang)" == "zh" ]] && printf '未运行\n' || printf 'not running\n'
    return 0
  fi
  kind="-"
  if [[ -n "$ws" ]]; then
    kind="$(session_display_kind "$ws")"
  fi
  if [[ "$(ui_lang)" == "zh" ]]; then
    net="普通网络"
    [[ -z "$keeper" ]] || net="独立网络"
    printf '运行中（%s，显示：%s）\n' "$net" "$kind"
  else
    net="normal network"
    [[ -z "$keeper" ]] || net="separate network"
    printf 'running (%s, display: %s)\n' "$net" "$kind"
  fi
}

# --netns on|off: whether the prefix's sessions get their own network namespace
netns_command() {
  if [[ -n "$NETNS_ARG" ]]; then
    if [[ "$NETNS_ARG" == "on" ]] && ! command -v pasta > /dev/null 2>&1; then
      die "passt (pasta) is not installed"
    fi
    set_prefix_netns "$([[ "$NETNS_ARG" == "on" ]] && printf 1 || printf 0)"
  fi
  if [[ "$(ui_lang)" == "zh" ]]; then
    printf '独立网络: %s\n会话:     %s\n' "$(netns_status_text)" "$(session_status_text)"
  else
    printf 'netns:   %s\nsession: %s\n' "$(netns_status_text)" "$(session_status_text)"
  fi
}

doctor_status() {
  local label="$1" status="$2" detail="${3:-}"
  if [[ -n "$detail" ]]; then
    printf '%-24s %s  %s\n' "$label" "$status" "$detail"
  else
    printf '%-24s %s\n' "$label" "$status"
  fi
}

doctor_command() {
  local label="$1" command_name="$2" path
  if path="$(command -v "$command_name" 2>/dev/null)"; then
    doctor_status "$label" ok "$path"
  else
    doctor_status "$label" missing "$command_name"
  fi
}

doctor_python_module() {
  local label="$1" module="$2"
  if python3 - "$module" >/dev/null 2>&1 <<'PY'
import importlib
import sys

importlib.import_module(sys.argv[1])
PY
  then
    doctor_status "$label" ok "$module"
  else
    doctor_status "$label" missing "$module"
  fi
}

doctor_gtk() {
  if python3 >/dev/null 2>&1 <<'PY'
import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gtk  # noqa: F401
PY
  then
    doctor_status "GTK 4 Python" ok "gi.repository.Gtk"
  else
    doctor_status "GTK 4 Python" missing "python-gobject / gtk4"
  fi
}

run_doctor() {
  local old_runner_type old_runner_path initialized default_runner default_runner_detail runner_count i
  old_runner_type="$RESOLVED_RUNNER_TYPE"
  old_runner_path="$RESOLVED_RUNNER_PATH"

  printf 'WinRun doctor\n'
  printf '\nCommands:\n'
  doctor_command "python3" python3
  doctor_command "curl" curl
  doctor_command "wget" wget
  doctor_command "tar" tar
  doctor_command "sha512sum" sha512sum
  doctor_command "notify-send" notify-send
  doctor_command "pasta (netns)" pasta
  doctor_command "nsenter (netns)" nsenter
  doctor_command "cc (netns overlay)" cc
  doctor_command "flock" flock
  doctor_gtk
  doctor_python_module "PyGObject" gi

  printf '\nPaths:\n'
  doctor_status "prefix" "$PREFIX" "$PREFIX/pfx"
  doctor_status "install dir" "$STEAM_RUNNER_DIR"
  doctor_status "download cache" "$INSTALL_DOWNLOAD_DIR"
  doctor_status "log dir" "$WRAPPER_CACHE_DIR/logs"

  printf '\nRuntime:\n'
  if [[ -e /lib/ld-linux.so.2 || -e /usr/lib/ld-linux.so.2 ]]; then
    doctor_status "32-bit loader" ok "ld-linux.so.2"
  else
    doctor_status "32-bit loader" missing "only needed with PROTON_USE_WOW64=0: enable multilib and install lib32-cairo on Arch"
  fi
  if ldconfig -p 2>/dev/null | grep -q 'libcairo.so.*(libc6'; then
    doctor_status "32-bit cairo" ok "libcairo.so"
  else
    doctor_status "32-bit cairo" unknown "only needed with PROTON_USE_WOW64=0: install lib32-cairo on Arch"
  fi
  if notify_available; then
    if notify_can_replace; then
      doctor_status "desktop notify" ok
    else
      doctor_status "desktop notify" ok "notify-send cannot update a notification; only start and end are shown"
    fi
  else
    doctor_status "desktop notify" unavailable "notifications will be skipped"
  fi
  if try_select_runner >/dev/null 2>&1; then
    doctor_status "steam runtime" "$(runtime_status "$RESOLVED_RUNNER_TYPE" "$RESOLVED_RUNNER_PATH")"
  fi

  printf '\nRunners:\n'
  collect_runners
  runner_count="${#RUNNER_PATHS[@]}"
  doctor_status "found" "$runner_count"
  if [[ "$runner_count" -gt 0 ]]; then
    for i in "${!RUNNER_PATHS[@]}"; do
      printf '  %s · %s · %s\n' "${RUNNER_NAMES[$i]}" "${RUNNER_SOURCES[$i]}" "${RUNNER_PATHS[$i]}"
    done
  fi
  if try_select_runner >/dev/null 2>&1; then
    default_runner="$RESOLVED_RUNNER_PATH"
    default_runner_detail="$RESOLVED_RUNNER_TYPE"
    doctor_status "default runner" ok "$default_runner_detail · $default_runner"
  else
    doctor_status "default runner" missing "run winrun --install $DEFAULT_PRODUCT"
  fi

  printf '\nPrefix:\n'
  initialized="no"
  [[ -d "$PREFIX/pfx" ]] && initialized="yes"
  doctor_status "initialized" "$initialized" "$PREFIX/pfx"

  RESOLVED_RUNNER_TYPE="$old_runner_type"
  RESOLVED_RUNNER_PATH="$old_runner_path"
}

