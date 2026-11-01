#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# scripts/adapters/copilot-cloud.sh - the Copilot cloud agent lane (docs/DESIGN.md section 15,
# build order item 3; U7: an executor's own cloud, reached from a local session). The agent
# works on GitHub (in GitHub Actions) and opens a pull request; it is billed in Copilot premium
# requests and Actions minutes. It goes through ghcp's ghcp-cloud (gh agent-task create -F -, a
# gh preview feature), never raw gh.
#
# Usage: copilot-cloud.sh probe|argv|run|parse [OPTIONS]   (the options of scripts/lib/adapter.sh)
#        copilot-cloud.sh fetch --out OUT --repo DIR --pr N --gh-repo HOST/OWNER/REPO
#        copilot-cloud.sh -h|--help | --version
#
#   argv:   <ghcp-cloud> create -R <--gh-repo HOST/OWNER/REPO> [--base <--base-branch>] -
#           with the task on stdin: $OUT/cloud-task.md, rendered from the section 6.4 contract
#           (--task-file: goal, context, acceptance tests, allowed changes and commands, the
#           Forbidden list without "committing, pushing or branching", then the delivery: one
#           pull request, never merged by the agent).
#   environment: the worker environment, COPILOT_ALLOW_ALL COPILOT_AUTO_TIER COPILOT_MODEL
#           COPILOT_PROVIDER_BASE_URL unset; GH_TOKEN/GITHUB_TOKEN kept (gh's own login).
#   run:    no pool slot: no local executor process (like cx-wsl ghcp-cloud).
#   parse:  the task and pull request from the URLs in gh's output (result.json "cloud": state,
#           task, pr, pr_url); the ledger records them. Gating stays Claude's: fetch the PR head
#           into a gate checkout like any lane's commit.
#   fetch:  git -C DIR fetch <R> pull/N/head from the task's repository (--gh-repo; R = the remote
#           of DIR whose URL names it, else https://HOST/OWNER/REPO.git, never a fork's origin by
#           default), then gh pr view N -R <it> --json headRefOid must name the fetched commit;
#           prints the commit (also $OUT/copilot-cloud.head) for the gate checkout; exit 2 when the
#           fetch fails or the commit is not that pull request's head (errors in
#           $OUT/copilot-cloud.fetch.err).
#   probe (free): gh --version, gh auth status, gh agent-task --help (the preview command exists).
#
# Exit codes: as scripts/lib/adapter.sh (0, 1, 2, 11, 13, 130).

set -uo pipefail
unset CDPATH
CX_ADAPTER=copilot-cloud
CX_PROG=adapter-copilot-cloud
# shellcheck source=../lib/adapter.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/adapter.sh"

lane_setup() {
  CXA_EXECUTOR=copilot-cloud CXA_LANE=copilot-cloud CXA_POOL=copilot-credits CXA_SLOT_POOL="" CXA_VARIANT=cloud
  CXA_MODEL="" CXA_EFFORT=""
  if [ -z "$A_GH_REPO" ] && [ "$A_ACTION" = run ] && [ -f "$A_OUT/copilot-cloud.meta.json" ]; then
    A_GH_REPO="$(cxa_py field "$A_OUT/copilot-cloud.meta.json" repo_gh 2>/dev/null)"   # run reuses argv's files
  fi
  case "$A_ACTION" in probe|fetch) ;; *) [ -n "$A_GH_REPO" ] || cx_usage_error "--gh-repo HOST/OWNER/REPO is required (gh repo view --json url)" ;; esac
  [ -z "$A_GH_REPO" ] || [[ $A_GH_REPO =~ ^[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+){1,2}$ ]] || cx_usage_error "invalid --gh-repo '$A_GH_REPO'"
  [ -z "$A_BASE_BRANCH" ] || [[ $A_BASE_BRANCH =~ ^[A-Za-z0-9._/-]+$ ]] || cx_usage_error "invalid --base-branch '$A_BASE_BRANCH'"
  cxa_need_bin CXR_BIN_ghcp_cloud "ghcp-cloud (the ghcp plugin)"
  cxa_need_bin CXR_BIN_gh gh
  CXA_BIN="$CXR_BIN_ghcp_cloud" CXA_CLI="$CXR_BIN_gh"
  CXA_ENV=()
  cxa_worker_env - || cxa_fail 2 FAILED "cannot build the worker shim set"
  cxa_unset COPILOT_ALLOW_ALL COPILOT_AUTO_TIER COPILOT_MODEL COPILOT_PROVIDER_BASE_URL
}

lane_argv() {
  CXA_ARGV=("$CXA_BIN" create -R "$A_GH_REPO")
  [ -z "$A_BASE_BRANCH" ] || CXA_ARGV+=(--base "$A_BASE_BRANCH")
  CXA_ARGV+=(-)
  if [ "$A_ACTION" = argv ] && [ -z "$A_DRY" ]; then
    [ -n "$A_TASK" ] && [ -f "$A_TASK" ] || cx_usage_error "--task-file F (a section 6.4 task.md) is required"
    if ! { mkdir -p -- "$A_OUT" && cxa_py render-cloud --task "$A_TASK" --base "$A_BASE_BRANCH" > "$A_OUT/cloud-task.md"; }; then
      cxa_fail 2 FAILED "cannot render the cloud task from $A_TASK"
    fi
  fi
}

