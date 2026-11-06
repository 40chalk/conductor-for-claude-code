#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# cx-job - background cx-run jobs (docs/DESIGN.md section 15.5). A job is one cx-run in a
# detached runner (its own session, setsid), so it survives the Bash call, the Claude Code turn
# and, forwarded from Git Bash, the wsl.exe call that started it.
#
# Usage: cx-job start [cx-run args...]        stdout: JOB_ID <id>; returns at once
#        cx-job status <id>                   queued | running | done rc=N | failed rc=N |
#                                             cancelled | unknown (the runner died without a status)
#        cx-job wait <id> [--timeout DUR]     blocks until the job ends, then like result; 75 when
#                                             DUR (30s, 10m, 2h) expires first (default: no limit)
#        cx-job result <id>                   stdout: the job's digest (cx-run's stdout); stderr: the
#                                             job's CX_* lines; exit = the job's rc; 75 while running
#        cx-job kill <id>                     cancels it: rc 130 first, then TERM to the runner's
#                                             process group and session and to every executor session
#                                             it recorded, KILL after 10 s (agy ignores TERM)
#        cx-job list [--all]                  running and queued jobs and those of the last 24 hours
#                                             (--all: every job): id, status, start time, arguments
#        cx-job unpause agy                   resumes agy dispatch after a wrong_tree pause
#        cx-job -h|--help | --version
#
# <id> is YYYYmmdd-HHMMSS-<4 hex>, or any unique prefix of it. A task id (cx-run's --id) is
# never taken for a job: one that names no job exits 1 with a note naming the JOB_ID of the one
# job that has it, and a prefix of one JOB_ID that is also another job's task id is ambiguous
# (exit 1); only a full JOB_ID is always its own job. The registry is
# $CX_HOME/jobs/<id>/ (argv, meta, pid, pid_start, sids, queued, out, err, rc). start checks the
# arguments with cx-run --dry-run first (exit 1 or 42: refused, nothing started; a taken id, a
# running task and an unmappable path are refused here, not later in the job) and reads a task
# given as - from stdin into the job; the task text is always stored after "--", so the job's
# cx-run never takes it for an option. A job waits for its pool slot inside the runner (status queued),
# so start returns at once; cx-job wait exits 75 for queued and running jobs when DUR expires.
# Wait for a job with ONE background Bash call (run_in_background, timeout 7200000): cx-job wait
# <id>, which notifies on exit; never by re-checking across turns. Forwarded from Git Bash, that
# call also keeps WSL running. kill signals only a runner proven by its start time (pid reuse)
# and only executor sessions whose processes carry the job's CX_JOB_DIR. Runs from the runtime
# copy ($CX_HOME/runtime/<version>), so a plugin update never swaps files under a running job.
#
# Exit codes: 0 ok; 1 usage error, unknown or ambiguous id, a cx-run preflight refusal (and for
# wait and result a job whose cx-run refused the request: its notes, no CX_SIGNAL); 2 FAILED
# (the registry cannot be written, the runner died without a status); 75 RUNNING (result while
# the job runs, wait after --timeout); for wait and result the job's own rc (cx-run's codes: 2,
# 3, 10-16, 20-28, 40-43, 130; a runner that hit its wall clock: 12), and the last CX_SIGNAL
# always names that exit; 130 CANCELLED (wait interrupted: the job keeps running); 40
# FORWARD_FAILED, 41 RUNTIME_MISSING, 42 PATH_UNMAPPABLE (start: a Git Bash path with no WSL
# form, refused before the job starts) (Git Bash forwarding); 43 HOST_UNSUPPORTED (a cloud
# session).

set -uo pipefail
unset CDPATH
CX_PROG=cx-job
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/options.sh
. "$HERE/lib/options.sh"

