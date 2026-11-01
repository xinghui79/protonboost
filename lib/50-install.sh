# shellcheck shell=bash
# 全局状态跨模块共享（由主程序 source），对整个文件屏蔽未用变量提示
# shellcheck disable=SC2034
# WinRun — version lists, download, install/update/remove runners

list_versions() {
  local product="$1"
  product="$(normalize_product "$product")"
  python3 - "$product" <<'PY'
import json
import sys
import urllib.request
import urllib.error

product = sys.argv[1]

if product == "ge":
    url = "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases?per_page=20"
elif product == "dw":
    url = "https://dawn.wine/api/v1/repos/dawn-winery/dwproton/releases?limit=20"
elif product == "we":
    raise SystemExit("WE-Proton 在线下载已移除（本地维护版）：请手动下载 WE-Proton 并解压到 ~/.local/share/Steam/compatibilitytools.d/WE-Proton Latest")
else:
    raise SystemExit(f"unknown product: {product}")

request = urllib.request.Request(url, headers={"User-Agent": "winrun"})
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
except urllib.error.HTTPError as exc:
    raise SystemExit(f"failed to fetch version list: HTTP {exc.code}")
except urllib.error.URLError as exc:
    raise SystemExit(f"failed to fetch version list: {exc.reason}")

if isinstance(data, dict):
    data = [data]

for release in data:
    tag = release.get("tag_name") or release.get("name") or ""
    if not tag:
        continue
    published = release.get("published_at") or release.get("created_at") or ""
    published = published[:10]
    print(f"{tag}  {published}")
PY
}

release_info() {
  local product="$1" version="$2"
  python3 - "$product" "$version" <<'PY'
import json
import sys
import urllib.request
import urllib.error

product = sys.argv[1]
version = sys.argv[2]

machine = __import__("platform").machine().lower()
if machine in ("x86_64", "amd64"):
    blocked_arches = ("aarch64", "arm64")
elif machine in ("aarch64", "arm64"):
    blocked_arches = ("x86_64", "amd64")
else:
    blocked_arches = ()

def asset_matches_host(name):
    lower = name.lower()
    return not any(arch in lower for arch in blocked_arches)

if product == "ge":
    if version == "latest":
        url = "https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
    else:
        url = f"https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/tags/{version}"
    archive_suffixes = (".tar.gz",)
    checksum_suffix = ".sha512sum"
elif product == "dw":
    if version == "latest":
        url = "https://dawn.wine/api/v1/repos/dawn-winery/dwproton/releases/latest"
    else:
        url = f"https://dawn.wine/api/v1/repos/dawn-winery/dwproton/releases/tags/{version}"
    archive_suffixes = ("x86_64.tar.xz",)
    checksum_suffix = "x86_64.sha512sum"
elif product == "we":
    raise SystemExit("WE-Proton 在线下载已移除（本地维护版）：请手动下载 WE-Proton 并解压到 ~/.local/share/Steam/compatibilitytools.d/WE-Proton Latest")
else:
    raise SystemExit(f"unknown product: {product}")

# WE-Proton releases also carry <tag>-source.tar.xz, the patched sources
excluded_suffixes = ("-source.tar.xz",)

request = urllib.request.Request(url, headers={"User-Agent": "winrun"})
try:
    with urllib.request.urlopen(request, timeout=30) as response:
        data = json.load(response)
except urllib.error.HTTPError as exc:
    raise SystemExit(f"release not found for {product} {version}: HTTP {exc.code}")
except urllib.error.URLError as exc:
    raise SystemExit(f"failed to fetch release info for {product} {version}: {exc.reason}")

assets = data.get("assets") or []
tag = data.get("tag_name") or data.get("name") or version
archive = None
checksum = None

for asset in assets:
    name = asset.get("name", "")
    download = asset.get("browser_download_url", "")
    if not download:
        continue
    if archive is None and asset_matches_host(name) and any(name.endswith(suffix) for suffix in archive_suffixes) \
            and not any(name.endswith(suffix) for suffix in excluded_suffixes):
        archive = (name, download)
    if checksum is None and asset_matches_host(name) and name.endswith(checksum_suffix):
        checksum = (name, download)

if archive is None:
    raise SystemExit(f"archive asset not found for {product} {version}")
if checksum is None:
    raise SystemExit(f"checksum asset not found for {product} {version}")

print(tag)
print(archive[0])
print(archive[1])
print(checksum[0])
print(checksum[1])
PY
}

