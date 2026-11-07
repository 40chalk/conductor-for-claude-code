#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR disable=SC2034  # sourced library: callers read the CX_WT_* variables
# scripts/lib/worktree.sh - task worktrees and gate checkouts for cx-run (docs/DESIGN.md sections
# 2.3, 6.4 and 15.1). Sourced, never run; executor host only.
#
# Every write task gets one worktree <worktree_root>/<repo>-<id> on branch cx/<id>, created from
# the task's base commit; worktree_root (option, default ~/.cx-wt) is one absolute directory
# outside every repository, so agy's single write_file grant covers every worktree and no main
# checkout. Read and review runs use a detached gate checkout $CX_HOME/gate/<id>.<n> instead.
# /.conductor (the task contract and the prompt file) is added once to the repository's
# info/exclude, so git add -A never stages it: no trailing slash, so a .conductor that an executor
# replaced by a symlink or a file is ignored too (/.conductor/ matches directories only). A
# .gitignore negation in the worktree still outranks it: cx-run refuses a gate checkout of a
# commit that tracks anything at .conductor, and never writes through a link there (cx_cdir).
#
# Functions:
#   cx_wt_root TOP              prints the absolute worktree root (an option inside TOP falls back
#                               to the default with a note); rc 1 when no usable root exists
#   cx_wt_exclude TOP           adds /.conductor to <git common dir>/info/exclude (0.2.1 and
#                               earlier wrote /.conductor/, which stays)
#   cx_wt_create TOP ID BASE WT [reuse]
#                               git worktree add -b cx/ID WT BASE; refuses an existing branch or
#                               path (rc 1, CX_WT_WHY) unless reuse, which needs WT to be a worktree
#                               of TOP on cx/ID; rc 2 when git fails
#   cx_wt_gate TOP COMMIT ID    a detached checkout of COMMIT at $CX_HOME/gate/ID.<n> (the first
#                               free n); prints its path; rc 2 when git fails
#   cx_wt_remove TOP DIR        git worktree remove --force DIR (rc ignored)
#   cx_wt_gcd DIR               sets CX_WT_GCD: the physical git common directory of DIR (a
#                               checkout the conductor trusts: the main checkout, never a worktree
#                               an executor wrote); rc 1 when DIR is no git checkout
#   cx_wt_admin GCD WT          sets CX_WT_GITDIR: WT's private git directory as the repository's
#                               own admin files name it (GCD/worktrees/<n>/gitdir is WT/.git),
#                               never as WT/.git says; rc 1 (CX_WT_WHY) when GCD has no entry for WT
#   cx_wt_gitdir GCD WT         cx_wt_admin, and WT/.git must still be the link file git wrote:
#                               a regular file whose one line "gitdir: <path>" names that
#                               directory; rc 1 (CX_WT_WHY) otherwise (the executor rewrote it)
#   cx_wt_git GITDIR WT ARGS... git ARGS in WT with --git-dir GITDIR --work-tree WT and
#                               CX_WT_GITC: the conductor's only way to run git in a worktree an
#                               executor wrote
#   cx_wt_changes TOP WT BASE OUT
#                               the executor's change against BASE, committed or not, untracked
#                               files included, through a scratch index (the worktree's own index
#                               is never touched): writes OUT/changed.txt (name-status) and sets
#                               CX_WT_DIFF (1|0), CX_WT_DIFFSTAT ("+A -R, N files" or ""),
#                               CX_WT_BRANCH (the worktree's branch, empty when detached),
#                               CX_WT_ADD_ERR (git add's first error line: a file it could not
#                               index, such as an embedded repository without a commit; the other
#                               files are still counted) and CX_WT_LINK (1, or 0 with CX_WT_WHY
#                               and rc 3 when WT/.git no longer links to its own git directory:
#                               no git runs in WT then)
#   cx_wt_rangestat TOP BASE C OUT
#                               the same facts for the commits BASE...C (a pull request head)
#   cx_wt_mark OUT WT           the running mark OUT/running (WT and its pwd -P form): agy's tree
#                               snapshots, in every thread, leave a marked worktree out
#
# Git in a worktree an executor wrote (section 15.1): every write lane may rewrite the worktree's
# .git file (it lies inside the worktree), and git would read the configuration of whatever
# directory it names (core.fsmonitor runs a command on git add, git status and git diff). So the
# conductor never lets git find the repository from the worktree: cx_wt_git names the private git
# directory the main repository's admin files give, with CX_WT_GITC (no fsmonitor, hooks, pager,
# ssh command or textconv, and no recursion into submodules or embedded repositories, whose own
# configuration would apply there; git passes the -c values on to every git it starts).

