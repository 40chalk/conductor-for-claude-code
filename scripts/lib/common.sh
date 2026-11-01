#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR disable=SC2034  # sourced library: the scripts that source it read these variables
# scripts/lib/common.sh - shared helpers for every conductor script (docs/DESIGN.md section 4.4).
#
# Sourced, never run. Pure bash plus the Git Bash tool list of DESIGN section 3.1, because the
# shims, the forwarder and the Windows part of cx-doctor run it under Git Bash, where python3 is
# never used (cx_py_ok is false there whatever PATH holds). It defines the version and pins, the
# exit-code table with its constant CX_SIGNAL reasons, notes, cx_signal / cx_emit, timeouts,
# WSL output decoding, the path-option wrappers and forwarding step 0 (DESIGN section 7.3).
#
# Each script sets CX_PROG (its name for notes) before sourcing this file.

if [ "${CX_COMMON_SH:-}" = "${BASH_SOURCE[0]}" ] && declare -F cx_note >/dev/null 2>&1; then
  return 0
fi
CX_COMMON_SH="${BASH_SOURCE[0]}"

CX_VERSION=0.1.0
CX_PIN_COPILOT=1.0.105
CX_PIN_GROK=1.0.70
CX_MIN_CLAUDE=2.1.316
CX_MIN_AGY=1.1.12
CX_MIN_GH_COPILOT_REVIEW=2.89.0

CX_PROG="${CX_PROG:-cx}"
# Never trust an inherited cache: python3 availability is decided by this process.
unset CX_PY_OK CX_UNAME_S_CACHE

# shellcheck disable=SC1007  # CDPATH= (empty) is intended: an exported CDPATH must not change cd
CX_ROOT="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
CX_LIB="$CX_ROOT/scripts/lib"
CX_HOSTDIR="$CX_ROOT/scripts/host"

# Directories of the runtime copy (DESIGN sections 7.5 and 13.4); D4 accepts exactly these plus
# RUNTIME_STAMP.
CX_RUNTIME_DIRS=(.claude-plugin bin scripts hooks worker-shims templates)

# The shipped file list (DESIGN section 13.4); cx-doctor D3 checks the installed copy against it.
CX_SHIPPED_FILES=(
  .claude-plugin/plugin.json .claude-plugin/marketplace.json
  bin/cx-doctor bin/cx-init bin/cx-wsl
  scripts/cx-doctor.sh scripts/cx-init.sh scripts/cx-wsl.sh
  scripts/lib/common.sh scripts/lib/options.sh scripts/lib/cxlib.py
  scripts/host/detect.sh scripts/host/pathmap.sh scripts/host/forward-wsl.sh
  scripts/host/wsl-entry.sh scripts/host/install-runtime.sh
  hooks/hooks.json hooks/policy.sh hooks/policy-context.json
  hooks/policy-context-gitbash.json hooks/policy-context-crlf.json
  worker-shims/claude worker-shims/copilot worker-shims/grok worker-shims/agy
  worker-shims/codex worker-shims/gemini worker-shims/cursor-agent worker-shims/agent
  templates/repo-bundle/AGENTS.md templates/repo-bundle/routes.json
  templates/repo-bundle/copilot-instructions.md
  skills/conductor/SKILL.md
  commands/doctor.md commands/init.md commands/route.md
)
# The executable subset (bin/*, scripts/*.sh, scripts/host/*.sh, hooks/policy.sh, worker-shims/*).
CX_SHIPPED_EXEC=(
  bin/cx-doctor bin/cx-init bin/cx-wsl
  scripts/cx-doctor.sh scripts/cx-init.sh scripts/cx-wsl.sh
  scripts/host/detect.sh scripts/host/pathmap.sh scripts/host/forward-wsl.sh
  scripts/host/wsl-entry.sh scripts/host/install-runtime.sh
  hooks/policy.sh
  worker-shims/claude worker-shims/copilot worker-shims/grok worker-shims/agy
  worker-shims/codex worker-shims/gemini worker-shims/cursor-agent worker-shims/agent
)

