#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR disable=SC2034  # sourced library: callers read the CX_SLOT_* / CX_LAUNCH_* variables
# scripts/lib/locks.sh - cross-process pool slots and the agy launch lock (docs/DESIGN.md
# section 15.3), shared by every executor path on the executor host: the adapters under cx-run
# and cx-job (cx-run takes the slot for every executor run) and cx-wsl for its executor calls
# (the skill's two hand executor calls run through it). Calls forwarded from Git Bash run their
# WSL side here too, so they share the same files.
#
# Sourced, never run. Each pool has CAP slot files $CX_HOME/locks/<pool>.<n> (n = 1..CAP; pools
# agy, copilot, grok; CAP from options cap_agy, cap_copilot, cap_grok); a holder keeps an flock
# on one of them for the life of its run. The descriptor is inherited by every child unless the
# holder closes it there: cx-wsl hands it to the tool it execs (and to a detached ghcp-job or
# agy-job runner); an adapter closes it in its executor's keeper, so only the adapter holds it
# and nothing the executor leaves behind keeps the slot. Waiters poll every 2 s for up
# to CX_SLOT_WAIT_SECS (default 600) seconds; 0 means do not wait.
#
# agy has two more locks: $CX_HOME/locks/agy-launch (exclusive: agy launches never overlap)
# and $CX_HOME/locks/agy, the whole-run lock of the Phase 1 skill (taken shared here, so a
# step of an older skill copy, which takes it exclusively, never overlaps any slot holder).
# Lock order, everywhere: agy (shared), then the slot, then agy-launch.
#
# Nesting: every lock taken here is recorded in the exported CX_SLOT_FDS ("NAME=FD ..."); a
# child that inherited that descriptor (checked in /proc) reuses it instead of waiting for a
# second slot, so a step that holds an agy slot can run a command that would take one itself.
#
# Functions (rc 0 ok, 28 no capacity, 2 the lock directory is unusable or the pool is unknown):
#   cx_lock_acquire POOL CAP [WAIT_SECS]   a slot: CX_SLOT_POOL CX_SLOT_N CX_SLOT_FD CX_SLOT_FILE
#                                          (CX_SLOT_FD empty when inherited; CX_SLOT_N 0 when
#                                          flock is missing and the run goes unguarded);
#                                          CX_SLOT_WHY on 28; while it waits and CX_JOB_DIR is a
#                                          directory, $CX_JOB_DIR/queued holds the pool name
#   cx_lock_try POOL CAP                   the same without waiting
#   cx_lock_release                        closes the slot (and the agy shared lock)
#   cx_lock_launch [WAIT_SECS]             the agy launch lock: CX_LAUNCH_FD
#   cx_lock_launch_release                 closes it (cx-run's raw agy lane: at the init event)
#   cx_lock_cap POOL                       prints the pool's cap from the options (0 = disabled)
#   cx_lock_wait_secs                      prints CX_SLOT_WAIT_SECS, validated (default 600)
#   cx_slot_take POOL [WAIT_SECS]          for cx-wsl: cap from the options, the
#                                          slot, and for agy also the launch lock for the whole
#                                          call; on failure one note and one CX_SIGNAL
#                                          (NO_CAPACITY, exit 28), and it returns 28 (it never
#                                          exits, so a caller decides)

[ -n "${CX_PROG:-}" ] || CX_PROG=slot
# shellcheck source=common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
declare -F cx_opt >/dev/null 2>&1 || . "$CX_LIB/options.sh"

CX_LOCK_POLL_SECS=2
CX_LOCK_POOLS="agy copilot grok"

_cx_lock_now() { printf '%(%s)T' -1; }

# cx_lock_dir: prints $CX_HOME/locks (default ~/.conductor/locks), created with mode 0700;
# rc 2 when it cannot be created.
cx_lock_dir() {
  local ld="${CX_HOME:-${HOME:-}/.conductor}/locks"
  if [ ! -d "$ld" ]; then
    (umask 077 && mkdir -p -- "$ld") 2>/dev/null || return 2
  fi
  [ -w "$ld" ] || return 2
  printf '%s\n' "$ld"
}

