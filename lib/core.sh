# shellcheck shell=bash
# 全局状态跨模块共享（由主程序 source），对整个文件屏蔽未用变量提示
# shellcheck disable=SC2034
# WinRun — locale, debug/run logging, app id

ui_lang() {
  local locale="${LANG_OVERRIDE:-${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}}"
  case "${locale,,}" in
    zh|zh_*|zh.*|zh-*) printf 'zh\n' ;;
    *) printf 'en\n' ;;
  esac
}

setup_debug_logging() {
  local log_dir name timestamp
  [[ $DEBUG -eq 1 ]] || return 0

  log_dir="$XDG_CACHE_HOME_VALUE/winrun/logs"
  mkdir -p "$log_dir"
  DEBUG_ENV=("PROTON_LOG=1" "PROTON_LOG_DIR=$log_dir")
  [[ -n "$TARGET" ]] && return 0

  name="${ACTION:-command}"
  name="$(safe_log_name "$name")"
  timestamp="$(date +%Y%m%d-%H%M%S)"
  DEBUG_LOG="$log_dir/$timestamp-$name.log"
  exec > >(tee -a "$DEBUG_LOG") 2>&1
  printf 'Debug log: %s\n' "$DEBUG_LOG"
  printf 'Command: winrun'
  printf ' %q' "${ORIGINAL_ARGS[@]}"
  printf '\n'
}

safe_log_name() {
  local name="$1"
  name="$(basename "${name:-command}")"
  printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_'
}

wrapper_app_id() {
  local prefix="$1" target="$2"
  python3 - "$prefix" "$target" <<'PY'
import hashlib
import sys

print(hashlib.sha256((sys.argv[1] + "\0" + sys.argv[2]).encode()).hexdigest()[:10])
PY
}

setup_run_logging() {
  local log_dir
  RUN_APP_ID="$(wrapper_app_id "$PREFIX" "$TARGET")"
  log_dir="$XDG_CACHE_HOME_VALUE/winrun/logs/$RUN_APP_ID"
  mkdir -p "$log_dir"
  rm -f "$log_dir"/*.log
  RUN_LOG="$log_dir/latest.log"
  RUN_ENV=(
    "WINRUN_APP_ID=$RUN_APP_ID"
    "WINRUN_APP_PATH=$TARGET"
    "WINRUN_PREFIX=$PREFIX"
    "WINRUN_LOG=$RUN_LOG"
  )
  if [[ $DEBUG -eq 1 ]]; then
    DEBUG_ENV=("PROTON_LOG=1" "PROTON_LOG_DIR=$log_dir")
  fi

  exec > >(tee -a "$RUN_LOG") 2>&1
  printf 'Log: %s\n' "$RUN_LOG"
  printf 'Command: winrun'
  printf ' %q' "${ORIGINAL_ARGS[@]}"
  printf '\n'
  printf 'App ID: %s\n' "$RUN_APP_ID"
  printf 'Target: %s\n' "$TARGET"
  printf 'Prefix: %s\n' "$PREFIX"
  printf 'Runner: %s\n' "$RESOLVED_RUNNER_PATH"
  printf 'Runner type: %s\n' "$RESOLVED_RUNNER_TYPE"
  if [[ $DEBUG -eq 1 ]]; then
    printf 'Proton debug log dir: %s\n' "$log_dir"
  fi
  printf -- '--- output ---\n'
}

