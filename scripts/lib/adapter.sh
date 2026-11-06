#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR disable=SC2034  # sourced library: the adapters set and read these variables
# scripts/lib/adapter.sh - shared machinery of the Phase 2 adapters scripts/adapters/<lane>.sh
# (docs/DESIGN.md sections 15.2, 15.6). Sourced, never run; executor host only (python3 needed).
#
# Interface of every adapter (cx-run and cx-job call exactly this):
#   <lane>.sh probe [OPTIONS]            free preflight JSON on stdout (cached 10 minutes in
#                                        $CX_HOME/state/preflight.json, per caller side: a WSL
#                                        terminal and a forwarded call never share an entry;
#                                        --refresh skips the cache), with the flag contract: the
#                                        CLI's live --help must list every flag the lane is about
#                                        to emit (no version pins, DESIGN section 5.4)
#   <lane>.sh argv  [OPTIONS]            writes $OUT/<lane>.argv and $OUT/<lane>.env (NUL-separated;
#                                        NAME= with no value = unset) and $OUT/<lane>.meta.json;
#                                        with --dry-run nothing is written: it prints the lane,
#                                        model, effort, argv (printf %q), env names, cwd, worktree
#   <lane>.sh run   [OPTIONS]            preflight (the probe: 13, 26 flag contract, 11, 14, agy paused 28),
#                                        the lane's own preparation (grok: its profile and the
#                                        per-run profile check, 2), the pool slot (locks.sh: 28),
#                                        the running mark, then the executor in the worker
#                                        environment under setsid and timeout; writes
#                                        $OUT/<lane>.out, .err, rc, <lane>.run.json (argv first
#                                        when its files are missing); a run that stops before its
#                                        executor leaves its reason in $OUT/adapter.why
#   <lane>.sh parse --out OUT            normalize.py parse: $OUT/result.json and answer.txt;
#                                        prints "<exit> <status>"
# Options: --out DIR --wt DIR --model M --effort E --mode write|read|review --timeout SECS
#   --allow CMD (repeatable) --id ID --prompt TEXT --repo DIR (the main checkout) --base SHA
#   --task-file F --no-wait --refresh --dry-run, and per lane --fusion standard|max (copilot),
#   --add-dir DIR (copilot, agy wrapper), --json-schema S --subagents (grok), --agy-mode
#   raw|wrapper (agy), --headless (claude), --gh-repo HOST/OWNER/REPO --base-branch B (copilot-cloud).
#
# Exit codes (DESIGN section 4.1): 0 (run: the executor ran, whatever its own status, which
# parse classifies), 1 usage, 2 FAILED, 11 AUTH_REQUIRED, 13 CLI_MISSING, 14 MODEL_UNAVAILABLE,
# 26 VERSION_MISMATCH (the flag contract: the CLI's help lacks a flag the lane emits), 28
# NO_CAPACITY (no slot, cap 0, agy paused or below its floor), 130
# CANCELLED. Every exit outside {0, 1} prints one CX_SIGNAL line, last, unless CX_SIGNAL_OWNER
# is set (cx-run sets it: the caller then prints the single signal of the whole run).
#
# Worker environment (section 15.6): CX_WORKER=1; PATH = the worker shims, then
# $CX_HOME/routes/<id> (the run's cx-route, which runs only the task's routes.json checks as
# cx-run snapshotted them), then the host record's path; COPILOT_AUTO_UPDATE=false
# GROK_DISABLE_AUTOUPDATER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true NO_COLOR=1 PYTHONDONTWRITEBYTECODE=1 (no __pycache__ in the
# worktree when the checks run Python); ANTHROPIC_API_KEY XAI_API_KEY GEMINI_API_KEY
# GOOGLE_API_KEY and every CLAUDE_PLUGIN_OPTION_* unset (the siblings read option variables of
# their own); executors by absolute path from the host record; cwd the worktree or gate checkout.
# A lane whose wrapper finds its executor by name (agy-delegate: command -v agy) gets the shim
# set without that name, $CX_HOME/shimsets/<names>/ (built once, atomically). The Copilot token
# reaches the executor through the environment only, never on a command line. Only the adapter
# holds the pool slot and the agy locks (the executor gets none of their descriptors).
#
# Cancellation (TERM, INT, HUP): TERM (agy: KILL) to the executor's session, KILL after
# CX_KILL_GRACE_SECS (default 10) seconds and once more at the end; a signal while the executor
# is being started waits for its session id first. After every run the executor's session is
# killed, so nothing it left behind outlives the adapter.

[ -n "${CX_PROG:-}" ] || CX_PROG="adapter"
# shellcheck source=common.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
# shellcheck source=options.sh
declare -F cx_opt >/dev/null 2>&1 || . "$CX_LIB/options.sh"
# shellcheck source=locks.sh
declare -F cx_lock_acquire >/dev/null 2>&1 || . "$CX_LIB/locks.sh"

CX_TASK_PROMPT='Read .conductor/task.md in the working directory and do exactly what it says. Run checks only as cx-route <name> (cx-route alone lists them). Do not spawn subagents. End with the DIGEST: line it specifies.'
CXA_HOME="${CX_HOME:-${HOME:-}/.conductor}"
CXA_NORM="$CX_LIB/normalize.py"

cxa_py() { python3 -I "$CXA_NORM" "$@"; }

