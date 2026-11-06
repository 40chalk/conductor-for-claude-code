# Changelog

## 0.2.1 — 2026-11-06

Fixes from the first real runs (one small `cx-run` per lane on the user's machine, 2026-11-02)
and from live probes of agy 1.5.1, grok 1.0.70 and Copilot CLI 1.0.105 (2026-11-06). No CLI
version is pinned any more.

- **No version pins.** `CX_PIN_*` are gone (`CX_VERIFIED_*`: the versions the lanes were last
  verified against, shown by `cx-doctor` as info lines, never a failure). Instead every adapter
  checks a **flag contract** in its free preflight: the CLI's live `--help` (and `copilot help
  permissions`, and the Copilot argv `ghcp-delegate --print-command` builds) must list every flag
  the lane is about to emit; a missing one refuses the lane before it runs with exit 26 (status
  `VERSION_MISMATCH`, reason "flag contract"). The check is cached with the probe (10 minutes,
  keyed by the flags and the binaries' identity, so an update re-probes at once). `cx-doctor`
  no longer tells you to disable auto-update (D14 is one info line); the worker environment still
  turns self-updates off for each run. D16 probes Copilot's login through `ghcp-models` (ghcp's
  free probe) on any version; the raw invalid-model probe runs only on 1.0.105.
- **`cx-route`.** At dispatch `cx-run` snapshots the task's checks, named from `.cx/routes.json`
  (`test`, `lint`, `typecheck`, other keys; `cmd-N` for a task's own command), into
  `$OUT/routes.json` and a generated, self-contained `$OUT/bin/cx-route` on the worker's PATH.
  `cx-route <name>` runs only that snapshot (an edit of the worktree's `routes.json` never reaches
  it), its exit status passes through, an unknown name or any extra argument exits 127. The task
  template, the default prompt and the review prompt tell every executor to run checks only as
  `cx-route <name>`.
- **agy**: each raw run passes `--settings $OUT/agy-settings.json` (session-only): `write_file(<the
  worktree>)` and `command()` for `cx-route`, `git status`, `git diff`, `git log`, `git show` and
  `ls`, never `--dangerously-skip-permissions`; its prompt says to read with agy's own file tools
  and that any other command ends the run (one denial ends a headless run). `cx-init
  --user-grants` writes no agy grant any more (a note, and `cx-doctor` D18, name the global grants
  0.2.0 left). The parser reads agy's real stream-json (`{"event": "init"|"step_update"|"result"}`)
  and names a denied command from its `step_update` (`tool_info.parameters.CommandLine`) in
  `result.json` `denied[].command` and `CX_DENIED.commands`; the hint no longer suggests a
  routes edit as the fix for an agy denial.
- **grok**: writers run under their repository's own sandbox profile `cx-<repo>-<hash>` in
  `~/.grok/sandbox.toml` (extends `strict`; `read_only` the repository's git directory and
  `~/.conductor/out`), written idempotently under a lock by the lane (or `cx-init
  --user-grants`), with `--sandbox <it> --always-approve` instead of `--permission-mode
  acceptEdits` and `--allow` rules (acceptEdits denied the first edit headless);
  `GIT_CONFIG_GLOBAL=/dev/null` in its worker environment. Option `grok_sandbox_profile` now
  defaults to `auto` (the 0.2.0 value `cx-workspace` counts as auto), and the invalid 0.2.0
  `cx-workspace` block (glob deny paths) is removed from `sandbox.toml`. Served-model alias:
  `grok-4.7` served as `grok-4.7-build` is accepted (an explicit suffix table); anything else
  stays 21. `cx-doctor` D17 checks for bubblewrap on Linux and WSL.
- **Copilot**: `--allow-shell cx-route` plus `git status`, `git diff`, `git log`, `git show`
  (Copilot approves a shell call by its command name, so `shell(python3 -m unittest …)` never
  matched and the real run's tests were denied); never `shell(python3)` or `shell(:*)`.
- `PYTHONDONTWRITEBYTECODE=1` in every worker environment (Python checks left `__pycache__` in
  the worktree).
- Tests: the parsers on every real run directory (`tests/fixtures/real/*/sbx-*`), A1 against the
  real agy 1.4.12 and 1.5.1, grok 1.0.70, Copilot 1.0.105 and `copilot help permissions` texts,
  the flag contract refusing a stub help without a flag, `cx-route` refusing anything outside the
  snapshot; new fixtures `real/agy/help-1.5.1.txt`, `real/copilot/help-permissions.txt` and
  `real/ghcp/print-command-cx-route.txt`.

## 0.2.0 — 2026-11-01

Phase 2 (docs/DESIGN.md section 15, build order items 1 to 3): every executor lane runs through
`cx-run` and `cx-job`. Executor runs are billed to the subscriptions as before; the suite still
spends nothing.

- Cross-process pool slots (`scripts/lib/locks.sh`, `flock`): `cap_agy`, `cap_copilot` and
  `cap_grok` hold across every session, Work locally thread and forwarded call on the computer;
  agy launches never overlap. `cx-wsl` takes a slot for its executor calls (free forms take
  none); a pool that stays full for `CX_SLOT_WAIT_SECS` (600 s) exits 28 `NO_CAPACITY`. They
  replace the Phase 1 agy lock (still honoured, shared, while an older skill copy runs).
- Adapters `scripts/adapters/{copilot,grok,agy,claude,copilot-cloud}.sh` (probe, argv, run,
  parse; the shared `scripts/lib/adapter.sh`): free preflight (pins 26, login 11, catalog 14,
  agy paused 28; green probes cached 10 minutes), the worker environment (shims first,
  `CX_WORKER=1`, API keys and `CLAUDE_PLUGIN_OPTION_*` unset, auto-update pins), executors under
  `setsid timeout`, agy raw mode (registration, launch lock until the init event, init-model
  check 21, SIGKILL 5 s after the result, tree snapshots 22 with `state/agy-paused`), Copilot
  through ghcp (`GHCP_FALLBACK` on Fusion 21, #5149), grok's `permission required:` 15, the
  claude dispatch and `--headless`, the Copilot cloud agent through `ghcp-cloud`.
- `normalize.py` (classification, `result.json`, `CX_RESULT`, `CX_DENIED`, `CX_NOTE`, the
  `VERIFY THIS:` line) and `ledger.py` (append-only, flock and fsync; `claude_session`,
  `claude_effort`).
- `cx-run`: one task on one lane (`--exec auto|agy|copilot|grok|claude|copilot-cloud`, `--mode
  write|read|review`, `--family gemini|gpt`, `--dry-run`, `--explain`, `--background`,
  `--finish`): the task contract (line-1 JSON, or free text in `templates/task.md`) and its
  hash (23), a worktree on `cx/<id>` under `worktree_root`, the repo's setup (25), the pool
  slot, the post-checks (no diff 3, diffstat), `vars.sh` for the skill's commit and gate step;
  `--exec auto` follows `opus_lane_order`, waits for a slot, then takes the claude lane; a cwd
  under `.claude/worktrees/` needs `--repo`; `--finish` of the cloud lane gates the pull
  request head (20 `GATE_FAILED`). Forwarded from Git Bash, `host_path` fields are Windows
  paths.
- `cx-job`: `start`, `status` (with `queued`), `wait`, `result`, `kill` (rc 130 first, TERM to
  the runner's group and session and to every recorded executor session, KILL after 10 s,
  pid-reuse guards), `list`, `unpause agy`. Jobs run from the runtime copy in their own
  session and outlive the Git Bash forwarder.
- `cx-init --user-grants`: agy's `write_file(<worktree_root>)` and `command(<cmd>)` grants, the
  grok `cx-workspace` sandbox profile (`templates/grok-sandbox.toml`) and grok's
  `[cli] auto_update = false`, merged idempotently with `.cx-bak` backups.
- The skill's recipe, both policies and the Projects instructions route through `cx-run` and
  `cx-job`; the hand steps left are the conductor commit and gate (until `cx-gate`), GitHub and
  commit-message drafting, and their two executor calls run as `cx-wsl grok` and `cx-wsl
  ghcp-ci-debug` (in WSL as from Windows), so they take the pool slots too. The policy names
  the Opus order `agy (raw), then Copilot, then own subagents`; the Windows policy keeps `cx-wsl`
  to `gh`, `git`, `ghcp-cloud list`/`view`, `ghcp-ci-debug` and the hand steps.
- `cx-doctor` D25 is narrow: one rule per command form the skill runs (`Bash(cx-run:*)`,
  `Bash(cx-job:*)`, `Bash(cx-wsl grok:*)`, `Bash(cx-wsl ghcp-ci-debug:*)`, `Bash(ghcp-cloud
  list:*)`, `Bash(ghcp-cloud view:*)`, the `vars.sh` line, `git -C "$WT" push`, `gh pr`; on
  Windows the `cx-wsl` forms it runs directly), no raw `agy`, `agy-delegate`, `ghcp-delegate` or
  job rule, never `Bash(cx-wsl:*)`; the suite checks the rules against the skill both ways. New
  D29 (free): copilot, grok and agy start with the worker shims first on PATH. D32 prints the
  slot caps next to the workflow concurrency.
- Hardening of the run machinery (final review): a signal while the executor is being started
  still kills and records its session; the Copilot token reaches ghcp-delegate through the
  environment only, never a command line; only the adapter holds the pool slot and the agy
  locks (the executor gets no descriptor of them) and the executor's session is killed after
  every run, so a daemon it leaves behind never keeps a slot; a TERM-ignoring executor is killed
  10 s after a cancellation (`CX_KILL_GRACE_SECS`), every process group of its session too; the
  preflight cache is per caller side (a WSL terminal and a forwarded call never share a login
  verdict); agy's pause is checked again after the slot and launch-lock waits (also in `cx-wsl`);
  agy's tree check also covers HEAD, branches and tags no worktree has checked out, the stash,
  git config (without `branch.*`), `info/exclude`, the hooks and ignored files, so a commit or a
  planted hook outside the worktree is a `wrong_tree`; stale running marks (a failed task's, a
  killed `cx-run`'s) no longer hide a tree from it.
- `cx-run`: `--` ends the options (a task text may start with `-`), and `--background` and
  `cx-job start` always store the text after `--`; a taken id, a `cx/<id>` branch, a running
  task (`$OUT/.run.lock`, one `cx-run` per task) and, forwarded, an unmappable path (42) are
  refused by the `--dry-run` preflight before a job starts; a gate checkout is removed on every
  exit; the running mark stays only for an ok change waiting for Step 3; `--finish` refuses a
  finished task, books a run and its finish once each in the ledger, and fetches a cloud pull
  request from the task's repository (never a fork's `origin`) and gates it only when GitHub
  names that commit as its head. `cx-job result`/`wait` exit with the job's rc and a last
  `CX_SIGNAL` that names it (rc 1: the job's notes, no signal; a wall-clock kill: 12).
- The runtime copy: an unchanged reinstall refreshes the stamp (no re-copy on every call after
  an mtime-only change), and changed content is never swapped into `runtime/<version>` while a
  `cx-run` or a job still uses it (the update waits for the next call after they end). `cx-wsl
  grok -v` is a free form. Worktree creation's error file comes from `mktemp`.
- 19 more worker shims (the sibling wrappers and the `cx-*` bins) and `templates/cx-worker.json`.
- A task worktree is marked running from its creation (setup included), so a sibling task's
  own work never gives a concurrent agy run a false `wrong_tree`; a cancelled run reports
  `cancelled` even when several signals reach it (a late TERM no longer ends the adapter
  before its `rc` is written); the raw agy lane reads agy's init event in one read, so a run is
  never killed as a false model mismatch.
- Tests: the Phase 2 cases A1–A18, A25–A28 and A30 of DESIGN section 15.8, including twelve
  concurrent `cx-run --background` (direct and forwarded) against the shared caps, plus a
  regression check for each fix above; the forwarded `cx-run`/`cx-job` sections check their own
  python3 trap (P42).
- Not built (optional item 4 of the build order, because ultracode is normally off): the
  `conductor:cx-runner` agent, its fail-closed `hooks/gate.sh`, the `workflows/opus-pools.js`
  workflow and doctor check D33 (A19–A24, A29). Phase 3 (`cx-gate`, the conductor commit,
  `cx-fanout`, the integration queue), Phase 4 (`--mode ci`, review findings parsing) and the
  v1.1 Docker lanes are not built either.
- Still to capture: `agy --help` (the raw agy flags `--add-dir`, `--print-timeout`,
  `--output-format stream-json`, `--disable-slash-commands` and `--new-project` are docs-only;
  A1 checks them against the synthetic `tests/fixtures/agy-help.synthetic.txt`), agy's
  stream-json and `/usage` shapes, and grok's JSON result fields (DESIGN section 20).

## 0.1.0 — 2026-11-01

Phase 1: skeleton, host layer and hand-dispatched lanes (docs/DESIGN.md sections 2 to 14),
including support for Claude Code Projects (beta) Work locally threads and for ultracode.
Nothing in this release calls a model.

- Plugin manifest with 24 string options (`copilot_reserve_pct` and `agy_claude_floor_pct`
  default to `0`: no spend caps) and a self-marketplace `conductor-for-claude-code`.
- Shared libraries: `scripts/lib/common.sh` (version and pins, the exit-code table, `CX_*`
  emitters with a constant-only fallback for Git Bash), `scripts/lib/options.sh` (settings.json
  re-read, defaults, validation, and the pure-bash Git Bash readers, linear in the size of the
  settings file) and `scripts/lib/cxlib.py`.
- Host layer: `detect.sh`, the two-way `pathmap.sh`, the Git Bash to WSL forwarder
  (`forward-wsl.sh`, `wsl-entry.sh`) with NUL-separated argv, an env allowlist, cwd mapping,
  exit propagation and cancellation, and the runtime copy installer. On WSL only the drive
  directories of the automount root (`/mnt/c/`, or `/c/` with `[automount] root = /`) count as
  the Windows side, so Linux mounts such as `/mnt/data` resolve.
- `cx-doctor`: host, prerequisites, plugin files (CRLF), runtime copy, options, CLI versions
  against the pins, free login probes, sibling plugin overlap (with one-step
  `claude plugin install NAME --marketplace SOURCE` fixes), deny and allow rules (D25 states that
  `Bash(cx-wsl:*)` also allows any command in WSL), billing switches, `--pools`, `--login-help`,
  `--windows`, `--json`; writes the host record. A report forwarded from Windows says that its
  fixes run in a WSL terminal, and a repository on a Windows drive is an info line there.
- `cx-init`: the repo bundle (`AGENTS.md`, `.cx/routes.json`, `.github/copilot-instructions.md`)
  with per-ecosystem command detection; never touches `CLAUDE.md` or `.claude/`.
- `cx-wsl`: an allow-listed passthrough to one WSL-side tool (`ghcp-delegate`, `ghcp-job`,
  `ghcp-handoff`, `ghcp-ci-debug`, `ghcp-models`, `ghcp-cloud`, `agy-delegate`, `agy-job`,
  `agy`, `grok`, `gh`, `git`, `bash`) with the per-tool environment prefixes, so the Windows app
  can delegate before `cx-run` exists (never `agy-handoff` or `agy-media`, which always pass
  `--yolo`). `cx-wsl ghcp-*` signs in with `~/.conductor/secrets/copilot-token` (a 0600 file you
  own) when Copilot's keyring is unreachable through `wsl.exe`, for that call only.
- SessionStart policy hook (WSL/Linux, Git Bash, CRLF-notice and cloud-notice variants, a
  Workflows line and an unattended-run sentence), worker shims, the `conductor` skill and
  `/conductor:doctor`, `/conductor:init`, `/conductor:route`.
- The skill's Phase 1 recipe: worktree and contract, the agy, Copilot, Grok and Claude lanes,
  commit and clean-checkout gate, cross-family reviews, GitHub. Every agy step takes a
  machine-wide lock (`~/.conductor/locks/agy`; `AGY_BUSY`, exit 28, after 80 minutes), so agy
  runs one job at a time across sessions and threads; agy has no job form. The `trees` snapshot
  behind `WRONG_TREE` skips Claude Code's worktrees and every worktree another lane marked
  `running`, and its remedy never restores a tree the task did not create. `REPO` comes from
  `gh repo view` (SSH host aliases resolved). A CI fix with `ghcp-ci-debug --apply` is handed
  back to the task branch before the gate. The Copilot cloud agent (`ghcp-cloud`) has a recipe,
  and its pull request goes through the same gate. From Windows the Claude lane uses the
  worktree's `\\wsl.localhost` path for file tools and `cx-wsl bash -c` for commands.
- Session kinds (`local`, `bridge`, `cloud`, `byoc`) and the attended flag in `detect.sh`, decided
  before the host: in a cloud session the hook prints the cloud notice and every `cx-*` exits 43
  before probing anything; a BYOC or self-hosted runner (any kind but `bridge`) with
  `exec_host=local` runs as this machine, in the policy hook too; a Git Bash or WSL host is never
  a cloud session.
- Claude Code Projects (beta): every Project thread runs as a Work locally thread (a Remote
  Control child with this machine's plugins, `session bridge`, local behaviour);
  `templates/projects-instructions.md` for Project settings > Memory says so, sets the
  precedence, and carries the Phase 1 rule that agy runs one job at a time across threads.
- Ultracode and workflows: a SubagentStart hook (`hooks/subagent.sh`) gives workflow and
  general-purpose subagents the Phase 1 rule that only the main session runs executors (with
  the Windows path rule for conductor worktrees); a compacting subagent gets that guard again,
  never the main policy. The skill's hybrid fan-out runs executors from the main turn and the
  own-subagent pool as a static claude-pool workflow (with a Windows `wt_win` prompt).
- `cx-doctor` D30 (session; a desktop WSL session warning), D31 (Work locally readiness), D32
  (workflows and ultracode), and W10/W11 on the Windows side; the header, `CX_HOST`, `CX_DOCTOR`
  and `--json` carry the session.
- Hermetic test suite (`tests/run-tests.sh`) with stubs for every CLI, `uname`, `cygpath`,
  `wsl.exe`, `wslpath` and `nproc`; the skill's snapshot, lock, Step 3 and CI hand-back run in
  scratch repositories.
