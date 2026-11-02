#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# scripts/adapters/agy.sh - the Antigravity lanes (docs/DESIGN.md section 15.2): agy-opus in raw
# mode (default: the agy CLI itself, which alone shows the served model) or wrapper mode
# (agy-delegate), and agy-gemini (always agy-delegate: digests, research, reviews).
# The raw flags (--add-dir, --print-timeout, --output-format stream-json,
# --disable-slash-commands, --new-project) are verified against `agy --help` 1.4.12 (DESIGN
# section 20 item 4); A1 checks them against tests/fixtures/real/agy/help.txt.
#
# Usage: agy.sh probe|argv|run|parse [OPTIONS]   (the options of scripts/lib/adapter.sh)
#        agy.sh -h|--help | --version
#
#   model: --model <slug or label>, else option agy_opus_slug_tpl with the effort (low|medium|
#   high; xhigh and max are not offered on agy: use the next pool). --agy-mode raw|wrapper
#   (default raw for write mode, wrapper otherwise); a non-Opus model is always wrapper mode.
#   raw argv:      <agy> --model <slug> --add-dir <WT> --print-timeout <T> --output-format
#                  stream-json --disable-slash-commands -p <prompt>
#   wrapper argv:  <agy-delegate> --model <M> --dir <WT> [--dir <DIR>...] --timeout <T> --digest <prompt>
#                  (a prompt that starts with "-": "-" and the prompt on stdin)
#   environment:   the worker environment, GEMINI_API_KEY and GOOGLE_API_KEY unset; wrapper mode
#                  adds AGY_USAGE_LOG=$CX_HOME/raw-usage.log and the shim set without agy
#                  (agy-delegate finds agy with command -v).
#   run:           the agy slot (cap_agy) and the agy launch lock, then the pause again (28 when
#                  another run paused agy while this one waited); raw: /usage before (free;
#                  option agy_claude_floor_pct > 0 and the claude_gpt bucket below it -> 28),
#                  registration (agy --new-project --output-format json -p /model in the
#                  worktree), a snapshot of every other worktree of the repo, the launch with
#                  the launch lock closed in the child, the init event within 120 s
#                  (CX_AGY_INIT_SECS; its model must be the slug, else the run is killed: 21),
#                  the launch lock released at init, SIGKILL of the session 5 s after the result
#                  event (#1313), a second snapshot (a change outside the worktree -> 22 and
#                  $CX_HOME/state/agy-paused: agy dispatch stops until cx-job unpause agy), /usage
#                  after (cost.quota_delta). Wrapper mode: registration and snapshots too, with
#                  the launch lock held for the whole call. TERM/INT/HUP kill the session at once
#                  (agy ignores TERM).
#   parse:         init.model (served), the result event's response, usage, denied_actions /
#                  a permission finished_reason (-> 15), subagent_info or another model (-> 2),
#                  an expired print timeout (-> 27); wrapper: model_served null, never 21.
#
# Exit codes: as scripts/lib/adapter.sh (0, 1, 2, 11, 13, 14, 26, 28, 130).

set -uo pipefail
unset CDPATH
CX_ADAPTER=agy
CX_PROG=adapter-agy
# shellcheck source=../lib/adapter.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/adapter.sh"

AGY_PAUSED="$CXA_HOME/state/agy-paused"