# The forwarder's command allowlist (DESIGN section 7.3 step 1).
CX_FORWARD_CMDS="cx-doctor cx-init cx-wsl cx-run cx-job cx-fanout cx-gate"
# Program names a hand-built CX_SIGNAL may carry in "cmd" (DESIGN section 4.2).
CX_SIGNAL_CMDS="cx-doctor cx-init cx-wsl cx-run cx-job cx-fanout cx-gate forward-wsl wsl-entry install-runtime pathmap detect"

# Exit-code table (DESIGN section 4.1): exit -> CX_SIGNAL status. 0, 1 and 126 have no status.
declare -gA CX_EXIT_STATUS=(
  [2]=FAILED [3]=EMPTY_OUTPUT [4]=CHECKS_FAILED [5]=EXISTS
  [10]=QUOTA_EXHAUSTED [11]=AUTH_REQUIRED [12]=TIMEOUT [13]=CLI_MISSING [14]=MODEL_UNAVAILABLE
  [15]=PERMISSION_DENIED [16]=SANDBOX_BLOCKED
  [20]=GATE_FAILED [21]=MODEL_MISMATCH [22]=WRONG_TREE [23]=SPEC_TAMPERED [24]=TAMPERED
  [25]=ENV_FAILED [26]=VERSION_MISMATCH [27]=PARTIAL [28]=NO_CAPACITY
  [40]=FORWARD_FAILED [41]=RUNTIME_MISSING [42]=PATH_UNMAPPABLE [43]=HOST_UNSUPPORTED
  [44]=CRLF_CORRUPT [75]=RUNNING [130]=CANCELLED
)
declare -gA CX_STATUS_EXIT=()
for _cx_k in "${!CX_EXIT_STATUS[@]}"; do CX_STATUS_EXIT[${CX_EXIT_STATUS[$_cx_k]}]=$_cx_k; done
unset _cx_k

# Constant reasons and retries, the only text a hand-built CX_SIGNAL carries (DESIGN section 4.2).
# ASCII without quotes or backslashes, so the hand-built JSON needs no escaping.
declare -gA CX_STATUS_REASON=(
  [FAILED]="unexpected failure; see the notes above"
  [EMPTY_OUTPUT]="the executor exited 0 with no answer and no diff"
  [CHECKS_FAILED]="at least one doctor check failed"
  [EXISTS]="a bundle file exists and differs; nothing was written"
  [QUOTA_EXHAUSTED]="quota or rate limit reached"
  [AUTH_REQUIRED]="the executor is not logged in"
  [TIMEOUT]="the wall clock expired"
  [CLI_MISSING]="the executor binary or sibling wrapper was not found"
  [MODEL_UNAVAILABLE]="the model, slug or effort was refused before any model call"
  [PERMISSION_DENIED]="the executor was denied a write, or a denial left no answer or diff"
  [SANDBOX_BLOCKED]="the Claude Code Bash sandbox blocks the executor"
  [GATE_FAILED]="a gate check failed"
  [MODEL_MISMATCH]="the served model differs from the requested model"
  [WRONG_TREE]="files changed outside the task worktree"
  [SPEC_TAMPERED]="the task contract hash does not match"
  [TAMPERED]="a protected path changed"
  [ENV_FAILED]="the repo setup command failed"
  [VERSION_MISMATCH]="the CLI version differs from the pin"
  [PARTIAL]="the executor returned partial output"
  [NO_CAPACITY]="every eligible lane is at its cap, disabled or paused"
  [FORWARD_FAILED]="wsl.exe failed, the WSL distribution is missing, or the WSL VM stopped"
  [RUNTIME_MISSING]="the conductor runtime copy in WSL is missing or does not match this version"
  [PATH_UNMAPPABLE]="a path has no equivalent on the other side"
  [HOST_UNSUPPORTED]="this host cannot do this"
  [CRLF_CORRUPT]="a runtime file still contains CR after stripping"
  [RUNNING]="the job is still running"
  [CANCELLED]="interrupted by INT, TERM or HUP"
)
declare -gA CX_STATUS_RETRY=(
  [CHECKS_FAILED]="fix the checks marked with a cross, then run cx-doctor again"
  [EXISTS]="cx-init --force (rewrites only the conductor block or routes.json)"
  [AUTH_REQUIRED]="cx-doctor --login-help"
  [CLI_MISSING]="cx-doctor (run it from a WSL terminal first)"
  [SANDBOX_BLOCKED]="rerun this Bash call outside the sandbox"
  [VERSION_MISMATCH]="cx-doctor"
  [FORWARD_FAILED]="cx-doctor --windows"
  [RUNTIME_MISSING]="cx-doctor --install-runtime"
  [PATH_UNMAPPABLE]="use a Windows drive path, a wsl.localhost path or wsl:<path>"
  [CRLF_CORRUPT]="cx-doctor"
  [RUNNING]="cx-job wait"
)

