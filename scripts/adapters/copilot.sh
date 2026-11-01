#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# scripts/adapters/copilot.sh - the Copilot lanes (docs/DESIGN.md section 15.2): copilot-opus,
# copilot-fusion, copilot-gpt. Copilot always runs through the user's ghcp plugin
# (ghcp-delegate, never raw copilot); a background run is cx-job around cx-run, not ghcp-job.
#
# Usage: copilot.sh probe|argv|run|parse [OPTIONS]   (the options of scripts/lib/adapter.sh)
#        copilot.sh -h|--help | --version
#
#   argv (write):  <ghcp-delegate> --model <copilot_opus_id> --effort <E> --dir <WT> --write
#                  --allow-shell <cmd>... --timeout <T>s --digest -- <prompt>
#   Fusion:        --fusion standard|max instead of --model/--effort
#   read/review:   no --write; --add-dir <DIR> for each --add-dir (the diff's directory)
#   effort: low|medium|high, xhigh only with option copilot_xhigh_ok=true, never max (#5149).
#   environment:   the worker environment, unset COPILOT_ALLOW_ALL COPILOT_AUTO_TIER
#                  COPILOT_MODEL COPILOT_PROVIDER_BASE_URL and GH_TOKEN/GITHUB_TOKEN (except the
#                  one the host record names as copilot_token_env), COPILOT_HOME as recorded;
#                  GHCP_COPILOT_BIN=<the recorded copilot>, GHCP_USAGE_LOG=$CX_HOME/raw-usage.log;
#                  COPILOT_GITHUB_TOKEN from $CX_HOME/secrets/copilot-token (0600) at run time.
#   probe (free):  copilot --version (pin 1.0.105), then ghcp-models --json only on the pin.
#   parse:         answer = stdout; GHCP_SESSION / GHCP_USAGE / GHCP_DENIED / GHCP_FALLBACK;
#                  served model = every models_used[].model (Fusion: any GHCP_FALLBACK -> 21);
#                  copilot#5149 (xhigh, >= 30,000 output tokens, empty answer) -> 2; ghcp's
#                  exits pass through. Slot pool: copilot (cap_copilot).
#
# Exit codes: as scripts/lib/adapter.sh (0, 1, 2, 11, 13, 14, 26, 28, 130).

set -uo pipefail
unset CDPATH
CX_ADAPTER=copilot
CX_PROG=adapter-copilot
# shellcheck source=../lib/adapter.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/adapter.sh"

lane_setup() {
  CXA_EXECUTOR=copilot CXA_POOL=copilot-credits CXA_SLOT_POOL=copilot CXA_VARIANT=wrapper
  CXA_MODEL="${A_MODEL:-${CXA_OPT[copilot_opus_id]}}"
  CXA_EFFORT="${A_EFFORT:-high}"
  case "$CXA_EFFORT" in
    low|medium|high) ;;
    xhigh) cx_bool "${CXA_OPT[copilot_xhigh_ok]}" || cx_usage_error "Copilot xhigh needs option copilot_xhigh_ok=true (the #5149 check)" ;;
    max) cx_usage_error "effort max never leaves Claude (Copilot #5149)" ;;
    *) cx_usage_error "invalid --effort '$CXA_EFFORT'" ;;
  esac
  if [ -n "$A_FUSION" ]; then
    case "$A_FUSION" in standard|max) ;; *) cx_usage_error "--fusion must be standard or max" ;; esac
    CXA_LANE=copilot-fusion CXA_MODEL=fusion CXA_EFFORT=""
  else
    case "$CXA_MODEL" in
      claude-opus*) CXA_LANE=copilot-opus ;;
      gpt-*) CXA_LANE=copilot-gpt ;;
      *) CXA_LANE=copilot ;;
    esac
  fi
  [[ $CXA_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] || cx_usage_error "invalid Copilot model id '$CXA_MODEL'"
  CXA_BIN="${CXR_BIN_ghcp_delegate:-}" CXA_CLI="${CXR_BIN_copilot:-}"
  cxa_need_bin CXR_BIN_ghcp_delegate "ghcp-delegate (the ghcp plugin)"
  # Never let ghcp fall back to whatever copilot is on PATH (a paid, unchecked binary).
  cxa_need_bin CXR_BIN_copilot "copilot"
  lane_env
}

