#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# cx-wsl - runs one allow-listed WSL-side tool with the conductor's per-tool environment
# (docs/DESIGN.md section 7.7). On Git Bash it forwards into WSL like every cx-* command, so the
# Windows app can delegate before cx-run exists; in WSL or on Linux it runs the tool here.
#
# Usage: cx-wsl TOOL [ARG...]
#        cx-wsl -h|--help | --version
#
# TOOL is one of
#   ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models    the ghcp plugin's wrappers
#   ghcp-cloud                                                        (the Copilot cloud agent, via gh)
#   agy-delegate agy-job                                              the antigravity plugin's
#   agy grok gh git                                                   the CLIs
#   bash                                                              /bin/bash (cx-wsl bash -s < FILE)
# and resolves to an absolute path from the host record $CX_HOME/hosts/<hostkey>.json that
# cx-doctor writes (never from PATH, never a Windows-side path under the automount root; a
# sibling wrapper that moved is re-resolved once from installed_plugins.json). Not allowed:
# copilot (always through ghcp), claude, agy-handoff and agy-media (both always pass --yolo,
# machine-wide) and the cx-* commands (they forward themselves).
#
# Environment: PATH = the sibling wrapper directories, the conductor's bin/, then the record's
# path. Per-tool prefixes (DESIGN section 12.2): ghcp-* unset COPILOT_MODEL COPILOT_ALLOW_ALL
# COPILOT_AUTO_TIER COPILOT_PROVIDER_BASE_URL and set CX_WORKER=1 COPILOT_AUTO_UPDATE=false
# (and GHCP_COPILOT_BIN, when unset, to the recorded copilot binary; and COPILOT_GITHUB_TOKEN,
# when unset, from $CX_HOME/secrets/copilot-token if that is a regular 0600 file you own: the
# keyring route for Copilot logins that wsl.exe cannot reach; never for bash or any other tool);
# agy and agy-* unset GEMINI_API_KEY GOOGLE_API_KEY and set CX_WORKER=1
# AGY_CLI_DISABLE_AUTO_UPDATE=true; grok unsets XAI_API_KEY GROK_SANDBOX and sets CX_WORKER=1
# GROK_DISABLE_AUTOUPDATER=1 GROK_CLAUDE_{HOOKS,SKILLS,MCPS,RULES,AGENTS}_ENABLED=false; gh, git
# and bash run with the environment unchanged (a shell step carries its own prefixes).
# Arguments pass byte for byte: paths in them must be WSL paths (/home/...). For bash -s with a
# step on stdin (not a terminal), a CR before each LF is stripped, with a cx-wsl: note.
#
# Exit codes: the tool's own status (0-255), its stdout and stderr unchanged, no CX_* line
# added. cx-wsl's own failures: 1 usage error (no TOOL, a tool outside the list); 2 FAILED (the
# bash -s step could not be buffered); 13 CLI_MISSING (no host record, or the tool is not
# recorded or not executable: run cx-doctor first, see the note); and from Git Bash forwarding
# 40 FORWARD_FAILED, 41 RUNTIME_MISSING, 42 PATH_UNMAPPABLE (the cwd has no WSL path) and 43
# HOST_UNSUPPORTED (also in a cloud session, before anything runs).

set -uo pipefail
unset CDPATH
CX_PROG=cx-wsl
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/options.sh
. "$HERE/lib/options.sh"

[ $# -gt 0 ] && cx_help_version "$1"
[ $# -gt 0 ] || cx_usage_error "missing TOOL (one of: ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models ghcp-cloud agy-delegate agy-job agy grok gh git bash)"
TOOL="$1"
case "$TOOL" in
  ghcp-delegate|ghcp-job|ghcp-handoff|ghcp-ci-debug|ghcp-models|ghcp-cloud|agy-delegate|agy-job|agy|grok|gh|git|bash) ;;
  *) cx_usage_error "not allowed: $TOOL (allowed: ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models ghcp-cloud agy-delegate agy-job agy grok gh git bash)" ;;
esac
cx_forward_if_needed cx-wsl "$@"
shift

# Executor host: resolve the tool from the host record (section 7.6).
REC="${CX_HOME:-$HOME/.conductor}/hosts/$CX_HOSTKEY.json"
if [ ! -f "$REC" ]; then
  cx_note "no host record $REC: run cx-doctor once (it records where $TOOL lives): from a Windows session it forwards into WSL and records what it finds; for your full interactive PATH run /conductor:doctor in a Claude Code session in WSL, or ~/.conductor/runtime/current/bin/cx-doctor in a WSL terminal (cx-doctor itself is not on a plain terminal's PATH; create that copy once with /conductor:doctor --install-runtime)"
  cx_signal CLI_MISSING 13 "no host record for $CX_HOSTKEY"
