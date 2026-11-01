#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# detect.sh - which kind of host this is (docs/DESIGN.md section 7.1).
#
# Usage: detect.sh [--shell | --json | --emit | --field NAME]
#        detect.sh -h|--help | --version
#
#   --shell        (default) KEY=value lines (printf %q) for CX_HOST CX_HOSTKEY CX_DISTRO
#                  CX_OS_ID CX_OS_VERSION CX_WSL_VERSION CX_ARCH CX_KERNEL CX_SESSION CX_ATTENDED
#   --field NAME   one value; NAME is a key above, with or without the CX_ prefix, any case
#   --json         the values as one JSON object on stdout (needs python3)
#   --emit         a CX_HOST line on stderr (needs python3)
#
# CX_HOST is one of wsl, linux, gitbash, docker, macos, cygwin, unknown. CX_SESSION is the
# Claude Code session kind, decided before the host (DESIGN section 7.1): local, bridge (a
# Remote Control child such as a Work locally project thread: local behaviour), cloud
# (CLAUDE_CODE_REMOTE truthy and no CLAUDE_CODE_ENVIRONMENT_KIND) or byoc (truthy with any
# other kind); CX_ATTENDED is 1, 0 (CLAUDE_CODE_SESSION_ATTENDED=0, never for a bridge child) or
# empty. Sourced, the file defines cx_detect (which also calls cx_session and cx_attended), and
# those two functions. Inputs: uname -s/-r/-m/-n (through PATH), the variables CLAUDE_CODE_REMOTE,
# CLAUDE_CODE_ENVIRONMENT_KIND, CLAUDE_CODE_SESSION_ATTENDED, WSL_DISTRO_NAME, MSYSTEM,
# container, COMPOSE_PROJECT_NAME, HOSTNAME, and files
# under ${CX_DETECT_ROOT:-} (empty in production): /.dockerenv, /run/.containerenv,
# /proc/1/cgroup, /proc/sys/fs/binfmt_misc/WSLInterop[-late], /etc/os-release, /etc/wsl.conf;
# on WSL without WSL_DISTRO_NAME also wslpath -w / (the registered distribution name).
# Pure bash: it also runs under Git Bash.
#
# Exit codes: 0 ok; 1 usage error; 2 --json/--emit without python3 (always so on Git Bash).

# shellcheck disable=SC2034  # CX_WSL_INTEROP and CX_DISTRO_SOURCE are read by cx-doctor
# cx_session: sets CX_SESSION (local|bridge|cloud|byoc) from the environment (pure bash), never
# cloud or byoc on Git Bash or WSL (uname -s/-r, WSL_DISTRO_NAME, WSLInterop under
# CX_DETECT_ROOT). "Truthy" is 1, true, yes or on, any case, spaces ignored. Change together
# with the cloud lines of hooks/policy.sh (DESIGN section 10.2 row 4).
cx_session() {
  local r="${CLAUDE_CODE_REMOTE:-}" k="${CLAUDE_CODE_ENVIRONMENT_KIND:-}" w
  r="${r//[[:space:]]/}"
  case "${r,,}" in
    1|true|yes|on)
      case "$k" in "") CX_SESSION=cloud ;; bridge) CX_SESSION=bridge ;; *) CX_SESSION=byoc ;; esac ;;
    *)
      case "$k" in bridge) CX_SESSION=bridge ;; *) CX_SESSION=local ;; esac ;;
  esac
  # Never cloud or BYOC on the user's computer: Anthropic's cloud containers are plain Linux,
  # so a Git Bash or WSL host is local whatever the variables say (a false cloud verdict would
  # switch the conductor off on its own executor host).
  case "$CX_SESSION" in
    cloud|byoc)
      case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*) CX_SESSION=local; return 0 ;; esac
      [ -n "${WSL_DISTRO_NAME:-}" ] && { CX_SESSION=local; return 0; }
      for w in "${CX_DETECT_ROOT:-}"/proc/sys/fs/binfmt_misc/WSLInterop*; do
        [ -e "$w" ] && { CX_SESSION=local; return 0; }
      done
      case "$(uname -r 2>/dev/null)" in *[Mm]icrosoft*) CX_SESSION=local ;; esac ;;
  esac
  return 0
}
# cx_attended: sets CX_ATTENDED (1|0|"") from CLAUDE_CODE_SESSION_ATTENDED; a bridge child is
# never 0 (it has a claude.ai UI even when Claude Code marks it unattended; [unverified]).
cx_attended() {
  case "${CLAUDE_CODE_SESSION_ATTENDED:-}" in
    1) CX_ATTENDED=1 ;;
    0) if [ "${CX_SESSION:-}" = bridge ]; then CX_ATTENDED=; else CX_ATTENDED=0; fi ;;
    *) CX_ATTENDED= ;;
  esac
  return 0
}