# The lane variables (lane_setup sets them) and the host record (cxa_record sets them).
CXA_LANE="" CXA_EXECUTOR="" CXA_POOL="" CXA_SLOT_POOL="" CXA_VARIANT="" CXA_MODEL="" CXA_EFFORT=""
CXA_BIN="" CXA_CLI="" CXA_CLI_VERSION="" CXA_SESSION_HINT="" CXA_DISPATCH="" CXA_RECORD=""
CXR_LOADED="" CXR_PATH="" CXR_COPILOT_HOME_SET=0 CXR_COPILOT_HOME="" CXR_COPILOT_TOKEN_ENV=""
CXR_RECORDED_AT="" CXR_PLUGIN_VERSION="" CXR_BIN_claude="" CXR_BIN_copilot="" CXR_BIN_grok=""
CXR_BIN_agy="" CXR_BIN_gh="" CXR_BIN_git="" CXR_BIN_python3="" CXR_BIN_ghcp_delegate="" CXR_BIN_ghcp_job=""
CXR_BIN_ghcp_handoff="" CXR_BIN_ghcp_ci_debug="" CXR_BIN_ghcp_models="" CXR_BIN_ghcp_cloud=""
CXR_BIN_agy_delegate="" CXR_BIN_agy_job=""

# cxa_fail EXIT STATUS REASON: one note, then CX_SIGNAL (unless CX_SIGNAL_OWNER is set), exit.
# A run that stops before its executor also leaves REASON in $OUT/adapter.why, for cx-run's
# result.
cxa_fail() {
  local code="$1" status="$2" reason="$3"
  declare -F cxa_unmark_running >/dev/null 2>&1 && CXA_KEEP_MARK="" cxa_unmark_running
  if [ "${A_ACTION:-}" = run ] && [ -n "${A_OUT:-}" ] && [ -d "$A_OUT" ]; then
    printf '%s\n' "$reason" > "$A_OUT/adapter.why" 2>/dev/null
  fi
  cx_note "$reason"
  [ -z "${CX_SIGNAL_OWNER:-}" ] || exit "$code"
  CX_SIGNAL_CMD=adapter cx_signal "$status" "$code" "$reason"
}

# ------------------------------------------------------------------ options and arguments

declare -gA CXA_OPT=()
# cxa_load_opts: the conductor options the adapters use, loaded in a subshell so no
# CLAUDE_PLUGIN_OPTION_* reaches this process's environment (and the sibling wrappers).
cxa_load_opts() {
  local k v
  while IFS=$'\t' read -r k v; do
    [ -n "$k" ] && CXA_OPT[$k]="$v"
  done < <(
    # shellcheck disable=SC2119  # no FILE: the default settings files
    [ -n "${CX_OPTIONS_LOADED:-}" ] || cx_load_options
    for k in agy_opus_slug_tpl agy_opus_mode copilot_opus_id copilot_xhigh_ok grok_bulk_model \
             grok_bulk_effort grok_sandbox_profile cap_agy cap_copilot cap_grok agy_claude_floor_pct \
             default_timeout review_model_gemini review_model_gpt; do
      printf '%s\t%s\n' "$k" "$(cx_opt "$k")"
    done
  )
}

# cxa_secs DURATION: 30s, 10m, 2h or plain seconds -> seconds; rc 1 when invalid.
cxa_secs() {
  [[ ${1-} =~ ^([0-9]{1,7})([smh]?)$ ]] || return 1
  local n=$((10#${BASH_REMATCH[1]}))
  case "${BASH_REMATCH[2]}" in m) n=$((n * 60)) ;; h) n=$((n * 3600)) ;; esac
  printf '%s\n' "$n"
}

# cxa_dur SECS: a duration for a CLI flag (30m when whole minutes, else 90s).
cxa_dur() { if [ $(($1 % 60)) -eq 0 ]; then printf '%sm\n' "$(($1 / 60))"; else printf '%ss\n' "$1"; fi; }

A_ACTION="" A_OUT="" A_WT="" A_MODEL="" A_EFFORT="" A_MODE=write A_TIMEOUT="" A_ID="" A_PROMPT=""
A_REPO="" A_BASE="" A_TASK="" A_NOWAIT="" A_REFRESH="" A_DRY="" A_FUSION="" A_SCHEMA="" A_SUBAGENTS=""
A_AGY_MODE="" A_HEADLESS="" A_GH_REPO="" A_BASE_BRANCH="" A_PR=""
A_ALLOW=() A_ADD=()