[ -n "${CX_PROG:-}" ] || CX_PROG=worktree
# shellcheck source=common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
declare -F cx_opt >/dev/null 2>&1 || . "$CX_LIB/options.sh"

CX_WT_WHY="" CX_WT_DIFF=0 CX_WT_DIFFSTAT="" CX_WT_BRANCH="" CX_WT_GCD="" CX_WT_GITDIR="" CX_WT_ADD_ERR="" CX_WT_LINK=1
CX_WT_GITC=(-c core.fsmonitor=false -c core.hooksPath=/dev/null -c core.pager=cat -c core.sshCommand=false
            -c diff.ignoreSubmodules=all -c submodule.recurse=false -c status.submoduleSummary=false)

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
  grep -qx '/.conductor' "$ex" 2>/dev/null && return 0
  mkdir -p -- "$gcd/info" 2>/dev/null
  # A last line without its newline would swallow the pattern.
  [ ! -s "$ex" ] || [ -z "$(tail -c 1 -- "$ex" 2>/dev/null)" ] || printf '\n' >> "$ex" 2>/dev/null
  printf '/.conductor\n' >> "$ex" 2>/dev/null
  return 0
}

cx_wt_create() {
  local top="$1" id="$2" base="$3" wt="$4" reuse="${5-}" br cur err
  CX_WT_WHY=""
  br="cx/$id"
  if [ -n "$reuse" ]; then
    # Never git -C "$wt": an earlier executor may have rewritten its .git (section 15.1).
    if [ -d "$wt" ] && cx_wt_gcd "$top" && cx_wt_gitdir "$CX_WT_GCD" "$wt" \
       && cur="$(cx_wt_git "$CX_WT_GITDIR" "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" && [ "$cur" = "$br" ]; then
      return 0
    fi
    CX_WT_WHY="--reuse-worktree: $wt is not a worktree of $top on branch $br${CX_WT_WHY:+ ($CX_WT_WHY)}"
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
  # git's stderr goes to a fresh mktemp file in the conductor's own scratch directory (never a
  # shared /tmp, which grok runs may write: cx_tmpdir).
  err="$(cx_mktemp cx-wt)" || { CX_WT_WHY="cannot create a scratch file in ${CX_HOME:-${HOME:-}/.conductor}/tmp"; return 2; }
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

cx_wt_gcd() {
  local g
  CX_WT_GCD=""
  g="$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [ -d "$g" ] || return 1
  CX_WT_GCD="$(_cx_wt_real "$g")" && [ -n "$CX_WT_GCD" ]
}

cx_wt_admin() {
  local gcd="$1" wt="$2" wtp g line
  CX_WT_GITDIR="" CX_WT_WHY=""
  wtp="$(_cx_wt_real "$wt")" && [ -n "$wtp" ] || { CX_WT_WHY="$wt does not exist"; return 1; }
  for g in "$gcd"/worktrees/*/gitdir; do
    [ -f "$g" ] || continue
    line=""
    IFS= read -r line < "$g" || [ -n "$line" ] || continue
    case "$line" in /*) ;; *) line="${g%/gitdir}/$line" ;; esac
    [ "$(_cx_wt_real "${line%/.git}")" = "$wtp" ] || continue
    CX_WT_GITDIR="$(_cx_wt_real "${g%/gitdir}")"
    [ -n "$CX_WT_GITDIR" ] && return 0
  done
  CX_WT_WHY="$wt is not a worktree of the repository at $gcd (no entry in its worktrees/)"
  return 1
}

cx_wt_gitdir() {
  local gcd="$1" wt="$2" c link
  cx_wt_admin "$gcd" "$wt" || return 1
  if [ -L "$wt/.git" ] || [ ! -f "$wt/.git" ]; then
    CX_WT_WHY="$wt/.git is no longer the link file git wrote (now $( [ -L "$wt/.git" ] && echo "a symlink" || { [ -d "$wt/.git" ] && echo "a directory"; } || echo "missing or special"))"
    return 1
  fi
  c="$(head -c 4097 -- "$wt/.git" 2>/dev/null)"
  link="${c#gitdir: }"
  if [ "${#c}" -gt 4096 ] || [ "$link" = "$c" ] || [ -z "$link" ] || [[ $link == *$'\n'* ]]; then
    CX_WT_WHY="$wt/.git is no longer one gitdir: line"
    return 1
  fi
  case "$link" in /*) ;; *) link="$wt/$link" ;; esac
  if [ "$(_cx_wt_real "$link")" != "$CX_WT_GITDIR" ]; then
    CX_WT_WHY="$wt/.git points at $link, not at its own git directory $CX_WT_GITDIR"
    return 1
  fi
  return 0
}

cx_wt_git() {
  local gd="$1" wt="$2"
  shift 2
  git -C "$wt" --git-dir="$gd" --work-tree="$wt" "${CX_WT_GITC[@]}" "$@"
}

cx_wt_changes() {
  local top="$1" wt="$2" base="$3" out="$4" idx err gd
  CX_WT_DIFF=0 CX_WT_DIFFSTAT="" CX_WT_BRANCH="" CX_WT_ADD_ERR="" CX_WT_LINK=1
  : > "$out/changed.txt"
  if ! cx_wt_gcd "$top"; then CX_WT_WHY="$top is not a git checkout"; CX_WT_LINK=0; return 3; fi
  if ! cx_wt_gitdir "$CX_WT_GCD" "$wt"; then CX_WT_LINK=0; return 3; fi
  gd="$CX_WT_GITDIR"
  CX_WT_BRANCH="$(cx_wt_git "$gd" "$wt" symbolic-ref -q --short HEAD 2>/dev/null)" || CX_WT_BRANCH=""
  # The scratch index and git's stderr live in the conductor's own scratch directory: a grok run
  # going on meanwhile may write /tmp, and an index changed between git add and git diff would
  # hide changes from changed.txt (cx_tmpdir).
  idx="$(cx_mktemp cx-idx)" || return 2
  err="$(cx_mktemp cx-add)" || { rm -f -- "$idx"; return 2; }
  if [ -f "$gd/index" ]; then cp -f -- "$gd/index" "$idx"; else rm -f -- "$idx"; fi
  # --ignore-errors: a file git cannot index (an embedded repository without a commit) must not
  # hide every other change of the run.
  if ! GIT_INDEX_FILE="$idx" cx_wt_git "$gd" "$wt" add -A --ignore-errors >/dev/null 2>"$err"; then
    CX_WT_ADD_ERR="$(grep -m 1 -E '^(error|fatal):' "$err" 2>/dev/null | head -c 300)"
    [ -n "$CX_WT_ADD_ERR" ] || CX_WT_ADD_ERR="git add -A failed"
  fi
  rm -f -- "$err"
  GIT_INDEX_FILE="$idx" cx_wt_git "$gd" "$wt" diff --cached --no-renames --no-ext-diff --no-textconv --name-status "$base" > "$out/changed.txt" 2>/dev/null
  _cx_wt_numstat < <(GIT_INDEX_FILE="$idx" cx_wt_git "$gd" "$wt" diff --cached --no-renames --no-ext-diff --no-textconv --numstat "$base" 2>/dev/null)
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