lane_setup() {
  CXA_EXECUTOR=agy CXA_SLOT_POOL=agy
  [ ! -e "$AGY_PAUSED" ] || CXA_PROBE_SALT=paused   # never answered from a cache entry of before the pause
  CXA_EFFORT="${A_EFFORT:-high}"
  if [ -n "$A_MODEL" ]; then
    CXA_MODEL="$A_MODEL"
  else
    case "$CXA_EFFORT" in
      low|medium|high) ;;
      xhigh|max) cx_usage_error "effort $CXA_EFFORT is not offered on agy (use the next pool in opus_lane_order)" ;;
      *) cx_usage_error "invalid --effort '$CXA_EFFORT'" ;;
    esac
    CXA_MODEL="${CXA_OPT[agy_opus_slug_tpl]//\{effort\}/$CXA_EFFORT}"
  fi
  case "$CXA_MODEL" in
    claude-opus*) CXA_LANE=agy-opus CXA_POOL=google-claude-bucket ;;
    *) CXA_LANE=agy-gemini CXA_POOL=google-gemini ;;
  esac
  CXA_VARIANT="$A_AGY_MODE"
  if [ -z "$CXA_VARIANT" ]; then
    if [ "$A_MODE" = write ]; then CXA_VARIANT=raw; else CXA_VARIANT=wrapper; fi
  fi
  case "$CXA_VARIANT" in raw|wrapper) ;; *) cx_usage_error "--agy-mode must be raw or wrapper" ;; esac
  [ "$CXA_LANE" = agy-opus ] || CXA_VARIANT=wrapper
  if [ "$CXA_VARIANT" = raw ]; then
    [[ $CXA_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || cx_usage_error "raw mode needs an agy model slug (got '$CXA_MODEL')"
  fi
  cxa_need_bin CXR_BIN_agy agy
  CXA_CLI="$CXR_BIN_agy"
  if [ "$CXA_VARIANT" = wrapper ]; then
    cxa_need_bin CXR_BIN_agy_delegate "agy-delegate (the antigravity plugin)"
    CXA_BIN="$CXR_BIN_agy_delegate"
  else
    CXA_BIN="$CXR_BIN_agy"
  fi
  CXA_ENV=()
  if [ "$CXA_VARIANT" = wrapper ]; then
    cxa_worker_env agy || cxa_fail 2 FAILED "cannot build the worker shim set without agy"
  else
    cxa_worker_env - || cxa_fail 2 FAILED "cannot build the worker shim set"
  fi
  cxa_unset GEMINI_API_KEY GOOGLE_API_KEY
  [ "$CXA_VARIANT" = raw ] || cxa_set AGY_USAGE_LOG "$CXA_HOME/raw-usage.log"
}

lane_argv() {
  local d wt="${A_WT:-$PWD}" dur
  dur="$(cxa_dur "$A_TIMEOUT")"
  if [ "$CXA_VARIANT" = raw ]; then
    CXA_ARGV=("$CXA_BIN" --model "$CXA_MODEL" --add-dir "$wt")
    for d in "${A_ADD[@]+"${A_ADD[@]}"}"; do CXA_ARGV+=(--add-dir "$d"); done
    CXA_ARGV+=(--print-timeout "$dur" --output-format stream-json --disable-slash-commands -p "$A_PROMPT")
  else
    CXA_ARGV=("$CXA_BIN" --model "$CXA_MODEL" --dir "$wt")
    for d in "${A_ADD[@]+"${A_ADD[@]}"}"; do CXA_ARGV+=(--dir "$d"); done
    # A prompt that starts with "-" goes on stdin (agy-delegate's documented "-" form), never
    # where the wrapper would take it for an option.
    CXA_ARGV+=(--timeout "$dur" --digest)
    if [[ $A_PROMPT == -* ]]; then CXA_ARGV+=(-); else CXA_ARGV+=("$A_PROMPT"); fi
  fi
}

# agy_trees FILE: a snapshot of every other worktree of the repo and of the repository's shared
# state, so agy writing, committing or planting anything outside its worktree shows (DESIGN
# section 15.2, WRONG_TREE). Per worktree ("== <path>"): HEAD, its branch, status with untracked
# files, the hash of git diff HEAD, the hashes of untracked files and of ignored files (git
# ls-files -o -i --directory: an ignored directory such as node_modules/ is one entry, its
# contents are not read). The repository ("== <common dir>#repo"): every branch and tag that no
# worktree has checked out (a checked-out branch moves with its worktree's HEAD, so a marked
# worktree's own commits are no alarm), the stash, git config without the branch.* keys (git push
# -u writes those), info/exclude and the hooks. Left out: the task's own worktree, and Claude
# Code's isolation worktrees under the main checkout's .claude/worktrees (unless it is --repo,
# the task's own checkout), in every list too.
agy_trees() {
  local out="$1" wt="${A_WT:-$PWD}" wtp main d gcd
  wtp="$(cd -- "$wt" 2>/dev/null && pwd -P)"
  main="$(git -C "$wt" worktree list --porcelain 2>/dev/null | sed -n '1s/^worktree //p')"
  gcd="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
  {
    git -C "$wt" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' | while IFS= read -r d; do
      { [ "$d" = "$wt" ] || [ "$d" = "$wtp" ]; } && continue
      if [ "$d" != "${A_REPO:-}" ]; then
        case "$d" in "$main"/.claude/worktrees/*) continue ;; esac
      fi
      [ -d "$d" ] || continue
      printf '== %s\n' "$d"
      printf 'HEAD %s %s\n' "$(git -C "$d" rev-parse -q --verify HEAD 2>/dev/null)" "$(git -C "$d" symbolic-ref -q HEAD 2>/dev/null)"
      git -C "$d" status --porcelain=v1 --untracked-files=all -- . ':!.claude/worktrees'
      git -C "$d" diff HEAD | sha256sum
      (cd -- "$d" && git ls-files -z -o --exclude-standard -- . ':!.claude/worktrees' | xargs -0r sha256sum)
      (cd -- "$d" && git ls-files -z -o -i --exclude-standard --directory -- . ':!.claude/worktrees' \
         | while IFS= read -r -d '' f; do
             case "$f" in */) printf 'ignored-dir %s\n' "$f" ;; *) printf 'ignored %s\n' "$(sha256sum -- "$f" 2>/dev/null | cut -c1-64)  $f" ;; esac
           done)
    done
    if [ -n "$gcd" ] && [ -d "$gcd" ]; then
      printf '== %s#repo\n' "$gcd"
      git -C "$wt" for-each-ref --format='%(refname) %(objectname)' refs/heads refs/tags \
        | awk 'FILENAME == ARGV[1] { co[$0] = 1; next } !($1 in co)' \
            <(git -C "$wt" worktree list --porcelain 2>/dev/null | sed -n 's/^branch //p') -
      printf 'stash\n'
      git -C "$wt" stash list --format='%H %gs' 2>/dev/null
      printf 'config\n'
      git config --file "$gcd/config" --list 2>/dev/null | grep -v '^branch\.' | sha256sum
      printf 'exclude '
      sha256sum < "$gcd/info/exclude" 2>/dev/null || printf 'none\n'
      (cd -- "$gcd" 2>/dev/null && find hooks -type f 2>/dev/null | LC_ALL=C sort | while IFS= read -r f; do sha256sum -- "$f"; done)
    fi
  } > "$out" 2>/dev/null
}

