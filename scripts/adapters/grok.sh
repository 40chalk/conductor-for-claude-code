#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# scripts/adapters/grok.sh - the grok lane (docs/DESIGN.md section 15.2): raw grok (last verified
# on 1.0.70; no pin: the preflight checks the live --help for every flag below), never the
# grok-build bridge plugin. Every flag below appears in the captured grok 1.0.70 help
# (tests/fixtures/real/grok/help.txt).
#
# Usage: grok.sh probe|argv|run|parse [OPTIONS]   (the options of scripts/lib/adapter.sh)
#        grok.sh -h|--help | --version
#
#   argv (write):  <grok> --prompt-file <WT>/.conductor/prompt.txt -m <grok_bulk_model>
#                  --effort <E> --cwd <WT> -s <uuid> --output-format json
#                  --sandbox <profile> --always-approve --no-subagents --max-turns 60
#                  (--subagents: no --no-subagents, GROK_MAX_CONCURRENT_SUBAGENTS=4). The profile
#                  is the repository's own, cx-<repo>-<8 hex of its git directory> (option
#                  grok_sandbox_profile auto, the default; the 0.2.0 value cx-workspace counts as
#                  auto; any other value names a profile of your own, used in every mode): extends
#                  grok's strict profile (reads the checkout, system paths and ~/.grok; writes the
#                  checkout, ~/.grok/sessions, /tmp and /var/tmp, nothing else of ~/.grok, as
#                  measured on 1.0.70: tests/fixtures/real/grok/write-probe-strict-1.0.70.txt; no
#                  child network) plus read_only access to the git directory (git status in a
#                  worktree) and $CX_HOME/routes (each run's cx-route; never the out
#                  directories, which hold other runs' tasks, diffs and digests; grok's own
#                  ~/.grok/sessions, which every grok run reads and writes, holds every grok
#                  session's transcript, other runs' tasks and answers included). The
#                  sandbox is the boundary, so every tool is approved inside it (a headless run
#                  cannot ask: acceptEdits denied the first edit, measured 2026-11-02).
#   read/review:   the same --prompt-file, --cwd <the gate checkout> and the same profile:
#                  --sandbox <profile> --always-approve --no-subagents --json-schema <schema>
#                  (the schema text itself, default [{file, line, why}] for read, [{file, line,
#                  severity, issue}] for review). Never grok's built-in read-only: measured on
#                  1.0.70 (tests/fixtures/real/grok/write-probe-read-only-1.0.70.txt) it lets grok
#                  write ~/.grok but its protected set (config.toml, sandbox.toml, hooks/, ...):
#                  grok's own binary (~/.grok/bin), its ripgrep (~/.grok/vendor) and
#                  ~/.grok/installed-plugins, code that later runs outside any sandbox, so a run
#                  steered by the executor-written code it reads could replace them. Every file a
#                  run reads is inside its checkout: the prompt file, .conductor/task.md and a
#                  review's .conductor/change.diff (cx-run copies them there).
#   effort: low|medium|high|xhigh (never max).
#   environment:   the worker environment, GROK_CLAUDE_{HOOKS,SKILLS,MCPS,RULES,AGENTS}_ENABLED=false,
#                  GIT_CONFIG_GLOBAL=/dev/null (the strict profile cannot read ~/.gitconfig),
#                  XAI_API_KEY and GROK_SANDBOX unset.
#   probe (free):  grok --version (recorded only), grok models (the -m id must be listed: an
#                  unlisted id silently drops --effort), grok --sandbox strict models (grok's
#                  sandbox must apply here: a "sandbox could not be applied" or "Refusing to start"
#                  line refuses the lane, 2, and so does a ProfileApplied event with enforced
#                  false that grok appended to ~/.grok/sessions/sandbox-events.jsonl during the
#                  probe for its cwd; enforced true records the platform; no event changes
#                  nothing), grok --help (the flag contract: 26 when it lacks a flag of the argv).
#   run:           in every mode, before the slot: a per-project .grok/sandbox.toml in the run's
#                  checkout refuses the run (2: it could redefine the run's profile, and a review's
#                  gate checkout is a checkout of an executor-written branch, which can carry one);
#                  the repository's profile is written into ~/.grok/sandbox.toml when it is missing
#                  or differs (under $CX_HOME/locks/grok-sandbox.lock). The name is conductor's
#                  own: any other definition of it (one left there without the cx:begin/cx:end
#                  lines) is replaced, and a file that would then not parse or still define it
#                  another way refuses the run (2). No conductor grok run can write sandbox.toml
#                  (grok write-denies it under read-only and strict, measured), so the rewrite
#                  guards against everything else: your own grok sessions without a sandbox,
#                  other tools. Then the per-run profile check (free): grok --sandbox <the run's
#                  profile> models in the run's checkout, with the preflight's probe machinery and
#                  worker environment, and only the bytes that call appended to grok's sandbox
#                  log: a ProfileApplied event for the checkout with enforced false, or with a
#                  read_write path that grants write to grok's home (${GROK_HOME:-~/.grok} itself,
#                  a directory above it or one inside it, but ~/.grok/sessions and below), refuses
#                  the run (2) before any prompt, as do a line saying the sandbox was not applied
#                  and a built-in profile that writes grok's home (off, devbox, workspace,
#                  read-only); no log or no event changes nothing; the facts (platform included)
#                  go into grok.run.json as sandbox_check. Once the slot is held the profile is
#                  written again (the run may have waited for it), then the prompt file, grok,
#                  then grok usage <uuid> (free).
#   parse:         JSON text / sessionId / modelUsage / usage / stopReason (verified on 1.0.70;
#                  text joins every turn's message with no separator, so with --json-schema the
#                  answer is structuredOutput as JSON; without one, text stays the answer, with
#                  a note); any "permission required:" on stderr -> 15; a modelUsage key other
#                  than the model or its -build alias -> 21; a stderr line saying the sandbox
#                  was not applied -> 2 (and, when grok went on anyway, a reason saying it ran
#                  unconfined). Slot pool: grok (cap_grok).
#
# Exit codes: as scripts/lib/adapter.sh (0, 1, 2, 11, 13, 14, 26, 28, 130).

