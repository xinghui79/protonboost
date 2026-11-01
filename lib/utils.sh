# shellcheck shell=bash
# 全局状态跨模块共享（由主程序 source），对整个文件屏蔽未用变量提示
# shellcheck disable=SC2034
# WinRun — errors, paths, runner discovery and selection

die() {
  printf 'winrun: %s\n' "$*" >&2
  exit 1
}

die_runner_not_found() {
  local runner="$1"
  if [[ "$(ui_lang)" == "zh" ]]; then
    die "未找到或不支持的运行器: $runner
使用 --list-runner 查看可用运行器，或使用 --runner ge/dw/we。"
  else
    die "runner not found or unsupported: $runner
Use --list-runner to see available runners, or use --runner ge/dw/we."
  fi
}

expand_path() {
  local path="$1"
  case "$path" in
    "~") printf '%s\n' "$HOME" ;;
    "~/"*) printf '%s\n' "$HOME/${path#~/}" ;;
    *) realpath -m "$path" ;;
  esac
}

xdg_download_dir() {
  local value line config
  if command -v xdg-user-dir >/dev/null 2>&1; then
    value="$(xdg-user-dir DOWNLOAD 2>/dev/null || true)"
    if [[ -n "$value" ]]; then
      expand_path "$value"
      return 0
    fi
  fi

  config="${XDG_CONFIG_HOME:-$HOME/.config}/user-dirs.dirs"
  if [[ -r "$config" ]]; then
    while IFS= read -r line; do
      if [[ "$line" =~ ^XDG_DOWNLOAD_DIR=\"(.*)\"$ ]]; then
        value="${BASH_REMATCH[1]}"
        value="${value//\$HOME/$HOME}"
        expand_path "$value"
        return 0
      fi
    done < "$config"
  fi

  printf '%s\n' "$HOME/Downloads"
}

steam_root_dir() {
  if [[ -d "$STEAM_ROOT" ]]; then
    expand_path "$STEAM_ROOT"
  elif [[ -d "$HOME/.local/share/Steam" ]]; then
    printf '%s\n' "$HOME/.local/share/Steam"
  else
    expand_path "$STEAM_ROOT"
  fi
}

default_install_dir() {
  case "$INSTALL_TO" in
    default|steam)
      printf '%s\n' "$STEAM_RUNNER_DIR"
      ;;
    local)
      printf '%s\n' "$LOCAL_RUNNER_DIR"
      ;;
    lutris)
      printf '%s\n' "$HOME/.local/share/lutris/runners/wine"
      ;;
    *)
      die "unknown install target: $INSTALL_TO"
      ;;
  esac
}

runner_name_from_path() {
  local type="$1" path="$2" root
  if [[ "$type" == "proton" ]]; then
    basename "$(dirname "$path")"
    return 0
  fi

  root="$(dirname "$path")"
  if [[ "$(basename "$root")" == "bin" ]]; then
    root="$(dirname "$root")"
  fi
  if [[ "$(basename "$root")" == "files" ]]; then
    root="$(dirname "$root")"
  fi
  basename "$root"
}

wine_root_has_proton() {
  local path="$1" root
  root="$(dirname "$path")"
  if [[ "$(basename "$root")" == "bin" ]]; then
    root="$(dirname "$root")"
  fi
  if [[ "$(basename "$root")" == "files" ]]; then
    root="$(dirname "$root")"
  fi
  [[ -x "$root/proton" ]]
}

host_runner_arch() {
  case "$(uname -m)" in
    x86_64|amd64) printf 'x86_64\n' ;;
    aarch64|arm64) printf 'aarch64\n' ;;
    i386|i486|i586|i686) printf 'x86\n' ;;
    *) uname -m ;;
  esac
}

runner_binary_for_path() {
  local path="$1" root
  if [[ "$(basename "$path")" == "proton" ]]; then
    root="$(dirname "$path")"
    for path in "$root/files/bin/wine" "$root/files/bin/wine64" "$root/bin/wine" "$root/bin/wine64"; do
      [[ -f "$path" ]] && { printf '%s\n' "$path"; return 0; }
    done
    return 1
  fi
  [[ -f "$path" ]] && printf '%s\n' "$path"
}

