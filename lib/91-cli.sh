# shellcheck shell=bash
# 全局状态跨模块共享（由主程序 source），对整个文件屏蔽未用变量提示
# shellcheck disable=SC2034
# WinRun — argument parsing

parse_args() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help)
        usage
        exit 0
        ;;
      --help-full)
        usage_full
        exit 0
        ;;
      --lang)
        [[ $# -ge 2 ]] || die "$1 requires zh or en"
        case "${2,,}" in
          zh|en) LANG_OVERRIDE="${2,,}" ;;
          *) die "unsupported language: $2" ;;
        esac
        shift 2
        ;;
      -p|--prefix)
        [[ $# -ge 2 ]] || die "$1 requires a directory"
        PREFIX="$2"
        PREFIX_EXPLICIT=1
        shift 2
        ;;
      --runner)
        [[ $# -ge 2 ]] || die "$1 requires a path"
        RUNNER_ARG="$2"
        RUNNER_EXPLICIT=1
        shift 2
        ;;
      --gs|--gamescope)
        GAMESCOPE=1
        GAMESCOPE_EXPLICIT=1
        shift
        while [[ $# -gt 0 ]]; do
          case "$1" in
            -h|--help)
              gamescope_usage
              exit 0
              ;;
            --windowed)
              GAMESCOPE_FULLSCREEN=0
              shift
              ;;
            --fullscreen)
              GAMESCOPE_FULLSCREEN=1
              shift
              ;;
            --res)
              [[ $# -ge 2 ]] || die "$1 requires WIDTHxHEIGHT"
              validate_resolution "$2"
              GAMESCOPE_RES="$2"
              shift 2
              ;;
            --fps)
              [[ $# -ge 2 ]] || die "$1 requires FPS"
              validate_number "$2"
              GAMESCOPE_FPS="$2"
              shift 2
              ;;
            --fsr)
              GAMESCOPE_FSR=1
              shift
              ;;
            --args)
              [[ $# -ge 2 ]] || die "$1 requires arguments"
              GAMESCOPE_EXTRA="$2"
              shift 2
              ;;
            --)
              shift
              break
              ;;
            --*)
              break
              ;;
            *)
              break
              ;;
          esac
        done
        ;;
      --mangohud)
        MANGOHUD=1
        MANGOHUD_EXPLICIT=1
        shift
        ;;
      --wayland)
        WAYLAND=1
        WAYLAND_EXPLICIT=1
        shift
        ;;
      --netns)
        ACTION="netns"
        if [[ $# -ge 2 && ( "$2" == "on" || "$2" == "off" ) ]]; then
          NETNS_ARG="$2"
          shift 2
        else
          shift
        fi
        ;;
      --debug)
        DEBUG=1
        shift
        ;;
      -d|--directory)
        [[ $# -ge 2 ]] || die "$1 requires a directory"
        DOWNLOAD_DIR="$2"
        shift 2
        ;;
      --version)
        [[ $# -ge 2 ]] || die "$1 requires a version"
        VERSION="$2"
        shift 2
        ;;
      --clean)
        CLEAN=1
        shift
        ;;
      --list-runner)
        ACTION="list"
        shift
        ;;
      --list-version)
        [[ $# -ge 2 ]] || die "$1 requires ge, dw or we"
        ACTION="list-version"
        PRODUCT="$2"
        shift 2
        ;;
      --status)
        ACTION="status"
        shift
        ;;
      --init)
        ACTION="init"
        shift
        ;;
      --winecfg)
        ACTION="winecfg"
        shift
        ;;
      --download)
        [[ $# -ge 2 ]] || die "$1 requires ge, dw or we"
        ACTION="download"
        PRODUCT="$2"
        shift 2
        ;;
      --install)
        [[ $# -ge 2 ]] || die "$1 requires ge, dw or we"
        ACTION="install"
        PRODUCT="$2"
        shift 2
        ;;
      --install-steam)
        [[ $# -ge 2 ]] || die "$1 requires ge, dw or we"
        ACTION="install"
        PRODUCT="$2"
        INSTALL_TO="steam"
        shift 2
        ;;
      --install-lutris)
        [[ $# -ge 2 ]] || die "$1 requires ge, dw or we"
        ACTION="install"
        PRODUCT="$2"
        INSTALL_TO="lutris"
        shift 2
        ;;
      --update)
        ACTION="update"
        shift
        ;;
      --check-update)
        ACTION="check-update"
        shift
        ;;
      --doctor)
        ACTION="doctor"
        shift
        ;;
      --remove)
        [[ $# -ge 2 ]] || die "$1 requires ge, dw or we"
        ACTION="remove"
        PRODUCT="$2"
        shift 2
        ;;
      --remove-steam)
        INSTALL_TO="steam"
        if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then
          ACTION="remove"
          PRODUCT="$2"
          shift 2
        else
          ACTION="remove-all"
          shift
        fi
        ;;
      --remove-lutris)
        INSTALL_TO="lutris"
        if [[ $# -ge 2 && ! "$2" =~ ^- ]]; then
          ACTION="remove"
          PRODUCT="$2"
          shift 2
        else
          ACTION="remove-all"
          shift
        fi
        ;;
      --)
        shift
        [[ $# -ge 1 ]] || die "-- requires a target"
        TARGET="$1"
        shift
        TARGET_ARGS=("$@")
        break
        ;;
      -*)
        die "unknown option: $1"
        ;;
      *)
        if [[ -z "$ACTION" ]]; then
          TARGET="$1"
          shift
          TARGET_ARGS=("$@")
          break
        fi
        die "unexpected argument for $ACTION: $1"
        ;;
    esac
  done
}

# ------------------------------------------------------- helper processes
# Started by the wrapper itself: --session-keeper by pasta inside a network
# namespace session, --in-gamescope by Gamescope in front of the program, and
# --ime-watch by the latter.

# The keeper of a network namespace session. It routes name servers around an
# accelerator's tunnel, bridges the session bus, passes games' connections to
# the host's Steam client, starts Windows programs for Linux programs of the
# session, and exits once the last other process has left the namespace, which
# ends pasta and the namespace with it.
