# shellcheck shell=bash
# 全局状态跨模块共享（由主程序 source），对整个文件屏蔽未用变量提示
# shellcheck disable=SC2034
# WinRun — product naming and install dirs

normalize_product() {
  local product="${1,,}"
  case "$product" in
    ge|ge-proton|proton-ge)
      printf 'ge\n'
      ;;
    dw|dwproton|dw-proton|dw_proton)
      printf 'dw\n'
      ;;
    we|weproton|we-proton|we_proton)
      printf 'we\n'
      ;;
    *)
      die "unknown runner product: $1"
      ;;
  esac
}

runner_dir_name() {
  local product="$1"
  case "$product" in
    ge) printf 'Proton-GE Latest' ;;
    dw) printf 'DW-Proton Latest' ;;
    we) printf 'WE-Proton Latest' ;;
    *) die "unknown runner product: $product" ;;
  esac
}

runner_target_dir_name() {
  local product="$1" version="$2" tag="${3:-}"
  if [[ "$version" == "latest" ]]; then
    runner_dir_name "$product"
  else
    printf '%s\n' "${tag:-$version}"
  fi
}

runner_product_alias() {
  local product="${1,,}"
  case "$product" in
    ge|ge-proton|proton-ge)
      printf 'ge\n'
      ;;
    dw|dwproton|dw-proton|dw_proton)
      printf 'dw\n'
      ;;
    we|weproton|we-proton|we_proton)
      printf 'we\n'
      ;;
    *)
      return 1
      ;;
  esac
}

try_resolve_runner_product() {
  local product="$1" name path
  name="$(runner_dir_name "$product")"

  # found in any of these places, it is used and not downloaded again
  for path in \
    "$STEAM_RUNNER_DIR/$name/proton" \
    "$HOME/.steam/root/compatibilitytools.d/$name/proton" \
    "$LOCAL_RUNNER_DIR/$name/proton" \
    "/usr/share/steam/compatibilitytools.d/$name/proton" \
    "/usr/lib/steam/compatibilitytools.d/$name/proton" \
    "$HOME/.var/app/com.valvesoftware.Steam/data/Steam/compatibilitytools.d/$name/proton" \
    "$HOME/.local/share/lutris/runners/proton/$name/proton" \
    "$HOME/.local/share/lutris/runners/wine/$name/proton" \
    "$HOME/.var/app/net.lutris.Lutris/data/lutris/runners/proton/$name/proton" \
    "$HOME/.var/app/net.lutris.Lutris/data/lutris/runners/wine/$name/proton"; do
    if [[ -x "$path" ]] && runner_arch_matches_host "$path"; then
      RESOLVED_RUNNER_TYPE="proton"
      RESOLVED_RUNNER_PATH="$(realpath -m "$path")"
      return 0
    fi
  done

  return 1
}

