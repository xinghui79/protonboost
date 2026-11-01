# shellcheck shell=bash
# 全局状态跨模块共享（由主程序 source），对整个文件屏蔽未用变量提示
# shellcheck disable=SC2034
# WinRun — sessions and network namespace (pasta keeper)

# ------------------------------------------------------------------ sessions
# All programs running in a prefix share one wineserver, and with it the
# display driver Wine's desktop picked and the network namespace it lives in.
# The running wineserver is the session: a program started while there is one
# joins it at once (Proton's "run"; "waitforexitandrun" waits for every program
# already running to exit) and keeps its runner and display. With the prefix's
# netns setting on, a session gets its own network namespace from pasta; a
# keeper process inside holds it open until the last program is gone, and
# every program enters it with nsenter. Starting a program takes the session's
# lock until the program is safely part of the session, so two programs
# started at once never set up two sessions.

SESSION_ROOT="${XDG_RUNTIME_DIR:-/tmp/winrun-$(id -u)}/winrun/sessions"
SESSION_LOCK_FD=""
SESSION_SETTLE=""
SESSION_NETNS=""
SESSION_KEEPER_PID=""
SESSION_ACTIVE=0
# what the program took on from the running session, for its log
SESSION_NOTES=()
# what the user is told
SESSION_NOTICE=()
SESSION_INHERITED=0
LAUNCH_TOKEN=""
PROTON_VERB="waitforexitandrun"
HOST_NETNS="$(readlink /proc/self/ns/net 2>/dev/null || true)"

session_message() {
  local key="$1" arg="${2:-}"
  if [[ "$(ui_lang)" == "zh" ]]; then
    case "$key" in
      netns_busy) printf '这个前置环境里有程序正在普通网络中运行，独立网络要等它们全部关闭后才生效。请先关闭这些程序。\n' ;;
      netns_orphan) printf '这个前置环境的独立网络会话已经没有网络了（会话守护进程不在了）。请在管理器的进程页强制关闭这个前置环境的进程后再试。\n' ;;
      no_pasta) printf '这个前置环境开启了独立网络，但没有安装 passt（pasta）。\n' ;;
      no_nsenter) printf '找不到 nsenter（util-linux）。\n' ;;
      keeper_failed) printf '独立网络会话没能启动，见日志：%s\n' "$arg" ;;
      busy_init) printf '这个前置环境里有程序正在运行，请先关闭它们再初始化。\n' ;;
      inherited) printf '前置环境正在运行，自动继承相关设置。\n' ;;
      runner) printf '这个前置环境正在用 %s 运行，这个程序也改用它。\n' "$arg" ;;
      gamescope_session) printf '这个前置环境的程序正在 Gamescope 里运行，其他程序不能再加入。请先关闭它们。\n' ;;
      no_gamescope) printf '这个前置环境已有程序在运行，这次不使用 Gamescope。\n' ;;
      to_wayland) printf '这个前置环境的程序以 Wayland 运行，这个程序也一样。\n' ;;
      to_x11) printf '这个前置环境的程序以 X11 运行，这次不使用 Wayland。\n' ;;
      no_wayland) printf '当前不是 Wayland 桌面，这次以 X11 运行。\n' ;;
      other_session) printf '这里是另一个前置环境的独立网络，不能从这里启动 %s 的程序。\n' "$arg" ;;
      no_launch) printf '这个独立网络会话是旧版本的 wrapper 启动的，里面的 Linux 程序不能启动 Windows 程序。请关闭这个前置环境的程序后再试。\n' ;;
    esac
  else
    case "$key" in
      netns_busy) printf 'Programs of this prefix are running on the normal network. The separate network takes effect once they are all closed; close them first.\n' ;;
      netns_orphan) printf "This prefix's separate network session has lost its network (its keeper is gone). Force close the prefix's processes on the manager's process page and try again.\n" ;;
      no_pasta) printf 'This prefix uses a separate network, but passt (pasta) is not installed.\n' ;;
      no_nsenter) printf 'nsenter (util-linux) was not found.\n' ;;
      keeper_failed) printf 'The separate network session did not start, see the log: %s\n' "$arg" ;;
      busy_init) printf 'Programs of this prefix are running; close them before initializing it.\n' ;;
      inherited) printf 'The prefix is running; this program takes on its settings.\n' ;;
      runner) printf 'This prefix is running with %s; this program uses it too.\n' "$arg" ;;
      gamescope_session) printf 'Programs of this prefix are running in Gamescope, no other program can join them. Close them first.\n' ;;
      no_gamescope) printf 'Programs of this prefix are already running; this time without Gamescope.\n' ;;
      to_wayland) printf 'Programs of this prefix run on Wayland; so does this one.\n' ;;
      to_x11) printf 'Programs of this prefix run on X11; this time without Wayland.\n' ;;
      no_wayland) printf 'This is not a Wayland desktop; running on X11 this time.\n' ;;
      other_session) printf "This is another prefix's separate network; programs of %s cannot be started from here.\n" "$arg" ;;
      no_launch) printf 'This separate network session was started by an older version of the wrapper; its Linux programs cannot start Windows programs. Close the programs of this prefix and try again.\n' ;;
    esac
  fi
}