runner_file_arch() {
  local binary info
  binary="$(runner_binary_for_path "$1" || true)"
  [[ -n "$binary" ]] || return 0
  info="$(env -u LD_PRELOAD file -L -b "$binary" 2>/dev/null || true)"
  case "$info" in
    *'ARM aarch64'*|*'ARM64'*) printf 'aarch64\n' ;;
    *'x86-64'*|*'x86_64'*|*'AMD x86-64'*) printf 'x86_64\n' ;;
    *'Intel 80386'*|*'80386'*) printf 'x86\n' ;;
  esac
}

runner_arch_matches_host() {
  local path="$1" runner_arch host_arch
  runner_arch="$(runner_file_arch "$path")"
  [[ -n "$runner_arch" ]] || return 0
  host_arch="$(host_runner_arch)"
  [[ "$runner_arch" == "$host_arch" || ( "$host_arch" == "x86_64" && "$runner_arch" == "x86" ) ]]
}

validate_runner_arch() {
  local path="$1" runner_arch host_arch binary
  runner_arch="$(runner_file_arch "$path")"
  [[ -n "$runner_arch" ]] || return 0
  host_arch="$(host_runner_arch)"
  if [[ "$runner_arch" == "$host_arch" || ( "$host_arch" == "x86_64" && "$runner_arch" == "x86" ) ]]; then
    return 0
  fi
  binary="$(runner_binary_for_path "$path" || printf '%s' "$path")"
  die_visible "runner architecture mismatch: $path
Host architecture: $host_arch
Runner binary: $binary ($runner_arch)
Remove this runner and reinstall the matching build."
}

reset_runners() {
  RUNNER_TYPES=()
  RUNNER_SOURCES=()
  RUNNER_NAMES=()
  RUNNER_PATHS=()
  RUNNER_SEEN=()
}

add_runner() {
  local type="$1" source="$2" path="$3" name real
  [[ -x "$path" ]] || return 0
  runner_arch_matches_host "$path" || return 0

  real="$(realpath -m "$path")"
  [[ -n "${RUNNER_SEEN[$real]:-}" ]] && return 0
  RUNNER_SEEN["$real"]=1

  name="$(runner_name_from_path "$type" "$path")"
  RUNNER_TYPES+=("$type")
  RUNNER_SOURCES+=("$source")
  RUNNER_NAMES+=("$name")
  RUNNER_PATHS+=("$real")
}

add_proton_paths() {
  local source="$1" path
  shift || true
  for path in "$@"; do
    add_runner proton "$source" "$path"
  done
}

add_wine_paths() {
  local source="$1" path
  shift || true
  for path in "$@"; do
    if ! wine_root_has_proton "$path"; then
      add_runner wine "$source" "$path"
    fi
  done
}

