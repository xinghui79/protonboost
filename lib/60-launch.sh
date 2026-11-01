# shellcheck shell=bash
# 全局状态跨模块共享（由主程序 source），对整个文件屏蔽未用变量提示
# shellcheck disable=SC2034
# WinRun — Steam runtime, launch command, Gamescope/MangoHud/overlay

# ------------------------------------------------------------ Steam runtime
# Proton is built for the Steam Linux Runtime container its toolmanifest.vdf
# names. Run directly on the host its bundled libraries miss dependencies, e.g.
# the GStreamer plugins Wine decodes WMA, WMV and H.264 with.

# Steam directory, umu directory, download directory and archive of a runtime.
runtime_info() {
  case "$1" in
    4183110) printf '%s\n' SteamLinuxRuntime_4 steamrt4 \
      "https://repo.steampowered.com/steamrt4/images/latest-public-stable/" SteamLinuxRuntime_4.tar.xz ;;
    1628350) printf '%s\n' SteamLinuxRuntime_sniper steamrt3 \
      "https://repo.steampowered.com/steamrt-images-sniper/snapshots/latest-container-runtime-public-beta/" \
      SteamLinuxRuntime_sniper.tar.xz ;;
    *) return 1 ;;
  esac
}

required_runtime_appid() {
  local manifest appid
  manifest="$(dirname "$1")/toolmanifest.vdf"
  [[ -r "$manifest" ]] || return 1
  appid="$(sed -n 's/.*"require_tool_appid"[[:space:]]*"\([0-9][0-9]*\)".*/\1/p' "$manifest" | head -n 1)"
  [[ -n "$appid" ]] || return 1
  printf '%s\n' "$appid"
}

# WE-Proton before release 10 was linked against host libraries the runtime
# does not have; it only works run directly.
runner_is_old_weproton() {
  local label oldest="we-proton-11.0-14-10"
  label="$(awk '{print $NF}' "$(dirname "$1")/version" 2>/dev/null || true)"
  [[ "$label" == we-proton-* && "$label" != "$oldest" ]] || return 1
  [[ "$(printf '%s\n' "$label" "$oldest" | sort -V | head -n 1)" == "$label" ]]
}

steam_library_roots() {
  printf '%s\n' "$HOME/.local/share/Steam" "$HOME/.steam/root" "$HOME/.steam/steam" \
    "$HOME/.var/app/com.valvesoftware.Steam/data/Steam"
  read_steam_libraries
}

