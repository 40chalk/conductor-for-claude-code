#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# cx-run - runs one conductor task on one executor lane (docs/DESIGN.md section 15.1): the task
# contract, the worktree, the repo's setup, the shared pool slot, the executor in the worker
# environment, the denial / served-model / tree checks, result.json, the ledger line and one
# CX_RESULT line. Claude owns the spec and the merge: cx-run never commits (Step 3 of the skill
# commits and gates; Phase 3 adds cx-gate).
#
# Usage: cx-run [--exec auto|agy|copilot|grok|claude|copilot-cloud] [--mode write|read|review]
#               [--task-file F | "<task>" | - | -- "<task>"] [--id ID] [--repo DIR] [--base REF]
#               [--model M] [--effort low|medium|high|xhigh|max] [--fusion standard|max]
#               [--family gemini|gpt] [--branch REF | --diff FILE] [--allow CMD]...
#               [--timeout DUR] [--agy-mode raw|wrapper] [--headless] [--gh-repo HOST/OWNER/REPO]
#               [--base-branch B] [--reuse-worktree] [--no-wait] [--background]
#               [--dry-run] [--explain]
#        cx-run --finish ID [--pr N]
#        cx-run -h|--help | --version
#
# Task: --task-file is a complete .conductor/task.md (line 1 <!-- cx-task {json} --> required);
# free text (or - for stdin; after --, one argument that is the text even when it starts with
# "-") is wrapped into templates/task.md with the .cx/routes.json commands and no allowed_paths.
# Prefer task files. The id is --id, else the task's "id", else generated; it must be unused on
# this computer (no cx/<id> branch, no $CX_HOME/out/<id>), also for --dry-run and --background.
# One cx-run per task at a time: a second one (a re-dispatch while the first still runs, or a
# --finish) exits 1 while $CX_HOME/out/<id>/.run.lock is held.
#
# Lanes (--exec): agy (agy-opus; raw mode by default, option agy_opus_mode or --agy-mode),
# copilot (copilot-opus, or copilot-fusion with --fusion), grok, claude (prints a dispatch JSON
# for one of your own subagents, then cx-run --finish <id>; --headless runs claude -p instead),
# copilot-cloud (the Copilot cloud agent through ghcp-cloud: it opens a pull request; then
# cx-run --finish <id> [--pr N] gates its head), and auto (write mode only, the default): the
# first lane of option opus_lane_order whose pool is on in routes.json, is not paused, passes the
# free preflight, supports the effort and has a free slot; agy always in raw mode. When every
# eligible executor pool is full it waits up to CX_SLOT_WAIT_SECS (default 600) for a slot, then
# takes the next lane in the order (the claude dispatch, last); --no-wait skips the wait.
#
# Modes: write (default): a worktree <worktree_root>/<repo>-<id> on branch cx/<id> from --base
# (default HEAD); setup, then the executor; the change is left uncommitted for Step 3.
# read: an answer only, on a detached gate checkout of --base ($CX_HOME/gate/<id>.<n>, removed
# after the run); the task text is the question (default lane grok). review (section 17.2):
# --branch REF (or --diff FILE) is reviewed on a gate checkout of it; --family gemini
# (agy-delegate, option review_model_gemini) or gpt (ghcp-delegate, option review_model_gpt), or
# --exec grok; the diff is in .conductor/change.diff there. ci arrives in Phase 4.
#
# Effort: max never leaves Claude; xhigh only on Copilot with option copilot_xhigh_ok=true (and
# never on agy); under auto, low does not spend Opus (it goes to the claude lane).
#
#   --timeout DUR     executor wall clock (30s, 30m, 2h; default option default_timeout)
#   --allow CMD       one more allowed shell command (besides the task's or routes.json commands)
#   --reuse-worktree  reuse an existing cx/<id> worktree and out directory (a re-dispatch)
#   --no-wait         a full pool exits 28 at once (an explicit lane) or is skipped (auto)
#   --background      starts the same command through cx-job and prints JOB_ID <id> on stdout
#   --dry-run         no worktree, no out directory, no executor: prints the plan, the adapter's
#                     argv (Copilot: ghcp-delegate --print-command) and the env names
#   --explain         --dry-run plus why each lane was chosen or skipped, and which preflight
#                     results came from the 10-minute cache
#   --finish ID       the post-run steps for a task that ran outside cx-run's own process: the
#                     claude dispatch (task hash, diff, the final CX_RESULT and ledger line) or
#                     the copilot-cloud lane (fetch the pull request head from the task's GitHub
#                     repository, gate it: setup and every routes command on a clean checkout).
#                     A finished task is refused (exit 1): a claude task no longer dispatched, a
#                     gated cloud task unless --pr N is given again (a re-gate); a run is booked
#                     in the ledger once. --dry-run checks the request only.
#
# Checks (cx-route): at dispatch the task's commands are snapshotted, named from .cx/routes.json
# (test, lint, typecheck, other keys; cmd-1... for the task's own), into $OUT/routes.json and the
# generated $CX_HOME/routes/<id>/cx-route, which is on the worker's PATH (the only directory of
# the run grok's sandbox profile may read). The prompts and the contract tell every executor to
# run checks only as cx-route <name>; it runs nothing else (in a clean bash: no BASH_ENV or
# exported functions of its caller), and an edit of the worktree's .cx/routes.json never reaches
# it. Copilot may approve only cx-route and git status; agy gets those and ls as per-run
# --settings grants; grok runs in its repository's sandbox profile (extends strict) in every
# mode, read and review included (never grok's built-in read-only, which writes ~/.grok).
#
# Output: stdout = the digest, then "VERIFY THIS: <what to check>" and the diffstat (the claude
# dispatch: its JSON). stderr = notes, CX_DENIED, CX_NOTE, CX_RESULT, then CX_SIGNAL (any exit
# other than 0 and 1). result.json and answer.txt are in $CX_HOME/out/<id>/, with vars.sh for
# the skill's hand steps (Step 3 commit and gate, Step 5 GitHub). The ledger (option
# ledger_path) gets one line per run. Forwarded from Git Bash, host_path fields are Windows paths.
# Run it outside Claude Code's Bash sandbox, as one background Bash call when it may run long.
#
# Exit codes: 0 ok (or dispatched); 1 usage error, refused request (also a cwd inside
# .claude/worktrees/ without --repo); 2 FAILED; 3 EMPTY_OUTPUT (write mode: no diff; read: no
# answer); 10 QUOTA_EXHAUSTED; 11 AUTH_REQUIRED; 12 TIMEOUT; 13 CLI_MISSING; 14
# MODEL_UNAVAILABLE; 15 PERMISSION_DENIED; 16 SANDBOX_BLOCKED; 20 GATE_FAILED (--finish of the
# cloud lane: a gate check failed); 21 MODEL_MISMATCH; 22 WRONG_TREE; 23 SPEC_TAMPERED; 24
# TAMPERED (the worktree's .git no longer links to its own git directory: no git ran there); 25
# ENV_FAILED (the repo's setup failed; not charged to the executor); 26 VERSION_MISMATCH (the
# flag contract: the CLI's live help lacks a flag the lane emits; no version is pinned); 27
# PARTIAL; 28 NO_CAPACITY (no slot within CX_SLOT_WAIT_SECS, a pool disabled in routes.json, cap
# 0, agy paused); 40 FORWARD_FAILED, 41 RUNTIME_MISSING, 42 PATH_UNMAPPABLE (Git Bash
# forwarding); 43 HOST_UNSUPPORTED (a cloud session); 130 CANCELLED.

set -uo pipefail
unset CDPATH
CX_PROG=cx-run
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/options.sh
. "$HERE/lib/options.sh"

