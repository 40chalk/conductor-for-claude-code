#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# forward-wsl.sh - runs a conductor command inside WSL from Git Bash (docs/DESIGN.md 7.3).
#
# Usage: forward-wsl.sh CMD [ARG...]
#        forward-wsl.sh --bootstrap-install     (cx-doctor --install-runtime on Git Bash)
#        forward-wsl.sh -h|--help | --version
#
# CMD is one of cx-doctor cx-init cx-wsl cx-run cx-job cx-fanout cx-gate. Every cx-* script
# execs this on Git Bash (forwarding step 0). The arguments cross as a NUL-separated file, never
# re-quoted or path-converted; only CX_WORKER, CX_DEBUG, NO_COLOR, CX_SLOT_WAIT_SECS and the
# conductor's CLAUDE_PLUGIN_OPTION_* variables cross (nothing else: no PATH, HOME, tokens); the cwd crosses
# as its long Windows form (cygpath -w -l) and is mapped on the WSL side. wsl.exe runs
#   wsl.exe [-d <distro>] --cd ~ --exec /bin/bash --noprofile --norc \
#     .conductor/runtime/<version>/scripts/host/wsl-entry.sh
# with only CX_FWD_WIN in WSLENV. stdin passes through, stdout is never altered, stderr is
# passed through. When the runtime copy is missing, it is installed once from this plugin copy
# (unless CX_NO_AUTO_INSTALL=1). INT/TERM/HUP stop the Linux-side process group too.
#
# Options read: wsl_distro (environment, else a pure-bash read of the Windows-side settings);
# auto = wsl.exe's default distribution. CX_DEBUG=1 prints the wsl.exe argv and keeps the
# transport directory (argv, env, meta). Pure bash plus the Git Bash tool list (DESIGN 3.1).
#
# Exit codes: the forwarded command's own status (0-255) passes through unchanged; the
# forwarder itself exits 1 (usage: CMD not allowed), 40 FORWARD_FAILED (wsl.exe missing,
# invalid wsl_distro, wsl.exe failed before the command started, or WSL died under it),
# 41 RUNTIME_MISSING (no runtime copy and it could not be installed), 42 PATH_UNMAPPABLE
# (a cwd that cannot be written to the transport), 43 HOST_UNSUPPORTED (no cygpath),
# 130 CANCELLED. --bootstrap-install exits with the installer's code (0, 1, 2, 44) or 40.

set -uo pipefail
unset CDPATH
CX_PROG=forward-wsl
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
. "$HERE/../lib/common.sh"
# shellcheck source=../lib/options.sh
. "$HERE/../lib/options.sh"