cxa_parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --subagents) A_SUBAGENTS=1; shift; continue ;;
      --headless) A_HEADLESS=1; shift; continue ;;
      --no-wait) A_NOWAIT=1; shift; continue ;;
      --refresh) A_REFRESH=1; shift; continue ;;
      --dry-run) A_DRY=1; shift; continue ;;
      --out|--wt|--model|--effort|--mode|--timeout|--allow|--id|--prompt|--repo|--base|--task-file|--fusion|--json-schema|--agy-mode|--gh-repo|--base-branch|--add-dir|--pr)
        [ $# -ge 2 ] || cx_usage_error "$1 needs a value" ;;
      *) cx_usage_error "unknown argument: $1" ;;
    esac
    case "$1" in
      --out) A_OUT="$2" ;;
      --wt) A_WT="$2" ;;
      --model) A_MODEL="$2" ;;
      --effort) A_EFFORT="$2" ;;
      --mode) A_MODE="$2" ;;
      --timeout) A_TIMEOUT="$2" ;;
      --allow) A_ALLOW+=("$2") ;;
      --add-dir) A_ADD+=("$2") ;;
      --id) A_ID="$2" ;;
      --prompt) A_PROMPT="$2" ;;
      --repo) A_REPO="$2" ;;
      --base) A_BASE="$2" ;;
      --task-file) A_TASK="$2" ;;
      --fusion) A_FUSION="$2" ;;
      --json-schema) A_SCHEMA="$2" ;;
      --agy-mode) A_AGY_MODE="$2" ;;
      --gh-repo) A_GH_REPO="$2" ;;
      --base-branch) A_BASE_BRANCH="$2" ;;
      --pr) A_PR="$2" ;;
    esac
    shift 2
  done
  case "$A_MODE" in write|read|review) ;; *) cx_usage_error "--mode must be write, read or review (got '$A_MODE')" ;; esac
  if [ -n "$A_TIMEOUT" ]; then
    A_TIMEOUT="$(cxa_secs "$A_TIMEOUT")" || cx_usage_error "--timeout must be seconds (or 30m, 2h)"
  else
    A_TIMEOUT="$(cxa_secs "${CXA_OPT[default_timeout]:-30m}")" || A_TIMEOUT=1800
  fi
  [ "$A_TIMEOUT" -ge 30 ] || cx_usage_error "--timeout must be at least 30 seconds"
  [ -z "$A_ID" ] || [[ $A_ID =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || cx_usage_error "invalid --id '$A_ID'"
  [ -z "$A_MODEL" ] || [[ ! $A_MODEL =~ [[:cntrl:]] ]] || cx_usage_error "invalid --model"
  local a
  for a in "${A_ALLOW[@]+"${A_ALLOW[@]}"}"; do
    [ -n "$a" ] && [[ ! $a =~ [[:cntrl:]] ]] || cx_usage_error "invalid --allow '$a' (one non-empty command per line-free value)"
  done
  [ -n "$A_PROMPT" ] || A_PROMPT="$CX_TASK_PROMPT"
  if [ -n "$A_OUT" ]; then
    case "$A_OUT" in /*) ;; *) A_OUT="$PWD/$A_OUT" ;; esac
    [ -n "$A_ID" ] || A_ID="$(basename -- "$A_OUT")"
  fi
  if [ -n "$A_WT" ]; then
    case "$A_WT" in /*) ;; *) A_WT="$PWD/$A_WT" ;; esac
  fi
  return 0
}

# ------------------------------------------------------------------ host record

cxa_record() {
  local rec out
  [ -n "${CXR_LOADED:-}" ] && return 0
  cx_py_ok || cxa_fail 2 FAILED "python3 is required on the executor host"
  _cx_source_detect
  cx_detect
  rec="$CXA_HOME/hosts/$CX_HOSTKEY.json"
  CXA_RECORD="$rec"
  if [ ! -f "$rec" ]; then
    cxa_fail 13 CLI_MISSING "no host record $rec: run cx-doctor once (from a Claude Code session in WSL, or ~/.conductor/runtime/current/bin/cx-doctor in a WSL terminal) so the conductor knows where the CLIs live"
  fi
  _cx_source_pathmap
  out="$(cx_py record-env --record "$rec" --config-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" --mnt-root "$(_cx_pm_mnt_root "")")" \
    || cxa_fail 13 CLI_MISSING "cannot read the host record $rec: run cx-doctor"
  eval "$out"
  CXR_LOADED=1
}

# cxa_need_bin VAR LABEL: VAR (a CXR_BIN_* value) must be an executable absolute path, else 13.
cxa_need_bin() {
  local v="${!1-}"
  [ -n "$v" ] && [ -x "$v" ] && return 0
  cxa_fail 13 CLI_MISSING "$2 is not in the host record $CXA_RECORD (or not executable there): install it in WSL, then run cx-doctor"
}

# ------------------------------------------------------------------ worker environment

CXA_ENV=()      # NAME=VALUE (set) or NAME= (unset), written to $OUT/<lane>.env
CXA_ARGV=()
cxa_set() { CXA_ENV+=("$1=$2"); }
cxa_unset() { local n; for n in "$@"; do CXA_ENV+=("$n="); done; }

# cxa_shimdir - | EXCLUDED...: the worker shim directory (-: the full set); with names, the shim set without them
# ($CX_HOME/shimsets/<sorted names joined by ->/, built once, atomically; rebuilt when the
# runtime's shims change).
cxa_shimdir() {
  local src="$CX_ROOT/worker-shims" name="" n dst tmp stamp f
  if [ $# -eq 0 ] || [ "$1" = - ]; then printf '%s\n' "$src"; return 0; fi
  while IFS= read -r n; do name="${name:+$name-}$n"; done < <(printf '%s\n' "$@" | LC_ALL=C sort -u)
  dst="$CXA_HOME/shimsets/$name"
  stamp="$CX_VERSION $(cd -- "$src" && find . -maxdepth 1 -type f ! -name '.*' -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')"
  if [ -f "$dst/.stamp" ] && [ "$(cat "$dst/.stamp" 2>/dev/null)" = "$stamp" ]; then
    printf '%s\n' "$dst"; return 0
  fi
  mkdir -p -- "$CXA_HOME/shimsets" || return 2
  tmp="$(mktemp -d "$CXA_HOME/shimsets/.tmp.XXXXXXXX")" || return 2
  for f in "$src"/*; do
    n="$(basename -- "$f")"
    case " $* " in *" $n "*) continue ;; esac
    cp -p -- "$f" "$tmp/$n" || { rm -rf -- "$tmp"; return 2; }
  done
  printf '%s\n' "$stamp" > "$tmp/.stamp"
  chmod 0755 "$tmp"
  if [ -d "$dst" ]; then
    mv -T -- "$dst" "$dst.old.$$" 2>/dev/null
    rm -rf -- "$dst.old.$$"
  fi
  mv -T -- "$tmp" "$dst" 2>/dev/null || rm -rf -- "$tmp"
  [ -d "$dst" ] || return 2
  printf '%s\n' "$dst"
}

# cxa_worker_env - | EXCLUDED...: the section 15.6 base environment with the full shim set (-) or
# the shim set without the EXCLUDED names; rc 2 when the shim set cannot be built.
cxa_worker_env() {
  local v p="${CXR_PATH:-}" shims
  shims="$(cxa_shimdir "$@")" && [ -n "$shims" ] || return 2
  [ -n "$p" ] || p="/usr/local/bin:/usr/bin:/bin"
  cxa_unset ANTHROPIC_API_KEY XAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY
  for v in $(compgen -e); do
    case "$v" in CLAUDE_PLUGIN_OPTION_*) cxa_unset "$v" ;; esac
  done
  cxa_set CX_WORKER 1
  cxa_set PATH "$shims:$(cxa_route_bin):$p"
  cxa_set COPILOT_AUTO_UPDATE false
  cxa_set GROK_DISABLE_AUTOUPDATER 1
  cxa_set AGY_CLI_DISABLE_AUTO_UPDATE true
  cxa_set NO_COLOR 1
  cxa_set PYTHONDONTWRITEBYTECODE 1
}

# cxa_route_bin: $CX_HOME/routes/<id>, where cx-run puts the run's cx-route (the id is --id, else
# the basename of --out; grok's sandbox profile reads $CX_HOME/routes, not the out directories).
cxa_route_bin() { printf '%s/routes/%s\n' "$CXA_HOME" "${A_ID:-<id>}"; }

# cxa_env_args: CXA_ENV as env(1) arguments in CXA_ENVARGS (-u NAME, NAME=VALUE), plus every
# CLAUDE_PLUGIN_OPTION_* present now (a job runner may carry other ones than argv saw).
# CXA_ENV_RUN is never among them: argv is world-readable in /proc/<pid>/cmdline.
cxa_env_args() {
  local e v
  CXA_ENVARGS=()
  for v in $(compgen -e); do
    case "$v" in CLAUDE_PLUGIN_OPTION_*) CXA_ENVARGS+=(-u "$v") ;; esac
  done
  for e in "${CXA_ENV[@]+"${CXA_ENV[@]}"}"; do
    if [ "${e#*=}" = "" ]; then CXA_ENVARGS+=(-u "${e%%=*}"); fi
  done
  for e in "${CXA_ENV[@]+"${CXA_ENV[@]}"}"; do
    [ "${e#*=}" = "" ] || CXA_ENVARGS+=("$e")
  done
}
CXA_ENV_RUN=()   # run-time additions never written to disk nor put on a command line (the Copilot token)
# cxa_run_env: exports CXA_ENV_RUN; only ever called inside the subshell that starts a probe or
# the executor, so the value reaches it through the environment (/proc/<pid>/environ is readable
# by its owner only), never through env(1)'s or timeout's argv.
cxa_run_env() {
  local e
  for e in "${CXA_ENV_RUN[@]+"${CXA_ENV_RUN[@]}"}"; do export "${e%%=*}=${e#*=}"; done
  return 0
}

# cxa_copilot_token: COPILOT_GITHUB_TOKEN from $CX_HOME/secrets/copilot-token (a regular 0600
# file of the user's; never a symlink) into CXA_ENV_RUN, unless the caller set one (section 7.7).
cxa_copilot_token() {
  local f="$CXA_HOME/secrets/copilot-token" tok=""
  [ -z "${COPILOT_GITHUB_TOKEN:-}" ] && [ -e "$f" ] || return 0
  if [ -f "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] && [ "$(stat -c %a -- "$f" 2>/dev/null)" = 600 ]; then
    IFS= read -r tok < "$f" || true
    tok="${tok//[[:space:]]/}"
    [ -z "$tok" ] || CXA_ENV_RUN+=("COPILOT_GITHUB_TOKEN=$tok")
  else
    cx_note "ignoring $f: it must be a regular file you own with mode 0600 (chmod 600 it)"
  fi
}

# ------------------------------------------------------------------ files of a run

cxa_files_write() {
  mkdir -p -- "$A_OUT" || cxa_fail 2 FAILED "cannot create $A_OUT"
  printf '%s\0' "${CXA_ARGV[@]}" > "$A_OUT/$CX_ADAPTER.argv" || cxa_fail 2 FAILED "cannot write $A_OUT"
  printf '%s\0' "${CXA_ENV[@]+"${CXA_ENV[@]}"}" > "$A_OUT/$CX_ADAPTER.env"
  cxa_meta > "$A_OUT/$CX_ADAPTER.meta.json" || cxa_fail 2 FAILED "cannot write the run metadata"
}

cxa_files_read() {
  CXA_ARGV=() CXA_ENV=()
  mapfile -d '' -t CXA_ARGV < "$A_OUT/$CX_ADAPTER.argv"
  mapfile -d '' -t CXA_ENV < "$A_OUT/$CX_ADAPTER.env"
  [ "${#CXA_ARGV[@]}" -gt 0 ]
}

# cxa_meta: the metadata JSON (what was requested) from the lane variables.
cxa_meta() {
  local wth="" outh=""
  [ -z "$A_WT" ] || wth="$(cx_host_path "$A_WT" 2>/dev/null)" || wth=""
  [ -z "$A_OUT" ] || outh="$(cx_host_path "$A_OUT" 2>/dev/null)" || outh=""
  cxa_py obj version:int 1 adapter "$CX_ADAPTER" lane "$CXA_LANE" executor "$CXA_EXECUTOR" \
    pool "$CXA_POOL" slot_pool "$CXA_SLOT_POOL" variant "$CXA_VARIANT" id "$A_ID" mode "$A_MODE" \
    model_requested "$CXA_MODEL" effort_requested "$CXA_EFFORT" fusion "$A_FUSION" \
    timeout_s:int "$A_TIMEOUT" wt "$A_WT" wt_host "$wth" out "$A_OUT" out_host "$outh" \
    prompt "$A_PROMPT" bin "$CXA_BIN" cli "$CXA_CLI" \
    cli_version "${CXA_CLI_VERSION:-}" session_hint "${CXA_SESSION_HINT:-}" task_file "$A_TASK" \
    repo "$A_REPO" base "$A_BASE" branch "$( [ "$A_MODE" = write ] && [ -n "$A_ID" ] && printf 'cx/%s' "$A_ID")" json_schema "$A_SCHEMA" \
    repo_gh "$A_GH_REPO" base_branch "$A_BASE_BRANCH" host "${CX_HOST:-}" caller "${CX_CALLER:-local}" \
    created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" dispatch:json "${CXA_DISPATCH:-null}" \
    --list allow "${#A_ALLOW[@]}" "${A_ALLOW[@]+"${A_ALLOW[@]}"}" \
    --list add_dirs "${#A_ADD[@]}" "${A_ADD[@]+"${A_ADD[@]}"}"
}

# cxa_json_list ITEM...: a JSON list of strings.
cxa_json_list() { cxa_py json-list -- "$@"; }

# ------------------------------------------------------------------ probe and preflight

# cxa_probe_cmd FILE CMD...: one free probe: cwd $CX_HOME/probe, stdin /dev/null, the lane's
# environment, a 30 s bound; stdout and stderr into FILE; returns the command's status.
cxa_probe_cmd() {
  mkdir -p -- "$CXA_HOME/probe"
  cxa_probe_cmd_in "$CXA_HOME/probe" "$@"
}
# cxa_probe_cmd_in DIR FILE CMD...: the same probe with cwd DIR (grok's per-run profile check
# runs in the run's checkout).
cxa_probe_cmd_in() {
  local d="$1" f="$2"
  shift 2
  cxa_env_args
  (cd -- "$d" && cxa_run_env && cx_timeout 30 env "${CXA_ENVARGS[@]}" "$@") < /dev/null > "$f" 2>&1
}

# cxa_flags: the flag tokens of CXA_ARGV after the executable ("--x=v" counts as "--x"; nothing
# after a literal "--"), sorted, comma-joined: the flag contract's part of the probe cache key.
cxa_flags() {
  local a
  local -a f=()
  for a in "${CXA_ARGV[@]:1}"; do
    [ "$a" = -- ] && break
    [[ $a =~ ^(--?[A-Za-z][A-Za-z0-9-]*)(=.*)?$ ]] && f+=("${BASH_REMATCH[1]}")
  done
  [ "${#f[@]}" -gt 0 ] || return 0
  printf '%s\n' "${f[@]}" | LC_ALL=C sort -u | paste -sd, -
}

# cxa_bin_ids: the identity (resolved path, mtime, size) of the lane's binaries, for the probe
# cache key: a CLI that updated itself is probed (and its flag contract checked) again at once.
cxa_bin_ids() {
  local b r
  for b in "${CXA_BIN:-}" "${CXA_CLI:-}"; do
    [ -n "$b" ] || continue
    r="$(readlink -f -- "$b" 2>/dev/null)" || r="$b"
    printf '%s:%s;' "$r" "$(stat -L -c '%Y.%s' -- "$r" 2>/dev/null)"
  done
}

# cxa_help NAME CMD...: one free help probe for the flag contract (DESIGN section 5.4): the
# output goes to $CXA_PROBE_TMP/help.NAME, and CXA_CONTRACT gains --help-file NAME=<it>::<label>.
CXA_CONTRACT=()
cxa_help() {
  local name="$1" label
  shift
  label="${1##*/} ${*:2}"
  cxa_probe_cmd "$CXA_PROBE_TMP/help.$name" "$@"
  CXA_CONTRACT+=(--help-file "$name=$CXA_PROBE_TMP/help.$name::$label")
}
# cxa_contract_argv NAME: the run's argv (CXA_ARGV) must fit help NAME.
cxa_contract_argv() { CXA_CONTRACT+=(--argv-file "$1=$CXA_PROBE_TMP/argv"); }