# cx_lock_wait_secs: CX_SLOT_WAIT_SECS (an integer of seconds, 0 = no wait), else 600; an
# invalid value prints one note.
cx_lock_wait_secs() {
  local v="${CX_SLOT_WAIT_SECS-}"
  if [ -z "$v" ]; then
    printf '600\n'
  elif [[ $v =~ ^[0-9]{1,6}$ ]]; then
    printf '%s\n' "$((10#$v))"
  else
    cx_note "ignoring invalid CX_SLOT_WAIT_SECS='$v'; using 600"
    printf '600\n'
  fi
}

# cx_lock_cap POOL: the cap option of POOL (cap_agy, cap_copilot, cap_grok), validated. The
# options are loaded in a subshell, so no CLAUDE_PLUGIN_OPTION_* variable reaches the caller's
# environment (and through it the sibling wrappers).
cx_lock_cap() {
  case "${1-}" in agy|copilot|grok) ;; *) return 2 ;; esac
  (
    # shellcheck disable=SC2119  # no FILE: the default settings files
    [ -n "${CX_OPTIONS_LOADED:-}" ] || cx_load_options
    cx_opt "cap_$1"
  )
}

# _cx_lock_held NAME DIR: rc 0 when CX_SLOT_FDS records NAME=FD and this process inherited FD
# open on DIR/NAME; prints FD.
_cx_lock_held() {
  local name="$1" dir="$2" e fd want got
  [ -n "${CX_SLOT_FDS:-}" ] || return 1
  for e in $CX_SLOT_FDS; do
    [ "${e%%=*}" = "$name" ] || continue
    fd="${e#*=}"
    [[ $fd =~ ^[0-9]+$ ]] || continue
    if [ -d "/proc/$BASHPID/fd" ]; then
      want="$(cd -- "$dir" 2>/dev/null && pwd -P)/$name"
      got="$(readlink -- "/proc/$BASHPID/fd/$fd" 2>/dev/null)" || continue
      [ "$got" = "$want" ] || continue
    else
      { : >&"$fd"; } 2>/dev/null || continue
    fi
    printf '%s\n' "$fd"
    return 0
  done
  return 1
}

_cx_lock_mark() {  # NAME FD
  local e out=""
  for e in ${CX_SLOT_FDS:-}; do [ "${e%%=*}" = "$1" ] || out="${out:+$out }$e"; done
  export CX_SLOT_FDS="${out:+$out }$1=$2"
}

_cx_lock_unmark() {  # NAME
  local e out=""
  for e in ${CX_SLOT_FDS:-}; do [ "${e%%=*}" = "$1" ] || out="${out:+$out }$e"; done
  if [ -n "$out" ]; then export CX_SLOT_FDS="$out"; else unset CX_SLOT_FDS; fi
}

# _cx_lock_queued POOL|"": the job's queued marker (cx-job status reports queued while it exists).
_cx_lock_queued() {
  [ -n "${CX_JOB_DIR:-}" ] && [ -d "$CX_JOB_DIR" ] || return 0
  if [ -n "$1" ]; then
    printf '%s\n' "$1" > "$CX_JOB_DIR/queued" 2>/dev/null
  else
    rm -f -- "$CX_JOB_DIR/queued" 2>/dev/null
  fi
  return 0
}

_cx_lock_warned_flock=""
_cx_lock_have_flock() {
  command -v flock >/dev/null 2>&1 && return 0
  if [ -z "$_cx_lock_warned_flock" ]; then
    _cx_lock_warned_flock=1
    cx_note "flock (util-linux) is missing: running without a pool slot (cx-doctor D2)"
  fi
  return 1
}

# _cx_lock_slots POOL CAP DIR: one pass over the slot files; rc 0 with the slot taken.
_cx_lock_slots() {
  local pool="$1" cap="$2" dir="$3" n fd
  for ((n = 1; n <= cap; n++)); do
    { exec {fd}>>"$dir/$pool.$n"; } 2>/dev/null || return 2
    if flock -n "$fd" 2>/dev/null; then
      CX_SLOT_FD="$fd"
      CX_SLOT_N="$n"
      CX_SLOT_FILE="$dir/$pool.$n"
      return 0
    fi
    exec {fd}>&-
  done
  return 1
}