# cx_detect: sets CX_HOST CX_HOSTKEY CX_DISTRO CX_OS_ID CX_OS_VERSION CX_WSL_VERSION CX_ARCH
# CX_KERNEL CX_SESSION CX_ATTENDED (and on WSL CX_WSL_INTEROP=1|0 and
# CX_DISTRO_SOURCE=env|wslpath|os-release).
cx_detect() {
  local s r m n root="${CX_DETECT_ROOT:-}" line key val cg="" name w
  cx_session
  cx_attended
  s="$(uname -s 2>/dev/null)" || s=""
  r="$(uname -r 2>/dev/null)" || r=""
  m="$(uname -m 2>/dev/null)" || m=""
  n="$(uname -n 2>/dev/null)" || n=""
  [ -n "$n" ] || n="${HOSTNAME:-}"
  [ -n "$n" ] || n=localhost
  CX_ARCH="$m"
  CX_KERNEL="$r"
  CX_DISTRO=""
  CX_OS_ID=""
  CX_OS_VERSION=""
  CX_WSL_VERSION=""
  CX_WSL_INTEROP=""
  CX_DISTRO_SOURCE=""

  # os-release ID / VERSION_ID, quotes stripped (Linux only).
  if [ "$s" = Linux ]; then
    local osr="$root/etc/os-release"
    [ -r "$osr" ] || osr="$root/usr/lib/os-release"
    if [ -r "$osr" ]; then
      while IFS= read -r line || [ -n "$line" ]; do
        line="${line%$'\r'}"
        case "$line" in
          ID=*|VERSION_ID=*)
            key="${line%%=*}"
            val="${line#*=}"
            case "$val" in
              \"*\") val="${val#\"}"; val="${val%\"}" ;;
              \'*\') val="${val#\'}"; val="${val%\'}" ;;
            esac
            if [ "$key" = ID ]; then CX_OS_ID="$val"; else CX_OS_VERSION="$val"; fi ;;
        esac
      done < "$osr"
    fi
  fi

  case "$s" in
    MINGW*|MSYS*)
      CX_HOST=gitbash
      CX_OS_ID=windows
      case "$s" in *_NT-*) CX_OS_VERSION="${s#*_NT-}" ;; esac ;;
    CYGWIN*)
      CX_HOST=cygwin
      CX_OS_ID=windows ;;
    Darwin)
      CX_HOST=macos
      CX_OS_ID=macos ;;
    Linux)
      [ -r "$root/proc/1/cgroup" ] && cg="$(< "$root/proc/1/cgroup")"
      if [ -e "$root/.dockerenv" ] || [ -e "$root/run/.containerenv" ] || [ -n "${container:-}" ] \
         || [[ $cg =~ docker|containerd|kubepods|libpod ]]; then
        CX_HOST=docker
      elif [ -n "${WSL_DISTRO_NAME:-}" ] || [ -e "$root/proc/sys/fs/binfmt_misc/WSLInterop" ] \
           || [ -e "$root/proc/sys/fs/binfmt_misc/WSLInterop-late" ]; then
        CX_HOST=wsl
        CX_WSL_INTEROP=1
      elif [[ $r =~ [Mm]icrosoft ]]; then
        CX_HOST=wsl
        CX_WSL_INTEROP=0
      else
        CX_HOST=linux
      fi ;;
    *)
      CX_HOST=unknown ;;
  esac

  if [ "$CX_HOST" = wsl ]; then
    if [[ $r =~ microsoft-standard|WSL2 ]]; then
      CX_WSL_VERSION=2
    elif [[ $r == *-Microsoft* ]]; then
      CX_WSL_VERSION=1
    fi
    # The registered name, as forwarded (wsl.exe-launched) calls see it in WSL_DISTRO_NAME.
    # Shells that lack the variable (ssh, su -, cron, systemd units) take it from wslpath -w /
    # (\\wsl.localhost\<Name>\ or the legacy \\wsl$\<Name>\), and only then from os-release.
    CX_DISTRO="${WSL_DISTRO_NAME:-}"
    CX_DISTRO_SOURCE="env"
    if [ -z "$CX_DISTRO" ]; then
      CX_DISTRO_SOURCE=os-release
      if command -v wslpath >/dev/null 2>&1; then
        w="$(wslpath -w / 2>/dev/null </dev/null)" || w=""
        w="${w//\\//}"
        case "${w,,}" in
          //wsl.localhost/?*|//wsl\$/?*)
            w="${w#//*/}"
            w="${w%%/*}"
            [[ $w =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] && { CX_DISTRO="$w"; CX_DISTRO_SOURCE=wslpath; } ;;
        esac
      fi
      [ -n "$CX_DISTRO" ] || CX_DISTRO="$CX_OS_ID"
    fi
  else
    CX_DISTRO="$CX_OS_ID"
    [ "$CX_HOST" = gitbash ] && CX_DISTRO=""
  fi

  case "$CX_HOST" in
    wsl) name="wsl-${CX_DISTRO:-unknown}" ;;
    docker) name="docker-${COMPOSE_PROJECT_NAME:-$n}" ;;
    *) name="$CX_HOST-$n" ;;
  esac
  CX_HOSTKEY="${name//[^A-Za-z0-9._-]/_}"
  return 0
}