# cxa_probe: prints the probe JSON (cached unless --refresh).
cxa_probe() {
  local key j tmp
  # The flag contract checks the argv the run is about to use: built here when the probe runs on
  # its own (cx-run's preflight, before the worktree exists).
  [ "${#CXA_ARGV[@]}" -gt 0 ] || lane_argv
  # The caller side is part of the key: logins differ between a WSL terminal and a call forwarded
  # through wsl.exe (no keyring there; the token file signs Copilot in), so a green probe of one
  # side never answers for the other (D16, W9). The flags are part of it too: a probe of other
  # flags (another mode) never answers for these.
  key="$CX_ADAPTER|$CXA_VARIANT|${CXA_BIN:-}|${CXA_CLI:-}|$CXA_MODEL|${A_FUSION:-}|${CXA_PROBE_SALT:-}"
  key="$key|fwd=${CX_FORWARDED:-0}|tok=$([ -e "$CXA_HOME/secrets/copilot-token" ] && echo 1 || echo 0)|env=$([ -n "${COPILOT_GITHUB_TOKEN:-}" ] && echo 1 || echo 0)"
  key="$key|mode=$A_MODE|flags=$(cxa_flags)|bins=$(cxa_bin_ids)"
  if [ -z "$A_REFRESH" ] && j="$(cxa_py cache-get --key "$key" 2>/dev/null)" && [ -n "$j" ]; then
    printf '%s\n' "$j"
    return 0
  fi
  # The probe's outputs decide the verdict: never in a /tmp that a grok run may write (cx_tmpdir).
  tmp="$(cx_mktemp -d cx-probe)" || cxa_fail 2 FAILED "cannot create a scratch directory in $CXA_HOME/tmp"
  CXA_PROBE_TMP="$tmp"
  printf '%s\0' "${CXA_ARGV[@]}" > "$tmp/argv"
  j="$(lane_probe)"
  rm -rf -- "$tmp"
  [ -n "$j" ] || cxa_fail 2 FAILED "the $CX_ADAPTER probe produced nothing"
  # cache-put keeps only a green probe: a refusal is probed again next time (the user may just
  # have fixed it).
  printf '%s\n' "$j" | cxa_py cache-put --key "$key" >/dev/null 2>&1
  printf '%s\n' "$j"
}

