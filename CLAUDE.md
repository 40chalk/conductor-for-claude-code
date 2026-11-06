# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`conductor` is a Claude Code plugin in which Claude Code conducts and the user's subscriptions
execute: GitHub Copilot CLI through the user's own `ghcp` plugin, Grok Build through the raw
`grok` 1.0.70 CLI, Antigravity through the raw `agy` CLI (Opus lane) and the `antigravity`
plugin's wrappers (Gemini, media, research). Claude owns the spec, the gates and the merge. It is
bash plus stdlib-only Python 3 (no jq, no node), published as `40chalk/conductor-for-claude-code`
(also its own marketplace). Plugin id: `conductor@conductor-for-claude-code`; bins `cx-*`;
commands `/conductor:*`; skill `conductor`.

- `docs/DESIGN.md` is the build spec for all of v1; code comments and test tags cite its §
  numbers. `docs/SPEC-NOTES.md` records where the code chose something the spec left open (fold
  accepted items into DESIGN.md).
- Phase 2 (0.2.0) is built through DESIGN §15 build order items 1-3: the pool slots, the
  adapters, `cx-run`, `cx-job`, the normalizer, the ledger, the worker environment, the
  `copilot-cloud` lane and `cx-init --user-grants`; the policy and the skill route every executor
  run through `cx-run`/`cx-job` (§12.2). Not built: item 4 (`agents/cx-runner.md`,
  `hooks/gate.sh`, `workflows/opus-pools.js`, D33; A19-A24, A29: ultracode is normally off),
  Phase 3 (`cx-gate`, `cx-fanout`, the integration queue), Docker lanes (v1.1); v2 notes are in
  DESIGN §19.

## Commands

```bash
bash tests/run-tests.sh                           # whole suite, ~130 s, stubs only
bash tests/run-tests.sh 2>&1 | grep -v '^PASS  '  # failures with detail, skips, sections, totals
CX_TEST_KEEP=1 bash tests/run-tests.sh            # keep the scratch dir (path printed last)
```

There is no per-test filter. The suite needs no network, spends nothing and runs inside Claude
Code's Bash sandbox. To run one script by hand against the stubs, isolate it much like the
suite does (which also unsets every `CLAUDE_PLUGIN_OPTION_*`, `STUB_*`, `CX_*`, `GHCP_*`,
`COPILOT_*`, `GROK_*`, `AGY_*`, `WSL_*` and the API-key variables):

```bash
S=$(mktemp -d "${TMPDIR:-/tmp}/cx.XXXXXX"); mkdir -p "$S/home" "$S/cfg" "$S/root"
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_CODE_REMOTE HOME=$S/home CLAUDE_CONFIG_DIR=$S/cfg XDG_CACHE_HOME=$S/cache \
  CX_HOME=$S/home/.conductor CX_DETECT_ROOT=$S/root PATH="$PWD/tests/stubs:$PATH" \
  GHCP_COPILOT_BIN="$PWD/tests/stubs/copilot" STUB_GROK_AUTH=1 STUB_LOG=$S/stub.log \
  bin/cx-doctor --no-record
```

- `claude plugin validate .` checks the manifests (`ICON_MISSING` is expected). If it reports an
  invalid `.mcp.json`, that is a sandbox placeholder at the repo root: validate a
  `git ls-files` copy instead.
- Simulate Git Bash with `STUB_UNAME_S=MINGW64_NT-10.0-26100` plus the cygpath and wsl.exe
  knobs (see the headers of `tests/stubs/cygpath` and `tests/stubs/wsl.exe`, and `gb_env` in
  the suite).

## Never spend credits by accident

- Put `tests/stubs` first on PATH and set `GHCP_COPILOT_BIN` to the stub: a real `copilot`,
  `grok`, `agy` or `claude` may be installed, and an invalid `GHCP_COPILOT_BIN` makes ghcp fall
  back to `copilot` on PATH (a paid run). Isolate `XDG_CACHE_HOME`: `--pools` reads ghcp's model
  cache there.
