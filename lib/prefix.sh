# shellcheck shell=bash
# 全局状态跨模块共享（由主程序 source），对整个文件屏蔽未用变量提示
# shellcheck disable=SC2034
# WinRun — prefix init, cached env/associations, drive maps, targets

init_prefix() {
  local status log
  select_init_runner
  if prefix_session_active; then
    die_visible "$(session_message busy_init)"
  fi

  # Creating a prefix takes minutes on first run. Without this the desktop
  # launch looks dead between the runner install and the program window.
  log="$WRAPPER_CACHE_DIR/logs/init.log"
  mkdir -p "$(dirname "$log")"
  notify_progress "WinRun" "$(download_message init "")"

  status=0
  if [[ "$RESOLVED_RUNNER_TYPE" == "proton" ]]; then
    run_proton_command "$RESOLVED_RUNNER_PATH" run wineboot -u > >(tee -a "$log") 2>&1 || status=$?
  else
    run_wine_command "$RESOLVED_RUNNER_PATH" wineboot -u > >(tee -a "$log") 2>&1 || status=$?
  fi

  if [[ $status -ne 0 ]]; then
    notify_error "$(download_message init_failed "")"$'\n'"$log"
    die "failed to initialize prefix: $PREFIX (exit $status)
See $log"
  fi
  wait_wineserver_exit
}

ensure_initialized() {
  if [[ ! -d "$PREFIX/pfx" ]]; then
    init_prefix
  fi
}

apply_cached_env_vars() {
  local encoded="$1" tmp status
  CACHED_ENV=()
  [[ -n "$encoded" ]] || return 0
  tmp="$(mktemp)"
  python3 - "$encoded" > "$tmp" <<'PY'
import shlex
import sys
from urllib.parse import unquote

text = unquote(sys.argv[1])
try:
    parts = shlex.split(text)
except ValueError:
    parts = [line.strip() for line in text.splitlines()]
for part in parts:
    if "=" not in part or part.startswith("="):
        continue
    sys.stdout.write(part)
    sys.stdout.write("\0")
PY
  status=$?
  if [[ $status -eq 0 ]]; then
    mapfile -d '' -t CACHED_ENV < "$tmp"
  fi
  rm -f "$tmp"
}

association_cache_file_for() {
  local target_path="$1" cache_dir key
  cache_dir="$XDG_CACHE_HOME_VALUE/winrun/associations"
  key="$(printf '%s' "$target_path" | sha256sum | cut -d ' ' -f 1)"
  printf '%s/%s.conf\n' "$cache_dir" "$key"
}

should_record_association() {
  local target_path="$1" name
  name="$(basename "$target_path")"
  name="${name%.*}"
  name="${name,,}"
  case "$name" in
    *setup*|*install*|*installer*|*uninstall*|unins*|*update*|*updater*|*patch*|*crash*|*helper*|*redist*|*vcredist*|*vc_redist*|dxsetup)
      return 1
      ;;
  esac
  return 0
}

record_default_association() {
  local target_path="$1" cache_file
  case "${target_path,,}" in
    *.exe|*.lnk) ;;
    *) return 0 ;;
  esac
  should_record_association "$target_path" || return 0
  cache_file="$(association_cache_file_for "$target_path")"
  if [[ ! -e "$cache_file" ]]; then
    record_new_association "$target_path" "$cache_file"
  fi
  # a game Steam starts: the manager starts it through Steam too
  if [[ $STEAM_LAUNCH -eq 1 && "${SteamAppId:-}" =~ ^[1-9][0-9]*$ ]] \
      && ! grep -qx "steam_appid=$SteamAppId" "$cache_file"; then
    sed -i '/^steam_appid=/d' "$cache_file"
    printf 'steam_appid=%s\n' "$SteamAppId" >> "$cache_file"
  fi
}

record_new_association() {
  local target_path="$1" cache_file="$2"
  mkdir -p "$(dirname "$cache_file")"
  cat > "$cache_file" <<EOF
exe=$target_path
prefix=$PREFIX
runner=$RESOLVED_RUNNER_PATH
program_args=
gamescope=$GAMESCOPE
gamescope_fullscreen=$GAMESCOPE_FULLSCREEN
gamescope_res=$GAMESCOPE_RES
gamescope_fps=$GAMESCOPE_FPS
gamescope_fsr=$GAMESCOPE_FSR
gamescope_args=$GAMESCOPE_EXTRA
mangohud=$MANGOHUD
wayland=$WAYLAND
env_vars=
source=auto
EOF
}