# cxa_preflight: the probe's verdict for run (section 15.1 free preflight).
cxa_preflight() {
  local j verdict code status reason
  j="$(cxa_probe)" || exit $?
  verdict="$(cxa_py verdict "$j")" || verdict="2 FAILED - the preflight verdict failed"
  code="${verdict%% *}"
  verdict="${verdict#* }"
  status="${verdict%% *}"
  verdict="${verdict#* }"
  CXA_CLI_VERSION="${verdict%% *}"
  [ "$CXA_CLI_VERSION" != - ] || CXA_CLI_VERSION=""
  reason="${verdict#* }"
  [ "$code" = 0 ] && return 0
  cxa_fail "$code" "$status" "$reason"
}

# ------------------------------------------------------------------ running mark, slot, exec

cxa_mark_running() {
  [ "$A_MODE" = write ] && [ -n "$A_OUT" ] && [ -d "$A_WT" ] || return 0
  printf '%s\n' "$A_WT" "$(cd -- "$A_WT" && pwd -P)" > "$A_OUT/running"
  CXA_MARKED=1
}
cxa_unmark_running() {
  [ -n "${CXA_MARKED:-}" ] && [ -z "${CXA_KEEP_MARK:-}" ] && rm -f -- "$A_OUT/running"
  CXA_MARKED=""
}

