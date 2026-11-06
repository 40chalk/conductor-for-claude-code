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
#                  --allow-shell cx-route --allow-shell 'git status' --timeout <T>s --digest -- <prompt>
#                  Copilot approves a shell call by its command name (and git's first-level
#                  subcommand), so shell(python3 -m unittest ...) never matches and shell(python3)
#                  would allow python3 -c: the routes commands run through the run's cx-route
#                  (ghcp turns each --allow-shell into --allow-tool 'shell(<it>)'). Never
#                  shell(python3), never shell(:*), and not git diff, log or show either: Copilot
#                  approves git by its first-level subcommand, so shell(git diff) would allow git
#                  diff --output=<path> (a write) and --no-index (a read) of any file.
#   Fusion:        --fusion standard|max instead of --model/--effort
#   read/review:   no --write; --add-dir <DIR> for each --add-dir (the diff's directory); the same
#                  --allow-shell list
#   effort: low|medium|high, xhigh only with option copilot_xhigh_ok=true, never max (#5149).
#   environment:   the worker environment, unset COPILOT_ALLOW_ALL COPILOT_AUTO_TIER
#                  COPILOT_MODEL COPILOT_PROVIDER_BASE_URL and GH_TOKEN/GITHUB_TOKEN (except the
#                  one the host record names as copilot_token_env), COPILOT_HOME as recorded;
#                  GHCP_COPILOT_BIN=<the recorded copilot>, GHCP_USAGE_LOG=$CX_HOME/raw-usage.log;
#                  COPILOT_GITHUB_TOKEN from $CX_HOME/secrets/copilot-token (0600) at run time;
#                  --fusion runs only: CLAUDE_PLUGIN_OPTION_FUSION_FALLBACK=off (ghcp then exits
#                  14, free, on a Fusion refusal instead of re-running on plain auto, billed,
#                  an answer conductor discards); COPILOT_CLI_ENABLED_FEATURE_FLAGS untouched.
#   probe (free):  copilot --version (recorded only; last verified 1.0.105), ghcp-models --json
#                  (ghcp's own free catalog probe: login and model), and the flag contract:
#                  ghcp-delegate --help for the argv, copilot --help for the Copilot argv
#                  ghcp-delegate --print-command builds from it (free), copilot help permissions
#                  for the shell() and write() kinds: 26 when one is missing.
#   parse:         answer = stdout; GHCP_SESSION / GHCP_USAGE / GHCP_DENIED / GHCP_FALLBACK;
#                  served model = every models_used[].model (Fusion: any GHCP_FALLBACK that still
#                  appears, from a ghcp that ignores the option -> 21; a refusal -> ghcp's 14);
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
  # A Fusion run: ghcp's option fusion_fallback (default on) re-runs a refused Fusion task once
  # on plain auto, which is billed, and conductor discards that answer (GHCP_FALLBACK on a Fusion
  # lane is 21). Off for --fusion runs only (ghcp's options loader lets the environment win over
  # settings.json): a refusal before any model call then ends as ghcp's free exit 14 and the next
  # lane follows. Not a spend cap. COPILOT_CLI_ENABLED_FEATURE_FLAGS is left alone: ghcp merges
  # the feature flags its headless Fusion needs itself.
  [ -z "$A_FUSION" ] || cxa_set CLAUDE_PLUGIN_OPTION_FUSION_FALLBACK off
  cxa_copilot_token
}

# The shell commands a Copilot run may approve (decision 5 of the 2026-11-06 probes, narrowed): the
# run's cx-route and git status; the routes commands themselves only through cx-route. git diff,
# log and show stay out: Copilot approves git by its first-level subcommand, and their
# --output=<path> writes any file (diff --no-index reads any file).
COPILOT_SHELL=(cx-route 'git status')

# The ghcp-delegate arguments after the binary (shared by argv and the dry run's --print-command).
copilot_args() {
  local c d
  CPA=()
  if [ -n "$A_FUSION" ]; then CPA+=(--fusion "$A_FUSION"); else CPA+=(--model "$CXA_MODEL" --effort "$CXA_EFFORT"); fi
  CPA+=(--dir "${A_WT:-$PWD}")
  [ "$A_MODE" = write ] && CPA+=(--write)
  for d in "${A_ADD[@]+"${A_ADD[@]}"}"; do CPA+=(--add-dir "$d"); done
  for c in "${COPILOT_SHELL[@]}"; do CPA+=(--allow-shell "$c"); done
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
  local t="$CXA_PROBE_TMP" mrc
  cxa_probe_cmd "$t/version" "$CXA_CLI" --version
  # ghcp's own catalog probe (an invalid --model, refused before any model call; ghcp-models
  # documents it as free): login and the model list, whatever the Copilot version.
  cxa_probe_cmd "$t/models" "${CXR_BIN_ghcp_models:-/nonexistent}" --json
  mrc=$?
  cxa_help ghcp "$CXA_BIN" --help
  cxa_contract_argv ghcp
  cxa_help copilot "$CXA_CLI" --help
  cxa_help perms "$CXA_CLI" help permissions
  copilot_print "$t/print"
  CXA_CONTRACT+=(--argv-shell "copilot=$t/print" --need "perms=shell(")
  [ "$A_MODE" != write ] || CXA_CONTRACT+=(--need "perms=write(")
  cxa_py probe --lane copilot --bin "$CXA_CLI" --wrapper "$CXA_BIN" --version-out "$t/version" \
    --verified "$CX_VERIFIED_COPILOT" --model "$CXA_MODEL" --models-cli copilot --models-out "$t/models" \
    --models-rc "$mrc" "${CXA_CONTRACT[@]}"
}

# copilot_print FILE: ghcp-delegate --print-command of this run's arguments (free: nothing runs),
# with --dir the probe directory (the worktree may not exist yet), into FILE.
copilot_print() {
  local A_WT="$CXA_HOME/probe"
  copilot_args
  cxa_probe_cmd "$1.all" "$CXA_BIN" --print-command "${CPA[@]}"
  grep -m 1 '^/' "$1.all" > "$1" 2>/dev/null
}

cxa_main "$@"