# cx_uname_s: `uname -s` through PATH (tests stub it), cached per process.
cx_uname_s() {
  if [ -z "${CX_UNAME_S_CACHE+x}" ]; then
    CX_UNAME_S_CACHE="$(uname -s 2>/dev/null)" || CX_UNAME_S_CACHE=""
  fi
  printf '%s\n' "$CX_UNAME_S_CACHE"
}

# cx_is_windows_shell: rc 0 under Git Bash, MSYS or Cygwin.
cx_is_windows_shell() {
  if [ -z "${CX_UNAME_S_CACHE+x}" ]; then
    CX_UNAME_S_CACHE="$(uname -s 2>/dev/null)" || CX_UNAME_S_CACHE=""
  fi
  case "$CX_UNAME_S_CACHE" in MINGW*|MSYS*|CYGWIN*) return 0 ;; esac
  return 1
}

# cx_py_ok: rc 0 when python3 may be used (never on Git Bash, MSYS or Cygwin).
cx_py_ok() {
  cx_is_windows_shell && return 1
  if [ -z "${CX_PY_OK:-}" ]; then
    if command -v python3 >/dev/null 2>&1 && python3 -I -V >/dev/null 2>&1; then
      CX_PY_OK=1
    else
      CX_PY_OK=0
    fi
  fi
  [ "$CX_PY_OK" = 1 ]
}

cx_py() { python3 -I "$CX_LIB/cxlib.py" "$@"; }

cx_root() { printf '%s\n' "$CX_ROOT"; }
cx_prog() { printf '%s\n' "$CX_PROG"; }
cx_note() { printf '%s: %s\n' "$CX_PROG" "$*" >&2; }

cx_usage_error() {
  cx_note "$*"
  printf '%s: try --help\n' "$CX_PROG" >&2
  exit 1
}

# cx_help [FILE]: the header comment of FILE (default $0), DESIGN section 3.2.
cx_help() {
  awk 'NR <= 2 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${1:-$0}"
}

# cx_help_version ARG: answers -h/--help and --version (DESIGN section 3.2); rc 1 otherwise.
cx_help_version() {
  case "${1-}" in
    -h|--help) cx_help; exit 0 ;;
    --version) printf '%s %s\n' "$CX_PROG" "$CX_VERSION"; exit 0 ;;
  esac
  return 1
}