lane_env() {
  local v keep="${CXR_COPILOT_TOKEN_ENV:-}"
  CXA_ENV=()
  cxa_worker_env - || cxa_fail 2 FAILED "cannot build the worker shim set"
  cxa_unset COPILOT_ALLOW_ALL COPILOT_AUTO_TIER COPILOT_MODEL COPILOT_PROVIDER_BASE_URL
  for v in GH_TOKEN GITHUB_TOKEN; do [ "$v" = "$keep" ] || cxa_unset "$v"; done
  if [ "${CXR_COPILOT_HOME_SET:-0}" = 1 ]; then cxa_set COPILOT_HOME "$CXR_COPILOT_HOME"; else cxa_unset COPILOT_HOME; fi
  cxa_set GHCP_COPILOT_BIN "$CXA_CLI"
  cxa_set GHCP_USAGE_LOG "$CXA_HOME/raw-usage.log"
  cxa_copilot_token
}

# The ghcp-delegate arguments after the binary (shared by argv and the dry run's --print-command).
copilot_args() {
  local c d
  CPA=()
  if [ -n "$A_FUSION" ]; then CPA+=(--fusion "$A_FUSION"); else CPA+=(--model "$CXA_MODEL" --effort "$CXA_EFFORT"); fi
  CPA+=(--dir "${A_WT:-$PWD}")
  [ "$A_MODE" = write ] && CPA+=(--write)
  for d in "${A_ADD[@]+"${A_ADD[@]}"}"; do CPA+=(--add-dir "$d"); done
  for c in "${A_ALLOW[@]+"${A_ALLOW[@]}"}"; do CPA+=(--allow-shell "$c"); done
  # "--" ends ghcp-delegate's options: a prompt that starts with "-" stays the prompt.
  CPA+=(--timeout "${A_TIMEOUT}s" --digest -- "$A_PROMPT")
}

lane_argv() {
  copilot_args
  CXA_ARGV=("$CXA_BIN" "${CPA[@]}")
  CXA_GRACE=60   # ghcp-delegate's own --timeout fires first
}

lane_dry_extra() {
  local line
  copilot_args
  cxa_env_args
  line="$(cd -- "$CXA_HOME" 2>/dev/null && env "${CXA_ENVARGS[@]}" "$CXA_BIN" --print-command "${CPA[@]}" 2>/dev/null </dev/null)" \
    || line="(ghcp-delegate --print-command failed)"
  printf 'copilot argv (ghcp-delegate --print-command): %s\n' "$line"
}

lane_probe() {
  local t="$CXA_PROBE_TMP" ver mrc="" ok=() pin="$CX_PIN_COPILOT"
  cxa_probe_cmd "$t/version" "$CXA_CLI" --version
  ver="$(cx_py semver "$(cat "$t/version")" 2>/dev/null)"
  if [ "$ver" = "$pin" ]; then
    # Free only on the pinned version (the invalid-model probe, DESIGN section 1.2, D16).
    cxa_probe_cmd "$t/models" "${CXR_BIN_ghcp_models:-/nonexistent}" --json
    mrc=$?
    ok=(--models-cli copilot --models-out "$t/models" --models-rc "$mrc")
  fi
  cxa_py probe --lane copilot --bin "$CXA_CLI" --wrapper "$CXA_BIN" --version-out "$t/version" \
    --pin "$pin" --model "$CXA_MODEL" "${ok[@]+"${ok[@]}"}"
}

cxa_main "$@"