# agy_marks FILE: every worktree another lane marked running (any thread), so its own writes are
# no false alarm; read before and after the run. A stale mark is left out: one whose task ended
# with a final status other than ok (a failed or cancelled run's tree is watched again), or whose
# task has no result and no live cx-run (its .run.lock is free: the cx-run was killed).
agy_marks() {
  local f d st
  for f in "$CXA_HOME"/out/*/running "${HOME:-}"/.conductor/out/*/running; do
    [ -f "$f" ] || continue
    d="${f%/running}"
    if [ -f "$d/result.json" ]; then
      st="$(cxa_py field "$d/result.json" status 2>/dev/null)"
      case "$st" in ok|dispatched) ;; *) continue ;; esac
    elif [ -e "$d/.run.lock" ] && command -v flock >/dev/null 2>&1 && ( flock -n 9 ) 9>>"$d/.run.lock" 2>/dev/null; then
      continue
    fi
    cat -- "$f"
  done 2>/dev/null | LC_ALL=C sort -u > "$1"
}

agy_usage() {  # FILE: /usage (zero-quota [docs-only], DESIGN section 20 item 5)
  cxa_probe_cmd "$1.raw" "$CXR_BIN_agy" -p /usage --output-format json
  cxa_py json-extract "$1.raw" "$1" 2>/dev/null
  rm -f -- "$1.raw"
}