set -uo pipefail
unset CDPATH
CX_ADAPTER=grok
CX_PROG=adapter-grok
# shellcheck source=../lib/adapter.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/../lib/adapter.sh"

GROK_READ_SCHEMA='{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"why":{"type":"string"}},"required":["file","line","why"]}}'
GROK_REVIEW_SCHEMA='{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"severity":{"type":"string"},"issue":{"type":"string"}},"required":["file","line","severity","issue"]}}'

lane_setup() {
  CXA_EXECUTOR=grok CXA_LANE=grok CXA_POOL=xai-weekly CXA_SLOT_POOL=grok CXA_VARIANT=raw
  CXA_MODEL="${A_MODEL:-${CXA_OPT[grok_bulk_model]}}"
  CXA_EFFORT="${A_EFFORT:-${CXA_OPT[grok_bulk_effort]}}"
  case "$CXA_EFFORT" in low|medium|high|xhigh) ;; max) cx_usage_error "effort max never leaves Claude" ;; *) cx_usage_error "invalid --effort '$CXA_EFFORT'" ;; esac
  [[ $CXA_MODEL =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] || cx_usage_error "invalid grok model id '$CXA_MODEL'"
  CXA_BIN="${CXR_BIN_grok:-}" CXA_CLI="${CXR_BIN_grok:-}"
  cxa_need_bin CXR_BIN_grok grok
  CXA_ENV=()
  cxa_worker_env - || cxa_fail 2 FAILED "cannot build the worker shim set"
  cxa_unset XAI_API_KEY GROK_SANDBOX
  local v
  for v in HOOKS SKILLS MCPS RULES AGENTS; do cxa_set "GROK_CLAUDE_${v}_ENABLED" false; done
  cxa_set GIT_CONFIG_GLOBAL /dev/null
  [ -z "$A_SUBAGENTS" ] || cxa_set GROK_MAX_CONCURRENT_SUBAGENTS 4
}