cxa_slot() {
  local cap wait rc
  CXA_SLOT_HELD="" CXA_SLOT_INFO=""
  [ -n "$CXA_SLOT_POOL" ] || return 0
  cap="${CXA_OPT[cap_$CXA_SLOT_POOL]:-${CX_OPT_DEFAULTS[cap_$CXA_SLOT_POOL]}}"
  wait="$(cx_lock_wait_secs)"
  [ -z "$A_NOWAIT" ] || wait=0
  cx_lock_acquire "$CXA_SLOT_POOL" "$cap" "$wait"
  rc=$?
  case "$rc" in
    0) CXA_SLOT_HELD=1 CXA_SLOT_INFO="${CX_SLOT_FILE:-}" ;;
    28) cxa_unmark_running; cxa_fail 28 NO_CAPACITY "no $CXA_SLOT_POOL capacity: $CX_SLOT_WHY" ;;
    *) cxa_unmark_running; cxa_fail 2 FAILED "pool slot: $CX_SLOT_WHY" ;;
  esac
}

# cxa_kill_session SIG: the executor's whole session (setsid; the wrappers' own timeout puts
# their child in another process group of the same session).
cxa_kill_session() {
  [ -n "${CXA_SID:-}" ] || return 0
  kill "-$1" -- "-$CXA_SID" 2>/dev/null
  command -v pkill >/dev/null 2>&1 && pkill "-$1" -s "$CXA_SID" 2>/dev/null
  return 0
}

CXA_CANCELLED="" CXA_SID="" CXA_KILL_FIRST=TERM CXA_SPAWNING="" CXA_WPID=""
# cxa_sid_wait SECS: the session id the keeper wrote ($OUT/<lane>.sid), polled for up to SECS
# seconds; sets CXA_SID (empty when none came).
cxa_sid_wait() {
  local n lim=$(( $1 * 20 ))
  for ((n = 0; n < lim; n++)); do
    [ -s "$A_OUT/$CX_ADAPTER.sid" ] && break
    [ -z "$CXA_WPID" ] || kill -0 "$CXA_WPID" 2>/dev/null || { [ -s "$A_OUT/$CX_ADAPTER.sid" ] || break; }
    sleep 0.05
  done
  CXA_SID="$(cat "$A_OUT/$CX_ADAPTER.sid" 2>/dev/null)"
  [[ $CXA_SID =~ ^[0-9]+$ ]] || CXA_SID=""
}
# shellcheck disable=SC2329  # invoked by the trap in cxa_run
cxa_on_signal() {
  CXA_CANCELLED=1
  if [ -z "${CXA_SID:-}" ] && [ -n "$CXA_SPAWNING" ]; then
    # The keeper is starting the executor (or has, and the adapter has not read its session id
    # yet): wait for the id, then stop that session; never leave it running unrecorded.
    cxa_sid_wait 5
  fi
  if [ -z "${CXA_SID:-}" ]; then
    # Nothing started yet (queued for a slot, registering): stop now. locks.sh sets no trap of
    # its own, so the job's queued marker is removed here.
    [ -z "$CXA_WPID" ] || kill -KILL "$CXA_WPID" 2>/dev/null
    if [ -n "${CX_JOB_DIR:-}" ]; then rm -f -- "$CX_JOB_DIR/queued"; fi
    if [ -n "$A_OUT" ] && [ -d "$A_OUT" ]; then printf '130\n' > "$A_OUT/rc"; fi
    cxa_fail 130 CANCELLED "cancelled before the $CX_ADAPTER executor started"
  fi
  cxa_kill_session "$CXA_KILL_FIRST"
}