notify_info() {
  notify_send normal "$DOWNLOAD_NOTIFY_EXPIRE" "WinRun" "$1"
}

# Settings of the prefix itself, next to its pfx.
prefix_conf_file() {
  printf '%s/.winrun.conf\n' "$PREFIX"
}

prefix_netns_enabled() {
  local file
  file="$(prefix_conf_file)"
  [[ -r "$file" ]] && grep -qx 'netns=1' "$file"
}

set_prefix_netns() {
  local file tmp
  file="$(prefix_conf_file)"
  tmp="$file.tmp.$$"
  mkdir -p "$PREFIX"
  {
    if [[ -r "$file" ]]; then
      grep -v '^netns=' "$file" || true
    fi
    printf 'netns=%s\n' "$1"
  } > "$tmp"
  mv "$tmp" "$file"
}

pid_netns() {
  readlink "/proc/$1/ns/net" 2>/dev/null || true
}

# The value of one variable in a process's environment.
pid_env() {
  local line
  {
    while IFS= read -r -d '' line; do
      if [[ "$line" == "$2="* ]]; then
        printf '%s\n' "${line#*=}"
        break
      fi
    done < "/proc/$1/environ"
  } 2>/dev/null || true
}

# The prefix's wineserver, in whichever namespace it runs. Wine names the
# server directory after the device and inode of the prefix, and the server
# keeps it as its working directory.
prefix_wineserver_pid() {
  local st suffix pid cwd
  st="$(stat -L -c '%d %i' "$PREFIX/pfx" 2>/dev/null)" || return 1
  printf -v suffix 'server-%x-%x' "${st% *}" "${st#* }"
  for pid in $(pgrep -x wineserver 2>/dev/null || true); do
    cwd="$(readlink "/proc/$pid/cwd" 2>/dev/null)" || continue
    if [[ "$cwd" == /tmp/.wine-*/"$suffix" ]]; then
      printf '%s\n' "$pid"
      return 0
    fi
  done
  return 1
}

session_dir() {
  printf '%s/%s\n' "$SESSION_ROOT" "$(printf '%s' "$PREFIX" | sha256sum | cut -c1-16)"
}

# The live keeper of the prefix's network namespace session.
session_keeper_pid() {
  local dir="$1" pid netns
  pid="$(cat "$dir/keeper.pid" 2>/dev/null)" || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  netns="$(pid_netns "$pid")"
  [[ -n "$netns" && "$(cat "$dir/netns" 2>/dev/null)" == "$netns" ]] || return 1
  printf '%s\n' "$pid"
}

prefix_session_active() {
  prefix_wineserver_pid > /dev/null || session_keeper_pid "$(session_dir)" > /dev/null
}