# grok_profile: the sandbox profile of a run in any mode (GROK_PROFILE), with GROK_GCD (the git
# common directory it grants) when it is the repository's own (GROK_PROFILE_AUTO=1).
GROK_PROFILE="" GROK_GCD="" GROK_PROFILE_AUTO=0
grok_profile() {
  local opt="${CXA_OPT[grok_sandbox_profile]:-auto}" d gcd=""
  case "$opt" in
    ""|auto|cx-workspace) ;;
    *) GROK_PROFILE="$opt" GROK_PROFILE_AUTO=0; return 0 ;;
  esac
  # The task's checkout (--repo) first: an earlier executor may have rewritten a reused
  # worktree's .git, and the common directory it names would become a read grant.
  for d in "${A_REPO:-}" "${A_WT:-$PWD}"; do
    [ -n "$d" ] && [ -d "$d" ] || continue
    gcd="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" && [ -d "$gcd" ] && break
    gcd=""
  done
  if [ -z "$gcd" ]; then
    # Not a git checkout: grok's strict profile as it is (nothing to grant).
    GROK_PROFILE=strict GROK_PROFILE_AUTO=0
    return 0
  fi
  GROK_GCD="$(cd -- "$gcd" && pwd -P)"
  GROK_PROFILE="$(cx_py grok-profile --name-only --gcd "$GROK_GCD")" && [ -n "$GROK_PROFILE" ] \
    || cxa_fail 2 FAILED "cannot name the grok sandbox profile of $GROK_GCD"
  GROK_PROFILE_AUTO=1
}
# grok's home (${GROK_HOME:-~/.grok}), its sandbox.toml, its sandbox log (one ProfileApplied JSON
# line per sandboxed start, measured on 1.0.70) and the log's size in bytes (0 when it is absent,
# a symlink or not a regular file).
grok_home() { printf '%s\n' "${GROK_HOME:-${HOME:-}/.grok}"; }
grok_sandbox_file() { printf '%s\n' "$(grok_home)/sandbox.toml"; }
grok_events_file() { printf '%s\n' "$(grok_home)/sessions/sandbox-events.jsonl"; }
grok_events_size() {
  local n=""
  if [ -f "$1" ] && [ ! -L "$1" ]; then n="$(stat -c %s -- "$1" 2>/dev/null)"; fi
  [[ $n =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$n"
}

lane_argv() {
  local wt="${A_WT:-$PWD}" schema="$A_SCHEMA"
  CXA_SESSION_HINT="$(cat /proc/sys/kernel/random/uuid 2>/dev/null)" || CXA_SESSION_HINT=""
  [[ $CXA_SESSION_HINT =~ ^[0-9a-f-]{36}$ ]] || CXA_SESSION_HINT="$(cxa_py uuid)"
  [[ $CXA_SESSION_HINT =~ ^[0-9a-f-]{36}$ ]] || cxa_fail 2 FAILED "cannot generate a session uuid"
  CXA_ARGV=("$CXA_BIN" --prompt-file "$wt/.conductor/prompt.txt" -m "$CXA_MODEL" --effort "$CXA_EFFORT"
            --cwd "$wt" -s "$CXA_SESSION_HINT" --output-format json)
  # Every mode runs under the run's own profile (the repository's, or the one option
  # grok_sandbox_profile names), never grok's built-in read-only (it writes ~/.grok/bin,
  # ~/.grok/vendor and ~/.grok/installed-plugins, measured on 1.0.70).
  grok_profile
  CXA_ARGV+=(--sandbox "$GROK_PROFILE" --always-approve)
  if [ "$A_MODE" = write ]; then
    [ -n "$A_SUBAGENTS" ] || CXA_ARGV+=(--no-subagents)
  else
    if [ -z "$schema" ]; then
      if [ "$A_MODE" = review ]; then schema="$GROK_REVIEW_SCHEMA"; else schema="$GROK_READ_SCHEMA"; fi
    fi
    A_SCHEMA="$schema"
    # --json-schema takes the schema text itself (no file to read).
    CXA_ARGV+=(--no-subagents --json-schema "$schema")
  fi
  CXA_ARGV+=(--max-turns 60)
}

lane_dry_extra() {
  [ -n "$GROK_PROFILE" ] || grok_profile
  if [ "$GROK_PROFILE_AUTO" = 1 ]; then
    printf 'sandbox profile: %s (extends strict; read_only %s and %s/routes; added to %s before the run when missing)\n' \
      "$GROK_PROFILE" "$GROK_GCD" "$CXA_HOME" "$(grok_sandbox_file)"
  else
    printf 'sandbox profile: %s (yours, or a built-in; used as it is)\n' "$GROK_PROFILE"
  fi
}

# grok_apply_profile: the repository's profile in ~/.grok/sandbox.toml, written under a lock
# when it is missing or differs (a note says what changed); 2 FAILED when it cannot be.
grok_apply_profile() {
  local out rc
  # grok refuses a profile whose read_only names no directory: both exist before it starts.
  mkdir -p -- "$CXA_HOME/locks" "$CXA_HOME/routes"
  out="$(cx_py grok-profile --gcd "$GROK_GCD" --sandbox "$(grok_sandbox_file)" --template "$CX_ROOT/templates/grok-sandbox.toml" \
           --routes-root "$CXA_HOME/routes" --lock "$CXA_HOME/locks/grok-sandbox.lock" 2>&1)"
  rc=$?
  [ "$rc" = 0 ] || cxa_fail 2 FAILED "cannot write the grok sandbox profile $GROK_PROFILE into $(grok_sandbox_file): ${out:-rc $rc}"
  case "$out" in same*|"") ;; *) cx_note "${1:+$1: }$out" ;; esac
}