# cx_trim VALUE: prints VALUE without leading and trailing whitespace.
cx_trim() {
  local v="${1-}"
  v="${v#"${v%%[![:space:]]*}"}"
  v="${v%"${v##*[![:space:]]}"}"
  printf '%s' "$v"
}

# cx_bool VALUE: rc 0 for on|true|1|yes|enabled, rc 1 for off|false|0|no|disabled|"",
# rc 2 for anything else (case-insensitive, whitespace ignored).
cx_bool() {
  local v="${1-}"
  v="${v//[[:space:]]/}"
  v="${v,,}"
  case "$v" in
    on|true|1|yes|enabled) return 0 ;;
    off|false|0|no|disabled|"") return 1 ;;
  esac
  return 2
}

# cx_status_for_exit N: prints the CX_SIGNAL status of exit N (DESIGN section 4.1); prints
# nothing and returns 1 for 0, 1, 126 and codes outside the table.
cx_status_for_exit() {
  local s="${CX_EXIT_STATUS[${1:-x}]-}"
  [ -n "$s" ] || return 1
  printf '%s\n' "$s"
}

_cx_signal_cmd() {
  local c="${CX_SIGNAL_CMD:-$CX_PROG}" w
  for w in $CX_SIGNAL_CMDS; do
    [ "$w" = "$c" ] && { printf '%s' "$c"; return 0; }
  done
  printf 'cx'
}

