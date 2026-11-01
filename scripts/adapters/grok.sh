#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# scripts/adapters/grok.sh - the grok lane (docs/DESIGN.md section 15.2): raw grok 1.0.70,
# never the grok-build bridge plugin. Every flag below appears in the captured grok 1.0.70 help
# (tests/fixtures/real/grok/help.txt).
#
# Usage: grok.sh probe|argv|run|parse [OPTIONS]   (the options of scripts/lib/adapter.sh)
#        grok.sh -h|--help | --version
#
#   argv (write):  <grok> --prompt-file <WT>/.conductor/prompt.txt -m <grok_bulk_model>
#                  --effort <E> --cwd <WT> -s <uuid> --output-format json
#                  --sandbox <grok_sandbox_profile> --permission-mode acceptEdits
#                  --allow 'Bash(<cmd>)'... --allow 'Bash(git status)' --allow 'Bash(git diff)'
#                  --no-subagents --max-turns 60
#                  (--subagents: no --no-subagents, GROK_MAX_CONCURRENT_SUBAGENTS=4)
#   read/review:   --sandbox read-only --always-approve --no-subagents --json-schema <schema>
#                  (default: [{file, line, why}] for read, [{file, line, severity, issue}] for review)
#   effort: low|medium|high|xhigh (never max).
#   environment:   the worker environment, GROK_CLAUDE_{HOOKS,SKILLS,MCPS,RULES,AGENTS}_ENABLED=false,
#                  XAI_API_KEY and GROK_SANDBOX unset.
#   probe (free):  grok --version (pin 1.0.70), grok models (the -m id must be listed: an
#                  unlisted id silently drops --effort).
#   run:           writes the prompt file, runs grok, then grok usage <uuid> (free).
#   parse:         JSON text / sessionId / modelUsage / usage / stopReason [docs-only]; any
#                  "permission required:" on stderr -> 15; modelUsage keys other than the model
#                  -> 21. Slot pool: grok (cap_grok).
#
# Exit codes: as scripts/lib/adapter.sh (0, 1, 2, 11, 13, 14, 26, 28, 130).

set -uo pipefail
unset CDPATH
CX_ADAPTER=grok
CX_PROG=adapter-grok
# shellcheck source=../lib/adapter.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/adapter.sh"

GROK_READ_SCHEMA='{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"why":{"type":"string"}},"required":["file","line","why"]}}'
GROK_REVIEW_SCHEMA='{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"severity":{"type":"string"},"issue":{"type":"string"}},"required":["file","line","severity","issue"]}}'

lane_setup() {
  CXA_EXECUTOR=grok CXA_LANE=grok CXA_POOL=xai-weekly CXA_SLOT_POOL=grok CXA_VARIANT=raw
  CXA_MODEL="${A_MODEL:-${CXA_OPT[grok_bulk_model]}}"
  CXA_EFFORT="${A_EFFORT:-${CXA_OPT[grok_bulk_effort]}}"
  case "$CXA_EFFORT" in low|medium|high|xhigh) ;; max) cx_usage_error "effort max never leaves Claude" ;; *) cx_usage_error "invalid --effort '$CXA_EFFORT'" ;; esac
  [[ $CXA_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] || cx_usage_error "invalid grok model id '$CXA_MODEL'"
  CXA_BIN="${CXR_BIN_grok:-}" CXA_CLI="${CXR_BIN_grok:-}"
  cxa_need_bin CXR_BIN_grok grok
  CXA_ENV=()
  cxa_worker_env - || cxa_fail 2 FAILED "cannot build the worker shim set"
  cxa_unset XAI_API_KEY GROK_SANDBOX
  local v
  for v in HOOKS SKILLS MCPS RULES AGENTS; do cxa_set "GROK_CLAUDE_${v}_ENABLED" false; done
  [ -z "$A_SUBAGENTS" ] || cxa_set GROK_MAX_CONCURRENT_SUBAGENTS 4
}

lane_argv() {
  local c wt="${A_WT:-$PWD}" schema="$A_SCHEMA"
  CXA_SESSION_HINT="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || CXA_SESSION_HINT=""
  [[ $CXA_SESSION_HINT =~ ^[0-9a-f-]{36}$ ]] || CXA_SESSION_HINT="$(cxa_py uuid)"
  [[ $CXA_SESSION_HINT =~ ^[0-9a-f-]{36}$ ]] || cxa_fail 2 FAILED "cannot generate a session uuid"
  CXA_ARGV=("$CXA_BIN" --prompt-file "$wt/.conductor/prompt.txt" -m "$CXA_MODEL" --effort "$CXA_EFFORT"
            --cwd "$wt" -s "$CXA_SESSION_HINT" --output-format json)
  if [ "$A_MODE" = write ]; then
    CXA_ARGV+=(--sandbox "${CXA_OPT[grok_sandbox_profile]}" --permission-mode acceptEdits)
    for c in "${A_ALLOW[@]+"${A_ALLOW[@]}"}"; do CXA_ARGV+=(--allow "Bash($c)"); done
    CXA_ARGV+=(--allow 'Bash(git status)' --allow 'Bash(git diff)')
    [ -n "$A_SUBAGENTS" ] || CXA_ARGV+=(--no-subagents)
  else
    if [ -z "$schema" ]; then
      if [ "$A_MODE" = review ]; then schema="$GROK_REVIEW_SCHEMA"; else schema="$GROK_READ_SCHEMA"; fi
    fi
    A_SCHEMA="$schema"
    CXA_ARGV+=(--sandbox read-only --always-approve --no-subagents --json-schema "$schema")
  fi
  CXA_ARGV+=(--max-turns 60)
}

lane_exec() {
  local wt="${A_WT:-$PWD}"
  if ! { mkdir -p -- "$wt/.conductor" && printf '%s\n' "$A_PROMPT" > "$wt/.conductor/prompt.txt"; }; then
    CXA_RC=2
    cx_note "cannot write $wt/.conductor/prompt.txt"
    return 0
  fi
  cxa_exec_default
}

lane_postrun() {
  [ -n "${CXA_SESSION_HINT:-}" ] || return 0
  cxa_probe_cmd "$A_OUT/grok.usage.txt" "$CXA_BIN" usage "$CXA_SESSION_HINT" || true
}

lane_probe() {
  local t="$CXA_PROBE_TMP" mrc
  cxa_probe_cmd "$t/version" "$CXA_BIN" --version
  cxa_probe_cmd "$t/models" "$CXA_BIN" models
  mrc=$?
  cxa_py probe --lane grok --bin "$CXA_BIN" --version-out "$t/version" --pin "$CX_PIN_GROK" \
    --models-cli grok --models-out "$t/models" --models-rc "$mrc" --model "$CXA_MODEL"
}

cxa_main "$@"