read_steam_libraries() {
  local file line lib
  for file in \
    "$HOME/.local/share/Steam/steamapps/libraryfolders.vdf" \
    "$HOME/.steam/root/steamapps/libraryfolders.vdf"; do
    [[ -r "$file" ]] || continue
    while IFS= read -r line; do
      if [[ "$line" =~ \"path\"[[:space:]]+\"([^\"]+)\" ]]; then
        lib="${BASH_REMATCH[1]}"
        expand_path "$lib"
      fi
    done < "$file"
  done
}

collect_runners() {
  local lib
  reset_runners

  if [[ -n "${WINRUN_RUNNER:-}" ]]; then
    try_resolve_runner_arg "$WINRUN_RUNNER" >/dev/null 2>&1 || true
    if [[ -n "${RESOLVED_RUNNER_PATH:-}" ]]; then
      add_runner "$RESOLVED_RUNNER_TYPE" env "$RESOLVED_RUNNER_PATH"
    fi
  fi

  if [[ -n "${PROTON_GE_PATH:-}" ]]; then
    try_resolve_runner_arg "$PROTON_GE_PATH" >/dev/null 2>&1 || true
    if [[ -n "${RESOLVED_RUNNER_PATH:-}" ]]; then
      add_runner "$RESOLVED_RUNNER_TYPE" env "$RESOLVED_RUNNER_PATH"
    fi
  fi

  shopt -s nullglob
  # The default runner first: whoever takes the first runner gets it.
  add_proton_paths steam "$STEAM_RUNNER_DIR/$(runner_dir_name "$DEFAULT_PRODUCT")/proton"
  add_proton_paths local "$LOCAL_RUNNER_DIR/$(runner_dir_name "$DEFAULT_PRODUCT")/proton"

  add_proton_paths steam \
    "$HOME/.local/share/Steam/compatibilitytools.d/DW-Proton Latest/proton" \
    "$HOME/.steam/root/compatibilitytools.d/DW-Proton Latest/proton" \
    "$HOME/.local/share/Steam/compatibilitytools.d/Proton-GE Latest/proton" \
    "$HOME/.steam/root/compatibilitytools.d/Proton-GE Latest/proton"
  add_proton_paths steam \
    "$HOME/.local/share/Steam/compatibilitytools.d"/*/proton \
    "$HOME/.steam/root/compatibilitytools.d"/*/proton
  add_proton_paths local "$LOCAL_RUNNER_DIR"/*/proton

  add_proton_paths steam-system \
    "/usr/share/steam/compatibilitytools.d"/*/proton \
    "/usr/lib/steam/compatibilitytools.d"/*/proton

  add_proton_paths steam-flatpak \
    "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d"/*/proton

  add_proton_paths lutris \
    "$HOME/.local/share/lutris/runners/proton"/*/proton \
    "$HOME/.local/share/lutris/runners/wine"/*/proton \
    "$HOME/.var/app/net.lutris.Lutris/data/lutris/runners/proton"/*/proton \
    "$HOME/.var/app/net.lutris.Lutris/data/lutris/runners/wine"/*/proton

  add_proton_paths steam-official \
    "$HOME/.local/share/Steam/steamapps/common/Proton - Experimental/proton" \
    "$HOME/.steam/root/steamapps/common/Proton - Experimental/proton"
  add_proton_paths steam-official \
    "$HOME/.local/share/Steam/steamapps/common"/Proton*/proton \
    "$HOME/.steam/root/steamapps/common"/Proton*/proton

  while IFS= read -r lib; do
    [[ -n "$lib" ]] || continue
    add_proton_paths steam-library "$lib/steamapps/common"/Proton*/proton
  done < <(read_steam_libraries)

  add_wine_paths lutris-wine \
    "$HOME/.local/share/lutris/runners/wine"/*/files/bin/wine \
    "$HOME/.local/share/lutris/runners/wine"/*/bin/wine \
    "$HOME/.var/app/net.lutris.Lutris/data/lutris/runners/wine"/*/files/bin/wine \
    "$HOME/.var/app/net.lutris.Lutris/data/lutris/runners/wine"/*/bin/wine
  shopt -u nullglob
}

RESOLVED_RUNNER_TYPE=""
RESOLVED_RUNNER_PATH=""

try_resolve_runner_arg() {
  local input path base root product
  input="$1"
  RESOLVED_RUNNER_TYPE=""
  RESOLVED_RUNNER_PATH=""

  if product="$(runner_product_alias "$input")"; then
    try_resolve_runner_product "$product"
    return $?
  fi

  path="$(expand_path "$input")"

  if [[ -d "$path" && -x "$path/proton" ]]; then
    RESOLVED_RUNNER_TYPE="proton"
    RESOLVED_RUNNER_PATH="$(realpath -m "$path/proton")"
    return 0
  fi

  if [[ -f "$path" && -x "$path" ]]; then
    base="$(basename "$path")"
    if [[ "$base" == "proton" ]]; then
      RESOLVED_RUNNER_TYPE="proton"
      RESOLVED_RUNNER_PATH="$(realpath -m "$path")"
      return 0
    fi
    if [[ "$base" == "wine" || "$base" == "wine64" ]]; then
      RESOLVED_RUNNER_TYPE="wine"
      RESOLVED_RUNNER_PATH="$(realpath -m "$path")"
      return 0
    fi
  fi

  if [[ -d "$path" ]]; then
    for root in "$path/files/bin/wine" "$path/bin/wine"; do
      if [[ -x "$root" ]]; then
        RESOLVED_RUNNER_TYPE="wine"
        RESOLVED_RUNNER_PATH="$(realpath -m "$root")"
        return 0
      fi
    done
  fi

  return 1
}

try_resolve_runner_from_prefix() {
  local config_line runner_root
  RESOLVED_RUNNER_TYPE=""
  RESOLVED_RUNNER_PATH=""

  [[ -r "$PREFIX/config_info" ]] || return 1
  config_line="$(sed -n '2p' "$PREFIX/config_info")"
  [[ -n "$config_line" ]] || return 1

  runner_root="$(dirname "$(dirname "$(dirname "$config_line")")")"
  if [[ -x "$runner_root/proton" ]] && runner_arch_matches_host "$runner_root/proton"; then
    RESOLVED_RUNNER_TYPE="proton"
    RESOLVED_RUNNER_PATH="$(realpath -m "$runner_root/proton")"
    return 0
  fi
  if [[ -x "$runner_root/bin/wine" ]] && runner_arch_matches_host "$runner_root/bin/wine"; then
    RESOLVED_RUNNER_TYPE="wine"
    RESOLVED_RUNNER_PATH="$(realpath -m "$runner_root/bin/wine")"
    return 0
  fi

  return 1
}

resolve_runner_arg() {
  try_resolve_runner_arg "$1" || die_runner_not_found "$1"
}

try_select_runner() {
  if [[ -n "$RUNNER_ARG" ]]; then
    try_resolve_runner_arg "$RUNNER_ARG"
    return $?
  fi

  if try_resolve_runner_from_prefix; then
    return 0
  fi

  collect_runners
  if [[ ${#RUNNER_PATHS[@]} -eq 0 ]]; then
    return 1
  fi

  RESOLVED_RUNNER_TYPE="${RUNNER_TYPES[0]}"
  RESOLVED_RUNNER_PATH="${RUNNER_PATHS[0]}"
  return 0
}

select_runner() {
  if try_select_runner; then
    return 0
  fi

  if [[ -n "$RUNNER_ARG" ]]; then
    die_runner_not_found "$RUNNER_ARG"
  fi

  ensure_runner_product "$DEFAULT_PRODUCT" || die_install "failed to install runner: $DEFAULT_PRODUCT"
}

list_runners() {
  local selected_path mark i
  collect_runners

  selected_path=""
  if [[ -n "$RUNNER_ARG" ]]; then
    resolve_runner_arg "$RUNNER_ARG"
    selected_path="$(realpath -m "$RESOLVED_RUNNER_PATH")"
  elif [[ ${#RUNNER_PATHS[@]} -gt 0 ]]; then
    selected_path="${RUNNER_PATHS[0]}"
  fi

  if [[ ${#RUNNER_PATHS[@]} -eq 0 ]]; then
    printf 'No runners found.\n'
    return 0
  fi

  for i in "${!RUNNER_PATHS[@]}"; do
    if [[ "${RUNNER_PATHS[$i]}" == "$selected_path" ]]; then
      printf '  * %s\n' "${RUNNER_NAMES[$i]}"
    else
      printf '    %s\n' "${RUNNER_NAMES[$i]}"
    fi
    printf '      type:   %s\n' "${RUNNER_TYPES[$i]}"
    printf '      source: %s\n' "${RUNNER_SOURCES[$i]}"
    printf '      path:   %s\n' "${RUNNER_PATHS[$i]}"
  done
}