# grok_check_run PROFILE: the per-run profile check (free; DESIGN section 15.2): grok --sandbox
# PROFILE models in the run's checkout (cxa_probe_cmd_in: the preflight's probe machinery, the
# lane's worker environment, the 30 s bound), then normalize.py grok-check on its output and on
# only the bytes it appended to grok's sandbox log. A refusal (2 FAILED) names the profile, the
# path and the log; the facts go into grok.run.json (sandbox_check).
grok_check_run() {
  local sb="$1" wt="${A_WT:-$PWD}" ev ev0 ev1 rc f v
  f="$A_OUT/grok.sandbox-check.txt"
  ev="$(grok_events_file)"
  ev0="$(grok_events_size "$ev")"
  cxa_probe_cmd_in "$wt" "$f" "$CXA_BIN" --sandbox "$sb" models
  rc=$?
  ev1="$(grok_events_size "$ev")"
  v="$(cxa_py grok-check --profile "$sb" --workspace "$wt" --grok-home "$(grok_home)" --probe-out "$f" --probe-rc "$rc" \
         --events "$ev" --from "$ev0" --to "$ev1" --json-out "$A_OUT/grok.sandbox-check.json")" \
    || cxa_fail 2 FAILED "the per-run check of grok's sandbox profile $sb failed (normalize.py grok-check)"
  case "$v" in
    ok) ;;
    "refuse "*) cxa_fail 2 FAILED "${v#refuse }: refused before the run's prompt" ;;
    *) cxa_fail 2 FAILED "the per-run check of grok's sandbox profile $sb gave no verdict" ;;
  esac
  [ ! -s "$A_OUT/grok.sandbox-check.json" ] || CXA_RUNJSON+=(sandbox_check:json "$(cat "$A_OUT/grok.sandbox-check.json")")
}