# cx_lock_acquire POOL CAP [WAIT_SECS]: see the header.
cx_lock_acquire() {
  local pool="${1-}" cap="${2-}" wait="${3-}" dir deadline now left n e fd rc waited=""
  CX_SLOT_POOL="$pool" CX_SLOT_N="" CX_SLOT_FD="" CX_SLOT_FILE="" CX_SLOT_WHY="" CX_SLOT_LEGACY_FD=""
  case " $CX_LOCK_POOLS " in *" $pool "*) ;; *) CX_SLOT_WHY="unknown pool '$pool'"; return 2 ;; esac
  [[ $cap =~ ^[0-9]+$ ]] || { CX_SLOT_WHY="invalid cap '$cap'"; return 2; }
  [ -n "$wait" ] || wait="$(cx_lock_wait_secs)"
  [[ $wait =~ ^[0-9]+$ ]] || wait=600
  if [ "$cap" -eq 0 ]; then
    CX_SLOT_WHY="the $pool pool is disabled (cap_$pool=0)"
    return 28
  fi
  dir="$(cx_lock_dir)" || { CX_SLOT_WHY="cannot create or write ${CX_HOME:-${HOME:-}/.conductor}/locks"; return 2; }
  _cx_lock_have_flock || { CX_SLOT_N=0; return 0; }
  # A slot this process inherited (a parent took it): reuse it.
  for e in ${CX_SLOT_FDS:-}; do
    e="${e%%=*}"
    n="${e#"$pool".}"
    [ "$n" != "$e" ] && [[ $n =~ ^[0-9]+$ ]] || continue
    if _cx_lock_held "$e" "$dir" >/dev/null; then
      CX_SLOT_N="$n" CX_SLOT_FILE="$dir/$e"
      return 0
    fi
  done
  now="$(_cx_lock_now)"
  deadline=$((now + wait))
  # agy: the Phase 1 skill's whole-run lock, shared (an older skill's step holds it exclusively).
  if [ "$pool" = agy ] && ! _cx_lock_held agy "$dir" >/dev/null; then
    { exec {fd}>>"$dir/agy"; } 2>/dev/null || { CX_SLOT_WHY="cannot open $dir/agy"; return 2; }
    if ! flock -s -n "$fd" 2>/dev/null; then
      cx_note "waiting up to ${wait} s for a Phase 1 agy step (the $dir/agy lock) to finish"
      _cx_lock_queued "$pool"
      waited=1
      if [ "$wait" -le 0 ] || ! flock -s -w "$wait" "$fd" 2>/dev/null; then
        exec {fd}>&-
        _cx_lock_queued ""
        CX_SLOT_WHY="a Phase 1 agy step held the agy lock for ${wait} s"
        return 28
      fi
    fi
    CX_SLOT_LEGACY_FD="$fd"
    _cx_lock_mark agy "$fd"
  fi
  while :; do
    _cx_lock_slots "$pool" "$cap" "$dir"
    rc=$?
    if [ "$rc" = 0 ]; then
      _cx_lock_mark "$pool.$CX_SLOT_N" "$CX_SLOT_FD"
      [ -z "$waited" ] || _cx_lock_queued ""
      return 0
    fi
    if [ "$rc" = 2 ]; then
      _cx_lock_queued ""
      cx_lock_release
      CX_SLOT_WHY="cannot open the slot files in $dir"
      return 2
    fi
    now="$(_cx_lock_now)"
    left=$((deadline - now))
    if [ "$left" -le 0 ]; then
      _cx_lock_queued ""
      cx_lock_release
      CX_SLOT_WHY="all $cap $pool slots stayed busy for ${wait} s"
      return 28
    fi
    if [ -z "$waited" ]; then
      waited=1
      _cx_lock_queued "$pool"
      cx_note "all $cap $pool slots are busy (cap_$pool=$cap); waiting up to ${wait} s"
    fi
    [ "$left" -lt "$CX_LOCK_POLL_SECS" ] || left="$CX_LOCK_POLL_SECS"
    sleep "$left"
  done
}

cx_lock_try() { cx_lock_acquire "${1-}" "${2-}" 0; }

# cx_lock_release: closes the slot and the agy shared lock this process took (an inherited
# slot is left to its owner).
cx_lock_release() {
  if [ -n "${CX_SLOT_FD:-}" ]; then
    exec {CX_SLOT_FD}>&-
    _cx_lock_unmark "$CX_SLOT_POOL.$CX_SLOT_N"
  fi
  if [ -n "${CX_SLOT_LEGACY_FD:-}" ]; then
    exec {CX_SLOT_LEGACY_FD}>&-
    _cx_lock_unmark agy
  fi
  CX_SLOT_FD="" CX_SLOT_LEGACY_FD="" CX_SLOT_N="" CX_SLOT_FILE=""
  return 0
}