[ $# -gt 0 ] && cx_help_version "$1"
[ $# -gt 0 ] || cx_usage_error "missing CMD (one of: $CX_FORWARD_CMDS)"
CMD="$1"
shift
MODE=forward
if [ "$CMD" = --bootstrap-install ]; then
  MODE=install
  [ $# -eq 0 ] || cx_usage_error "--bootstrap-install takes no arguments"
  CMD=cx-doctor
else
  case " $CX_FORWARD_CMDS " in
    *" $CMD "*) ;;
    *) cx_usage_error "not a forwardable command: $CMD (one of: $CX_FORWARD_CMDS)" ;;
  esac
fi
CX_SIGNAL_CMD="$CMD"
ARGS=("$@")

# Step 2: the distribution.
if [ -n "${CLAUDE_PLUGIN_OPTION_WSL_DISTRO+x}" ]; then
  DISTRO="${CLAUDE_PLUGIN_OPTION_WSL_DISTRO}"
else
  DISTRO="$(cx_opt_lite wsl_distro "$(cx_win_settings_file)")"
fi
DISTRO="$(cx_trim "$DISTRO")"
[ -n "$DISTRO" ] || DISTRO=auto
D_ARGS=()
if [ "${DISTRO,,}" = auto ]; then
  DISTRO=auto
elif [[ $DISTRO =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then
  D_ARGS=(-d "$DISTRO")
else
  cx_note "invalid option wsl_distro='$DISTRO' (expected auto or a distribution name)"
  cx_signal FORWARD_FAILED 40 ""
fi

# Step 3: the Windows tools.
if ! command -v wsl.exe >/dev/null 2>&1; then
  cx_note "wsl.exe not found on PATH (is WSL installed?)"
  cx_signal FORWARD_FAILED 40 ""
fi
if ! command -v cygpath >/dev/null 2>&1; then
  cx_note "cygpath not found: forwarding needs Git for Windows' Git Bash"
  cx_signal HOST_UNSUPPORTED 43 ""
fi

# Step 4: the transport directory.
FWD="$(mktemp -d "${TMPDIR:-/tmp}/cx-fwd.XXXXXXXX" 2>/dev/null)" || FWD=""
if [ -z "$FWD" ] || [ ! -d "$FWD" ]; then
  cx_note "cannot create a temporary directory under ${TMPDIR:-/tmp}"
  cx_signal FORWARD_FAILED 40 ""
fi
WPID=""
TPID=""
cleanup() {
  { exec 4>&-; } 2>/dev/null
  if [ "${CX_DEBUG:-}" = 1 ]; then
    return 0
  fi
  [ -n "$FWD" ] && rm -rf "$FWD"
}
trap cleanup EXIT
[ "${CX_DEBUG:-}" = 1 ] && cx_note "CX_DEBUG=1: keeping the transport directory $FWD"
FWD_WIN="$(cygpath -w -l "$FWD" 2>/dev/null)" || FWD_WIN=""
case "$FWD_WIN" in
  ""|*$'\r'*|*$'\n'*)
    cx_note "cygpath cannot map the transport directory $FWD"
    cx_signal FORWARD_FAILED 40 "" ;;
esac

# The option variables that may cross (derived from CX_OPT_DEFAULTS).
OPT_VARS=()
for _n in "${CX_OPT_NAMES[@]}"; do OPT_VARS+=("CLAUDE_PLUGIN_OPTION_${_n^^}"); done
unset _n

exec 3<&0

# Step 5: argv, env and meta, written as bytes.
write_transport() {
  local inst="$1" n cwd_win ws ws_win=""
  : > "$FWD/argv" || return 1
  if [ "${#ARGS[@]}" -gt 0 ]; then
    printf '%s\0' "${ARGS[@]}" > "$FWD/argv" || return 1
  fi
  : > "$FWD/env" || return 1
  for n in CX_WORKER CX_DEBUG NO_COLOR CX_SLOT_WAIT_SECS "${OPT_VARS[@]}"; do
    if [ -n "${!n+x}" ]; then
      printf '%s=%s\0' "$n" "${!n}" >> "$FWD/env" || return 1
    fi
  done
  cwd_win="$(cygpath -w -l "$PWD" 2>/dev/null)" || cwd_win=""
  case "$cwd_win" in
    *$'\r'*|*$'\n'*)
      cx_note "the current directory's Windows path contains CR or LF: $PWD"
      cx_signal PATH_UNMAPPABLE 42 "" ;;
  esac
  ws="$(cx_win_settings_file)"
  if [ -f "$ws" ]; then
    ws_win="$(cygpath -w -l "$ws" 2>/dev/null)" || ws_win=""
    case "$ws_win" in *$'\r'*|*$'\n'*) ws_win="" ;; esac
  fi
  {
    printf 'v=1\n'
    printf 'cmd=%s\n' "$CMD"
    printf 'version=%s\n' "$CX_VERSION"
    printf 'caller=gitbash\n'
    printf 'distro=%s\n' "$DISTRO"
    printf 'cwd_win=%s\n' "$cwd_win"
    printf 'win_settings=%s\n' "$ws_win"
    printf 'installed=%s\n' "$inst"
  } > "$FWD/meta"
}

# wait_bounded PID SECS: waits for PID, giving up after SECS seconds.
wait_bounded() {
  local pid="$1" n=$(( $2 * 10 ))
  [ -n "$pid" ] || return 0
  while [ "$n" -gt 0 ] && kill -0 "$pid" 2>/dev/null; do
    sleep 0.1
    n=$((n - 1))
  done
  wait "$pid" 2>/dev/null
  return 0
}

# Step 7: cancellation.
on_signal() {
  trap '' INT TERM HUP
  local pid="" i
  if [ -f "$FWD/pgid" ]; then
    pid="$(< "$FWD/pgid")"
    pid="${pid//[[:space:]]/}"
    if [[ $pid =~ ^[0-9]+$ ]]; then
      cx_timeout 10 env MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' WSL_UTF8=1 \
        wsl.exe "${D_ARGS[@]+"${D_ARGS[@]}"}" --exec /bin/kill -TERM -- "-$pid" \
        </dev/null >/dev/null 2>&1
    fi
  fi
  if [ -n "$WPID" ]; then
    kill -TERM "$WPID" 2>/dev/null
    for ((i = 0; i < 50; i++)); do
      kill -0 "$WPID" 2>/dev/null || break
      sleep 0.1
    done
  fi
  { exec 4>&-; } 2>/dev/null
  wait_bounded "$TPID" 2
  cx_signal CANCELLED 130 ""
}
trap on_signal INT TERM HUP

# Step 6: wsl.exe as a background child, waited for.
RC=0
run_wsl() {
  local rc
  local -a cmdline=(wsl.exe "${D_ARGS[@]+"${D_ARGS[@]}"}" --cd '~' --exec /bin/bash --noprofile --norc
    ".conductor/runtime/$CX_VERSION/scripts/host/wsl-entry.sh")
  rm -f "$FWD/started" "$FWD/pgid" "$FWD/pgid.tmp" "$FWD/wsl.err"
  [ "${CX_DEBUG:-}" = 1 ] && cx_note "wsl.exe argv: $(printf '%q ' "${cmdline[@]}")"
  exec 4> >(tee "$FWD/wsl.err" >&2)
  TPID=$!
  WSL_UTF8=1 MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' CX_FWD_WIN="$FWD_WIN" WSLENV=CX_FWD_WIN \
    "${cmdline[@]}" <&3 2>&4 &
  WPID=$!
  while :; do
    wait "$WPID"
    rc=$?
    if [ "$rc" -gt 128 ] && kill -0 "$WPID" 2>/dev/null; then
      continue
    fi
    break
  done
  WPID=""
  exec 4>&-
  wait_bounded "$TPID" 5
  TPID=""
  RC=$rc
}