# lane_prepare (run, after the preflight, before the slot; every mode): no per-project
# .grok/sandbox.toml in the run's checkout, the repository's profile in ~/.grok/sandbox.toml
# (grok_apply_profile; GROK_APPLY=1 when lane_exec applies it again), then the per-run check.
GROK_APPLY=""
lane_prepare() {
  local i sb="" wt="${A_WT:-$PWD}"
  # grok also reads a per-project .grok/sandbox.toml in its cwd, which could redefine the run's
  # profile (which definition wins is unverified), so none may exist: a writer may leave one in
  # its worktree, and a review's gate checkout is a checkout of an executor-written branch, which
  # can carry one (a read's checks out --base, which may carry one too).
  if [ -e "$wt/.grok/sandbox.toml" ] || [ -L "$wt/.grok/sandbox.toml" ]; then
    if [ "$A_MODE" = write ]; then
      cxa_fail 2 FAILED "the worktree holds .grok/sandbox.toml (a per-project grok sandbox file that could redefine the run's profile): remove it, or use another lane"
    fi
    cxa_fail 2 FAILED "the gate checkout holds .grok/sandbox.toml (a per-project grok sandbox file, committed in the commit it checks out, that could redefine the run's profile): a $A_MODE run never starts grok there; use another lane"
  fi
  for ((i = 1; i < ${#CXA_ARGV[@]} - 1; i++)); do
    [ "${CXA_ARGV[i]}" = --sandbox ] && sb="${CXA_ARGV[i + 1]}"
  done
  [ -n "$sb" ] || cxa_fail 2 FAILED "the grok argv names no --sandbox profile"
  [ -n "$GROK_PROFILE" ] || grok_profile
  # Written only for the profile the argv names, and only when it is the repository's own.
  if [ "$GROK_PROFILE_AUTO" = 1 ] && [ "$sb" = "$GROK_PROFILE" ]; then
    grok_apply_profile
    GROK_APPLY=1
  fi
  grok_check_run "$sb"
}

lane_exec() {
  local wt="${A_WT:-$PWD}"
  # Again once the slot is held: the run may have waited for it while something other than a
  # conductor grok run (none can write sandbox.toml: grok write-denies it under its sandbox
  # profiles) changed the file. Only the moment before grok reads it at startup stays open.
  [ -z "$GROK_APPLY" ] || grok_apply_profile "while this run waited for its slot"
  if ! { mkdir -p -- "$wt/.conductor" && printf '%s\n' "$A_PROMPT" > "$wt/.conductor/prompt.txt"; }; then
    CXA_RC=2
    cx_note "cannot write $wt/.conductor/prompt.txt"
    return 0
  fi
  cxa_exec_default
}

lane_postrun() {
  [ -n "${CXA_SESSION_HINT:-}" ] || return 0
  cxa_probe_cmd "$A_OUT/grok.usage.txt" "$CXA_BIN" usage "$CXA_SESSION_HINT" || true
}

lane_probe() {
  local t="$CXA_PROBE_TMP" mrc src ev ev0 ev1
  cxa_probe_cmd "$t/version" "$CXA_BIN" --version
  cxa_probe_cmd "$t/models" "$CXA_BIN" models
  mrc=$?
  # grok's sandbox must apply on this host: every grok run approves every tool inside it. The
  # lines grok appends to its sandbox log during this probe (only those: the sizes before and
  # after) hold its ProfileApplied event for the probe's cwd; enforced false refuses the lane.
  ev="$(grok_events_file)"
  ev0="$(grok_events_size "$ev")"
  cxa_probe_cmd "$t/sandbox" "$CXA_BIN" --sandbox strict models
  src=$?
  ev1="$(grok_events_size "$ev")"
  cxa_help grok "$CXA_BIN" --help
  cxa_contract_argv grok
  cxa_py probe --lane grok --bin "$CXA_BIN" --version-out "$t/version" --verified "$CX_VERIFIED_GROK" \
    --models-cli grok --models-out "$t/models" --models-rc "$mrc" --model "$CXA_MODEL" \
    --sandbox-out "$t/sandbox" --sandbox-rc "$src" --sandbox-events "$ev" --sandbox-events-from "$ev0" \
    --sandbox-events-to "$ev1" --sandbox-workspace "$CXA_HOME/probe" "${CXA_CONTRACT[@]}"
}

cxa_main "$@"
