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
- Phase 1 (0.1.0) has no `cx-run`: the policy and the skill route through the sibling wrappers'
  exact commands (DESIGN §12.2). Docker lanes are v1.1; v2 notes are in DESIGN §19.

## Commands

```bash
bash tests/run-tests.sh                           # whole suite, ~70 s, stubs only
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
  `agy -p` (other than `/usage`, `/model`, `/config`) or any sibling wrapper outside the stubs.
  Every stub logs its argv; a billable form logs `BILLABLE` and exits 99, and `[P30]` fails the
  suite on it.
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
- **`scripts/cx-doctor.sh`**: W1–W11 on Git Bash (pure bash), D1–D32 on the executor host, all
  probes through `probe` (timeout, `/dev/null` stdin, cwd `$CX_HOME/probe`); records go through
  `chk` as TSV and are rendered once by `cxlib.py doctor-render`.
- **`scripts/cx-init.sh`**: detection (`init-plan`) and the all-or-nothing writer
  (`init-apply`). **`scripts/cx-wsl.sh`**: allow-listed passthrough resolved from the host
  record (`ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models ghcp-cloud
  agy-delegate agy-job agy grok gh git bash`), with the §12.2 per-tool environment prefixes;
  its `ghcp-*` arm alone exports `COPILOT_GITHUB_TOKEN` from a 0600
  `$CX_HOME/secrets/copilot-token`. On WSL only drive directories (`<mnt root><letter>/`,
  `/mnt/<letter>/`) are the Windows side, in the doctor and in `wsl-resolve` alike.
- **Claude Code side**: `hooks/hooks.json` (both entries `onFailure: continue`) →
  `hooks/policy.sh` (SessionStart `startup|clear|compact`; a compacting `workflow-subagent` or
  `general-purpose` agent gets `subagent-context-compact.json`, another subagent nothing; a cloud
  session, or BYOC (any non-bridge kind) without `exec_host=local`, gets the cloud notice
  `-cloud.json`, never on Git Bash or WSL; else `policy-context.json`,
  `-gitbash.json` or the CRLF notice `-crlf.json`, rendering `{ORDER}` from `opus_lane_order`
  and `{ATTN}` when `CLAUDE_CODE_SESSION_ATTENDED=0`) and `hooks/subagent.sh` (SubagentStart
  `workflow-subagent|general-purpose`: the Phase 1 rule that subagents never run executors),
  `skills/conductor/SKILL.md`, `commands/{doctor,init,route}.md`, `templates/projects-instructions.md`
  (pasted by the user into Project settings > Memory), `worker-shims/*` (exit 126 inside workers).
- **Session kinds** (DESIGN §7.1): every Claude Code Project thread runs as a Work locally thread
  (`bridge`, local behaviour); cloud handling is only a never-fail safety net. Ultracode is
  normally off; in Phase 1 workflows never run executors (the main turn does), and the Phase 2
  runner agent, gate and `opus-pools` workflow are optional. Phase 2 starts with cross-process
  pool slots taken by every executor path, `cx-wsl` included; until then agy runs one job at a
  time across threads, enforced by the skill's lock line (`flock` on `~/.conductor/locks/agy`,
  `AGY_BUSY` exit 28), and agy has no job form.
- **The skill's recipe** (SKILL section 4 = DESIGN §12.2, `[P43]` compares every bash line):
  step 1 writes `vars.sh` with the `trees` snapshot (one definition; it skips Claude Code's
  worktrees under the main checkout and every worktree a dispatch marked in
  `~/.conductor/out/<id>/running`); `REPO` comes from `gh repo view`; the agy steps take the
  lock before they register; `ghcp-ci-debug --apply` is handed back to `cx/<id>` before step 3;
  the Copilot cloud agent's PR is gated on a gate checkout. Scratch-repo checks run `trees`,
  the lock, step 3 and the hand-back.

## Options

Claude Code injects `CLAUDE_PLUGIN_OPTION_*` into hooks only, so scripts re-read
`${CX_WIN_SETTINGS}` (forwarded calls) and `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` →
`.pluginConfigs["conductor@conductor-for-claude-code"].options` (else `conductor`, else the first
`conductor@…`). Precedence: environment (even empty) > Windows-side settings > executor-host
settings > `CX_OPT_DEFAULTS`. Every default is written twice (`plugin.json` and
`CX_OPT_DEFAULTS`; `[P2]` pins them equal). `policy.sh` reads only the injected
`CLAUDE_PLUGIN_OPTION_POLICY`, `_OPUS_LANE_ORDER` and `_EXEC_HOST` (byoc), `subagent.sh` only
`_POLICY`. No spend caps: `copilot_reserve_pct`
and `agy_claude_floor_pct` default to `0` and nothing advises a cap.

## Exit codes and the `CX_*` protocol

0 ok · 1 usage (no `CX_SIGNAL`) · 2 FAILED · 3 EMPTY_OUTPUT · 4 CHECKS_FAILED · 5 EXISTS ·
10–16 as ghcp · 20–28 gates and run checks (Phases 2–3) · 40 FORWARD_FAILED · 41
RUNTIME_MISSING · 42 PATH_UNMAPPABLE · 43 HOST_UNSUPPORTED · 44 CRLF_CORRUPT · 75 RUNNING ·
126 worker shim · 130 CANCELLED. Every exit outside {0, 1, 126} prints exactly one
`CX_SIGNAL {json}` line, last on stderr; in a forwarded call each failure has one signal owner
(DESIGN §7.3 step 8). `cx-wsl` passes the tool's status and output through and adds no `CX_*`
line (wsl-entry.sh emits no `CX_FORWARD` for it). `CX_*` stderr lines are single-line
`json.dumps(ensure_ascii=True)` with default separators and are an API.

## Forwarding (Git Bash → WSL)

Step 0 in every `cx-*` script: hosts `wsl`, `linux`, `macos`, `docker` run locally; Git Bash
always forwards (a leaked `CX_FORWARDED` never makes it run locally); Cygwin/unknown exit 43.
The forwarder writes `argv` (NUL-separated), `env` (only `CX_WORKER`, `CX_DEBUG`, `NO_COLOR` and
the 24 option variables) and `meta` into a temp dir, passes only `CX_FWD_WIN` through `WSLENV`,
and runs `wsl.exe [-d D] --cd ~ --exec /bin/bash --noprofile --norc
.conductor/runtime/<v>/scripts/host/wsl-entry.sh` as a background child. Every Windows path it
emits comes from `cygpath -w -l`. `CX_DEBUG=1` keeps the temp dir. The runtime is installed on
first use from the Git Bash side (`bash -s` with `CX_STAGE_WIN`), unless `CX_NO_AUTO_INSTALL=1`.

## Invariants

- Python always runs as `python3 -I`, only in `scripts/lib/*.py` or quoted
  `python3 -I - <<'PY'` heredocs in `options.sh`; never `python3 -c`. Settings and
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

## Changes that touch many files

- **Exit code**: DESIGN §4.1, `common.sh` (`CX_EXIT_STATUS`, reasons, retries), each script
  header (`[P10]` checks every code a script returns is listed), README and SKILL tables.
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
- **`cx-wsl` allowlist or prefixes**: DESIGN §7.7 and §12.2, `cx-wsl.sh`, `CX_WSL_KEYS` and
  `D25_HOST_RULES` in `cxlib.py`, SKILL.md, the Git Bash policy (it names the allowlist), README,
  `[P43]`, `[P45]`.
- **Version bump**: `plugin.json`, `marketplace.json`, `CX_VERSION`, `cxlib.VERSION`, a new
  `## x.y.z — date` heading in `CHANGELOG.md` (`[P2]`).
- **Pin bump**: `CX_PIN_*` in `common.sh`, DESIGN §1 and §5.4, README.
- **New shipped file**: DESIGN §13.4, `CX_SHIPPED_FILES`/`CX_SHIPPED_EXEC`,
  `install-runtime.sh` dirs and D4's subset (`[P41]`).
- **Git Bash tool use**: DESIGN §3.1's list and the `GB_MINI` list in the tests.

## Tests

- Tags: `[P1]`–`[P63]` (plus `[P22b]`) are DESIGN §14.3 cases, `[X]` is extra coverage. Add a
  check with `check "[X] name" cmd args…`; most checks are single-quoted `eval` strings.
  Helpers: `run`/`runin`, `rc_is`, `out_has`, `err_has`, `one_signal STATUS`, `line_is CX_NAME
  key value`, `outj_is`; doctor lines `d_ok/d_warn/d_fail/d_info ID TEXT`.
- Isolation: one mktemp root holds HOME, CLAUDE_CONFIG_DIR, XDG_*, TMPDIR, CX_HOME and an empty
  `CX_DETECT_ROOT`; the suite runs from a scratch cwd with `tests/stubs` first on PATH. It also
  unsets every `CLAUDE_CODE_*` and, by name (`ISO_VARS`, `[P62]`), the session, Work locally and
  workflow signals: a Claude Code cloud session (this build container) sets
  `CLAUDE_CODE_REMOTE=true`, which would flip every policy case to the cloud notice. On a real
  WSL kernel it pins `STUB_UNAME_R` to a plain one (a WSL host is never cloud, so the cloud
  cases would turn local); cases that need WSL or Git Bash set `STUB_UNAME_*` themselves.
- Parallelism: the static, cx-init and doctor sections run as background sections
  (`bg_section`/`join_section`, own `$O`/`$E` files and counters); doctor and Git Bash runs go
  through a pool (`doc_bg`, `gb_bg`, `POOL_MAX`). A background section must not rely on
  variables set by another; shared helpers live above the sections.
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
  each file verified or synthetic. Two checks are timing-based (agy hang with
  `CX_PROBE_TIMEOUT=2`, INT cancellation within 6 s) and could flake on a loaded machine.

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
`gh repo view` resolves SSH host aliases, that agy keeps the lock fd for its whole run, and
`ghcp-cloud`'s host-qualified `-R` (items 62–65).
