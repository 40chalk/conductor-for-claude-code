#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# cx-init - writes the conductor repo bundle into a git repository (docs/DESIGN.md section 9).
#
# Usage: cx-init [--dir <path>] [--dry-run] [--force] [--json] [--only agents|routes|copilot]...
#                [--setup <cmd>] [--test <cmd>] [--lint <cmd>] [--typecheck <cmd>]
#        cx-init --user-grants [--dir <path>] [--dry-run] [--json]
#        cx-init -h|--help | --version
#
# Writes, at the root of the repository that holds --dir (default: the current directory):
#   AGENTS.md                         the conductor block (<!-- cx:begin ... --> ... <!-- cx:end -->)
#   .github/copilot-instructions.md   the same kind of block, for Copilot code review and agent
#   .cx/routes.json                   setup and check commands, protected paths, pools (schema v1)
# and adds /.conductor/ to the repository's info/exclude. A file without the block gets the
# block appended (text outside it is never changed); a block or routes.json that differs is a
# conflict: nothing at all is written and the exit is 5, unless --force rewrites the selected
# files (only the block, or the whole routes.json). It never creates or edits CLAUDE.md,
# anything under .claude/, .gitignore or .gitattributes.
#
#   --dir <path>     a directory inside a non-bare git work tree (Windows, \\wsl.localhost\...,
#                    Git Bash /c/... and wsl:/... forms are mapped when forwarded)
#   --only <file>    agents, routes or copilot; repeatable; the others are reported "skipped"
#   --dry-run        write nothing (not even the exclude line); exits as the real run would
#   --force          rewrite conflicting selected files
#   --json           one JSON document on stdout instead of the text report
#   --setup/--test/--lint/--typecheck <cmd>
#                    override a detected command; an empty value ('') means none
#
# --user-grants (DESIGN section 15.7) writes the user-level settings a repository's executor runs
# need, idempotently: the grok sandbox profile of the repository at --dir (default: the current
# directory, when it is one), cx-<repo>-<8 hex>, from templates/grok-sandbox.toml (extends
# grok's strict profile; read_only the repository's git directory and ~/.conductor/out), added
# to ~/.grok/sandbox.toml or rewritten when it differs (cx-run's grok lane writes the same
# profile on the repository's first grok run, so this is optional), and it removes the invalid
# cx-workspace profile conductor 0.2.0 wrote there. agy needs no user-level grant (each raw agy
# run passes its own --settings): a note names the global grants 0.2.0 left in
# ~/.gemini/antigravity-cli/settings.json, which it never edits. Grok's auto-update setting is
# yours: nothing pins a CLI version. A file that changes is first copied to <file>.cx-bak; a
# result that would not parse is a CONFLICT and nothing is written (exit 5).
#
# Detection (repo root only): npm/pnpm/yarn/bun, Python (uv, poetry, pytest, ruff, mypy), Go,
# Rust, then tests/run-tests.sh and Makefile targets. stdout: create/update/same/skipped/CONFLICT
# lines and "detected: <slot> = <cmd>" lines; stderr: notes, CX_INIT, and CX_SIGNAL EXISTS on
# exit 5. On Git Bash it forwards into WSL (cx-doctor --help explains the forwarder).
#
# Exit codes: 0 ok; 1 usage error (not inside a git work tree, bad argument); 2 FAILED (no
# python3 or git, unexpected error); 5 EXISTS (a selected file differs, or --user-grants met a
# file it cannot merge; nothing written);
# 40 FORWARD_FAILED and 41 RUNTIME_MISSING (Git Bash forwarding); 42 PATH_UNMAPPABLE (--dir or
# the forwarded cwd has no WSL path); 43 HOST_UNSUPPORTED (a cloud session, Cygwin,
# exec_host=local on Git Bash).

set -uo pipefail
unset CDPATH
CX_PROG=cx-init
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/options.sh
. "$HERE/lib/options.sh"

[ $# -gt 0 ] && cx_help_version "$1"
cx_forward_if_needed cx-init "$@"
# shellcheck disable=SC2119  # no FILE: the default settings files
cx_load_options

DIR=""
HAVE_DIR=0
GRANTS=0
DRY=0
FORCE=0
JSON=0
PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|--version) cx_help_version "$1" ;;
    --dir)
      [ $# -ge 2 ] || cx_usage_error "--dir needs a path"
      DIR="$2"; HAVE_DIR=1; shift 2 ;;
    --dir=*) DIR="${1#*=}"; HAVE_DIR=1; shift ;;
    --dry-run) DRY=1; shift ;;
    --user-grants) GRANTS=1; shift ;;
    --force) FORCE=1; shift ;;
    --json) JSON=1; shift ;;
    --only|--only=*)
      if [ "$1" = --only ]; then
        [ $# -ge 2 ] || cx_usage_error "--only needs agents, routes or copilot"
        v="$2"; shift 2
      else
        v="${1#*=}"; shift
      fi
      case "$v" in
        agents|routes|copilot) PASS+=("--only=$v") ;;
        *) cx_usage_error "--only takes agents, routes or copilot, not '$v'" ;;
      esac ;;
    --setup|--test|--lint|--typecheck)
      [ $# -ge 2 ] || cx_usage_error "$1 needs a command (use '' for none)"
      PASS+=("$1=$2"); shift 2 ;;
    --setup=*|--test=*|--lint=*|--typecheck=*) PASS+=("$1"); shift ;;
    *) cx_usage_error "unknown argument: $1" ;;
  esac