lane_dry_extra() {
  if [ -n "$A_TASK" ] && [ -f "$A_TASK" ]; then
    printf 'task on stdin (rendered from %s):\n' "$A_TASK"
    cxa_py render-cloud --task "$A_TASK" --base "$A_BASE_BRANCH" | sed 's/^/  | /'
  fi
}

lane_exec() {
  if [ ! -s "$A_OUT/cloud-task.md" ]; then
    { [ -n "$A_TASK" ] && cxa_py render-cloud --task "$A_TASK" --base "$A_BASE_BRANCH" > "$A_OUT/cloud-task.md"; } \
      || { cx_note "no rendered task in $A_OUT/cloud-task.md (pass --task-file)"; CXA_RC=2; return 0; }
  fi
  CXA_STDIN="$A_OUT/cloud-task.md"
  cxa_exec_default
}

lane_probe() {
  local t="$CXA_PROBE_TMP" arc ok=false
  cxa_probe_cmd "$t/version" "$CXR_BIN_gh" --version
  cxa_probe_cmd "$t/auth" "$CXR_BIN_gh" auth status
  arc=$?
  cxa_probe_cmd "$t/at" "$CXR_BIN_gh" agent-task --help && ok=true
  cxa_py probe --lane copilot-cloud --bin "$CXR_BIN_gh" --wrapper "$CXA_BIN" --version-out "$t/version" \
    --version-ok "$ok" --auth-out "$t/auth" --auth-kind rc --auth-rc "$arc" --model-ok true
}

# cc_repo_of URL: host/owner/repo of a git remote URL (https, ssh, scp-like), lower-case.
# shellcheck disable=SC2329  # used by lane_action_fetch, which cxa_main calls indirectly
cc_repo_of() {
  printf '%s\n' "$1" | sed -E 's#^[a-z+]+://([^@/]*@)?##; s#^[^@/]*@([^:/]+):#\1/#; s#^([^/:]+):[0-9]+/#\1/#; s#\.git/?$##; s#/$##' | tr '[:upper:]' '[:lower:]'
}

# fetch: the agent's PR head for the gate checkout (DESIGN section 12.2 step 5), from the task's
# repository and confirmed by GitHub as that pull request's head.
# shellcheck disable=SC2329  # called by cxa_main as lane_action_<action>
lane_action_fetch() {
  local sha want r url src="" err head
  [ -n "$A_REPO" ] && [ -d "$A_REPO" ] || cx_usage_error "fetch needs --repo DIR (the main checkout)"
  [[ $A_PR =~ ^[0-9]+$ ]] || cx_usage_error "fetch needs --pr N"
  [ -n "$A_OUT" ] || cx_usage_error "fetch needs --out DIR"
  [ -n "$A_GH_REPO" ] || cx_usage_error "fetch needs --gh-repo HOST/OWNER/REPO (the repository the agent task ran in)"
  mkdir -p -- "$A_OUT" || cxa_fail 2 FAILED "cannot create $A_OUT"
  err="$A_OUT/copilot-cloud.fetch.err"
  : > "$err"
  want="$(printf '%s\n' "$A_GH_REPO" | tr '[:upper:]' '[:lower:]')"
  case "$want" in */*/*) ;; *) want="github.com/$want" ;; esac
  for r in $(git -C "$A_REPO" remote 2>/dev/null); do
    url="$(git -C "$A_REPO" remote get-url "$r" 2>/dev/null)" || continue
    if [ "$(cc_repo_of "$url")" = "$want" ]; then src="$r"; break; fi
  done
  [ -n "$src" ] || src="https://$want.git"
  if ! git -C "$A_REPO" fetch -q "$src" "pull/$A_PR/head" 2>>"$err" < /dev/null; then
    cxa_fail 2 FAILED "git fetch $src pull/$A_PR/head failed in $A_REPO (see $err)"
  fi
  sha="$(git -C "$A_REPO" rev-parse FETCH_HEAD)" || cxa_fail 2 FAILED "no FETCH_HEAD after the fetch"
  # GitHub must name the same commit as that pull request's head: a remote that is not the task's
  # repository (a fork with its own pull/N) is never gated in its place.
  mkdir -p -- "$CXA_HOME/probe"
  cxa_env_args
  head="$( (cd -- "$CXA_HOME/probe" && cx_timeout 30 env "${CXA_ENVARGS[@]}" "$CXR_BIN_gh" pr view "$A_PR" -R "$A_GH_REPO" \
             --json headRefOid --jq .headRefOid) < /dev/null 2>>"$err" | tr -d '[:space:]')"
  if ! [[ $head =~ ^[0-9a-f]{40}$ ]]; then
    cxa_fail 2 FAILED "gh pr view $A_PR -R $A_GH_REPO did not name the pull request's head commit (see $err)"
  fi
  [ "$head" = "$sha" ] || cxa_fail 2 FAILED "pull/$A_PR/head fetched from $src is $sha, but $A_GH_REPO's pull request $A_PR has head $head: not gating it"
  printf '%s\n' "$sha" > "$A_OUT/copilot-cloud.head"
  printf '%s\n' "$sha"
}

cxa_main "$@"