fetch_file() {
  local url="$1" dest="$2" tmp timeout_prefix product title status
  if [[ -s "$dest" ]]; then
    printf 'Using existing: %s\n' "$dest"
    return 0
  fi

  tmp="$dest.part"
  timeout_prefix=()
  # Only wrap in `timeout` when a total cap was explicitly requested; a healthy
  # but slow transfer must be allowed to finish. Stalls are caught by curl/wget.
  if [[ "$DOWNLOAD_TIMEOUT_SECONDS" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
    timeout_prefix=(timeout "${DOWNLOAD_TIMEOUT_SECONDS}s")
  fi
  product="${DOWNLOAD_NOTIFY_PRODUCT:-$(basename "$dest")}"
  title="WinRun"
  status=0
  if command -v curl >/dev/null 2>&1; then
    run_download_command_with_notifications "$title" "$product" "${timeout_prefix[@]}" \
      curl -L --fail --progress-bar --connect-timeout 30 \
        --speed-limit 1024 --speed-time "$DOWNLOAD_STALL_SECONDS" \
        --retry 3 --retry-delay 5 -C - -o "$tmp" "$url" || status=$?
  elif command -v wget >/dev/null 2>&1; then
    run_download_command_with_notifications "$title" "$product" "${timeout_prefix[@]}" \
      wget --continue --timeout=30 --read-timeout="$DOWNLOAD_STALL_SECONDS" --tries=3 -O "$tmp" "$url" || status=$?
  else
    install_error "curl or wget is required for downloads"
    return 1
  fi

  if [[ $status -ne 0 ]]; then
    # Keep the partial file: the next attempt resumes instead of restarting.
    install_error "download failed (exit $status): $url"
    return 1
  fi
  mv "$tmp" "$dest"
}

notify_available() {
  command -v notify-send >/dev/null 2>&1 && [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]
}

# One run keeps a single notification and updates it in place (download,
# extraction, done, prefix setup, errors) instead of stacking new ones.
NOTIFY_ID=""
NOTIFY_CAN_REPLACE=""

notify_can_replace() {
  if [[ -z "$NOTIFY_CAN_REPLACE" ]]; then
    NOTIFY_CAN_REPLACE=0
    if notify-send --help 2>/dev/null | grep -q -- '--replace-id'; then
      NOTIFY_CAN_REPLACE=1
    fi
  fi
  [[ "$NOTIFY_CAN_REPLACE" == 1 ]]
}

notify_send() {
  local urgency="$1" expire="$2" title="$3" message="$4" id
  local args=(--app-name="WinRun" --app-icon=winrun --icon=winrun --urgency="$urgency")
  notify_available || return 0
  [[ -n "$expire" ]] && args+=(--expire-time="$expire")
  if notify_can_replace; then
    [[ -n "$NOTIFY_ID" ]] && args+=(--replace-id="$NOTIFY_ID")
    if id="$(notify-send "${args[@]}" --print-id "$title" "$message" 2>/dev/null)" && [[ "$id" =~ ^[0-9]+$ ]]; then
      NOTIFY_ID="$id"
    fi
  else
    notify-send "${args[@]}" "$title" "$message" >/dev/null 2>&1 || true
  fi
}

# Something is still going on: stay up until the next update replaces it.
notify_progress() {
  notify_send normal "$(( DOWNLOAD_NOTIFY_INTERVAL * 1000 + 5000 ))" "$1" "$2"
}

notify_download() {
  notify_send normal "$DOWNLOAD_NOTIFY_EXPIRE" "$1" "$2"
}

# Errors must survive a desktop launch, where stderr goes nowhere. Critical
# urgency keeps the notification on screen until it is dismissed.
notify_error() {
  notify_send critical "" "WinRun" "$1"
}

# Record a failure reason and report it, without killing the caller: the
# caller still has to notify the user and clean up.
install_error() {
  INSTALL_ERROR="$*"
  printf 'winrun: %s\n' "$*" >&2
}

die_visible() {
  notify_error "$*"
  die "$@"
}

download_message() {
  local key="$1" product="$2"
  if [[ "$(ui_lang)" == "zh" ]]; then
    case "$key" in
      start) printf '正在下载 %s...\n' "$product" ;;
      downloaded) printf '%s 下载完成，正在解压安装...\n' "$product" ;;
      extracting) printf '正在解压 %s，请稍候...\n' "$product" ;;
      done) printf '%s 已安装完成。\n' "$product" ;;
      failed) printf '%s 下载或安装失败。\n' "$product" ;;
      timeout) printf '%s 下载超时，已终止。\n' "$product" ;;
      init) printf '正在初始化运行环境，首次运行需要几分钟...\n' ;;
      init_failed) printf '运行环境初始化失败。\n' ;;
      runtime_fallback) printf 'Steam 运行时不可用，这次在宿主机上直接运行 Proton，视频和音频解码等可能出问题。\n' ;;
    esac
  else
    case "$key" in
      start) printf 'Downloading %s...\n' "$product" ;;
      downloaded) printf '%s download completed. Extracting and installing...\n' "$product" ;;
      extracting) printf 'Extracting %s, please wait...\n' "$product" ;;
      done) printf '%s has been installed.\n' "$product" ;;
      failed) printf 'Failed to download or install %s.\n' "$product" ;;
      timeout) printf '%s download timed out and was stopped.\n' "$product" ;;
      init) printf 'Setting up the runtime environment. The first run takes a few minutes...\n' ;;
      init_failed) printf 'Failed to set up the runtime environment.\n' ;;
      runtime_fallback) printf 'The Steam Linux Runtime is not available; running Proton directly this time, so e.g. video and audio decoding may fail.\n' ;;
    esac
  fi
}

