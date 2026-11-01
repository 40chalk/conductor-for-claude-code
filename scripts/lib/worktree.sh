#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR disable=SC2034  # sourced library: callers read the CX_WT_* variables
# scripts/lib/worktree.sh - task worktrees and gate checkouts for cx-run (docs/DESIGN.md sections
# 2.3, 6.4 and 15.1). Sourced, never run; executor host only.
#
# Every write task gets one worktree <worktree_root>/<repo>-<id> on branch cx/<id>, created from
# the task's base commit; worktree_root (option, default ~/.cx-wt) is one absolute directory
# outside every repository, so agy's single write_file grant covers every worktree and no main
# checkout. Read and review runs use a detached gate checkout $CX_HOME/gate/<id>.<n> instead.
# /.conductor/ (the task contract and the prompt file) is added once to the repository's
# info/exclude, so it is never committed.
#
# Functions:
#   cx_wt_root TOP              prints the absolute worktree root (an option inside TOP falls back
#                               to the default with a note); rc 1 when no usable root exists
#   cx_wt_exclude TOP           adds /.conductor/ to <git common dir>/info/exclude
#   cx_wt_create TOP ID BASE WT [reuse]
#                               git worktree add -b cx/ID WT BASE; refuses an existing branch or
#                               path (rc 1, CX_WT_WHY) unless reuse, which needs WT to be a worktree
#                               of TOP on cx/ID; rc 2 when git fails
#   cx_wt_gate TOP COMMIT ID    a detached checkout of COMMIT at $CX_HOME/gate/ID.<n> (the first
#                               free n); prints its path; rc 2 when git fails
#   cx_wt_remove TOP DIR        git worktree remove --force DIR (rc ignored)
#   cx_wt_changes WT BASE OUT   the executor's change against BASE, committed or not, untracked
#                               files included, through a scratch index (the worktree's own index
#                               is never touched): writes OUT/changed.txt (name-status) and sets
#                               CX_WT_DIFF (1|0), CX_WT_DIFFSTAT ("+A -R, N files" or ""),
#                               CX_WT_BRANCH (the worktree's branch, empty when detached)
#   cx_wt_rangestat TOP BASE C OUT
#                               the same facts for the commits BASE...C (a pull request head)
#   cx_wt_mark OUT WT           the running mark OUT/running (WT and its pwd -P form): agy's tree
#                               snapshots, in every thread, leave a marked worktree out

[ -n "${CX_PROG:-}" ] || CX_PROG=worktree
# shellcheck source=common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
declare -F cx_opt >/dev/null 2>&1 || . "$CX_LIB/options.sh"

CX_WT_WHY="" CX_WT_DIFF=0 CX_WT_DIFFSTAT="" CX_WT_BRANCH=""

_cx_wt_real() { (cd -- "$1" 2>/dev/null && pwd -P); }

