#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# scripts/adapters/claude.sh - the claude lane (docs/DESIGN.md section 15.2): Claude's own pool.
# By default no process runs: the lane is dispatched to a Claude subagent of the calling
# session, working in the conductor's worktree, and cx-run --finish <id> runs the post-run
# steps afterwards. --headless runs a claude -p worker instead.
#
# Usage: claude.sh probe|argv|run|parse [OPTIONS]   (the options of scripts/lib/adapter.sh)
#        claude.sh -h|--help | --version
#
#   dispatch (default): run prints {"dispatch": "claude-subagent", "id", "worktree",
#                  "host_path", "prompt", "effort", "task_file", "cx_route"} on stdout (also in
#                  $OUT/claude.dispatch.json); parse gives status "dispatched", exit 0. The
#                  prompt names the run's cx-route by its path ($CX_HOME/routes/<id>/cx-route:
#                  the subagent's PATH is the session's).
#   --headless:    cd <WT> && <claude> -p --model claude-opus-5-5 --effort <E> --output-format
#                  json --session-id <uuid> --permission-mode acceptEdits --settings
#                  $OUT/cx-worker.json -- <prompt>; cx-worker.json = templates/cx-worker.json (allow
#                  cx-route and git status; deny every agent CLI, sibling wrapper and cx-* bin)
#                  plus Bash(<cmd>) per --allow.
#                  Environment: the worker environment with every name of CLAUDE_WORKER_SCRUB
#                  (the hosted-session, entrypoint and effort variables of DESIGN section 15
#                  build order item 2) and every CLAUDE_CODE_REMOTE* / CLAUDE_CODE_SESSION_*
#                  unset: a nested claude that inherits a hosted entrypoint can be refused login
#                  [docs-only]. They are only unset for the child, never read.
#                  --safe-mode is not passed (DESIGN section 20 item 18).
#   effort: low|medium|high|xhigh|max (the claude lane is max's home).
#   probe (free):  claude --version (recorded only), claude auth status --json and claude --help
#                  (the flag contract: 26 when it lacks a flag of the argv; headless only).
#   parse:         JSON result / session_id / usage / modelUsage [assumption, section 20 item
#                  27]; no pool slot (Claude's own pool has no cap here).
#
# Exit codes: as scripts/lib/adapter.sh (0, 1, 2, 11, 13, 26, 130).

set -uo pipefail
unset CDPATH
CX_ADAPTER=claude
CX_PROG=adapter-claude
# shellcheck source=../lib/adapter.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/adapter.sh"

CLAUDE_WORKER_SCRUB=(CLAUDE_CODE_ENTRYPOINT CLAUDE_CODE_ENVIRONMENT_KIND CLAUDE_CODE_CHILD_SESSION CLAUDE_CODE_SESSION_ID CLAUDECODE AI_AGENT CLAUDE_EFFORT CLAUDE_CODE_REMOTE CLAUDE_PLUGIN_ROOT CLAUDE_PROJECT_DIR)  # unset for the child only, never read (P62)

lane_setup() {
  local v
  CXA_EXECUTOR=claude CXA_LANE=claude CXA_POOL=claude-plan CXA_SLOT_POOL=""
  CXA_MODEL="${A_MODEL:-claude-opus-5-5}"
  CXA_EFFORT="${A_EFFORT:-high}"
  case "$CXA_EFFORT" in low|medium|high|xhigh|max) ;; *) cx_usage_error "invalid --effort '$CXA_EFFORT'" ;; esac
  [[ $CXA_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*(\[[A-Za-z0-9]+\])?$ ]] || cx_usage_error "invalid model '$CXA_MODEL'"
  CXA_ENV=()
  if [ -z "$A_HEADLESS" ]; then
    CXA_VARIANT=dispatch CXA_BIN="" CXA_CLI="" CXA_KEEP_MARK=1   # the subagent writes after run returns: cx-run --finish clears the mark
    return 0
  fi
  CXA_VARIANT=headless
  cxa_need_bin CXR_BIN_claude claude
  CXA_BIN="$CXR_BIN_claude" CXA_CLI="$CXR_BIN_claude"
  cxa_worker_env - || cxa_fail 2 FAILED "cannot build the worker shim set"
  cxa_unset "${CLAUDE_WORKER_SCRUB[@]}"
  for v in $(compgen -e); do
    case "$v" in CLAUDE_CODE_REMOTE*|CLAUDE_CODE_SESSION_*) cxa_unset "$v" ;; esac
  done
}