run_download_command_with_notifications() {
  local title product pid notifier_pid status message
  title="$1"
  product="$2"
  shift 2

  message="$(download_message start "$product")"
  notify_progress "$title" "$message"
  "$@" &
  pid=$!
  notifier_pid=""
  # Refresh the same notification so it stays up for the whole download.
  # Without in-place updates every refresh would be a new notification.
  if notify_available && notify_can_replace; then
    (
      while sleep "$DOWNLOAD_NOTIFY_INTERVAL"; do
        kill -0 "$pid" >/dev/null 2>&1 || exit 0
        notify_progress "$title" "$message"
      done
    ) &
    notifier_pid=$!
  fi

  status=0
  wait "$pid" || status=$?
  if [[ -n "$notifier_pid" ]]; then
    kill "$notifier_pid" >/dev/null 2>&1 || true
    wait "$notifier_pid" >/dev/null 2>&1 || true
  fi
  if [[ $status -eq 124 ]]; then
    message="$(download_message timeout "$product")"
    notify_download "$title" "$message"
  fi
  # Other failures are reported once, with a reason, by the install caller.
  return "$status"
}

install_runner_with_notifications() {
  local product title message status old_product log_dir
  product="$(runner_dir_name "$(normalize_product "$PRODUCT")")"
  title="WinRun"
  old_product="${DOWNLOAD_NOTIFY_PRODUCT:-}"
  DOWNLOAD_NOTIFY_PRODUCT="$product"
  INSTALL_ERROR=""

  log_dir="$WRAPPER_CACHE_DIR/logs"
  mkdir -p "$log_dir"
  INSTALL_LOG="$log_dir/install-$(safe_log_name "$product").log"
  : > "$INSTALL_LOG"

  status=0
  install_runner > >(tee -a "$INSTALL_LOG") 2>&1 || status=$?

  if [[ -n "$old_product" ]]; then
    DOWNLOAD_NOTIFY_PRODUCT="$old_product"
  else
    unset DOWNLOAD_NOTIFY_PRODUCT
  fi

  if [[ $status -ne 0 ]]; then
    message="$(download_message failed "$product")"
    if [[ -n "$INSTALL_ERROR" ]]; then
      message="$message"$'\n'"$INSTALL_ERROR"
    fi
    message="$message"$'\n'"$INSTALL_LOG"
    notify_error "$message"
  else
    message="$(download_message done "$product")"
    notify_download "$title" "$message"
  fi
  return "$status"
}

verify_archive() {
  local dir="$1" checksum_name="$2"
  if ! (cd "$dir" && sha512sum -c "$checksum_name"); then
    install_error "checksum verification failed: $dir/$checksum_name
The download is incomplete or corrupted. It has been discarded; run again to re-download."
    return 1
  fi
}