[ $# -gt 0 ] && cx_help_version "$1"
if [ "${1-}" != __runner ]; then
  cx_forward_if_needed cx-job "$@"
fi

CXH="${CX_HOME:-$HOME/.conductor}"
JOBS="$CXH/jobs"

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# The start time of PID (field 22 of /proc/PID/stat, after the parenthesized command name).
proc_start() {
  local s
  s="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  s="${s##*) }"
  # shellcheck disable=SC2086  # the fields are split on purpose
  set -- $s
  [ $# -ge 20 ] || return 1
  printf '%s\n' "${20}"
}

# task_id_of JD: the task id (--id X or --id=X) among the job's cx-run arguments, before the
# task text; nothing when the id came from a task file or was generated.
task_id_of() {
  local i
  local -a A=()
  [ -f "$1/argv" ] && mapfile -d '' -t A < "$1/argv" || return 1
  for ((i = 0; i < ${#A[@]}; i++)); do
    case "${A[$i]}" in
      --) break ;;
      --id) printf '%s\n' "${A[$((i + 1))]:-}"; return 0 ;;
      --id=*) printf '%s\n' "${A[$i]#*=}"; return 0 ;;
      --exec|--mode|--family|--model|--effort|--fusion|--task-file|--repo|--base|--branch|--diff|--allow|--timeout|--finish|--pr|--agy-mode|--gh-repo|--base-branch)
        i=$((i + 1)) ;;   # a value: never read as an option (cx-run.sh has the same list)
    esac
  done
  return 1
}

# task_jobs ID: the JOB_IDs of the jobs whose task id is ID, one per line.
task_jobs() {
  local d
  [ -n "${1-}" ] || return 0
  shopt -s nullglob
  for d in "$JOBS"/*/; do
    d="${d%/}"
    [ "$(task_id_of "$d" 2>/dev/null)" = "$1" ] && printf '%s\n' "${d##*/}"
  done
  shopt -u nullglob
}

# no_job ID: the note for an ID that names no job. When ID is the task id of exactly one job,
# it says which JOB_ID that is; the caller still exits 1 (nothing acts on the resolved job).
no_job() {
  local id="$1" t=()
  [ -n "$id" ] || return 1
  mapfile -t t < <(task_jobs "$id")
  if [ "${#t[@]}" = 1 ]; then
    cx_note "no job $id in $JOBS: $id is the task id of job ${t[0]}; cx-job takes the JOB_ID that cx-run --background printed"
    return 0
  fi
  return 1
}

# jobdir ID: the job directory of ID or of the unique job whose id starts with it. A prefix
# that is also the task id of another job (cx-run takes ids of digits alone, such as 20261106)
# is ambiguous: neither job is acted on.
jobdir() {
  local id="${1-}" d m=() n t=() o=()
  [[ $id =~ ^[0-9A-Za-z][0-9A-Za-z-]*$ ]] || { no_job "$id" || cx_note "invalid job id '$id'"; return 1; }
  if [ -d "$JOBS/$id" ]; then printf '%s\n' "$JOBS/$id"; return 0; fi
  shopt -s nullglob
  for d in "$JOBS/$id"*; do [ -d "$d" ] && m+=("$d"); done
  shopt -u nullglob
  n="${#m[@]}"
  if [ "$n" = 1 ]; then
    mapfile -t t < <(task_jobs "$id")
    for d in "${t[@]+"${t[@]}"}"; do [ "$d" = "${m[0]##*/}" ] || o+=("$d"); done
    if [ "${#o[@]}" -gt 0 ]; then
      n="job ${o[0]}"; [ "${#o[@]}" = 1 ] || n="jobs ${o[*]}"
      cx_note "job id $id is ambiguous: it starts the JOB_ID ${m[0]##*/} and is the task id of $n; give the full JOB_ID that cx-run --background printed"
      return 1
    fi
    printf '%s\n' "${m[0]}"; return 0
  fi
  if [ "$n" = 0 ]; then no_job "$id" || cx_note "no job $id in $JOBS"; else cx_note "job id $id is ambiguous (${n} jobs start with it)"; fi
  return 1
}

# runner_alive JD: rc 0 when the runner of JD is alive and proven to be it: its start time
# matches pid_start, or (no start time recorded) ps shows cx-job.sh __runner JD.
runner_alive() {
  local jd="$1" pid want got args
  pid="$(cat "$jd/pid" 2>/dev/null)" || return 1
  [[ $pid =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  want="$(cat "$jd/pid_start" 2>/dev/null)"
  if [ -n "$want" ]; then
    got="$(proc_start "$pid")" || got=""
    [ -n "$got" ] && [ "$got" = "$want" ] && return 0
    [ -z "$got" ] || return 1
  fi
  args="$(ps -o args= -p "$pid" 2>/dev/null)" || return 1
  case "$args" in *"cx-job.sh __runner $jd"*) return 0 ;; esac
  return 1
}

# write_rc JD N: rc atomically, unless it exists (a kill wrote 130 first).
write_rc() {
  local jd="$1" tmp="$1/rc.tmp.$$"
  printf '%s\n' "$2" > "$tmp" || return 1
  ln -- "$tmp" "$jd/rc" 2>/dev/null
  rm -f -- "$tmp"
  return 0
}

job_status() {  # JD: prints the status word(s)
  local jd="$1" rc
  if [ -f "$jd/rc" ]; then
    rc="$(cat "$jd/rc" 2>/dev/null)"
    case "$rc" in
      0) echo "done rc=0" ;;
      130) echo cancelled ;;
      *) echo "failed rc=${rc:-?}" ;;
    esac
  elif runner_alive "$jd"; then
    if [ -e "$jd/queued" ]; then echo queued; else echo running; fi
  elif [ ! -s "$jd/pid" ] && [ -n "$(find "$jd/argv" -newermt '-10 seconds' 2>/dev/null)" ]; then
    echo queued
  else
    echo unknown
  fi
}