AGY_FACTS=()
agy_fact() { AGY_FACTS+=("$@"); }

lane_exec() {
  local wt="${A_WT:-$PWD}" wait rc init="" seen="" deadline floor rem wpid="" changed="[]"
  CXA_KILL_FIRST=KILL
  : > "$A_OUT/agy.events"
  wait="$(cx_lock_wait_secs)"
  [ -z "$A_NOWAIT" ] || wait=0
  cx_lock_launch "$wait"
  rc=$?
  if [ "$rc" != 0 ]; then
    cx_lock_release
    cxa_fail "$rc" "$([ "$rc" = 28 ] && echo NO_CAPACITY || echo FAILED)" "agy launch lock: $CX_SLOT_WHY"
  fi
  # The pause is checked again after every wait (the slot, the launch lock): a run that queued
  # before another run found WRONG_TREE never launches agy.
  if [ -e "$AGY_PAUSED" ]; then
    cx_lock_launch_release
    cx_lock_release
    cxa_fail 28 NO_CAPACITY "agy dispatch is paused ($AGY_PAUSED: a wrong_tree result while this run waited); cx-job unpause agy once the user has checked the other trees"
  fi
  if [ "$CXA_VARIANT" = raw ]; then
    agy_usage "$A_OUT/agy.usage.before.json"
    floor="${CXA_OPT[agy_claude_floor_pct]:-0}"
    if [ "${floor:-0}" -gt 0 ] 2>/dev/null; then
      rem="$(cxa_py field "$A_OUT/agy.usage.before.json" buckets.claude_gpt.remaining_percent 2>/dev/null)"
      if [[ $rem =~ ^[0-9]+(\.[0-9]+)?$ ]] && [ "${rem%%.*}" -lt "$floor" ]; then
        cx_lock_launch_release
        cxa_fail 28 NO_CAPACITY "the agy Claude/GPT bucket is at ${rem}% (option agy_claude_floor_pct=$floor): the agy Opus lane is ineligible"
      fi
    fi
  fi
  # Registration: agy works in its LAST project root unless the directory is registered first.
  cxa_env_args
  (cd -- "$wt" && cx_timeout 60 env "${CXA_ENVARGS[@]}" "$CXR_BIN_agy" --new-project --output-format json -p /model) \
    < /dev/null > "$A_OUT/agy.register.json" 2>&1
  rc=$?
  agy_fact register_rc:int "$rc"
  if [ "$rc" != 0 ]; then
    cx_note "agy registration of $wt failed (exit $rc): not launching (agy would work in its last project root)"
    cx_lock_launch_release
    CXA_RC=2
    return 0
  fi
  agy_marks "$A_OUT/agy.marks.before"
  agy_trees "$A_OUT/agy.trees.before"
  if [ "$CXA_VARIANT" = wrapper ]; then
    CXA_KEEP_LAUNCH=1 CXA_KILL_AFTER=15
    local in=/dev/null
    if [ "${CXA_ARGV[$((${#CXA_ARGV[@]} - 1))]}" = - ]; then
      printf '%s\n' "$A_PROMPT" > "$A_OUT/agy.prompt.txt" && in="$A_OUT/agy.prompt.txt"
    fi
    cxa_spawn "$in" "$wt" "$((A_TIMEOUT + 300))"
    cxa_wait_exec
    cx_lock_launch_release
  else
    CXA_KILL_AFTER=15
    cxa_spawn /dev/null "$wt" "$((A_TIMEOUT + 300))"
    (
      [ -z "${CX_LAUNCH_FD:-}" ] || exec {CX_LAUNCH_FD}>&-
      exec python3 -I "$CXA_NORM" agy-watch --ndjson "$A_OUT/agy.out" --events "$A_OUT/agy.events" \
        --pgid "$CXA_SID" --after-result "${CX_AGY_AFTER_RESULT_SECS:-5}"
    ) < /dev/null > /dev/null 2>&1 &
    wpid=$!
    deadline=$((SECONDS + ${CX_AGY_INIT_SECS:-120}))
    while :; do
      # One read of the events file: the watcher may append the init line at any moment, and a
      # second read could see a line the first did not (an empty model: a false mismatch, 21).
      if init="$(grep -m 1 -e '^init$' -e '^init ' "$A_OUT/agy.events" 2>/dev/null)"; then
        init="${init#init}"
        init="${init# }"
        seen=1
        break
      fi
      kill -0 "$CXA_SID" 2>/dev/null || break
      [ -z "$CXA_CANCELLED" ] || break
      if [ "$SECONDS" -ge "$deadline" ]; then
        cx_note "no init event from agy within ${CX_AGY_INIT_SECS:-120} s: killing it"
        agy_fact init_timeout:bool 1 init_secs:int "${CX_AGY_INIT_SECS:-120}"
        CXA_NOT_TIMEOUT=1
        cxa_kill_session KILL
        break
      fi
      sleep 0.3
    done
    cx_lock_launch_release
    if [ -n "$seen" ]; then
      agy_fact init_model "$init"
      if [ "$init" != "$CXA_MODEL" ]; then
        cx_note "agy's init event names model '${init:-none}', requested '$CXA_MODEL': killing the run (21)"
        agy_fact mismatch_killed:bool 1
        CXA_NOT_TIMEOUT=1
        cxa_kill_session KILL
      fi
    fi
    cxa_wait_exec
    [ -z "$wpid" ] || wait "$wpid" 2>/dev/null
    if grep -qx killed_after_result "$A_OUT/agy.events" 2>/dev/null; then
      agy_fact killed_after_result:bool 1
      CXA_NOT_TIMEOUT=1
    fi
  fi
  [ -n "$CXA_CANCELLED" ] && return 0
  agy_marks "$A_OUT/agy.marks.after"
  agy_trees "$A_OUT/agy.trees.after"
  if ! cxa_py trees-diff "$A_OUT/agy.trees.before" "$A_OUT/agy.trees.after" \
       --exclude-file "$A_OUT/agy.marks.before" --exclude-file "$A_OUT/agy.marks.after" > "$A_OUT/agy.trees.changed"; then
    mapfile -t CH < "$A_OUT/agy.trees.changed"
    changed="$(cxa_json_list "${CH[@]}")"
    mkdir -p -- "$(dirname -- "$AGY_PAUSED")"
    cxa_py obj id "$A_ID" at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" worktree "$wt" changed:json "$changed" > "$AGY_PAUSED"
    cx_note "WRONG_TREE: agy changed ${CH[*]}; agy dispatch is paused ($AGY_PAUSED) until cx-job unpause agy. Never reset a tree the conductor did not create: ask the user"
  fi
  agy_fact tree_changed:json "$changed"
  if [ "$CXA_VARIANT" = raw ] && cx_lock_launch 60; then
    agy_usage "$A_OUT/agy.usage.after.json"
    cx_lock_launch_release
  fi
  CXA_RUNJSON+=("${AGY_FACTS[@]+"${AGY_FACTS[@]}"}")
}

lane_probe() {
  local t="$CXA_PROBE_TMP" mrc paused=()
  [ -e "$AGY_PAUSED" ] && paused=(--paused)
  cxa_probe_cmd "$t/version" "$CXR_BIN_agy" --version
  cxa_probe_cmd "$t/models" "$CXR_BIN_agy" models
  mrc=$?
  cxa_py probe --lane agy --bin "$CXR_BIN_agy" --wrapper "$([ "$CXA_VARIANT" = wrapper ] && printf '%s' "$CXA_BIN")" \
    --version-out "$t/version" --min "$CX_MIN_AGY" --models-cli agy --models-out "$t/models" \
    --models-rc "$mrc" --model "$CXA_MODEL" "${paused[@]+"${paused[@]}"}"
}

cxa_main "$@"