# cxa_wait_exec: waits for the executor (its keeper subshell, $CXA_WPID). After a cancellation it
# polls instead of blocking: KILL to the whole session after CX_KILL_GRACE_SECS (default 10) s,
# and KILL once more at the end, so no process group of the executor's session outlives a
# cancelled run. Sets CXA_RC.
cxa_wait_exec() {
  local t0="" rc=0 grace="${CX_KILL_GRACE_SECS:-10}"
  [[ $grace =~ ^[0-9]{1,4}$ ]] || grace=10
  while :; do
    if [ -n "$CXA_CANCELLED" ]; then
      [ -n "$t0" ] || t0=$SECONDS
      if kill -0 "$CXA_WPID" 2>/dev/null; then
        [ $((SECONDS - t0)) -lt "$grace" ] || cxa_kill_session KILL
        sleep 1 &
        wait "$!" 2>/dev/null
        continue
      fi
      wait "$CXA_WPID" 2>/dev/null
      rc=$?
      break
    fi
    wait "$CXA_WPID" 2>/dev/null
    rc=$?
    kill -0 "$CXA_WPID" 2>/dev/null && continue
    break
  done
  CXA_RC=$rc
  if [ -n "$CXA_CANCELLED" ]; then
    cxa_kill_session KILL
    CXA_RC=130
  fi
}

# cxa_spawn STDIN CWD LIMIT_SECS: starts CXA_ARGV in the worker environment under setsid and
# timeout --kill-after=30s, stdout/stderr into $OUT/<lane>.out/.err. A keeper subshell (stderr to
# /dev/null, so bash's "Killed" job notices never reach anyone) closes the pool slot, the agy
# shared lock and (unless CXA_KEEP_LAUNCH) the launch lock, so only this adapter holds them while
# the executor runs and no daemon the executor leaves behind can keep a slot; it starts the
# executor, records its session id in $OUT/<lane>.sid and $CX_JOB_DIR/sids (cx-job kill signals
# it) before anything else, and waits for it (a trapped TERM/INT/HUP never ends it early).
cxa_spawn() {
  local in="$1" cwd="$2" limit="$3"
  cxa_env_args
  rm -f -- "$A_OUT/$CX_ADAPTER.sid"
  CXA_SPAWNING=1
  (
    trap ':' TERM INT HUP
    [ -z "${CX_SLOT_FD:-}" ] || exec {CX_SLOT_FD}>&-
    [ -z "${CX_SLOT_LEGACY_FD:-}" ] || exec {CX_SLOT_LEGACY_FD}>&-
    [ -z "${CX_LAUNCH_FD:-}" ] || [ -n "${CXA_KEEP_LAUNCH:-}" ] || exec {CX_LAUNCH_FD}>&-
    unset CX_SLOT_FDS
    cd -- "$cwd" || exit 2
    cxa_run_env
    setsid timeout --kill-after="${CXA_KILL_AFTER:-30}s" "${limit}s" env "${CXA_ENVARGS[@]}" "${CXA_ARGV[@]}" \
      < "$in" > "$A_OUT/$CX_ADAPTER.out" 2> "$A_OUT/$CX_ADAPTER.err" &
    p=$!
    if [ -n "${CX_JOB_DIR:-}" ] && [ -d "$CX_JOB_DIR" ]; then printf '%s\n' "$p" >> "$CX_JOB_DIR/sids"; fi
    printf '%s\n' "$p" > "$A_OUT/$CX_ADAPTER.sid.tmp" && mv -f -- "$A_OUT/$CX_ADAPTER.sid.tmp" "$A_OUT/$CX_ADAPTER.sid"
    while :; do
      wait "$p"
      r=$?
      kill -0 "$p" 2>/dev/null || break
    done
    # A wait a trapped signal interrupted returns > 128 even when the child then ended on its
    # own terms: bash keeps the real status for one more wait.
    if [ "$r" -gt 128 ]; then wait "$p"; r2=$?; [ "$r2" = 127 ] || r=$r2; fi
    exit "$r"
  ) 2>/dev/null &
  CXA_WPID=$!
  [ -n "$CXA_SID" ] || cxa_sid_wait 5
  CXA_SPAWNING=""
}

# cxa_on_exit: the executor's session never outlives the adapter (an EXIT trap; a SIGKILLed
# adapter leaves it to cx-job kill, which signals every recorded session).
# shellcheck disable=SC2329  # invoked by the trap in cxa_run
cxa_on_exit() {
  [ -z "${CXA_SID:-}" ] || [ -n "${CXA_REAPED:-}" ] || cxa_kill_session KILL
}

# cxa_exec_default: the plain lanes (copilot, grok, claude --headless, copilot-cloud).
cxa_exec_default() {
  local in="${CXA_STDIN:-/dev/null}" cwd="${A_WT:-$PWD}"
  [ -d "$cwd" ] || cwd="$PWD"
  cxa_spawn "$in" "$cwd" "$((A_TIMEOUT + ${CXA_GRACE:-0}))"
  cxa_wait_exec
}