# sid_ours SID JD: rc 0 when a process of session SID carries CX_JOB_DIR=JD (pid reuse guard).
sid_ours() {
  local sid="$1" jd="$2" p
  [[ $sid =~ ^[0-9]+$ ]] || return 1
  for p in $(pgrep -s "$sid" 2>/dev/null); do
    { tr '\0' '\n' < "/proc/$p/environ"; } 2>/dev/null | grep -qxF "CX_JOB_DIR=$jd" && return 0
  done
  return 1
}

# signal_job JD SIG: the runner's group and session (when proven) and every recorded executor
# session that is still ours.
signal_job() {
  local jd="$1" sig="$2" pid s
  if runner_alive "$jd"; then
    pid="$(cat "$jd/pid")"
    kill "-$sig" -- "-$pid" 2>/dev/null
    pkill "-$sig" -s "$pid" 2>/dev/null
  fi
  [ -f "$jd/sids" ] || return 0
  while IFS= read -r s; do
    if sid_ours "$s" "$jd"; then
      kill "-$sig" -- "-$s" 2>/dev/null
      pkill "-$sig" -s "$s" 2>/dev/null
    fi
  done < <(sort -u "$jd/sids")
}

job_busy() {  # JD: rc 0 while the runner or a recorded executor session still runs
  local jd="$1" s
  runner_alive "$jd" && return 0
  [ -f "$jd/sids" ] || return 1
  while IFS= read -r s; do sid_ours "$s" "$jd" && return 0; done < <(sort -u "$jd/sids")
  return 1
}

do_result() {  # JD
  local jd="$1" rc st last
  if [ ! -f "$jd/rc" ]; then
    st="$(job_status "$jd")"
    if [ "$st" = unknown ]; then
      cx_note "job $(basename -- "$jd"): the runner died without recording a status (log: $jd/err)"
      cx_signal FAILED 2 "the job's runner died without a status"
    fi
    cx_note "job $(basename -- "$jd") is $st"
    cx_signal RUNNING 75 "the job is still $st"
  fi
  rc="$(cat "$jd/rc" 2>/dev/null)"
  [[ $rc =~ ^[0-9]+$ ]] || rc=2
  cat "$jd/out" 2>/dev/null
  if [ "$rc" = 1 ]; then
    # The job's cx-run refused the request (exit 1 carries no CX_SIGNAL): its notes, exit 1.
    grep -v '^CX_' "$jd/err" >&2 2>/dev/null
    exit 1
  fi
  [ ! -s "$jd/err" ] || cx_note "full log: $jd/err"
  grep '^CX_' "$jd/err" 2>/dev/null | grep -v '^CX_SIGNAL ' >&2
  [ "$rc" = 0 ] && exit 0
  # The last CX_SIGNAL and the exit always agree: the job's own signal is relayed only when it
  # names the job's rc (a wall-clock kill or a cx-job kill that landed after it overrules it).
  last="$(grep '^CX_SIGNAL ' "$jd/err" 2>/dev/null | tail -n 1)"
  case "$rc" in
    124|137) cx_signal TIMEOUT 12 "the job's runner hit its wall clock" ;;
  esac
  if [ -n "$last" ] && [[ $last =~ \"exit\":\ *([0-9]+)[,}] ]] && [ "${BASH_REMATCH[1]}" = "$rc" ]; then
    printf '%s\n' "$last" >&2
    exit "$rc"
  fi
  case "$rc" in
    130) cx_signal CANCELLED 130 "the job was cancelled" ;;
  esac
  st="$(cx_status_for_exit "$rc")" || { cx_signal FAILED 2 "the job ended with exit $rc"; }
  cx_signal "$st" "$rc" "the job ended with exit $rc"
}

