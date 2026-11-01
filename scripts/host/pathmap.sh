#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# pathmap.sh - two-way path mapping between WSL, Windows and Git Bash (docs/DESIGN.md 7.2).
#
# Usage: pathmap.sh to-wsl     [--caller gitbash|win|wsl] [--distro D] [--mnt-root R] PATH
#        pathmap.sh to-win     [--distro D] [--mnt-root R] [--mixed] PATH
#        pathmap.sh to-gitbash [--distro D] [--mnt-root R] PATH
#        pathmap.sh -h|--help | --version
#
# Pure bash string mapping (no filesystem access, no wslpath, no cygpath), identical on both
# sides. Prints the result and a newline. A path with no equivalent on the other side is
# refused: "pathmap: <reason>" and one CX_SIGNAL PATH_UNMAPPABLE line on stderr, exit 42.
#
# Defaults: --distro = $WSL_DISTRO_NAME, else $CX_WSL_DISTRO, else none (rules that need the
# name then refuse with "distro unknown (pass --distro)"); --mnt-root = $CX_MNT_ROOT, else
# [automount] root from ${CX_DETECT_ROOT:-}/etc/wsl.conf, else /mnt/; --caller = wsl unless
# CX_CALLER=gitbash. to-wsl accepts drive paths (C:\x, c:/x, \\?\C:\x), \\wsl.localhost\<D>\...
# and \\wsl$\<D>\... (either separator), wsl:<abs posix path>, Git Bash /c/... (caller gitbash)
# and relative paths; it refuses network shares, device paths and drive-relative paths.
#
# Sourced, it defines cx_path_to_wsl, cx_path_to_win and cx_path_to_gitbash with the same
# arguments: they print the result, set CX_PATHMAP_OUT, and on refusal return 42 with the
# reason in CX_PATHMAP_ERR (nothing printed).
#
# Exit codes: 0 mapped; 1 usage error; 42 PATH_UNMAPPABLE.

# _cx_pm_mnt_root [R]: the normalized mount root (always ends in /).
_cx_pm_mnt_root() {
  local r="${1-}" line sect="" val
  if [ -z "$r" ]; then r="${CX_MNT_ROOT:-}"; fi
  if [ -z "$r" ] && [ -r "${CX_DETECT_ROOT:-}/etc/wsl.conf" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      line="${line%%#*}"
      line="${line#"${line%%[![:space:]]*}"}"
      line="${line%"${line##*[![:space:]]}"}"
      case "$line" in
        \[*\]) sect="${line#[}"; sect="${sect%]}"; sect="${sect,,}"; sect="${sect//[[:space:]]/}" ;;
        *=*)
          if [ "$sect" = automount ]; then
            val="${line%%=*}"
            val="${val//[[:space:]]/}"
            if [ "${val,,}" = root ]; then
              val="${line#*=}"
              val="${val#"${val%%[![:space:]]*}"}"
              case "$val" in \"*\") val="${val#\"}"; val="${val%\"}" ;; \'*\') val="${val#\'}"; val="${val%\'}" ;; esac
              [ -n "$val" ] && r="$val"
            fi
          fi ;;
      esac
    done < "${CX_DETECT_ROOT:-}/etc/wsl.conf"
  fi
  [ -n "$r" ] || r=/mnt/
  case "$r" in */) ;; *) r="$r/" ;; esac
  while [[ $r == *//* ]]; do r="${r//\/\//\/}"; done
  printf '%s' "$r"
}

# _cx_pm_norm PATH: collapse runs of /, drop a trailing / except on /.
_cx_pm_norm() {
  local p="$1"
  while [[ $p == *//* ]]; do p="${p//\/\//\/}"; done
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s' "$p"
}

_cx_pm_refuse() {
  CX_PATHMAP_ERR="$1"
  CX_PATHMAP_OUT=""
  return 42
}

# _cx_pm_args: shared option parsing; sets PM_CALLER PM_DISTRO PM_MNT PM_MIXED PM_PATH.
_cx_pm_args() {
  PM_CALLER=wsl
  [ "${CX_CALLER:-}" = gitbash ] && PM_CALLER=gitbash
  PM_DISTRO="${WSL_DISTRO_NAME:-${CX_WSL_DISTRO:-}}"
  PM_MNT=""
  PM_MIXED=0
  PM_PATH=""
  local have=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --caller)
        [ $# -ge 2 ] || { CX_PATHMAP_ERR="--caller needs a value"; return 1; }
        case "$2" in gitbash|win|wsl) PM_CALLER="$2" ;; *) CX_PATHMAP_ERR="invalid --caller: $2"; return 1 ;; esac
        shift 2 ;;
      --caller=*)
        case "${1#*=}" in gitbash|win|wsl) PM_CALLER="${1#*=}" ;; *) CX_PATHMAP_ERR="invalid --caller: ${1#*=}"; return 1 ;; esac
        shift ;;
      --distro) [ $# -ge 2 ] || { CX_PATHMAP_ERR="--distro needs a value"; return 1; }; PM_DISTRO="$2"; shift 2 ;;
      --distro=*) PM_DISTRO="${1#*=}"; shift ;;
      --mnt-root) [ $# -ge 2 ] || { CX_PATHMAP_ERR="--mnt-root needs a value"; return 1; }; PM_MNT="$2"; shift 2 ;;
      --mnt-root=*) PM_MNT="${1#*=}"; shift ;;
      --mixed) PM_MIXED=1; shift ;;
      --) shift; [ $# -eq 1 ] || { CX_PATHMAP_ERR="expected exactly one PATH"; return 1; }; PM_PATH="$1"; have=1; shift ;;
      *)
        [ "$have" = 0 ] || { CX_PATHMAP_ERR="expected exactly one PATH"; return 1; }
        PM_PATH="$1"; have=1; shift ;;
    esac
  done
  [ "$have" = 1 ] || { CX_PATHMAP_ERR="missing PATH"; return 1; }
  PM_MNT="$(_cx_pm_mnt_root "$PM_MNT")"
  return 0
}