apply_cached_association() {
  local target_path="$1" cache_dir key cache_file line name value
  local cache_prefix="" cache_runner="" cache_runner_valid="0" cache_gamescope="0" cache_fullscreen="1"
  local cache_res="" cache_fps="" cache_fsr="0" cache_args="" cache_mangohud="0" cache_wayland="0" cache_env_vars=""
  local cache_program_args=""

  cache_file="$(association_cache_file_for "$target_path")"
  [[ -r "$cache_file" ]] || return 0

  while IFS= read -r line; do
    [[ "$line" == *=* ]] || continue
    name="${line%%=*}"
    value="${line#*=}"
    case "$name" in
      prefix) cache_prefix="$value" ;;
      runner) cache_runner="$value" ;;
      program_args) cache_program_args="$value" ;;
      gamescope) cache_gamescope="$value" ;;
      gamescope_fullscreen) cache_fullscreen="$value" ;;
      gamescope_res) cache_res="$value" ;;
      gamescope_fps) cache_fps="$value" ;;
      gamescope_fsr) cache_fsr="$value" ;;
      gamescope_args) cache_args="$value" ;;
      mangohud) cache_mangohud="$value" ;;
      wayland) cache_wayland="$value" ;;
      env_vars) cache_env_vars="$value" ;;
    esac
  done < "$cache_file"

  [[ -n "$cache_prefix" && -d "$cache_prefix" ]] || return 0
  if [[ -n "$cache_runner" && -x "$cache_runner" ]] && runner_arch_matches_host "$cache_runner"; then
    cache_runner_valid="1"
  fi
  [[ "$cache_gamescope" == "1" ]] || cache_gamescope="0"
  [[ "$cache_fullscreen" == "0" ]] || cache_fullscreen="1"
  [[ "$cache_fsr" == "1" ]] || cache_fsr="0"
  [[ "$cache_mangohud" == "1" ]] || cache_mangohud="0"
  [[ "$cache_wayland" == "1" ]] || cache_wayland="0"

  if [[ $PREFIX_EXPLICIT -eq 0 ]]; then
    PREFIX="$cache_prefix"
  fi
  if [[ $RUNNER_EXPLICIT -eq 0 ]]; then
    if [[ "$cache_runner_valid" == "1" ]]; then
      RUNNER_ARG="$cache_runner"
    elif [[ "${cache_runner,,}" == *proton-ge* || "${cache_runner,,}" == *ge-proton* ]]; then
      RUNNER_ARG="ge"
    elif [[ "${cache_runner,,}" == *dw-proton* || "${cache_runner,,}" == *dwproton* ]]; then
      RUNNER_ARG="dw"
    elif [[ "${cache_runner,,}" == *we-proton* || "${cache_runner,,}" == *weproton* ]]; then
      RUNNER_ARG="we"
    fi
  fi
  if [[ $GAMESCOPE_EXPLICIT -eq 0 ]]; then
    GAMESCOPE="$cache_gamescope"
    GAMESCOPE_FULLSCREEN="$cache_fullscreen"
    GAMESCOPE_RES="$cache_res"
    GAMESCOPE_FPS="$cache_fps"
    GAMESCOPE_FSR="$cache_fsr"
    GAMESCOPE_EXTRA="$cache_args"
  fi
  if [[ $MANGOHUD_EXPLICIT -eq 0 ]]; then
    MANGOHUD="$cache_mangohud"
  fi
  if [[ $WAYLAND_EXPLICIT -eq 0 ]]; then
    WAYLAND="$cache_wayland"
  fi
  apply_cached_env_vars "$cache_env_vars"
  apply_cached_program_args "$cache_program_args"
}

open_winecfg() {
  select_runner
  GAMESCOPE=0
  WAYLAND=0
  session_prepare
  if [[ "$RESOLVED_RUNNER_TYPE" == "proton" ]]; then
    build_launch_command proton "$RESOLVED_RUNNER_PATH" "$PROTON_VERB" winecfg
  else
    build_launch_command wine "$RESOLVED_RUNNER_PATH" winecfg
  fi
  launch_in_session
}

# Windows programs outside the prefix start from a drive letter for their
# folder. Each folder keeps its own letter, recorded in
# .winrun-drives, so programs of different folders can run at
# the same time without a drive being pointed elsewhere under one of them.
# s: and t: stay out: Proton's "run" deletes them unless a game asks for them.
DRIVE_LETTERS="d e f g h i j k l m n o p q r u v w x y"