# cx_lock_launch [WAIT_SECS]: the agy launch lock ($CX_HOME/locks/agy-launch), exclusive; rc 0
# (CX_LAUNCH_FD; empty when inherited), 28 after WAIT_SECS, 2 when it cannot be opened.
cx_lock_launch() {
  local wait="${1-}" dir fd
  CX_LAUNCH_FD="" CX_SLOT_WHY=""
  [ -n "$wait" ] || wait="$(cx_lock_wait_secs)"
  [[ $wait =~ ^[0-9]+$ ]] || wait=600
  dir="$(cx_lock_dir)" || { CX_SLOT_WHY="cannot create or write ${CX_HOME:-${HOME:-}/.conductor}/locks"; return 2; }
  _cx_lock_have_flock || return 0
  _cx_lock_held agy-launch "$dir" >/dev/null && return 0
  { exec {fd}>>"$dir/agy-launch"; } 2>/dev/null || { CX_SLOT_WHY="cannot open $dir/agy-launch"; return 2; }
  if ! flock -n "$fd" 2>/dev/null; then
    cx_note "another agy launch is in progress; waiting up to ${wait} s (agy launches never overlap: a hand-dispatched agy run holds the launch lock until it ends)"
    _cx_lock_queued agy
    if [ "$wait" -le 0 ] || ! flock -w "$wait" "$fd" 2>/dev/null; then
      exec {fd}>&-
      _cx_lock_queued ""
      CX_SLOT_WHY="another agy run held the agy launch lock for ${wait} s"
      return 28
    fi
    _cx_lock_queued ""
  fi
  CX_LAUNCH_FD="$fd"
  _cx_lock_mark agy-launch "$fd"
  return 0
}

cx_lock_launch_release() {
  if [ -n "${CX_LAUNCH_FD:-}" ]; then
    exec {CX_LAUNCH_FD}>&-
    _cx_lock_unmark agy-launch
  fi
  CX_LAUNCH_FD=""
  return 0
}

# _cx_slot_fail EXIT REASON: one note and one CX_SIGNAL (from a subshell, so the caller goes on).
_cx_slot_fail() {
  local code="$1" why="$2"
  if [ "$code" = 28 ]; then
    cx_note "no $CX_SLOT_POOL capacity: $why; use the next pool in the order"
    (cx_signal NO_CAPACITY 28 "no $CX_SLOT_POOL capacity: $why")
  else
    cx_note "pool slot: $why"
    (cx_signal FAILED 2 "pool slot: $why")
  fi
  return "$code"
}

# cx_slot_take POOL [WAIT_SECS]: see the header. The descriptors stay open in the calling shell
# (never call it in a subshell or a command substitution).
cx_slot_take() {
  local pool="${1-}" wait="${2-}" cap rc t0
  CX_SLOT_POOL="$pool"
  case " $CX_LOCK_POOLS " in *" $pool "*) ;; *) _cx_slot_fail 2 "unknown pool '$pool' (one of: $CX_LOCK_POOLS)"; return 2 ;; esac
  [ -n "$wait" ] || wait="$(cx_lock_wait_secs)"
  cap="$(cx_lock_cap "$pool")" || cap="${CX_OPT_DEFAULTS[cap_$pool]}"
  t0="$(_cx_lock_now)"
  cx_lock_acquire "$pool" "$cap" "$wait"
  rc=$?
  [ "$rc" = 0 ] || { _cx_slot_fail "$rc" "$CX_SLOT_WHY"; return "$rc"; }
  if [ "$pool" = agy ]; then
    wait=$((wait - ($(_cx_lock_now) - t0)))
    [ "$wait" -ge 0 ] || wait=0
    cx_lock_launch "$wait"
    rc=$?
    if [ "$rc" != 0 ]; then
      cx_lock_release
      CX_SLOT_POOL=agy
      _cx_slot_fail "$rc" "$CX_SLOT_WHY"
      return "$rc"
    fi
  fi
  return 0
}