secs_of() {  # DUR -> seconds; rc 1 when invalid
  [[ ${1-} =~ ^([0-9]{1,7})([smh]?)$ ]] || return 1
  local n=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in m) n=$((n * 60)) ;; h) n=$((n * 3600)) ;; esac
  printf '%s\n' "$n"
}

# ------------------------------------------------------------------ the runner (internal)
if [ "${1-}" = __runner ]; then
  JD="${2-}"
  [ -d "$JD" ] && [ -f "$JD/argv" ] || exit 2
  # A detached job holds nothing of its starter: every inherited descriptor above 2 is closed
  # (a pipe of the caller's, such as a forwarder's stderr relay, would keep that caller waiting
  # for the job), except the one bash reads this script from; the job takes its own pool slot.
  SELF="$(readlink -f -- "${BASH_SOURCE[0]}")"
  for FDP in "/proc/$$/fd"/*; do
    FDN="${FDP##*/}"
    [[ $FDN =~ ^[0-9]+$ ]] && [ "$FDN" -gt 2 ] || continue
    [ "$(readlink -f -- "$FDP" 2>/dev/null)" = "$SELF" ] && continue
    eval "exec $FDN>&-" 2>/dev/null
  done
  unset CX_SLOT_FDS
  printf '%s\n' "$$" > "$JD/pid.tmp" && mv -f -- "$JD/pid.tmp" "$JD/pid"
  proc_start "$$" > "$JD/pid_start" 2>/dev/null
  export CX_JOB_DIR="$JD"
  ARGV=()
  mapfile -d '' -t ARGV < "$JD/argv"
  # The wall clock of the whole job: the run's timeout, the repo's setup (default_timeout), the
  # slot wait and the adapters' grace (agy: 5 minutes), plus 2 minutes.
  # shellcheck disable=SC2119  # no FILE: the default settings files
  cx_load_options
  T="" i=0
  for ((i = 0; i < ${#ARGV[@]}; i++)); do
    case "${ARGV[$i]}" in
      --) break ;;
      --timeout) T="${ARGV[$((i + 1))]:-}"; i=$((i + 1)) ;;
      --timeout=*) T="${ARGV[$i]#*=}" ;;
      --exec|--mode|--family|--model|--effort|--fusion|--task-file|--id|--repo|--base|--branch|--diff|--allow|--finish|--pr|--agy-mode|--gh-repo|--base-branch)
        i=$((i + 1)) ;;   # a value: never read as an option (cx-run.sh has the same list)
    esac
  done
  D="$(secs_of "$(cx_opt default_timeout)")" || D=1800
  T="$(secs_of "$T")" || T="$D"
  W="${CX_SLOT_WAIT_SECS:-600}"
  [[ $W =~ ^[0-9]{1,6}$ ]] || W=600
  LIMIT=$((T + D + 10#$W + 420))
  timeout --kill-after=30s "${LIMIT}s" bash "$HERE/cx-run.sh" "${ARGV[@]+"${ARGV[@]}"}" > "$JD/out" 2> "$JD/err" < /dev/null &
  CPID=$!
  trap 'kill -TERM "$CPID" 2>/dev/null' TERM INT
  while :; do
    wait "$CPID" 2>/dev/null
    RC=$?
    kill -0 "$CPID" 2>/dev/null || break
  done
  if [ "$RC" -gt 128 ]; then
    wait "$CPID" 2>/dev/null
    R2=$?
    [ "$R2" = 127 ] || RC=$R2
  fi
  write_rc "$JD" "$RC"
  rm -f -- "$JD/queued"
  exit 0
fi

# ------------------------------------------------------------------ commands
CMD="${1-}"
[ $# -gt 0 ] && shift
case "$CMD" in
  start)
    cx_py_ok || cx_signal FAILED 2 "python3 (3.8 or newer, run as python3 -I) is required on the executor host"
    # The task text (- read from stdin now, or the one argument after --) is stored after "--" at
    # the end, so the job's cx-run never parses it as an option.
    ARGS=() HAVE_TEXT=0 TEXT=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --) shift
            [ $# = 1 ] || cx_usage_error "-- takes exactly one argument after it: the task text"
            [ "$HAVE_TEXT" = 0 ] || cx_usage_error "only one task (a text, or - for stdin)"
            HAVE_TEXT=1; TEXT="$1"; shift; break ;;
        --background) ;;
        -) [ "$HAVE_TEXT" = 0 ] || cx_usage_error "only one task (a text, or - for stdin)"; HAVE_TEXT=1; TEXT="$(cat)" ;;
        *) ARGS+=("$1") ;;
      esac
      shift
    done
    [ "$HAVE_TEXT" = 0 ] || ARGS+=(-- "$TEXT")
    cx_runtime_ensure
    RT="$CX_RT"
    # The preflight: cx-run --dry-run with the same arguments (--finish has a dry run of its own).
    # A refusal (1) or a path with no WSL form (42) never changes, so nothing is started.
    PRE="$(cx_mktemp cx-job-pre)" || cx_signal FAILED 2 "cannot create a scratch file in $CXH/tmp"
    bash "$RT/scripts/cx-run.sh" --dry-run "${ARGS[@]+"${ARGS[@]}"}" > /dev/null 2> "$PRE" < /dev/null
    prc=$?
    if [ "$prc" = 1 ] || [ "$prc" = 42 ]; then
      grep -v '^CX_' "$PRE" >&2
      why="$(sed -n 's/^CX_SIGNAL .*"reason": "\([^"]*\)".*/\1/p' "$PRE" | tail -n 1)"
      rm -f -- "$PRE"
      cx_note "nothing started"
      [ "$prc" = 1 ] && exit 1
      cx_signal PATH_UNMAPPABLE 42 "${why:-a path of the request has no WSL form}"
    fi
    rm -f -- "$PRE"
    mkdir -p -- "$JOBS" || cx_signal FAILED 2 "cannot create $JOBS"
    for n in 1 2 3 4 5 6 7 8; do
      ID="$(date -u +%Y%m%d-%H%M%S)-$(od -An -N2 -tx1 /dev/urandom 2>/dev/null | tr -d ' \n')"
      mkdir -- "$JOBS/$ID" 2>/dev/null && break
      ID=""
    done
    [ -n "$ID" ] || cx_signal FAILED 2 "cannot create a job directory in $JOBS"
    JD="$JOBS/$ID"
    printf '%s\0' "${ARGS[@]+"${ARGS[@]}"}" > "$JD/argv" || cx_signal FAILED 2 "cannot write $JD"
    { printf 'id=%s\nstarted_at=%s\ncwd=%s\ncaller=%s\nruntime=%s\n' "$ID" "$(stamp)" "$PWD" "${CX_CALLER:-local}" "$RT"; } > "$JD/meta"
    : > "$JD/out"; : > "$JD/err"; : > "$JD/sids"
    setsid nohup bash "$RT/scripts/cx-job.sh" __runner "$JD" < /dev/null > /dev/null 2>&1 &
    for n in $(seq 1 40); do [ -s "$JD/pid" ] && break; sleep 0.05; done
    printf 'JOB_ID %s\n' "$ID"
    if [ "${CX_FORWARDED:-}" = 1 ]; then
      cx_note "wait for it with one background Bash call: cx-job wait $ID (that call also keeps WSL running)"
    fi
    exit 0 ;;
  status)
    [ $# = 1 ] || cx_usage_error "usage: cx-job status <id>"
    jd="$(jobdir "$1")" || exit 1
    job_status "$jd"
    exit 0 ;;
  result)
    [ $# = 1 ] || cx_usage_error "usage: cx-job result <id>"
    jd="$(jobdir "$1")" || exit 1
    do_result "$jd" ;;
  wait)
    [ $# -ge 1 ] || cx_usage_error "usage: cx-job wait <id> [--timeout DUR]"
    id="$1"; shift
    LIM=""
    while [ $# -gt 0 ]; do
      case "$1" in
        --timeout) [ $# -ge 2 ] || cx_usage_error "--timeout needs a duration"; LIM="$(secs_of "$2")" || cx_usage_error "--timeout must be 30s, 10m, 2h or seconds"; shift 2 ;;
        --timeout=*) LIM="$(secs_of "${1#*=}")" || cx_usage_error "--timeout must be 30s, 10m, 2h or seconds"; shift ;;
        *) cx_usage_error "unknown argument: $1" ;;
      esac
    done
    jd="$(jobdir "$id")" || exit 1
    trap 'cx_note "the wait was interrupted; job $(basename -- "$jd") keeps running"; cx_signal CANCELLED 130 "the wait was interrupted"' INT TERM HUP
    T0=$SECONDS
    while [ ! -f "$jd/rc" ]; do
      st="$(job_status "$jd")"
      [ "$st" != unknown ] || break
      if [ -n "$LIM" ] && [ $((SECONDS - T0)) -ge "$LIM" ]; then
        printf '%s\n' "$st"
        cx_note "job $(basename -- "$jd") is still $st after ${LIM} s"
        cx_signal RUNNING 75 "the job is still $st"
      fi
      sleep 1 &
      wait $!
    done
    trap - INT TERM HUP
    do_result "$jd" ;;
  kill)
    [ $# = 1 ] || cx_usage_error "usage: cx-job kill <id>"
    jd="$(jobdir "$1")" || exit 1
    id="$(basename -- "$jd")"
    if [ -f "$jd/rc" ] && ! job_busy "$jd"; then
      printf 'job %s already ended: %s\n' "$id" "$(job_status "$jd")"
      exit 0
    fi
    write_rc "$jd" 130
    signal_job "$jd" TERM
    for n in $(seq 1 20); do
      job_busy "$jd" || break
      sleep 0.5
    done
    if job_busy "$jd"; then
      signal_job "$jd" KILL
      for n in $(seq 1 10); do job_busy "$jd" || break; sleep 0.2; done
    fi
    rm -f -- "$jd/queued"
    printf 'cancelled %s\n' "$id"
    exit 0 ;;
  list)
    ALL=0
    case "${1-}" in "") ;; --all) ALL=1 ;; *) cx_usage_error "usage: cx-job list [--all]" ;; esac
    [ -d "$JOBS" ] || exit 0
    shopt -s nullglob
    for jd in "$JOBS"/*/; do
      jd="${jd%/}"
      [ -f "$jd/argv" ] || continue
      st="$(job_status "$jd")"
      if [ "$ALL" = 0 ] && [ -f "$jd/rc" ] && [ -z "$(find "$jd/rc" -newermt '-24 hours' 2>/dev/null)" ]; then continue; fi
      started="$(sed -n 's/^started_at=//p' "$jd/meta" 2>/dev/null)"
      mapfile -d '' -t A < "$jd/argv"
      printf -v args '%q ' "${A[@]+"${A[@]}"}"
      args="${args% }"
      [ "${#args}" -le 100 ] || args="${args:0:97}..."
      printf '%s  %-12s  %s  %s\n' "$(basename -- "$jd")" "$st" "${started:--}" "$args"
    done
    shopt -u nullglob
    exit 0 ;;
  unpause)
    [ "${1-}" = agy ] && [ $# = 1 ] || cx_usage_error "usage: cx-job unpause agy"
    f="$CXH/state/agy-paused"
    if [ -e "$f" ]; then
      printf 'agy was paused: %s\n' "$(head -c 400 "$f" | tr '\n' ' ')"
      rm -f -- "$f"
      printf 'agy dispatch resumed\n'
    else
      printf 'agy is not paused\n'
    fi
    exit 0 ;;
  "") cx_usage_error "missing command (start, status, wait, result, kill, list, unpause)" ;;
  *) cx_usage_error "unknown command: $CMD" ;;
esac