# An installed copy of the runtime: ours, umu's or Steam's.
find_runtime() {
  local info dir lib
  mapfile -t info < <(runtime_info "$1") || return 1
  [[ ${#info[@]} -eq 4 ]] || return 1
  for dir in "$RUNTIME_DIR/${info[1]}" "$XDG_DATA_HOME_VALUE/umu/${info[1]}"; do
    if [[ -f "$dir/_v2-entry-point" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done
  while IFS= read -r lib; do
    dir="$lib/steamapps/common/${info[0]}"
    if [[ -f "$dir/_v2-entry-point" ]]; then
      printf '%s\n' "$dir"
      return 0
    fi
  done < <(steam_library_roots)
  return 1
}

fetch_text() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --connect-timeout 30 "$1"
  else
    wget -qO- --timeout=30 "$1"
  fi
}

# Download the runtime from Valve into $RUNTIME_DIR, checked against SHA256SUMS.
download_runtime() {
  local info sums expected dest staging old_product title="WinRun" status=0
  mapfile -t info < <(runtime_info "$1")
  mkdir -p "$INSTALL_DOWNLOAD_DIR" "$RUNTIME_DIR"
  if ! sums="$(fetch_text "${info[2]}SHA256SUMS")"; then
    install_error "cannot fetch ${info[2]}SHA256SUMS"
    return 1
  fi
  expected="$(awk -v f="${info[3]}" '{n = $NF; sub(/^\*/, "", n)} n == f {print $1; exit}' <<< "$sums")"
  if [[ -z "$expected" ]]; then
    install_error "no checksum for ${info[3]} in ${info[2]}SHA256SUMS"
    return 1
  fi

  dest="$INSTALL_DOWNLOAD_DIR/${info[3]}"
  old_product="${DOWNLOAD_NOTIFY_PRODUCT:-}"
  DOWNLOAD_NOTIFY_PRODUCT="Steam Linux Runtime"
  fetch_file "${info[2]}${info[3]}" "$dest" || status=$?
  DOWNLOAD_NOTIFY_PRODUCT="$old_product"
  [[ $status -eq 0 ]] || return 1
  if [[ "$(sha256sum "$dest" | cut -d' ' -f1)" != "$expected" ]]; then
    rm -f "$dest"
    install_error "checksum verification failed: $dest
The download is incomplete or corrupted. It has been discarded; run again to re-download."
    return 1
  fi

  notify_progress "$title" "$(download_message extracting "Steam Linux Runtime")"
  if ! staging="$(mktemp -d "$RUNTIME_DIR/.extract-XXXXXX")"; then
    install_error "failed to create a work directory in: $RUNTIME_DIR"
    return 1
  fi
  if ! tar -xJf "$dest" -C "$staging" || [[ ! -f "$staging/${info[0]}/_v2-entry-point" ]]; then
    rm -rf "$staging"
    install_error "failed to extract: $dest"
    return 1
  fi
  rm -rf "${RUNTIME_DIR:?}/${info[1]}"
  mv "$staging/${info[0]}" "$RUNTIME_DIR/${info[1]}"
  rm -rf "$staging" "$dest"
  notify_download "$title" "$(download_message done "Steam Linux Runtime")"
}

# Set RUNTIME_PREFIX to the command that runs this Proton inside its runtime,
# downloading the runtime first if needed. It stays empty, and Proton runs
# directly, when the runtime is turned off, the Proton asks for none we know,
# or the runtime cannot be had.
prepare_runtime() {
  local runner="$1" verb="$2" appid runtime log status=0
  RUNTIME_PREFIX=()
  [[ "$RUNTIME_ENABLED" != 0 ]] || return 0
  appid="$(required_runtime_appid "$runner")" || return 0
  runtime_info "$appid" >/dev/null || return 0
  if runner_is_old_weproton "$runner"; then
    return 0
  fi
  if ! runtime="$(find_runtime "$appid")"; then
    log="$WRAPPER_CACHE_DIR/logs/install-runtime.log"
    mkdir -p "$(dirname "$log")"
    : > "$log"
    INSTALL_ERROR=""
    download_runtime "$appid" > >(tee -a "$log" >&2) 2>&1 || status=$?
    if [[ $status -ne 0 ]] || ! runtime="$(find_runtime "$appid")"; then
      notify_error "$(download_message runtime_fallback "")"$'\n'"${INSTALL_ERROR:+$INSTALL_ERROR$'\n'}$log"
      printf 'winrun: %s\n' "$(download_message runtime_fallback "")" >&2
      return 0
    fi
  fi
  RUNTIME_PREFIX=("$runtime/_v2-entry-point" "--verb=$verb" "--")
}

validate_resolution() {
  [[ "$1" =~ ^[0-9]+x[0-9]+$ ]] || die "invalid resolution: $1"
}

validate_number() {
  [[ "$1" =~ ^[0-9]+$ ]] || die "invalid number: $1"
}

prepare_mangohud_env() {
  MANGOHUD_ENV=()
  [[ $MANGOHUD -eq 1 ]] || return 0
  command -v mangohud >/dev/null 2>&1 || die_visible "mangohud is not installed"
  MANGOHUD_ENV=("MANGOHUD=1")
}

# A Steam game in a session's namespace runs as root there, while the Steam
# client runs as the user: Steam's overlay in the game names what it shares
# with the client after getuid() (/dev/shm/u<uid>-ValveIPCSharedObj-Steam and
# the like), so the two never meet. A small library preloaded after the
# overlay gives the overlay, and only it, the user's uid; Wine and the rest of
# the game keep root, the wineserver and the accelerator's TUN adapter with it.
# It is built with the system's C compiler the first time it is needed.
OVERLAY_UID_ENV=()

# The uid the current user has outside any user namespace.
host_uid() {
  local uid inside outside count
  uid="$(id -u)"
  while read -r inside outside count; do
    if (( uid >= inside && uid < inside + count )); then
      printf '%s\n' "$(( outside + uid - inside ))"
      return 0
    fi
  done < /proc/self/uid_map
  printf '%s\n' "$uid"
}

build_overlay_uid_library() {
  local out="$1" bits="$2" tmp
  [[ -e "$out" ]] && return 0
  [[ -e "$out.failed" ]] && return 1
  mkdir -p "$(dirname "$out")"
  tmp="$(mktemp "$out.XXXXXX")"
  if cc "-m$bits" -shared -fPIC -O2 -fno-stack-protector -U_FORTIFY_SOURCE -x c - -o "$tmp" \
      > /dev/null 2>&1 <<'C'
/* Preloaded into a Steam game run in a session's network namespace, where the
 * user is root: Steam's overlay names what it shares with the Steam client
 * after getuid(), so it answers the overlay with the user the client runs as.
 * Every other caller, Wine among them, gets the real uid. */
#define _GNU_SOURCE
#include <link.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/syscall.h>
#include <unistd.h>

static uintptr_t overlay_start, overlay_end;

static int find_overlay(struct dl_phdr_info *info, size_t size, void *data)
{
    const char *name = info->dlpi_name;
    uintptr_t start = UINTPTR_MAX, end = 0;
    int i;

    (void)size;
    (void)data;
    if (!name || !strstr(name, "/gameoverlayrenderer.so"))
        return 0;
    for (i = 0; i < info->dlpi_phnum; i++) {
        const ElfW(Phdr) *phdr = &info->dlpi_phdr[i];
        if (phdr->p_type != PT_LOAD)
            continue;
        if (info->dlpi_addr + phdr->p_vaddr < start)
            start = info->dlpi_addr + phdr->p_vaddr;
        if (info->dlpi_addr + phdr->p_vaddr + phdr->p_memsz > end)
            end = info->dlpi_addr + phdr->p_vaddr + phdr->p_memsz;
    }
    if (end) {
        overlay_start = start;
        overlay_end = end;
    }
    return 1;
}

static long overlay_uid(void)
{
    const char *value = getenv("WINRUN_OVERLAY_UID");
    long uid = 0;

    if (!value || !*value)
        return -1;
    for (; *value; value++) {
        if (*value < '0' || *value > '9')
            return -1;
        uid = uid * 10 + (*value - '0');
    }
    return uid;
}

uid_t getuid(void)
{
    uintptr_t caller = (uintptr_t)__builtin_return_address(0);
    long uid;

    if (!overlay_end)
        dl_iterate_phdr(find_overlay, NULL);
    if (caller >= overlay_start && caller < overlay_end && (uid = overlay_uid()) >= 0)
        return (uid_t)uid;
    return (uid_t)syscall(SYS_getuid);
}
C
  then
    mv -f "$tmp" "$out"
  else
    rm -f "$tmp"
    touch "$out.failed"
    return 1
  fi
}

prepare_overlay_uid() {
  local dir key lib bits libs=()
  OVERLAY_UID_ENV=()
  [[ -n "$SESSION_NETNS" && "${LD_PRELOAD:-}" == *gameoverlayrenderer.so* ]] || return 0
  if ! command -v cc > /dev/null 2>&1; then
    printf 'Session: no C compiler (cc), Steam overlay stays off in the separate network\n'
    return 0
  fi
  key="$(declare -f build_overlay_uid_library | sha256sum | cut -c1-12)"
  dir="$WRAPPER_CACHE_DIR/overlay-uid/$key"
  # the 32-bit one only where a 32-bit C library is installed; the loader
  # skips the one of the other word size
  for bits in 64 32; do
    lib="$dir/overlay-uid-$bits.so"
    if build_overlay_uid_library "$lib" "$bits"; then
      libs+=("$lib")
    fi
  done
  if (( ${#libs[@]} == 0 )); then
    printf 'Session: building the Steam overlay helper failed, the overlay stays off in the separate network\n'
    return 0
  fi
  OVERLAY_UID_ENV=(
    "LD_PRELOAD=$LD_PRELOAD$(printf ':%s' "${libs[@]}")"
    "WINRUN_OVERLAY_UID=$(host_uid)"
  )
}

# Split a shell-style argument string into PARSED_ARGS, one element per
# argument, without eval. A malformed quote is reported as an error.
parse_argument_string() {
  local value="$1" kind="$2" tmp err status
  PARSED_ARGS=()
  [[ -n "$value" ]] || return 0
  tmp="$(mktemp)"
  err="$(mktemp)"
  status=0
  python3 - "$value" "$kind" > "$tmp" 2> "$err" <<'PY' || status=$?
import shlex
import sys

try:
    args = shlex.split(sys.argv[1])
except ValueError as exc:
    raise SystemExit(f"invalid {sys.argv[2]}: {exc}")

for arg in args:
    sys.stdout.write(arg)
    sys.stdout.write("\0")
PY
  if [[ $status -ne 0 ]]; then
    local message
    message="$(<"$err")"
    rm -f "$tmp" "$err"
    die_visible "${message:-invalid ${kind}: $value}"
  fi
  mapfile -d '' -t PARSED_ARGS < "$tmp"
  rm -f "$tmp" "$err"
}

append_gamescope_extra_args() {
  local extra="$1"
  [[ -n "$extra" ]] || return 0
  parse_argument_string "$extra" "Gamescope arguments"
  if [[ ${#PARSED_ARGS[@]} -gt 0 ]]; then
    GAMESCOPE_ARGS+=("${PARSED_ARGS[@]}")
  fi
}

apply_cached_program_args() {
  local extra="$1"
  [[ -n "$extra" ]] || return 0
  parse_argument_string "$extra" "program arguments"
  if [[ ${#PARSED_ARGS[@]} -gt 0 ]]; then
    TARGET_ARGS=("${PARSED_ARGS[@]}" "${TARGET_ARGS[@]}")
  fi
}

build_gamescope_args() {
  GAMESCOPE_ARGS=()
  [[ $GAMESCOPE -eq 1 ]] || return 0
  command -v gamescope >/dev/null 2>&1 || die_visible "gamescope is not installed"

  if [[ $GAMESCOPE_FULLSCREEN -eq 1 ]]; then
    GAMESCOPE_ARGS+=("-f")
  fi
  if [[ -n "$GAMESCOPE_RES" ]]; then
    validate_resolution "$GAMESCOPE_RES"
    GAMESCOPE_ARGS+=("-w" "${GAMESCOPE_RES%x*}" "-h" "${GAMESCOPE_RES#*x}")
  fi
  if [[ -n "$GAMESCOPE_FPS" ]]; then
    validate_number "$GAMESCOPE_FPS"
    GAMESCOPE_ARGS+=("-r" "$GAMESCOPE_FPS")
  fi
  if [[ $GAMESCOPE_FSR -eq 1 ]]; then
    GAMESCOPE_ARGS+=("-F" "fsr")
  fi
  append_gamescope_extra_args "$GAMESCOPE_EXTRA"
}

# The command that runs a Windows program, in LAUNCH_CMD:
#   [gamescope ... -- wrapper --in-gamescope --] [nsenter ... --] env ... [runtime --] runner args
# Gamescope stays outside the session's network namespace: inside it the real
# root is unmapped, /tmp/.X11-unix looks owned by nobody and gamescope refuses
# to start its Xwayland. The program still reaches that Xwayland through the
# socket file; the abstract socket is per network namespace.
LAUNCH_CMD=()
JOIN_PREFIX=()
SESSION_ENV=()

build_launch_command() {
  local type="$1" runner="$2" env_args
  shift 2
  validate_runner_arch "$runner"
  prepare_mangohud_env
  LAUNCH_CMD=()
  if [[ $GAMESCOPE -eq 1 ]]; then
    build_gamescope_args
    LAUNCH_CMD+=(gamescope "${GAMESCOPE_ARGS[@]}" -- "$SELF_PATH" --in-gamescope --)
  fi
  LAUNCH_CMD+=("${JOIN_PREFIX[@]}")
  env_args=("${MANGOHUD_ENV[@]}" "${DEBUG_ENV[@]}" "${CACHED_ENV[@]}" "${RUN_ENV[@]}")
  # Wine's new WoW64 mode runs 32-bit programs through the 64-bit host
  # libraries: no 32-bit system libraries are needed, and they get the fixes
  # WE-Proton builds for 64 bits only, e.g. the builtin wintun accelerator
  # engines (32-bit) need. PROTON_USE_WOW64=0, set outside or in an exe's
  # environment variables, turns it off.
  if [[ "$type" == "proton" && -z "${PROTON_USE_WOW64:-}" ]] \
      && ! printf '%s\n' "${CACHED_ENV[@]}" | grep -q '^PROTON_USE_WOW64='; then
    env_args+=("PROTON_USE_WOW64=1")
  fi
  if [[ $WAYLAND -eq 1 && $GAMESCOPE -eq 0 ]]; then
    # Proton sets WINE_GRAPHICS_DRIVER from PROTON_ENABLE_WAYLAND
    if [[ "$type" == "proton" ]]; then
      env_args+=("PROTON_ENABLE_WAYLAND=1")
    else
      env_args+=("WINE_GRAPHICS_DRIVER=wayland")
    fi
  fi
  env_args+=("${SESSION_ENV[@]}")
  prepare_overlay_uid
  env_args+=("${OVERLAY_UID_ENV[@]}")
  if [[ "$type" == "proton" ]]; then
    prepare_runtime "$runner" "${1:-run}"
    mkdir -p "$PREFIX"
    # Proton looks up a game's fixes by UMU_ID before SteamAppId; a Steam
    # game is left to be found by its app ID, as when Steam runs it
    umu_env=()
    if [[ $STEAM_LAUNCH -eq 0 ]]; then
      umu_env=(UMU_ID="${UMU_ID:-winrun}" UMU_USE_STEAM="${UMU_USE_STEAM:-0}")
    fi
    LAUNCH_CMD+=(env "${env_args[@]}"
      STEAM_COMPAT_DATA_PATH="$PREFIX"
      STEAM_COMPAT_CLIENT_INSTALL_PATH="$(steam_root_dir)"
      SteamAppId="${SteamAppId:-0}"
      SteamGameId="${SteamGameId:-0}"
      "${umu_env[@]}"
      "${RUNTIME_PREFIX[@]}" "$runner" "$@")
  else
    mkdir -p "$PREFIX/pfx"
    LAUNCH_CMD+=(env "${env_args[@]}" WINEPREFIX="$PREFIX/pfx" "$runner" "$@")
  fi
}

# Outside any session and without Gamescope, e.g. while creating the prefix.
run_proton_command() {
  local GAMESCOPE=0 WAYLAND=0 JOIN_PREFIX=() SESSION_ENV=()
  build_launch_command proton "$@"
  "${LAUNCH_CMD[@]}"
}

run_wine_command() {
  local GAMESCOPE=0 WAYLAND=0 JOIN_PREFIX=() SESSION_ENV=()
  build_launch_command wine "$@"
  "${LAUNCH_CMD[@]}"
}