# _cx_wt_under DIR PARENT: rc 0 when DIR is PARENT or lies below it (physical paths when they exist).
_cx_wt_under() {
  local d p
  d="$(_cx_wt_real "$1")" || d="$1"
  [ -n "$d" ] || d="$1"
  p="$(_cx_wt_real "$2")" || p="$2"
  [ -n "$p" ] || p="$2"
  case "$d/" in "$p"/*) return 0 ;; esac
  return 1
}

cx_wt_root() {
  local top="$1" root def
  root="$(cx_expand_tilde "$(cx_opt worktree_root)")"
  while [ "${#root}" -gt 1 ] && [ "${root%/}" != "$root" ]; do root="${root%/}"; done
  if [ -n "$top" ] && _cx_wt_under "$root" "$top"; then
    def="$(cx_expand_tilde "${CX_OPT_DEFAULTS[worktree_root]}")"
    cx_note "ignoring invalid option worktree_root='$root' (inside the repository $top); using '${CX_OPT_DEFAULTS[worktree_root]}'"
    root="$def"
    _cx_wt_under "$root" "$top" && return 1
  fi
  case "$root" in /?*) ;; *) return 1 ;; esac
  printf '%s\n' "$root"
}

cx_wt_exclude() {
  local top="$1" gcd ex
  gcd="$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 0
  ex="$gcd/info/exclude"
  grep -qx '/.conductor/' "$ex" 2>/dev/null && return 0
  mkdir -p -- "$gcd/info" 2>/dev/null
  printf '/.conductor/\n' >> "$ex" 2>/dev/null
  return 0
}

cx_wt_create() {
  local top="$1" id="$2" base="$3" wt="$4" reuse="${5-}" br cur err
  CX_WT_WHY=""
  br="cx/$id"
  if [ -n "$reuse" ]; then
    if [ -d "$wt" ] && cur="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" && [ "$cur" = "$br" ] \
       && [ "$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" = "$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]; then
      return 0
    fi
    CX_WT_WHY="--reuse-worktree: $wt is not a worktree of $top on branch $br"
    return 1
  fi
  if git -C "$top" show-ref --verify --quiet "refs/heads/$br"; then
    CX_WT_WHY="branch $br already exists in $top (pick another --id, or pass --reuse-worktree)"
    return 1
  fi
  if [ -e "$wt" ]; then
    CX_WT_WHY="$wt already exists (pick another --id, or pass --reuse-worktree)"
    return 1
  fi
  mkdir -p -- "$(dirname -- "$wt")" || { CX_WT_WHY="cannot create $(dirname -- "$wt")"; return 2; }
  # git's stderr goes to a fresh mktemp file (never a predictable name in a shared /tmp).
  err="$(mktemp "${TMPDIR:-/tmp}/cx-wt.XXXXXXXX")" || { CX_WT_WHY="mktemp failed in ${TMPDIR:-/tmp}"; return 2; }
  if ! git -C "$top" worktree add -q -b "$br" "$wt" "$base" 2>"$err"; then
    CX_WT_WHY="git worktree add failed: $(head -n 1 "$err" 2>/dev/null)"
    rm -f -- "$err"
    return 2
  fi
  rm -f -- "$err"
  return 0
}

cx_wt_gate() {
  local top="$1" commit="$2" id="$3" gd n=1
  gd="${CX_HOME:-${HOME:-}/.conductor}/gate"
  mkdir -p -- "$gd" || return 2
  while [ -e "$gd/$id.$n" ]; do n=$((n + 1)); done
  git -C "$top" worktree add -q --detach "$gd/$id.$n" "$commit" >/dev/null 2>&1 || return 2
  printf '%s\n' "$gd/$id.$n"
}

cx_wt_remove() {
  git -C "$1" worktree remove --force "$2" >/dev/null 2>&1 || rm -rf -- "${2:?}"
  git -C "$1" worktree prune >/dev/null 2>&1
  return 0
}

cx_wt_changes() {
  local wt="$1" base="$2" out="$3" idx real
  CX_WT_DIFF=0 CX_WT_DIFFSTAT="" CX_WT_BRANCH=""
  CX_WT_BRANCH="$(git -C "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" || CX_WT_BRANCH=""
  idx="$(mktemp "${TMPDIR:-/tmp}/cx-idx.XXXXXXXX")" || return 2
  real="$(git -C "$wt" rev-parse --path-format=absolute --git-path index 2>/dev/null)"
  if [ -n "$real" ] && [ -f "$real" ]; then cp -f -- "$real" "$idx"; else rm -f -- "$idx"; fi
  GIT_INDEX_FILE="$idx" git -C "$wt" add -A >/dev/null 2>&1
  GIT_INDEX_FILE="$idx" git -C "$wt" diff --cached --no-renames --name-status "$base" > "$out/changed.txt" 2>/dev/null
  _cx_wt_numstat < <(GIT_INDEX_FILE="$idx" git -C "$wt" diff --cached --no-renames --numstat "$base" 2>/dev/null)
  rm -f -- "$idx"
  return 0
}

# _cx_wt_numstat: reads git diff --numstat on stdin; sets CX_WT_DIFF and CX_WT_DIFFSTAT.
_cx_wt_numstat() {
  local a r n nf=0 add=0 del=0
  while IFS=$'\t' read -r a r n; do
    [ -n "$n" ] || continue
    nf=$((nf + 1))
    [[ $a =~ ^[0-9]+$ ]] && add=$((add + a))
    [[ $r =~ ^[0-9]+$ ]] && del=$((del + r))
  done
  CX_WT_DIFF=0 CX_WT_DIFFSTAT=""
  if [ "$nf" -gt 0 ]; then
    CX_WT_DIFF=1
    CX_WT_DIFFSTAT="+$add -$del, $nf file$([ "$nf" = 1 ] || echo s)"
  fi
}

cx_wt_rangestat() {
  local top="$1" base="$2" c="$3" out="$4"
  CX_WT_BRANCH=""
  git -C "$top" diff --no-renames --name-status "$base...$c" > "$out/changed.txt" 2>/dev/null
  _cx_wt_numstat < <(git -C "$top" diff --no-renames --numstat "$base...$c" 2>/dev/null)
}

cx_wt_mark() {
  printf '%s\n' "$2" "$(cd -- "$2" 2>/dev/null && pwd -P)" > "$1/running"
}