drive_map_file() {
  printf '%s/.winrun-drives\n' "$PREFIX"
}

drive_map_has() {
  awk -F '\t' -v letter="$1" '$1 == letter { found = 1 } END { exit !found }' "$(drive_map_file)" 2> /dev/null
}

# Record letter → folder; the most recently used comes last.
drive_map_set() {
  local map tmp
  map="$(drive_map_file)"
  tmp="$map.tmp.$$"
  {
    if [[ -r "$map" ]]; then
      awk -F '\t' -v letter="$1" '$1 != letter' "$map"
    fi
    printf '%s\t%s\n' "$1" "$2"
  } > "$tmp"
  mv "$tmp" "$map"
}

drive_map_remove() {
  local map tmp
  map="$(drive_map_file)"
  [[ -r "$map" ]] || return 0
  tmp="$map.tmp.$$"
  awk -F '\t' -v letter="$1" '$1 != letter' "$map" > "$tmp"
  mv "$tmp" "$map"
}

# Drop our letters for folders inside root. Wine names a path by the deepest
# drive it is on, so such a letter would take a program out of root's drive:
# a launcher in it would no longer find the game it starts in the folder above.
drive_map_drop_inside() {
  local root="$1" letter folder _
  while IFS=$'\t' read -r letter folder _; do
    [[ " $DRIVE_LETTERS " == *" $letter "* && "$folder" == "$root/"* ]] || continue
    if [[ "$(realpath -m "$PREFIX/pfx/dosdevices/$letter:")" == "$folder" ]]; then
      rm -f "$PREFIX/pfx/dosdevices/$letter:"
    fi
    drive_map_remove "$letter"
  done < <(cat "$(drive_map_file)" 2> /dev/null || true)
}