done

cx_py_ok || cx_signal FAILED 2 "python3 (3.8 or newer, run as python3 -I) is required on the executor host"
command -v git >/dev/null 2>&1 || cx_signal FAILED 2 "git is required"

if [ "$HAVE_DIR" = 1 ]; then
  [ -n "$DIR" ] || cx_usage_error "--dir needs a path"
  cx_path_in_var DIR "$DIR"
else
  DIR="$PWD"
fi

if [ "$GRANTS" = 1 ]; then
  [ "$FORCE" = 0 ] && [ "${#PASS[@]}" = 0 ] || cx_usage_error "--user-grants takes only --dir, --dry-run and --json"
  # shellcheck source=lib/worktree.sh
  . "$HERE/lib/worktree.sh"
  UG=(--home "$HOME" --grok-home "${GROK_HOME:-$HOME/.grok}" --profile "$(cx_opt grok_sandbox_profile)"
      --template "$CX_ROOT/templates/grok-sandbox.toml" --out-root "${CX_HOME:-$HOME/.conductor}/out")
  TOP=""
  if [ -d "$DIR" ] && TOP="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)" && [ -n "$TOP" ]; then
    UG+=(--repo "$TOP")
    G="$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [ -d "$G" ] && UG+=(--gcd "$(cd -- "$G" && pwd -P)")
    RT_CMDS=()
    o="$(python3 -I "$CX_LIB/normalize.py" routes --file "$TOP/.cx/routes.json")" && eval "$o"
    [ "${RT_FOUND:-0}" = 1 ] || cx_note "no .cx/routes.json in $TOP (cx-init writes one): no command grants"
    for c in "${RT_CMDS[@]+"${RT_CMDS[@]}"}"; do UG+=(--cmd "$c"); done
  else
    TOP=""
  fi
  ROOT="$(cx_wt_root "$TOP")" || cx_usage_error "option worktree_root lies inside $TOP and no default is usable"
  UG+=(--root "$ROOT")
  [ "$DRY" = 1 ] && UG+=(--dry-run)
  [ "$JSON" = 1 ] && UG+=(--json)
  cx_py user-grants "${UG[@]}"
  rc=$?
  case "$rc" in
    0) exit 0 ;;
    5) cx_signal EXISTS 5 "a grant file cannot be merged; nothing was written (fix it by hand, then run cx-init --user-grants again)" ;;
    *) cx_signal FAILED 2 "writing the user grants failed (rc $rc)" ;;
  esac
fi
[ -d "$DIR" ] || cx_usage_error "not a directory: $DIR"
if [ "$(git -C "$DIR" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]; then
  cx_usage_error "not inside a git work tree (bare repositories are not supported): $DIR"
fi
TOP="$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null)"
[ -n "$TOP" ] && [ -d "$TOP" ] || cx_usage_error "cannot find the repository root of $DIR"
SUB=()
REAL_DIR="$(cd -- "$DIR" && pwd -P)"
REAL_TOP="$(cd -- "$TOP" && pwd -P)"
[ "$REAL_DIR" = "$REAL_TOP" ] || SUB=(--subdir)

GCD="$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || GCD=""
if [ -z "$GCD" ]; then
  GCD="$(git -C "$TOP" rev-parse --git-common-dir 2>/dev/null)" || GCD=""
  case "$GCD" in ""|/*) ;; *) GCD="$TOP/$GCD" ;; esac
fi
[ -n "$GCD" ] || cx_signal FAILED 2 "cannot find the git directory of $TOP"
EXCLUDE="$GCD/info/exclude"
AUTOCRLF="$(git -C "$TOP" config --get core.autocrlf 2>/dev/null)" || AUTOCRLF=""

PLAN="$(cx_py init-plan --repo "$TOP" "${PASS[@]+"${PASS[@]}"}" "--exclude-file=$EXCLUDE" \
  "--autocrlf=$AUTOCRLF" "${SUB[@]+"${SUB[@]}"}")" || cx_signal FAILED 2 "repository detection failed"

APPLY=(--dir "$TOP" --templates "$CX_ROOT/templates/repo-bundle" "--plan=$PLAN")
[ "$DRY" = 1 ] && APPLY+=(--dry-run)
[ "$FORCE" = 1 ] && APPLY+=(--force)
[ "$JSON" = 1 ] && APPLY+=(--json)
cx_py init-apply "${APPLY[@]}"
rc=$?
case "$rc" in
  0) exit 0 ;;
  5) cx_signal EXISTS 5 "a bundle file exists and differs; nothing was written (--force rewrites the selected files)" ;;
  *) cx_signal FAILED 2 "writing the bundle failed (rc $rc)" ;;
esac