lane_argv() {
  local wt="${A_WT:-$PWD}" host=""
  if [ "$CXA_VARIANT" = dispatch ]; then
    host="$(cx_host_path "$wt" 2>/dev/null)" || host=""
    local route p="$A_PROMPT"
    route="$(cxa_route_bin)/cx-route"
    [ "$p" != "$CX_TASK_PROMPT" ] || p="${p//as cx-route <name> (cx-route alone lists them)/as $route <name> (alone it lists them)}"
    A_PROMPT="$p"
    CXA_DISPATCH="$(cxa_py obj dispatch claude-subagent id "$A_ID" worktree "$wt" host_path "${host:-$wt}" \
      prompt "$A_PROMPT" effort "$CXA_EFFORT" task_file "${A_TASK:-$wt/.conductor/task.md}" cx_route "$route")"
    CXA_ARGV=(claude-subagent)
    return 0
  fi
  CXA_SESSION_HINT="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || CXA_SESSION_HINT=""
  [[ $CXA_SESSION_HINT =~ ^[0-9a-f-]{36}$ ]] || CXA_SESSION_HINT="$(cxa_py uuid)"
  # A dry run without --out (cx-run --dry-run) shows the out directory a run of that id would use.
  local out="${A_OUT:-$CXA_HOME/out/${A_ID:-<id>}}"
  CXA_ARGV=("$CXA_BIN" -p --model "$CXA_MODEL" --effort "$CXA_EFFORT" --output-format json
            --session-id "$CXA_SESSION_HINT" --permission-mode acceptEdits --settings "$out/cx-worker.json" -- "$A_PROMPT")
}

lane_exec() {
  local -a al=()
  local c
  if [ "$CXA_VARIANT" = dispatch ]; then
    cxa_py field "$A_OUT/claude.meta.json" dispatch > "$A_OUT/claude.dispatch.json" || { CXA_RC=2; return 0; }
    cp -f -- "$A_OUT/claude.dispatch.json" "$A_OUT/claude.out"
    : > "$A_OUT/claude.err"
    cat "$A_OUT/claude.dispatch.json"
    CXA_RC=0
    return 0
  fi
  for c in "${A_ALLOW[@]+"${A_ALLOW[@]}"}"; do al+=(--allow "$c"); done
  cxa_py worker-settings --template "$CX_ROOT/templates/cx-worker.json" --out "$A_OUT/cx-worker.json" "${al[@]+"${al[@]}"}" \
    || { cx_note "cannot write $A_OUT/cx-worker.json"; CXA_RC=2; return 0; }
  cxa_exec_default
}

lane_probe() {
  local t="$CXA_PROBE_TMP"
  if [ "$CXA_VARIANT" = dispatch ]; then
    cxa_py probe --lane claude --model "$CXA_MODEL" --model-ok true --version-ok true
    return 0
  fi
  cxa_probe_cmd "$t/version" "$CXA_BIN" --version
  cxa_probe_cmd "$t/auth" "$CXA_BIN" auth status --json
  cxa_help claude "$CXA_BIN" --help
  cxa_contract_argv claude
  cxa_py probe --lane claude --bin "$CXA_BIN" --version-out "$t/version" --verified "$CX_VERIFIED_CLAUDE" \
    --auth-out "$t/auth" --auth-kind claude --model "$CXA_MODEL" "${CXA_CONTRACT[@]}"
}

cxa_main "$@"