# relay FILE [keep_signal]: prints FILE (decoded) to stderr, minus CX_SIGNAL lines unless asked.
relay() {
  local line keep="${2:-0}"
  [ -s "$1" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$keep" = 0 ] && [ "${line#CX_SIGNAL }" != "$line" ]; then
      continue
    fi
    printf '%s\n' "$line" >&2
  done < <(cx_decode_wsl < "$1")
}

# The bootstrap install (DESIGN 7.5): stage the six runtime directories, strip CRs, and feed
# the installer to bash -s inside WSL, so no path crosses the command line.
INSTALL_RC=0
bootstrap_install() {
  local stage="$FWD/stage" d f stage_win
  local -a files=()
  rm -rf "$stage"
  mkdir -p "$stage" || return 2
  for d in "${CX_RUNTIME_DIRS[@]}"; do
    [ -e "$CX_ROOT/$d" ] || continue
    cp -R "$CX_ROOT/$d" "$stage/$d" || return 2
  done
  shopt -s globstar dotglob nullglob
  for f in "$stage"/**; do
    [ -f "$f" ] && [ ! -L "$f" ] && files+=("$f")
  done
  shopt -u globstar dotglob nullglob
  if [ "${#files[@]}" -gt 0 ]; then
    sed -i 's/\r$//' "${files[@]}" || return 2
  fi
  [ -f "$stage/scripts/host/install-runtime.sh" ] || return 2
  stage_win="$(cygpath -w -l "$stage" 2>/dev/null)" || return 2
  CX_STAGE_WIN="$stage_win" WSLENV=CX_STAGE_WIN WSL_UTF8=1 MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' \
    wsl.exe "${D_ARGS[@]+"${D_ARGS[@]}"}" --cd '~' --exec /bin/bash --noprofile --norc -s \
    < "$stage/scripts/host/install-runtime.sh" > "$FWD/install.out" 2> "$FWD/install.err"
  INSTALL_RC=$?
  return "$INSTALL_RC"
}

if [ "$MODE" = install ]; then
  bootstrap_install
  rc=$?
  [ -s "$FWD/install.out" ] && cx_decode_wsl < "$FWD/install.out"
  relay "$FWD/install.err" 1
  if [ "$rc" -ne 0 ]; then
    if [ -s "$FWD/install.err" ] && cx_decode_wsl < "$FWD/install.err" | grep -q '^CX_SIGNAL '; then
      exit "$rc"
    fi
    first="$(cx_decode_wsl < "$FWD/install.err" 2>/dev/null | awk 'NF { print; exit }')"
    cx_note "the runtime install did not run (rc $rc): ${first:-no message}"
    cx_signal FORWARD_FAILED 40 ""
  fi
  exit 0
fi

INSTALLED=0
while :; do
  write_transport "$INSTALLED" || { cx_note "cannot write the transport files in $FWD"; cx_signal FORWARD_FAILED 40 ""; }
  run_wsl
  # Step 8: classification; every failure has exactly one CX_SIGNAL owner.
  if [ -f "$FWD/started" ]; then
    if [ "$RC" -eq 1 ]; then
      msg="$(cx_decode_wsl < "$FWD/wsl.err" \
        | awk 'NF { l[++n] = $0 } END { for (i = (n > 5 ? n - 4 : 1); i <= n; i++) print l[i] }' \
        | grep -E -m1 'Wsl/[A-Za-z0-9_/]+|instance has terminated')"
      if [ -n "$msg" ]; then
        cx_note "WSL stopped while the command ran: $msg"
        cx_signal FORWARD_FAILED 40 ""
      fi
    fi
    exit "$RC"
  fi
  dec="$(cx_decode_wsl < "$FWD/wsl.err" 2>/dev/null)"
  if [ "$RC" -eq 127 ] && [[ $dec == *wsl-entry.sh* ]]; then
    if [ "$INSTALLED" = 1 ] || [ "${CX_NO_AUTO_INSTALL:-}" = 1 ]; then
      cx_note "no conductor runtime $CX_VERSION in WSL (~/.conductor/runtime/$CX_VERSION)"
      cx_signal RUNTIME_MISSING 41 ""
    fi
    cx_note "installing the conductor runtime $CX_VERSION into WSL (first use)"
    if ! bootstrap_install; then
      relay "$FWD/install.err" 0
      cx_note "the runtime install failed (rc $INSTALL_RC)"
      cx_signal RUNTIME_MISSING 41 ""
    fi
    relay "$FWD/install.err" 0
    INSTALLED=1
    continue
  fi
  first="$(printf '%s\n' "$dec" | awk 'NF { print; exit }')"
  cx_note "wsl.exe failed (rc $RC): ${first:-no message}"
  cx_signal FORWARD_FAILED 40 ""
done