# _cx_pm_to_wsl P CALLER DISTRO MNT: rules T1-T14.
_cx_pm_to_wsl() {
  local p="$1" caller="$2" distro="$3" mnt="$4" s rest d letter
  CX_PATHMAP_ERR=""
  # T1
  if [ -z "$p" ]; then _cx_pm_refuse "empty path"; return; fi
  case "$p" in *$'\r'*|*$'\n'*) _cx_pm_refuse "path contains CR or LF"; return ;; esac
  # T2
  if [ "${p:0:4}" = "wsl:" ]; then
    rest="${p:4}"
    case "$rest" in
      /*) CX_PATHMAP_OUT="$(_cx_pm_norm "$rest")"; return 0 ;;
      *) _cx_pm_refuse "wsl: needs an absolute POSIX path"; return ;;
    esac
  fi
  s="${p//\\//}"
  # T3, T4
  if [ "${s:0:4}" = "//?/" ]; then
    rest="${s:4}"
    if [[ ${rest,,} == unc/wsl.localhost || ${rest,,} == unc/wsl.localhost/* || ${rest,,} == 'unc/wsl$' || ${rest,,} == 'unc/wsl$/'* ]]; then
      s="//${rest:4}"   # the extended-length form of a T6 path: continue at T6
    elif [[ ${rest,,} == unc/* ]] || [ "${rest,,}" = unc ]; then
      _cx_pm_refuse "network share (\\\\?\\UNC\\...)"; return
    elif [[ $rest =~ ^[A-Za-z]:(/|$) ]]; then
      p="${p:4}"
      s="$rest"
    else
      _cx_pm_refuse "unsupported \\\\?\\ path"; return
    fi
  fi
  # T5
  if [ "${s:0:4}" = "//./" ]; then _cx_pm_refuse "device path"; return; fi
  # T6, T7
  if [ "${s:0:2}" = "//" ] && [ "${s:2:1}" != "/" ]; then
    rest="${s:2}"
    local host="${rest%%/*}"
    if [ "${host,,}" = wsl.localhost ] || [ "${host,,}" = 'wsl$' ]; then
      rest="${rest#"$host"}"
      rest="${rest#/}"
      d="${rest%%/*}"
      rest="${rest#"$d"}"
      if [ -z "$d" ]; then _cx_pm_refuse "no distribution in $p"; return; fi
      if [ -z "$distro" ]; then _cx_pm_refuse "distro unknown (pass --distro)"; return; fi
      if [ "${d,,}" != "${distro,,}" ]; then
        _cx_pm_refuse "path is in distribution $d, the executor host is $distro"; return
      fi
      CX_PATHMAP_OUT="$(_cx_pm_norm "/${rest#/}")"
      return 0
    fi
    _cx_pm_refuse "network share (map it inside WSL first)"; return
  fi
  if [ "${s:0:2}" = "//" ]; then
    _cx_pm_refuse "network share (map it inside WSL first)"; return
  fi
  # T8, T9
  if [[ $s =~ ^([A-Za-z]): ]]; then
    letter="${BASH_REMATCH[1],,}"
    rest="${s:2}"
    case "$rest" in
      /*) CX_PATHMAP_OUT="$(_cx_pm_norm "$mnt$letter$rest")"; return 0 ;;
      *) _cx_pm_refuse "drive-relative path"; return ;;
    esac
  fi
  # T10-T13
  if [ "${p:0:1}" = "/" ]; then
    case "$caller" in
      wsl) CX_PATHMAP_OUT="$(_cx_pm_norm "$p")"; return 0 ;;
      gitbash)
        if [[ $p =~ ^/([A-Za-z])(/.*)?$ ]]; then
          CX_PATHMAP_OUT="$(_cx_pm_norm "$mnt${BASH_REMATCH[1],,}${BASH_REMATCH[2]}")"
          return 0
        fi
        local q="$p/"
        if [ "${q:0:${#mnt}}" = "$mnt" ]; then
          rest="${q:${#mnt}}"
          if [[ $rest =~ ^[a-z]/ ]]; then
            CX_PATHMAP_OUT="$(_cx_pm_norm "$p")"
            return 0
          fi
        fi
        _cx_pm_refuse "Git Bash path with no WSL equivalent; pass a Windows path or wsl:<path>"
        return ;;
      *)
        _cx_pm_refuse "POSIX path from a Windows caller has no WSL equivalent; pass a Windows path or wsl:<path>"
        return ;;
    esac
  fi
  # T14
  [ "$caller" = wsl ] || p="$s"
  CX_PATHMAP_OUT="$(_cx_pm_norm "$p")"
  return 0
}

# _cx_pm_winsafe P: rc 1 when a component cannot be represented on Windows.
_cx_pm_winsafe() {
  case "$1" in
    *\\*|*:*|*\**|*\?*|*\"*|*\<*|*\>*|*\|*) return 1 ;;
  esac
  [[ $1 =~ [[:cntrl:]] ]] && return 1
  return 0
}

# _cx_pm_drive P MNT: when P is <mnt>x or <mnt>x/rest, sets PM_LETTER and PM_REST.
_cx_pm_drive() {
  local p="$1/" mnt="$2" rest
  [ "${p:0:${#mnt}}" = "$mnt" ] || return 1
  rest="${p:${#mnt}}"
  [[ $rest =~ ^([a-z])(/.*)$ ]] || return 1
  PM_LETTER="${BASH_REMATCH[1]}"
  PM_REST="${BASH_REMATCH[2]}"
  PM_REST="${PM_REST%/}"
  return 0
}

_cx_pm_to_win() {
  local p="$1" distro="$2" mnt="$3" mixed="$4" sep="\\" out
  CX_PATHMAP_ERR=""
  [ "$mixed" = 1 ] && sep=/
  if [ -z "$p" ]; then _cx_pm_refuse "empty path"; return; fi
  case "$p" in
    /*) ;;
    *) _cx_pm_refuse "relative path (to-win needs an absolute WSL path)"; return ;;
  esac
  if ! _cx_pm_winsafe "$p"; then _cx_pm_refuse "not representable on Windows: $p"; return; fi
  p="$(_cx_pm_norm "$p")"
  if _cx_pm_drive "$p" "$mnt"; then
    out="${PM_LETTER^^}:${PM_REST//\//$sep}"
    [ -n "$PM_REST" ] || out="${PM_LETTER^^}:$sep"
    CX_PATHMAP_OUT="$out"
    return 0
  fi
  if [ -z "$distro" ]; then _cx_pm_refuse "distro unknown (pass --distro)"; return; fi
  if [ "$p" = / ]; then
    CX_PATHMAP_OUT="$sep${sep}wsl.localhost$sep$distro$sep"
  else
    CX_PATHMAP_OUT="$sep${sep}wsl.localhost$sep$distro${p//\//$sep}"
  fi
  return 0
}

_cx_pm_to_gitbash() {
  local p="$1" distro="$2" mnt="$3"
  CX_PATHMAP_ERR=""
  if [ -z "$p" ]; then _cx_pm_refuse "empty path"; return; fi
  case "$p" in
    /*) ;;
    *)
      _cx_pm_to_wsl "$p" win "$distro" "$mnt" || return
      p="$CX_PATHMAP_OUT"
      case "$p" in /*) ;; *) _cx_pm_refuse "relative path"; return ;; esac ;;
  esac
  p="$(_cx_pm_norm "$p")"
  if _cx_pm_drive "$p" "$mnt"; then
    CX_PATHMAP_OUT="/$PM_LETTER$PM_REST"
    return 0
  fi
  if ! _cx_pm_winsafe "$p"; then _cx_pm_refuse "not representable on Windows: $p"; return; fi
  if [ -z "$distro" ]; then _cx_pm_refuse "distro unknown (pass --distro)"; return; fi
  if [ "$p" = / ]; then CX_PATHMAP_OUT="//wsl.localhost/$distro/"; else CX_PATHMAP_OUT="//wsl.localhost/$distro$p"; fi
  return 0
}

cx_path_to_wsl() {
  CX_PATHMAP_OUT=""
  _cx_pm_args "$@" || return 42
  _cx_pm_to_wsl "$PM_PATH" "$PM_CALLER" "$PM_DISTRO" "$PM_MNT" || return 42
  printf '%s\n' "$CX_PATHMAP_OUT"
}

cx_path_to_win() {
  CX_PATHMAP_OUT=""
  _cx_pm_args "$@" || return 42
  _cx_pm_to_win "$PM_PATH" "$PM_DISTRO" "$PM_MNT" "$PM_MIXED" || return 42
  printf '%s\n' "$CX_PATHMAP_OUT"
}

cx_path_to_gitbash() {
  CX_PATHMAP_OUT=""
  _cx_pm_args "$@" || return 42
  _cx_pm_to_gitbash "$PM_PATH" "$PM_DISTRO" "$PM_MNT" || return 42
  printf '%s\n' "$CX_PATHMAP_OUT"
}

_cx_pathmap_main() {
  set -uo pipefail
  # shellcheck disable=SC2034  # read by common.sh
  CX_PROG=pathmap
  # shellcheck source=/dev/null disable=SC1007  # common.sh sources this file; CDPATH= is intended
  . "$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"
  [ $# -gt 0 ] || cx_usage_error "missing mode (to-wsl, to-win or to-gitbash)"
  cx_help_version "$1"
  local mode="$1"
  shift
  case "$mode" in
    to-wsl|to-win|to-gitbash) ;;
    *) cx_usage_error "unknown mode: $mode" ;;
  esac
  if ! _cx_pm_args "$@"; then cx_usage_error "$CX_PATHMAP_ERR"; fi
  [ "$mode" = to-win ] || [ "$PM_MIXED" = 0 ] || cx_usage_error "--mixed is only for to-win"
  case "$mode" in
    to-wsl) _cx_pm_to_wsl "$PM_PATH" "$PM_CALLER" "$PM_DISTRO" "$PM_MNT" ;;
    to-win) _cx_pm_to_win "$PM_PATH" "$PM_DISTRO" "$PM_MNT" "$PM_MIXED" ;;
    to-gitbash) _cx_pm_to_gitbash "$PM_PATH" "$PM_DISTRO" "$PM_MNT" ;;
  esac
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'pathmap: %s\n' "$CX_PATHMAP_ERR" >&2
    cx_signal PATH_UNMAPPABLE 42 ""
  fi
  printf '%s\n' "$CX_PATHMAP_OUT"
  exit 0
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _cx_pathmap_main "$@"
fi