# The install folder of the Steam game a program is part of, if any: it is
# one drive for the game however the game is started.
steam_install_folder() {
  local path="$1" rest
  [[ "$path" == */steamapps/common/*/* ]] || return 1
  rest="${path#*/steamapps/common/}"
  printf '%s/steamapps/common/%s\n' "${path%%/steamapps/common/*}" "${rest%%/*}"
}

# The single letter used before every folder got its own.
migrate_drive_marker() {
  local marker="$PREFIX/.winrun-drive" letter link
  [[ -e "$marker" ]] || return 0
  letter="$(sed -n '1p' "$marker" 2> /dev/null || true)"
  link="$PREFIX/pfx/dosdevices/$letter:"
  if [[ " $DRIVE_LETTERS " == *" $letter "* && -L "$link" ]]; then
    drive_map_set "$letter" "$(realpath -m "$link")"
  fi
  rm -f "$marker"
}

# Print the drive letter of a folder, giving it one if needed: one that already
# points there (whoever made it), a free one, then one of ours whose folder is
# gone, and while no program runs in the prefix, the least recently used.
drive_letter_for() {
  local dir="$1" dosdevices letter link folder victim=""
  dosdevices="$PREFIX/pfx/dosdevices"
  for letter in $DRIVE_LETTERS; do
    link="$dosdevices/$letter:"
    if [[ -L "$link" && "$(realpath -m "$link")" == "$dir" ]]; then
      if drive_map_has "$letter"; then
        drive_map_set "$letter" "$dir"
      fi
      printf '%s\n' "$letter"
      return 0
    fi
  done
  for letter in $DRIVE_LETTERS; do
    link="$dosdevices/$letter:"
    if [[ ! -e "$link" && ! -L "$link" ]]; then
      ln -s "$dir" "$link"
      drive_map_set "$letter" "$dir"
      printf '%s\n' "$letter"
      return 0
    fi
  done
  while IFS=$'\t' read -r letter folder; do
    if [[ " $DRIVE_LETTERS " == *" $letter "* && ! -d "$folder" ]]; then
      victim="$letter"
      break
    fi
  done < <(cat "$(drive_map_file)" 2> /dev/null || true)
  if [[ -z "$victim" && $SESSION_ACTIVE -eq 0 ]]; then
    victim="$(awk -F '\t' 'NR == 1 { print $1 }' "$(drive_map_file)" 2> /dev/null || true)"
  fi
  [[ -n "$victim" ]] || return 1
  rm -f "$dosdevices/$victim:"
  ln -s "$dir" "$dosdevices/$victim:"
  drive_map_set "$victim" "$dir"
  printf '%s\n' "$victim"
}

# A program outside the prefix gets a drive letter for its folder, or for
# root, a folder above it: a game in Binaries/Win64 reaches its data by ..\..
prepare_mapped_drive_target() {
  local target_path="$1" root="${2:-}" source_dir base letter
  target_path="$(realpath -m "$target_path")"
  source_dir="$(dirname "$target_path")"
  base="$(basename "$target_path")"
  proton_exe="$target_path"

  case "$target_path" in
    "$PREFIX/pfx/drive_c"/*)
      workdir="$source_dir"
      exe="./$base"
      return 0
      ;;
  esac

  mkdir -p "$PREFIX/pfx/dosdevices"
  migrate_drive_marker
  if [[ -n "$root" ]]; then
    root="$(realpath -m "$root")"
    if [[ "$target_path" == "$root/"* ]]; then
      source_dir="$root"
      base="${target_path#"$root/"}"
      base="${base//\//\\}"
      drive_map_drop_inside "$root"
    fi
  fi
  letter="$(drive_letter_for "$source_dir")" || die "no free Wine drive letter found for: $source_dir"
  workdir="$PREFIX/pfx/drive_c"
  exe="${letter}:\\$base"
}

# Steam's %command% for a game it runs with Proton: its launch helpers and
# runtime, the proton script with a verb, then the game and its arguments.
# With "winrun %command%" as a game's launch option, the game
# alone runs, the way any program does here: in the wrapper's prefix and its
# session, so it shares them with what else runs there, an accelerator say.
take_steam_command() {
  local args=("$TARGET" "${TARGET_ARGS[@]}") i
  for ((i = 0; i + 2 < ${#args[@]}; i++)); do
    [[ "$(basename -- "${args[i]}")" == "proton" ]] || continue
    case "${args[i + 1]}" in
      waitforexitandrun|run|runinprefix) ;;
      *) continue ;;
    esac
    TARGET="${args[i + 2]}"
    TARGET_ARGS=("${args[@]:i + 3}")
    STEAM_LAUNCH=1
    # Steam hands its launch option the libraries of its own runtime; the
    # programs the wrapper runs on the host want the system's
    [[ -v SYSTEM_LD_LIBRARY_PATH ]] && export LD_LIBRARY_PATH="$SYSTEM_LD_LIBRARY_PATH"
    [[ -v SYSTEM_PATH ]] && export PATH="$SYSTEM_PATH"
    return 0
  done
  return 1
}

# Whether the target is a Linux program: a command on PATH or an executable
# file that is not a Windows one. Sets TARGET to its path.
linux_target() {
  local path
  if [[ "$TARGET" == */* || "$TARGET" == "~"* ]]; then
    path="$(expand_path "$TARGET")"
  elif ! path="$(type -P -- "$TARGET")"; then
    path="$PWD/$TARGET"
  fi
  [[ -f "$path" && -x "$path" ]] || return 1
  [[ "$(head -c 2 -- "$path" 2> /dev/null)" != "MZ" ]] || return 1
  TARGET="$path"
}

# A Linux program runs in the prefix's network namespace when the prefix has
# one, so that an accelerator there carries it too; Steam's %command% for a
# Linux game is one. pasta makes the user root in the namespace, which
# programs like Steam refuse, so the program gets a user namespace of its own
# that maps the user back. A Windows program it starts through the wrapper
# then cannot enter the session itself and is started by the session's keeper
# (delegate_to_keeper).
run_linux_target() {
  local dir here keeper
  dir="$(session_dir)"
  if here="$(session_here)"; then
    [[ "$here" == "$dir" ]] || die_visible "$(session_message other_session "$PREFIX")"
    exec "$TARGET" "${TARGET_ARGS[@]}"
  fi
  if ! prefix_netns_enabled; then
    printf 'Session: %s has no separate network, the program runs directly\n' "$PREFIX" >&2
    exec "$TARGET" "${TARGET_ARGS[@]}"
  fi
  command -v unshare > /dev/null 2>&1 || die_visible "$(session_message no_nsenter)"
  session_lock
  if ! keeper="$(session_keeper_pid "$dir")"; then
    session_start "$dir" >&2
    keeper="$SESSION_KEEPER_PID"
  fi
  printf 'Session: network namespace of keeper %s\n' "$keeper" >&2
  # the session lock is held until the program is inside the namespace
  exec nsenter -t "$keeper" -U -n --preserve-credentials -- \
    unshare -U --map-user="$(id -u)" --map-group="$(id -g)" -- \
    bash -c 'flock -u "$1"; eval "exec $1>&-"; shift; exec "$@"' bash "$SESSION_LOCK_FD" \
    "$TARGET" "${TARGET_ARGS[@]}"
}