[ $# -gt 0 ] && cx_help_version "$1"
cx_forward_if_needed cx-run "$@"
# shellcheck disable=SC2119  # no FILE: the default settings files
cx_load_options
# shellcheck source=lib/locks.sh
. "$HERE/lib/locks.sh"
# shellcheck source=lib/worktree.sh
. "$HERE/lib/worktree.sh"
# shellcheck source=lib/taskfile.sh
. "$HERE/lib/taskfile.sh"

CXH="${CX_HOME:-$HOME/.conductor}"
NORM="$CX_LIB/normalize.py"
norm() { python3 -I "$NORM" "$@"; }
export CX_SIGNAL_OWNER=cx-run

# ------------------------------------------------------------------ arguments
EXEC="" MODE=write FAMILY="" MODEL="" EFFORT="" FUSION="" TASK_FILE="" TASK_TEXT="" HAVE_TEXT=0
ID="" REPO_DIR="" BASE_REF="" REUSE="" BRANCH="" DIFF_FILE="" TIMEOUT="" BG="" NOWAIT="" HEADLESS=""
DRY="" EXPLAIN="" FINISH="" PR="" AGY_MODE="" GH_REPO="" BASE_BRANCH="" TARGET=""
ALLOW=() BG_ARGS=()
while [ $# -gt 0 ]; do
  a="$1"
  case "$a" in
    --) shift
        [ $# = 1 ] || cx_usage_error "-- takes exactly one argument after it: the task text"
        [ "$HAVE_TEXT" = 0 ] || cx_usage_error "only one task (a text, or - for stdin)"
        HAVE_TEXT=1; TASK_TEXT="$1"; shift; break ;;
    --*=*) set -- "${a%%=*}" "${a#*=}" "${@:2}"; continue ;;
  esac
  case "$a" in
    -h|--help|--version) cx_help_version "$a" ;;
    --reuse-worktree) REUSE=1; BG_ARGS+=("$a"); shift; continue ;;
    --background) BG=1; shift; continue ;;
    --no-wait) NOWAIT=1; BG_ARGS+=("$a"); shift; continue ;;
    --headless) HEADLESS=1; BG_ARGS+=("$a"); shift; continue ;;
    --dry-run) DRY=1; BG_ARGS+=("$a"); shift; continue ;;
    --explain) EXPLAIN=1 DRY=1; BG_ARGS+=("$a"); shift; continue ;;
    -) [ "$HAVE_TEXT" = 0 ] || cx_usage_error "only one task (a text, or - for stdin)"
       HAVE_TEXT=1; TASK_TEXT="$(cat)"; shift; continue ;;
    --exec|--mode|--family|--model|--effort|--fusion|--task-file|--id|--repo|--base|--branch|--diff|--allow|--timeout|--finish|--pr|--agy-mode|--gh-repo|--base-branch)
      [ $# -ge 2 ] || cx_usage_error "$a needs a value" ;;
    -*) cx_usage_error "unknown option: $a" ;;
    *) [ "$HAVE_TEXT" = 0 ] || cx_usage_error "only one task (a text, or - for stdin); quote it"
       HAVE_TEXT=1; TASK_TEXT="$a"; shift; continue ;;
  esac
  BG_ARGS+=("$a" "$2")
  case "$a" in
    --exec) EXEC="$2" ;;
    --mode) MODE="$2" ;;
    --family) FAMILY="$2" ;;
    --model) MODEL="$2" ;;
    --effort) EFFORT="$2" ;;
    --fusion) FUSION="$2" ;;
    --task-file) TASK_FILE="$2" ;;
    --id) ID="$2" ;;
    --repo) REPO_DIR="$2" ;;
    --base) BASE_REF="$2" ;;
    --branch) BRANCH="$2" ;;
    --diff) DIFF_FILE="$2" ;;
    --allow) ALLOW+=("$2") ;;
    --timeout) TIMEOUT="$2" ;;
    --finish) FINISH="$2" ;;
    --pr) PR="$2" ;;
    --agy-mode) AGY_MODE="$2" ;;
    --gh-repo) GH_REPO="$2" ;;
    --base-branch) BASE_BRANCH="$2" ;;
  esac
  shift 2
done

if [ -n "$BG" ]; then
  [ -z "$DRY" ] || cx_usage_error "--background and --dry-run/--explain do not combine"
  # The task text always travels after "--": the job's cx-run never takes it for an option.
  [ "$HAVE_TEXT" = 0 ] || BG_ARGS+=(-- "$TASK_TEXT")
  exec bash "$HERE/cx-job.sh" start "${BG_ARGS[@]+"${BG_ARGS[@]}"}"
fi

cx_py_ok || cx_signal FAILED 2 "python3 (3.8 or newer, run as python3 -I) is required on the executor host"
command -v git >/dev/null 2>&1 || cx_signal FAILED 2 "git is required"

case "$MODE" in
  write|read|review) ;;
  ci) cx_usage_error "--mode ci arrives in Phase 4 (DESIGN section 17.3): run ghcp-ci-debug as the skill's Step 5 shows" ;;
  *) cx_usage_error "--mode must be write, read or review (got '$MODE')" ;;
esac
case "$EXEC" in ""|auto|agy|copilot|grok|claude|copilot-cloud) ;; *) cx_usage_error "--exec must be auto, agy, copilot, grok, claude or copilot-cloud (got '$EXEC')" ;; esac
case "$EFFORT" in ""|low|medium|high|xhigh|max) ;; *) cx_usage_error "--effort must be low, medium, high, xhigh or max" ;; esac
case "$FUSION" in ""|standard|max) ;; *) cx_usage_error "--fusion must be standard or max" ;; esac
case "$FAMILY" in ""|gemini|gpt) ;; *) cx_usage_error "--family must be gemini or gpt" ;; esac
case "$AGY_MODE" in ""|raw|wrapper) ;; *) cx_usage_error "--agy-mode must be raw or wrapper" ;; esac
[ -z "$PR" ] || [[ $PR =~ ^[0-9]{1,9}$ ]] || cx_usage_error "--pr must be a pull request number"
TIMEOUT_S=""
if [ -n "$TIMEOUT" ]; then
  [[ $TIMEOUT =~ ^([0-9]{1,7})([smh]?)$ ]] || cx_usage_error "--timeout must be 30s, 30m, 2h or seconds"
  TIMEOUT_S=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in m) TIMEOUT_S=$((TIMEOUT_S * 60)) ;; h) TIMEOUT_S=$((TIMEOUT_S * 3600)) ;; esac
  [ "$TIMEOUT_S" -ge 30 ] || cx_usage_error "--timeout must be at least 30 seconds"
fi
for c in "${ALLOW[@]+"${ALLOW[@]}"}"; do
  [ -n "$c" ] && [[ ! $c =~ [[:cntrl:]] ]] || cx_usage_error "--allow needs one command without control characters"
done
[ -z "$MODEL" ] || [[ ! $MODEL =~ [[:cntrl:]] ]] || cx_usage_error "invalid --model"
valid_id() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] && [[ $1 != *..* ]] && [[ $1 != *.lock ]] && [[ $1 != *. ]]; }
[ -z "$ID" ] || valid_id "$ID" || cx_usage_error "invalid --id '$ID' (letters, digits, . _ -; at most 64)"
[ -z "$FINISH" ] || valid_id "$FINISH" || cx_usage_error "invalid --finish id '$FINISH'"

# ------------------------------------------------------------------ helpers
CANCELLED="" CHILD="" RAN="" MARKED="" BG_PENDING="" GATE="" KEEP_GATE="" TOP="" CX_RUN_LOCK_FD=""
# unmark: drops the running mark cx-run set on a worktree it created (or reused unmarked), for a
# run that stops before its executor.
unmark() { [ -z "$MARKED" ] || rm -f -- "${OUT:?}/running"; MARKED=""; }
# shellcheck disable=SC2329  # invoked by the trap below
on_signal() {
  CANCELLED=1
  if [ -n "$CHILD" ]; then
    kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null
    return 0
  fi
  # bg_wait is starting a child: it forwards the TERM itself once the child's pid is known.
  [ -z "$BG_PENDING" ] || return 0
  # The adapter's run has begun (RAN): a cancellation sends more than one signal (cx-job kill
  # signals the session, timeout forwards its own), and one that arrives after the adapter
  # returned only marks the result cancelled, which is written next.
  [ -z "$RAN" ] || return 0
  [ -z "${CX_JOB_DIR:-}" ] || rm -f -- "$CX_JOB_DIR/queued"
  unmark
  cx_note "cancelled before the executor started"
  cx_signal CANCELLED 130 "interrupted before the executor started"
}
trap on_signal INT TERM HUP
# on_exit: a gate checkout this run created is removed on every exit, unless it is kept on
# purpose (the claude dispatch works in it until --finish; a red cloud gate stays for inspection).
# shellcheck disable=SC2329  # invoked by the trap below
on_exit() {
  [ -n "$GATE" ] && [ -z "$KEEP_GATE" ] && [ -n "$TOP" ] && [ -e "$GATE" ] && cx_wt_remove "$TOP" "$GATE"
  return 0
}
trap on_exit EXIT

