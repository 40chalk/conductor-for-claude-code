#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR disable=SC2034  # sourced library: callers read the TK_* variables
# scripts/lib/taskfile.sh - the task contract for cx-run (docs/DESIGN.md section 6.4). Sourced,
# never run; executor host only (python3 for the JSON).
#
# $OUT/task.md is canonical ($OUT = $CX_HOME/out/<id>). Line 1 is machine-readable JSON in an
# HTML comment (<!-- cx-task {"id", "base", "lane", "effort", "allowed_paths", "lockfiles",
# "commands", "subagents"?} -->), the rest is prose for the executor. Before every dispatch it is
# copied to $WT/.conductor/task.md and its sha256 is recorded in $OUT/task.sha; after the run the
# copy must still hash the same (else spec_tampered, exit 23).
#
# Functions:
#   cx_task_meta FILE           evals the line-1 JSON into TK_ID TK_BASE TK_LANE TK_EFFORT
#                               TK_SUBAGENTS TK_LOCKFILES TK_HAS_CMDS TK_CMDS TK_ALLOWED; rc 1
#                               (CX_TASK_WHY) when line 1 is missing or invalid
#   cx_task_from_file OUT FILE  copies a complete task.md (line-1 JSON required) to OUT/task.md
#   cx_task_from_text OUT TEXTFILE ID BASE LANE EFFORT CMD...
#                               wraps free text into templates/task.md as OUT/task.md (each
#                               check as cx-route <name> when OUT/routes.json, the run's
#                               cx-route snapshot, exists)
#   cx_task_install OUT DIR     DIR/.conductor/task.md = OUT/task.md; OUT/task.sha = its sha256
#   cx_task_hash_ok OUT DIR     rc 0 when DIR/.conductor/task.md still hashes to OUT/task.sha

[ -n "${CX_PROG:-}" ] || CX_PROG=taskfile
# shellcheck source=common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

CX_TASK_WHY=""
TK_ID="" TK_BASE="" TK_LANE="" TK_EFFORT="" TK_SUBAGENTS=0 TK_LOCKFILES=0 TK_HAS_CMDS=0
TK_CMDS=() TK_ALLOWED=()

cx_task_meta() {
  local out
  CX_TASK_WHY=""
  if ! out="$(python3 -I "$CX_LIB/normalize.py" task-meta --file "$1" 2>&1)"; then
    CX_TASK_WHY="${out#normalize: }"
    return 1
  fi
  eval "$out"
}

cx_task_from_file() {
  local out="$1" f="$2"
  cx_task_meta "$f" || return 1
  cp -f -- "$f" "$out/task.md" || { CX_TASK_WHY="cannot copy $f to $out/task.md"; return 1; }
}

cx_task_from_text() {
  local out="$1" text="$2" id="$3" base="$4" lane="$5" effort="$6" c
  shift 6
  local -a ca=()
  for c in "$@"; do ca+=(--cmd "$c"); done
  # The run's cx-route snapshot (cx-run writes it first) names each check: cx-route <name>.
  [ ! -f "$out/routes.json" ] || ca+=(--snapshot "$out/routes.json")
  python3 -I "$CX_LIB/normalize.py" task-render --template "$CX_ROOT/templates/task.md" --out "$out/task.md" \
    --id "$id" --base "$base" --lane "$lane" --effort "$effort" --text-file "$text" "${ca[@]+"${ca[@]}"}" \
    || { CX_TASK_WHY="cannot render the task text into templates/task.md"; return 1; }
  cx_task_meta "$out/task.md"
}

cx_task_install() {
  local out="$1" dir="$2"
  mkdir -p -- "$dir/.conductor" && cp -f -- "$out/task.md" "$dir/.conductor/task.md" \
    && sha256sum "$out/task.md" | cut -d' ' -f1 > "$out/task.sha"
}

cx_task_hash_ok() {
  local out="$1" dir="$2"
  [ -f "$dir/.conductor/task.md" ] && [ -s "$out/task.sha" ] || return 1
  [ "$(sha256sum "$dir/.conductor/task.md" | cut -d' ' -f1)" = "$(cat "$out/task.sha")" ]
}