# cx_signal STATUS EXIT REASON [RETRY]: prints one CX_SIGNAL line to stderr and exits EXIT.
# With python3 the payload is built by cxlib.py (REASON sanitized); without it (always on Git
# Bash) the line holds only constants and REASON goes into a plain note before it.
cx_signal() {
  local status="${1:-FAILED}" code="${2:-2}" reason="${3-}" retry cmd
  if [ $# -ge 4 ]; then retry="$4"; else retry="${CX_STATUS_RETRY[$status]-}"; fi
  cmd="$(_cx_signal_cmd)"
  [[ $code =~ ^[0-9]+$ ]] || code=2
  if cx_py_ok && [ -f "$CX_LIB/cxlib.py" ]; then
    local -a rargs=(retry "$retry")
    [ -n "$retry" ] || rargs=(retry:null "")
    [ -n "$reason" ] || reason="${CX_STATUS_REASON[$status]-unexpected failure}"
    if python3 -I "$CX_LIB/cxlib.py" emit SIGNAL status "$status" exit:int "$code" \
         reason "$reason" "${rargs[@]}" cmd "${CX_SIGNAL_CMD:-$CX_PROG}" >&2 2>/dev/null; then
      exit "$code"
    fi
  fi
  [ -n "$reason" ] && cx_note "$reason"
  _cx_signal_const "$status" "$code" "$cmd"
  exit "$code"
}

# _cx_signal_const STATUS EXIT CMD: the hand-built line; every value comes from a fixed table.
_cx_signal_const() {
  local status="$1" code="$2" cmd="$3" r t
  if [ -z "${CX_STATUS_EXIT[$status]-}" ]; then
    status="${CX_EXIT_STATUS[$code]-FAILED}"
  fi
  code="${CX_STATUS_EXIT[$status]}"
  r="${CX_STATUS_REASON[$status]}"
  t="${CX_STATUS_RETRY[$status]-}"
  if [ -n "$t" ]; then t="\"$t\""; else t=null; fi
  printf 'CX_SIGNAL {"status": "%s", "exit": %s, "reason": "%s", "retry": %s, "cmd": "%s"}\n' \
    "$status" "$code" "$r" "$t" "$cmd" >&2
}

# cx_emit NAME [KEY VALUE]...: one CX_NAME line on stderr (KEY suffixes :int :bool :json
# :null; none = string). Without python3 a plain note stands in for it.
cx_emit() {
  local name="$1"
  shift
  if cx_py_ok && [ -f "$CX_LIB/cxlib.py" ]; then
    python3 -I "$CX_LIB/cxlib.py" emit "$name" "$@" >&2 && return 0
  fi
  local s="CX_$name not emitted (python3 unavailable):"
  while [ $# -ge 2 ]; do
    s="$s ${1%%:*}=$2"
    shift 2
  done
  cx_note "$s"
  return 0
}

# cx_have_timeout: rc 0 when GNU timeout is on PATH.
cx_have_timeout() { command -v timeout >/dev/null 2>&1; }

# cx_timeout SECS CMD...: timeout --kill-after=5s SECSs CMD..., SECS capped by CX_PROBE_TIMEOUT.
# Without timeout it runs CMD unguarded and sets CX_UNGUARDED=1.
cx_timeout() {
  local secs="$1"
  shift
  if [[ ${CX_PROBE_TIMEOUT:-} =~ ^[0-9]+$ ]] && [ "$CX_PROBE_TIMEOUT" -ge 1 ] \
     && [ "$CX_PROBE_TIMEOUT" -lt "$secs" ]; then
    secs="$CX_PROBE_TIMEOUT"
  fi
  if cx_have_timeout; then
    timeout --kill-after=5s "${secs}s" "$@"
  else
    CX_UNGUARDED=1
    "$@"
  fi
}

# cx_decode_wsl: stdin -> stdout. UTF-16LE (BOM FF FE, or a NUL second byte) is decoded with
# iconv when present, else by dropping NULs; a BOM is dropped; CRs are always removed.
cx_decode_wsl() {
  local t u b
  t="$(mktemp "${TMPDIR:-/tmp}/cx-dec.XXXXXXXX" 2>/dev/null)" || { tr -d '\r'; return 0; }
  cat > "$t"
  b="$(od -An -tx1 -N2 "$t" 2>/dev/null | tr -d ' \n')"
  if [ "$b" = fffe ] || [ "${b:2:2}" = 00 ]; then
    u="$t.u8"
    if command -v iconv >/dev/null 2>&1 && iconv -f UTF-16LE -t UTF-8 "$t" > "$u" 2>/dev/null; then
      LC_ALL=C sed '1s/^\xef\xbb\xbf//' "$u" | tr -d '\r'
    else
      tr -d '\000' < "$t" | LC_ALL=C sed '1s/^\xff\xfe//' | tr -d '\r'
    fi
    rm -f "$u"
  else
    LC_ALL=C sed '1s/^\xef\xbb\xbf//' "$t" | tr -d '\r'
  fi
  rm -f "$t"
  return 0
}

# cx_win_config_dir / cx_win_settings_file (Git Bash): the Windows-side Claude config dir and
# settings file (DESIGN section 7.3): $CLAUDE_CONFIG_DIR, else %USERPROFILE%\.claude, else
# $HOME/.claude.
cx_win_config_dir() {
  local d
  if [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    d="$CLAUDE_CONFIG_DIR"
    case "$d" in
      [A-Za-z]:*|*\\*) d="$(cygpath -u "$d" 2>/dev/null)" || d="" ;;
    esac
    [ -n "$d" ] && { printf '%s\n' "$d"; return 0; }
  fi
  if [ -n "${USERPROFILE:-}" ] && d="$(cygpath -u "$USERPROFILE" 2>/dev/null)" && [ -n "$d" ]; then
    printf '%s\n' "$d/.claude"
    return 0
  fi
  printf '%s\n' "${HOME:-}/.claude"
}
cx_win_settings_file() { printf '%s\n' "$(cx_win_config_dir)/settings.json"; }

_cx_source_pathmap() {
  declare -F cx_path_to_wsl >/dev/null 2>&1 && return 0
  # shellcheck source=../host/pathmap.sh
  . "$CX_HOSTDIR/pathmap.sh"
}

_cx_source_detect() {
  declare -F cx_detect >/dev/null 2>&1 && return 0
  # shellcheck source=../host/detect.sh
  . "$CX_HOSTDIR/detect.sh"
}

# cx_path_in_var VAR VALUE: maps a user-supplied path option to its WSL form (pathmap to-wsl,
# caller from CX_CALLER) into VAR; on refusal a note, CX_SIGNAL PATH_UNMAPPABLE and exit 42.
cx_path_in_var() {
  local __var="$1" __val="$2" __caller=wsl
  [ "${CX_CALLER:-}" = gitbash ] && __caller=gitbash
  _cx_source_pathmap
  if cx_path_to_wsl --caller "$__caller" -- "$__val" >/dev/null; then
    printf -v "$__var" '%s' "$CX_PATHMAP_OUT"
    return 0
  fi
  cx_note "cannot map path '$__val': $CX_PATHMAP_ERR"
  cx_signal PATH_UNMAPPABLE 42 "cannot map path: $CX_PATHMAP_ERR"
}

# cx_path_in VALUE: cx_path_in_var for command substitution; the caller checks the rc
# (the signal is printed, the subshell exits 42).
cx_path_in() {
  local out
  cx_path_in_var out "$1" || return $?
  printf '%s\n' "$out"
}

# cx_host_path WSLPATH: the caller-side (Windows) form for machine output when CX_CALLER=gitbash,
# else nothing. rc 42 (nothing printed) when the path is not representable.
cx_host_path() {
  [ "${CX_CALLER:-}" = gitbash ] || return 0
  _cx_source_pathmap
  local -a d=()
  if [ -z "${WSL_DISTRO_NAME:-}" ]; then
    local o="${CLAUDE_PLUGIN_OPTION_WSL_DISTRO:-auto}"
    [ "$o" != auto ] && [ -n "$o" ] && d=(--distro "$o")
  fi
  cx_path_to_win "${d[@]+"${d[@]}"}" -- "$1" >/dev/null || return 42
  printf '%s\n' "$CX_PATHMAP_OUT"
}

# cx_forward_if_needed CMD ARGS...: DESIGN section 7.3 step 0. Returns on hosts that run
# locally; on Git Bash it execs the forwarder (it never returns there).
cx_forward_if_needed() {
  local cmd="$1" eh
  shift
  _cx_source_detect
  cx_detect
  case "$CX_HOST" in
    wsl|macos|docker) return 0 ;;
    linux)
      if declare -F cx_opt >/dev/null 2>&1; then
        [ -n "${CX_OPTIONS_LOADED:-}" ] || cx_load_options
        eh="$(cx_opt exec_host 2>/dev/null)"
        if [ "$eh" = wsl ]; then
          cx_note "option exec_host=wsl, but this host is plain Linux, not WSL"
          cx_signal HOST_UNSUPPORTED 43 "exec_host=wsl on a plain Linux host"
        fi
      fi
      return 0 ;;
    gitbash) ;;
    *)
      cx_note "host '$CX_HOST' is not supported (uname -s: $(cx_uname_s))"
      cx_signal HOST_UNSUPPORTED 43 "unsupported host $CX_HOST" ;;
  esac
  # Git Bash: never run locally, whatever CX_FORWARDED holds (DESIGN section 7.3 step 2).
  if [ -n "${CLAUDE_PLUGIN_OPTION_EXEC_HOST+x}" ]; then
    eh="${CLAUDE_PLUGIN_OPTION_EXEC_HOST:-auto}"
  else
    eh=""
    if declare -F cx_opt_lite >/dev/null 2>&1; then
      eh="$(cx_opt_lite exec_host "$(cx_win_settings_file)")"
    fi
    eh="${eh:-auto}"
  fi
  eh="${eh//[[:space:]]/}"
  eh="${eh,,}"
  case "$eh" in
    local)
      cx_note "option exec_host=local cannot run on Git Bash: the executors live in WSL"
      cx_signal HOST_UNSUPPORTED 43 "exec_host=local on Git Bash" ;;
    auto|wsl) ;;
    *) cx_note "ignoring invalid option exec_host='$eh'; using 'auto'" ;;
  esac
  exec "${BASH:-bash}" "$CX_HOSTDIR/forward-wsl.sh" "$cmd" "$@"
}
