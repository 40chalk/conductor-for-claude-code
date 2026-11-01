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
#   agy-delegate agy-job agy-media                                    the antigravity plugin's
#   agy grok gh git                                                   the CLIs
#   bash                                                              /bin/bash (cx-wsl bash -s < FILE)
# and resolves to an absolute path from the host record $CX_HOME/hosts/<hostkey>.json that
# cx-doctor writes (never from PATH; a sibling wrapper that moved is re-resolved once from
# installed_plugins.json). Not allowed: copilot (always through ghcp), claude, agy-handoff (it
# always passes --yolo), ghcp-cloud and the cx-* commands (they forward themselves).
#
# Environment: PATH = the sibling wrapper directories, the conductor's bin/, then the record's
# path. Per-tool prefixes (DESIGN section 12.2): ghcp-* unset COPILOT_MODEL COPILOT_ALLOW_ALL
# COPILOT_AUTO_TIER COPILOT_PROVIDER_BASE_URL and set CX_WORKER=1 COPILOT_AUTO_UPDATE=false
# (and GHCP_COPILOT_BIN, when unset, to the recorded copilot binary);
# agy and agy-* unset GEMINI_API_KEY GOOGLE_API_KEY and set CX_WORKER=1
# AGY_CLI_DISABLE_AUTO_UPDATE=true; grok unsets XAI_API_KEY GROK_SANDBOX and sets CX_WORKER=1
# GROK_DISABLE_AUTOUPDATER=1 GROK_CLAUDE_{HOOKS,SKILLS,MCPS,RULES,AGENTS}_ENABLED=false; gh, git
# and bash run with the environment unchanged (a shell step carries its own prefixes).
# Arguments pass byte for byte: paths in them must be WSL paths (/home/...).
#
# Exit codes: the tool's own status (0-255), its stdout and stderr unchanged, no CX_* line
# added. cx-wsl's own failures: 1 usage error (no TOOL, a tool outside the list); 13
# CLI_MISSING (no host record, or the tool is not recorded or not executable: run cx-doctor
# from a WSL terminal first); and from Git Bash forwarding 40 FORWARD_FAILED, 41
# RUNTIME_MISSING, 42 PATH_UNMAPPABLE (the cwd has no WSL path) and 43 HOST_UNSUPPORTED.

set -uo pipefail
unset CDPATH
CX_PROG=cx-wsl
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/options.sh
. "$HERE/lib/options.sh"

[ $# -gt 0 ] && cx_help_version "$1"
[ $# -gt 0 ] || cx_usage_error "missing TOOL (one of: ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models agy-delegate agy-job agy-media agy grok gh git bash)"
TOOL="$1"
case "$TOOL" in
  ghcp-delegate|ghcp-job|ghcp-handoff|ghcp-ci-debug|ghcp-models|agy-delegate|agy-job|agy-media|agy|grok|gh|git|bash) ;;
  *) cx_usage_error "not allowed: $TOOL (allowed: ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models agy-delegate agy-job agy-media agy grok gh git bash)" ;;
esac
cx_forward_if_needed cx-wsl "$@"
shift

# Executor host: resolve the tool from the host record (section 7.6).
REC="${CX_HOME:-$HOME/.conductor}/hosts/$CX_HOSTKEY.json"
if [ ! -f "$REC" ]; then
  cx_note "no host record $REC: run cx-doctor once from a WSL terminal (it records where $TOOL lives)"
  cx_signal CLI_MISSING 13 "no host record for $CX_HOSTKEY"
fi
if ! cx_py_ok; then
  cx_note "python3 is required on the executor host to read the host record"
  cx_signal CLI_MISSING 13 "python3 missing on the executor host"
fi
RES=()
mapfile -t RES < <(cx_py wsl-resolve --record "$REC" --tool "$TOOL" --config-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
  --conductor-bin "$CX_ROOT/bin" 2>/dev/null)
ABS="${RES[0]-}"
NEWPATH="${RES[1]-}"
COPILOT_BIN="${RES[2]-}"
if [ -z "$ABS" ] || [ -z "$NEWPATH" ] || [ ! -x "$ABS" ]; then
  cx_note "$TOOL is not recorded in $REC, or not executable there: run cx-doctor from a WSL terminal"
  cx_signal CLI_MISSING 13 "$TOOL not found in the host record"
fi

case "$TOOL" in
  ghcp-*)
    # The copilot binary the doctor checked against the pin, unless the caller chose one: an
    # unset or invalid GHCP_COPILOT_BIN makes ghcp fall back to whatever copilot is on PATH.
    [ -n "${GHCP_COPILOT_BIN:-}" ] || [ -z "$COPILOT_BIN" ] || export GHCP_COPILOT_BIN="$COPILOT_BIN"
    exec env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL \
      PATH="$NEWPATH" CX_WORKER=1 COPILOT_AUTO_UPDATE=false "$ABS" "$@" ;;
  agy|agy-*)
    exec env -u GEMINI_API_KEY -u GOOGLE_API_KEY \
      PATH="$NEWPATH" CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true "$ABS" "$@" ;;
  grok)
    exec env -u XAI_API_KEY -u GROK_SANDBOX PATH="$NEWPATH" CX_WORKER=1 GROK_DISABLE_AUTOUPDATER=1 \
      GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_SKILLS_ENABLED=false GROK_CLAUDE_MCPS_ENABLED=false \
      GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false "$ABS" "$@" ;;
  *)
    exec env PATH="$NEWPATH" "$ABS" "$@" ;;
esac