fi
if ! cx_py_ok; then
  cx_note "python3 is required on the executor host to read the host record"
  cx_signal CLI_MISSING 13 "python3 missing on the executor host"
fi
RES=()
_cx_source_pathmap
mapfile -t RES < <(cx_py wsl-resolve --record "$REC" --tool "$TOOL" --config-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
  --conductor-bin "$CX_ROOT/bin" --mnt-root "$(_cx_pm_mnt_root "")" 2>/dev/null)
ABS="${RES[0]-}"
NEWPATH="${RES[1]-}"
COPILOT_BIN="${RES[2]-}"
if [ -z "$ABS" ] || [ -z "$NEWPATH" ] || [ ! -x "$ABS" ]; then
  cx_note "$TOOL is not recorded in $REC, or not executable there: install it in WSL, then run cx-doctor from this session, /conductor:doctor in a Claude Code session in WSL, or ~/.conductor/runtime/current/bin/cx-doctor in a WSL terminal (create that copy once with /conductor:doctor --install-runtime)"
  cx_signal CLI_MISSING 13 "$TOOL not found in the host record"
fi

case "$TOOL" in
  ghcp-*)
    # The copilot binary the doctor checked against the pin, unless the caller chose one: an
    # unset or invalid GHCP_COPILOT_BIN makes ghcp fall back to whatever copilot is on PATH.
    [ -n "${GHCP_COPILOT_BIN:-}" ] || [ -z "$COPILOT_BIN" ] || export GHCP_COPILOT_BIN="$COPILOT_BIN"
    # The token route (cx-doctor --login-help copilot, W9): when Copilot's keyring login is
    # unreachable through wsl.exe, a fine-grained PAT in $CX_HOME/secrets/copilot-token signs in
    # this ghcp-* call only. Never a symlink, someone else's file or one others can read.
    TOKF="${CX_HOME:-$HOME/.conductor}/secrets/copilot-token"
    if [ -z "${COPILOT_GITHUB_TOKEN:-}" ] && [ -e "$TOKF" ]; then
      if [ -f "$TOKF" ] && [ ! -L "$TOKF" ] && [ -O "$TOKF" ] && [ "$(stat -c %a -- "$TOKF" 2>/dev/null)" = 600 ]; then
        IFS= read -r TOK < "$TOKF" || true
        TOK="${TOK//[[:space:]]/}"
        [ -n "$TOK" ] && export COPILOT_GITHUB_TOKEN="$TOK"
        unset TOK
      else
        cx_note "ignoring $TOKF: it must be a regular file you own with mode 0600 (chmod 600 it)"
      fi
    fi
    exec env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL \
      PATH="$NEWPATH" CX_WORKER=1 COPILOT_AUTO_UPDATE=false "$ABS" "$@" ;;
  agy|agy-*)
    exec env -u GEMINI_API_KEY -u GOOGLE_API_KEY \
      PATH="$NEWPATH" CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true "$ABS" "$@" ;;
  grok)
    exec env -u XAI_API_KEY -u GROK_SANDBOX PATH="$NEWPATH" CX_WORKER=1 GROK_DISABLE_AUTOUPDATER=1 \
      GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_SKILLS_ENABLED=false GROK_CLAUDE_MCPS_ENABLED=false \
      GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false "$ABS" "$@" ;;
  bash)
    # A shell step (cx-wsl bash -s < FILE) written on the Windows side may come out CRLF: a CR
    # would end up in every word (`. "$HOME/.conductor/out/t1/vars.sh"\r` fails, WT stays
    # empty, `git -C "$WT" add -A` runs in the cwd). Strip a CR before each LF and say so; a
    # terminal on stdin is passed through untouched.
    if [ "${1-}" = -s ] && [ ! -t 0 ]; then
      STEP="$(mktemp "${TMPDIR:-/tmp}/cx-wsl-step.XXXXXXXX")" || cx_signal FAILED 2 "cannot create a temporary file"
      cat > "$STEP" || { rm -f "$STEP"; cx_signal FAILED 2 "cannot read the step on stdin"; }
      if grep -q $'\r$' "$STEP"; then
        sed -i 's/\r$//' "$STEP"
        cx_note "the step on stdin had CRLF line endings; ran it with LF (write step files with LF)"
      fi
      exec 3< "$STEP"
      rm -f "$STEP"
      exec env PATH="$NEWPATH" "$ABS" "$@" <&3 3<&-
    fi
    exec env PATH="$NEWPATH" "$ABS" "$@" ;;
  *)
    exec env PATH="$NEWPATH" "$ABS" "$@" ;;
esac