dir_free_kib() {
  df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

file_size_kib() {
  local size
  size="$(stat -c %s "$1" 2>/dev/null || printf '0')"
  printf '%s\n' "$(( (size + 1023) / 1024 ))"
}

# Proton archives expand to roughly five times their compressed size. Refuse
# early with a clear reason instead of failing halfway through tar.
check_extract_space() {
  local archive="$1" dest="$2" needed free
  needed=$(( $(file_size_kib "$archive") * 5 ))
  free="$(dir_free_kib "$dest")"
  [[ "$free" =~ ^[0-9]+$ ]] || return 0
  if [[ "$free" -lt "$needed" ]]; then
    install_error "not enough free space in $dest
Need about $(( (needed + 1023) / 1024 )) MiB, only $(( free / 1024 )) MiB available."
    return 1
  fi
}

find_extracted_runner_root() {
  local extract_dir="$1" path
  if [[ -x "$extract_dir/proton" ]]; then
    printf '%s\n' "$extract_dir"
    return 0
  fi

  shopt -s nullglob
  for path in "$extract_dir"/*; do
    if [[ -d "$path" && -x "$path/proton" ]]; then
      shopt -u nullglob
      printf '%s\n' "$path"
      return 0
    fi
  done
  shopt -u nullglob

  return 1
}

installed_runner_version() {
  local target="$1" product="$2" line version

  if [[ -r "$target/.winrun-version" ]]; then
    sed -n '1p' "$target/.winrun-version"
    return 0
  fi

  if [[ -r "$target/version" ]]; then
    line="$(sed -n '1p' "$target/version")"
    case "$product" in
      ge)
        version="$(printf '%s\n' "$line" | grep -o 'GE-Proton[^[:space:]]*' | head -n 1 || true)"
        ;;
      dw)
        version="$(printf '%s\n' "$line" | grep -o 'dwproton-[^[:space:]]*' | head -n 1 || true)"
        ;;
      we)
        version="$(printf '%s\n' "$line" | grep -o 'we-proton-[^[:space:]]*' | head -n 1 || true)"
        ;;
      *)
        version=""
        ;;
    esac
    [[ -n "$version" ]] && printf '%s\n' "$version"
  fi
}

download_runner() {
  local product info tag archive_name archive_url checksum_name checksum_url dir release_output
  product="$(normalize_product "$PRODUCT")"
  info=()
  release_output="$(release_info "$product" "$VERSION" 2>&1)" || die "$release_output"
  mapfile -t info <<< "$release_output"
  tag="${info[0]:-}" archive_name="${info[1]:-}" archive_url="${info[2]:-}" checksum_name="${info[3]:-}" checksum_url="${info[4]:-}"
  [[ -n "$tag" ]] || die "release not found for $product $VERSION"
  dir="$(expand_path "${DOWNLOAD_DIR:-$(xdg_download_dir)}")"

  mkdir -p "$dir"
  fetch_file "$archive_url" "$dir/$archive_name" || exit 1
  fetch_file "$checksum_url" "$dir/$checksum_name" || exit 1
  verify_archive "$dir" "$checksum_name" || exit 1

  printf 'Downloaded: %s\n' "$dir/$archive_name"
  printf 'Checksum:   %s\n' "$dir/$checksum_name"
  printf 'Verified:   yes\n'
  printf 'Version:    %s\n' "$tag"
}

# Whether a running process executes from this runner directory. Replacing
# a runner under a running session would leave its wineserver on the old
# version and every program that joins the session on the new one.
runner_in_use() {
  local dir proc exe
  dir="$(realpath -m "$1")"
  for proc in /proc/[0-9]*; do
    exe="$(readlink "$proc/exe" 2>/dev/null)" || continue
    exe="${exe#/run/host}"
    [[ "$exe" == "$dir/"* ]] && return 0
  done
  return 1
}

# Returns non-zero on failure and leaves the reason in INSTALL_ERROR. It must
# never exit: the caller is responsible for telling the user what went wrong.
install_runner() {
  local product info tag archive_name archive_url checksum_name checksum_url download_dir install_dir work_dir use_existing extract_dir root target temp_download_dir dir_name release_output release_err
  local product_name title
  product="$(normalize_product "$PRODUCT")"
  info=()
  release_err="$(mktemp)"
  if ! release_output="$(release_info "$product" "$VERSION" 2>"$release_err")"; then
    install_error "$(<"$release_err")"
    rm -f "$release_err"
    return 1
  fi
  rm -f "$release_err"
  mapfile -t info <<< "$release_output"
  tag="${info[0]:-}" archive_name="${info[1]:-}" archive_url="${info[2]:-}" checksum_name="${info[3]:-}" checksum_url="${info[4]:-}"
  if [[ -z "$tag" || -z "$archive_name" || -z "$checksum_name" ]]; then
    install_error "release not found for $product $VERSION"
    return 1
  fi
  download_dir="$(expand_path "${DOWNLOAD_DIR:-$INSTALL_DOWNLOAD_DIR}")"
  install_dir="$(expand_path "${INSTALL_DIR:-$(default_install_dir)}")"
  dir_name="$(runner_target_dir_name "$product" "$VERSION" "$tag")"
  target="$install_dir/$dir_name"
  product_name="$(runner_dir_name "$product")"
  title="WinRun"

  mkdir -p "$download_dir" "$install_dir"
  find "$download_dir" -maxdepth 1 -type d \( -name 'install-*' -o -name 'partial-*' \) -mmin +1440 -exec rm -rf {} + 2>/dev/null || true
  find "$install_dir" -maxdepth 1 -type d -name '.pw-extract-*' -mmin +60 -exec rm -rf {} + 2>/dev/null || true

  use_existing=0
  temp_download_dir=""
  extract_dir=""

  cleanup_install_failure() {
    [[ -n "$extract_dir" ]] && rm -rf "$extract_dir"
    return 0
  }

  if [[ -s "$download_dir/$archive_name" && -s "$download_dir/$checksum_name" ]]; then
    work_dir="$download_dir"
    use_existing=1
    printf 'Using downloaded files in: %s\n' "$download_dir"
  else
    # A fixed directory per release, not a random one: a retry after a dropped
    # connection resumes the partial file instead of downloading it all again.
    temp_download_dir="$download_dir/partial-$tag"
    work_dir="$temp_download_dir"
    mkdir -p "$work_dir"
    if ! fetch_file "$archive_url" "$work_dir/$archive_name"; then
      return 1
    fi
    if ! fetch_file "$checksum_url" "$work_dir/$checksum_name"; then
      return 1
    fi
    notify_progress "$title" "$(download_message downloaded "$product_name")"
  fi

  if ! verify_archive "$work_dir" "$checksum_name"; then
    # A corrupt file must not be resumed, so this is the one case that discards it.
    rm -f "$work_dir/$archive_name" "$work_dir/$archive_name.part" "$work_dir/$checksum_name"
    return 1
  fi

  if ! check_extract_space "$work_dir/$archive_name" "$install_dir"; then
    return 1
  fi

  notify_progress "$title" "$(download_message extracting "$product_name")"

  # Extract next to the install target, not in /tmp: /tmp is usually a tmpfs
  # backed by RAM, and this keeps the final move a same-filesystem rename.
  if ! extract_dir="$(mktemp -d "$install_dir/.pw-extract-XXXXXX")"; then
    install_error "failed to create a work directory in: $install_dir"
    return 1
  fi
  if ! tar -xf "$work_dir/$archive_name" -C "$extract_dir"; then
    cleanup_install_failure
    install_error "failed to extract archive: $work_dir/$archive_name
The archive may be corrupted or the disk may be full."
    return 1
  fi
  if ! root="$(find_extracted_runner_root "$extract_dir")"; then
    cleanup_install_failure
    install_error "extracted archive does not contain a proton runner: $work_dir/$archive_name"
    return 1
  fi
  if [[ -e "$target" && ! -x "$target/proton" ]]; then
    cleanup_install_failure
    install_error "install target exists but is not a runner: $target"
    return 1
  fi
  if [[ -e "$target" ]] && runner_in_use "$target"; then
    cleanup_install_failure
    install_error "runner is in use: $target
Close the programs running with it, then update again."
    return 1
  fi
  if ! rm -rf "$target"; then
    cleanup_install_failure
    install_error "failed to remove old install target: $target"
    return 1
  fi
  if ! mv "$root" "$target"; then
    cleanup_install_failure
    install_error "failed to install runner to: $target"
    return 1
  fi
  printf '%s\n' "$tag" > "$target/.winrun-version"
  if [[ "$VERSION" == "latest" ]]; then
    pin_runner_tool_name "$target" "$product_name" "$tag"
  fi
  rm -rf "$extract_dir"
  extract_dir=""

  if [[ $use_existing -eq 0 ]]; then
    rm -rf "$work_dir"
    temp_download_dir=""
  elif [[ $CLEAN -eq 1 ]]; then
    rm -f "$download_dir/$archive_name" "$download_dir/$checksum_name"
  fi

  printf 'Installed: %s\n' "$target/proton"
}

# Steam remembers each game's compatibility tool by the tool's internal name
# in compatibilitytool.vdf, which a release sets to its version. A "Latest"
# runner is replaced on every update, and a new name each time would leave the
# games set to it without a tool, so it keeps one name: its folder's, and the
# version goes into the name Steam shows.
pin_runner_tool_name() {
  local dir="$1" name="$2" version="$3"
  [[ -f "$dir/compatibilitytool.vdf" ]] || return 0
  python3 - "$dir/compatibilitytool.vdf" "${name// /-}" "$name${version:+ ($version)}" <<'PY'
import re
import sys

path, internal, display = sys.argv[1:]
with open(path, encoding="utf-8") as file:
    text = file.read()
# the first key in "compat_tools" is the tool's internal name
match = re.search(r'"compat_tools"\s*\{\s*"([^"]+)"', text)
if not match:
    sys.exit(0)
text = text[:match.start(1)] + internal + text[match.end(1):]
text = re.sub(r'("display_name"\s+)"[^"]*"', lambda m: m.group(1) + '"' + display + '"', text, count=1)
with open(path, "w", encoding="utf-8") as file:
    file.write(text)
PY
}

# Whether release $2 is newer than the installed version $1. A runner built
# locally, or installed before a release was withdrawn, can be ahead of the
# latest release; replacing it would be a downgrade.
version_newer() {
  [[ "$1" != "$2" && "$(printf '%s\n' "$1" "$2" | sort -V | tail -n 1)" == "$2" ]]
}

update_runner() {
  local product target install_to_old old_product old_version release_output tag current found updated skipped
  local -A latest_tags=()
  install_to_old="$INSTALL_TO"
  old_product="$PRODUCT"
  old_version="$VERSION"
  VERSION="latest"
  found=0
  updated=0
  skipped=0

  for INSTALL_TO in local steam lutris; do
    for product in ge dw; do
      PRODUCT="$product"
      target="$(expand_path "$(default_install_dir)")/$(runner_dir_name "$product")"
      if [[ -e "$target" ]]; then
        found=1
        # one lookup per product, though it may be installed in several places
        if [[ ! -v "latest_tags[$product]" ]]; then
          release_output="$(release_info "$product" latest 2>&1)" || die "$release_output"
          latest_tags[$product]="${release_output%%$'\n'*}"
        fi
        tag="${latest_tags[$product]}"
        [[ -n "$tag" ]] || die "release not found for $product latest"
        current="$(installed_runner_version "$target" "$product" || true)"
        if [[ "$current" == "$tag" ]]; then
          printf 'Already latest: %s (%s)\n' "$target" "$tag"
          pin_runner_tool_name "$target" "$(runner_dir_name "$product")" "$current"
          skipped=1
        elif [[ -n "$current" ]] && ! version_newer "$current" "$tag"; then
          printf 'Newer than the latest release, kept: %s (%s, latest %s)\n' "$target" "$current" "$tag"
          pin_runner_tool_name "$target" "$(runner_dir_name "$product")" "$current"
          skipped=1
        else
          printf 'Updating: %s\n' "$target"
          if [[ -n "$current" ]]; then
            printf '  %s -> %s\n' "$current" "$tag"
          fi
          install_runner_with_notifications || die_install "failed to update runner: $product"
          updated=1
        fi
      fi
    done
  done

  INSTALL_TO="$install_to_old"
  PRODUCT="$old_product"
  VERSION="$old_version"
  [[ $found -eq 1 ]] || die "no installed Latest runners found"
  if [[ $updated -eq 0 && $skipped -eq 1 ]]; then
    printf 'All installed Latest runners are up to date.\n'
  fi
}

check_update_runner() {
  local product target release_output tag current found
  local install_to_old old_product old_version
  local -A latest_tags=()
  install_to_old="$INSTALL_TO"
  old_product="$PRODUCT"
  old_version="$VERSION"
  VERSION="latest"
  found=0

  for INSTALL_TO in local steam lutris; do
    for product in ge dw; do
      PRODUCT="$product"
      target="$(expand_path "$(default_install_dir)")/$(runner_dir_name "$product")"
      if [[ -e "$target" ]]; then
        found=1
        if [[ ! -v "latest_tags[$product]" ]]; then
          release_output="$(release_info "$product" latest 2>/dev/null)" || release_output=""
          latest_tags[$product]="${release_output%%$'\n'*}"
        fi
        tag="${latest_tags[$product]}"
        [[ -n "$tag" ]] || continue
        current="$(installed_runner_version "$target" "$product" 2>/dev/null || true)"
        if [[ -n "$current" ]] && version_newer "$current" "$tag"; then
          printf '%s\t%s\t->\t%s\t(%s)\n' "$product" "$current" "$tag" "$INSTALL_TO"
        fi
      fi
    done
  done

  INSTALL_TO="$install_to_old"
  PRODUCT="$old_product"
  VERSION="$old_version"
  [[ $found -eq 1 ]] || return 0
  return 0
}

remove_runner() {
  local product dir_name install_dir target targets removed lang
  product="$(normalize_product "$PRODUCT")"
  dir_name="$(runner_target_dir_name "$product" "$VERSION")"
  install_dir="$(expand_path "${INSTALL_DIR:-$(default_install_dir)}")"
  targets=("$install_dir/$dir_name")
  # --remove also takes what earlier versions installed in the old place
  if [[ -z "$INSTALL_DIR" && "$INSTALL_TO" == "default" ]]; then
    targets+=("$LOCAL_RUNNER_DIR/$dir_name")
  fi
  lang="$(ui_lang)"

  removed=0
  for target in "${targets[@]}"; do
    [[ -e "$target" ]] || continue
    rm -rf "$target"
    removed=1
    if [[ "$lang" == "zh" ]]; then
      printf '已移除: %s\n' "$target"
    else
      printf 'Removed: %s\n' "$target"
    fi
  done

  if [[ $removed -eq 0 ]]; then
    if [[ "$lang" == "zh" ]]; then
      die "$dir_name 未安装"
    else
      die "$dir_name is not installed"
    fi
  fi
}

remove_all_runners() {
  local install_dir path removed lang
  install_dir="$(expand_path "${INSTALL_DIR:-$(default_install_dir)}")"
  lang="$(ui_lang)"
  removed=0

  shopt -s nullglob
  for path in "$install_dir"/*; do
    if [[ -d "$path" && -f "$path/.winrun-version" ]]; then
      rm -rf "$path"
      removed=1
      if [[ "$lang" == "zh" ]]; then
        printf '已移除: %s\n' "$path"
      else
        printf 'Removed: %s\n' "$path"
      fi
    fi
  done
  shopt -u nullglob

  if [[ $removed -eq 0 ]]; then
    if [[ "$lang" == "zh" ]]; then
      die "没有找到由 winrun 安装的运行器: $install_dir"
    else
      die "no runners installed by winrun found in: $install_dir"
    fi
  fi
}

ensure_runner_product() {
  local product="$1" old_product old_version old_install_to status
  if try_resolve_runner_product "$product"; then
    return 0
  fi

  old_product="$PRODUCT"
  old_version="$VERSION"
  old_install_to="$INSTALL_TO"

  PRODUCT="$product"
  VERSION="latest"
  INSTALL_TO="default"
  status=0
  install_runner_with_notifications || status=$?

  PRODUCT="$old_product"
  VERSION="$old_version"
  INSTALL_TO="$old_install_to"

  [[ $status -eq 0 ]] || return 1

  try_resolve_runner_product "$product"
}

# install_runner_with_notifications has already shown the reason; only announce
# it here when the failure happened somewhere that stayed silent.
die_install() {
  if [[ -n "$INSTALL_ERROR" ]]; then
    die "$*"
  fi
  die_visible "$*"
}

select_init_runner() {
  local product
  if [[ -n "$RUNNER_ARG" ]]; then
    if product="$(runner_product_alias "$RUNNER_ARG")"; then
      ensure_runner_product "$product" || die_install "failed to install runner: $product"
    else
      resolve_runner_arg "$RUNNER_ARG"
    fi
    return 0
  fi

  ensure_runner_product "$DEFAULT_PRODUCT" || die_install "failed to install runner: $DEFAULT_PRODUCT"
}