_cx_detect_main() {
  set -uo pipefail
  # shellcheck disable=SC2034  # read by common.sh
  CX_PROG=detect
  # shellcheck source=/dev/null disable=SC1007  # common.sh sources this file; CDPATH= is intended
  . "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"
  local mode="--shell" field="" k
  if [ $# -gt 0 ]; then
    cx_help_version "$1"
    case "$1" in
      --shell|--json|--emit) mode="$1"; [ $# -eq 1 ] || cx_usage_error "unexpected argument: $2" ;;
      --field)
        [ $# -eq 2 ] || cx_usage_error "--field needs exactly one NAME"
        mode=--field
        field="$2" ;;
      *) cx_usage_error "unknown argument: $1" ;;
    esac
  fi
  cx_detect
  local -a keys=(CX_HOST CX_HOSTKEY CX_DISTRO CX_OS_ID CX_OS_VERSION CX_WSL_VERSION CX_ARCH CX_KERNEL
                 CX_SESSION CX_ATTENDED)
  case "$mode" in
    --shell)
      for k in "${keys[@]}"; do printf '%s=%q\n' "$k" "${!k}"; done ;;
    --field)
      k="${field^^}"
      k="CX_${k#CX_}"
      case " ${keys[*]} " in
        *" $k "*) printf '%s\n' "${!k}" ;;
        *) cx_usage_error "unknown field: $field" ;;
      esac ;;
    --json|--emit)
      if ! cx_py_ok; then
        cx_note "$mode needs python3 (never used on Git Bash); use --shell or --field"
        cx_signal FAILED 2 ""
      fi
      local -a args=(host "$CX_HOST" hostkey "$CX_HOSTKEY")
      if [ -n "$CX_DISTRO" ]; then args+=(distro "$CX_DISTRO"); else args+=(distro:null ""); fi
      if [ -n "$CX_OS_ID" ]; then args+=(os_id "$CX_OS_ID"); else args+=(os_id:null ""); fi
      if [ -n "$CX_OS_VERSION" ]; then args+=(os_version "$CX_OS_VERSION"); else args+=(os_version:null ""); fi
      if [ -n "$CX_WSL_VERSION" ]; then args+=(wsl_version:int "$CX_WSL_VERSION"); else args+=(wsl_version:null ""); fi
      args+=(arch "$CX_ARCH" kernel "$CX_KERNEL" session "$CX_SESSION")
      if [ -n "$CX_ATTENDED" ]; then args+=(attended:int "$CX_ATTENDED"); else args+=(attended:null ""); fi
      if [ "$mode" = --json ]; then
        cx_py json "${args[@]}" || cx_signal FAILED 2 "cxlib.py json failed"
      else
        cx_emit HOST "${args[@]}"
      fi ;;
  esac
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _cx_detect_main "$@"
fi