- Never run `claude -p`, `copilot -p` (other than the doctor's invalid-model probe), `grok -p`,
  `agy -p` (other than `/usage`, `/model`, `/config`), `cx-run`/`cx-job` or any sibling wrapper
  outside the stubs. Every stub logs its argv; a billable form logs `BILLABLE` and exits 99, and
  `[P30]` fails the suite on it. An executor run in a test needs its scenario knob
  (`STUB_GROK_RUN`, `STUB_GHCP_RUN`, `STUB_AGY_RUN`, `STUB_AGY_DELEGATE_RUN`, `STUB_CLAUDE_RUN`,
  `STUB_GH_AGENT_TASK`).
- The doctor's Copilot login probe is free only on the pinned Copilot 1.0.105, so it runs only
  when D9 reports exactly that version, from the empty `$CX_HOME/probe`.

## Architecture

- **`bin/cx-*`**: 3-line shims to `scripts/cx-*.sh` (exact text in DESIGN §3.6; never
  symlinks; `CDPATH= cd` makes them safe under an exported `CDPATH`).
- **`scripts/lib/common.sh`** (pure bash, also on Git Bash): version and pins, the exit table
  with constant `CX_SIGNAL` reasons, `cx_signal`/`cx_emit` (python when `cx_py_ok`, a
  constant-only line otherwise), `cx_timeout`, `cx_decode_wsl`, the path-option wrappers and
  forwarding step 0 (`cx_forward_if_needed`, which starts with step 0a `cx_cloud_gate`: a cloud
  session, or BYOC without `exec_host=local`, exits 43 before anything runs; a Git Bash or WSL
  host never counts as either). `cx_py_ok` is
  false on Git Bash/MSYS/Cygwin whatever PATH holds.
- **`scripts/lib/options.sh`**: `CX_OPT_DEFAULTS`, `cx_load_options` (python heredoc),
  `cx_opt` (validates; an invalid value prints one note and uses the default), and the pure-bash
  `cx_opt_lite` for `exec_host`/`wsl_distro` and `cx_lite_top`/`cx_lite_value` (top-level
  settings keys and the `env` block for W10/W11) on Git Bash. Keep these readers linear: split
  at quotes once (`IFS='"' read -d '' -a`), search keys with `${x%%"KEY"*}`; `${x#*"KEY"}` and
  `${s:i:1}` loops are quadratic in bash (seconds on a 70 KB settings file).
- **`scripts/lib/cxlib.py`**: every structured job (emit, option checks, sibling report, model
  parsing, host record, doctor rendering, `claude-settings`/`doctor-session` for D31/D32, init
  detection and writing, `wsl-resolve` for cx-wsl).
- **`scripts/host/`**: `detect.sh` (session kind `local|bridge|cloud|byoc` and the attended
  flag from the environment, decided first, but never `cloud`/`byoc` on Git Bash or WSL; then the
  host kind; `CX_DETECT_ROOT` prefixes every file it reads),
  `pathmap.sh` (pure string mapping WSL ↔ Windows ↔ Git Bash; refuses with 42),
  `forward-wsl.sh` (Git Bash side) and `wsl-entry.sh` (WSL side) of the forwarder,
  `install-runtime.sh` (the runtime copy in `~/.conductor/runtime/<version>`).
- **`scripts/cx-run.sh`** (one task on one lane, §15.1): argv (`--` ends the options), the task
  contract (`taskfile.sh`), ids (refused when taken, also by `--dry-run`), the worktree or gate
  checkout (`worktree.sh`; a gate checkout is removed on every exit unless kept on purpose), the
  repo's setup, `--exec auto` over `opus_lane_order`, the adapter's `run` as a background child
  (`bg_wait`), `finish_result` (parse, report, emit, one ledger line per run and per `--finish`,
  the running mark kept only for an ok change waiting for Step 3), one `CX_SIGNAL` for the whole
  run (`CX_SIGNAL_OWNER=cx-run`). `$OUT/.run.lock` (flock, its `rt=` line names the runtime) is
  held for cx-run's life: one cx-run per task. `--finish` covers the claude dispatch and the
  cloud lane (fetch from the task's repository, head confirmed by `gh pr view`).
  **`scripts/cx-job.sh`** (§15.5): detached runners (`setsid`) in `$CX_HOME/jobs/<id>/`, the
  `--dry-run` preflight (refuses on 1 and 42), the task text stored after `--`, `status`,
  `wait`, `result` (the last `CX_SIGNAL` always names the exit), `kill` (rc 130 first, then
  TERM/KILL to proven pids and recorded sessions), `list`, `unpause agy`.
- **`scripts/adapters/<lane>.sh`** (copilot, grok, agy, claude, copilot-cloud; actions `probe`,
  `argv`, `run`, `parse`) on **`scripts/lib/adapter.sh`**: the free preflight (cached 10 min in
  `state/preflight.json`, keyed by the caller side too), the worker environment (§15.6; the
  Copilot token only through the environment, never a command line), the slot (only the adapter
  holds it: the keeper closes the lock descriptors before `setsid timeout <executor>`), the
  session id recorded in `$OUT/<lane>.sid` and `$CX_JOB_DIR/sids` by the keeper, cancellation
  (TERM, KILL after `CX_KILL_GRACE_SECS`=10, a signal during the start waits for the sid), the
  session killed after every run. agy raw: registration, launch lock until `init`, the tree
  snapshot (`agy_trees`: other worktrees, refs, stash, config, hooks, ignored files) and the
  pause (`state/agy-paused`, re-checked after every wait). **`scripts/lib/normalize.py`**
  (classification, `result.json`, `CX_RESULT`, the probe cache, `trees-diff`) and
  **`ledger.py`** (append-only, flock). **`scripts/lib/locks.sh`** (§15.3): `cap_agy`,
  `cap_copilot`, `cap_grok` slots in `$CX_HOME/locks`, the agy launch lock, `CX_SLOT_WAIT_SECS`
  (default 600; forwarded); `cx-wsl` takes a slot for its executor calls.
- **Runtime copy** (`$CX_HOME/runtime/<version>`, `install-runtime.sh`, `cx_runtime_ensure`):
  `cx-run`, `cx-job` and the adapters run from it; an unchanged reinstall only refreshes the
  stamp, and changed content waits while `cx_runtime_users` counts a live run or job on it.
- **`scripts/cx-doctor.sh`**: W1–W11 on Git Bash (pure bash), D1–D32 on the executor host, all
  probes through `probe` (timeout, `/dev/null` stdin, cwd `$CX_HOME/probe`); records go through
  `chk` as TSV and are rendered once by `cxlib.py doctor-render`.
- **`scripts/cx-init.sh`**: detection (`init-plan`) and the all-or-nothing writer
  (`init-apply`). **`scripts/cx-wsl.sh`**: allow-listed passthrough resolved from the host
  record (`ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models ghcp-cloud
  agy-delegate agy-job agy grok gh git bash`), with the §12.2 per-tool environment prefixes and,
  for an executor call (`slot_pool`; free forms such as `--version`, `grok -v`, `models` take
  none), a pool slot it hands to the exec'd tool (an agy call also the launch lock, and 28 while
  agy is paused); its `ghcp-*` arm alone exports `COPILOT_GITHUB_TOKEN` from a 0600
  `$CX_HOME/secrets/copilot-token`. In WSL the skill uses it for its two hand executor calls. On WSL only drive directories (`<mnt root><letter>/`,
  `/mnt/<letter>/`) are the Windows side, in the doctor and in `wsl-resolve` alike.
- **Claude Code side**: `hooks/hooks.json` (both entries `onFailure: continue`) →
  `hooks/policy.sh` (SessionStart `startup|clear|compact`; a compacting `workflow-subagent` or
  `general-purpose` agent gets `subagent-context-compact.json`, another subagent nothing; a cloud
  session, or BYOC (any non-bridge kind) without `exec_host=local`, gets the cloud notice
  `-cloud.json`, never on Git Bash or WSL; else `policy-context.json`,
  `-gitbash.json` or the CRLF notice `-crlf.json`, rendering `{ORDER}` from `opus_lane_order`
  and `{ATTN}` when `CLAUDE_CODE_SESSION_ATTENDED=0`) and `hooks/subagent.sh` (SubagentStart
  `workflow-subagent|general-purpose`: subagents never run executors directly; only a task that
  names `cx-run --background` may),
  `skills/conductor/SKILL.md`, `commands/{doctor,init,route}.md`, `templates/projects-instructions.md`
  (pasted by the user into Project settings > Memory), `worker-shims/*` (exit 126 inside workers).
- **Session kinds** (DESIGN §7.1): every Claude Code Project thread runs as a Work locally thread
  (`bridge`, local behaviour); cloud handling is only a never-fail safety net. Ultracode is
  normally off; workflow and Agent-tool subagents never run executors directly (the SubagentStart
  rule), only `cx-run --background` when their task names it. The pool slots are shared by every
  session, thread, workflow agent and forwarded call on the computer.
- **The skill's recipe** (SKILL section 4 = DESIGN §12.2, `[P43]` compares every bash line):
  step 1 the contract (`~/.conductor/tasks/t1.md` in WSL, never `/tmp`, which grok runs may
  write; from Windows a Windows-side path, never Git
  Bash's `/tmp`: exit 42); step 2 `cx-run`/`cx-job` (`vars.sh` comes from cx-run); step 3 the
  conductor's squash commit and gate (`BRANCH_TAMPERED` 24); step 4 reviews; step 5 GitHub,
  `cx-wsl ghcp-ci-debug` and its hand-back to `cx/<id>`. The hand steps' only executor calls are
  `cx-wsl grok` (commit messages) and `cx-wsl ghcp-ci-debug`: `cx-wsl` takes the slot and adds the
  prefix, in WSL as from Windows. The D25 rules match the skill's command forms both ways.

## Options

Claude Code injects `CLAUDE_PLUGIN_OPTION_*` into hooks only, so scripts re-read
`${CX_WIN_SETTINGS}` (forwarded calls) and `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` →
`.pluginConfigs["conductor@conductor-for-claude-code"].options` (else `conductor`, else the first
`conductor@…`). Precedence: environment (even empty) > Windows-side settings > executor-host
settings > `CX_OPT_DEFAULTS`. Every default is written twice (`plugin.json` and
`CX_OPT_DEFAULTS`; `[P2]` pins them equal). `policy.sh` reads only the injected
`CLAUDE_PLUGIN_OPTION_POLICY`, `_OPUS_LANE_ORDER` and `_EXEC_HOST` (byoc), `subagent.sh` only
`_POLICY`. No spend caps: `copilot_reserve_pct`
and `agy_claude_floor_pct` default to `0` and nothing advises a cap; `cap_agy`, `cap_copilot`
and `cap_grok` (2, 3, 5) are concurrency limits, not spend limits. `CX_SLOT_WAIT_SECS` (600) is an
environment variable, forwarded from Git Bash; `CX_KILL_GRACE_SECS` (10) and
`CX_AGY_INIT_SECS` (120) are test knobs read only by the adapters.

## Exit codes and the `CX_*` protocol

0 ok · 1 usage (no `CX_SIGNAL`) · 2 FAILED · 3 EMPTY_OUTPUT · 4 CHECKS_FAILED · 5 EXISTS ·
10–16 as ghcp · 20 GATE_FAILED (`cx-run --finish` of the cloud lane) · 21 MODEL_MISMATCH · 22
WRONG_TREE (agy paused) · 23 SPEC_TAMPERED · 24 TAMPERED (cx-run: the worktree's `.git`
rewritten; the skill's Step 3: BRANCH_TAMPERED) · 25
ENV_FAILED · 26 VERSION_MISMATCH · 27 PARTIAL · 28 NO_CAPACITY (slots, cap 0, agy paused) · 40
FORWARD_FAILED · 41 RUNTIME_MISSING · 42 PATH_UNMAPPABLE · 43 HOST_UNSUPPORTED · 44 CRLF_CORRUPT ·
75 RUNNING (`cx-job`) · 126 worker shim · 130 CANCELLED. `cx-run` owns the single signal of a
run (adapters run with `CX_SIGNAL_OWNER`); `cx-job result`/`wait` relay the job's last signal
only when it names the job's rc (rc 1: notes, no signal; 124/137: 12). Every exit outside {0, 1, 126} prints exactly one
`CX_SIGNAL {json}` line, last on stderr; in a forwarded call each failure has one signal owner
(DESIGN §7.3 step 8). `cx-wsl` passes the tool's status and output through and adds no `CX_*`
line (wsl-entry.sh emits no `CX_FORWARD` for it). `CX_*` stderr lines are single-line
`json.dumps(ensure_ascii=True)` with default separators and are an API.

## Forwarding (Git Bash → WSL)

Step 0 in every `cx-*` script: hosts `wsl`, `linux`, `macos`, `docker` run locally; Git Bash
always forwards (a leaked `CX_FORWARDED` never makes it run locally); Cygwin/unknown exit 43.
The forwarder writes `argv` (NUL-separated), `env` (only `CX_WORKER`, `CX_DEBUG`, `NO_COLOR`,
`CX_SLOT_WAIT_SECS` and the option variables) and `meta` into a temp dir, passes only `CX_FWD_WIN` through `WSLENV`,
and runs `wsl.exe [-d D] --cd ~ --exec /bin/bash --noprofile --norc
.conductor/runtime/<v>/scripts/host/wsl-entry.sh` as a background child. Every Windows path it
emits comes from `cygpath -w -l`. `CX_DEBUG=1` keeps the temp dir. The runtime is installed on
first use from the Git Bash side (`bash -s` with `CX_STAGE_WIN`), unless `CX_NO_AUTO_INSTALL=1`.

## Invariants

- Python always runs as `python3 -I`, only in `scripts/lib/*.py` (`cxlib.py`, `normalize.py`,
  `ledger.py`; normalize.py loads cxlib.py by path with bytecode writing off, so no
  `__pycache__` lands in the plugin) or quoted `python3 -I - <<'PY'` heredocs in `options.sh`;
  never `python3 -c`. Settings and
  `installed_plugins.json` are read with `utf-8-sig`. JSON with variable content is built with
  `json.dumps`; the only hand-built JSON is `cx_signal`'s constant fallback.
- Git Bash code paths (shims, `common.sh`, the lite reader, `detect.sh`, `pathmap.sh`,
  `forward-wsl.sh`, `cx-wsl.sh`'s forwarding, the doctor's Windows part, `policy.sh`,
  `subagent.sh`) use only
  bash and the tools of DESIGN §3.1; `[P42]` runs them on a mini bin with a python3 trap.
- Bash: `#!/usr/bin/env bash`, `set -uo pipefail` without `-e` (check rcs), `unset CDPATH` in
  scripts that `cd`, empty-array-safe expansions, `shellcheck -x` clean (line 2 of each script
  is `# shellcheck source-path=SCRIPTDIR`). Each script's header comment is its `--help`;
  user-facing scripts answer `-h|--help` and `--version` before any other work.
- Everything is LF; `hooks/policy.sh` and `hooks/subagent.sh` alone are CRLF-tolerant (every
  line ends in ` #`); `policy.sh` reports a CRLF copy through three canary files. No fix text ever uses `git reset` or
  `rm -r --cached`.
- Hooks fail open and are silent when `CX_WORKER` is set (not `0`); a hook that exits 0 has its
  stderr discarded, so user-visible notes go into the JSON (`systemMessage`). Never route on
  `CLAUDE_CODE_ENTRYPOINT`, never read `CLAUDE_CODE_VERSION` or `CLAUDE_PROJECT_DIR` in scripts
  (`[P62]`; D30's wording lines are allow-listed).
- Nothing conductor-specific is ever written into a repo's `CLAUDE.md` or `.claude/`.
- The scripts' git in a worktree an executor wrote runs only through `worktree.sh`'s
  `cx_wt_git` (the git directory from the main repository's admin files, never the worktree's
  own `.git`; `CX_WT_GITC`: no fsmonitor, hooks, pager, textconv or submodules), never
  `git -C "$WT"`; a rewritten link is 24 `tampered` (the skill's Step 3 runs only after an ok
  run, so after that check). Executors get only `cx-route <name>` and
  `git status` (agy also `ls`), never `git diff`/`log`/`show` (`--output=` writes any file);
  the run's `cx-route` lives in `$CX_HOME/routes/<id>/` (grok's profile reads only that root).
- Executors run only inside `cx-run` (the adapters) and, for the hand steps and Windows tool
  calls, `cx-wsl`; both take the pool slot. Never put a secret on a command line (argv is
  world-readable in `/proc`): the Copilot token travels in the environment only. An adapter's
  executor never inherits a lock descriptor; temporary files come from `cx_mktemp`, in
  `$CX_HOME/tmp` (0700), never `$TMPDIR` or `/tmp`, which every strict-based grok run may write
  (only the Git Bash side keeps the Windows temp directory; a static `[X]` check greps it).
- `<checkout>/.conductor/` is the conductor's: written only through `cx_cdir` (a real directory
  holding no symlink) and `cx_cput` (a new file); a read or review of a commit that tracks
  `.conductor` exits 2 before its checkout; `info/exclude` gets `/.conductor` (no slash).
- `cx-wsl grok` runs (forms that take a slot) need `--sandbox strict` and an absolute `--cwd`
  (else 1) and run from that directory; the skill's one `cx-wsl grok` line is pinned by a
  static check (`$OUT/msg` emptied first, strict only, no `--cwd "$TOP"`).

## Changes that touch many files

- **Exit code**: DESIGN §4.1, `common.sh` (`CX_EXIT_STATUS`, reasons, retries), each script
  header (`[P10]` checks every code a script returns is listed; the adapters list theirs in
  `adapter.sh` and each `scripts/adapters/*.sh`), `normalize.py`'s classification (`ORDER`, the
  status → exit map), `cx-run`'s stop statuses, `cx-job`'s `do_result`, README and SKILL tables.
- **Adapter or lane**: `scripts/adapters/<lane>.sh` and its header, `adapter.sh`'s options,
  `normalize.py` (`PARSERS`, the lane's facts), the stub's scenarios (`STUB_*_RUN` in
  `tests/stubs/*`), the A1 help fixture (`tests/fixtures/real/*/help.txt`; agy's is
  the captured `tests/fixtures/real/agy/help.txt`), `cx-run`'s
  `lane_args`/`lane_adapter`, DESIGN §15.2, the skill's lane rows.
- **Option**: `plugin.json`, `CX_OPT_DEFAULTS` and `CX_OPT_NAMES`, `cx_opt_check` and
  `cxlib.check_option`, DESIGN §5.1, README table, `OPT_EXPECT` in the tests.
- **Policy text**: DESIGN §10.3–§10.6 blocks and the four `hooks/policy-context*.json`
  (`[P20]`, `[P47]` compare them byte for byte; the WSL and Git Bash texts ≤ 2800 characters
  rendered with the longest order and the `{ATTN}` sentence). The subagent block of §10.7 and
  `hooks/subagent-context{,-compact}.json` (`[P55]`, ≤ 800); the §9.6 block and
  `templates/projects-instructions.md` (`[P52]`). Regenerate the JSON from the blocks with
  `json.dumps(obj, indent=2, ensure_ascii=True) + "\n"`.
- **Session kinds**: `cx_session` in `detect.sh` and the cloud lines of `hooks/policy.sh` (the
  case line and the Git Bash/WSL override; DESIGN §7.1 and §10.2 row 4, `[P46]`, `[P48]`,
  `[P49]`); the Remote Control blocker list in `cxlib.py` (`RC_BLOCK_ENV`, D31), W10 in
  `cx-doctor.sh` and DESIGN §1.7; the executor names in the policy, the subagent guard and
  (Phase 2) the gate.
- **`cx-wsl` allowlist or prefixes**: DESIGN §7.7 and §12.2, `cx-wsl.sh` (and its `slot_pool`
  free forms), `CX_WSL_KEYS` in `cxlib.py`, SKILL.md, README, `[P43]`, `[P45]`. The Git Bash
  policy names only the `cx-wsl` uses left (gh, git, `ghcp-cloud list`/`view`,
  `ghcp-ci-debug`, the hand steps), never the executor tools.
- **A command form in the skill**: DESIGN §12.2 (P43 compares every bash line),
  `D25_HOST_RULES`/`D25_WIN_RULES` in `cxlib.py` (P43 checks both ways: every executor and
  GitHub command of the skill matches a rule, every rule matches one), the DESIGN §8.3 D25 row
  and README's allow-rule lists.
- **Version bump**: `plugin.json`, `marketplace.json`, `CX_VERSION`, `cxlib.VERSION`, a new
  `## x.y.z — date` heading in `CHANGELOG.md` (`[P2]`).
- **grok's home-writing built-ins** (`off`, `devbox`, `workspace`, `read-only`):
  `GROK_HOME_WRITERS` in `normalize.py` and D17's case arm in `cx-doctor.sh` (a static `[X]`
  check pins them equal), DESIGN §1.3, §8.3 D17, §15.2 and §15.7, README, SKILL troubleshooting.
- **Pin bump**: `CX_PIN_*` in `common.sh`, DESIGN §1 and §5.4, README.
- **New shipped file**: DESIGN §13.4, `CX_SHIPPED_FILES`/`CX_SHIPPED_EXEC`,
  `install-runtime.sh` dirs and D4's subset (`[P41]`).
- **Git Bash tool use**: DESIGN §3.1's list and the `GB_MINI` list in the tests.

## Tests

- Tags: `[P1]`–`[P63]` (plus `[P22b]`) are DESIGN §14.3 cases, `[A1]`–`[A30]` the Phase 2 cases
  of §15.8 (all but A19–A24 and A29, the optional item 4 that is not built), `[X]` is extra
  coverage. Add a check with `check "[X] name" cmd args…`; most checks are single-quoted `eval`
  strings. Helpers: `run`/`runin`, `rc_is`, `out_has`, `err_has`, `one_signal STATUS`,
  `line_is CX_NAME key value`, `outj_is`; doctor lines `d_ok/d_warn/d_fail/d_info ID TEXT`;
  adapters `ad`, `adr` (run then parse: `$PR`, `$RJ`), `ad_bg`; `cx-run`/`cx-job` `cr`;
  `hold FILE -x MARKER` (holds an flock), `wait_file`, `alive PID` (a zombie is not alive).
- Isolation: one mktemp root holds HOME, CLAUDE_CONFIG_DIR, XDG_*, TMPDIR, CX_HOME and an empty
  `CX_DETECT_ROOT`; the suite runs from a scratch cwd with `tests/stubs` first on PATH. It also
  unsets every `CLAUDE_CODE_*` and, by name (`ISO_VARS`, `[P62]`), the session, Work locally and
  workflow signals: a Claude Code cloud session (this build container) sets
  `CLAUDE_CODE_REMOTE=true`, which would flip every policy case to the cloud notice. On a real
  WSL kernel it pins `STUB_UNAME_R` to a plain one (a WSL host is never cloud, so the cloud
  cases would turn local); cases that need WSL or Git Bash set `STUB_UNAME_*` themselves.
- Parallelism: the static, cx-init, doctor, slots, adapter (three), cx-run (four), cx-job, A25
  and forwarding sections run as background sections (`bg_section`/`join_section`, own
  `$O`/`$E` files and counters, each in its own `$CX_HOME` and stub log); doctor and Git Bash
  runs go through a pool (`doc_bg`, `gb_bg`, `POOL_MAX`). A background section must not rely on
  variables set by another; shared helpers live above the sections. A background section that
  forwards from the simulated Git Bash gets its own python3 trap (`gb_private_mini`) and checks
  it itself (P42).
- Stubs: each logs one line per call to `$STUB_LOG` (`NAME<TAB>cwd=…<TAB>extras<TAB>argv: <%q
  args>`). Knobs are `STUB_*` variables (see each stub's header); knobs that must survive the
  forwarder's `env -i` are read from `$HOME/.stub.env` (the WSL-side home). Don't symlink a
  stub: it finds `.stublib` and `../fixtures` relative to its own path.
- Git Bash simulation: `STUB_UNAME_S`, a fake Windows root (`$TMP/win/<x>` ↔ `X:\`,
  `$TMP/unc` ↔ `\\wsl.localhost\Ubuntu\`, `$TMP/share` ↔ `\\server\share\`), a wsl.exe stub
  that runs the WSL side under `env -i`, and per-scenario clones of a template WSL home
  (`wsl_clone`) that holds settings, the fake sibling plugins, an interactive host record and
  the runtime copy. A test-only `scripts/cx-gate.sh` inside the cloned runtime records the
  forwarded target's environment, cwd and argv.
- `tests/fixtures/` is marked `-text` (intentional CRLF and UTF-16LE bytes); its README labels
  each file verified or synthetic (`real/` holds the captured help texts and ghcp's real Copilot
  recordings, and agy 1.4.12's help). Some checks are timing-based (agy hang with
  `CX_PROBE_TIMEOUT=2`, INT cancellation within 6 s, cx-job kill's KILL after 10 s, the adapter's
  KILL grace, the slot waits) and could flake on a loaded machine.

## Unverified

Do not treat these as facts (DESIGN §20): the Windows app's `$PWD` form for `\\wsl.localhost`
projects and which shell runs hooks on Windows; whether WSL keeps detached jobs alive after the
last `wsl.exe` exits; wsl.exe's stdin/Ctrl-C relay and `WSL_UTF8`; agy's `--output-format json`
and `/usage` shapes and whether `/usage` is zero-quota; grok's logged-in `models` listing and
exit code; the `Task(...)`/`Agent(...)` deny-rule syntax and how env-prefixed allow rules match on
2.1.316; whether `claude plugin update` re-copies an unchanged version; above all whether
`claude remote-control` started inside WSL serves Work locally threads with the WSL plugins
(live check L11, first); the SubagentStart matcher's alternation and injection timing, bridge
children's `CLAUDE_CODE_SESSION_ATTENDED`, and what a compacting subagent's SessionStart payload
holds (DESIGN §20 items 40–61); that Copilot signs in with `COPILOT_GITHUB_TOKEN`, that
`gh repo view` resolves SSH host aliases, and `ghcp-cloud`'s host-qualified `-R` (items 62–65);
agy's stream-json events, whether `--effort xhigh|max` applies to the Opus slugs and whether
its `-p /model|/usage|/config` slash forms cost quota (items 67, 68; its flags themselves are
verified against the captured 1.4.12 help), and claude -p's result shape (§20); whether grok
reads `--prompt-file` before its sandbox applies or under it, whether its daemon backend ever
runs a conductor run, and which directory `strict`'s CWD grant follows when the process cwd and
`--cwd` differ (items 77, 78, 80; all moot or refused by construction); under the built-in
`read-only` only an append-open of grok's protected set was measured denied, not a rename in the
writable `~/.grok` (item 76).