# Run this wrapper again in the session's user namespace, started by the
# session's keeper (launch_serve there) on our standard input, output and
# error, and exit with its status. Ending this process stops it.
delegate_to_keeper() {
  local socket="$1/launch" script
  [[ -S "$socket" ]] || die_visible "$(session_message no_launch)"
  printf 'Session: started by the keeper of the session this runs in\n' >&2
  script="$(cat <<'PY'
import array
import json
import os
import signal
import socket
import sys

signal.signal(signal.SIGINT, signal.SIG_DFL)
conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
conn.connect(sys.argv[1])
data = json.dumps({"argv": sys.argv[2:], "env": dict(os.environ), "cwd": os.getcwd()}).encode()
conn.sendmsg([len(data).to_bytes(4, "big")],
             [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [0, 1, 2]))])
conn.sendall(data)
reply = b""
while len(reply) < 4:
    chunk = conn.recv(4 - len(reply))
    if not chunk:
        sys.exit(1)
    reply += chunk
sys.exit(int.from_bytes(reply, "big", signed=True) & 0xff)
PY
)"
  exec python3 -c "$script" "$socket" "$SELF_PATH" "${ORIGINAL_ARGS[@]}"
}

run_target() {
  local workdir exe proton_exe status steam_dir here
  case "${TARGET,,}" in
    *.exe|*.lnk|*.msi|*.bat|*.cmd|*.com) ;;
    *)
      steam_dir="$PWD"
      if ! take_steam_command && linux_target; then
        run_linux_target
      fi
      ;;
  esac
  # a Linux program of the session started this one
  if here="$(session_here)"; then
    [[ "$here" == "$(session_dir)" ]] || die_visible "$(session_message other_session "$PREFIX")"
    session_userns_here "$here" || delegate_to_keeper "$here"
  fi
  TARGET="$(expand_path "$TARGET")"
  [[ -e "$TARGET" ]] || die_visible "target not found: $TARGET"
  apply_cached_association "$TARGET"
  PREFIX="$(expand_path "$PREFIX")"
  select_runner
  # a program started meanwhile waits until the prefix exists
  session_lock
  ensure_initialized
  record_default_association "$TARGET"
  setup_run_logging
  session_prepare

  case "${TARGET,,}" in
    *.lnk)
      if [[ "$RESOLVED_RUNNER_TYPE" == "proton" ]]; then
        build_launch_command proton "$RESOLVED_RUNNER_PATH" "$PROTON_VERB" start /unix "$TARGET" "${TARGET_ARGS[@]}"
      else
        build_launch_command wine "$RESOLVED_RUNNER_PATH" start /wait /unix "$TARGET" "${TARGET_ARGS[@]}"
      fi
      ;;
    *)
      # a Steam game sees its install folder as one drive, and when Steam
      # starts it, starts in the folder Steam starts it in
      if [[ $STEAM_LAUNCH -eq 1 ]]; then
        prepare_mapped_drive_target "$TARGET" "${STEAM_COMPAT_INSTALL_PATH:-$(steam_install_folder "$TARGET" || true)}"
        workdir="$steam_dir"
      else
        prepare_mapped_drive_target "$TARGET" "$(steam_install_folder "$TARGET" || true)"
      fi
      # shellcheck disable=SC2164  # sourced with set -e: cd failure aborts the script
      cd "$workdir"
      if [[ "$RESOLVED_RUNNER_TYPE" == "proton" ]]; then
        build_launch_command proton "$RESOLVED_RUNNER_PATH" "$PROTON_VERB" "$proton_exe" "${TARGET_ARGS[@]}"
      else
        build_launch_command wine "$RESOLVED_RUNNER_PATH" "$exe" "${TARGET_ARGS[@]}"
      fi
      ;;
  esac

  status=0
  launch_in_session || status=$?
  printf -- '--- exit: %s ---\n' "$status"
  exit "$status"
}

# Where the runner would run: the runtime's path, or why it runs directly.