# The command run in a checkout (setup and gate checks): cd, then the repo's command under the
# wall clock, with pipefail.
# shellcheck disable=SC2016  # expanded by the inner bash
IN_DIR='cd -- "$1" && exec timeout --kill-after=30s "$2" bash -o pipefail -c "$3"'

# bg_wait CMD...: runs CMD as a background child (its own process group, so a cancel reaches
# everything it started) and waits for it; sets BG_RC. Signals reach on_signal at once.
bg_wait() {
  local r
  BG_PENDING=1
  set -m
  # The child never inherits the task's run lock (a daemon it leaves behind would hold it).
  if [ -n "$CX_RUN_LOCK_FD" ]; then "$@" {CX_RUN_LOCK_FD}>&- & else "$@" & fi
  CHILD=$!
  set +m
  BG_PENDING=""
  # A signal that came while the child was being started was only recorded: forward it now.
  if [ -n "$CANCELLED" ]; then kill -TERM -- "-$CHILD" 2>/dev/null || kill -TERM "$CHILD" 2>/dev/null; fi
  while :; do
    wait "$CHILD" 2>/dev/null
    BG_RC=$?
    kill -0 "$CHILD" 2>/dev/null || break
  done
  # A wait interrupted by a trapped signal returns > 128 even when the child then exits on its
  # own terms: collect its real status (bash keeps it for a later wait).
  if [ "$BG_RC" -gt 128 ]; then
    wait "$CHILD" 2>/dev/null
    r=$?
    [ "$r" = 127 ] || BG_RC=$r
  fi
  CHILD=""
}

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# run_lock: $OUT/.run.lock, held (flock) for cx-run's whole life: one cx-run per task at a time.
# Exit 1 when another cx-run of the task holds it. Without flock the run goes unguarded.
run_lock() {
  local holder
  command -v flock >/dev/null 2>&1 || return 0
  { exec {CX_RUN_LOCK_FD}>>"$OUT/.run.lock"; } 2>/dev/null || cx_signal FAILED 2 "cannot open $OUT/.run.lock"
  if ! flock -n "$CX_RUN_LOCK_FD" 2>/dev/null; then
    holder="$(head -n 1 "$OUT/.run.lock" 2>/dev/null | head -c 200)"
    exec {CX_RUN_LOCK_FD}>&-
    CX_RUN_LOCK_FD=""
    cx_usage_error "task $ID is running (${holder% }): wait for it (cx-job wait) or stop it (cx-job kill) before another cx-run of it"
  fi
  printf 'pid=%s job=%s since=%s\nrt=%s\n' "$$" "${CX_JOB_DIR:+${CX_JOB_DIR##*/}}" "$(stamp)" "$RT" > "$OUT/.run.lock" 2>/dev/null
  return 0
}
# run_busy DIR: rc 0 when a cx-run holds DIR/.run.lock now (checked without taking it).
run_busy() {
  [ -e "$1/.run.lock" ] && command -v flock >/dev/null 2>&1 || return 1
  ! ( flock -n 9 ) 9>>"$1/.run.lock" 2>/dev/null
}
gen_id() { printf '%s%s-%s' "$1" "$(date -u +%Y%m%d-%H%M%S)" "$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"; }
secs_of() { [[ $1 =~ ^([0-9]{1,7})([smh]?)$ ]] || { printf '1800'; return; }; local n=$((10#${BASH_REMATCH[1]})); case "${BASH_REMATCH[2]}" in m) n=$((n * 60)) ;; h) n=$((n * 3600)) ;; esac; printf '%s' "$n"; }

# The runtime copy (DESIGN section 7.5): adapters, worker shims and job runners run from
# $CX_HOME/runtime/<version> (common.sh cx_runtime_ensure).
RT="$CX_ROOT"
ensure_runtime() { cx_runtime_ensure; RT="$CX_RT"; }

# The host record (section 7.6): refreshed with cx-doctor --record-only when missing, older than
# 7 days or from another plugin version (free: resolution and --version probes only).
refresh_record() {
  local rec at pv age j
  _cx_source_detect
  cx_detect
  rec="$CXH/hosts/$CX_HOSTKEY.json"
  if [ -f "$rec" ]; then
    j="$(head -c 65536 "$rec" 2>/dev/null)"
    pv="" at=""
    [[ $j =~ \"plugin_version\":[[:space:]]*\"([^\"]*)\" ]] && pv="${BASH_REMATCH[1]}"
    [[ $j =~ \"recorded_at\":[[:space:]]*\"([^\"]*)\" ]] && at="${BASH_REMATCH[1]}"
    age=$(( $(printf '%(%s)T' -1) - $(date -u -d "$at" +%s 2>/dev/null || echo 0) ))
    [ "$pv" != "$CX_VERSION" ] || [ "$age" -gt 604800 ] || return 0
  fi
  if ! bash "$RT/scripts/cx-doctor.sh" --record-only >/dev/null 2>&1; then
    cx_note "the host record $rec could not be refreshed (cx-doctor --record-only failed); using it as it is"
  fi
}

# ------------------------------------------------------------------ the repository and routes
TOP="" BASE="" REPO_GH=""
resolve_repo() {
  local d="$PWD"
  if [ -n "$REPO_DIR" ]; then cx_path_in_var REPO_DIR "$REPO_DIR"; d="$REPO_DIR"; fi
  [ -d "$d" ] || cx_usage_error "not a directory: $d"
  TOP="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || TOP=""
  [ -n "$TOP" ] || cx_usage_error "not inside a git work tree: $d (run from the repository, or pass --repo DIR)"
  if [ -z "$REPO_DIR" ]; then
    case "$TOP/" in
      */.claude/worktrees/*) cx_usage_error "the cwd's checkout $TOP is one of Claude Code's own worktrees (.claude/worktrees/): the base would be wrong; run from the main checkout or pass --repo DIR" ;;
    esac
  fi
}
resolve_base() {  # REF (default HEAD)
  local ref="${1:-HEAD}"
  BASE="$(git -C "$TOP" rev-parse --verify -q "$ref^{commit}" 2>/dev/null)" || BASE=""
  [ -n "$BASE" ] || cx_usage_error "--base '$ref' is not a commit in $TOP"
}
gh_repo() {  # host/owner/repo for gh -R: gh resolves the checkout's remote (ssh host aliases too), else the origin URL
  [ -n "$REPO_GH" ] && return 0
  if [ -n "$GH_REPO" ]; then REPO_GH="$GH_REPO"; return 0; fi
  REPO_GH="$( (cd -- "$TOP" && cx_timeout 15 gh repo view --json url --jq .url) 2>/dev/null </dev/null | sed -E 's#^https?://##')" || REPO_GH=""
  [[ $REPO_GH =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+){1,2}$ ]] || REPO_GH=""
  if [ -z "$REPO_GH" ]; then
    REPO_GH="$(git -C "$TOP" remote get-url origin 2>/dev/null | sed -E 's#^[a-z+]+://([^@/]*@)?##; s#^[^@/]*@([^:/]+):#\1/#; s#^([^/:]+):[0-9]+/#\1/#; s#\.git$##')"
    [[ $REPO_GH =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+){1,2}$ ]] || REPO_GH=""
  fi
}
# shellcheck disable=SC2034  # RT_POOL_* are read through eval, RT_DIFF_BUDGET is for Phase 3
RT_FOUND=0 RT_VALID=1 RT_SETUP="" RT_POOL_agy=1 RT_POOL_copilot=1 RT_POOL_grok=1 RT_DIFF_BUDGET=400
RT_CMDS=()
load_routes() {
  local o
  o="$(norm routes --file "$TOP/.cx/routes.json")" && eval "$o"
  if [ "$RT_FOUND" = 0 ]; then
    cx_note "no .cx/routes.json in $TOP: no setup and no allowed commands (run cx-init to write one)"
  elif [ "$RT_VALID" = 0 ]; then
    cx_note "$TOP/.cx/routes.json is not valid JSON: using the defaults (no setup, no commands)"
  fi
}

# ------------------------------------------------------------------ lanes
ADAPTER="" EXPLAIN_LINES=()
explain() { EXPLAIN_LINES+=("$*"); }
lane_adapter() { case "$1" in agy|copilot|grok|claude|copilot-cloud) printf '%s' "$1" ;; esac; }
eff_or() { if [ -n "$EFFORT" ]; then printf '%s' "$EFFORT"; elif [ -n "$TK_EFFORT" ]; then printf '%s' "$TK_EFFORT"; else printf '%s' "$1"; fi; }

# lane_args LANE: the adapter options for LANE (LARGS), besides --out/--wt/--prompt.
LARGS=()
lane_args() {
  local lane="$1" e
  LARGS=(--mode "$MODE" --timeout "${TIMEOUT_S:-$(secs_of "$(cx_opt default_timeout)")}")
  [ -z "$ID" ] || LARGS+=(--id "$ID")
  [ -z "$TOP" ] || LARGS+=(--repo "$TOP")
  [ -z "$BASE" ] || LARGS+=(--base "$BASE")
  [ -z "$NOWAIT" ] || LARGS+=(--no-wait)
  local c
  for c in "${CMDS[@]+"${CMDS[@]}"}"; do LARGS+=(--allow "$c"); done
  case "$lane" in
    agy)
      if [ -n "$MODEL" ]; then LARGS+=(--model "$MODEL")
      elif [ "$MODE" = review ]; then LARGS+=(--model "$(cx_opt review_model_gemini)")
      elif [ "$MODE" = read ]; then LARGS+=(--model gemini-3.8-flash-high)
      fi
      e="$(eff_or high)"; LARGS+=(--effort "$e")
      if [ "$MODE" = write ]; then
        if [ "$EXEC" = auto ] || [ -z "$EXEC" ]; then LARGS+=(--agy-mode raw)
        else LARGS+=(--agy-mode "${AGY_MODE:-$(cx_opt agy_opus_mode)}"); fi
      fi ;;
    copilot)
      if [ -n "$FUSION" ]; then LARGS+=(--fusion "$FUSION")
      else
        if [ -n "$MODEL" ]; then LARGS+=(--model "$MODEL")
        elif [ "$MODE" != write ]; then LARGS+=(--model "$(cx_opt review_model_gpt)")
        fi
        LARGS+=(--effort "$(eff_or high)")
      fi ;;
    grok)
      [ -z "$MODEL" ] || LARGS+=(--model "$MODEL")
      e="$(eff_or "")"
      [ -n "$e" ] || { [ "$MODE" = write ] || e=medium; }
      [ -z "$e" ] || LARGS+=(--effort "$e")
      [ "$TK_SUBAGENTS" != 1 ] || LARGS+=(--subagents) ;;
    claude)
      [ -z "$MODEL" ] || LARGS+=(--model "$MODEL")
      LARGS+=(--effort "$(eff_or high)")
      [ -z "$HEADLESS" ] || LARGS+=(--headless) ;;
    copilot-cloud)
      gh_repo
      [ -n "$REPO_GH" ] || cx_usage_error "copilot-cloud needs the GitHub repository: pass --gh-repo HOST/OWNER/REPO (gh repo view --json url)"
      LARGS+=(--gh-repo "$REPO_GH")
      if [ -z "$BASE_BRANCH" ]; then BASE_BRANCH="$(git -C "$TOP" symbolic-ref -q --short HEAD 2>/dev/null)" || BASE_BRANCH=""; fi
      [ -z "$BASE_BRANCH" ] || LARGS+=(--base-branch "$BASE_BRANCH") ;;
  esac
}

# probe LANE: the adapter's free preflight (cached 10 minutes). Sets PRB_CODE, PRB_STATUS,
# PRB_REASON, PRB_CACHED; rc 0 when green.
PRB_CODE="" PRB_STATUS="" PRB_REASON="" PRB_CACHED=""
probe() {
  local lane="$1" j v err
  err="$(mktemp "${TMPDIR:-/tmp}/cx-run-probe.XXXXXXXX")" || err=/dev/null
  lane_args "$lane"
  j="$(bash "$RT/scripts/adapters/$lane.sh" probe "${LARGS[@]}" 2>"$err")"
  local rc=$?
  PRB_CACHED=false
  if [ "$rc" != 0 ] || [ -z "$j" ]; then
    PRB_CODE="$rc" PRB_STATUS="${CX_EXIT_STATUS[$rc]:-FAILED}"
    PRB_REASON="$(grep -v '^CX_' "$err" | sed -n 's/^adapter-[a-z-]*: //p' | head -n 1)"
    [ -n "$PRB_REASON" ] || PRB_REASON="the $lane probe failed (exit $rc)"
    [ "$rc" != 1 ] || PRB_CODE=1
    [ "$err" = /dev/null ] || rm -f -- "$err"
    return 1
  fi
  [ "$err" = /dev/null ] || rm -f -- "$err"
  case "$j" in *'"cached": true'*) PRB_CACHED=true ;; esac
  v="$(norm verdict "$j")" || v="2 FAILED - the preflight verdict failed"
  PRB_CODE="${v%% *}"; v="${v#* }"
  PRB_STATUS="${v%% *}"; v="${v#* }"; v="${v#* }"
  PRB_REASON="$v"
  [ "$PRB_CODE" = 0 ]
}

effort_ok() {  # LANE EFFORT: rc 0 when auto may give LANE this effort (section 6.3)
  case "$1:$2" in
    agy:medium|agy:high|copilot:medium|copilot:high) return 0 ;;
    copilot:xhigh) cx_bool "$(cx_opt copilot_xhigh_ok)" ;;
    claude:*) return 0 ;;
  esac
  return 1
}
slot_free() {  # POOL: a free slot right now (taken and released at once)
  local cap
  cap="$(cx_opt "cap_$1")"
  cx_lock_try "$1" "$cap" 2>/dev/null || return 1
  cx_lock_release
  return 0
}

# auto: the lane in option opus_lane_order (section 15.1). Sets EXEC.
choose_auto() {
  local order lane e full=() waited deadline wait p
  [ -z "$MODEL" ] || cx_usage_error "--model needs an explicit --exec (auto picks the model per lane)"
  [ -z "$FUSION" ] || cx_usage_error "--fusion needs --exec copilot"
  e="$(eff_or high)"
  order="$(cx_opt opus_lane_order)"
  for lane in ${order//,/ }; do
    if [ "$lane" = claude ]; then
      if [ "${#full[@]}" -gt 0 ] && [ -z "$NOWAIT" ]; then
        wait="$(cx_lock_wait_secs)"
        if [ -n "$DRY" ]; then
          explain "every eligible executor pool is full (${full[*]}): a run would wait up to ${wait} s for a slot, then take the claude lane"
        else
          cx_note "every eligible executor pool is full (${full[*]}); waiting up to ${wait} s for a slot, then the claude lane"
          [ -z "${CX_JOB_DIR:-}" ] || printf 'auto\n' > "$CX_JOB_DIR/queued" 2>/dev/null
          deadline=$(( $(date +%s) + wait ))
          waited=""
          while [ "$(date +%s)" -lt "$deadline" ]; do
            for p in "${full[@]}"; do
              if slot_free "$p"; then waited="$p"; break 2; fi
            done
            sleep 2
          done
          [ -z "${CX_JOB_DIR:-}" ] || rm -f -- "$CX_JOB_DIR/queued"
          if [ -n "$waited" ]; then
            EXEC="$waited"
            explain "$waited: a slot came free while waiting"
            return 0
          fi
        fi
      fi
      EXEC=claude
      explain "claude: chosen (the Claude pool takes every effort and has no slot)"
      return 0
    fi
    if ! effort_ok "$lane" "$e"; then
      explain "$lane: skipped: effort $e is not offered there (section 6.3: low does not spend Opus, xhigh only on Copilot with copilot_xhigh_ok, max stays with Claude)"
      continue
    fi
    if [ "$(eval "printf %s \"\${RT_POOL_$lane}\"")" = 0 ]; then
      explain "$lane: skipped: the pool is off in .cx/routes.json (pools.$lane false)"
      continue
    fi
    if [ "$lane" = agy ] && [ -e "$CXH/state/agy-paused" ]; then
      explain "agy: skipped: agy dispatch is paused after a wrong_tree result (cx-job unpause agy)"
      continue
    fi
    if [ "$(cx_opt "cap_$lane")" = 0 ]; then
      explain "$lane: skipped: cap_$lane=0 (the lane is disabled)"
      continue
    fi
    if ! probe "$lane"; then
      explain "$lane: skipped: preflight $PRB_STATUS ($PRB_REASON; cached: $PRB_CACHED)"
      continue
    fi
    if slot_free "$lane"; then
      EXEC="$lane"
      explain "$lane: chosen: preflight green (cached: $PRB_CACHED), a slot is free"
      return 0
    fi
    explain "$lane: full: every cap_$lane slot is busy"
    full+=("$lane")
  done
  EXEC=claude
  explain "claude: chosen (end of the order)"
}

# review_prompt: the review lane's prompt (section 17.2); agy (agy-delegate, no grants) is told
# to read with its own tools, since its first shell command ends the run.
review_prompt() {
  local p="Review the change in .conductor/change.diff against the code in this checkout. List findings as file:line - severity - issue, most severe first. Do not edit files."
  case "$EXEC" in
    agy) p="$p Read files with your own file tools and run no shell command: any command ends the run." ;;
    claude) ;;
    *) p="$p Run checks only as cx-route <name> (cx-route alone lists them)." ;;
  esac
  printf '%s\n' "$p"
}

# ------------------------------------------------------------------ result handling
# finish_result EXIT_HINT: parse, emit, report, ledger; prints the single CX_SIGNAL and exits.
finish_result() {
  local pr code status ledger lp
  pr="$(bash "$RT/scripts/adapters/$ADAPTER.sh" parse --out "$OUT" 2>/dev/null)"
  code="${pr%% *}"
  status="${pr#* }"
  if ! [[ $code =~ ^[0-9]+$ ]] || [ ! -f "$OUT/result.json" ]; then
    cx_signal FAILED 2 "the result of $ID could not be parsed ($OUT)"
  fi
  # The running mark (agy's snapshots leave a marked worktree out) stays only for a change that
  # waits for the conductor's commit (status ok, a diff; never an agy task, whose tree must stay
  # in later agy snapshots) and for the claude dispatch, whose subagent is writing; a failed,
  # cancelled or empty run drops it.
  if [ "$MODE" = write ] && [ -n "${WT:-}" ]; then
    case "$status" in
      dispatched) ;;
      ok) if [ "$ADAPTER" != agy ] && [ "${CX_WT_DIFF:-0}" = 1 ]; then cx_wt_mark "$OUT" "$WT"; else rm -f -- "$OUT/running"; fi ;;
      *) rm -f -- "$OUT/running" ;;
    esac
  fi
  norm report --out "$OUT"
  norm emit --out "$OUT" 2>"$OUT/emit.err" || true
  if [ "$status" != dispatched ] && [ -z "${NO_LEDGER:-}" ]; then
    # One ledger line per run and one per --finish of it (the cloud lane books its dispatch and
    # its gate): a repeated --finish (a re-gate) is not booked again.
    if [ -e "$OUT/${LEDGER_MARK:-ledger.done}" ]; then
      cx_note "the ledger already has a line for this run of $ID ($(head -c 40 "$OUT/${LEDGER_MARK:-ledger.done}" 2>/dev/null)): not booked again"
    else
      lp="$(cx_expand_tilde "$(cx_opt ledger_path)")"
      if ledger="$(python3 -I "$CX_LIB/ledger.py" append --ledger "$lp" "$OUT/result.json" 2>&1 >/dev/null)"; then
        stamp > "$OUT/${LEDGER_MARK:-ledger.done}"
      else
        cx_note "the ledger line was not written: ${ledger:-ledger.py failed}"
      fi
    fi
  fi
  cat "$OUT/emit.err" >&2
  rm -f -- "$OUT/emit.err"
  [ "$code" = 0 ] && exit 0
  cx_signal "$(cx_status_for_exit "$code" || echo FAILED)" "$code" "$(norm field "$OUT/result.json" reason 2>/dev/null || echo "$status")"
}

# stop_result STATUS REASON: the run stopped before (or instead of) the executor.
stop_result() {
  norm obj stop:json "$(norm obj status "$1" reason "$2")" > "$OUT/checks.json"
  cx_note "$2"
  finish_result
}

write_checks() {  # post-run facts of a write run (section 15.1 post-checks)
  local spec=1 notes=() why=""
  cx_task_hash_ok "$OUT" "$WT" || spec=0
  # Git runs in the worktree only through its own git directory (worktree.sh): a .git the
  # executor rewrote is TAMPERED (24), and nothing reads it.
  cx_wt_changes "$TOP" "$WT" "$BASE" "$OUT"
  if [ "$CX_WT_LINK" = 0 ]; then
    why="the worktree's .git was rewritten during the run, so no git ran in it: do not run git there; remove the worktree with rm -rf, then git worktree prune in the repository"
    cx_note "$CX_WT_WHY"
  elif [ -n "$CX_WT_BRANCH" ] && [ "$CX_WT_BRANCH" != "cx/$ID" ]; then
    notes+=("the executor left cx/$ID (now on $CX_WT_BRANCH): Step 3 stops with BRANCH_TAMPERED")
  elif [ -z "$CX_WT_BRANCH" ]; then
    notes+=("the worktree's HEAD is detached: Step 3 stops with BRANCH_TAMPERED")
  fi
  [ -z "$CX_WT_ADD_ERR" ] || notes+=("git add could not index every file of the worktree ($CX_WT_ADD_ERR); the other files are in the diff")
  norm obj spec_ok:bool "$spec" git_link_ok:bool "$CX_WT_LINK" git_link_why "$why" diff:bool "$CX_WT_DIFF" \
    diffstat "$CX_WT_DIFFSTAT" commit:json null \
    branch "${CX_WT_BRANCH:-}" base "$BASE" gate:json null finished:bool "${1:-0}" cancelled:bool "$CANCELLED" \
    notes:json "$(norm json-list "${notes[@]+"${notes[@]}"}")" > "$OUT/checks.json"
  [ -n "$CX_WT_DIFFSTAT" ] || return 0
}

write_vars() {  # $OUT/vars.sh for the skill's hand steps (Step 3 commit and gate, Step 5 GitHub)
  local p
  p='Read .conductor/task.md in the working directory and do exactly what it says. Run checks only as cx-route <name> (cx-route alone lists them). Do not spawn subagents. End with the DIGEST: line it specifies.'
  gh_repo
  { printf '%s=%q\n' ID "$ID" TOP "$TOP" BASE "$BASE" WT "$WT" OUT "$OUT" REPO "$REPO_GH" P "$p"
    echo 'G_ENV=(GROK_DISABLE_AUTOUPDATER=1 GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_SKILLS_ENABLED=false GROK_CLAUDE_MCPS_ENABLED=false GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false)'
  } > "$OUT/vars.sh"
}

save_state() {
  norm obj version:int 1 id "$ID" exec "$EXEC" adapter "$ADAPTER" mode "$MODE" top "$TOP" base "$BASE" \
    wt "$WT" gate "${GATE:-}" repo_gh "${REPO_GH:-}" created_at "$(stamp)" caller "${CX_CALLER:-local}" \
    job "${CX_JOB_DIR:-}" setup "$RT_SETUP" --list commands "${#CMDS[@]}" "${CMDS[@]+"${CMDS[@]}"}" \
    --list allowed_paths "${#TK_ALLOWED[@]}" "${TK_ALLOWED[@]+"${TK_ALLOWED[@]}"}" > "$OUT/cx-run.json"
}

# run_checks DIR: the repo's setup, then every routes command, in DIR (a gate checkout); logs
# in $OUT/gate/. Sets GATE_VERDICT green|red|env and GATE_WHY.
run_checks() {
  local dir="$1" c n=0 lim
  GATE_VERDICT=green GATE_WHY=""
  mkdir -p -- "$OUT/gate"
  lim="$(secs_of "$(cx_opt default_timeout)")"
  if [ -n "$RT_SETUP" ]; then
    bg_wait bash -c "$IN_DIR" _ "$dir" "${lim}s" "$RT_SETUP" \
      > "$OUT/gate/setup.log" 2>&1 < /dev/null
    if [ "$BG_RC" != 0 ]; then GATE_VERDICT=env GATE_WHY="setup failed in the gate checkout (exit $BG_RC; $OUT/gate/setup.log)"; return 0; fi
  fi
  for c in "${CMDS[@]+"${CMDS[@]}"}"; do
    n=$((n + 1))
    bg_wait bash -c "$IN_DIR" _ "$dir" "${lim}s" "$c" \
      > "$OUT/gate/check-$n.log" 2>&1 < /dev/null
    if [ "$BG_RC" != 0 ]; then GATE_VERDICT=red GATE_WHY="'$c' failed (exit $BG_RC; $OUT/gate/check-$n.log)"; return 0; fi
  done
}

# ------------------------------------------------------------------ --finish
if [ -n "$FINISH" ]; then
  ID="$FINISH"
  OUT="$CXH/out/$ID"
  [ -f "$OUT/cx-run.json" ] || cx_usage_error "no cx-run task $ID ($OUT/cx-run.json is missing; a Phase 1 hand run finishes with the skill's Step 3)"
  [ -n "$DRY" ] || ensure_runtime
  st() { norm field "$OUT/cx-run.json" "$1" 2>/dev/null; }
  ADAPTER="$(st adapter)" MODE="$(st mode)" TOP="$(st top)" BASE="$(st base)" WT="$(st wt)" EXEC="$(st exec)"
  REPO_GH="$(st repo_gh)" RT_SETUP="$(st setup)"
  CMDS=()
  mapfile -t CMDS < <(norm field-lines "$OUT/cx-run.json" commands 2>/dev/null)
  [ -n "$ADAPTER" ] && [ -f "$RT/scripts/adapters/$ADAPTER.sh" ] || cx_signal FAILED 2 "unreadable $OUT/cx-run.json"
  [ -d "$TOP" ] || cx_signal FAILED 2 "the repository $TOP of task $ID is gone"
  # A finished task is not finished again (each finish would book the run in the ledger again).
  RS=""
  [ ! -f "$OUT/result.json" ] || RS="$(norm field "$OUT/result.json" status 2>/dev/null)"
  case "$ADAPTER" in
    claude)
      [ -z "$RS" ] || [ "$RS" = dispatched ] || cx_usage_error "task $ID is already finished (status $RS); a new run needs a new --id (or --reuse-worktree)" ;;
    copilot-cloud)
      GV="$(norm field "$OUT/result.json" gate 2>/dev/null)"
      if [ -n "$RS" ] && [ -z "$PR" ] && [ -n "$GV" ] && [ "$GV" != null ]; then
        cx_usage_error "task $ID is already gated (gate $GV); to gate the pull request again (after new commits), pass --pr N"
      fi ;;
    *)
      [ -z "$RS" ] || cx_usage_error "task $ID is already finished (status $RS): its run ended inside cx-run" ;;
  esac
  run_busy "$OUT" && cx_usage_error "task $ID is running: wait for it (cx-job wait) before --finish"
  if [ -n "$DRY" ]; then
    printf 'cx-run dry run: nothing changed\n--finish %s: the post-run steps of a %s task (%s mode) in %s\n' "$ID" "$ADAPTER" "$MODE" "$TOP"
    exit 0
  fi
  run_lock
  LEDGER_MARK=ledger.finish.done
  case "$ADAPTER" in
    claude)
      [ "$(norm field "$OUT/claude.meta.json" variant 2>/dev/null)" = dispatch ] || cx_usage_error "task $ID ran claude --headless; it needs no --finish"
      if [ "$MODE" = write ]; then
        [ -d "$WT" ] || cx_signal FAILED 2 "the worktree $WT of task $ID is gone"
        write_checks 1
      else
        norm obj finished:bool 1 > "$OUT/checks.json"
        GATE="$(st gate)"
        [ -z "$GATE" ] || cx_wt_remove "$TOP" "$GATE"
        GATE=""
      fi
      finish_result ;;
    copilot-cloud)
      if [ -z "$PR" ]; then PR="$(norm field "$OUT/result.json" cloud.pr 2>/dev/null)"; fi
      [[ $PR =~ ^[0-9]+$ ]] || cx_usage_error "no pull request is known for $ID yet: pass --pr N once the agent opened it (ghcp-cloud list)"
      C="$(bash "$RT/scripts/adapters/copilot-cloud.sh" fetch --out "$OUT" --repo "$TOP" --pr "$PR" --gh-repo "$REPO_GH")" \
        || cx_signal FAILED 2 "cannot fetch pull/$PR/head of ${REPO_GH:-the task repository} into $TOP (or it is not that pull request's head; $OUT/copilot-cloud.fetch.err)"
      GATE="$(cx_wt_gate "$TOP" "$C" "$ID")" || cx_signal FAILED 2 "cannot create a gate checkout of $C"
      cx_wt_rangestat "$TOP" "$BASE" "$C" "$OUT"
      DS="$CX_WT_DIFFSTAT"
      run_checks "$GATE"
      GV="$GATE_VERDICT" GR="$GATE_WHY"
      NOTES=("gate checkout of pull/$PR/head: $GATE ($( [ "$GV" = green ] && echo removed || echo kept for inspection)); read $OUT/changed.txt against allowed_paths and the protected set (G4) before anything merges")
      case "$GV" in
        env) norm obj stop:json "$(norm obj status env_failed reason "$GR")" > "$OUT/checks.json" ;;
        *) norm obj finished:bool 1 diff:bool "$CX_WT_DIFF" diffstat "${DS:-}" commit "$C" cancelled:bool "$CANCELLED" \
             branch "pull/$PR/head" base "$BASE" gate "$GV" gate_reason "$GR" notes:json "$(norm json-list "${NOTES[@]}")" > "$OUT/checks.json" ;;
      esac
      if [ "$GV" = green ]; then cx_wt_remove "$TOP" "$GATE"; GATE=""; else KEEP_GATE=1; fi
      [ -z "$GR" ] || cx_note "$GR"
      finish_result ;;
    *)
      [ "$MODE" = write ] && [ -d "$WT" ] || cx_usage_error "task $ID ($ADAPTER, $MODE) has nothing to finish"
      write_checks 1
      finish_result ;;
  esac
fi

# ------------------------------------------------------------------ the task
[ -z "$FAMILY" ] || [ "$MODE" = review ] || cx_usage_error "--family is for --mode review"
[ -z "$BRANCH$DIFF_FILE" ] || [ "$MODE" = review ] || cx_usage_error "--branch and --diff are for --mode review"
if [ "$MODE" = review ]; then
  [ -n "$BRANCH" ] || [ -n "$DIFF_FILE" ] || cx_usage_error "--mode review needs --branch REF (e.g. cx/<id>) or --diff FILE"
  [ -z "$BRANCH" ] || [ -z "$DIFF_FILE" ] || cx_usage_error "--branch and --diff do not combine"
  case "$FAMILY:$EXEC" in
    gemini:|gemini:agy) EXEC=agy ;;
    gpt:|gpt:copilot) EXEC=copilot ;;
    :) EXEC=agy; FAMILY=gemini ;;
    :agy|:copilot|:grok|:claude) ;;
    *) cx_usage_error "--family $FAMILY and --exec $EXEC disagree" ;;
  esac
  [ "$EXEC" != auto ] && [ "$EXEC" != copilot-cloud ] || cx_usage_error "--mode review runs on agy, copilot, grok or claude"
fi
if [ "$MODE" = read ]; then
  [ -n "$EXEC" ] || EXEC=grok
  [ "$EXEC" != auto ] && [ "$EXEC" != copilot-cloud ] || cx_usage_error "--mode read runs on grok, agy, copilot or claude"
fi
[ -n "$EXEC" ] || EXEC=auto
[ "$EXEC" = auto ] || [ "$EXEC" = copilot ] || [ -z "$FUSION" ] || cx_usage_error "--fusion needs --exec copilot"
[ "$EXEC" = claude ] || [ -z "$HEADLESS" ] || cx_usage_error "--headless is for --exec claude"
[ -z "$TASK_FILE" ] || [ "$HAVE_TEXT" = 0 ] || cx_usage_error "--task-file and a task text do not combine"
if [ "$MODE" != review ]; then
  [ -n "$TASK_FILE" ] || [ "$HAVE_TEXT" = 1 ] || cx_usage_error "missing the task: --task-file F, a quoted task text, or - for stdin"
fi
if [ -n "$TASK_FILE" ]; then
  cx_path_in_var TASK_FILE "$TASK_FILE"
  [ -f "$TASK_FILE" ] || cx_usage_error "no such task file: $TASK_FILE"
  cx_task_meta "$TASK_FILE" || cx_usage_error "$CX_TASK_WHY"
fi
[ "$HAVE_TEXT" = 0 ] || [ -n "${TASK_TEXT//[[:space:]]/}" ] || cx_usage_error "the task text is empty"
if [ -n "$ID" ] && [ -n "$TK_ID" ] && [ "$ID" != "$TK_ID" ]; then
  cx_usage_error "--id $ID differs from the task file's id $TK_ID"
fi
[ -n "$ID" ] || ID="$TK_ID"

resolve_repo
if [ "$MODE" = review ] && [ -n "$BRANCH" ]; then
  TARGET="$(git -C "$TOP" rev-parse --verify -q "$BRANCH^{commit}" 2>/dev/null)" || TARGET=""
  [ -n "$TARGET" ] || cx_usage_error "--branch '$BRANCH' is not a commit in $TOP"
  if [ -n "$BASE_REF" ]; then resolve_base "$BASE_REF"
  else BASE="$(git -C "$TOP" merge-base HEAD "$TARGET" 2>/dev/null)" || cx_usage_error "no merge base of HEAD and $BRANCH"; fi
else
  resolve_base "${BASE_REF:-${TK_BASE:-HEAD}}"
  [ "$MODE" != read ] || TARGET="$BASE"
fi
if [ -n "$DIFF_FILE" ]; then
  cx_path_in_var DIFF_FILE "$DIFF_FILE"
  [ -s "$DIFF_FILE" ] || cx_usage_error "--diff $DIFF_FILE is missing or empty"
  TARGET="$BASE"
fi
load_routes
CMDS=()
if [ "$TK_HAS_CMDS" = 1 ]; then CMDS=("${TK_CMDS[@]+"${TK_CMDS[@]}"}"); else CMDS=("${RT_CMDS[@]+"${RT_CMDS[@]}"}"); fi
for c in "${ALLOW[@]+"${ALLOW[@]}"}"; do CMDS+=("$c"); done

if [ -z "$ID" ]; then
  if [ "$MODE" = write ]; then ID="$(gen_id t)"; else ID="$(gen_id r)"; fi
fi
OUT="$CXH/out/$ID"
WT_ROOT="$(cx_wt_root "$TOP")" || cx_usage_error "option worktree_root lies inside $TOP and no default is usable"
WT="" GATE=""
[ "$MODE" != write ] || [ "$EXEC" = copilot-cloud ] || WT="$WT_ROOT/$(basename -- "$TOP")-$ID"

# The id must be free (or reused on purpose, and then not running): checked before the dry run, so
# cx-job start's --dry-run preflight refuses a taken id before it starts a job.
if [ -e "$OUT" ] && [ -z "$REUSE" ]; then
  cx_usage_error "the id $ID is taken on this computer ($OUT exists): pick another --id, or --reuse-worktree for a re-dispatch"
fi
if [ "$MODE" = write ] && [ -n "$WT" ] && [ -z "$REUSE" ]; then
  git -C "$TOP" show-ref --verify --quiet "refs/heads/cx/$ID" && cx_usage_error "branch cx/$ID already exists in $TOP (pick another --id, or pass --reuse-worktree)"
  [ ! -e "$WT" ] || cx_usage_error "$WT already exists (pick another --id, or pass --reuse-worktree)"
fi
run_busy "$OUT" && cx_usage_error "task $ID is running: wait for it (cx-job wait) or stop it (cx-job kill) before a re-dispatch"

if [ "$EXEC" = auto ]; then
  [ -z "$DRY" ] && ensure_runtime
  case "$(eff_or high)" in max|low) EXEC=claude; explain "claude: chosen: effort $(eff_or high) stays with Claude (section 6.3)" ;; *) choose_auto ;; esac
fi
ADAPTER="$(lane_adapter "$EXEC")"

# ------------------------------------------------------------------ --dry-run / --explain
if [ -n "$DRY" ]; then
  P_DRY=""
  [ "$MODE" != read ] || [ -n "$TASK_FILE" ] || P_DRY="$TASK_TEXT"
  [ "$MODE" != review ] || P_DRY="$(review_prompt)"
  lane_args "$ADAPTER"
  printf 'cx-run dry run: nothing created, no executor started\n'
  printf 'repo: %s\nbase: %s\nid: %s\nmode: %s\nexec: %s\n' "$TOP" "$BASE" "$ID" "$MODE" "$EXEC"
  if [ "$MODE" = write ] && [ -n "$WT" ]; then printf 'worktree: %s (branch cx/%s, created from the base)\n' "$WT" "$ID"
  elif [ "$MODE" != write ]; then printf 'checkout: a detached gate checkout of %s under %s/gate/\n' "${TARGET:-$BASE}" "$CXH"; fi
  printf 'out: %s\n' "$OUT"
  if [ -n "$TASK_FILE" ]; then printf 'task: %s (line-1 JSON ok)\n' "$TASK_FILE"
  elif [ "$MODE" != review ]; then printf 'task: free text (%s characters), wrapped into templates/task.md\n' "${#TASK_TEXT}"; fi
  printf 'setup: %s\n' "${RT_SETUP:-none}"
  printf 'allowed commands: %s\n' "$( [ "${#CMDS[@]}" -gt 0 ] && printf '%s; ' "${CMDS[@]}" | sed 's/; $//' || echo none)"
  if [ "$EXEC" != copilot-cloud ]; then
    RS_ARGS=()
    for c in "${CMDS[@]+"${CMDS[@]}"}"; do RS_ARGS+=(--cmd "$c"); done
    printf 'cx-route (%s/routes/%s/cx-route, snapshotted at dispatch): %s\n' "$CXH" "$ID" \
      "$(norm route-snapshot --dry-run --routes "$TOP/.cx/routes.json" --out "$OUT" --dir "${WT:-$TOP}" --id "$ID" "${RS_ARGS[@]+"${RS_ARGS[@]}"}" | sed 's/$/;/' | tr '\n' ' ' | sed 's/; $//')"
  fi
  for c in "${EXPLAIN_LINES[@]+"${EXPLAIN_LINES[@]}"}"; do printf 'explain: %s\n' "$c"; done
  if [ -n "$EXPLAIN" ] && [ "${#EXPLAIN_LINES[@]}" = 0 ]; then
    if probe "$ADAPTER"; then printf 'explain: %s: --exec %s; preflight green (cached: %s)\n' "$EXEC" "$EXEC" "$PRB_CACHED"
    else printf 'explain: %s: --exec %s; preflight %s: %s (cached: %s)\n' "$EXEC" "$EXEC" "$PRB_STATUS" "$PRB_REASON" "$PRB_CACHED"; fi
  fi
  DWT="${WT:-${TARGET:+$CXH/gate/$ID.1}}"
  [ -n "$DWT" ] || DWT="$TOP"
  DP=()
  [ -z "$P_DRY" ] || DP=(--prompt "$P_DRY")
  [ -z "$TASK_FILE" ] || DP+=(--task-file "$TASK_FILE")
  bash "$RT/scripts/adapters/$ADAPTER.sh" argv --dry-run --wt "$DWT" "${DP[@]+"${DP[@]}"}" "${LARGS[@]}"
  rc=$?
  [ "$rc" = 0 ] || exit "$rc"
  exit 0
fi

# ------------------------------------------------------------------ preflight (free; before anything is created)
ensure_runtime
refresh_record
case "$EXEC" in agy|copilot|grok)
  if [ "$(eval "printf %s \"\${RT_POOL_$EXEC}\"")" = 0 ]; then
    cx_note "the $EXEC pool is off for this repository (.cx/routes.json pools.$EXEC false)"
    cx_signal NO_CAPACITY 28 "the $EXEC pool is disabled in .cx/routes.json"
  fi ;;
esac
if ! probe "$ADAPTER"; then
  [ "$PRB_CODE" != 1 ] || cx_usage_error "$PRB_REASON"
  cx_note "$PRB_REASON"
  cx_signal "$PRB_STATUS" "$PRB_CODE" "$PRB_REASON"
fi

# ------------------------------------------------------------------ out dir, worktree or checkout, contract
if [ -e "$OUT" ] && [ -z "$REUSE" ]; then
  cx_usage_error "the id $ID is taken on this computer ($OUT exists): pick another --id, or --reuse-worktree for a re-dispatch"
fi
mkdir -p -- "$OUT" || cx_signal FAILED 2 "cannot create $OUT"
# One cx-run per task: a re-dispatch while the first run still goes would delete its files.
run_lock
rm -f -- "$OUT/checks.json" "$OUT/result.json" "$OUT/rc" "$OUT/ledger.done" "$OUT/ledger.finish.done"
cx_wt_exclude "$TOP"
if [ "$MODE" = write ] && [ -n "$WT" ]; then
  cx_wt_create "$TOP" "$ID" "$BASE" "$WT" "$REUSE"
  rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 1 ] && cx_usage_error "$CX_WT_WHY"; cx_signal FAILED 2 "$CX_WT_WHY"; }
  # The worktree is marked running from its creation on (the adapter keeps the mark during its
  # run): every agy snapshot, in any thread, leaves it out while the repo's setup and the executor
  # change it, so a sibling task's own work is never taken for agy writing into another tree.
  if [ ! -e "$OUT/running" ]; then cx_wt_mark "$OUT" "$WT"; MARKED=1; fi
  DIR="$WT"
elif [ "$MODE" = write ]; then
  DIR=""
else
  GATE="$(cx_wt_gate "$TOP" "$TARGET" "$ID")" || cx_signal FAILED 2 "cannot create a gate checkout of ${TARGET} in $CXH/gate"
  DIR="$GATE"
fi

# The run's cx-route (DESIGN section 15.1): the task's checks, named from .cx/routes.json as it is
# now, into $OUT/routes.json and $CX_HOME/routes/<id>/cx-route (the worker's PATH has that
# directory; grok's profile reads $CX_HOME/routes, never another run's out directory). The worker
# runs checks only through it; an edit of the worktree's routes.json never reaches it.
RBIN="$CXH/routes/$ID"
rm -rf -- "${OUT:?}/bin" "${OUT:?}/routes.json" "${RBIN:?}"
if [ -n "$DIR" ]; then
  RS_ARGS=()
  for c in "${CMDS[@]+"${CMDS[@]}"}"; do RS_ARGS+=(--cmd "$c"); done
  norm route-snapshot --routes "$TOP/.cx/routes.json" --out "$OUT" --bin "$RBIN" --bash "$BASH" --dir "$DIR" --id "$ID" "${RS_ARGS[@]+"${RS_ARGS[@]}"}" \
    || { unmark; cx_signal FAILED 2 "cannot write the run's cx-route snapshot into $OUT and $RBIN"; }
fi

PROMPT=""
if [ -n "$TASK_FILE" ]; then
  cx_task_from_file "$OUT" "$TASK_FILE" || { unmark; cx_signal FAILED 2 "$CX_TASK_WHY"; }
elif [ "$MODE" = write ]; then
  printf '%s\n' "$TASK_TEXT" > "$OUT/task.txt"
  cx_task_from_text "$OUT" "$OUT/task.txt" "$ID" "$BASE" "$EXEC" "$(eff_or high)" "${CMDS[@]+"${CMDS[@]}"}" \
    || { unmark; cx_signal FAILED 2 "$CX_TASK_WHY"; }
fi
if [ "$MODE" = review ]; then
  if [ -n "$DIFF_FILE" ]; then cp -f -- "$DIFF_FILE" "$OUT/change.diff"
  else git -C "$TOP" diff "$BASE" "$TARGET" > "$OUT/change.diff" 2>/dev/null; fi
  if [ ! -s "$OUT/change.diff" ]; then
    cx_wt_remove "$TOP" "$GATE"
    cx_note "nothing to review: no change between ${BASE:0:12} and ${TARGET:0:12}"
    cx_signal EMPTY_OUTPUT 3 "nothing to review (empty diff)"
  fi
  mkdir -p -- "$GATE/.conductor" && cp -f -- "$OUT/change.diff" "$GATE/.conductor/change.diff"
  PROMPT="$(review_prompt)"
elif [ "$MODE" = read ] && [ -z "$TASK_FILE" ]; then
  PROMPT="$TASK_TEXT"
fi
if [ -f "$OUT/task.md" ] && [ -n "$DIR" ]; then
  cx_task_install "$OUT" "$DIR" || { unmark; cx_signal FAILED 2 "cannot copy the task contract into $DIR/.conductor/"; }
fi

lane_args "$ADAPTER"
AARGS=(--out "$OUT")
[ -z "$DIR" ] || AARGS+=(--wt "$DIR")
[ -z "$PROMPT" ] || AARGS+=(--prompt "$PROMPT")
[ ! -f "$OUT/task.md" ] || AARGS+=(--task-file "$OUT/task.md")
# prepare_argv: the adapter's argv files (adapter run writes them itself when they are missing;
# a run stopped before the executor needs them for its result).
prepare_argv() {
  local rc
  [ -f "$OUT/$ADAPTER.meta.json" ] && return 0
  bash "$RT/scripts/adapters/$ADAPTER.sh" argv "${AARGS[@]}" "${LARGS[@]}"
  rc=$?
  [ "$rc" = 0 ] || { [ "$rc" = 1 ] && exit 1; cx_signal FAILED 2 "the $ADAPTER adapter could not prepare the run (exit $rc)"; }
}
rm -f -- "$OUT/$ADAPTER.argv" "$OUT/$ADAPTER.env" "$OUT/$ADAPTER.meta.json" "$OUT/adapter.why"
save_state
[ "$MODE" != write ] || [ -z "$WT" ] || write_vars

# ------------------------------------------------------------------ setup (not charged to the executor)
if [ "$MODE" = write ] && [ -n "$WT" ] && [ -n "$RT_SETUP" ]; then
  bg_wait bash -c "$IN_DIR" _ "$WT" \
    "$(secs_of "$(cx_opt default_timeout)")s" "$RT_SETUP" > "$OUT/setup.log" 2>&1 < /dev/null
  if [ -n "$CANCELLED" ] || [ "$BG_RC" != 0 ]; then unmark; prepare_argv; fi
  if [ -n "$CANCELLED" ]; then
    norm obj stop:json "$(norm obj status cancelled reason "cancelled during the repo's setup")" > "$OUT/checks.json"
    NO_LEDGER=1 finish_result
  fi
  if [ "$BG_RC" != 0 ]; then
    stop_result env_failed "the repo's setup failed in $WT (exit $BG_RC; $OUT/setup.log): fix it before dispatching; the executor was not started"
  fi
fi

# ------------------------------------------------------------------ the executor
RAN=1
bg_wait bash "$RT/scripts/adapters/$ADAPTER.sh" run "${AARGS[@]}" "${LARGS[@]}" > "$OUT/adapter.out" < /dev/null
ARC="$BG_RC"
if [ "$ARC" != 0 ] && [ ! -f "$OUT/rc" ]; then
  case "$ARC" in
    28) st=no_capacity ;; 13) st=missing ;; 26) st=version_mismatch ;; 11) st=auth ;; 14) st=model_unavailable ;;
    130) st=cancelled ;; *) st=failed ;;
  esac
  # An adapter that a cancellation's signal ended before it wrote its rc file was cancelled too.
  [ -z "$CANCELLED" ] || st=cancelled
  [ "$MODE" = write ] && [ -n "$WT" ] && rm -f -- "$OUT/running"
  prepare_argv
  # The adapter's own reason (adapter.why: grok's per-run profile check, a sandbox file it
  # refused, a missing CLI, ...) goes into the result.
  WHY="$(head -c 400 "$OUT/adapter.why" 2>/dev/null | tr '\n' ' ')"
  WHY="${WHY% }"
  stop_result "$st" "the $ADAPTER lane stopped before its executor ran (exit $ARC)${WHY:+: $WHY}"
fi
if [ "$MODE" = write ] && [ -n "$WT" ] && { [ "$ADAPTER" != claude ] || [ -n "$HEADLESS" ]; }; then
  # finish_result keeps the running mark only for an ok change that waits for Step 3.
  write_checks 0
fi
if [ "$MODE" != write ]; then
  norm obj branch "${BRANCH:-}" commit "$TARGET" base "$BASE" cancelled:bool "$CANCELLED" > "$OUT/checks.json"
fi
if [ -n "$GATE" ] && { [ "$ADAPTER" != claude ] || [ -n "$HEADLESS" ]; }; then
  cx_wt_remove "$TOP" "$GATE"
  GATE=""
fi
# The claude dispatch's subagent works in the gate checkout until cx-run --finish removes it.
[ -z "$GATE" ] || KEEP_GATE=1
finish_result