# The session whose network namespace the wrapper itself runs in, if any: a
# program of the session started it, Steam running there say.
session_here() {
  local file
  [[ -n "$HOST_NETNS" ]] || return 1
  for file in "$SESSION_ROOT"/*/netns; do
    if [[ -r "$file" && "$(cat "$file")" == "$HOST_NETNS" ]]; then
      dirname "$file"
      return 0
    fi
  done
  return 1
}

# Whether the wrapper runs in the session's user namespace, as the session's
# Windows programs do, rather than in the one of a Linux program of the
# session (see run_linux_target), from which it cannot enter the session.
session_userns_here() {
  local dir="$1"
  if [[ -r "$dir/userns" ]]; then
    [[ "$(cat "$dir/userns")" == "$(readlink /proc/self/ns/user 2> /dev/null)" ]]
  else
    # a keeper of an older version: only its user namespace can look at it
    session_keeper_pid "$dir" > /dev/null
  fi
}

session_lock() {
  local dir
  dir="$(session_dir)"
  mkdir -p "$dir"
  exec {SESSION_LOCK_FD}>"$dir/lock"
  flock "$SESSION_LOCK_FD"
}

session_unlock() {
  [[ -n "$SESSION_LOCK_FD" ]] || return 0
  flock -u "$SESSION_LOCK_FD" 2> /dev/null || true
  exec {SESSION_LOCK_FD}>&-
  SESSION_LOCK_FD=""
}

# MAC address for the adapter inside the namespace. pasta makes up a new one on
# every start, which to anti-cheat looks like a machine-ID changer; use the one
# of the host adapter the default route goes through instead, so programs see
# the same adapter with or without the namespace. The fallback is the one
# wegame-launcher uses, so both show the same adapter.
namespace_mac_address() {
  local iface dest flags metric best="" best_metric=0 mac hex first
  {
    read -r _
    while read -r iface dest _ flags _ _ metric _; do
      [[ "$dest" == "00000000" ]] || continue
      (( 16#$flags & 1 )) || continue
      if [[ -z "$best" ]] || (( metric < best_metric )); then
        best="$iface"
        best_metric="$metric"
      fi
    done
  } < /proc/net/route 2> /dev/null || true
  if [[ -n "$best" ]]; then
    mac="$(cat "/sys/class/net/$best/address" 2> /dev/null || true)"
    if [[ "$mac" =~ ^([0-9a-f]{2}:){5}[0-9a-f]{2}$ && "$mac" != "00:00:00:00:00:00" ]]; then
      printf '%s\n' "$mac"
      return 0
    fi
  fi
  hex="$({ printf 'wegame-launcher netns '; cat /etc/machine-id 2> /dev/null || printf '%s' "$HOME"; } | sha256sum | cut -c1-12)"
  first=$(( (16#${hex:0:2} & 0xfc) | 0x02 ))
  printf '%02x:%s:%s:%s:%s:%s\n' "$first" "${hex:2:2}" "${hex:4:2}" "${hex:6:2}" "${hex:8:2}" "${hex:10:2}"
}

# Start the prefix's network namespace and its keeper; sets SESSION_KEEPER_PID.
session_start() {
  local dir="$1" log mac i pidns
  command -v pasta > /dev/null 2>&1 || die_visible "$(session_message no_pasta)"
  command -v nsenter > /dev/null 2>&1 || die_visible "$(session_message no_nsenter)"
  rm -f "$dir/keeper.pid" "$dir/netns" "$dir/userns" "$dir/bus" "$dir/launch"
  log="$WRAPPER_CACHE_DIR/logs/session-$(basename "$dir").log"
  mkdir -p "$(dirname "$log")"
  mac="$(namespace_mac_address)"
  # newer pasta starts the command in a new PID namespace unless told not to;
  # older ones never do and don't know the option
  pidns=()
  [[ "$(pasta --help 2>&1 || true)" == *--no-pidns* ]] && pidns=(--no-pidns)
  printf -- '--- %s %s\n' "$(date '+%F %T')" "$PREFIX" >> "$log"
  # pasta forwards automatically only the host's ports outside the ephemeral
  # range; the Steam client's 57343, in it, the keeper forwards itself while
  # the host's Steam runs. A game Steam starts brings Steam's overlay in
  # LD_PRELOAD, which the namespace's own programs must not get.
  setsid env -u WINRUN_APP_ID -u WINRUN_APP_PATH -u WINRUN_LOG -u LD_PRELOAD \
    WINRUN_PREFIX="$PREFIX" \
    pasta --config-net --ns-mac-addr "$mac" -T auto -f "${pidns[@]}" -- "$SELF_PATH" --session-keeper "$dir" \
    >> "$log" 2>&1 < /dev/null {SESSION_LOCK_FD}>&- &
  for ((i = 0; i < 75; i++)); do
    if SESSION_KEEPER_PID="$(session_keeper_pid "$dir")"; then
      printf 'Session: separate network namespace started, log %s\n' "$log"
      return 0
    fi
    sleep 0.2
  done
  die_visible "$(session_message keeper_failed "$log")"
}

# Run with the session's runner: a wineserver only talks to its own version.
session_adopt_runner() {
  local exe bin root type path
  exe="$(readlink "/proc/$1/exe" 2> /dev/null || true)"
  exe="${exe% (deleted)}"
  exe="${exe#/run/host}"
  [[ -n "$exe" ]] || return 0
  bin="$(dirname "$exe")"
  root="$(dirname "$bin")"
  if [[ "$(basename "$root")" == "files" ]]; then
    root="$(dirname "$root")"
  fi
  if [[ -x "$root/proton" ]]; then
    type="proton"
    path="$(realpath -m "$root/proton")"
  elif [[ -x "$bin/wine" ]]; then
    type="wine"
    path="$(realpath -m "$bin/wine")"
  else
    return 0
  fi
  if [[ "$path" != "$(realpath -m "$RESOLVED_RUNNER_PATH")" ]]; then
    SESSION_NOTES+=("$(session_message runner "$(runner_name_from_path "$type" "$path")")")
    SESSION_INHERITED=1
    RESOLVED_RUNNER_TYPE="$type"
    RESOLVED_RUNNER_PATH="$path"
  fi
  return 0
}

# How the session shows its windows. The wineserver keeps the environment of
# the program that started it: a nested Gamescope leaves its own display there
# (one the desktop itself runs in, e.g. Steam's game mode, is everyone's).
session_display_kind() {
  local gamescope
  gamescope="$(pid_env "$1" GAMESCOPE_WAYLAND_DISPLAY)"
  if [[ -n "$gamescope" && "$gamescope" != "${GAMESCOPE_WAYLAND_DISPLAY:-}" ]]; then
    printf 'gamescope\n'
  elif [[ "$(pid_env "$1" WINE_GRAPHICS_DRIVER)" == "wayland" ]]; then
    printf 'wayland\n'
  else
    printf 'x11\n'
  fi
}

# Wine's desktop picks the display driver and screen for every program of the
# session, so a program joining it shows its windows the way the session does.
# A program in another Gamescope would draw there while thinking the screen is
# the desktop's; one joining a Gamescope session would lose its windows when
# the program that runs Gamescope exits.
session_adopt_display() {
  local kind
  kind="$(session_display_kind "$1")"
  if [[ "$kind" == "gamescope" ]]; then
    die_visible "$(session_message gamescope_session)"
  fi
  if [[ $GAMESCOPE -eq 1 ]]; then
    GAMESCOPE=0
    SESSION_NOTES+=("$(session_message no_gamescope)")
    SESSION_INHERITED=1
  fi
  if [[ "$kind" == "wayland" && $WAYLAND -eq 0 ]]; then
    WAYLAND=1
    SESSION_NOTES+=("$(session_message to_wayland)")
    SESSION_INHERITED=1
  elif [[ "$kind" == "x11" && $WAYLAND -eq 1 ]]; then
    WAYLAND=0
    SESSION_NOTES+=("$(session_message to_x11)")
    SESSION_INHERITED=1
  fi
  return 0
}

# Decide how this launch enters the prefix's session, setting one up when there
# is none: PROTON_VERB, JOIN_PREFIX and SESSION_ENV for build_launch_command.
# It may switch the runner, Gamescope and Wayland to match the running session.
session_prepare() {
  local dir ws ws_netns keeper overrides item want_netns=0 inside=0
  dir="$(session_dir)"
  [[ -n "$SESSION_LOCK_FD" ]] || session_lock
  if prefix_netns_enabled; then
    want_netns=1
  fi
  # started from inside the session's namespace, by its keeper for a Linux
  # program of the session (delegate_to_keeper)
  if [[ "$(session_here || true)" == "$dir" ]]; then
    inside=1
  fi
  JOIN_PREFIX=()
  SESSION_ENV=()
  SESSION_NOTES=()
  SESSION_NOTICE=()
  SESSION_INHERITED=0
  SESSION_NETNS=""
  SESSION_SETTLE="wineserver"
  PROTON_VERB="waitforexitandrun"
  LAUNCH_TOKEN="$$-$RANDOM$RANDOM"
  keeper="$(session_keeper_pid "$dir" || true)"
  ws="$(prefix_wineserver_pid || true)"

  SESSION_ACTIVE=0
  if [[ -n "$ws" ]]; then
    SESSION_ACTIVE=1
    ws_netns="$(pid_netns "$ws")"
    if [[ $inside -eq 0 && "$ws_netns" == "$HOST_NETNS" ]]; then
      if [[ $want_netns -eq 1 ]]; then
        die_visible "$(session_message netns_busy)"
      fi
      keeper=""
    elif [[ -z "$keeper" || "$(pid_netns "$keeper")" != "$ws_netns" ]]; then
      die_visible "$(session_message netns_orphan)"
    fi
    session_adopt_runner "$ws"
    session_adopt_display "$ws"
    PROTON_VERB="run"
    # Proton runs a program's fixes (protonfixes) only for waitforexitandrun,
    # which would first wait for the session to end; WE-Proton also runs them
    # for this run when asked to
    SESSION_ENV+=("PROTONFIXES_RUN_VERB=1")
    SESSION_SETTLE=""
  elif [[ -z "$keeper" && $want_netns -eq 1 ]]; then
    [[ $inside -eq 0 ]] || die_visible "$(session_message netns_orphan)"
    session_start "$dir"
    keeper="$SESSION_KEEPER_PID"
  fi

  if [[ -n "$keeper" ]]; then
    SESSION_NETNS="$(pid_netns "$keeper")"
    if [[ $inside -eq 0 ]]; then
      JOIN_PREFIX=(nsenter -t "$keeper" -U -n --preserve-credentials --)
    fi
    if [[ -n "$ws" ]]; then
      SESSION_SETTLE="joined"
    fi
    # an accelerator's wintun.dll would install a Windows driver; WE-Proton's
    # builtin one creates a TUN adapter in the namespace instead
    overrides="${WINEDLLOVERRIDES:-}"
    for item in "${CACHED_ENV[@]}"; do
      if [[ "$item" == WINEDLLOVERRIDES=* ]]; then
        overrides="${item#*=}"
      fi
    done
    SESSION_ENV+=("WINEDLLOVERRIDES=${overrides:+$overrides;}wintun=b")
    # pasta maps the user to root in the namespace, which the session bus
    # refuses; the keeper bridges it
    if [[ -S "$dir/bus" ]]; then
      SESSION_ENV+=("DBUS_SESSION_BUS_ADDRESS=unix:path=$dir/bus")
    fi
  fi
  SESSION_ENV+=("WINRUN_LAUNCH=$LAUNCH_TOKEN")

  if [[ $WAYLAND -eq 1 && $GAMESCOPE -eq 0 && -z "${WAYLAND_DISPLAY:-}" ]]; then
    WAYLAND=0
    SESSION_NOTES+=("$(session_message no_wayland)")
    SESSION_NOTICE+=("$(session_message no_wayland)")
  fi
  if [[ $SESSION_INHERITED -eq 1 ]]; then
    SESSION_NOTICE=("$(session_message inherited)" "${SESSION_NOTICE[@]}")
  fi
  if (( ${#SESSION_NOTES[@]} )); then
    printf 'Session: %s\n' "${SESSION_NOTES[@]}"
  fi
  if (( ${#SESSION_NOTICE[@]} )); then
    notify_info "$(printf '%s\n' "${SESSION_NOTICE[@]}")"
  fi
  printf 'Session: verb %s%s\n' "$PROTON_VERB" "${keeper:+, network namespace of keeper $keeper}"
}

# Whether a process of this launch has entered the session's namespace.
session_token_in_netns() {
  python3 - "$SESSION_NETNS" "WINRUN_LAUNCH=$LAUNCH_TOKEN" <<'PY'
import os
import sys

netns, token = sys.argv[1], sys.argv[2].encode()
for name in os.listdir("/proc"):
    if not name.isdigit():
        continue
    try:
        if os.readlink(f"/proc/{name}/ns/net") != netns:
            continue
        with open(f"/proc/{name}/environ", "rb") as file:
            if token in file.read().split(b"\0"):
                sys.exit(0)
    except OSError:
        pass
sys.exit(1)
PY
}

# Hold the session lock until the program is part of the session: a new
# session's wineserver is up (so the next program sees its runner and display),
# or a joining program is inside the namespace (so the keeper cannot find it
# empty in between and close it).
session_wait_settled() {
  local child="$1" i
  case "$SESSION_SETTLE" in
    wineserver)
      for ((i = 0; i < 600; i++)); do
        prefix_wineserver_pid > /dev/null && return 0
        kill -0 "$child" 2> /dev/null || return 0
        sleep 0.2
      done
      ;;
    joined)
      for ((i = 0; i < 75; i++)); do
        session_token_in_netns && return 0
        kill -0 "$child" 2> /dev/null || return 0
        sleep 0.2
      done
      ;;
  esac
  return 0
}

# Run LAUNCH_CMD in the session and return its exit status.
launch_in_session() {
  local child status=0
  if [[ -n "$SESSION_LOCK_FD" ]]; then
    "${LAUNCH_CMD[@]}" {SESSION_LOCK_FD}>&- &
  else
    "${LAUNCH_CMD[@]}" &
  fi
  child=$!
  # a background job ignores SIGINT; pass on what would end the program
  trap 'kill -TERM "$child" 2> /dev/null || true' INT TERM HUP
  session_wait_settled "$child"
  session_unlock
  while true; do
    status=0
    wait "$child" || status=$?
    kill -0 "$child" 2> /dev/null || break
  done
  trap - INT TERM HUP
  return "$status"
}

# wineboot leaves its wineserver up for a few seconds; let it go, so the
# program started next sets the session up the way it is configured.
wait_wineserver_exit() {
  local i
  for ((i = 0; i < 100; i++)); do
    prefix_wineserver_pid > /dev/null || return 0
    sleep 0.2
  done
  return 0
}