CXA_RUNJSON=()   # extra run.json KEY VALUE pairs a lane adds
cxa_run() {
  local t0 t1 started
  [ -n "$A_OUT" ] || cx_usage_error "run needs --out DIR"
  rm -f -- "$A_OUT/adapter.why"
  if [ -f "$A_OUT/$CX_ADAPTER.argv" ] && [ -f "$A_OUT/$CX_ADAPTER.meta.json" ] && cxa_files_read; then
    # The argv files win over this call's options: restore what they were built from.
    eval "$(cxa_py meta-env "$A_OUT/$CX_ADAPTER.meta.json")" || cxa_fail 2 FAILED "unreadable $A_OUT/$CX_ADAPTER.meta.json"
  else
    lane_argv
    cxa_files_write
  fi
  cxa_preflight
  # lane_prepare: what a lane needs in place before the slot and the executor (grok: its
  # repository's sandbox profile); it fails with its own exit before anything ran.
  declare -F lane_prepare >/dev/null 2>&1 && lane_prepare
  trap cxa_on_signal INT TERM HUP
  trap cxa_on_exit EXIT
  cxa_mark_running
  cxa_slot
  started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  t0=$SECONDS
  rm -f -- "$A_OUT/rc" "$A_OUT/$CX_ADAPTER.out" "$A_OUT/$CX_ADAPTER.err"
  if declare -F lane_exec >/dev/null 2>&1; then lane_exec; else cxa_exec_default; fi
  t1=$SECONDS
  # Whatever the executor left in its session (a daemon started with &, a TERM-ignoring child)
  # ends with it: its slot must not stay held after the run.
  cxa_kill_session KILL
  CXA_REAPED=1
  declare -F lane_postrun >/dev/null 2>&1 && [ -z "$CXA_CANCELLED" ] && lane_postrun
  cxa_unmark_running
  [ -z "${CXA_SLOT_HELD:-}" ] || cx_lock_release
  # The trap stays until rc and run.json are written: a cancellation delivers more than one
  # signal (cx-job kill signals the runner's session, and cx-run forwards each TERM it gets to
  # this process group), and a late one must never kill this shell between the executor's end
  # and its rc file (cx-run would then report a run that never started). A signal from here on
  # only marks the run cancelled.
  [ -z "$CXA_CANCELLED" ] || CXA_RC=130
  cxa_py obj version:int 1 rc:int "$CXA_RC" started_at "$started" \
    finished_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" duration_s:int "$((t1 - t0))" sid "${CXA_SID:-}" \
    cancelled:bool "${CXA_CANCELLED:-0}" timed_out:bool "$( { [ "$CXA_RC" = 124 ] || [ "$CXA_RC" = 137 ]; } && [ -z "${CXA_NOT_TIMEOUT:-}" ] && echo 1 || echo 0)" \
    host "${CX_HOST:-}" slot "${CXA_SLOT_INFO:-}" cli_version "${CXA_CLI_VERSION:-}" "${CXA_RUNJSON[@]+"${CXA_RUNJSON[@]}"}" \
    > "$A_OUT/$CX_ADAPTER.run.json"
  [ -z "$CXA_CANCELLED" ] || CXA_RC=130
  printf '%s\n' "$CXA_RC" > "$A_OUT/rc.tmp" && mv -f -- "$A_OUT/rc.tmp" "$A_OUT/rc"
  trap - INT TERM HUP
  if [ -n "$CXA_CANCELLED" ]; then
    cxa_fail 130 CANCELLED "cancelled: the $CX_ADAPTER run was interrupted"
  fi
  return 0
}

# ------------------------------------------------------------------ dry run and main

cxa_dry_print() {
  local e sets="" unsets="" a
  printf 'lane: %s (adapter %s, executor %s, pool %s)\n' "$CXA_LANE" "$CX_ADAPTER" "$CXA_EXECUTOR" "$CXA_POOL"
  printf 'model: %s\neffort: %s\nmode: %s\n' "${CXA_MODEL:-none}" "${CXA_EFFORT:-none}" "$A_MODE"
  printf -v a '%q ' "${CXA_ARGV[@]}"
  printf 'argv: %s\n' "${a% }"
  for e in "${CXA_ENV[@]+"${CXA_ENV[@]}"}"; do
    if [ "${e#*=}" = "" ]; then unsets="$unsets ${e%%=*}"; else sets="$sets ${e%%=*}"; fi
  done
  printf 'env set:%s\nenv unset:%s\n' "$sets" "$unsets"
  printf 'cwd: %s\nworktree: %s\n' "${A_WT:-$PWD}" "${A_WT:-none}"
  printf 'slot: %s\n' "${CXA_SLOT_POOL:-none}"
  declare -F lane_dry_extra >/dev/null 2>&1 && lane_dry_extra
  return 0
}

cxa_main() {
  local action="${1-}"
  case "$action" in
    -h|--help) cx_help "$0"; exit 0 ;;
    --version) printf '%s %s\n' "$CX_PROG" "$CX_VERSION"; exit 0 ;;
    probe|argv|run|parse) shift ;;
    "") cx_usage_error "missing action (probe, argv, run or parse)" ;;
    *) declare -F "lane_action_$action" >/dev/null 2>&1 || cx_usage_error "unknown action: $action"; shift ;;
  esac
  A_ACTION="$action"
  cxa_load_opts
  cxa_parse_args "$@"
  if [ "$action" = parse ]; then
    [ -n "$A_OUT" ] || cx_usage_error "parse needs --out DIR"
    cxa_py parse --lane "$CX_ADAPTER" --out "$A_OUT"
    exit $?
  fi
  cxa_record
  lane_setup
  case "$action" in
    probe) cxa_probe ;;
    argv)
      lane_argv
      if [ -n "$A_DRY" ]; then cxa_dry_print; else
        [ -n "$A_OUT" ] || cx_usage_error "argv needs --out DIR (or --dry-run)"
        cxa_files_write
      fi ;;
    run) cxa_run ;;
    *) "lane_action_$action" ;;
  esac
  exit 0
}
