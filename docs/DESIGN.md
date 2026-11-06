# conductor — Claude Code conducts Copilot, Grok Build and Antigravity (design spec, v0.2.2)

Claude Code is the conductor. This plugin routes each piece of work to the subscription best
suited to it: GitHub Copilot CLI (through the user's own `ghcp` plugin), Grok Build (the raw
`grok` 1.0.70 CLI) and Antigravity (the raw `agy` CLI for the Opus lane, the `antigravity`
plugin's wrappers for Gemini, media and research). It sends Opus 5.5 fan-out to the two included
Opus pools (Antigravity `claude-opus-5-5-high`, then Copilot `claude-opus-5.5` at
`--reasoning-effort high`, then Claude's own subagents) and keeps Claude the judge of quality:
Claude owns the spec, the gates and the merge. It never forks the sibling plugins.

This file is the build spec for all of v1 (Phases 1–4), v1.1 (Docker) and the v2 notes. Code
comments and test tags cite its § numbers. Phase 1 sections are fully specified; later phases
are specified enough to build against and say what Phase 0/1 evidence they still wait for.

## 0. Identity, sources and decisions

### 0.1 Identity

| Item | Value |
|---|---|
| Plugin name / version | `conductor` / `0.2.0` (Phase 1 shipped as 0.1.0) |
| Marketplace | `conductor-for-claude-code` (the repo is its own marketplace, like ghcp) |
| Plugin id | `conductor@conductor-for-claude-code` |
| Options key | `pluginConfigs["conductor@conductor-for-claude-code"].options` in `${CLAUDE_CONFIG_DIR:-~/.claude}/settings.json` |
| Author | `{"name": "40chalk", "url": "https://github.com/40chalk"}` |
| Repository / homepage | `https://github.com/40chalk/conductor-for-claude-code` |
| License | MIT (`LICENSE`, Copyright (c) 2026 40chalk) |
| Bins / commands / skill | `cx-*` / `/conductor:*` / `conductor` |
| Env prefix / stderr protocol prefix / branch prefix | `CX_` / `CX_<NAME> {json}` / `cx/` |

### 0.2 Status tags and sources

- **[verified]**: captured CLI help, a primary source, or a measurement recorded in the
  research. **[measured 2026-11-01]**: measured while writing this spec (Claude Code 2.1.316 in
  the build container). **[docs-only]**: vendor docs, changelogs or strings seen in research,
  never run. **[unverified]**: inferred, third-party or untested. **[assumption]**: a design
  choice that a later check may overturn. Anything tagged other than verified/measured must be
  coded defensively (accept several shapes, fail loudly) and is listed in §20.
- "plan §n" cites the research plan `00-final-plan.md` (2026-11-01; kept outside the repo).
  Everything this spec relies on is restated here, so the repo stands alone.
- "ghcp §n" cites `docs/DESIGN.md` of `40chalk/ghcp-for-claude-code`, whose conventions this
  plugin copies (its `CLAUDE.md` sections Architecture, Options, Invariants and Tests).

### 0.3 User decisions (2026-11-01; they override the plan)

| # | Decision | Consequence in this spec |
|---|---|---|
| U1 | Google AI Ultra is billed directly through Google One. | The agy Opus lane survives the 2026-11-02 third-party cutoff; it is first in `opus_lane_order` until the A/B (§6.7) says otherwise. |
| U2 | Autonomy: the conductor may spend Copilot credits and agy quota without asking, and may push branches, open PRs and request `@copilot` reviews by itself. | The policy (§10.3) says so. `cx-doctor` prints the Claude Code allow rules that remove the permission prompts (§8.3 D25); it never edits settings itself. Phase 3/4 push `cx/*` branches and open PRs without a confirmation step. |
| U3 | No spend caps. | `copilot_reserve_pct` defaults to `"0"` (off) and, for the same reason, `agy_claude_floor_pct` defaults to `"0"` (plan: 30 and 20). No per-call or per-session credit cap exists anywhere, and no text advises one (ghcp's stance). The concurrency caps `cap_*` are throughput limits, not spend caps, and stay. |
| U4 | No data restrictions. | Every pool is enabled for every repo: `.cx/routes.json` `pools` defaults to all `true`, `docker_only` to `false`. |
| U5 | Cursor is out of v1 (X Subscription: no included Opus). | No Cursor options, adapters or doctor checks. The worker shims still block `cursor-agent` and `agent` (§11). §19 keeps a v2 note. |
| U6 | Windows + WSL. Today Claude Code runs inside WSL; within days a Windows box runs the Claude desktop app (Bash tool = Git Bash) that also uses WSL. | WSL is the canonical executor host. From Git Bash every `cx-*` bin forwards into WSL through `wsl.exe` (§7.3). Docker (`/home/user/coding-agents-docker`) is v1.1 (§18). |
| U7 | Claude Code Projects (beta) threads always run locally, as **Work locally** threads (Remote Control children on the user's computer); executors may still use their own clouds from such a thread (the Copilot cloud agent through `ghcp-cloud`, Grok remote sessions), which is welcome. | Session kinds are decided before the host (§7.1): `bridge` (a Work locally thread) behaves as a local session; `cloud` and `byoc` are only a never-fail safety net (§10.6, §7.3 step 0a). The Projects instructions template says to run every thread locally (§9.6). Several local threads at once are the normal case, so the cross-process pool slots are the first Phase 2 item (§15.3, built): `cap_agy`, `cap_copilot` and `cap_grok` hold across threads and agy launches are serialized; they replaced Phase 1's machine-wide agy lock (one agy job at a time across threads); `cx-run` takes them for every executor run (§15.1). The Copilot cloud agent is `cx-run`'s `copilot-cloud` lane, its pull request gated by `cx-run --finish` (§12.2 step 5); Grok remote sessions are the user's to start (grok 1.0.70 can only resume one). A Git Bash or WSL host is never classified cloud (§7.1). |
| U8 | Ultracode is normally off; the conductor only has to behave correctly when it is on, and the Phase 2 runner agent is optional. | Phase 1 rule: workflow and Agent-tool subagents never run executors; the main turn dispatches executor lanes between workflows (§10.7, §12.1). The runner agent, its gate and the `opus-pools` workflow are optional Phase 2 items (§15.9–§15.11). |

Deviations from the plan that this spec makes on its own authority, each for a stated reason:
- The plan's `nudge` option is not declared: v1 has no UserPromptSubmit hook, and an option
  nothing reads is dead config. It returns with the hook in v2 (§19).
- `agy-handoff` is not used for conductor write lanes outside Docker: it always passes `--yolo`
  (`--dangerously-skip-permissions`, machine-wide; `agy-handoff.sh:143`), which §6.5 G10
  forbids. Phase 1 agy writes use `agy-delegate` plus a static grant (§12.2).
- For the same reason the plan's media and research lanes wait for the v1.1 Docker lane:
  `agy-media` always passes `--yolo` (`agy-media.sh:184`; its own warning says this approves
  every agy tool across the machine), and `/antigravity:research` runs `agy-delegate --yolo`
  (`commands/research.md:18`; headless web search has no narrower grant). Phase 1 names them
  only to forbid them (policy, skill), leaves `agy-media` out of `cx-wsl` and of D25's rules,
  and routes research to Claude's own WebSearch and grok. Lifting this needs the user's consent:
  U2 covers spending, not skipping permissions.
- Host records are per host key (`$CX_HOME/hosts/<hostkey>.json`), not one `hosts.json`,
  because v1.1 bind-mounts `~/.conductor` into the container and two hosts would overwrite one
  file (§7.6).
- `policy.sh` is the only CRLF-tolerant script (§10.2). Every other script requires LF; tests
  assert it, `policy.sh` detects a corrupted copy at session start and `cx-doctor` reports
  corruption outside its own execution path (§3.5).
- The plan's `cx-init` (plan §12.1) also writes the static agy and grok grants. Here that is
  Phase 2 `cx-init --user-grants` (§15.7): the grants are user-level files shared by every repo
  and every parallel run, while `cx-init` is a per-repo bootstrapper. Phase 1 relies on the
  one-time manual agy merge of §12.2 and grok's built-in `--sandbox workspace`.
- The plan's grok `--agent explore` for exploration and first-pass review is dropped: the
  sandbox plus `--always-approve` already fence those runs (since 0.2.2 the repository's
  strict-based profile; 0.2.1's built-in `read-only` let grok write `~/.grok`, §1.3), and a
  per-type model pin for `explore` in the user's grok config could override `-m`/`--effort`
  [assumption]. It returns only after a Phase 0 check shows `-m` and `--effort` still apply
  under it.
- The plan's `--caller` flag is the environment variable `CX_CALLER` instead: the caller is a
  property of the transport (set by `wsl-entry.sh`, §7.4, or by the Docker forwarder, §18), not
  something a user types, and one variable serves every `cx-*` command.
- Phase 1 adds `cx-wsl` (§7.7), a forwarded passthrough the plan does not have, so that the
  Windows app can delegate before `cx-run` lands (Phase 2).

### 0.4 Scope by phase

| Phase | Deliverable | § |
|---|---|---|
| 0 (outside the repo, already run or run by hand) | Free checks and tiny paid checks of plan §13.2–13.3; raw outputs sanitized (§14.2) and saved under `tests/fixtures/real/<cli>/` when they land | §20 |
| **1 Skeleton + host layer** | `plugin.json`, `marketplace.json`, `scripts/lib` (options, common, `cxlib.py`), `scripts/host` (detect, pathmap, forward-wsl, wsl-entry, install-runtime), `cx-doctor`, `cx-init` + `templates/repo-bundle/`, `cx-wsl` passthrough, session kinds and the cloud refusal (§7.1, §7.3 step 0a), SessionStart policy hook (WSL, Git Bash, CRLF and cloud variants) and SubagentStart guard (§10), the Projects instructions template (§9.6), worker shims, skill + 3 commands, tests + stubs, README, CLAUDE.md, CHANGELOG. In parallel (live, paid, by hand): the blinded Opus A/B (§6.7) and the Windows job-survival check (§14.4) | §2–§14 |
| 2 Adapters + run + jobs + ledger | `scripts/adapters/{copilot,grok,agy,claude}.sh`, `cx-run`, `cx-job`, normalizer, ledger, locks, wrapper worker shims, `cx-init --user-grants` | §15 |
| 3 Gates + fan-out + integration | `cx-gate` (incl. verdict parser), conductor commit step, `cx-fanout`, integration queue | §16 |
| 4 Live cross-environment + review + GitHub | Windows end to end, review lane, PR + `@copilot` review with ledger accounting, `ghcp-ci-debug` passthrough | §17 |
| v1.1 Docker | `forward-docker.sh`, `--host docker`, container clones, image/compose changes (in the docker repo) | §18 |
| v2 | Notes only | §19 |

## 1. Facts the design rests on

### 1.1 Claude Code 2.1.316

- `claude --version` prints `2.1.316 (Claude Code)` [measured 2026-11-01].
- `claude auth status --json` prints a JSON object with `"loggedIn": true|false` (plus
  `authMethod`, `apiProvider`), makes no model call and exits 0 [measured 2026-11-01: logged-in
  shape; the logged-out value `false` is an assumption]. `claude auth login` (default
  `--claudeai`) signs in [measured: help].
- `${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/installed_plugins.json` is
  `{"version": 2, "plugins": {"<id>": [{"scope", "installPath", "version", "installedAt",
  "lastUpdated", "gitCommitSha"?}]}}`. `settings.json` holds `enabledPlugins` (`{"<id>": bool}`),
  `extraKnownMarketplaces` and `pluginConfigs["<id>"].options` (string values)
  [measured 2026-11-01 by installing ghcp into a scratch `CLAUDE_CONFIG_DIR`]. The conductor reads
  these files directly; it never runs `claude plugin list` (no subprocess, stub-free in tests).
- `printf '%s' '{"k":"v"}' | claude plugin configure <id> --values-stdin` saves options into
  `pluginConfigs["<id>"].options` [measured 2026-11-01].
- Claude Code injects `CLAUDE_PLUGIN_OPTION_*` into hooks only, never into Bash-tool subshells;
  a hook that exits 0 has its stderr discarded; Claude Code puts a plugin's `bin/` on the Bash
  tool's PATH [verified, ghcp `CLAUDE.md`]. A `wsl.exe` child or `bash --noprofile --norc` does
  not inherit that PATH, so conductor scripts call sibling wrappers by absolute path (§7.6).
- The Bash tool kills a foreground call at its timeout (default 2 minutes, maximum 10) and
  every call starts a fresh shell: variables and functions do not persist between calls
  [measured 2026-11-01: Bash tool description]. Long work therefore runs as one background
  Bash call (`run_in_background`), which notifies on exit (§12.2). A background call is also
  stopped at its `timeout`, whose default is 1,800,000 ms (30 minutes) and maximum 7,200,000 ms
  (2 hours) [verified: the Bash tool description in the build harness and the 2.1.316 binary
  text]: shorter than a 30-minute executor run plus registration, the raw agy arm's 35-minute
  bound or `ghcp-handoff`'s delegation, tests and fix-up. Every background executor or wait call
  therefore passes `timeout: 7200000`, and each lane's own wall clock stays below it. ghcp forwards TERM to
  Copilot on a kill (billed tokens, exit 130); agy ignores TERM and is orphaned (antigravity
  `SKILL.md:319-325`).
- `claude -p` worker flags: `--model`, `--effort low|medium|high|xhigh|max`,
  `--output-format json|stream-json`, `--session-id`, `--settings <file>`, `--permission-mode`,
  `--json-schema` [verified, cli-help]. `--safe-mode` disables plugins, hooks and CLAUDE.md;
  whether it keeps OAuth is [unverified]. `--bare` needs an API key [verified].
- `claude plugin validate <dir>` checks manifests [measured: help].

### 1.2 GitHub Copilot CLI 1.0.105 and ghcp 0.1.0

- Last verified on 1.0.105; nothing is pinned (§5.4): the user's machine runs 1.0.106
  (auto-updated) and the Copilot lanes work there [user report, 2026-11-06]. (The 1.0.106-1
  prerelease lacked the `DYNAMIC_AUTO_TIERS` / `HYDRAFUSION_PLAN_V2` strings ghcp's Fusion path
  sets [strings verified; effect inferred]: a Fusion refusal falls back, `GHCP_FALLBACK`, 21.)
- Permissions [verified, `copilot help permissions` 1.0.105, `tests/fixtures/real/copilot/
  help-permissions.txt`]: `--allow-tool 'shell(<command>)'` matches a shell call by its command
  name ("in most cases an exact match against the command name"; git and gh by their first-level
  subcommand, `shell(git status)`; a `:*` suffix matches a stem). So `shell(python3 -m unittest
  discover -s tests)` never matches (the approval key is `python3`) and `shell(python3)` would
  allow `python3 -c`: the real run's tests were denied that way (`GHCP_DENIED` kind shell, 2
  calls). `write(<path>)`: an absolute path scopes one location, a relative one matches by
  trailing components. The conductor allows `shell(cx-route)` and `shell(git status)` only
  (§15.2): `git diff`, `git log` and `git show` take `--output=<path>` (a write of any file) and
  `git diff --no-index` reads any file, and a first-level-subcommand approval cannot forbid an
  option. Copilot cannot sign in from the build container (its GitHub proxy serves repository
  API paths only): Copilot lanes are verified with stubs, `--print-command` and the real
  fixtures; the live check runs on the user's machine.
  `copilot --version` output contains the version; the exact wording is [assumption] (ghcp's stub
  prints `GitHub Copilot CLI 1.0.105 (test stub).`), so parse the first semver.
- Free probes [verified, ghcp §1.1, §1.4]: `copilot -p . --model <invalid id> --no-ask-user
  --no-auto-update --no-color </dev/null` fails with rc 1 BEFORE any model call:
  `Error: Model "<id>" from --model flag is not available.` when logged in,
  `Error: No authentication information found.` when not, and `Read-only file system (os error
  30)` inside Claude Code's Bash sandbox. Only the `--model` flag is validated for free: an
  unknown `COPILOT_MODEL` value is silently ignored and bills the default model.
- `ghcp-models [--json] [--refresh]` [verified]: JSON `{"dynamic_auto_tiers": true|false|null,
  "models": [{"id", "name", "vendor", "policy", "price_category", "input_price", "output_price",
  "restricted_to"}]}`; exit 0 ok, 1 usage, 2 catalog absent, 11 not authenticated, 12 probe
  timeout, 13 copilot missing, 16 sandbox; 24 h cache in
  `${XDG_CACHE_HOME:-~/.cache}/ghcp-claude/models.json`. Without `--refresh` a fresh cache answers
  without probing, so only `--refresh` proves the account is still logged in. The probe runs in
  the caller's cwd, where Copilot may load repo-level config.
- The free invalid-model behaviour is measured on 1.0.105 only; another version could fall
  through to the billed default model, so the doctor's raw probe runs only on that version and
  otherwise D16 relies on ghcp-models' own probe (§8.3 D16; the adapters always use ghcp-models). ghcp-delegate passes `--disable-builtin-mcps` on every run [verified].
- `ghcp-job start` prints `JOB_ID <id>`; `ghcp-job status` prints exactly `running`,
  `done rc=0`, `failed rc=<n>` or `unknown`; `ghcp-job result` exits 75 while running, else the
  job's rc. There is no `wait` subcommand [verified, read 2026-11-01].
- `ghcp-delegate` [verified]: stdout = answer only; stderr `GHCP_SESSION <id>` (plain text),
  `GHCP_DENIED {…}`, `GHCP_NOTE {…}`, `GHCP_USAGE {…}` (`model`, `models_used[].model`,
  `ai_credits`, token counts, `fusion`), `GHCP_SIGNAL {…}`, `GHCP_FALLBACK {…}`; exits 0, 1, 2, 3,
  10–16, 130; read-only by default (`--write`, `--allow-shell <cmd>`, `--github`, …); an explicit
  `--model` gets no tier effort, so `--effort` must be passed; `--print-command` is free;
  `GHCP_COPILOT_BIN` picks the binary and an invalid value falls back to `copilot` on PATH (a paid
  run), so the conductor only ever passes an absolute path it has checked. `GHCP_USAGE_LOG`
  appends usage lines to a file. Fusion re-runs on plain `auto` (billed) after a refusal and
  prints `GHCP_FALLBACK`.
- Copilot cannot run inside Claude Code's Bash sandbox (it must write `~/.copilot`): exit 16.
- Economics [docs-only, plan §2.1]: Opus 5.5 costs 400/20/500/2000 AI credits per 1M tokens
  (input/cached/cache-write/output) from 20,000 credits a month (Max), resetting 00:00 UTC on the
  1st; 13–18k overhead tokens per call. #5149: Opus at xhigh/max can burn the 32k output budget
  on hidden reasoning and bill empty turns (~200 credits each). `COPILOT_MODEL`, a trusted repo's
  `.github/copilot/settings.json` and `GH_TOKEN` can silently change model or account.

### 1.3 Grok Build 1.0.70 (last verified; no pin)

From the captured `grok --help` (GH) unless tagged:
- `grok --version` prints `grok 1.0.70 (f50904eaee6c)` [verified, research].
- Unauthenticated `grok models` prints exactly [verified on 1.0.70 with an isolated GROK_HOME]:
  ```
  You are not authenticated.
  Default model: grok-4.6
  Available models:
  * grok-4.6 (default)
  - grok-4.5
  ```
  Its exit code and the logged-in listing shape are [unverified] (Phase 0 fixture).
- `grok login --device-auth` (alias `--device-code`): device-code login for headless/remote;
  `--oauth` forces the loopback browser flow. `grok update --version <V>` installs a version.
  `grok usage <SESSION_ID> [TURN]`, `grok inspect --json`, `grok models`, `grok worker …`
  (registers the machine as a Cursor private worker: never run).
- Headless flags: `-p/--single <PROMPT>`, `--prompt-file <PATH>`, `--output-format
  plain|json|streaming-json|streaming-messages-json`, `--json-schema`, `-s/--session-id <uuid>`
  (new conversations only), `--max-turns N`, `--cwd`, `--add-dir`, `--sandbox <PROFILE>` (env
  `GROK_SANDBOX`), `--permission-mode default|acceptEdits|auto|dontAsk|bypassPermissions|plan`,
  `--allow/--deny <RULE>`, `--always-approve`, `--no-subagents`, `-m/--model`,
  `--reasoning-effort` (alias `--effort`), `--agent <NAME>`, `--disable-web-search`,
  `-w/--worktree`, `--worktree-ref`.
- Hidden flags: `--yolo` parses on 1.0.70 [verified]; `--trust` and `--no-auto-update` were
  parse-verified only on 1.0.73.
- Sandbox [verified 2026-11-06 on 1.0.70 in the build container, `~/.grok/README.md` section
  Sandbox, `~/.grok/docs/user-guide/18-sandbox.md` and live probes]: the profile is applied to
  the whole grok process at startup (Landlock on Linux; irreversible), so every tool and child
  inherits it. Built-ins, as grok's docs describe them: `workspace` (read everywhere; write CWD,
  `~/.grok`, `/tmp`, `/var/tmp`; child network allowed), `devbox` (write every top-level
  directory but `/data`), `read-only` (read everywhere; write `~/.grok`, `/tmp`, `/var/tmp`; no
  child network), `strict` (read CWD, system paths and `~/.grok`; write CWD, `~/.grok/sessions`,
  `/tmp`, `/var/tmp`, and `~/.grok/daemon/run/strict` when grok's daemon backend runs the
  session; child network blocked). Under `workspace`, `read-only`, `strict` and the profiles
  extending them grok's docs ("Direct global write protection") say the kernel write-denies a
  protected set even where the profile grants write: `~/.grok/hooks/`, `~/.grok/hooks-paths` and
  its absolute targets, `config.toml`, `trusted_folders.toml`, `managed_config.toml`,
  `requirements.toml`, `sandbox.toml`, `bundled/` and `bundles/`; `devbox` and `off` do not.
- Measured write sets [verified 2026-11-06, grok 1.0.70, linux/landlock plus bubblewrap,
  enforced: grok's agent ran `tests/fixtures/real/grok/write-probe.sh` through its shell tool
  (an append-open that writes nothing per file, a dotfile created and removed per directory)
  under `--sandbox read-only` and under `--sandbox strict`; results verbatim in
  `write-probe-read-only-1.0.70.txt` and `write-probe-strict-1.0.70.txt`, tests/fixtures/README.md]:
  under the built-in `read-only` the protected set is DENIED (`config.toml`, `sandbox.toml`,
  `trusted_folders.toml`, `managed_config.toml`, `requirements.toml`, `hooks-paths`, `hooks/`,
  `bundled/`, `bundles/`) and the rest of `~/.grok` is WRITABLE: `auth.json`,
  `models_cache.json`, `settings_cache.json`, `worktrees.db`, `bin/grok-1.0.70` (grok's own
  binary: its installer puts grok in `~/.grok/bin`), `vendor/rg-15.0.0-override` (the ripgrep
  grok runs) and the directories `~/.grok` itself, `bin/`, `vendor/`, `installed-plugins/`,
  `logs/`, `sessions/` and `docs/`. Under `strict` every one of those is DENIED but `sessions/`.
  So a run under the built-in `read-only` cannot change `sandbox.toml` or `config.toml` (0.2.1's
  docs said it could), but it can replace grok's binary or ripgrep or plant a grok plugin: code
  that later runs outside any sandbox. Conductor 0.2.1 ran the read and review runs and the
  skill's Step 3 commit-message call under `read-only`, and all three read executor-written or
  repository content that could steer them there; since 0.2.2 no conductor grok run uses it
  (§12.2, §15.2 grok, §20 item 76). The profiles extending `strict` (the repository's profile,
  §15.7) log the same write grants as `strict` (next item); the probe script ran under the
  built-ins only. `~/.grok/sessions` holds every grok session's transcript (the prompt, the
  files read, tool output, the answer) for every repository, and every grok run can read and
  write it (§20 item 75).
- Custom profiles in `~/.grok/sandbox.toml` (or a project's `.grok/sandbox.toml`): `extends`,
  `restrict_network`, `read_only` and `read_write` (literal DIRECTORIES; a file path makes grok
  refuse to start), `deny` (literal paths, no globs: the 0.2.0 `cx-workspace` template's
  `**/.env` globs were invalid). A custom profile cannot reuse a built-in name: a
  `[profiles.strict]` in `sandbox.toml` (with a file in `read_only`) did not change `--sandbox
  strict`. When the user's file and a project's define the same custom profile differently,
  grok's docs say it uses the user's and warns [docs-only, §20 item 73]; project hooks are gated
  by folder trust [docs-only]. `~/.ssh`, `~/.aws`, `~/.gnupg` and `~/.grok/auth` are always
  write-protected [README]; `~/.grok/auth.json` is not (WRITABLE under `read-only`, above). A profile with deny lists needs bubblewrap on Linux (grok refuses to start:
  "Install bubblewrap with `apt install -y bubblewrap`"). A profile grok cannot apply makes it
  refuse to start (`warning: sandbox could not be applied: Expected a directory but got a file:
  /etc/hostname`, then `error: could not apply the 'cxtest' sandbox profile; see the warning
  above for the cause. Refusing to start with its protections missing.`, rc 1; free `grok
  --sandbox <p> models` probes, 2026-11-06). Where Landlock is missing (kernel < 5.13, or
  disabled) the README says grok "logs a warning and continues without enforcement" [docs-only,
  §20 item 72].
- Sandbox log [verified 2026-11-06 on 1.0.70, `tests/fixtures/real/grok/sandbox-events-1.0.70.jsonl`]:
  every sandboxed start appends one JSON line to `${GROK_HOME:-~/.grok}/sessions/sandbox-events.jsonl`:
  `{"timestamp", "event_type": "ProfileApplied", "profile", "workspace" (the cwd), "platform":
  "linux/landlock", "enforced": true, "restrict_network", "read_write_paths"}`, plus
  `read_only_paths` for `strict` and the profiles extending it (the write run's
  `cx-textutil-78d1f9c2`: `read_write_paths` the worktree, `~/.grok/sessions`, `/tmp`,
  `/var/tmp`; `read_only_paths` the system directories, the worktree, `~/.grok`, the git common
  directory and `$CX_HOME/routes`). The built-in `read-only` logs no `read_only_paths` (0.2.1's
  read run in its gate checkout: `read_write_paths` `~/.grok`, `/tmp`, `/var/tmp`). Neither
  shape lists the protected set: the log shows the grants, not grok's write-deny. The preflight
  and D17 read only the bytes their `grok --sandbox strict models` appended, for its cwd:
  `enforced` false refuses the lane (§15.2); an absent log or event changes nothing. Since 0.2.2
  every grok run also checks its own profile the same way, in its checkout, before its slot and
  its prompt (§15.2 grok): `enforced` false, or a `read_write_paths` entry that grants write to
  grok's home (the home itself, a directory above it or one inside it, but `~/.grok/sessions`),
  refuses the run. The sizes come from GNU `stat -c %s` (Linux, WSL), and D17 reads the log only
  when python3 runs: elsewhere (macOS, untested) the log is not read and nothing changes. What
  an unenforced start logs is unseen (§20 item 72).
- Result JSON (`--output-format json`) [verified on 1.0.70: the real runs sbx-grok-1, -2, -3]: one
  object with `text`, `stopReason`, `sessionId`, `requestId`, `cwd`, `thought`, `usage`
  {`input_tokens`, `cache_read_input_tokens`, `cache_creation_input_tokens`, `output_tokens`,
  `reasoning_tokens`, `total_tokens`}, `num_turns`, `total_cost_usd`, `total_cost_usd_ticks`,
  `modelUsage` {`<served>`: {`inputTokens`, `outputTokens`, `cacheReadInputTokens`,
  `cacheCreationInputTokens`, `modelCalls`, `costUSD`}} and, with `--json-schema`,
  `structuredOutput` (the validated answer). `text` joins every turn's assistant message with no
  separator (a write digest begins "I'll start by reading `.conductor/task.md` …The task is …";
  a read gave `[ ][{…}]`, a first turn's `[ ]` before the array), so turn boundaries cannot be
  recovered from it: the digest is kept as it is, and with `--json-schema` the answer is
  `structuredOutput` (§15.2; without one, `text` stays the answer, with a note saying so).
- `--sandbox strict --always-approve` in a worktree under `$HOME`: edits in the worktree and
  `python3 -m unittest discover -s tests` work; a write or read outside is denied; `git status`
  fails (`~/.gitconfig` and the worktree's git common directory in the main repository are
  unreadable). Adding `read_only = ["<git common dir>"]` to a profile that extends `strict`, with
  `GIT_CONFIG_GLOBAL=/dev/null`, makes `git status --short` and `git log --oneline -1` work.
- `--permission-mode acceptEdits` does not approve an edit headless ("permission required: Edit
  … was not run, as a headless run cannot ask for approval": the real run sbx-grok-1).
- Served model names: `-m grok-4.6` serves `grok-4.6-build`, `-m grok-4.7` serves
  `grok-4.7-build` (modelUsage keys; real runs). `grok models` lists `grok-4.7` (default),
  `grok-4.7-build-fast`, `grok-4.6`, `grok-4.5`. Python tests leave `__pycache__` in the
  worktree unless `PYTHONDONTWRITEBYTECODE=1`.
- A denied tool exits 0 with `permission required:` on stderr [verified: the real run
  sbx-grok-1]; sandbox profiles live in `~/.grok/sandbox.toml`, with built-ins `read-only`,
  `workspace` and `strict` [verified: the 2026-11-06 probes, above].
- [docs-only]: `GROK_DISABLE_AUTOUPDATER=1` and `[cli] auto_update = false` in
  `~/.grok/config.toml`; `GROK_CLAUDE_{HOOKS,SKILLS,MCPS,RULES,AGENTS}_ENABLED=false` stop grok
  importing `~/.claude`; allow-rule syntax `Bash(<cmd>)`; an `-m` id missing from the catalog
  silently drops `--effort`; `-p` waits up to 10 minutes for background subagents and can exit 1
  with an error object that has no `sessionId`; folder trust gates project config (worktrees are
  untrusted).

### 1.4 Antigravity: agy 1.4.12 / 1.5.1 and the antigravity plugin 0.30.2

- `agy --version` prints the version on its first line [docs-only; the plugin's doctor parses
  it that way]. `agy models` prints `<slug>\t<Label>` lines, sometimes after
  `Fetching available models...`; `--output-format json` exists since 1.1.12 with a shape that
  is [unverified]. Opus slugs `claude-opus-5-5-{low,medium,high}` (labels `Claude Opus 5.5
  (High)` etc.); nothing above `high` [docs-only]. The catalog differs per account.
- Zero-quota probes: `agy -p /model`, `-p /usage`, `-p /config`, each with
  `--output-format json </dev/null` [verified 2026-11-06: `/model` and `/usage` report
  `num_turns` 0 and 0 tokens; §20 item 68].
- Permissions in print mode [verified 2026-11-06 on 1.5.1, cheap live probes]: the default
  `permission_mode` is `request-review`; headless it cannot prompt, so ONE denied tool call ends
  the run (result `SUCCESS`, response `""`, `denied_actions [{action, display_name}]`, rc 0).
  `--settings '<JSON or file>'` applies `{"permissions": {"allow": [...]}}` to that session only
  (never saved). `command(<rule>)` matches each simple command of a compound line (`git status
  --short; cat x` ran with `command(git status)` and `command(cat)` allowed; `cat x; ls -la` was
  denied without `ls`), a multi-word rule as a token prefix (`command(python3 -m unittest discover
  -s tests)` allows the same command with `-v`, not `python3 -c`). `write_file(<dir>)` grants
  writes beneath `<dir>`; writes under `/tmp` need no grant; a write elsewhere under `$HOME` is
  denied. Reading inside the workspace with agy's own tools (read/view file, list dir, find,
  grep) needs no grant. agy 1.5.1's help is 1.4.12's plus `--remote-agent` and `acp`
  (`tests/fixtures/real/agy/help-1.5.1.txt`).
- stream-json [verified: the real run `tests/fixtures/real/agy/sbx-agy-1/agy.out`, 1.4.12]:
  `{"event": "init", "conversation_id", "init": {"model", "cwd", "tools", "permission_mode"}}`,
  `{"event": "step_update", "step_update": {"step_index", "state", "step_type": "user_input" |
  "agent_response" | "tool", "tool_name", "tool_info": {"name", "parameters": {"CommandLine" |
  "Path" …}, "output"}, "usage"}}` and `{"event": "result", "result": {"status", "response",
  "duration_seconds", "num_turns", "usage", "denied_actions"}}`; a denied `run_command` step
  still reads `DONE`. stderr then says "auto-denied … Add an allow-rule under
  permissions.allow … or re-run with --dangerously-skip-permissions" (the conductor never does
  the latter).
- In a directory agy has never seen it works in its LAST project root unless the directory is
  registered first with `agy --new-project -p /model` [verified by the plugin's measurement,
  `SKILL.md:319-320`, `agy-handoff.sh:209-210`].
- Hazards [docs-only issues]: #1313 print mode never exits after the result (only SIGKILL
  works; ~19k-character prompts trigger it); #318 hangs without a TTY; an expired
  `--print-timeout` returns PARTIAL output with rc 0; `--dangerously-skip-permissions` covers the
  whole machine; subagents cannot be pinned to Opus; print mode ignores `AGENTS.md` unless
  `--project` is passed. `--add-dir`, `--disable-slash-commands`, `--print-timeout` and
  `--output-format stream-json` are [docs-only] until `agy --help` is captured.
- The plugin [verified, read 2026-11-01]: `agy-delegate` (`-m/--model <exact name>`,
  `-d/--dir <path>` repeatable, `--timeout <dur>` (default option `timeout`, 5m), `--digest`,
  `--yolo` → `--dangerously-skip-permissions`, `--print-command`; exits 0, 1, 2, 3, 10–15;
  `AGY_USAGE` / `AGY_SIGNAL` stderr lines; finds `agy` with `command -v agy`); `agy-handoff`
  (always `--yolo`); `agy-job start|list|status|result|cancel` (no `wait`; `start` prints the
  bare id; `status` prints a `job:` line, the job's `meta` lines indented (including its task
  text) and `  state=running|done|failed`; `result` exits 2 while running and 0 whatever the
  finished job's rc: read `<jobdir>/rc`); `agy-media <file> [focus]`. The `model` field of
  `AGY_USAGE` is the REQUESTED model echoed back (`agy-delegate.sh:552`:
  `"model": os.environ.get("AGY_MODEL", "")`, set from its own `--model`), not what agy served:
  wrapper runs carry no served-model evidence at all (§6.5 G6). Write grants live in
  `~/.gemini/antigravity-cli/settings.json` `permissions.allow` (`write_file(<dir>)` is
  recursive, `command(<cmd>)`). Options: `default_tier`, `timeout` (5m), `coding_policy` (on),
  `default_model`, `tier_flash`, `tier_flash_lo`, `tier_pro`, `structured_output`,
  `digest_warn_chars`, `delegation_nudge` (on), `usage_log`.

### 1.5 Windows, WSL and Git Bash

- `wsl.exe -d <distro>` selects the distro; `--cd <dir>` sets the working directory (`~` = the
  Linux home, `/…` = a Linux path, otherwise an absolute Windows path); `--exec <prog> [args]`
  runs a program without the default shell; `--` hands the rest to the default shell, which
  re-parses it (the conductor never uses it); `-l -v` lists NAME / STATE / VERSION
  [docs-only].
- wsl.exe's OWN messages are UTF-16LE unless `WSL_UTF8=1` is set [docs-only]; the Linux
  program's stdout/stderr pass through as raw bytes; wsl.exe exits with the Linux program's
  status [docs-only].
- `WSLENV=NAME1:NAME2` passes the listed Windows-side variables into WSL (no flag = value
  verbatim; `/p` would translate paths) [docs-only]. The conductor passes one variable, verbatim,
  and maps paths itself.
- MSYS2 rewrites POSIX-looking arguments passed to native executables unless
  `MSYS_NO_PATHCONV=1` (Git for Windows) and `MSYS2_ARG_CONV_EXCL='*'` are set [docs-only].
- `cygpath -w|-u|-m` converts paths in Git Bash; `-l` (with `-w`/`-m`) prints the long form
  [docs-only]. Git Bash shows drive paths as `/c/…`; its `/tmp` is normally
  `%LOCALAPPDATA%\Temp` [assumption], which often contains 8.3 short names
  (`C:\Users\JOHNSM~1\…`) for long or spaced user names; DrvFs resolution of such a component in
  WSL is not guaranteed, so the forwarder always emits long forms (§7.3).
- `wsl.exe -l -q` lists distro names only; in `-l -v` the default distro's row starts with `*`,
  VERSION is the last field and STATE is localized and may be several words [docs-only]. Without
  `-d`, wsl.exe uses the default distro, whose name the Linux side sees as `WSL_DISTRO_NAME`.
- WSL mounts drives at `/mnt/<letter>` unless `/etc/wsl.conf` `[automount] root = …` says
  otherwise; Windows sees the distro at `\\wsl.localhost\<Distro>\…` (and legacy `\\wsl$\…`);
  `wslpath -u|-w` converts inside WSL [docs-only]. Git for Windows refuses `\\wsl.localhost\…`
  repos as "dubious ownership" until `safe.directory` lists them [docs-only].
- Git for Windows ships bash 5, coreutils (incl. GNU `timeout` in `/usr/bin`), sed, awk, grep,
  tar, iconv and cygpath but no python3 [assumption]; a `python3.exe` App Execution Alias may
  exist, exit 9009 and only open the Microsoft Store, and a real Windows Python prints CRLF. A
  PATH with `C:\Windows\System32` first resolves `timeout` to the unrelated `timeout.exe`.
  Therefore every Git Bash code path is pure bash plus the tools of §3.1, and never python.
- The desktop app's WSL sessions (the WSL environment, or a `\\wsl.localhost\…` folder chosen
  in the folder picker, which "reopens inside that distribution") run Claude Code inside WSL,
  and "plugins aren't available in WSL sessions" [docs-only, `desktop-wsl.md`; §20 item 45].
  A live run contradicts that for this user's setup: on 2026-11-01 a session in WSL that
  carried the desktop app's signals loaded the conductor and ran `/conductor:doctor` (§20
  item 66). So D30 no longer assumes the docs: it checks whether this session's PATH holds the
  plugin's own `bin/` (Claude Code adds a plugin's `bin/` only for a loaded plugin) and reports
  ✓ when it does, ! only when it does not inside a Claude Code Bash call. Conductor work on a repo that lives in WSL therefore runs in a
  desktop session on a Windows folder (it forwards into WSL), in a WSL terminal, or behind
  `claude remote-control` in WSL (§20 item 40); W3, D30 and `wsl-entry.sh`'s cwd note never send
  the user to a picker-opened WSL session.
- Unverified (§20): whether the desktop app opens `\\wsl.localhost` projects and what `$PWD`
  then looks like; which shell runs hook commands on Windows; whether WSL's idle shutdown kills
  detached jobs after the last `wsl.exe` exits; whether wsl.exe relays stdin and Ctrl-C.

### 1.6 Sibling plugins

| Plugin id | Facts that matter | Conductor response |
|---|---|---|
| `ghcp@ghcp-for-claude-code` 0.1.0 (user's own) | SessionStart policy (`coding_policy`, on) and UserPromptSubmit nudge (`delegation_nudge`, on); PreToolUse(Bash) gate fails closed on malformed payloads; options read from user settings only | Recommend both options off (§8.3 D21); call its bins by absolute path; parse its `GHCP_*` lines |
| `antigravity@antigravity-for-claude-code` 0.30.2 | Same two options (on); policy on startup and compact; `antigravity-delegate` agent has no working gate; `timeout` default 5m returns PARTIAL (exit 12) | Recommend both options off and `timeout` 30m (§8.3 D22); deny the agent (D24) |
| `grok-build@xai-grok-build` 0.2.1 | SessionStart/SessionEnd hooks (node, no matcher); SessionEnd also fires on `/clear` and kills and erases session-tagged bridge jobs in the hook's cwd workspace; `grok-build:grok-delegate` (Sonnet, writes by default, ungated); bridge caps effort at low/medium/high, writes unsandboxed with `--always-approve`, fails on prompts over 128 KiB, calls the missing `grok import` | Never used by the conductor; doctor warns (D23) and recommends denying the agent (D24) |

### 1.7 Projects, cloud sessions, hooks and workflows (Claude Code 2.1.316)

Tags as in §0.2; "[docs-only, binary]" marks a string read from the 2.1.316 executable with
`grep -a`, never run.

- **Code-tab Projects (public beta).** A project is one coordinator conversation that starts
  threads; each thread is a full Claude Code session, in the cloud by default or on the user's
  computer as a **Work locally** thread: a Remote Control child in a folder on that machine,
  which uses the machine's settings, hooks, permission rules and plugins, runs in auto mode and
  gets the Projects instructions (Project settings > Memory, up to 16,000 characters) but not
  project memory [docs-only]. It needs Claude Code ≥ 2.1.280, the desktop app's "Use this
  computer from your phone and claude.ai" with the folder added (or `claude remote-control`
  running in the folder), a claude.ai login (not an API key, `ANTHROPIC_BASE_URL` gateway,
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` or `DISABLE_GROWTHBOOK`), and "Require trusted
  devices" off [docs-only]. The user runs every thread locally (U7). Cloud threads load only the
  repo's root `CLAUDE.md`, `.claude/CLAUDE.md`, `.claude/rules/`, the Projects instructions,
  project memory, account skills and plugins added in Project settings; claude.ai refuses a
  plugin with a top-level `bin/` [docs-only], so the conductor never runs there.
- **Session signals** (inherited by hooks and the Bash tool): `CLAUDE_CODE_REMOTE` truthy and no
  `CLAUDE_CODE_ENVIRONMENT_KIND` = Anthropic cloud [docs-only, binary; measured `true` in the
  build container, a desktop cloud session with `CLAUDE_CODE_ENTRYPOINT=remote_desktop`];
  kind `byoc` = a BYOC or self-hosted runner; kind `bridge` = a Remote Control child, always on
  the user's computer [docs-only, binary]; because that tag is unverified, a Git Bash or WSL host
  is never classified cloud whatever the variables say (§7.1). `CLAUDE_CODE_SESSION_ATTENDED` is `0` in headless,
  scheduled and background sessions [docs-only, binary]. The entrypoint is never used for routing
  (a bridge child inherits it), `CLAUDE_CODE_VERSION` is wrong (measured 2.1.42 against a 2.1.316
  binary) and `CLAUDE_PROJECT_DIR` is unset for the Bash tool (measured).
- **Hooks.** `claude plugin validate` checks a plugin's `hooks/hooks.json`: it accepts
  `SubagentStart` and `"onFailure": "continue"` and reports any other `onFailure` value as an
  invalid command hook [measured 2026-11-01]. SubagentStart fires for every workflow `agent()`
  and Agent-tool subagent with `agent_type` set (`workflow-subagent` by default,
  `general-purpose`, or a plugin's `<plugin>:<name>`), and its `additionalContext` is injected
  into that agent [docs-only, binary; §20 item 49]. SessionStart `compact` also fires when a
  subagent compacts, with that agent's context (`agent_id`, `agent_type`) [docs-only, binary;
  §20 item 60].
- **Workflows and ultracode.** Ultracode is a session setting (the `ultracode` settings key,
  `--effort ultracode`, `/effort ultracode`, or the word typed in a prompt; not from `-p`); no
  environment variable exposes it and a plugin's settings honour only `agent` and
  `subagentStatusLine`, so the conductor can neither detect nor force it [docs-only, binary].
  Its reminders ("use the Workflow tool on every substantive task") reach only the main loop.
  Every workflow `agent()` is an in-process Claude subagent with the parent's plugins, hooks,
  CLAUDE.md and skills; nothing replaces it with an external CLI. Workflows are off with
  `CLAUDE_CODE_DISABLE_WORKFLOWS`, `CLAUDE_CODE_WORKFLOWS=false`, `disableWorkflows: true` or
  `enableWorkflows: false`, and by default on Pro. Concurrency per workflow is
  min(16, max(2, CPUs − 2)) unless `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS` (1–256) sets it;
  `isolation: 'remote'` throws in workflows and `isolation: 'worktree'` fences an agent inside
  `<repo>/.claude/worktrees/`; `budget` counts Claude output tokens only. In auto mode a
  workflow agent's prompt gets no user-intent credit [docs-only]. Five statements of the earlier
  design note are corrected here: the concurrency floor of 2, `isolation: 'remote'` throwing,
  repo `enabledPlugins` not reaching the cloud, SubagentStart firing for workflow agents, and
  `--effort` in `--help` listing only low–max (ultracode is a hidden alias).
- **Tool serving** (`_host`, attached computer folders) is refused from Windows and from WSL
  [docs-only, binary; §20 item 57]; v1 never routes through it.

## 2. Architecture and component inventory

### 2.1 Topology

```
Claude Code in WSL (today) ─── bin/cx-* ──► scripts/*.sh (runs locally; WSL = executor host)

Claude desktop app on Windows (Bash tool = Git Bash)
  bin/cx-* ──► scripts/*.sh ──► scripts/host/forward-wsl.sh  (pure bash)
                                   │ wsl.exe [-d <distro>] --cd ~ --exec /bin/bash --noprofile --norc
                                   ▼   .conductor/runtime/<version>/scripts/host/wsl-entry.sh
                     WSL: wsl-entry.sh ──► ~/.conductor/runtime/<version>/scripts/<cmd>.sh

Executor host (WSL): copilot, grok, agy, gh, claude, ghcp-* / agy-* wrappers (absolute paths)
v1.1: WSL ──► docker compose exec -T agents … (scripts/host/forward-docker.sh, §18)
```

- WSL holds every CLI, every login and every git operation the conductor performs. Git Bash
  never runs an executor and never runs git on a repo (except `cx-doctor --windows`' read-only
  `safe.directory` probe, §8.6). In Phase 1 the Windows app reaches WSL-side tools only through
  `cx-wsl` (§7.7), which uses the same forwarder.
- The SessionStart hook runs wherever Claude Code runs (WSL or Git Bash) and is pure bash. It
  picks the WSL, Git Bash or CRLF policy variant (§10.2).

### 2.2 Files

All paths are relative to the plugin root. "Host" says where the file runs: W = executor host
(WSL/Linux, python3 available), G = Git Bash side (pure bash), B = both.

| Path | Phase | Host | Role | § |
|---|---|---|---|---|
| `.claude-plugin/plugin.json` | 1 | — | Manifest + `userConfig` (all `type: "string"`) | §5 |
| `.claude-plugin/marketplace.json` | 1 | — | Self-marketplace | §13 |
| `.gitattributes` | exists (Phase 1 appends two lines) | — | `* text=auto eol=lf`; `*.sh`, `bin/*`, `hooks/*`, `worker-shims/*` `text eol=lf`; `*.ps1` `eol=crlf`; then, last so they win, `tests/fixtures/** -text` and `*.utf16le binary` (fixtures keep their bytes, intentional CRLF included) | §3.5 |
| `bin/cx-doctor`, `bin/cx-init`, `bin/cx-wsl` | 1 | B | 3-line shims → `scripts/cx-<name>.sh` | §3.6 |
| `bin/cx-run`, `bin/cx-job` | 2 (built) | B | shims | §15 |
| `bin/cx-gate`, `bin/cx-fanout` | 3 | B | shims | §16 |
| `scripts/cx-doctor.sh` | 1 | B | Health check, pools, login help, Windows checks | §8 |
| `scripts/cx-init.sh` | 1 | W | Repo bundle writer | §9 |
| `scripts/cx-wsl.sh` | 1 | B | Allow-listed passthrough to one WSL-side tool (forwards from Git Bash) | §7.7 |
| `scripts/lib/common.sh` | 1 | B | Pure-bash helpers: version, pins, exit table, notes, `cx_signal`, `cx_emit`, forwarding hook, timeouts, WSL output decoding | §4.4 |
| `scripts/lib/options.sh` | 1 | B | Options loader, defaults table, Git Bash lite reader | §5.2 |
| `scripts/lib/cxlib.py` | 1 | W | stdlib-only helpers (subcommands in §4.4, §8, §9) | §4.4 |
| `scripts/host/detect.sh` | 1 | B | Host detection | §7.1 |
| `scripts/host/pathmap.sh` | 1 | B | Two-way path mapping | §7.2 |
| `scripts/host/forward-wsl.sh` | 1 | G | Git Bash → WSL forwarder | §7.3 |
| `scripts/host/wsl-entry.sh` | 1 | W | WSL side of the forwarder | §7.4 |
| `scripts/host/install-runtime.sh` | 1 | W | Runtime copy into `~/.conductor/runtime/<version>` | §7.5 |
| `scripts/host/forward-docker.sh` | v1.1 | W | WSL → container | §18 |
| `scripts/adapters/{copilot,grok,agy,claude,copilot-cloud}.sh`, `scripts/lib/adapter.sh` | 2 (built) | W | probe / argv / run / parse; the shared machinery (sourced) | §15.2 |
| `scripts/cx-run.sh`, `scripts/cx-job.sh` | 2 (built) | B (forward from Git Bash) / W | One task; background jobs | §15 |
| `scripts/lib/{normalize.py,ledger.py,worktree.sh,taskfile.sh,locks.sh}` | 2 (built) | W | Result normalizer, ledger, worktrees, task rendering, pool locks | §15 |
| `scripts/cx-gate.sh`, `scripts/lib/verdict.py` | 3 | W | Gate + test-verdict parser | §16 |
| `scripts/cx-fanout.sh` | 3 | W | N tasks, failover, integration queue | §16 |
| `hooks/hooks.json`, `hooks/policy.sh`, `hooks/policy-context.json`, `hooks/policy-context-gitbash.json`, `hooks/policy-context-crlf.json`, `hooks/policy-context-cloud.json` | 1 | B | SessionStart policy (WSL/Linux, Git Bash, CRLF-corruption and cloud variants) | §10 |
| `hooks/subagent.sh`, `hooks/subagent-context.json`, `hooks/subagent-context-compact.json` | 1 | B | SubagentStart guard (and its compaction copy): subagents never run executors | §10.7 |
| `agents/cx-runner.md`, `hooks/gate.sh`, `workflows/opus-pools.js` | 2 (optional) | — | Workflow stage runner, its fail-closed PreToolUse gate, the shipped Opus fan-out workflow | §15.9–§15.11 |
| `worker-shims/{claude,copilot,grok,agy,codex,gemini,cursor-agent,agent}` | 1 | W | Block agent CLIs inside workers | §11 |
| `worker-shims/{ghcp-*,agy-*,cx-*}` | 2 (built) | W | Block sibling wrappers and conductor bins inside workers | §11, §15.6 |
| `templates/repo-bundle/{AGENTS.md,routes.json,copilot-instructions.md}` | 1 | W | Bundle templates | §9.5 |
| `templates/projects-instructions.md` | 1 | — | Text the user pastes into Project settings > Memory | §9.6 |
| `templates/task.md`, `templates/cx-worker.json`, `templates/grok-sandbox.toml` | 2 (built) | W | Task contract, Claude worker settings, grok profile | §6.4, §15 |
| `skills/conductor/SKILL.md` | 1 | — | Routing, effort, commands, guardrails, hazards | §12.1 |
| `commands/{doctor,init,route}.md` | 1 | — | `/conductor:doctor`, `:init`, `:route` | §12.3 |
| `commands/{run,fanout,review,jobs}.md` | 2–4 | — | Later commands | §15–§17 |
| `tests/run-tests.sh`, `tests/stubs/*`, `tests/fixtures/*` | 1 | W | Hermetic suite | §14 |
| `tests/live/*.sh` | 4 | W | Opt-in, billed live checks (never run by the suite) | §17.5 |
| `docs/DESIGN.md`, `README.md`, `CLAUDE.md`, `CHANGELOG.md`, `LICENSE` | 1 | — | Docs | §13 |

### 2.3 State on the executor host

`CX_HOME` (environment only, default `$HOME/.conductor`; not an option):

```
$CX_HOME/
  hosts/<hostkey>.json, hosts/<hostkey>.path   host record (cx-doctor, §7.6)
  pools.json                                   user-entered Copilot month-to-date credits (§8.4)
  probe/                                       empty scratch cwd for every doctor CLI probe (§8.3)
  runtime/<version>/, runtime/current -> <version>, runtime/.install.lock   runtime copy (§7.5)
  secrets/copilot-token                        optional fine-grained PAT, mode 0600, user-created (§8.5)
  ledger.jsonl (+ ledger.jsonl.lock)           default of option ledger_path (Phase 2)
  raw-usage.log                                GHCP_USAGE_LOG / AGY_USAGE_LOG target (Phase 2)
  ab/2026-11/                                  raw A/B records; never committed (§6.7)
  out/<id>/                                    vars.sh, task.md, prompt.txt, task.sha, raw outputs (Phase 1, §12.2); result.json (Phase 2)
  jobs/<id>/                                   cx-job registry (Phase 2)
  locks/<pool>.<n>, locks/agy-launch           pool slots and the agy launch lock (Phase 2)
  state/agy-paused                             set by a wrong_tree result (Phase 2)
  gate/<id>.<n>/                               clean gate checkouts (Phase 3)
```

Worktrees live under option `worktree_root` (default `~/.cx-wt`) as `<repo>-<id>`, on branch
`cx/<id>`. The root is one absolute path outside every repo, so one static agy write grant
covers every worktree and no main checkout (plan §12.1).

## 3. Engineering conventions

### 3.1 Languages and dependencies

- Runtime: bash ≥ 4.4 and stdlib-only Python ≥ 3.8 on the executor host. No jq, no node, no
  pip packages. `timeout`, `setsid`, `flock`, `sha256sum` (coreutils/util-linux) and `git` are
  required on the executor host (checked by D2).
- Git Bash code paths (shims, `common.sh`, `options.sh`'s lite reader, `detect.sh`,
  `pathmap.sh`, `forward-wsl.sh`, `cx-wsl.sh`'s forwarding, `cx-doctor.sh`'s Windows part,
  `policy.sh`) are pure bash plus exactly these external tools, an authoritative list: `awk`,
  `cat`, `cp`, `cut`, `cygpath`, `dirname`, `env`, `grep`, `head`, `iconv` (optional), `kill`,
  `mkdir`, `mktemp`, `od`, `rm`, `sed`, `sleep`, `tee`, `timeout` (GNU coreutils from
  `/usr/bin`, checked by W1), `tr`, `uname`, `wc`, plus the Windows executables `wsl.exe` and,
  for W5 only, Git for Windows' `git`. A Git Bash path that needs another tool adds it here and to
  P42's mini bin in the same commit. They never call python3: `common.sh`'s `cx_py_ok` is false
  whenever `uname -s` matches `MINGW*|MSYS*|CYGWIN*`, whatever PATH holds (the Store alias exits
  9009; a real Windows Python prints CRLF into `CX_*` lines and option values), and
  `cx_signal`, `cx_emit`, `cx_load_options` and `detect.sh --json` consult it. Tests enforce this
  with a python3 trap on the simulated Git Bash PATH (§14.3 P42).
- Python always runs as `python3 -I` (a test plants `json.py` in the cwd). Python lives in
  `scripts/lib/*.py` or in quoted `python3 -I - <<'PY'` heredocs (only in `options.sh`), never
  in `python3 -c` strings.

### 3.2 Bash rules

`#!/usr/bin/env bash`; `set -uo pipefail` without `-e` (check every rc explicitly); `unset
CDPATH` in scripts that `cd`; empty-array-safe `"${a[@]+"${a[@]}"}"`; quote everything;
shellcheck-clean at the default severity. Each script's header comment (from line 2 to the first
non-comment line) is its `--help`, printed with
`awk 'NR <= 2 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"`. Every user-facing
script (`bin/*`, `scripts/*.sh`, `scripts/host/{detect,pathmap,forward-wsl,install-runtime}.sh`)
accepts `-h|--help` and `--version` (prints `<prog> <CX_VERSION>`) before any other work. Not
user-facing, so exempt from that rule (they keep the shebang and the header comment):
`worker-shims/*` (fixed output for any argv, §11), `hooks/policy.sh` (prints the policy whatever
its argv, §10.2) and `scripts/host/wsl-entry.sh` (no argv contract, §7.4).

### 3.3 Python rules

stdlib only; `#!/usr/bin/env python3` but always invoked as `python3 -I <file>`; argparse
subcommands; never crash on malformed input (count and skip); read files as UTF-8 with
`errors="replace"`, and every `settings.json` and `installed_plugins.json` (either side) with
`encoding="utf-8-sig"` (a Windows-edited file may start with a BOM and use CRLF; plain `utf-8`
makes `json.load` raise on the BOM, and the loader's silent no-op would drop every option);
JSONL split on `"\n"` only, never `splitlines()`; every JSON with variable content is built with
`json.dumps`.

### 3.4 Machine-readable output

Human and result output go to stdout. Machine-readable lines go to stderr as
`CX_<NAME> <json>` (§4.2); they are an API. Protocol output that callers parse on stdout is
named explicitly (e.g. `cx-doctor --json`, `JOB_ID <id>`, `cx-fanout`'s unplaced list).

### 3.5 Line endings

Everything is LF (`.gitattributes`). Its `eol=lf` attributes also override a Windows
`core.autocrlf=true`, so git checkouts of this repo stay LF; CRLF copies come from installs that
ignore `.gitattributes` (archive downloads, copies made with Windows tools, a `directory`
marketplace folder edited on Windows). Scripts are not made CRLF-tolerant. A CRLF copy of
`bin/cx-doctor`, `common.sh` or `forward-wsl.sh` cannot run at all (`env: 'bash\r': No such file
or directory`, `set: pipefail\r: invalid option name`), so it cannot report itself. Instead:
- the tests assert that every shipped text file is LF-only and ends with a newline (P39);
- `hooks/policy.sh`, the one script written so a CRLF copy behaves identically (a hook runs in
  every session and must fail open), checks three canary files at every session start and
  switches to the CRLF notice with the fix (§10.2, §10.5);
- `cx-doctor` reports CR in files outside its own execution path (D3 on the executor host, W6 on
  Git Bash) with the fixes of D3, none of which uses `git reset`;
- the runtime installer strips CRs and refuses a file that still contains one (§7.5).

Every `hooks.json` command is `bash "${CLAUDE_PLUGIN_ROOT}/hooks/<x>.sh"`, so neither exec bits
nor shebangs matter.

### 3.6 Shims

`bin/cx-<name>` is exactly three lines and must not be a symlink:

```bash
#!/usr/bin/env bash
# Plugin bin/ entry point (Claude Code puts bin/ on the Bash tool's PATH); forwards to scripts/cx-<name>.sh.
exec "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/scripts/cx-<name>.sh" "$@"
```

Each `scripts/cx-<name>.sh` sources `scripts/lib/common.sh` and calls
`cx_forward_if_needed cx-<name> "$@"` before anything that needs the executor host (§7.3).

### 3.7 Free by construction

No conductor code path in Phase 1 can call a model. Doctor probes are `--version`, model
listings, `auth status`, `--help` (the flag contract, §5.4) and ghcp's invalid-model probe
(§8.3: through ghcp-models on any version, the raw form only on Copilot 1.0.105) from an empty
scratch directory (D16); agy's `-p /usage` runs only with
`cx-doctor --pools --agy-usage` until §20 item 5 confirms it is zero-quota.
Tests use stubs only and assert from the stubs' argv logs that no billable invocation happened
(P30). Live (billed) checks live in `tests/live/` and are never run by `tests/run-tests.sh`.

## 4. Exit codes and the CX_* stderr protocol

### 4.1 Exit codes

One table for every `cx-*` command, the forwarder and the adapters. Codes 2, 3, 10–16 and 130
deliberately equal ghcp's (and agy-delegate's) codes, so adapters pass them through unchanged.

| Exit | `CX_SIGNAL` status | Ledger status | Raised by | Meaning |
|---|---|---|---|---|
| 0 | — | `ok` | all | Success |
| 1 | — (no `CX_SIGNAL`) | — | all | Usage error, invalid argument, refused request |
| 2 | `FAILED` | `failed` | all | Unexpected failure, unparseable executor output, unclassified executor failure |
| 3 | `EMPTY_OUTPUT` | `empty` | cx-run | Executor exited 0 with no answer and (write mode) no diff |
| 4 | `CHECKS_FAILED` | — | cx-doctor | At least one ✗ check |
| 5 | `EXISTS` | — | cx-init | A bundle file exists and differs; nothing written (no `--force`) |
| 10 | `QUOTA_EXHAUSTED` | `quota` | cx-run | Quota or rate limit |
| 11 | `AUTH_REQUIRED` | `auth` | cx-run | Executor not logged in |
| 12 | `TIMEOUT` | `timeout` | cx-run, cx-gate | Wall clock expired |
| 13 | `CLI_MISSING` | `missing` | cx-run, cx-wsl | Executor binary or sibling wrapper not found |
| 14 | `MODEL_UNAVAILABLE` | `model_unavailable` | cx-run | Model/slug/effort refused before any model call |
| 15 | `PERMISSION_DENIED` | `denied` | cx-run | A denied write, or any denial with no answer/diff (exit 0 is not success) |
| 16 | `SANDBOX_BLOCKED` | `sandbox` | cx-run, cx-doctor probes | Claude Code's Bash sandbox blocks the executor |
| 20 | `GATE_FAILED` | `gate_failed` | cx-gate, cx-fanout, cx-run (`--finish` of the copilot-cloud lane) | Tests, lint, typecheck, verdict parser, diff budget or integrated gate red |
| 21 | `MODEL_MISMATCH` | `model_mismatch` | cx-run | Served model ≠ requested (incl. `GHCP_FALLBACK` on a Fusion lane, agy `init.model`) |
| 22 | `WRONG_TREE` | `wrong_tree` | cx-run (agy) | Files changed outside the task's worktree |
| 23 | `SPEC_TAMPERED` | `spec_tampered` | cx-run, cx-gate | `.conductor/task.md` hash mismatch |
| 24 | `TAMPERED` | `tampered` | cx-run, cx-gate | Protected path changed (tests, lockfiles, CI, routes.json, agent config, …; cx-run: the worktree's `.git` link rewritten during the run, so no git ran there, §15.1), or the executor left the task branch (`BRANCH_TAMPERED`, §12.2 step 3) |
| 25 | `ENV_FAILED` | `env_failed` | cx-run, cx-gate | The repo's `setup` command failed (not charged to the executor) |
| 26 | `VERSION_MISMATCH` | `version_mismatch` | cx-run | flag contract: the CLI's live help lacks a flag the lane is about to emit; lane refused before running (no version is pinned, §5.4) |
| 27 | `PARTIAL` | `partial` | cx-run (agy) | Partial output (agy print-timeout expired with rc 0) |
| 28 | `NO_CAPACITY` | `no_capacity` | cx-run, cx-wsl (`locks.sh`) | Every eligible lane at its cap, disabled or paused; for one pool: no slot (or no agy launch lock) within `CX_SLOT_WAIT_SECS`, or its cap is 0 (§15.3) |
| 40 | `FORWARD_FAILED` | — | forward-wsl.sh (also for a `wsl-entry.sh` step-1 failure) | `wsl.exe` missing, distro missing, wsl.exe failed before the command started, or wsl.exe died after it started (VM terminated) |
| 41 | `RUNTIME_MISSING` | — | forward-wsl.sh, wsl-entry.sh | No runtime copy in WSL and auto-install is off or failed; or the runtime's version/meta mismatch |
| 42 | `PATH_UNMAPPABLE` | — | pathmap.sh, wsl-entry.sh, any path option | A path has no equivalent on the other side |
| 43 | `HOST_UNSUPPORTED` | — | all | This host cannot do this (a cloud session or a BYOC runner without `exec_host=local`, §7.3 step 0a; Cygwin, `exec_host=local` on Git Bash, `--host docker` before v1.1, `--windows` merge without Git Bash) |
| 44 | `CRLF_CORRUPT` | — | install-runtime.sh | A runtime file still contains CR after stripping |
| 75 | `RUNNING` | — | cx-job result/wait | Job still running |
| 126 | — (no `CX_SIGNAL`) | — | worker shims | `blocked: CX_WORKER` (§11) |
| 130 | `CANCELLED` | `cancelled` | all long-running | INT/TERM/HUP, or `cx-job kill` |

Every exit not in {0, 1, 126} prints exactly one `CX_SIGNAL` line, and it is the last stderr
line. Exit 1 prints `<prog>: <message>` (and `<prog>: try --help`) only. One exception:
`cx-wsl` (§7.7) exits with the passed-through tool's own status (0–255) and adds no `CX_*` line
to it (the tool's `GHCP_*`/`AGY_*` lines are the protocol); only its own failures (1, 2, 13, 28
from the pool slots, and 40–42 from the forwarder) follow this table. In a forwarded call each failure has exactly one
signal owner (§7.3 step 8).

### 4.2 Line format

`CX_<NAME> <payload>` on ONE stderr line, where the payload is
`json.dumps(obj, ensure_ascii=True)` with default separators (`{"key": value, ...}`). Only these
names exist; a new one needs a row in §4.3. The shapes below list keys and types.

Free-text fields (`reason`, `detail`) are sanitized by `cxlib.py`: control characters (incl.
CR, LF, TAB, U+2028/2029) collapse to one space, the result is trimmed and cut to 200 characters
(the cut ends in `...`). When `cx_py_ok` is false (no python3, and always on Git Bash, §3.1), `cx_signal` prints a
hand-built line whose every value is a constant from a fixed table: `status` and `exit` from §4.1,
`cmd` from the fixed command list, and `reason`/`retry` from the per-status constant strings in
`common.sh`. No variable text is ever placed in hand-built JSON; variable detail goes into a
preceding plain `<prog>: …` note.

### 4.3 Line schemas

| Line | Payload keys | Emitted by, when |
|---|---|---|
| `CX_SIGNAL` | `status` str, `exit` int, `reason` str, `retry` str\|null, `cmd` str | Any exit ∉ {0,1,126}; always last |
| `CX_HOST` | `host` (`wsl\|linux\|gitbash\|docker\|macos\|cygwin\|unknown`), `hostkey` str, `distro` str\|null, `os_id` str\|null, `os_version` str\|null, `wsl_version` int\|null, `arch` str, `kernel` str, `session` (`local\|bridge\|cloud\|byoc`, §7.1; the caller's in a forwarded doctor), `attended` int\|null | `detect.sh --emit`; `cx-doctor` (once) |
| `CX_FORWARD` | `caller` (`gitbash`), `host` (`wsl`), `distro` str (`WSL_DISTRO_NAME`, also when `wsl_distro=auto`), `cmd` str, `cwd` str\|null (WSL path), `cwd_win` str, `runtime` str (version), `installed` bool | `wsl-entry.sh`, once, before it starts the target |
| `CX_RUNTIME` | `version` str, `path` str, `changed` bool, `stripped_cr` int (files) | `install-runtime.sh` |
| `CX_DOCTOR` | `ok` int, `warn` int, `fail` int, `host` str, `caller` str, `session` str, `attended` int\|null, `record` str\|null (host record path), `pools` bool | `cx-doctor`, last line before any `CX_SIGNAL` |
| `CX_POOLS` | `agy` {`opus_slugs` [str], `usage` obj\|null}, `copilot` {`opus_id_enabled` bool, `review_ids` [str], `mtd_credits` num\|null, `mtd_age_days` num\|null, `ledger_month_credits` num\|null, `reserve_pct` int}, `grok` {`bulk_model_listed` bool, `claude_ids` [str]} | `cx-doctor --pools` |
| `CX_INIT` | `repo` str, `dry_run` bool, `written` [str], `unchanged` [str], `conflicts` [str], `excluded` bool, `detected` obj (§9.3) | `cx-init` |
| `CX_RESULT` | the result.json summary (§15.4) plus `path`, `host_path` | `cx-run`, `cx-job wait/result` (Phase 2) |
| `CX_DENIED` | `count` int, `kinds` [str], `hint` str (per lane: what that executor may run and write; never a skip-permissions flag), `commands` [str] when the denials name command lines (agy's `run_command`, 0.2.1) | `cx-run` when the executor denied anything (Phase 2) |
| `CX_NOTE` | `same_family_as_conductor` bool, `models` [str] | `cx-run` when a Claude model reviewed or wrote (Phase 2) |
| `CX_GATE` | §16.1 | `cx-gate` (Phase 3) |
| `CX_FAILOVER` | `id`, `from` (lane), `to` (lane\|`claude`), `reason` | `cx-fanout` (Phase 3) |
| `CX_QUEUE` | `batch`, `k` int, `id`, `action` (`merged\|reverted\|conflict\|redispatched`), `gate` (`green\|red\|null`) | integration queue (Phase 3) |

Order within one command: plain notes first, then protocol lines in the order the table lists
them, `CX_SIGNAL` last.

### 4.4 Emitters and shared helpers

`scripts/lib/common.sh` (pure bash; sourced by every script):

| Function | Contract |
|---|---|
| `CX_VERSION`, `CX_VERIFIED_COPILOT`, `CX_VERIFIED_GROK`, `CX_VERIFIED_AGY`, `CX_VERIFIED_CLAUDE`, `CX_MIN_CLAUDE`, `CX_MIN_AGY`, `CX_MIN_GH_COPILOT_REVIEW` | Constants `0.2.2`; the versions last verified `1.0.105`, `1.0.70`, `1.5.1`, `2.1.316` (doctor info only, never a refusal: §5.4); the doctor minimums `2.1.316`, `1.1.12`, `2.89.0` (oldest gh measured to accept `--add-reviewer @copilot`; §20 item 29) |
| `cx_py_ok` | rc 0 when python3 may be used: rc 1 whenever `uname -s` matches `MINGW*\|MSYS*\|CYGWIN*` (whatever PATH holds), else rc 0 iff `python3 -I -V` succeeds (cached in `CX_PY_OK`) |
| `cx_root` | Prints the plugin root (the directory holding `scripts/`), computed from `BASH_SOURCE` |
| `cx_prog` | Program name for notes (`cx-doctor`, …) set by each script |
| `cx_note MSG` | `printf '%s: %s\n' "$CX_PROG" "$MSG" >&2` |
| `cx_usage_error MSG` | note + `<prog>: try --help`, exit 1 |
| `cx_signal STATUS EXIT REASON [RETRY]` | Emits `CX_SIGNAL` (python when `cx_py_ok`, else the constant fallback, §4.2) and exits EXIT |
| `cx_emit NAME [KEY VALUE]...` | `python3 -I cxlib.py emit NAME …` to stderr when `cx_py_ok`, else a plain note; KEY suffixes `:int`, `:bool`, `:json`, `:null`, none = string |
| `cx_help` | Prints the calling script's header (§3.2) |
| `cx_bool VALUE` | rc 0 for `on\|true\|1\|yes\|enabled`, rc 1 for `off\|false\|0\|no\|disabled\|""` (case-insensitive, trimmed) |
| `cx_timeout SECS CMD…` | `timeout --kill-after=5s <SECS>s CMD…`, with SECS capped by `CX_PROBE_TIMEOUT` when set; without `timeout`, runs unguarded and sets `CX_UNGUARDED=1` |
| `cx_forward_if_needed CMD ARGS…` | §7.3 step 0 |
| `cx_decode_wsl` | stdin→stdout: if the first two bytes are `FF FE` or the second byte is `00`, decode UTF-16LE (`iconv -f UTF-16LE -t UTF-8` when present, else `tr -d '\000'`), drop a BOM; always `tr -d '\r'` |
| `cx_status_for_exit N` | §4.1 mapping |
| `cx_shell_words WORD…` | The words shell-quoted with `printf %q` and joined by single spaces: every path list in a printed `fix:` line (D3, W6), so the line runs as printed whatever the paths hold |

`scripts/lib/cxlib.py` (executor host only) subcommands, all printing to stdout unless noted:

| Subcommand | Contract |
|---|---|
| `emit NAME [KEY VALUE]…` | One `CX_NAME {json}` line (§4.2) |
| `sanitize` | stdin text → one sanitized line (§4.2) |
| `semver TEXT` | First `\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?` in TEXT, else exit 1 |
| `vercmp A B` | Prints `-1\|0\|1` (numeric dot parts; a prerelease sorts before its release) |
| `json-get FILE DOTTED.KEY` | Prints a scalar (JSON for objects/lists); exit 1 if absent |
| `toml-get FILE SECTION KEY` | `tomllib` when available, else a line scanner for `[section]` / `key = value`; prints the raw value |
| `options-check` | Reads the effective `CLAUDE_PLUGIN_OPTION_*` env; prints JSON `[{"name","value","default","valid","note"}]` per §5.3 |
| `plugins --config-dir DIR` | Sibling-plugin report (§8.3 D20–D26) as JSON |
| `parse-models --cli copilot\|grok\|agy FILE` | Model ids per CLI (§8.3 D16–D18); never fails, returns `{"ids": [...], "authenticated": bool\|null, "shape": "..."}`; for agy, `authenticated` is `true` only when an id looks like a model slug (one token with a digit), and an object is read as a `{slug: label}` map only when it has no status key (D18) |
| `wsl-resolve --record F --tool T --config-dir D [--conductor-bin B] [--mnt-root R]` | cx-wsl (§7.7): the tool's absolute path, its PATH and the recorded copilot; never a path under `R` or `/mnt/` |
| `host-record --out-dir DIR --hostkey K` | Reads a JSON description on stdin and writes `K.json` and `K.path` atomically (§7.6) |
| `doctor-render --checks TSV [--extra TSV] [--json] [--pools JSON]` | Renders the doctor report (§8.2, §8.7); exit 0, or 4 when any check failed |
| `init-detect DIR` | Detection JSON (§9.3) |
| `init-apply --dir DIR --templates DIR --plan JSON [--dry-run] [--force] [--json]` | Bundle writer (§9.2); exit 0 or 5 |
| `pools-mtd --file F [--set CREDITS]` | Reads or writes the month-to-date record (§8.4) |

## 5. Options

### 5.1 Option table

All options are `"type": "string"` in `plugin.json`, with `title`, `description` and `default`.
Every default is written twice: in `plugin.json` and in `options.sh`'s defaults table; a test
pins them equal (P2). An empty value means "use the default" for every option.

| Option | Default | Meaning (plugin.json description, condensed) | Valid values | Read by |
|---|---|---|---|---|
| `policy` | `on` | Inject the conductor routing policy at SessionStart (startup, clear, compact) and the subagent guard at SubagentStart. off/false/0/no/disabled suppress both. | boolean words | `hooks/policy.sh`, `hooks/subagent.sh`, `cx-doctor` D21–D22 |
| `exec_host` | `auto` | Where executors run. `auto`: Git Bash forwards into WSL, every other host runs locally. `wsl`: always WSL. `local`: run here (refused on Git Bash; on a BYOC or self-hosted runner it marks the runner as the executor host, §7.3 step 0a). `docker` arrives in v1.1. | `auto\|wsl\|local` (v1.1: `\|docker`) | `common.sh` forwarding step 0 (every `cx-*`; lite reader on Git Bash), `hooks/policy.sh` (byoc only), `cx-doctor`, `cx-run` |
| `wsl_distro` | `auto` | WSL distribution used by forwarding and by `\\wsl.localhost\<distro>` path mapping. `auto`: wsl.exe's default distribution (no `-d`); WSL-side mappings use `WSL_DISTRO_NAME`. | `auto` or `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$` | `forward-wsl.sh` (lite), `common.sh` (`cx_host_path` passes an explicit value as `--distro` when `WSL_DISTRO_NAME` is unset), `cx-doctor` W2/W4 (with `auto`, Git Bash takes the name from the `*` row of `wsl.exe -l -v`) |
| `docker_compose_file` | `` | v1.1: absolute WSL path of coding-agents-docker's `compose.yaml`. Empty = Docker lanes off. | absolute path | v1.1 `forward-docker.sh`, `cx-doctor --host docker` |
| `docker_service` | `agents` | v1.1: compose service that runs the agents. | compose service name | v1.1 |
| `opus_lane_order` | `agy,copilot,claude` | Order in which Opus 5.5 work fills the included pools; rewritten by the Phase 1 A/B. `claude` is appended when missing. | comma list of distinct `agy`, `copilot`, `claude` | `hooks/policy.sh` (renders the policy's order, §10.2), `cx-run --exec auto`, `cx-fanout`, `cx-doctor` D7 |
| `agy_opus_slug_tpl` | `claude-opus-5-5-{effort}` | agy model slug for the Opus lane; `{effort}` becomes low/medium/high. | contains `{effort}` | `adapters/agy.sh`, `cx-doctor --pools` |
| `agy_opus_mode` | `raw` | `raw` runs the agy CLI directly (kill 5 s after the result, launch lock, tree snapshots); `wrapper` uses agy-delegate. | `raw\|wrapper` | `adapters/agy.sh` |
| `copilot_opus_id` | `claude-opus-5.5` | Copilot model id for the Opus lane. | model id | `adapters/copilot.sh`, `cx-doctor --pools` |
| `copilot_xhigh_ok` | `false` | Allow `--reasoning-effort xhigh` on Copilot Opus. Set true only after the #5149 check passes; `max` is never sent. | boolean words | `adapters/copilot.sh`, `cx-run` |
| `grok_bulk_model` | `grok-4.7` | Grok model for mechanical lanes (always passed with `-m`). | model id | `adapters/grok.sh`, `cx-doctor` D17 |
| `grok_bulk_effort` | `high` | Grok effort for mechanical lanes. | `low\|medium\|high\|xhigh` | `adapters/grok.sh` |
| `grok_sandbox_profile` | `auto` | Grok sandbox profile every conductor grok run (write, read and review) runs under: `auto` = each repository's own `cx-<repo>-<hash>` in `~/.grok/sandbox.toml` (extends `strict`, §15.7); `cx-workspace` (the 0.2.0 default) counts as `auto`; any other name is a profile of the user's own, used as it is in every mode (a run is refused when it lets grok write `~/.grok`, §15.2). | profile name | `adapters/grok.sh`, `cx-init --user-grants`, `cx-doctor` D17 |
| `review_model_gemini` | `Gemini 4 Argon (High)` | agy-delegate model label for the Gemini-family reviewer (reviews Opus-written code by default). | exact agy label | `cx-run --mode review --family gemini`, skill |
| `review_model_gpt` | `gpt-6.1-sol` | Copilot model id for the GPT-family reviewer (joins on high-risk paths). | Copilot model id | `cx-run --mode review --family gpt`, skill |
| `cap_agy` | `2` | Max concurrent agy Opus processes (launches are also serialized). | integer 0–16 (0 disables the lane) | `locks.sh` via `cx-run` / `cx-fanout` |
| `cap_copilot` | `3` | Max concurrent Copilot executor processes. | integer 0–16 | same |
| `cap_grok` | `5` | Max concurrent grok processes; internal grok subagents count. | integer 0–32 | same |
| `copilot_reserve_pct` | `0` | Percent of the 20,000-credit month to leave unused by conductor lanes. 0 = off (default): no reserve. Not a per-call or session cap. | integer 0–90 | `cx-fanout`, `cx-run --exec auto`, `cx-doctor --pools` |
| `copilot_mtd_max_age_days` | `3` | Age after which the month-to-date credits figure you entered is reported stale (a warning only while `copilot_reserve_pct` > 0). | integer 1–31 | `cx-doctor --pools` |
| `agy_claude_floor_pct` | `0` | Stop dispatching agy Opus while `/usage` shows the Claude/GPT bucket below this percent. 0 = off (default). | integer 0–90 | `adapters/agy.sh` preflight, `cx-doctor --pools` |
| `worktree_root` | `~/.cx-wt` | Absolute root for task worktrees (`~` expands); never inside a repo, never `/` or `$HOME` itself. | path | `worktree.sh`, `cx-init --user-grants`, `cx-doctor` D7 |
| `ledger_path` | `~/.conductor/ledger.jsonl` | Ledger file (one JSON line per executor run). | path | `ledger.py`, `cx-doctor --pools` |
| `default_timeout` | `30m` | Wall clock per executor run unless `--timeout` is given. | `^[0-9]+[smh]?$`, ≥ 30 s | `cx-run`, `cx-job`, adapters |

### 5.2 Loader and precedence

`scripts/lib/options.sh` is a port of ghcp's `plugin-options.sh`:
- `cx_load_options [FILE…]`: for each settings file in order, read
  `.pluginConfigs["conductor@conductor-for-claude-code"]` (else key `conductor`, else the first
  key starting with `conductor@`) `.options` with `python3 -I - <<'PY'`, and export
  `CLAUDE_PLUGIN_OPTION_<UPPER>=<shlex.quote(value)>` for each scalar whose variable is not set
  yet (an already-set variable wins, even when empty; booleans become `true`/`false`, numbers
  their decimal text, null/list/object are skipped, keys must match `[A-Za-z_][A-Za-z0-9_]*`).
  Files are opened with `encoding="utf-8-sig"` (§3.3). Silent no-op when a file is missing,
  `cx_py_ok` is false or the JSON is invalid. With no FILE it loads
  `${CX_WIN_SETTINGS:-}` (set only in forwarded calls, §7.4) and then
  `${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json`.
- `cx_opt NAME`: prints `${CLAUDE_PLUGIN_OPTION_<UPPER>:-<default>}` from the defaults table
  `CX_OPT_DEFAULTS` (a bash associative array declared in `options.sh`; it is the "script
  fallback" copy of every default).
- `cx_opt_lite NAME FILE` (Git Bash only, pure bash, for `exec_host` and `wsl_distro` only):
  read FILE, strip a leading UTF-8 BOM (`$'\xef\xbb\xbf'`) and every CR; anchor on the
  pluginConfigs entry `"conductor@conductor-for-claude-code"[[:space:]]*:[[:space:]]*\{` (an
  `enabledPlugins` entry, `"…": true`, does not match); from that `{`, scan to its matching `}`
  by brace counting outside JSON strings (a `"` toggles string state unless preceded by an odd
  number of backslashes); inside that span find `"options"[[:space:]]*:[[:space:]]*\{` and, within
  that object (again to its matching brace), the first
  `"NAME"[[:space:]]*:[[:space:]]*"([A-Za-z0-9._-]*)"`. Prints the value, or nothing when any
  step finds nothing. It is a heuristic; `cx-doctor --windows` cross-checks it against the real
  parse on the WSL side (W7).

Precedence, highest first: CLI flag > environment variable already set (even empty, incl. ones a
forwarded call carries from Git Bash) > Windows-side `settings.json` (forwarded calls only) >
the executor host's `settings.json` > the default. Hooks get `CLAUDE_PLUGIN_OPTION_*` from Claude
Code itself and do not re-read files (§10.2). Only `cx-doctor.sh`, `cx-init.sh`, `cx-run.sh`,
`cx-job.sh`, `cx-fanout.sh`, `cx-gate.sh`, `forward-wsl.sh` and `common.sh`'s forwarding step
(lite reader), `hooks/policy.sh` and `hooks/subagent.sh` (env) load options; adapters receive
them from `cx-run`.

### 5.3 Validation

Readers validate the options they use against §5.1. An invalid value prints
`<prog>: ignoring invalid option <name>='<value>'; using '<default>'` once and the default is
used (never a hard failure: a typo must not break a session). `cx-doctor` D7 lists every invalid
value as `!`, every unknown key under the conductor's `options` as `!` (probable typo), and the
effective non-default values as info. Special cases: `exec_host=local` on Git Bash exits 43;
`exec_host=docker` before v1.1 is treated as invalid; a `worktree_root` that is relative, `/`,
`$HOME`, or inside the current repo is invalid.

### 5.4 Versions: no pins, a flag contract

Nothing pins a CLI version (user decision, 2026-11-06: the CLIs auto-update, and the user's
machine already ran Copilot CLI 1.0.106 when the conductor still pinned 1.0.105). `common.sh`
keeps the versions the lanes were last verified against (`CX_VERIFIED_COPILOT` 1.0.105,
`CX_VERIFIED_GROK` 1.0.70, `CX_VERIFIED_AGY` 1.5.1, `CX_VERIFIED_CLAUDE` 2.1.316): `cx-doctor`
shows them as info lines (D9–D11), never as a failure. Minimums stay doctor checks only (Claude
Code `>= 2.1.316` !, agy `>= 1.1.12` !, agy `< 1.1.10` ✗).

Instead every adapter's free preflight checks a **flag contract** (`normalize.py probe
--help-file/--argv-file/--argv-shell/--need`): it runs the CLI's own help (`grok --help`,
`agy --help`, `agy-delegate --help`, `ghcp-delegate --help`, `copilot --help` and `copilot help
permissions`, `claude --help`, `ghcp-cloud --help`; free: no model call) and requires every flag
token of the argv the run is about to use (after the executable, up to a literal `--`; `--x=v`
counts as `--x`) to appear there as a whole token, plus the lane's fixed extras (agy's
registration and `/usage` forms: `--new-project`, `--output-format`, `-p`; Copilot: the argv
`ghcp-delegate --print-command` builds from this run's options, and the `shell(` and, for a
writer, `write(` kinds in `copilot help permissions`). A missing flag, or a help that prints
nothing, refuses the lane before anything runs: exit 26, status `VERSION_MISMATCH` (the API name
is kept), reason `flag contract: <lane> <version>: the help no longer lists <flag> (<help>)`.
The verdict is part of the probe and cached with it (10 minutes; the cache key holds the flags
and the binaries' resolved path, mtime and size, so a self-update is probed again at once).

Auto-update is the user's choice and no doctor check advises against it (D14 is information
only). Each run still sets `COPILOT_AUTO_UPDATE=false`, `GROK_DISABLE_AUTOUPDATER=1` and
`AGY_CLI_DISABLE_AUTO_UPDATE=true` in its own worker environment (§15.6), so no CLI replaces
itself in the middle of a run, and `wsl-entry.sh` exports the three for every forwarded command
(§7.4). Releasing a new verified version is a plugin release (version bump, CHANGELOG, the
`CX_VERIFIED_*` constant and the doctor's info text).

## 6. Routing model

This section is the single source for the skill (§12), the policy (§10.3), `/conductor:route`
and, from Phase 2, `cx-run --explain`.

### 6.1 Lanes

| Lane id | Executor and model | Pool | Writes | Phase 1 invocation | From Phase 2 |
|---|---|---|---|---|---|
| `claude` | Claude Code, `claude-opus-5-5`, effort up to `max` | Claude plan (the pool to conserve) | yes | Your own Task/Agent subagents | Same; `cx-fanout` returns unplaced tasks; `claude -p` worker optional |
| `agy-opus` | agy, `claude-opus-5-5-{medium,high}` | Ultra Claude/GPT bucket | yes (per-run `--settings` grants since 0.2.1) | `agy-delegate --model claude-opus-5-5-high` after registration (§12.2) | `cx-run --exec agy` (raw mode) |
| `copilot-opus` | ghcp, `claude-opus-5.5 --effort high` | Copilot credits | yes | `ghcp-delegate --model claude-opus-5.5 --effort high --write …` | `cx-run --exec copilot` |
| `copilot-fusion` | ghcp Fusion Standard/Max | Copilot credits | yes | `ghcp-delegate --fusion standard\|max`, `ghcp-handoff --tier pro` | `cx-run --exec copilot --fusion …` |
| `copilot-gpt` | ghcp, `gpt-6.1-sol` (`gpt-6-astra` critique, `gpt-6-luna` text) | Copilot credits | no | `ghcp-delegate --model gpt-6.1-sol --effort high --digest` | `cx-run --mode review --family gpt` |
| `copilot-github` | Copilot code review, `/pr fix`, ghcp-ci-debug; ghcp `--github` only for a task meant to act on GitHub (it adds every GitHub MCP tool, acting as the user) | Copilot credits | via PR; `--github` writes on GitHub as the user | `gh pr edit cx/<id> -R "$REPO" --add-reviewer @copilot`; `ghcp-ci-debug` without `--apply`; triage = `gh` fetch + read-only `copilot-gpt` digest (§12.2 step 5) | §17 |
| `grok` | grok (last verified 1.0.70), `-m grok-4.7` | xAI weekly first-party pool | yes (its repository's strict sandbox profile, `--always-approve` inside it) | raw `grok` (§12.2) | `cx-run --exec grok` |
| `agy-gemini` | agy-delegate, `Gemini 4 Argon (High)` / `gemini-3.8-flash-high` | Ultra Gemini quota (not the Claude/GPT bucket) | no | `agy-delegate --model '<label>' --digest` | `cx-run --mode review --family gemini` |
| `agy-media` | agy-media, `/antigravity:research` | Ultra Gemini quota | machine-wide: both always pass `--yolo` (§0.3) | none: not used outside Docker | the v1.1 Docker lane (§18) |

### 6.2 Routing table

Rules for every writing task: one task, one executor, one worktree, one `cx/<id>` branch; the
task contract is `.conductor/task.md` (§6.4); the repo's `setup` runs first; the conductor
commits and gates (§6.5). "Gate" = Claude reruns the repo's checks on a clean checkout of the
conductor's commit, then the integrated gate at merge.

| Task type | Primary (lane · model · effort) | Fallback | Verification |
|---|---|---|---|
| Architecture / hard reasoning | `claude` · xhigh (max for one-way doors) | `copilot-opus` high | Claude writes the ADR; optional read-only alternatives from `agy-opus`, critique from `copilot-gpt` (`gpt-6-astra`) are input only |
| Exploration / "where is X" | `grok` · `grok-4.7` medium, read mode (the repository's strict-based profile, §15.2), `--json-schema` returning `[{file,line,why}]` | `agy-gemini` flash, read-only (register the dir) | Claude spot-checks cited lines |
| Small (<~200 lines) or judgement-heavy change | `claude` | — | Normal tests (delegating below break-even is a measured loss) |
| Debugging / root cause | `claude` owns hypotheses; `grok` high writes repro scripts, `git bisect run`, log digests | `agy-gemini` flash for logs >200k tokens | Claude sees the test fail before and pass after |
| Spec'd feature, design-sensitive | Opus lanes in `opus_lane_order` (§6.3), high, only with strong acceptance tests until the A/B | next Opus lane; Fusion Max (`ghcp-handoff --tier pro`) when both pools are drained; then `claude` | Clean-checkout tests, tamper check, diff budget, cross-family review, integrated gate |
| Spec'd feature, mechanical | `grok` · `grok-4.7` high, `--no-subagents`, `--max-turns 60` | `copilot-fusion` standard; `agy-gemini` flash high | Same gate plus the `permission required:` stderr scan |
| Bulk edits / migrations | `claude` writes a codemod; `grok` high does the remainder, one worktree per directory shard, 4–6 lanes | `copilot-fusion` standard | Full checks; grep for leftovers; Claude reads a 5–10 % sample of hunks |
| Dependency upgrades | `grok` mechanical (lockfiles exempt; only this task type may run `setup`) | `copilot-fusion` standard | Integrated gate; Claude reads the upstream changelog; `audit` when routes defines it |
| Exhaustive tests | `grok` high against a contract Claude wrote | `agy-gemini` flash high; `copilot-gpt` medium | Tests pass on current code, zero source changes, opt-in mutation threshold, Claude samples for tautologies |
| Performance | `claude` profiles and picks the hotspot; Opus lane (design) or `grok` (mechanical) implements | `claude` | `bench` before/after on the same host; tests still pass |
| First-pass review, local diff | `grok` high, review mode (the repository's strict-based profile), `--json-schema` review schema, on a gate checkout + diff file | `agy-gemini` flash read-only | Claude confirms every accepted finding at file:line |
| First-pass review, GitHub PR | `copilot-github` code review | `grok` review of `gh pr diff N` | Claude adjudicates; Copilot approvals count only after explicit opt-in |
| Security review | `claude` + `copilot-gpt` (`gpt-6.1-sol` high) + CodeQL/secret scanning; never Grok alone | `agy-gemini` Argon | Claude adjudicates every finding at file:line |
| Second opinion on Opus-written code | `agy-gemini` Argon High; `copilot-gpt` also on `high_risk` paths | `grok` xhigh | Never count Opus reviewing Opus as independent (`same_family_as_conductor`) |
| Second opinion on Grok/Gemini-written code | `claude`, depth scaled by risk | — | — |
| PR / issue / CI triage | `copilot-github` (`ghcp-ci-debug`); issues and PRs fetched with `gh` first, then a read-only `copilot-gpt` digest (never `--github` for triage: it acts as the user) | `grok` digest of `gh run view <id> --log-failed` | Fixes go through the same gates |
| Commit messages, PR text, changelogs | `grok` low/medium, `--sandbox strict` in a directory that holds only the prompt file with the diff (§12.2) | `copilot-gpt` (`gpt-6-luna`) | Claude edits; nothing not in the diff |
| Merge conflicts / integration fixes | `claude` | — | Integrated gate |
| UI / frontend code | `claude` designs; Opus lanes make 2–3 parallel variants (one worktree each) | `claude` subagent | Screenshots (setup [unverified]), a11y lint; Claude picks and says why |
| Media understanding | v1.1 Docker lane (`agy-media` always passes `--yolo`); Phase 1: Claude reads what it can (images, transcripts) | — | Claude checks timestamps it relies on |
| Web-grounded research | Claude WebSearch / WebFetch; `grok` (real time, X) | `agy-gemini` flash on text Claude fetched (headless agy web search needs `--yolo`; `/antigravity:research` waits for Docker) | Claude re-fetches load-bearing citations; ≥2 sources per claim |
| Long-file / codebase digest | `agy-gemini` Argon High above ~200k tokens, flash below (register the dir) | `grok`; `copilot` long-context | Claude spot-checks 3–5 file:line references |
| Docs | `grok` medium for reference docs; `claude` for narrative/architecture | `agy-gemini` flash; `copilot-fusion` | Examples and doctests run; Claude edits |
| Images (v2 lane) | agy `image-generator`, interactive until headless is confirmed | — | Claude opens each file |
| N-way Opus fan-out | `cx-fanout` (Phase 3); in Phase 1 Claude dispatches by hand in `opus_lane_order` | failover down the chain after a worktree reset | §6.5 gates and the integration queue |

### 6.3 Opus pool order and effort map

Order = option `opus_lane_order` (default `agy,copilot,claude`): agy is flat-fee Ultra quota
that refreshes every 5 hours and weekly (unused capacity is lost), but its harness has only been
measured with Flash (3.4/5) and it is the least reliable lane (#1313, #318); Copilot is exactly
metered and also pays for reviews and CI triage (batch work into large calls: 13–18k overhead
tokens each); Claude native is the default home for xhigh/max. Until the A/B (§6.7) lands, the
agy Opus lane takes only tasks with strong acceptance tests, and every agy task contract forbids
subagents (they cannot be pinned to Opus).

| Requested effort | agy | Copilot | Claude |
|---|---|---|---|
| low | Do not spend Opus: `grok` low/medium or `gemini-3.8-flash-low` | — | low |
| medium | `claude-opus-5-5-medium` | `--reasoning-effort medium` | medium |
| high (offload default) | `claude-opus-5-5-high` | `--reasoning-effort high` | high |
| xhigh | not offered → next pool | only when `copilot_xhigh_ok=true` | **default home** |
| max | not offered | never (#5149) | **max** |

Never switch model or effort inside one executor session (it invalidates the cache).

### 6.4 Task contract

- `$OUT/task.md` is canonical (`$OUT = $CX_HOME/out/<id>`). Before EVERY dispatch it is copied
  to `$WT/.conductor/task.md` and its sha256 recorded in `$OUT/task.sha`. `/.conductor/` is
  added once to `$(git rev-parse --git-common-dir)/info/exclude`, so it is never committed.
- The prompt is always the fixed text (kept tiny because ~19k-character agy prompts trigger
  #1313): `Read .conductor/task.md in the working directory and do exactly what it says. Run
  checks only as cx-route <name> (cx-route alone lists them). Do not spawn subagents. End with
  the DIGEST: line it specifies.` The agy raw lane adds what its per-run grants allow (read with
  agy's own file tools; only cx-route, git status and ls, never git diff, log or show; any other
  command ends the run); the claude dispatch names cx-route by its path
  (`$CX_HOME/routes/<id>/cx-route`).
- Checks run only through the run's `cx-route` (§15.1): the contract names each as
  `cx-route <name>` (`templates/task.md` does it for free-text tasks, from the run's snapshot).
- `templates/task.md` (Phase 2; Claude writes the same structure by hand in Phase 1). Line 1 is
  machine-readable JSON in an HTML comment, the rest is prose for the executor:

```markdown
<!-- cx-task {"id": "t1", "base": "<sha>", "lane": "agy-opus", "effort": "high", "allowed_paths": ["src/feature/**"], "lockfiles": false, "commands": ["npm test"]} -->
# Task t1: <one-line goal>
## Goal
## Context
Files and pointers (paths, functions). No pasted file contents beyond short excerpts.
## Acceptance tests
- Must pass: `cx-route test` (`npm test`) …
- Existing tests that must not change: `tests/foo.test.ts` …
## Allowed changes
Only paths matching: `src/feature/**`. Lockfiles: no.
## Allowed commands
Run checks only through cx-route: `cx-route test` (`npm test`), snapshotted from .cx/routes.json
at dispatch (`cx-route` alone lists them). Also allowed: git status. Read files, and your own
changes, with your file tools. No other shell command.
## Forbidden
Editing .conductor/task.md, the tests listed above, CI config, .cx/routes.json or git hooks;
installing, upgrading or patching dependencies; committing, pushing or branching; starting
subagents or other coding agents.
## Output contract
Reply with a compact digest: what changed (file:line), what you ran and its result, open
issues. No full file contents, no raw logs. End with exactly one line: DIGEST: <one sentence>.
```

### 6.5 Guardrails

| # | Guardrail | Phase 1 (by hand, via the skill) | Enforced from |
|---|---|---|---|
| G1 | Spec first: Claude writes acceptance tests and task.md before delegating | skill recipe | Phase 2 (`taskfile.sh`) |
| G2 | One task, one executor, one worktree, one branch; two executors only for an explicit cross-model review | skill recipe | Phase 2 locks + worktree.sh |
| G3 | The conductor commits; Claude reruns the checks on a fresh checkout with fresh `setup`; never gate in the worker's tree | skill recipe | Phase 3 `cx-gate` |
| G4 | Tamper check: tests, lockfiles (unless exempt), CI, test-runner config, `.cx/routes.json`, `.git/*`, `.gitignore`, submodules, agent config, task.md hash; executors may not install deps | skill checklist | Phase 3 `cx-gate` |
| G5 | Exit 0 is not success: agy `denied_actions`/`finished_reason`/exit 15; grok `permission required:`; Copilot `GHCP_DENIED`/15; and a diff must exist | skill checklist | Phase 2 adapters |
| G6 | Check the served model every run; any mismatch (incl. `GHCP_FALLBACK` on a Fusion lane) fails the run | Copilot: `GHCP_USAGE.models_used`. agy: `AGY_USAGE.model` only echoes the request (§1.4), so a wrapper run is recorded as served model `unverified (wrapper)`; only the raw A/B arm's `init` event verifies it (§12.2 step 2a) | Phase 2 adapters (exit 21); agy only in raw mode (wrapper mode never counts as verified, §15.2) |
| G7 | Cross-family review; Claude's own review scaled to risk; every accepted finding confirmed at file:line, every rejected one gets a reason | policy + skill | Phase 4 review lane |
| G8 | No self-reported success: digests end with "VERIFY THIS" when relayed | skill | Phase 2 `cx-run` output |
| G9 | No version pins (0.2.1): every lane checks the live `--help` for each flag it emits before it runs; pass model and effort explicitly every time | doctor D9–D11 (versions last verified, info) | Phase 2 preflight (exit 26, the flag contract, §5.4) |
| G10 | Fence workers in the environment: `CX_WORKER=1`, worker shims first on PATH, `GROK_CLAUDE_*_ENABLED=false`, scrubbed `COPILOT_*` and API keys (`XAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`; each would bill an API account instead of the subscription); no skip-permissions outside Docker; no conductor content in repo `CLAUDE.md` or `.claude/` | per-command env prefixes on every executor command (§12.2), never exported; shims shipped; cx-init writes nothing there | Phase 2 adapters |
| G11 | Secrets: repos with secrets use Docker lanes (v1.1) or exclude pools in routes.json (default: all pools on, U4); grok always runs under a sandbox profile (writers: the repository's `cx-<repo>-<hash>`, extends `strict`, §15.7) | — | Phase 2, v1.1 |

### 6.6 Hazards and how they are neutralized (no forks)

| Hazard | Neutralization | Where |
|---|---|---|
| grok-build SessionEnd kills and erases bridge jobs on `/clear` | Never use the bridge for conductor work; conductor jobs live in `$CX_HOME/jobs` | D23 warning |
| grok-build bridge: effort capped, unsandboxed `--always-approve` writes, prompt re-tokenizing, 128 KiB E2BIG, missing `grok import` | Call raw `grok` with `--prompt-file`, explicit `-m`/`--effort`, `--sandbox` profile | §12.2, adapters |
| Ungated proactive subagents `grok-build:grok-delegate`, `antigravity:antigravity-delegate` | User-level deny rules (`Task(...)` syntax [unverified] on 2.1.316) | D24; the policy names both and forbids them (P20) |
| Wrappers that hard-code `--yolo`: `agy-handoff`, `agy-media`, `/antigravity:research` | Not Phase 1 lanes (§0.3); named only to forbid them; not on the `cx-wsl` allowlist; no D25 rule | P20, P43, P45 |
| Two sibling SessionStart policies (~4.4k chars) and two nudges | Turn `coding_policy`/`delegation_nudge` off for ghcp and antigravity at user level; the conductor injects one policy | D21–D22 |
| Both siblings read `CLAUDE_PLUGIN_OPTION_{TIER_PRO,TIMEOUT,…}` | Never export those globally; prefix single commands only | skill |
| ghcp's PreToolUse gate fails closed on malformed payloads | The conductor's hook never emits malformed JSON | §10 |
| grok imports `~/.claude` hooks, skills, MCP and plugins | `GROK_CLAUDE_*_ENABLED=false` on every grok run [docs-only] + shims | §12.2, adapters |
| `/antigravity:migrate`, `agy plugin import claude` copy every Claude plugin into agy | Never run them on conductor machines | skill, login help |
| agy works in its last project root for an unseen dir | Register with `--new-project -p /model`; launch lock; tree snapshots → `wrong_tree` | §12.2, Phase 2 agy adapter |
| agy-delegate rescues #1313 only after print-timeout + ≤120 s | Opus lane raw mode kills 5 s after the result event | Phase 2 |
| agy-delegate default print timeout 5m returns PARTIAL | Always pass `--timeout 30m`; recommend antigravity `timeout=30m` | §12.2, D22 |
| `agy-job result` exits 0 whatever the job rc | Read `<jobdir>/rc` | skill |
| `--continue` races between parallel runs | Use `--resume <id>` / `--conversation <id>` only | skill, adapters |
| A CLI update drops or renames a flag a lane passes | The flag contract refuses the lane before it runs (26; no pin, §5.4); a Fusion refusal on a Copilot build without the Fusion strings is a `GHCP_FALLBACK`, 21 | Phase 2 preflight; D9–D11 info |
| Fusion refusal → billed re-run on plain auto | `GHCP_FALLBACK` on a Fusion lane = `model_mismatch` | Phase 2 copilot adapter |
| `grok worker` registers the machine with Cursor | Never run it; warn when a `grok worker` process runs (leader processes are normal grok leader mode) | D27 |
| Executors cannot run in Claude Code's Bash sandbox: Copilot writes `~/.copilot` (exit 16), agy `~/.gemini` and `~/.antigravity` (no exit 16: shows as 2/11 or a hang), grok `~/.grok`; worktrees under `worktree_root` and `~/.conductor` writes fail too | Executor calls, `gh`, `git push` and worktree setup use the unsandboxed Bash mode; exit 16 is reported, never retried silently; agy/grok permission or EROFS text inside the sandbox → rerun unsandboxed | policy, skill, D26 |
| The Bash tool kills foreground calls at 2–10 minutes (ghcp: billed tokens, exit 130; agy: orphaned) | Every call that may exceed 9 minutes is one background Bash call, or a `ghcp-job` start waited for inside one background call (agy has no job form: its lock and snapshots span the run) | §12.2, policy |
| `agy-job status` prints the job's task text, so a bare `grep running` can match it | No Phase 1 form waits on `agy-job`; anyone who does matches `grep -qx '  state=running'` | skill hazards |
| Billing switches in the environment: `XAI_API_KEY`, `GEMINI_API_KEY`/`GOOGLE_API_KEY`, `COPILOT_ALLOW_ALL`, `COPILOT_PROVIDER_BASE_URL`, `COPILOT_AUTO_TIER`, `COPILOT_MODEL` | Per-command `env -u …` prefixes in every Phase 1 command; D28 warns | §12.2, D28 |
| `AGENTS.md` imported into `CLAUDE.md` (`@AGENTS.md`) would bind the conductor and the Copilot coding agent to worker rules | Worker-only rules are conditional on `.conductor/task.md` existing | §9.5 |
| A git-based CRLF fix run on a plugin cache copy resolves the enclosing repo (`reset --hard` there loses work) | No fix text uses `git reset`; git fixes only on a verified marketplace clone | D3, P29 |

### 6.7 Phase 1 blinded A/B (sets `opus_lane_order`)

Run by hand in Phase 1, in parallel with the build; it is billed (Copilot side ≈100–500 credits
per task, agy side Ultra quota; allowed by U2).
1. Pick 3 representative tasks from a real repo, each with acceptance tests written first.
2. One `task.md` per task, identical for every lane. For each task create three worktrees from
   the same BASE and run: agy-opus-high (§12.2 step 2a; preferably the raw arm, whose `init`
   event verifies the served model; a wrapper-arm run is recorded as served model
   `unverified (wrapper)`), copilot-opus-high (§12.2 step 2b), and a Claude subagent at high
   effort. Every executor run is one background Bash call (§12.2).
3. The conductor commits each result and runs the gate on a clean checkout (§12.2 step 3).
   Record per run: gate result, diffstat, wall time, credits/quota (`GHCP_USAGE.ai_credits`,
   `AGY_USAGE`, agy `/usage` delta), served model and how it was verified, tamper findings.
4. Blind review: copy the three diffs to files named `A`, `B`, `C` in a random order recorded in
   a sealed file; a fresh Claude subagent scores each 1–5 on correctness, minimality (no dead
   code, no unrequested options), test integrity and style, using the antigravity plugin's A/B
   method.
5. Decision: rank lanes by (gate passes, then mean blind score). agy stays first only if its
   passes ≥ Copilot's and its mean score ≥ Copilot's − 0.3; otherwise the order becomes
   `copilot,agy,claude`. Keep the raw records (diffs, digests, transcripts: third-party or
   proprietary code) under `$CX_HOME/ab/2026-11/`, never in the plugin repo; commit only an
   aggregate table (per lane: gate passes, mean blind scores, credits/quota, wall time, served
   model verification) to `docs/ab-2026-11.md`. Set the option with
   `printf '%s' '{"opus_lane_order":"<order>"}' | claude plugin configure
   conductor@conductor-for-claude-code --values-stdin`; the policy picks it up at the next
   session start (§10.2).

## 7. Host layer (`scripts/host/`)

### 7.1 `detect.sh`

```
detect.sh [--shell | --json | --emit | --field NAME]
```

Sourced, `cx_detect` sets `CX_HOST CX_HOSTKEY CX_DISTRO CX_OS_ID CX_OS_VERSION CX_WSL_VERSION
CX_ARCH CX_KERNEL CX_SESSION CX_ATTENDED` (the last two from `cx_session` and `cx_attended`, below). `--shell` prints `KEY=value` lines (`printf '%s=%q\n'`, pure bash);
`--field NAME` prints one value; `--json` / `--emit` (a `CX_HOST` line) need `cx_py_ok` (exit 2
with a note otherwise, which is always the case on Git Bash, §3.1).

Inputs: `uname -s`, `uname -r`, `uname -m`, `uname -n` (through PATH, so tests stub them); env
`WSL_DISTRO_NAME`, `MSYSTEM`, `container`, `COMPOSE_PROJECT_NAME`, `HOSTNAME`; files under
`${CX_DETECT_ROOT:-}` (empty in production; a test root in the suite): `/.dockerenv`,
`/run/.containerenv`, `/proc/1/cgroup`, `/proc/sys/fs/binfmt_misc/WSLInterop`,
`/proc/sys/fs/binfmt_misc/WSLInterop-late`, `/etc/os-release`, `/etc/wsl.conf`.

Decision order (first match wins):

| # | Condition | `CX_HOST` |
|---|---|---|
| 1 | `uname -s` matches `MINGW*` or `MSYS*` | `gitbash` (`CX_OS_ID=windows`) |
| 2 | `CYGWIN*` | `cygwin` (unsupported: exit 43 wherever it matters) |
| 3 | `Darwin` | `macos` (runs locally; untested) |
| 4 | anything but `Linux` | `unknown` |
| 5 | Linux and a container marker: `/.dockerenv` or `/run/.containerenv` exists, `container` is non-empty, or `/proc/1/cgroup` matches `docker\|containerd\|kubepods\|libpod` | `docker`. Checked before WSL on purpose: Docker Desktop containers run on the WSL2 kernel, whose `uname -r` contains `microsoft-standard-WSL2` |
| 6 | Linux and (`WSL_DISTRO_NAME` non-empty or a `WSLInterop*` file exists) | `wsl`; `CX_WSL_VERSION=2` when `uname -r` matches `microsoft-standard\|WSL2`, `1` when it matches `-Microsoft`, else empty |
| 7 | Linux and `uname -r` matches `[Mm]icrosoft` | `wsl` (interop disabled; noted by the doctor) |
| 8 | otherwise | `linux` |

`CX_DISTRO`: `$WSL_DISTRO_NAME` on WSL; when that is empty (ssh into WSL, `su -`, cron,
systemd units) the registered name from `wslpath -w /` (`\\wsl.localhost\<Name>\` or the
legacy `\\wsl$\<Name>\`; whether wslpath names the distribution in such shells is
[unverified]); else `ID` from os-release. `CX_DISTRO_SOURCE` (`env`, `wslpath`, `os-release`;
not printed) tells the doctor which one won (D1). Elsewhere `ID` from os-release. `CX_OS_ID`/`CX_OS_VERSION`:
os-release `ID`/`VERSION_ID` (quotes stripped, pure bash). `CX_HOSTKEY`: `wsl-<distro>`,
`linux-<hostname>`, `docker-<COMPOSE_PROJECT_NAME or hostname>`, `macos-<hostname>`,
`gitbash-<hostname>`, with every character outside `[A-Za-z0-9._-]` replaced by `_`.

**Session kind first.** The conductor decides by session kind before the shell host and the
attended flag (§1.7). `cx_session` and `cx_attended` are pure bash, read the environment (and,
for the user's-computer override, `uname` and the `WSLInterop` files under `CX_DETECT_ROOT`),
and are also defined standalone (step 0a calls `cx_session` before host detection). A Git Bash
or WSL host is never `cloud` or `byoc`: Anthropic's cloud containers are plain Linux, the
cloud branch is only a safety net (U7), and a false cloud verdict would turn the policy off and
make every `cx-*` exit 43 on the user's own executor host. `CLAUDE_CODE_ENVIRONMENT_KIND=bridge`
stays the primary Work locally signal (§1.7; it is [docs-only, binary]):

```bash
cx_session() {
  local r="${CLAUDE_CODE_REMOTE:-}" k="${CLAUDE_CODE_ENVIRONMENT_KIND:-}" w
  r="${r//[[:space:]]/}"
  case "${r,,}" in
    1|true|yes|on)
      case "$k" in "") CX_SESSION=cloud ;; bridge) CX_SESSION=bridge ;; *) CX_SESSION=byoc ;; esac ;;
    *)
      case "$k" in bridge) CX_SESSION=bridge ;; *) CX_SESSION=local ;; esac ;;
  esac
  # Never cloud or BYOC on the user's computer: Anthropic's cloud containers are plain Linux,
  # so a Git Bash or WSL host is local whatever the variables say (a false cloud verdict would
  # switch the conductor off on its own executor host).
  case "$CX_SESSION" in
    cloud|byoc)
      case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*) CX_SESSION=local; return 0 ;; esac
      [ -n "${WSL_DISTRO_NAME:-}" ] && { CX_SESSION=local; return 0; }
      for w in "${CX_DETECT_ROOT:-}"/proc/sys/fs/binfmt_misc/WSLInterop*; do
        [ -e "$w" ] && { CX_SESSION=local; return 0; }
      done
      case "$(uname -r 2>/dev/null)" in *[Mm]icrosoft*) CX_SESSION=local ;; esac ;;
  esac
  return 0
}
cx_attended() {
  case "${CLAUDE_CODE_SESSION_ATTENDED:-}" in
    1) CX_ATTENDED=1 ;;
    0) if [ "${CX_SESSION:-}" = bridge ]; then CX_ATTENDED=; else CX_ATTENDED=0; fi ;;
    *) CX_ATTENDED= ;;
  esac
  return 0
}
```

| `CX_SESSION` | Arises as | Behaviour |
|---|---|---|
| `local` | a terminal, VS Code, a desktop session on a Windows folder, `claude -p` | as before: WSL policy, or Git Bash forwarding |
| `bridge` | a Remote Control child: a **Work locally** project thread (U7) or a session driven from claude.ai, from the desktop app (Git Bash) or `claude remote-control` (WSL) | exactly `local`; Phase 1 adds the cross-thread rule that agy runs one job at a time (no shared pool slots yet, §15.3) |
| `cloud` | an Anthropic cloud session, cloud thread or coordinator | never fails: the cloud notice (§10.6), every `cx-*` exits 43 at step 0a (§7.3) |
| `byoc` | a BYOC or self-hosted runner (`CLAUDE_CODE_ENVIRONMENT_KIND=byoc`, `self_hosted`, or any other kind but `bridge`) | as `cloud`, unless option `exec_host=local` says the runner is the executor host; then as `local` (the policy too, §10.2 row 4) |

`CX_ATTENDED` is `0` only when `CLAUDE_CODE_SESSION_ATTENDED=0` and the session is not a bridge
child (a Work locally thread has a claude.ai UI even when Claude Code marks it unattended,
§20 item 51); the policy then adds its unattended sentence (§10.2 `{ATTN}`) and D30 an info line.
`--shell`, `--field session|attended` and `--json`/`--emit` expose both. Forwarded calls drop
the `CLAUDE_CODE_*` variables (the §7.3 env allowlist), so the WSL side always sees `local`;
the Git Bash side reports the caller's values (W10, the doctor header). Rules: never route on
the entrypoint alone (a bridge child inherits it); never read `CLAUDE_CODE_VERSION` (wrong, §1.7)
or `CLAUDE_PROJECT_DIR` in Bash-tool code paths (unset there); ignore
`CLAUDE_CODE_HOSTED_DESKTOP`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_ATTRIBUTION_PROJECT`,
prompt markers and MCP server names. `cx_session` and `policy.sh`'s case line (§10.2 row 4)
change together.

### 7.2 `pathmap.sh`

```
pathmap.sh to-wsl     [--caller gitbash|win|wsl] [--distro D] [--mnt-root R] PATH
pathmap.sh to-win     [--distro D] [--mnt-root R] [--mixed] PATH
pathmap.sh to-gitbash [--distro D] [--mnt-root R] PATH
```

Pure bash string mapping (no filesystem access, no `wslpath`, no `cygpath`), so it is
deterministic and identical on both sides. Prints the result and a newline, exit 0; on refusal
prints `pathmap: <reason>` to stderr and exits 42. Sourced, it defines `cx_path_to_wsl`,
`cx_path_to_win` and `cx_path_to_gitbash` with the same arguments (rc 42 and the reason in
`CX_PATHMAP_ERR`). Defaults: `--distro` = `$WSL_DISTRO_NAME`, else `$CX_WSL_DISTRO` (set by
Git Bash callers once they resolved the name, §7.3), else none: a rule that needs the name (T6,
`to-win` of a non-drive path, `to-gitbash` of one) then refuses with "distro unknown (pass
--distro)", and every other rule still works; `--mnt-root` =
`$CX_MNT_ROOT`, else `[automount] root` from `${CX_DETECT_ROOT:-}/etc/wsl.conf` when readable,
else `/mnt/` (always normalized to end in `/`); `--caller` = `wsl` unless `CX_CALLER=gitbash`.

`to-wsl` rules, applied in order:

| Rule | Input shape | Result |
|---|---|---|
| T1 | empty, or contains NUL, CR or LF | refuse |
| T2 | `wsl:<abs posix>` | the posix path unchanged (relative → refuse) |
| T3 | `\\?\UNC\…` or `//?/UNC/…` | `\\?\UNC\wsl.localhost\…` and `\\?\UNC\wsl$\…` (host case-insensitive; the extended-length form `cygpath -w` may print for a path over `MAX_PATH` [unverified]) → `\\wsl.localhost\…` / `\\wsl$\…`, continue at T6; any other host → refuse (network share) |
| T4 | `\\?\X:\…` or `//?/X:/…` | strip the prefix, continue at T7 |
| T5 | `\\.\…` or `//./…` | refuse (device path) |
| T6 | `\\wsl.localhost\<D>\rest`, `\\wsl$\<D>\rest`, same with `/` separators (host case-insensitive) | `<D>` must equal the distro (case-insensitive) else refuse; result `/rest` with `\` → `/`; no rest → `/` |
| T7 | other `\\host\…` or `//host/…` | refuse (network share: map it inside WSL first) |
| T8 | `X:\rest` or `X:/rest` | `<mnt-root><lowercase x>/rest` with `\` → `/`; `X:\` → `<mnt-root>x` |
| T9 | `X:` alone or `X:rest` (drive-relative) | refuse |
| T10 | `/…` with `--caller wsl` | unchanged |
| T11 | `/x` or `/x/rest` (single letter) with `--caller gitbash` | `<mnt-root>x/rest` |
| T12 | `<mnt-root>x` or `<mnt-root>x/rest` with `--caller gitbash` | unchanged (already a WSL drive path) |
| T13 | any other `/…` with `--caller gitbash`, or any `/…` with `--caller win` | refuse ("Git Bash path with no WSL equivalent; pass a Windows path or wsl:<path>") |
| T14 | relative | `\` → `/` unless `--caller wsl`; stays relative (the caller resolves it against its cwd) |

After mapping: runs of `/` collapse to one, a trailing `/` is dropped except on `/`, and `.` /
`..` components are kept as given (lexical normalization through symlinks would be wrong).

`to-win` (input must be an absolute WSL path): refuse a relative path; refuse a path with a
component containing `\ : * ? " < > |` or a control character ("not representable on Windows");
`<mnt-root>x[/rest]` (single letter) → `X:\rest` (`X:\` alone for the drive root); anything else
→ `\\wsl.localhost\<D>\rest` (`\\wsl.localhost\<D>\` for `/`). `--mixed` uses `/` separators.
`to-gitbash`: a drive path → `/x/rest`; anything else → `//wsl.localhost/<D>/rest`; Windows
inputs are first mapped with `to-wsl --caller win`.

Examples (`--distro Ubuntu`, mount root `/mnt/`); the suite checks every row (P11):

| Mode | Input | Output |
|---|---|---|
| to-wsl, caller win | `C:\Users\me\repo` | `/mnt/c/Users/me/repo` |
| to-wsl, caller win | `c:/Users/me/repo/` | `/mnt/c/Users/me/repo` |
| to-wsl, caller win | `D:\data\x y\z.txt` | `/mnt/d/data/x y/z.txt` |
| to-wsl, caller win | `C:\` | `/mnt/c` |
| to-wsl, caller win | `\\?\C:\long\path` | `/mnt/c/long/path` |
| to-wsl, caller win | `\\wsl.localhost\Ubuntu\home\me\repo` | `/home/me/repo` |
| to-wsl, caller win | `\\wsl$\Ubuntu\home\me\repo` | `/home/me/repo` |
| to-wsl, caller win | `\\WSL.LOCALHOST\ubuntu\tmp` | `/tmp` |
| to-wsl, caller win | `\\wsl.localhost\Ubuntu` | `/` |
| to-wsl, caller gitbash | `//wsl.localhost/Ubuntu/home/me/repo` | `/home/me/repo` |
| to-wsl, caller gitbash | `//wsl$/Ubuntu/home/me` | `/home/me` |
| to-wsl, caller gitbash | `/c/Users/me/repo` | `/mnt/c/Users/me/repo` |
| to-wsl, caller gitbash | `/c` | `/mnt/c` |
| to-wsl, caller gitbash | `/mnt/c/Users/me` | `/mnt/c/Users/me` |
| to-wsl, caller gitbash | `wsl:/home/me/repo` | `/home/me/repo` |
| to-wsl, caller gitbash | `src\main.c` | `src/main.c` |
| to-wsl, caller wsl | `/home/me//repo/` | `/home/me/repo` |
| to-wsl, caller wsl | `C:\Users\me` | `/mnt/c/Users/me` |
| to-wsl, `--mnt-root /win/` | `E:\x` | `/win/e/x` |
| to-wsl, caller win | `\\wsl.localhost\Debian\home\me` | refuse (distro Debian, executor Ubuntu) |
| to-wsl, caller win | `\\server\share\x` | refuse (network share) |
| to-wsl, caller win | `\\?\UNC\server\share` | refuse (network share) |
| to-wsl, caller win | `\\?\UNC\wsl.localhost\Ubuntu\home\me\proj` | `/home/me/proj` |
| to-wsl, caller win | `\\?\UNC\wsl$\Ubuntu\home\me` | `/home/me` |
| to-wsl, caller gitbash | `//?/UNC/WSL.LOCALHOST/ubuntu/tmp` | `/tmp` |
| to-wsl, caller win | `\\?\UNC\wsl.localhost\Debian\x` | refuse (distro Debian, executor Ubuntu) |
| to-wsl, caller win | `\\.\pipe\x` | refuse (device) |
| to-wsl, caller win | `C:relative` | refuse (drive-relative) |
| to-wsl, caller win | `/home/me` | refuse (POSIX path from a Windows caller) |
| to-wsl, caller gitbash | `/tmp/x` | refuse (Git Bash-only path) |
| to-wsl, caller gitbash | `/home/me` | refuse (ambiguous: use `wsl:/home/me`) |
| to-wsl, any | `` (empty) | refuse |
| to-win | `/mnt/c/Users/me/repo` | `C:\Users\me\repo` |
| to-win | `/mnt/c` | `C:\` |
| to-win | `/mnt/d/x y/z.txt` | `D:\x y\z.txt` |
| to-win | `/home/me/repo` | `\\wsl.localhost\Ubuntu\home\me\repo` |
| to-win | `/` | `\\wsl.localhost\Ubuntu\` |
| to-win | `/mnt/wsl/x` | `\\wsl.localhost\Ubuntu\mnt\wsl\x` |
| to-win | `/mnt/cc/x` | `\\wsl.localhost\Ubuntu\mnt\cc\x` |
| to-win `--mixed` | `/mnt/c/Users/me` | `C:/Users/me` |
| to-win `--mixed` | `/home/me` | `//wsl.localhost/Ubuntu/home/me` |
| to-win | `/home/me/a:b` | refuse (not representable) |
| to-win | `/home/me/a\b` | refuse (not representable) |
| to-win | `relative/x` | refuse (relative) |
| to-gitbash | `/mnt/c/Users/me` | `/c/Users/me` |
| to-gitbash | `/home/me/repo` | `//wsl.localhost/Ubuntu/home/me/repo` |
| to-gitbash | `C:\Users\me` | `/c/Users/me` |

`common.sh` wraps these for scripts: `cx_path_in VALUE` maps every user-supplied path option
(`to-wsl`, caller from `CX_CALLER`, exit 42 on refusal), and `cx_host_path WSLPATH` prints the
caller-side form for machine output (`to-win` when `CX_CALLER=gitbash`, else nothing). Every path
field in machine output has a `host_path` sibling when the caller is Git Bash (`null` when
`to-win` refuses).

### 7.3 Forwarding protocol (`forward-wsl.sh`, Git Bash side, pure bash)

**Step 0, in every `cx-*` script** (`cx_forward_if_needed CMD "$@"`, after `--help` and
`--version` were answered locally):

0a. `cx_cloud_gate` (before host detection, and in `cx-doctor` after `--login-help` too):
   `cx_session` is `cloud`, or `byoc` without option `exec_host=local` (environment, else the
   lite reader on Git Bash, else the loaded options) → the note `<prog>: cloud session (<kind>):
   the executors and their logins are in WSL on your computer; run this in a local desktop
   session, a WSL terminal or a Work locally project thread`, one `CX_SIGNAL HOST_UNSUPPORTED`
   (the constant reason; the detail stays in the note, §4.2) and exit 43. Nothing is probed,
   installed or forwarded and `wsl.exe` is never tried. `cx-doctor` prints its header, ✗ D30 and
   the summary first (on stderr with `--json`, so stdout stays empty). A Phase 2 workflow treats
   43 like a pool failure and runs the task in the Claude pool.
1. `cx_detect` first. Host `wsl`, `linux`, `macos`, `docker` → return (run locally); with
   `exec_host=wsl` on a non-WSL Linux → exit 43. Host `cygwin` or `unknown` → exit 43.
2. Host `gitbash` always continues at step 3, whatever `CX_FORWARDED` holds: a value leaked
   into a Git Bash environment must never make a `cx-*` command run locally there (no python,
   no executors). Step 0 never reads `CX_FORWARDED`; `wsl-entry.sh` is its only setter, and only
   WSL-side readers use it (D14–D19, D25, §7.6).
3. Host `gitbash`: `exec_host` = env `CLAUDE_PLUGIN_OPTION_EXEC_HOST`, else `cx_opt_lite`
   on the Windows-side settings file, else `auto`. `local` → exit 43 (Git Bash cannot run the
   executors: ghcp needs `setsid`, agy hangs headless on Windows). `auto` or `wsl` →
   `exec bash "<root>/scripts/host/forward-wsl.sh" CMD "$@"`.

The Windows-side settings file is `$CLAUDE_CONFIG_DIR/settings.json` when set, else
`$(cygpath -u "$USERPROFILE")/.claude/settings.json`, else `$HOME/.claude/settings.json`.

**`forward-wsl.sh CMD [ARG…]`:**
1. CMD must be one of `cx-doctor cx-init cx-wsl cx-run cx-job cx-fanout cx-gate`, else exit 1.
2. Distro: env `CLAUDE_PLUGIN_OPTION_WSL_DISTRO`, else `cx_opt_lite wsl_distro`, else `auto`.
   `auto` → `D_ARGS=()`: wsl.exe uses its default distribution and the WSL side reports the
   name (`CX_FORWARD.distro`). Any other value must match `^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$`,
   else note + exit 40, and gives `D_ARGS=(-d "$DISTRO")`. When the Git Bash side itself needs
   the name (W2/W4, `cx_host_path`), it takes it from the `*` row of `wsl.exe -l -v` and exports
   it as `CX_WSL_DISTRO`.
3. `wsl.exe` on PATH, else exit 40; `cygpath` on PATH, else exit 43.
4. `FWD=$(mktemp -d "${TMPDIR:-/tmp}/cx-fwd.XXXXXXXX")`, removed by an EXIT trap;
   `FWD_WIN=$(cygpath -w -l "$FWD")`. Every Windows path the forwarder emits (`FWD_WIN`,
   `cwd_win`, `win_settings`, `CX_STAGE_WIN`) is produced with `cygpath -w -l` (long form):
   `%TEMP%` often holds 8.3 short names (`C:\Users\JOHNSM~1\…`) that DrvFs may not resolve.
5. Transport files (written as bytes, never re-quoted, never path-converted):
   - `argv`: `printf '%s\0' "$@"` — every argument NUL-terminated, exactly as received (empty
     arguments, spaces, quotes, `$`, backslashes, newlines and non-ASCII survive). Zero
     arguments → an empty file.
   - `env`: `printf '%s=%s\0' NAME "${!NAME}"` for each allowlisted variable that is set.
     Allowlist: `CX_WORKER`, `CX_DEBUG`, `NO_COLOR`, `CX_SLOT_WAIT_SECS` (the pool-slot wait,
     §15.3, so a forwarded call waits like a local one), and `CLAUDE_PLUGIN_OPTION_<UPPER>` for
     the 24 options of §5.1 (names taken from `CX_OPT_DEFAULTS`). Nothing else crosses: not PATH,
     HOME, TMPDIR, tokens, `GH_TOKEN`, `COPILOT_*`, `GHCP_*`, `ANTHROPIC_*`, `CX_FORWARDED`.
   - `meta`: LF-terminated `key=value` lines: `v=1`, `cmd=<CMD>`, `version=<CX_VERSION>`,
     `caller=gitbash`, `distro=<auto or the name>`, `cwd_win=<cygpath -w -l "$PWD">`,
     `win_settings=<cygpath -w -l of the Windows-side settings file, or empty when it does not
     exist>`, `installed=0|1`. A value containing CR or LF → exit 42 (cwd) or the key is left
     empty (settings).
6. Invoke wsl.exe as a BACKGROUND child and wait for it. Not `exec`, so the traps run; not a
   foreground child, because bash runs a trapped signal's handler only after the foreground
   child exits, so a cancel would otherwise do nothing until wsl.exe ends:

   ```bash
   exec 3<&0                                   # the caller's stdin; a plain `cmd &` would get /dev/null
   exec 4> >(tee "$FWD/wsl.err" >&2); TPID=$!  # stderr passthrough plus a copy
   WSL_UTF8=1 MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' CX_FWD_WIN="$FWD_WIN" WSLENV=CX_FWD_WIN \
     wsl.exe "${D_ARGS[@]+"${D_ARGS[@]}"}" --cd '~' --exec /bin/bash --noprofile --norc \
       ".conductor/runtime/$CX_VERSION/scripts/host/wsl-entry.sh" <&3 2>&4 &
   WPID=$!
   while :; do wait "$WPID"; rc=$?; [ "$rc" -gt 128 ] && kill -0 "$WPID" 2>/dev/null || break; done
   exec 4>&-; wait "$TPID" 2>/dev/null         # let tee drain
   ```

   The loop retries `wait` while it was interrupted (rc > 128) and wsl.exe is still alive.
   wsl.exe's command line carries only the validated distro, `~`, fixed paths and the version
   (digits and dots): nothing the user typed, so Windows command-line quoting cannot change an
   argument. `--exec` avoids the default shell's re-parse; `--noprofile --norc` avoids rc files
   (Ubuntu's `.bashrc` returns early for non-interactive shells, so its PATH would be partial
   anyway; PATH comes from the host record, §7.6). The runtime is addressed relative to the
   Linux home, so the Windows side never needs to know it. stdin reaches the child through
   fd 3; stdout is inherited and never decoded or altered; stderr is passed through and also
   copied to `wsl.err`.
7. INT/TERM/HUP trap: (a) when `$FWD/pgid` exists and holds only digits (the Linux pid of the
   target, which leads its own process group, §7.4 step 8), run `MSYS_NO_PATHCONV=1
   WSL_UTF8=1 cx_timeout 10 wsl.exe "${D_ARGS[@]+"${D_ARGS[@]}"}" --exec /bin/kill -TERM --
   "-$pid"`, because killing wsl.exe does not stop the Linux process; (b) TERM the wsl.exe
   child and poll up to 5 s; (c) exit 130 with `CX_SIGNAL CANCELLED`. Work started detached
   inside WSL (Phase 2 jobs, `setsid`) is in its own session there and survives (§15.5).
   wsl-entry.sh's watchdog (§7.4 step 8) is the second layer, for a forwarder that is KILLed
   before its trap can run.
8. Classification; every failure has exactly one `CX_SIGNAL` owner:
   - `$FWD/started` exists (written by wsl-entry.sh):
     - rc 1 and the last 5 non-empty lines of `cx_decode_wsl < wsl.err` contain a wsl.exe
       message (the language-independent error code `Wsl/[A-Za-z0-9_/]+`, or the English
       `instance has terminated` [docs-only]) → note with that line, exit 40 `FORWARD_FAILED`,
       signal by the forwarder (the WSL VM died under the command; a usage error of the
       forwarded command never contains such a line).
     - otherwise → exit with `rc` unchanged. The forwarded command, or wsl-entry.sh for its own
       41/42, printed the `CX_*` lines.
   - No `started`, `rc` = 127, and the decoded `wsl.err` mentions `wsl-entry.sh` → runtime
     missing: unless `CX_NO_AUTO_INSTALL=1` or this is already the retry, run the bootstrap
     install (§7.5) and repeat steps 5–8 once with `installed=1`; otherwise exit 41, signal by
     the forwarder (`retry`: `cx-doctor --install-runtime`).
   - Otherwise (including wsl-entry.sh's step-1 failure, which cannot write `started`) → note
     `forward-wsl: wsl.exe failed (rc N): <first non-empty line of cx_decode_wsl < wsl.err>`
     and exit 40, signal by the forwarder.
9. `CX_DEBUG=1` adds a note with the wsl.exe argv (`printf '%q '`) and keeps `$FWD` (its path
   in a note) instead of deleting it, so `argv`, `env` and `meta` can be inspected (P13, P14).

Encoding: `WSL_UTF8=1` asks wsl.exe for UTF-8 messages [docs-only]; `cx_decode_wsl` (§4.4)
decodes UTF-16LE anyway when it sees it, and strips CRs. Only wsl.exe's own messages are ever
decoded (step 8 and `wsl.exe -l -v`/`-l -q` in §8.6); the forwarded command's output is passed
through byte for byte.

Exit codes: wsl.exe returns the Linux exit status (0–255), so 0–5, 10–16, 20–28, 41–44, 75, 130
and every status `cx-wsl` passes through cross unchanged. The forwarder produces 40 (no
`started`, or a wsl.exe message after it) and its own 41 (runtime missing and not installed);
wsl-entry.sh produces 41 (meta or version mismatch) and 42 after `started` and emits their
signals; a wsl.exe-internal failure (e.g. `-1` → 255) without `started` becomes 40.

### 7.4 `wsl-entry.sh` (WSL side)

1. `RT` = the runtime root (`…/runtime/<version>`), from `BASH_SOURCE`. Map `CX_FWD_WIN` with
   `pathmap.sh to-wsl --caller win`; it must be a directory holding `meta`, `argv`, `env`, else
   print a note and exit 40. No `started` can be written there, so it emits no `CX_SIGNAL`: the
   Git Bash side emits the one signal (§7.3 step 8).
2. Write `$FWD/started` (`$$`). From here on wsl-entry.sh emits its own `CX_SIGNAL` for each of
   its failures (python3 is available on the executor host).
3. Read `meta`; `v` must be `1` and `version` must equal the runtime's `CX_VERSION`, else
   `CX_SIGNAL RUNTIME_MISSING` and exit 41.
4. Environment, built from scratch for the target (`env -i` plus the list below):
   - kept from what wsl.exe provides: `HOME USER LOGNAME SHELL WSL_DISTRO_NAME WSL_INTEROP TERM
     LANG XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS DISPLAY WAYLAND_DISPLAY`. The last four are how
     Copilot's keychain service (`copilot-cli`), agy's system keyring and gh's keyring are
     reached; without them those CLIs look logged out only when forwarded. When
     `XDG_RUNTIME_DIR` is unset and `/run/user/$(id -u)` is a directory, it is exported; when
     `DBUS_SESSION_BUS_ADDRESS` is unset and `/run/user/$(id -u)/bus` is a socket, it is exported
     as `unix:path=/run/user/<uid>/bus`; an `SSH_AUTH_SOCK` that wsl.exe passed on is kept when it
     names a live socket (rc files that start an agent never run here, so D5 warns about SSH
     remotes);
   - `PATH` = the one line in `$CX_HOME/hosts/<hostkey>.path` when it exists, else
     `$HOME/.local/bin:$HOME/.npm-global/bin:<newest $HOME/.nvm/versions/node/*/bin>:$HOME/.bun/bin:$HOME/.cargo/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`;
     in both cases every entry under `/mnt/` is dropped (WSL appends the Windows PATH, which
     would find Windows binaries). `LANG` defaults to `C.UTF-8`;
   - the auto-update pins `COPILOT_AUTO_UPDATE=false GROK_DISABLE_AUTOUPDATER=1
     AGY_CLI_DISABLE_AUTO_UPDATE=true` (§5.4), for every forwarded command;
   - each `env` record whose name passes the allowlist again (others dropped with a note);
   - `CX_FORWARDED=1`, `CX_CALLER=gitbash`, `CX_CALLER_CWD_WIN=<cwd_win>`,
     `CX_WIN_SETTINGS=<win_settings mapped to-wsl, or empty>`. `CX_FWD_WIN` and `WSLENV` are not
     passed on.
5. cwd: map `cwd_win` (`to-wsl --caller win`). A directory → `cd` there. Otherwise, for
   `cx-init cx-run cx-fanout cx-gate cx-wsl` → note (open the project from a drive path, or work
   on a repo that lives in WSL from a WSL terminal; never a picker-opened `\\wsl.localhost`
   desktop session, which runs without plugins, §1.5) + `CX_SIGNAL PATH_UNMAPPABLE`, exit 42
   (`cx-wsl` must never run git or a shell step in `$HOME` by accident); for `cx-doctor cx-job`
   → `cd "$HOME"`, export `CX_CALLER_CWD_UNMAPPED=1`.
6. `mapfile -d '' -t ARGV < "$FWD/argv"` (bash ≥ 4.4; empty records preserved).
7. Emit `CX_FORWARD` (§4.3; `distro` = `WSL_DISTRO_NAME`; a note instead when python3 is
   missing).
8. Run the target and stay its parent (not `exec`). Which process group it gets depends on the
   terminal: field 5 (`pgrp`) and field 8 (`tpgid`, the foreground group of the controlling
   terminal, `-1` without one) of `/proc/$$/stat`.
   - No controlling terminal, or wsl-entry.sh is not in its foreground group (the Claude Bash
     tool, a background call): the target leads its own process group, so a cancel stops
     everything it started:

     ```bash
     exec 3<&0
     set -m
     env -i "${KEEP[@]}" /bin/bash "$RT/scripts/$CMD.sh" "${ARGV[@]+"${ARGV[@]}"}" <&3 & tpid=$!
     set +m
     printf '%s\n' "$tpid" > "$FWD/pgid.tmp" && mv -f "$FWD/pgid.tmp" "$FWD/pgid"
     ```

     With `set -m` the background job leads its own process group (pgid = `tpid`) and its stdin
     is the explicit `<&3`, not `/dev/null` [measured 2026-11-01: bash 5 without a tty].
     wsl-entry.sh traps INT/TERM/HUP and forwards TERM to `-$tpid`, then waits for `tpid`
     (retrying while interrupted, as in §7.3 step 6).
   - `tpgid` = `pgrp` (wsl.exe attached to a console gives the Linux side a pty, and wsl-entry.sh
     leads its foreground group [unverified through wsl.exe, §20 item 39]): a separate group would be a background group of that
     terminal, and a target that reads the tty or changes its settings (`gh auth login`, a
     credential prompt, `less`, `cx-wsl bash`) would stop on SIGTTIN/SIGTTOU while wsl-entry.sh
     waits forever [measured 2026-11-01 under a pty]. The target therefore runs in the
     FOREGROUND of wsl-entry.sh's own group, with the inherited stdin, and `pgid` holds that
     group (`pgrp`): the terminal's Ctrl-C reaches the target directly, and the Git Bash side's
     group TERM (§7.3 step 7) reaches it together with wsl-entry.sh.

   In both cases a watchdog subshell polls every 2 s: when wsl-entry.sh's parent changed (field 4
   of `/proc/$$/stat` ≠ the `$PPID` recorded at start, i.e. the wsl.exe relay is gone) it sends
   TERM to the recorded group and KILL 5 s later (ignoring TERM itself in between, since in the
   terminal case it is a member of that group); it exits when wsl-entry.sh (or the background
   target) is gone. wsl-entry.sh then stops the watchdog and exits with the target's status.
   The suite runs a forwarded `cx-wsl bash -c 'read -r x; echo "got:$x"'` under a pty (P16).

### 7.5 Runtime copy (`install-runtime.sh`)

```
install-runtime.sh [--from DIR]          # normal mode (WSL / Linux)
bash -s < install-runtime.sh             # bootstrap mode: needs CX_STAGE_WIN
```

- Source: `--from DIR`, default the plugin root that contains the script; in bootstrap mode
  `wslpath -u "$CX_STAGE_WIN"` (fallback: `X:\rest` → `/mnt/x/rest`).
  Bootstrap mode is recognized by an empty `BASH_SOURCE[0]` captured at FILE scope (under
  `bash -s` the top-level array is empty, while inside a function `BASH_SOURCE[0]` is the literal
  `main`, so a file named `main` in the WSL home would otherwise look like the script) [measured
  2026-11-01].
- Version: the `CX_VERSION=` line of `<src>/scripts/lib/common.sh`, which must match
  `^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.]+)?$`. Destination
  `${CX_HOME:-$HOME/.conductor}/runtime/<version>`.
- Copy `.claude-plugin bin scripts hooks worker-shims templates` (never tests, docs, skills or
  commands) into `runtime/.tmp.<pid>`; `sed -i 's/\r$//'` every regular file and count the files
  it changed; refuse with exit 44 if any file still contains `\r`; `chmod 0755` `bin/*`,
  `scripts/**/*.sh`, `scripts/lib/*.py`, `hooks/*.sh`, `worker-shims/*`; write `RUNTIME_STAMP`
  (`version=`, `installed_at=` UTC ISO-8601, `source=`, `sha256=` over the sorted relative paths
  and contents).
- Concurrency: two first-use forwarded calls, or two Claude sessions, can install the same
  version at once. Everything from reading the installed `RUNTIME_STAMP` to the `current` swap
  runs while holding `flock -w 60 "$CX_HOME/runtime/.install.lock"`, and the stamp is re-read
  under the lock: of two concurrent installers of one source, one reports `changed: true` and
  the other `changed: false`, leaving one clean tree. Lock timeout → exit 2.
- Same `sha256` already installed → drop the tmp copy, `changed=false`. Otherwise, with `mv -T`
  for every directory move (a plain `mv tmp runtime/<version>` onto an existing directory
  would move the copy INSIDE it): `mv -T runtime/<version> runtime/.old.<pid>` when present,
  `mv -T runtime/.tmp.<pid> runtime/<version>`, delete the old copy (running bash processes keep
  their open inodes), then `ln -sfn <version> current.tmp.<pid> && mv -T current.tmp.<pid>
  current`.
- Emit `CX_RUNTIME`; exit 0, 1, 2 or 44.
- Forwarded calls always use the default `CX_HOME` (`$HOME/.conductor`): the variable is not on
  the forwarder allowlist, and the forwarder addresses the runtime as `.conductor/runtime/<version>`
  relative to the Linux home.
- Bootstrap from Git Bash (forward-wsl.sh step 8, or `cx-doctor --install-runtime` on Git Bash):
  copy the six directories of the Windows-side plugin root to `$FWD/stage`, strip `\r$` there
  with `sed -i` (defence in depth for stray CRs in non-executed files; a copy whose own
  `forward-wsl.sh` is CRLF never gets this far, and the session-start canary reports it,
  §10.2), then `CX_STAGE_WIN="$(cygpath -w -l "$FWD/stage")" WSLENV=CX_STAGE_WIN WSL_UTF8=1
  MSYS_NO_PATHCONV=1 MSYS2_ARG_CONV_EXCL='*' wsl.exe "${D_ARGS[@]+"${D_ARGS[@]}"}" --cd '~'
  --exec /bin/bash --noprofile --norc -s < "$FWD/stage/scripts/host/install-runtime.sh"`: the
  installer's text arrives on stdin, so no path crosses the command line.
- On the executor host, `cx-doctor --install-runtime` installs from the installed plugin copy.
  From Phase 2, `cx-run` and `cx-job` install the runtime when `runtime/<version>/RUNTIME_STAMP`
  is missing and run adapters, worker shims and job runners from the runtime copy, so a plugin
  update never swaps files under a running job.

### 7.6 Host record (`$CX_HOME/hosts/<hostkey>.{json,path}`)

Written by `cx-doctor` on the executor host (never on Git Bash; skipped with `--no-record`),
atomically (tmp + `mv`), through `cxlib.py host-record`:

```json
{"version": 1, "recorded_at": "2026-11-01T10:00:00Z", "plugin_version": "0.1.0",
 "host": "wsl", "hostkey": "wsl-Ubuntu", "distro": "Ubuntu", "home": "/home/me",
 "path": "/home/me/.local/bin:/home/me/.npm-global/bin:/usr/local/bin:/usr/bin:/bin",
 "path_source": "interactive",
 "bin": {"claude": "/home/me/.local/bin/claude", "copilot": "/home/me/.npm-global/bin/copilot",
         "grok": "...", "agy": "...", "gh": "/usr/bin/gh", "git": "/usr/bin/git", "python3": "/usr/bin/python3",
         "ghcp_delegate": "<ghcp installPath>/bin/ghcp-delegate", "ghcp_job": "...", "ghcp_handoff": "...",
         "ghcp_ci_debug": "...", "ghcp_models": "...", "ghcp_cloud": "...",
         "agy_delegate": "<antigravity installPath>/bin/agy-delegate", "agy_handoff": "...",
         "agy_job": "...", "agy_media": "..."},
 "versions": {"claude": "2.1.316", "copilot": "1.0.105", "grok": "1.0.70", "agy": "1.4.12", "gh": "2.89.0"},
 "copilot_home": null,
 "copilot_token_env": null,
 "logins": {"copilot": {"direct": true, "direct_at": "2026-11-01T10:00:00Z", "forwarded": null, "forwarded_at": null},
            "claude": {}, "grok": {}, "agy": {}, "gh": {}},
 "plugins": {"ghcp@ghcp-for-claude-code": {"version": "0.1.0", "enabled": true, "scope": "user", "install_path": "..."}}}
```

- Every `bin` value is an absolute path or `null`. CLIs resolve as: copilot =
  `GHCP_COPILOT_BIN` (only if it is an executable file), else the first `copilot` on PATH, else
  `${XDG_DATA_HOME:-$HOME/.local/share}/gh/copilot/copilot` (ghcp's order); the others = the
  first executable of that name on PATH. On WSL the walk skips every PATH entry in a drive
  directory of the automount root (`<root><letter>/`, and `/mnt/<letter>/`), never the whole
  root: with `[automount] root = /` (for `/c/...` paths) every Linux path starts with the root,
  and `/mnt/data` or `/mnt/wsl` are Linux mounts. WSL appends the Windows PATH, and Windows npm installs leave
  extensionless POSIX shims (`%APPDATA%\npm\copilot`, `claude`) that are executable on DrvFs.
  A CLI found only there resolves to `null` and its D8–D12 line names the Windows-side path
  ("install it in WSL"); a `GHCP_COPILOT_BIN` there is ignored with a D9 warning; and
  `cxlib.py wsl-resolve` (§7.7) refuses such a path even from an old record. Sibling wrappers come only from `installed_plugins.json`
  (`<installPath>/bin/<name>`), never from PATH: the entry with `"scope": "user"` first (a
  project-scoped install may belong to another project), else the first entry. Every reader
  checks `-x` at use time; on a miss (a sibling update moves `installPath`) it re-resolves from
  `installed_plugins.json` once, rewrites the record when it can, and only then reports 13.
- `path`: ordered and de-duplicated: the directory of each resolved CLI (claude, copilot, grok,
  agy, gh, git, python3, node), `$HOME/.local/bin`, `$HOME/.npm-global/bin`, `$HOME/.bun/bin`,
  `$HOME/.cargo/bin`, `/home/linuxbrew/.linuxbrew/bin`, `/snap/bin`,
  `/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin` (directories that exist).
  Never a `/mnt/…` entry, a relative entry, a plugin `bin/` directory or `worker-shims`.
  `<hostkey>.path` holds the same value on one line for pure-bash readers.
- `path_source`: `interactive` when a non-forwarded run wrote `path`, `forwarded` when a
  forwarded run (`CX_FORWARDED=1`, whose PATH is §7.4's fallback) did. A forwarded run never
  replaces an `interactive` `path` or a `bin` entry an interactive run recorded; it only fills
  missing values. With no record, or `path_source: forwarded`, a forwarded doctor adds to D2 the
  note "run ~/.conductor/runtime/current/bin/cx-doctor once in a WSL terminal (or /conductor:doctor in a WSL Claude Code
  session) so the record captures your interactive PATH". The runtime copy's doctor is named
  because a plain WSL terminal has no plugin `bin/` on its PATH (Claude Code adds it only to its
  own Bash tool), and the runtime exists once any call was forwarded.
- `logins`: per CLI (`claude copilot grok agy gh`), `direct` is the last non-forwarded login
  result and `forwarded` the last forwarded one (`true`, `false` or `null` = not probed), with
  timestamps; each doctor run updates only its own side. D15–D19 compare them (§8.3).
- `copilot_home`: the `COPILOT_HOME` value at record time, or `null`; Phase 2 adapters unset
  `COPILOT_HOME` only when it differs from this.
- `copilot_token_env`: `GH_TOKEN` or `GITHUB_TOKEN` when D16 found that Copilot is logged in
  only through that variable, else `null`; the Phase 2 Copilot adapter then keeps that one
  variable (§15.2).
- A record older than 7 days or from another plugin version is stale: readers still use it, and
  Phase 2 `cx-run` refreshes it with `cx-doctor --record-only` (resolution and `--version` only).

### 7.7 `cx-wsl` (Phase 1 passthrough to one WSL-side tool)

```
cx-wsl TOOL [ARG…]
cx-wsl -h|--help | --version
```

Purpose: let the Windows app (Git Bash) delegate in Phase 1, before `cx-run` lands, without
installing anything on the Windows side and without raw `wsl.exe` command lines (Windows
quoting, MSYS path conversion, no plugin `bin/` on the WSL PATH). It stays useful afterwards for
`gh` and `git`. On Git Bash it forwards like every `cx-*` (§7.3 step 0; `cx-wsl` is in the
forwarder's CMD allowlist), reusing the NUL-separated argv, the env allowlist, cwd mapping,
stdin passthrough, exit propagation and cancellation of §7.3–§7.4. On WSL or Linux it runs
locally, which is equivalent to calling the tool with its §12.2 prefix.

- TOOL allowlist, each resolved to an absolute path from the host record `bin` (§7.6; no PATH
  lookup): `ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models ghcp-cloud` →
  `bin.ghcp_*` (`ghcp-cloud` is the Copilot cloud agent through `gh agent-task`, U7: an
  executor's own cloud, reached from a local session, §12.2 step 5);
  `agy-delegate agy-job` → `bin.agy_*`; `agy grok gh git` → `bin.<name>`; `bash` →
  `/bin/bash` (for the shell steps of §12.2, run as `cx-wsl bash -s < FILE`, and one-line
  commands as `cx-wsl bash -c '…'`). Anything else → exit 1 (`cx-wsl: not allowed: <tool>`).
  Left out on purpose: `copilot` (always through ghcp), `claude`, `agy-handoff` and `agy-media`
  (both always pass `--yolo`, §0.3), and `cx-*` (call them directly; they forward themselves).
- No host record, or the entry is `null` or not executable after the §7.6 re-resolve →
  `CX_SIGNAL CLI_MISSING`, exit 13, `retry`: `cx-doctor (from a Claude Code session; in a WSL
  terminal, where cx-doctor is not on PATH: ~/.conductor/runtime/current/bin/cx-doctor,
  created once by cx-doctor --install-runtime)`; the note names `/conductor:doctor` in a Claude
  Code session in WSL and the runtime copy (a WSL-only user has none until
  `/conductor:doctor --install-runtime` or a first forwarded call; a forwarded doctor also
  writes a record, from its fallback PATH, §7.6).
- Environment: `PATH` = the directories of the resolved sibling wrappers, then the conductor's
  own `bin/` (`$RT/bin` when forwarded, else the plugin root's), then the record's `path` (so a `cx-wsl bash -s` step sees the same commands as a Bash tool in a WSL
  Claude Code session). Per-tool prefixes, identical to §12.2: `ghcp-*` → unset `COPILOT_MODEL
  COPILOT_ALLOW_ALL COPILOT_AUTO_TIER COPILOT_PROVIDER_BASE_URL`, set `CX_WORKER=1
  COPILOT_AUTO_UPDATE=false` (plus `GHCP_COPILOT_BIN`, when unset, from the record; and
  `COPILOT_GITHUB_TOKEN`, when unset, from `$CX_HOME/secrets/copilot-token` if that is a
  regular file, not a symlink, owned by the user with mode 0600: the keyring route of §8.5 for
  Copilot logins that `wsl.exe` cannot reach; any other file → a note and no export; never for
  `bash` or another tool, so a shell step through `cx-wsl bash -s` does not get it [the variable
  is docs-only, §20 item 62]); `agy-*`, `agy` → unset `GEMINI_API_KEY GOOGLE_API_KEY`, set
  `CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true`; `grok` → unset `XAI_API_KEY GROK_SANDBOX`,
  set `CX_WORKER=1 GROK_DISABLE_AUTOUPDATER=1 GROK_CLAUDE_{HOOKS,SKILLS,MCPS,RULES,AGENTS}_ENABLED=false`;
  `gh`, `git`, `bash`: unchanged (a shell step carries its own prefixes).
- Pool slot (Phase 2, §15.3; this closes the passthrough bypass): before the `exec`, an executor
  call takes a slot of its pool with `cx_slot_take` and keeps the descriptor open across the
  `exec`, so the tool and every child that inherits it hold the slot until they exit (a
  `ghcp-job start` or `agy-job start` detaches a job that keeps it for the job's life). Pools by
  call: `copilot` for `ghcp-delegate` (not `--print-command`), `ghcp-handoff`, `ghcp-ci-debug`
  and `ghcp-job start`; `agy` for `agy-delegate` (not `--print-command`), `agy-job start`,
  `agy --new-project …` and every other `agy` call except `--version`/`-v`/`--help`/`help`,
  `models` and the zero-quota `-p /usage|/model|/config` probes (no `--new-project`); `grok` for
  every `grok` call except `--version`/`-v`/`--help`/`help`/`version`, `models`, `usage`,
  `inspect`, `login`, `logout`. An `agy` call also holds the agy launch lock for the whole call
  (it cannot see agy's `init` event). Free forms take nothing: `-h`/`--help`/`--version` as the
  first argument, the other `ghcp-job`/`agy-job` subcommands (status, result, list, cancel),
  `ghcp-models` (a free catalog probe) and `ghcp-cloud` (the agent runs on GitHub; no local
  executor process); `gh`, `git` and `bash` take none (a hand step's executor call goes through
  `cx-wsl grok` or `cx-wsl ghcp-ci-debug`, which take theirs). An `agy` call while agy dispatch
  is paused (`$CX_HOME/state/agy-paused`) exits 28 once it has its slot.
  A busy pool prints one `cx-wsl:` note and waits up to `CX_SLOT_WAIT_SECS` (default 600,
  forwarded from Git Bash, §7.3 step 5), then one note and `CX_SIGNAL NO_CAPACITY`, exit 28;
  a cap of 0 exits 28 at once. A forwarded call takes the WSL side's slots (`$CX_HOME` there).
- Run: `exec env <prefix> "<abs tool>" "$@"`. The tool's stdout, stderr and exit status are the
  result; `cx-wsl` adds no `CX_*` line to them (§4.1 exception). Its own failures: 1 (usage,
  not allowed), 2 (a `bash -s` step could not be buffered, or the lock directory is unusable),
  13 (tool missing), 28 (no pool slot), and from forwarding 40–42 (an unmappable cwd is 42,
  §7.4 step 5).
- `bash -s` with a step on stdin that is not a terminal: the step is buffered in a temporary
  file (unlinked once opened), a CR before each LF is stripped, and when anything was stripped
  one `cx-wsl:` note says so on stderr (the only text cx-wsl ever adds). A step written on the
  Windows side may come out CRLF; with the CRs, `. "$HOME/.conductor/out/t1/vars.sh"` would
  fail, `WT`, `TOP` and `BASE` would stay empty and `git -C "$WT" …` would run in the cwd, the
  user's main checkout. A terminal on stdin is passed through untouched.
- No argument rewriting: arguments arrive byte for byte. Paths in them must be WSL paths
  (`/home/me/…`); a `C:\…` or `/c/…` argument reaches the tool unchanged and is the caller's
  error (`wsl:` is a `cx-*` path-option convention, §7.2 T2, not stripped here). Git Bash does
  not convert arguments passed to a bash script, and the argv crosses as a NUL file.
- Long calls run as one background Bash call (§12.2); cancelling that call reaches the Linux
  process group (§7.3 step 7).

## 8. `cx-doctor`

### 8.1 CLI

```
cx-doctor [--pools] [--json] [--no-record]
cx-doctor --host wsl|docker [same flags]
cx-doctor --windows                         # Git Bash only: Windows-side checks, no forwarding
cx-doctor --login-help [copilot|grok|agy|gh|claude] [--host wsl|docker]
cx-doctor --install-runtime
cx-doctor --record-only
cx-doctor --pools --set-copilot-mtd <credits>
cx-doctor --pools --agy-usage
cx-doctor -h|--help | --version
```

| Flag | Behaviour |
|---|---|
| (none) | On the executor host: every D check, writes the host record. On Git Bash: W1–W7, W10 and W11 locally, then forwards `cx-doctor <same flags> --windows-report <win path of the W results>` into WSL, which merges the W lines under a "Windows (Git Bash)" heading. If forwarding fails, Git Bash prints its W lines in plain text (no python), adds ✗ W8, and exits 40/41 |
| `--pools` | Adds §8.4 and the `CX_POOLS` line |
| `--agy-usage` | With `--pools`: also run `agy -p /usage` (documented as zero-quota but [docs-only]; opt-in until §20 item 5 is settled) |
| `--json` | The report as one JSON document on stdout (§8.7) instead of text. On Git Bash the forwarder's stderr is held back while the WSL side runs; when forwarding fails (40/41) no document exists, so stdout stays EMPTY, the W lines and ✗ W8 go to stderr in plain text, then the forwarder's notes and its `CX_SIGNAL` (still the last line). Not with `--windows` (exit 1: that report is plain text, and Git Bash runs no python to encode it) |
| `--no-record` | Do not write the host record |
| `--host wsl` | Git Bash: forward without running W checks. WSL: run locally. Other hosts: exit 43 |
| `--host docker` | v1: exit 43 ("Docker host arrives in v1.1"); v1.1: §18.5 |
| `--windows` | Git Bash: W1–W11 only (W8 = forwarder smoke, W9 = forwarded login probes). Elsewhere: prints `! --windows checks only run from Git Bash` and exits 0 |
| `--windows-report FILE` | Internal (set by the Git Bash side; mapped with `cx_path_in`) |
| `--logins-only` | Internal (W9): D15–D19 only, with the forwarded comparison of §8.3; never writes `path` or `bin` into the host record, only its `logins.forwarded` values |
| `--login-help [cli]` | Prints §8.5 for one or every CLI; no probes; runs locally on any host (pure bash), exit 0 |
| `--install-runtime` | §7.5 (Git Bash: bootstrap into WSL; executor host: from the installed plugin) and exit with its code |
| `--record-only` | Resolution and `--version` probes only, writes the host record, prints nothing on success (exit 0, or 2) |
| `--set-copilot-mtd N` | Records the month-to-date Copilot credits you read on GitHub's billing page, with the current time, in `$CX_HOME/pools.json`; implies `--pools` |

Exit: 0 (no ✗), 4 `CHECKS_FAILED`, 1 usage, 40/41 forwarding, 43 host (a cloud session
included: header, ✗ D30, summary, exit 43 before any probe, §7.3 step 0a). The doctor writes
nothing except the host record, `pools.json` (`--set-copilot-mtd`), the runtime copy
(`--install-runtime`), the empty probe directory `$CX_HOME/probe` and temp files.

### 8.2 Output

Text on stdout: a header `conductor doctor <version>: host <host> (<distro> <os_version>,
WSL<n>), caller <caller>, session <kind>` (a forwarded run shows the Git Bash caller's session,
which the Windows report carries as a `meta session` record); a report with caller `gitbash`
from the WSL side adds the line `Fixes run inside WSL, in a WSL terminal (wsl.exe), never in
Git Bash; only the Windows section's fixes run on Windows.` (pasted into Git Bash, a `~/.profile` export
or `claude plugin …` would act on the Windows side); then sections Session, Host,
Runtime, Options, CLIs, Version pins, Logins (free
probes), Sibling plugins, Windows (Git Bash), Pools; one line per check, `  ✓ <text> [<ID>]`,
`  ! <text> [<ID>]`, `  ✗ <text> [<ID>]`, followed by `      fix: <command>` lines for ✗/! that
have a fix, and 6-space-indented info lines; then `Summary: <n> ✓, <n> !, <n> ✗`. Checks are
collected as TSV records (`status<TAB>id<TAB>section<TAB>text<TAB>fix`, with TAB/CR/LF in fields
replaced by spaces) and rendered once by `cxlib.py doctor-render`. stderr: `CX_HOST`, `CX_POOLS`
(with `--pools`), `CX_DOCTOR`, and `CX_SIGNAL CHECKS_FAILED` on exit 4.

Every probe runs under `cx_timeout` with stdin from `/dev/null` and with cwd `$CX_HOME/probe`, a
directory the doctor creates and keeps empty (never a repo, so no CLI loads repo-level config or
MCP servers from the user's cwd). Every agy probe (D11, D18, `-p /usage`) carries the §12.2 agy
prefix `env -u GEMINI_API_KEY -u GOOGLE_API_KEY AGY_CLI_DISABLE_AUTO_UPDATE=true` and every grok
probe (D10, D17) `env -u XAI_API_KEY -u GROK_SANDBOX GROK_DISABLE_AUTOUPDATER=1`: an exported API
key would make a probe sign in (and list models) through the API account the real commands never
use, and an unpinned CLI could update itself mid-check. Without `timeout`, D2 fails and the agy
probes are skipped with `!` (they can hang). The doctor must run outside Claude Code's Bash sandbox (the Copilot probe
fails with exit 16, agy and grok probes with permission errors); `commands/doctor.md` says so
and D16 explains exit 16.

### 8.3 Checks and free probes

| ID | Check | Free probe (exact) | Expected → status |
|---|---|---|---|
| D1 | Host | `scripts/host/detect.sh` | `wsl`, `linux` ✓; `docker` ! (plain Linux host in v1); `macos` ! (untested); `cygwin`/`unknown` ✗. On WSL: the distribution name from `wslpath -w /` → info; from os-release (no `WSL_DISTRO_NAME`, no wslpath name) → ! (the record's hostkey differs from the one forwarded calls use); a non-forwarded run with `CX_HOME` set to anything but `$HOME/.conductor` → ! (forwarded calls ignore `CX_HOME`, §7.5) |
| D2 | Prerequisites | `BASH_VERSINFO`; `python3 -I -V`; `command -v timeout setsid flock sha256sum git`; `git --version` | bash ≥ 4.4, `Python 3.x` ≥ 3.8, each tool present, git ≥ 2.31 (`rev-parse --path-format`) → ✓ each; else ✗; forwarded (`CX_FORWARDED=1`) with no host record or `path_source: forwarded` → info "run ~/.conductor/runtime/current/bin/cx-doctor once in a WSL terminal (or /conductor:doctor in a WSL Claude Code session) so the record captures your interactive PATH" (§7.6) |
| D3 | Plugin files | The INSTALLED plugin copy on this host: `CLAUDE_PLUGIN_ROOT` when set, else the conductor's `installPath` from `installed_plugins.json` (the `scope: "user"` entry first, §7.6); never `cx_root` when it lies under `$CX_HOME/runtime/` (a forwarded doctor runs from the runtime copy, which lacks `skills/` and `commands/`). Presence + exec bits of the shipped list (§13.4); `grep -l $'\r'` over it | all present, executables executable, no CR → ✓; no installed copy on this host (a Windows-only install whose runtime came from Git Bash) → info "plugin files are checked on Windows by W6". CR found → ✗ `CRLF line endings in: <files>` with the fixes below |
| D4 | Runtime copy | `$CX_HOME/runtime/<CX_VERSION>/RUNTIME_STAMP`; the top-level entries of that directory | present with this version ✓; missing ! (`cx-doctor --install-runtime`; the forwarder installs it on first use); entries other than exactly `.claude-plugin bin scripts hooks worker-shims templates` plus `RUNTIME_STAMP` (the §13.4 subset of §7.5) → ! (`cx-doctor --install-runtime`) |
| D5 | Repo location and forwarded git | `git rev-parse --show-toplevel` in cwd; `git config --get remote.origin.url`, `commit.gpgsign` there | under `/mnt/<letter>/` → ! (slow; keep repos on the WSL filesystem), but forwarded from Git Bash → info with W3's wording (slow `/mnt` access; for a repo that lives in WSL use a WSL terminal or `claude remote-control` there, never a desktop session opened on `\\wsl.localhost`, which loads no plugins, H8): from the Windows app a Windows folder is the supported place. Forwarded calls rebuild the environment (§7.4: no shell rc files, so no ssh-agent and no tty for a passphrase): an SSH origin (`git@…:`, `ssh://`) → forwarded without a live `SSH_AUTH_SOCK` ! (pushing `cx/*` fails with `Permission denied (publickey)`; fixes `gh auth setup-git` with an HTTPS remote, or `IdentityAgent`/`IdentityFile` in `~/.ssh/config`), not forwarded on WSL → info; `commit.gpgsign=true` → forwarded ! (Step 3's commit cannot prompt; fix: `commit.gpgsign false` for that repo or a cached passphrase), not forwarded on WSL → info; else no line |
| D6 | Path mapping (WSL) | `wslpath -u 'C:\'` vs `pathmap.sh to-wsl --caller win 'C:\'`; `wslpath -w /` | equal ✓ else ✗ (automount root differs: set `CX_MNT_ROOT` or fix `/etc/wsl.conf`); the `\\wsl.localhost\` vs `\\wsl$\` prefix → info |
| D7 | Options | `cxlib.py options-check` | invalid value or unknown key → ! each; non-default values → info |
| D8 | claude | `timeout -k 5 15 claude --version </dev/null` | `^(\d+\.\d+\.\d+) \(Claude Code\)` ≥ 2.1.316 ✓; lower !; missing ! (only `claude -p` workers need it on this host) |
| D9 | copilot | `COPILOT_AUTO_UPDATE=false NO_COLOR=1 timeout -k 5 15 <copilot> --version </dev/null` | a semver ✓ plus an info line with the version last verified (`CX_VERIFIED_COPILOT`, 1.0.105; never a failure: §5.4); no version !; missing ✗, fix `npm install -g @github/copilot` |
| D10 | grok | `env -u XAI_API_KEY -u GROK_SANDBOX GROK_DISABLE_AUTOUPDATER=1 timeout -k 5 15 grok --version </dev/null` | `grok <semver> (<hash>)` ✓ plus the last-verified info line (`CX_VERIFIED_GROK`, 1.0.70); no version !; missing ✗, fix `npm install -g @xai-official/grok` |
| D11 | agy | `env -u GEMINI_API_KEY -u GOOGLE_API_KEY AGY_CLI_DISABLE_AUTO_UPDATE=true timeout -k 5 10 agy --version </dev/null` | first-line semver ≥ 1.1.12 ✓ plus the last-verified info line (`CX_VERIFIED_AGY`, 1.5.1); 1.1.10–1.1.11 !; < 1.1.10 ✗ (ignores `--model` headless); killed ! (hang); missing ✗ |
| D12 | gh | `timeout -k 5 10 gh --version </dev/null`; `timeout -k 5 10 gh pr edit --help </dev/null` (offline, free) | `gh version X.Y.Z` ✓; missing ✗ (PRs, Copilot review and ghcp-ci-debug need it). The help text mentions `@copilot` → ✓ "can request @copilot reviews"; else ! "gh <X.Y.Z> cannot request @copilot reviews (measured on ≥ `CX_MIN_GH_COPILOT_REVIEW` = 2.89.0); upgrade gh or use the skill's REST fallback" |
| D13 | Sibling wrappers | `installed_plugins.json` → `<installPath>/bin/<name>` (the `scope: "user"` entry first, §7.6) | ghcp: `ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models ghcp-cloud`; antigravity: `agy-delegate agy-handoff agy-job agy-media`; all executable ✓; plugin missing ✗ (`claude plugin install ghcp --marketplace 40chalk/ghcp-for-claude-code` / `claude plugin install antigravity --marketplace yuting0624/antigravity-for-claude-code`: the one-step form adds the marketplace too, §13.2; forwarded, the fix starts with `in a WSL terminal:`) |
| D14 | Auto-update (information only, §5.4) | env `COPILOT_AUTO_UPDATE`, `GROK_DISABLE_AUTOUPDATER`, `AGY_CLI_DISABLE_AUTO_UPDATE`; `cxlib.py toml-get ~/.grok/config.toml cli auto_update` | one info line with the four values: auto-update is the user's choice, every conductor run turns it off for its own run (the worker environment, §15.6) and each lane checks the live `--help` for its flags first. Never a warning, never a fix |
| D15 | claude login | `timeout -k 5 15 claude auth status --json </dev/null` | `"loggedIn": true` ✓; `false` or missing → ! (`claude auth login`; only `claude -p` workers need it, so it never turns the doctor red); unparseable ! |
| D16 | copilot login | Through `ghcp-models --json --refresh` (ghcp's own free probe) on any Copilot version; the raw invalid-model probe only without ghcp-models and only when D9 reports `CX_VERIFIED_COPILOT` (measured free there); see "D16 details" below | rc 0 ✓ (catalog kept for `--pools`); 11 ✗ (`copilot login`, unless a rule below applies); 16 ✗ (re-run this Bash call outside Claude Code's sandbox); 12 ! (timed out); 13 ✗; 2 ! (catalog unparseable); other ✗. Raw probe: stderr `from --model flag is not available` ✓; `AUTH_RE` ✗; `SANDBOX_RE` ✗; else !. No ghcp-models and D9 not exactly 1.0.105 → ! "copilot login not probed" (install the ghcp plugin), and no Copilot process starts |
| D17 | grok login, model, profile | `env -u XAI_API_KEY -u GROK_SANDBOX GROK_DISABLE_AUTOUPDATER=1 GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_SKILLS_ENABLED=false GROK_CLAUDE_MCPS_ENABLED=false GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false timeout -k 5 30 grok models </dev/null 2>&1` | contains `You are not authenticated` ✗ (`grok login --device-auth`); rc 0, no such phrase and ≥ 1 id parsed → ✓; killed → ! (hung); anything else (non-zero rc, crash, network error, no ids) → ! with the first output line. `grok_bulk_model` among the ids (`cxlib.py parse-models --cli grok`: `^\s*[*-]\s+(\S+)` lines, else bare-id lines) ✓ else ! (an unlisted `-m` id silently drops `--effort`). `grok_sandbox_profile` `auto` (or the 0.2.0 value `cx-workspace`): info, the number of `cx-<repo>-<hash>` profiles in `~/.grok/sandbox.toml` (each repository's first grok run, or `cx-init --user-grants`, writes its own; every grok run, write, read and review, uses it, §15.7); a built-in that lets grok write `~/.grok` (`off`, `devbox`, `workspace`, `read-only`) ✗ (every grok run is refused, §15.2; fix `grok_sandbox_profile` back to `auto`); another name defined there ✓ else !. The invalid 0.2.0 `cx-workspace` block still there → ! (fix `cx-init --user-grants`). Linux and WSL: `bwrap` on PATH ✓ else ! (`sudo apt install -y bubblewrap`: grok refuses to start a profile with deny lists without it); `cxlib.py landlock` (the `landlock_create_ruleset` version query): an ABI ✓, ENOSYS/EOPNOTSUPP ! (grok cannot confine its process here), else info. Always: `grok --sandbox strict models` (free, the same prefix): a line saying the sandbox was not applied (`sandbox could not be applied`, `Refusing to start with its protections missing` or `… denied paths unprotected`, `without enforcement`) ✗ (every grok run is refused: Landlock, kernel 5.13 or newer, and bubblewrap); rc 0 ✓; killed or another rc !. Then the bytes grok appended to its sandbox log (`${GROK_HOME:-~/.grok}/sessions/sandbox-events.jsonl`, §1.3) during that probe (`cxlib.py grok-sandbox-event`; never when the log file itself is a symlink; the sizes from GNU `stat -c %s` and only with python3, so not on macOS): a `ProfileApplied` event for the probe's cwd with `enforced` false ✗ in place of that ✓ (every grok run is refused); with `enforced` true one more ✓ naming the platform (`linux/landlock`); no log or no such event: nothing more |
| D18 | agy login, grant | `env -u GEMINI_API_KEY -u GOOGLE_API_KEY AGY_CLI_DISABLE_AUTO_UPDATE=true timeout -k 5 30 agy models --output-format json </dev/null`; if rc ≠ 0 or unparseable, the same prefix with `agy models` | ≥ 1 id that looks like a model slug (one token with a digit; `cxlib.py parse-models --cli agy` reads a `{"<slug>": "<label>"}` map only when every key is such a slug and no `error`/`status`/`message`/`code`/`detail`/`reason` key is present, so an rc-0 status envelope is no model list) ✓; 0 ids, not killed ✗ (run `agy` once in a terminal and sign in); killed ! (hang: not an auth problem, #318 or MCP startup). `~/.gemini/antigravity-cli/settings.json` `permissions.allow` holds `write_file(...)` or `command(...)` rules → info: global grants conductor 0.2.0 wrote, no longer needed (each raw run passes its own `--settings`, §15.2) and applying to every agy session; none → info that the grants are per run |
| D19 | gh login | `timeout -k 5 15 gh auth status </dev/null` | rc 0 ✓; else ✗ (`gh auth login --web`) |
| D20 | conductor install | `installed_plugins.json`, `enabledPlugins` | installed → info with version; disabled → ! |
| D21 | ghcp policy overlap | `cxlib.py plugins`: ghcp `coding_policy`, `delegation_nudge` (saved value, else the ghcp default `on`) | with conductor `policy` on: both `off` ✓; either on ! with fix `printf '%s' '{"coding_policy":"off","delegation_nudge":"off"}' \| claude plugin configure ghcp@ghcp-for-claude-code --values-stdin`; ghcp `usage_log` empty → info |
| D22 | antigravity overlap | same for antigravity, plus `timeout` (default `5m`) | both off and timeout ≥ 30m ✓; else ! with fix `printf '%s' '{"coding_policy":"off","delegation_nudge":"off","timeout":"30m"}' \| claude plugin configure antigravity@antigravity-for-claude-code --values-stdin` |
| D23 | grok-build bridge | installed and enabled | ! "its SessionEnd hook also fires on /clear and kills and erases its session-tagged bridge jobs in the current workspace; the conductor never uses the bridge"; ! "grok-build:grok-delegate is a proactive subagent that writes by default without a gate"; info: `/grok-build:import` calls a `grok import` that 1.0.70 lacks |
| D24 | Deny rules | `settings.json` `permissions.deny` | for each installed plugin: `Task(antigravity:antigravity-delegate)` and `Task(grok-build:grok-delegate)` (the `Agent(...)` spelling is accepted too; syntax [unverified] on 2.1.316) ✓; missing ! with the JSON to add; info "the same deny rules also refuse those agents as a workflow `agent()` agentType" |
| D25 | Autonomy allow rules (U2) | `permissions.allow` of the settings of the host where Claude Code runs: not forwarded, the executor host's `settings.json`; forwarded (`CX_FORWARDED=1`), the Windows-side file `CX_WIN_SETTINGS` | info listing any missing rule. The rules are narrow: one per leading form of a simple command in the skill's (§12.2) bash blocks, written exactly as the skill writes them, and no other (P43 checks both ways: every executor and GitHub command of the skill matches a rule, every rule matches one of them). Executor host (`cxlib.D25_HOST_RULES`): `Bash(cx-doctor:*)`, `Bash(cx-init:*)`, `Bash(cx-run:*)`, `Bash(cx-job:*)` (every executor run), `Bash(cx-wsl grok:*)` and `Bash(cx-wsl ghcp-ci-debug:*)` (the hand steps' two executor calls: `cx-wsl` takes their pool slot and adds the per-tool prefix, in WSL as from Windows), `Bash(ghcp-cloud list:*)` and `Bash(ghcp-cloud view:*)` (following the Copilot cloud agent; free), `Bash(. "$HOME/.conductor/out/:*)` (the `vars.sh` line that starts every hand step), `Bash(git -C "$WT" push:*)` and `Bash(gh pr:*)` (Step 5 names the repo with `-R "$REPO"`, never a `(cd … && gh …)` subshell). No raw `agy`, `agy-delegate`, `ghcp-delegate`, `ghcp-job`, `ghcp-handoff` or `agy-job` rule: those would run an executor without `cx-run`'s pool slot, agy registration, tree snapshots and served-model checks; no `agy-media` rule (it always passes `--yolo`). Windows side (`cxlib.D25_WIN_RULES`, forwarded): `Bash(cx-doctor:*)`, `Bash(cx-init:*)`, `Bash(cx-run:*)`, `Bash(cx-job:*)` (they forward themselves, so they cover every executor run) and the `cx-wsl` forms the skill's Windows section runs directly: `Bash(cx-wsl ghcp-ci-debug:*)`, `Bash(cx-wsl ghcp-cloud list:*)`, `Bash(cx-wsl ghcp-cloud view:*)`, `Bash(cx-wsl gh pr:*)`. Never `Bash(cx-wsl:*)`, which also covers `cx-wsl bash -c`/`-s`, i.e. any command in WSL (user decision 2026-11-01: U2 grants spending, pushes, PRs and `@copilot` reviews, not every shell command); the skill's `cx-wsl bash` steps prompt. `Bash(cx-wsl:*)` found in the checked settings → ! (forwarded: replace it with the tool rules; in WSL: remove it, a WSL session needs only the `cx-wsl` tool rules listed). Phase 3 adds `cx-fanout` and `cx-gate`. How 2.1.316 matches rules that hold literal `$VAR` text, and how it splits multi-line steps, is [unverified] (§20 item 36). Never written by the doctor. D24's deny rules stay checked on the executor host's settings, where the siblings live. |
| D26 | Sandbox exclusion | `settings.json` `sandbox` (of the host where Claude Code runs, as in D25) | sandbox enabled and `sandbox.excludedCommands` [docs-only key] lacks any of `ghcp-*`, `agy-*`, `agy`, `grok`, `gh`, `git`, `copilot`, `cx-*` → info with the JSON, noting that worktree setup writes `worktree_root` (default `~/.cx-wt`) and `~/.conductor`, which the sandbox also blocks |
| D27 | Stray grok worker | `ps -eo args` | a line matching `(^\|/)grok(\.js)? worker( \|$)` → ! (`CURSOR_WORKER_MSG` in `cxlib.py`: "registers this machine with Cursor; stop it"). `grok leader` processes are normal grok leader mode and are not reported |
| D28 | Billing and account switches | env `COPILOT_MODEL`, `COPILOT_ALLOW_ALL`, `COPILOT_AUTO_TIER`, `COPILOT_PROVIDER_BASE_URL`, `GH_TOKEN`, `GITHUB_TOKEN`, `XAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `ANTHROPIC_API_KEY` | each `COPILOT_*` set → ! (it can silently change the model, permissions or endpoint of every Copilot run; `COPILOT_MODEL` with an unknown id bills the default model); each API key set → ! "bills an API account instead of the subscription"; `GH_TOKEN`/`GITHUB_TOKEN` set → ! (can change the account Copilot uses), except the variable recorded as `copilot_token_env` (D16) → info "Copilot signs in through <VAR>". The Phase 1 command prefixes (§12.2) and Phase 2 adapters unset them per command |
| D29 | Worker shims first on PATH (§15.6; Phase 2, free) | `env PATH="$CX_ROOT/worker-shims:$PATH" CX_WORKER=1 <prefix> <abs cli> --version` for copilot, grok and agy whose own `--version` probe (D9-D11) succeeded | ✓ one line naming the CLIs that start with the shims first; ! per CLI that exits 126 or prints `blocked: CX_WORKER` (it starts a tool by name, so every `cx-run` of its lane would fail inside the worker), or exits non-zero only with the shims first |
| D30 | Session (first line of the Session section) | `cx_session`, `cx_attended` (§7.1); `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_DESKTOP_APP_VERSION`, `CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE`, `CLAUDE_PROJECT_UUID` (wording only, never routing) | `local`: info `session local (entrypoint X[, desktop app Y])`. `bridge`: info "a Remote Control child, such as a Work locally project thread; this machine's settings, hooks and plugins apply. the pool slots are shared by every thread and session on this computer (cap_agy, cap_copilot, cap_grok; agy launches one at a time)". `byoc` with `exec_host=local`: info "option exec_host=local treats this runner as this machine". `cloud`, or `byoc` without it: ✗ "cloud session (<kind>[, environment <type>]): the conductor is inactive here; the executors and their logins are in WSL on your computer", fix "run cx-doctor in a local desktop session, a WSL terminal or a Work locally project thread"; no other check runs and the exit is 43. `CX_ATTENDED=0`: info "unattended session: permission prompts are denied, so executor commands need the D25 allow rules". `CLAUDE_PROJECT_UUID` set: info "a claude.ai Project is attached; Claude Code adds its instructions itself". Host `wsl`, session `local`, entrypoint `claude-desktop*` or a desktop app version: when a PATH entry holds this plugin's own `cx-doctor` (same file by `-ef`), ✓ "Claude desktop app session in WSL: the conductor plugin is loaded in this session (its bin/ is on PATH)"; otherwise, only when `CLAUDECODE` is set (a Claude Code Bash call), ! "this Claude desktop app session in WSL has not loaded the conductor plugin (its bin/ is not on this session's PATH)" with the fix "open the repo in a desktop session on a Windows folder, run claude in a WSL terminal, or serve the WSL folder with claude remote-control from a WSL terminal"; with neither, no line (§1.5, §20 item 66). Forwarded (`CX_FORWARDED=1`): no D30 line, W10 reports the caller |
| D31 | Work locally readiness (info only, never ! or ✗: many users never use Remote Control) | `cxlib.py doctor-session`: env and the merged settings `env` blocks for `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_GROWTHBOOK`, `ANTHROPIC_BASE_URL` other than `https://api.anthropic.com` (a trailing `/` ignored); settings `disableRemoteControl`; D8's version against 2.1.280; `ANTHROPIC_API_KEY` | one info line per blocker ("Remote Control, and so Work locally threads on this machine, is off while: …"); none → info "Work locally prerequisites met here; a thread also needs the desktop app with 'Use this computer from your phone and claude.ai' on (folder added) or claude remote-control running in the folder, and Require trusted devices off" (on WSL plus "claude remote-control started in the repo folder serves Work locally threads with this WSL install's plugins", §20 item 40). The blocker list changes together with W10 and §1.7 |
| D32 | Workflows and ultracode (info only) | `cxlib.py claude-settings` / `doctor-session --config-dir CFG --repo TOP --root CX_DETECT_ROOT`: managed (`<root>/etc/claude-code/managed-settings.d/*.json`, later names first, `managed-settings.json`, `${CLAUDE_CONFIG_DIR:-~/.claude}/remote-settings.json`), local (`<top>/.claude/settings.local.json`), project (`<top>/.claude/settings.json`), user (`settings.json`); effective = managed > local > project > user (`--settings` flags are invisible). Keys `ultracode`, `disableWorkflows`, `enableWorkflows`, `workflowKeywordTriggerEnabled`, `workflowSizeGuideline`, the `Workflow…` allow rules. Env `CLAUDE_CODE_DISABLE_WORKFLOWS`, `CLAUDE_CODE_WORKFLOWS`, `CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`, `CLAUDE_CODE_SUBAGENT_MODEL`, `CLAUDE_CODE_SUBAGENT_EFFORT`, `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS`; `nproc` | (1) "workflows available (… on Pro they default off: turn on Dynamic workflows in /config)", or "workflows off (<cause>): ultracode is unavailable; conductor fan-out uses the main-turn recipe". (2) "ultracode on for new sessions (<layer> settings, <file>)", or "ultracode not set in the settings files; a session can still turn it on (…); the doctor cannot see session toggles"; set while workflows are off → "… has no effect". (3) keyword trigger off. (4) size guideline (advisory only). (5) each model or effort override. (6) concurrency: the env value, or min(16, max(2, nproc − 2)). (7) the `Workflow…` allow rules. Not on a forwarded run (W11 covers the Windows side). Phase 2: (5) for the first two variables becomes ! ("overrides conductor:cx-runner's haiku"), (6) adds the pool slots, and a missing `Workflow(conductor:opus-pools)` allow rule is info Phase 2: one more info line, `slot caps: cap_agy=N cap_copilot=N cap_grok=N`, next to the workflow concurrency (the caps hold for every session, thread and workflow agent on the computer, §15.3); the ultracode line says workflow agents run executors only through `cx-run --background`. |

**D3 fixes**, printed in this order (P29 asserts that no fix text contains `reset --hard` or
`rm -r --cached`: the install path is normally a copy under `~/.claude/plugins/cache/…`, not a
work tree, so `git -C <it>` would resolve an ENCLOSING repository, such as a dotfiles repo
holding `~/.claude`, and discard its uncommitted work):
1. `sed -i 's/\r$//' <files>`: the files D3 listed, absolute paths, each shell-quoted with
   `printf %q` (`cx_shell_words`, §4.4) so that a path with a space (`/c/Users/John Smith/…`)
   stays one word when the line is run as printed. It works whatever produced the CRs.
2. Only for the marketplace clone `X=${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/marketplaces/conductor-for-claude-code`,
   and only after `git -C "$X" rev-parse --show-toplevel` printed exactly `X`:
   `git -C <X> -c core.autocrlf=input checkout-index -a -f` (rewrites tracked files from the
   index with this repo's `eol=lf` rules; HEAD and untracked files are untouched), then
   `claude plugin update conductor@conductor-for-claude-code`.
3. The fallback: a folder (`directory`) marketplace edited with Windows tools needs the same
   sed fix in its source folder, or the next update copies the CRs back; an archive install can
   instead be refreshed with `claude plugin marketplace update conductor-for-claude-code &&
   claude plugin update conductor@conductor-for-claude-code` (whether `update` re-copies an
   unchanged version is [unverified], §20 item 32; otherwise uninstall and reinstall the plugin).

No fix sets `core.autocrlf`: this repo's `eol=lf` attributes override it (§3.5), so CRs in an
installed copy come from archive downloads, copies made with Windows tools or a folder
marketplace edited on Windows, where autocrlf changes nothing. W6 still warns about
`autocrlf=true` for the user's own repositories. D3's `chmod 0755` fix quotes its paths the same
way.

Reachability: a CRLF copy of the doctor's own files cannot run (§3.5), so D3 and W6 only ever
see CR in files outside the doctor's execution path; the session-start canary (§10.2) covers
the rest.

**D16 details.** The ghcp path runs on any Copilot version (ghcp-models' catalog probe is
ghcp's own, documented free); the raw path only when D9 printed exactly `CX_VERIFIED_COPILOT`
(the invalid-model refusal is measured free there). Both run from the empty
`$CX_HOME/probe`, in the Copilot adapter's environment: `env -u GH_TOKEN -u GITHUB_TOKEN -u
COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL
COPILOT_AUTO_UPDATE=false NO_COLOR=1`.
- With ghcp: `(cd "$CX_HOME/probe" && env … GHCP_COPILOT_BIN=<abs copilot> timeout -k 5 90
  <ghcp-models> --json --refresh </dev/null)`. `--refresh` is required for the login verdict:
  without it a fresh 24 h cache answers without probing, and a logged-out account would show ✓.
- Without ghcp: `(cd "$CX_HOME/probe" && env … timeout -k 5 60 <copilot> -p . --model
  __cx_doctor_probe__ --no-ask-user --no-auto-update --no-color --disable-builtin-mcps
  </dev/null)`. `AUTH_RE`/`SANDBOX_RE` are ghcp's, copied verbatim.
- Logged out while `GH_TOKEN` or `GITHUB_TOKEN` is set: probe once more keeping that one
  variable; logged in → ✓ with info "Copilot signs in through <VAR>", recorded as
  `copilot_token_env` (§7.6).
- `--pools` takes the catalog from this probe. When D16 did not probe (no ghcp-models and D9
  not 1.0.105),
  `--pools` reads ghcp's cache file `${XDG_CACHE_HOME:-~/.cache}/ghcp-claude/models.json`
  directly, labelled with its age, and never runs `ghcp-models` (a stale cache would make it
  probe the unpinned binary).

**Forwarded login comparison (D15–D19).** Each login probe result is stored in the host
record's `logins` (§7.6) as `direct` or `forwarded`. When `CX_FORWARDED=1` and a probe says
logged out while that CLI's last `direct` result says logged in, the line is ! "logged in from a
WSL terminal but not through wsl.exe: the keyring is unreachable (D-Bus)" with the token-file
fix of §8.5 for Copilot and the file-store notes for agy and gh, never the login command (which
would send the user to log in again where it already works). W9 runs this comparison from
`cx-doctor --windows`.

`cxlib.py plugins --config-dir DIR` reads `DIR/plugins/installed_plugins.json` and
`DIR/settings.json` (both with `encoding="utf-8-sig"`, §3.3) and returns, per sibling id,
`installed`, `enabled`, `version`, `scope` and `install_path` (the `scope: "user"` entry
first, §7.6), the saved options, and the `permissions.allow` / `permissions.deny` lists.

### 8.4 `--pools`

| Pool | Probe | Report |
|---|---|---|
| agy | D18's ids; with `--agy-usage` only: the agy prefix, then `timeout -k 5 45 agy -p /usage --output-format json </dev/null` (zero quota [docs-only]) | Opus slugs matching `^claude-opus-5-5-(low\|medium\|high)$`; `agy_opus_slug_tpl` at `high` listed ✓, else ✗ ("Opus not offered: Ultra must be billed directly, U1"). With `--agy-usage`: bucket percentages when the `/usage` JSON has recognizable keys, else its first 5 lines as info, and `agy_claude_floor_pct` > 0 with the Claude bucket below it → !; without it: info naming the flag |
| copilot | D16's catalog (when D16 did not probe: ghcp's cache file, with its age) | `copilot_opus_id` with `policy` `enabled` ✓ else ✗; presence of `gpt-6.1-sol`, `gpt-6-astra`, `gpt-6-luna`, `gemini-4-argon` → info; `copilot_xhigh_ok=false` → info (#5149 check pending); `copilot_reserve_pct=0` → info "no reserve (U3)"; month-to-date figure from `pools.json` with its age: older than `copilot_mtd_max_age_days`, or missing, is ! only while `copilot_reserve_pct` > 0 (the figure then gates dispatch, §16.3) and info otherwise (with no reserve nothing reads it, and the doctor never nudges anyone to track spend); ledger month sum (Phase 2; none → info). Info: the ledger is a lower bound, because PR reviews (average Lite 25, Balanced 150, Max 1,000 credits [docs-only]) and interactive use bill the same 20,000-credit month |
| grok | D17's ids | `grok_bulk_model` listed ✓ else !; Claude ids → info ("record one as an Opus lane only after an `--effort` check; never automatic"); info `CURSOR_POOL_MSG` (`cxlib.py`): "interactive Cursor IDE use on Grok/Composer drains the same weekly pool" |
| claude | — | info: conductor pool for xhigh/max work, architecture and unplaced tasks |

`pools.json`: `{"version": 1, "copilot_mtd_credits": <number>, "copilot_mtd_at": "<UTC ISO>"}`.

### 8.5 `--login-help`

Logins live on the executor host. From Git Bash, the text starts with: `Logins are per host;
open a WSL terminal (wsl.exe, or wsl.exe -d <distro> when wsl_distro is set) and run these there. The Windows side's logins do not
count.` Then, per CLI (exact text may be wrapped, commands must be verbatim):

| CLI | Fresh login (WSL) | Verify (free) | Notes and things to avoid |
|---|---|---|---|
| copilot | `copilot login` (device flow: open https://github.com/login/device and enter the code it prints) [docs-only] | `/conductor:doctor` in a Claude Code session in WSL, or `~/.conductor/runtime/current/bin/cx-doctor` in a WSL terminal (create that copy once with `/conductor:doctor --install-runtime`; its D16 line probes the login; ghcp's `ghcp-models` is not on a plain terminal's PATH) | If the keyring is unreachable through `wsl.exe` (no D-Bus): create a fine-grained PAT with the "Copilot Requests" permission and store it with `install -d -m 700 ~/.conductor/secrets && install -m 600 /dev/null ~/.conductor/secrets/copilot-token`, then paste the token into that file; `cx-wsl ghcp-*` calls export it as `COPILOT_GITHUB_TOKEN` for that call only (§7.7), so from Windows the Copilot lanes run as direct `cx-wsl ghcp-*` calls (§12.2 From Windows), not inside `cx-wsl bash -s` steps; Phase 2 adapters export it for every Copilot lane. Avoid classic `ghp_` tokens and a stray `GH_TOKEN`/`GITHUB_TOKEN` (they can change the account Copilot uses) |
| grok | `grok login --device-auth` (prints a URL and a code; works headless) [verified flag] | `grok models` must not print `You are not authenticated.` | Avoid `grok login --oauth` in containers (loopback callback) and `XAI_API_KEY` (bills the API account, not the subscription) |
| agy | `agy` (first run asks you to sign in with Google; over SSH it prints a URL and a code) then quit [docs-only] | `agy models` lists `claude-opus-5-5-high` | Without D-Bus agy stores credentials in a file (expected in wsl.exe shells). Avoid `GEMINI_API_KEY` (bills the key, not the plan); never run `/antigravity:migrate` or `agy plugin import claude` |
| gh | `gh auth login --web` (prints a one-time code for https://github.com/login/device) | `gh auth status` | — |
| claude | `claude auth login` (Claude subscription is the default) | `claude auth status --json` shows `"loggedIn": true` | `--console` would bill API usage instead of the plan |

`--host docker` (v1.1) prefixes each command with
`docker compose -f <docker_compose_file> exec <docker_service>` and adds: localhost-callback
OAuth does not work in the container; the credential directories are named volumes
(`~/.grok`, `~/.gemini`, `~/.antigravity`, `~/.config/gh`, `~/.copilot`).

### 8.6 Windows checks (Git Bash, pure bash)

| ID | Probe | Expected → status |
|---|---|---|
| W1 | `command -v wsl.exe`; `timeout --version` | wsl.exe present ✓, else ✗; the first line of `timeout --version` names GNU coreutils ✓, else ✗ ("`timeout` resolves to `C:\Windows\System32\timeout.exe`: put `/usr/bin` before the Windows directories on PATH") |
| W2 | `WSL_UTF8=1 wsl.exe -l -q \| cx_decode_wsl` (one name per line); `WSL_UTF8=1 wsl.exe -l -v \| cx_decode_wsl` (rows after the header: an optional `*` marking the default, NAME as the first field, VERSION as the LAST field; STATE is localized and may be several words, so it is shown verbatim but never parsed) | `wsl_distro=auto`: a default (`*`) row exists with VERSION 2 ✓ (its name is exported as `CX_WSL_DISTRO`), VERSION 1 !, no default ✗; explicit `wsl_distro`: listed by `-l -q` with VERSION 2 ✓, VERSION 1 !, absent ✗ (`installed: <names>; set wsl_distro or leave it auto`); command failed ✗ |
| W3 | `command -v cygpath`; `cygpath -w -l "$PWD"` | cygpath present ✓ else ✗; cwd under `\\wsl.localhost\` or `\\wsl$\` ✓; on a drive info (slow `/mnt/<x>` access from WSL for large repos; for a repo that lives in WSL use a WSL terminal, `claude` or `claude remote-control` there, never a desktop session opened on `\\wsl.localhost`, which runs inside WSL without plugins, §1.5); other UNC ✗ (unmappable) |
| W4 | `[ -d "//wsl.localhost/$D/" ]`, else `[ -d "//wsl\$/$D/" ]` (`D` from W2: the explicit `wsl_distro`, or the default row's name) | first ✓; only the legacy prefix ! (host paths use `\\wsl.localhost`); neither ! (distro not running yet) |
| W5 | cwd on a WSL UNC path: `git rev-parse --show-toplevel` (Git for Windows) | success ✓; output contains `dubious ownership` ✗, fix = the `git config --global --add safe.directory …` line git prints (extracted verbatim), else `git config --global --add safe.directory '%(prefix)///wsl.localhost/<D>/<path>'` [unverified form]; not a repo → no line. All conductor git operations still run in WSL git |
| W6 | `grep -l $'\r'` over every Windows-side file of the shipped list (`CX_SHIPPED_FILES`, §13.4; grep only reads, so the files on the doctor's own execution path cost nothing when they are fine, and `bin/cx-init`, `bin/cx-wsl`, `scripts/cx-init.sh`, `scripts/cx-wsl.sh`, which no canary covers, are checked); `git config --global --get core.autocrlf` | no CR ✓, else ✗ with D3 fixes 1 and 3 (paths shell-quoted); `autocrlf=true` ! (repos touched from both sides need `* text=auto eol=lf` in `.gitattributes`; this plugin's own `eol=lf` rules already protect its git checkouts). CR in the execution path itself (`bin/`, `scripts/cx-*.sh`, `scripts/lib/*.sh`, the forwarder) means this check cannot run; the session-start canary reports that case (§10.2) |
| W7 | Windows-side `plugins/installed_plugins.json` and `settings.json` (grep after stripping a BOM and CRs, no python) | conductor installed ✓; ghcp, antigravity or grok-build installed natively ! each ("its policy would send Claude to run its wrappers in Git Bash, bypassing WSL; install it in WSL only"). The lite-read `exec_host`/`wsl_distro` are passed along; the WSL side compares them with its real parse of the same file (`CX_WIN_SETTINGS`) and reports a disagreement as ! |
| W8 | `bash scripts/host/forward-wsl.sh cx-doctor --version` (`--windows` mode only) | prints `cx-doctor <CX_VERSION>` ✓; exit 41 ✗ (runtime could not be installed); exit 40 ✗ with the decoded wsl.exe message |
| W9 | `bash scripts/host/forward-wsl.sh cx-doctor --logins-only` (`--windows` mode only) | relays the forwarded D15–D19 lines verbatim (rendered on the WSL side). A CLI that is logged out through wsl.exe while the host record's last `direct` result says logged in → ! "keyring unreachable through wsl.exe" with the token-file fix of §8.5 instead of the login command (§8.3, forwarded login comparison); no `direct` result yet → info "run ~/.conductor/runtime/current/bin/cx-doctor once in a WSL terminal to compare" |
| W10 | The caller's session and Work locally readiness (pure bash): `cx_session`, `cx_attended`, the entrypoint and desktop version, the Windows environment, and the Windows-side `settings.json` through the lite readers (`cx_lite_top`/`cx_lite_value` in `options.sh`: BOM and CRs stripped, nested objects cut out, the top-level `env` object kept) | As D30 (without the desktop WSL-session check) plus an always-present info "desktop app sessions opened on a \\wsl.localhost folder (or in the WSL environment) run inside WSL, where plugins are not loaded: keep conductor work in a desktop session on a Windows folder, like this one, in a WSL terminal, or behind claude remote-control in WSL"; then D31's blockers (environment, the settings `env` block, top-level `disableRemoteControl`, `ANTHROPIC_API_KEY`; no claude version on the Windows side) as info lines. The caller's session and attended flag also go into the Windows report as a `meta session` record for the WSL side's header, `CX_HOST` and `CX_DOCTOR` |
| W11 | D32 on the Windows side (pure bash) | The lite top-level reader over `$ProgramFiles/ClaudeCode/managed-settings.json` (wins) and the Windows-side `settings.json`; the registry and project files are not read; concurrency from `CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS`, else `NUMBER_OF_PROCESSORS` (no `nproc` on the §3.1 list) | As D32, all info |

### 8.7 `--json`

```json
{"version": 1, "plugin_version": "0.1.0",
 "host": {"host": "wsl", "hostkey": "wsl-Ubuntu", "distro": "Ubuntu", "os_id": "ubuntu", "os_version": "24.04", "wsl_version": 2, "arch": "x86_64", "kernel": "...", "session": "bridge", "attended": null},
 "caller": "gitbash", "session": "bridge", "attended": null,
 "checks": [{"id": "D9", "section": "CLIs", "status": "fail", "text": "copilot not found (GHCP_COPILOT_BIN, PATH, gh's copilot download)", "fix": "npm install -g @github/copilot"}],
 "pools": null,
 "record": "/home/me/.conductor/hosts/wsl-Ubuntu.json",
 "summary": {"ok": 24, "warn": 3, "fail": 1}}
```

`status` ∈ `ok|warn|fail|info`; `session` is the caller's session kind (§7.1; a forwarded call
takes it from the Git Bash side's report, because the env allowlist drops the `CLAUDE_CODE_*`
variables) and `attended` its flag (`1`, `0` or null); `pools` holds the `CX_POOLS` payload with `--pools`; exit codes
as in text mode. stdout holds exactly this one document or, when there is none (a Git Bash
forwarding failure, §8.1), nothing at all: a caller checks the exit code before parsing.

## 9. `cx-init` and the repo bundle

### 9.1 CLI

```
cx-init [--dir <path>] [--dry-run] [--force] [--json] [--only agents|routes|copilot]…
        [--setup <cmd>] [--test <cmd>] [--lint <cmd>] [--typecheck <cmd>]
```

1. `--dir` (default: cwd) goes through `cx_path_in`; it must be inside a non-bare git work tree,
   else exit 1. The repo is `git -C <dir> rev-parse --show-toplevel` (a subdirectory is
   accepted with a note).
2. `cxlib.py init-detect <repo>` (§9.3); a command flag overrides its slot, and an empty value
   (`--lint ''`) means "none".
3. `cxlib.py init-apply` renders the three files and classifies each (§9.2). `--only`
   (repeatable; `agents` = `AGENTS.md`, `routes` = `.cx/routes.json`, `copilot` =
   `.github/copilot-instructions.md`) restricts classification and writing to the named files;
   the others are reported as `skipped`. All or nothing: if any selected file is a conflict and
   `--force` is absent, nothing is written and the exit is 5, with every conflict listed;
   `--force` applies only to the selected files (so `--only agents --force` never overwrites a
   hand-edited routes.json).
4. Unless `--dry-run`: write the files (UTF-8, LF, trailing newline; create `.cx/` and
   `.github/` as needed) and add `/.conductor/` to
   `$(git rev-parse --path-format=absolute --git-common-dir)/info/exclude` when absent.
5. Notes (never acted on): no `.gitattributes` at the repo root ("touched from Windows and WSL?
   add `* text=auto eol=lf`"); `core.autocrlf=true`; nothing detected for a slot.
6. Output: stdout lines `create   <file>`, `update   <file> (<what>)`, `same     <file>`,
   `skipped  <file>`, `CONFLICT <file> (<why>; --force to <action>)`, then `detected: <slot> = <cmd>` lines (`--json`
   prints `{"repo", "dry_run", "files": [{"path", "action", "reason"}], "excluded", "detected",
   "notes"}` instead). stderr: `CX_INIT`, plus `CX_SIGNAL EXISTS` on exit 5.
7. `--dry-run` writes nothing (not even the exclude line) and exits as the real run would (0 or
   5). Exit codes: 0, 1, 5, 42.

`cx-init` never creates or edits `CLAUDE.md`, anything under `.claude/`, `.gitignore` or
`.gitattributes` (P36 asserts it). Phase 2 adds `cx-init --user-grants` (§15.7).

### 9.2 Files and write rules

| File | Unit cx-init owns | Rules |
|---|---|---|
| `AGENTS.md` | The block from the line `<!-- cx:begin conductor bundle v1: written by cx-init; edit freely, cx-init --force rewrites this block -->` to the line `<!-- cx:end -->` | absent → create (block only); block present and equal → `same`; block present and different → conflict, `--force` replaces the block only; file present with no block → `update` (non-destructive, no `--force` needed): a blank line and the block are appended at the end. Text outside the block is never changed, byte for byte |
| `.github/copilot-instructions.md` | Same block markers | Same rules |
| `.cx/routes.json` | The whole file (`json.dumps(obj, indent=2) + "\n"`) | absent → create; present and JSON-equal → `same`; different → conflict, `--force` overwrites. cx-init is a bootstrapper, not a sync tool: after hand edits, do not use `--force` |

For every file, before anything is written: the file itself and every directory between the repo
root and it (`.cx/`, `.github/`) are checked with `lstat`. A symlink anywhere on that path (a
repository can commit `.cx` or `.github` as a symlink to anywhere the user can write, such as
another repo's `.cx/routes.json`, the file Phase 2 executes gate commands from), a component that
exists and is not a directory (a regular file `.cx`), or a parent whose real path lies outside
the repository's real path → conflict, even with `--force`. Because these checks happen while
classifying, any of them stops the whole bundle (exit 5) and nothing at all is written, AGENTS.md
included. The writer then creates missing directories one at a time (`os.mkdir` after another
check) and opens each file with `O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW`.

### 9.3 Detection rules (`cxlib.py init-detect`)

Output: `{"ecosystems": [..], "package_manager": "npm|pnpm|yarn-classic|yarn-berry|bun|null",
"setup": str|null, "test": str|null, "lint": str|null, "typecheck": str|null, "notes": [..]}`.
Only the repo root is inspected. A `setup` must not create or modify tracked files in a fresh
worktree: whatever it writes would be staged by the conductor's `git add -A` (§12.2 step 3) and
reported as tampering on every run. Hence the lockfile rules below.

| Ecosystem (trigger) | setup | test | lint | typecheck |
|---|---|---|---|---|
| Node (`package.json` parses). Manager: `packageManager` prefix `pnpm@`/`yarn@`/`npm@`/`bun@` wins; else `pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn (berry when `.yarnrc.yml` exists or the lock contains `__metadata:`, else classic), `bun.lock` or `bun.lockb` → bun, else npm | npm with `package-lock.json` or `npm-shrinkwrap.json`: `npm ci --prefer-offline`; npm without: `npm install --no-audit --no-fund --no-package-lock` (never writes a lockfile); bun: null with a note ("bun detected: set setup yourself, e.g. `bun install --frozen-lockfile`");  pnpm: `pnpm install --frozen-lockfile --prefer-offline`; yarn classic: `yarn install --frozen-lockfile`; yarn berry: `yarn install --immutable` | `scripts.test` present and not containing `no test specified` → `npm test` / `pnpm test` / `yarn test` / `bun run test` | `scripts.lint` → `npm run lint` / `pnpm run lint` / `yarn lint` / `bun run lint` | first script among `typecheck`, `type-check`, `tsc`, `check-types` → `npm run <s>` / `pnpm run <s>` / `yarn <s>` / `bun run <s>`; else `tsconfig.json` and `typescript` in `dependencies`/`devDependencies` → `npx tsc --noEmit` / `pnpm exec tsc --noEmit` / `yarn tsc --noEmit` / `bunx tsc --noEmit` |
| Python (`pyproject.toml`, `setup.cfg`, `setup.py` or `requirements*.txt`). Runner: `uv.lock` → `uv run `, `poetry.lock` → `poetry run `, else `python3 -m ` | `uv sync --frozen`; `poetry install --no-interaction`; else null with a note (no lockfile tool; pip into a system Python is refused on PEP 668 distros) | pytest when any of: `[tool.pytest.ini_options]` in pyproject, `pytest.ini`, root `conftest.py`, `[tool:pytest]` in setup.cfg, `[pytest]` in tox.ini, `pytest` in a requirements file or the pyproject dependency text, `tests/test_*.py` → `<runner>pytest -q` | `[tool.ruff]` in pyproject, `ruff.toml` or `.ruff.toml` → `<runner>ruff check .` | `[tool.mypy]` in pyproject, `mypy.ini`, `.mypy.ini` or `[mypy]` in setup.cfg → `<runner>mypy .` |
| Go (`go.mod`) | `go mod download` | `go test ./...` | `golangci-lint run` when `.golangci.{yml,yaml,toml,json}` exists, else `go vet ./...` | null |
| Rust (`Cargo.toml`) | `cargo fetch --locked` when `Cargo.lock` is tracked (`git ls-files --error-unmatch Cargo.lock`); else null with a note ("Cargo.lock is not tracked: cargo creates it in every worktree; commit it or keep it in .gitignore") | `cargo test --quiet` | `cargo clippy --all-targets --quiet -- -D warnings` | `cargo check --all-targets --quiet` |
| Fallbacks (only for a slot still null) | — | `tests/run-tests.sh` → `bash tests/run-tests.sh`; Makefile with `^test:` → `make test` | Makefile with `^lint:` → `make lint` | — |

`pyproject.toml` is parsed with `tomllib` when available, else scanned for section headers and
dependency text. Several ecosystems: each slot joins the non-null commands with ` && ` in the
order node, python, go, rust, and a note names the ecosystems.

### 9.4 `.cx/routes.json` (schema v1)

Keys in this order (the bundle template carries the defaults; detection fills `setup` and
`commands`):

```json
{
  "version": 1,
  "setup": "npm ci --prefer-offline",
  "commands": {"test": "npm test", "lint": "npm run lint", "typecheck": "npx tsc --noEmit"},
  "bench": null,
  "audit": null,
  "mutation": null,
  "protected": [],
  "high_risk": [],
  "diff_budget": 400,
  "pools": {"grok": true, "agy": true, "copilot": true},
  "docker_only": false,
  "review_family": {},
  "copilot_review_tier": "balanced"
}
```

| Key | Type | Meaning | Used from |
|---|---|---|---|
| `setup` | str\|null | Runs in every fresh worktree and gate checkout before anything else; executors never run it, except in dependency-upgrade tasks | Phase 1 skill, Phase 2 cx-run, Phase 3 cx-gate |
| `commands.test/lint/typecheck` | str\|null | The gate runs each non-null one; they are also the only shell commands executors are allowed | same |
| `bench` | str\|null | Performance tasks: run before and after on the same host | Phase 3 |
| `audit` | str\|null | Dependency-upgrade tasks | Phase 3 |
| `mutation` | null \| `{"command": str, "threshold": 0–100}` | Opt-in mutation gate | Phase 3 |
| `protected` | [glob] | Any change is a tamper finding unless the task allows it | Phase 3 |
| `high_risk` | [glob] | Full Claude read and a second (GPT) reviewer | Phase 4 |
| `diff_budget` | int | Max added + removed lines per task (the task may lower it) | Phase 3 |
| `pools` | {pool: bool} | Per-repo pool switch (U4: all true) | Phase 2 |
| `docker_only` | bool | v1.1: writers only in Docker lanes | v1.1 |
| `review_family` | {glob: `gemini\|gpt`} | Overrides the default reviewer family per path | Phase 4 |
| `copilot_review_tier` | `lite\|balanced\|max` | Which documented average cost the ledger books for a requested `@copilot` review | Phase 4 |

Globs: repo-relative POSIX paths; `**` matches any number of segments, `*` and `?` stay within a
segment. `.cx/routes.json` is itself protected (§16.1).

### 9.5 Templates (final text)

`templates/repo-bundle/AGENTS.md` (the block; `{{test}}` etc. render as `` `cmd` `` or as
`(none detected; set it in .cx/routes.json)`). Its rules are split: general rules bind everyone
(people, interactive agent sessions, the Copilot coding agent, and the conductor itself when a
repo imports `AGENTS.md` into `CLAUDE.md` with `@AGENTS.md`); worker-only rules apply only where
`.conductor/task.md` exists, i.e. inside a conductor worktree (P36 asserts the conditional
sentence verbatim):

```markdown
<!-- cx:begin conductor bundle v1: written by cx-init; edit freely, cx-init --force rewrites this block -->
## Rules for coding agents

General rules, for everyone working in this repository:

- Make the smallest change that meets the acceptance tests. No dead code, no commented-out code, and no options, flags or configuration nobody asked for.
- Match the existing style, naming and structure. Do not reformat code you did not change.
- Never weaken, delete or rewrite tests to make them pass.
- Run the commands below to check your work and report the results honestly.

If `.conductor/task.md` exists in your working directory (you are a conductor worker):

- It is your contract: do exactly what it says, and never edit it.
- Do not modify tests, test fixtures, lockfiles, CI configuration, `.cx/routes.json`, `.gitignore`, `.gitattributes` or git hooks unless the task says so explicitly.
- Do not install, upgrade or patch dependencies, and never edit installed packages to make a check pass.
- Do not commit, push, rebase or create branches. Your work is committed by the caller.
- Do not start subagents or other coding agents.
- Every claim you make is verified independently.

### Commands

- Setup (run by the caller before you start; do not run it unless your task says so): {{setup}}
- Test: {{test}}
- Lint: {{lint}}
- Typecheck: {{typecheck}}
<!-- cx:end -->
```

`templates/repo-bundle/copilot-instructions.md`:

```markdown
<!-- cx:begin conductor bundle v1: written by cx-init; edit freely, cx-init --force rewrites this block -->
## Code review

- Put correctness, security and data loss first; style last. Cite file:line for every finding.
- Flag tests that were weakened, deleted or rewritten to pass, and changes to lockfiles, CI or test configuration.
- Flag new options, flags or configuration the change does not need, and dead or duplicated code.
- Say when you are unsure. Do not invent APIs or behaviour.

## Coding agent

- Follow the general rules in AGENTS.md.
- In a conductor run (`.conductor/task.md` exists in the working directory), also follow AGENTS.md's worker-only rules.
- The worker-only rules do not apply to Copilot coding agent tasks assigned on GitHub: branch, commit and open a pull request as usual.
- Checks: test {{test}}, lint {{lint}}, typecheck {{typecheck}}.
<!-- cx:end -->
```

`templates/repo-bundle/routes.json`: §9.4 with `setup` and `commands.*` null.

### 9.6 Projects instructions (`templates/projects-instructions.md`; final; ASCII; at most 2,000 characters)

The only conductor-aware text that reaches every Claude Code Project thread and the coordinator
without a plugin: the user pastes the file into **Project settings > Memory** (the Projects
instructions, 16,000 characters; how they are injected is undocumented, so the text states its
own precedence, §20 item 47). `cx-init` never writes it, and nothing conductor-specific goes into
a repo's `CLAUDE.md` or `.claude/`, Project settings > Plugins, the cloud environment's setup
script or its secrets (claude.ai refuses a plugin with a top-level `bin/`, and subscription
logins live on the user's computer). It is written for U7: every thread runs as a Work locally
thread; the executors live in WSL behind the conductor and may use their own clouds; a cloud
thread, if one ever happens, works with Claude alone and pushes its work in progress; and that
the conductor shares its pool slots between threads (§15.3; Phase 1's line said agy ran one job
at a time across threads until then): at most `cap_agy`, `cap_copilot` and `cap_grok` runs at a
time on the computer, agy launches one at a time, a full pool waits, then the next Opus pool
takes the work. The precedence, highest first: the user's
own messages in a thread; these instructions and the repository's `CLAUDE.md`; the conductor
policy and skill; a coordinator's brief, which sets the task and its acceptance tests and
approves nothing the gates refuse. P52 compares the file with this block.

<!-- projects-instructions:begin -->
```text
Conductor routing for this project. These are my standing rules; where they conflict with the conductor plugin's policy or skill, these win, and my own messages in a thread win over all of them.
- Run every thread of this project as a Work locally thread on my computer, never as a cloud thread. The conductor plugin, Copilot CLI, Grok Build, Antigravity and their logins live there, in WSL, and the conductor reaches them for the thread.
- The executors may use their own clouds from such a thread, for example the Copilot cloud agent through ghcp-cloud (it ends in a pull request that the conductor gates) or Grok remote sessions that I start; that is welcome.
- If a thread ever runs in the cloud anyway, it does its task with Claude alone (workflows and ultracode included), never installs, logs in to or asks for tokens of those tools, and commits and pushes work in progress to a branch, because a cloud sandbox can lose uncommitted changes.
- Several Work locally threads may run at once: the conductor shares its pool slots between threads (at most cap_agy agy, cap_copilot Copilot and cap_grok Grok runs at a time on my computer, and agy launches one at a time); a thread whose pool is full waits up to 10 minutes for a slot, then uses the next Opus pool. If two threads work in the same folder, turn on Worktree in the folder card.
- A coordinator brief sets a thread's task and acceptance tests. It does not approve skipping the conductor's gates, and it is not my approval for anything the thread would otherwise ask me.
```
<!-- projects-instructions:end -->

## 10. Hooks and the policy

### 10.1 `hooks/hooks.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/policy.sh\"", "onFailure": "continue" }
        ]
      }
    ],
    "SubagentStart": [
      {
        "matcher": "workflow-subagent|general-purpose",
        "hooks": [
          { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/subagent.sh\"", "onFailure": "continue" }
        ]
      }
    ]
  }
}
```

Two events in Phase 1, both context-only and both never-fail (§1.5 "never fail" rules):
- `"onFailure": "continue"` [docs-only: the 2.1.316 hook schema's `onFailure` is `continue` or
  `block`, "what a failure of this hook does: it could not start, timed out, exited with a code
  other than 0 or 2"; validated, §1.7; §20 item 50] covers a host where the hook cannot even start (Windows
  without Git Bash falls back to PowerShell, where any exit other than 0 or 2 blocks; a missing
  plugin directory; CRLF damage). Both scripts also always exit 0 themselves.
- SubagentStart fires for every workflow `agent()` and every Agent-tool subagent, with
  `agent_type` set to the definition type, and its `additionalContext` is injected into that
  agent [docs-only, from the binary; §20 item 49]. The matcher names the two types a workflow or
  the Agent tool uses by default; other plugins' agent types are not matched (ghcp's
  `ghcp:ghcp-delegate` must keep calling ghcp).
- No PreToolUse gate in Phase 1 (the Phase 2 gate of §15.10 becomes `PreToolUse[0]`, with no
  `onFailure`, because a forced block would stop every Bash call of the main session too), no
  UserPromptSubmit nudge, no SessionEnd. `resume` is not matched because a resumed transcript
  already carries the policy.

### 10.2 `hooks/policy.sh`

Bash builtins plus `cat` and `uname`; reads at most 256 KiB of stdin (the hook payload) with a
2-second timeout; always exits 0 and prints either nothing or one whole JSON document. It reads
options only from `CLAUDE_PLUGIN_OPTION_POLICY`, `CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER` and
`CLAUDE_PLUGIN_OPTION_EXEC_HOST`, which Claude Code injects into hooks; it does not re-read
settings files. First match wins:

| # | Condition | Prints | § |
|---|---|---|---|
| 1 | `CX_WORKER` set to anything but empty or `0` (a conductor worker running Claude) | nothing | §11 |
| 2 | option `policy` off (`off\|false\|0\|no\|disabled`, any case, spaces ignored) | nothing | §5.1 |
| 3 | the payload has a non-empty `"agent_id"` string: a **subagent** is compacting (SessionStart `compact` carries that agent's context [docs-only, from the binary; §20 item 60]) | `hooks/subagent-context-compact.json` when `"agent_type"` is `workflow-subagent` or `general-purpose`; else nothing (a plugin agent such as `ghcp:ghcp-delegate` keeps its own rules, and the main policy would invite a subagent to start delegating on its own) | §10.7 |
| 4 | `CLAUDE_CODE_REMOTE` truthy (`1\|true\|yes\|on`, any case, spaces ignored) and `CLAUDE_CODE_ENVIRONMENT_KIND` not `bridge`, except any non-empty kind (BYOC: `byoc`, `self_hosted`, any other) with option `exec_host=local`; and never on the user's computer: not when `uname -s` is `MINGW*`/`MSYS*`, `WSL_DISTRO_NAME` is set, `/proc/sys/fs/binfmt_misc/WSLInterop*` exists (under `CX_DETECT_ROOT`) or `uname -r` contains `microsoft` (Anthropic's cloud containers are plain Linux, and a false cloud verdict would switch the conductor off on its own executor host) | `hooks/policy-context-cloud.json`; nothing when it is unreadable (in the cloud silence is correct and the WSL policy would be wrong) | §10.6 |
| 5 | the first line of `bin/cx-doctor`, `scripts/lib/common.sh` or `scripts/host/forward-wsl.sh` ends in CR (`IFS= read -r l < "$f"; [[ $l == *$'\r' ]]`, builtins only) | `hooks/policy-context-crlf.json` | §10.5 |
| 6 | `uname -s` matches `MINGW*` or `MSYS*` (missing `uname` = no match: fail open to the default) | `hooks/policy-context-gitbash.json` | §10.4 |
| 7 | otherwise | `hooks/policy-context.json` | §10.3 |

A `--agent` main thread has `agent_type` but no `agent_id`, so it gets the main policy. Row 4
duplicates `cx_session`'s truth table (§7.1) with builtins only: the two change together. Cloud
comes before the CRLF canary because both route nothing and only the cloud text is true in the
cloud.

It then replaces two placeholders with phrases composed only of constants, so the JSON stays
valid without escaping and no option text ever reaches it:
- `{ORDER}`: the trimmed, lowercased `opus_lane_order` must consist of `[a-z,]` only with no
  empty segment (no leading, trailing or doubled comma: the grammar `^[a-z]+(,[a-z]+)*$` of
  `cx_opt_check`, §5.3, in pure bash), else the default, so the session policy and the scripts
  always agree on the order in force; `claude` is appended when missing, each distinct token
  maps to `agy (raw)`, `Copilot` or `own subagents`, and the pieces are
  joined with `, then `; an unknown or repeated token gives the default phrase
  `agy (raw), then Copilot, then own subagents`. agy is labelled raw: under `cx-run --exec auto`
  its Opus lane always runs the agy CLI itself, the only mode that verifies the served model
  (§15.1); no label names a wrapper to call. The A/B's result
  (§6.7) therefore takes effect at the next session start without regenerating any file.
- `{ATTN}`, at the end of the last line of both policies: when `CLAUDE_CODE_SESSION_ATTENDED=0`
  and the session is not a bridge child (headless `claude -p`, scheduled and background
  sessions, §7.1), the 246-character sentence ` UNATTENDED RUN: nobody approves prompts or
  reads a later turn, so commands outside the allow rules are denied; wait for jobs with
  consecutive foreground waits of at most 9 minutes (not background Bash) and report any job
  still running by its id.`; otherwise nothing.

The phrases contain no `&` and no backslash (bash 5.2's `patsub_replacement` would expand `&`
in the replacement).

CRLF-tolerant by construction: no blank lines, and every line after the shebang either is a
comment or ends with ` #`, so a CR from a CRLF checkout lands inside a comment (the shebang does
not matter: hooks.json runs `bash <file>`). Reference text:

```bash
#!/usr/bin/env bash
# hooks/policy.sh - SessionStart (startup|clear|compact): print the conductor policy as #
# hookSpecificOutput.additionalContext (docs/DESIGN.md section 10). Bash builtins plus cat and #
# uname; reads at most 256 KiB of stdin with a 2-second timeout; always exits 0 (fails open). #
# Silent when CX_WORKER is set (a conductor worker) or option policy is off. A compacting #
# workflow-subagent or general-purpose agent gets the subagent guard instead, another agent #
# nothing; a cloud session, or BYOC (any kind but bridge) without exec_host=local, gets the cloud #
# notice, never on Git Bash or WSL (the user's computer). Every line ends in " #" (CRLF-safe). #
set -uo pipefail #
case "${CX_WORKER:-}" in ""|0) ;; *) exit 0 ;; esac #
p="${CLAUDE_PLUGIN_OPTION_POLICY:-on}" #
p="${p//[[:space:]]/}" #
shopt -s nocasematch #
case "$p" in off|false|0|no|disabled) exit 0 ;; esac #
shopt -u nocasematch #
d="${BASH_SOURCE[0]%/*}" #
[ "$d" != "${BASH_SOURCE[0]}" ] || d=. #
i= #
IFS= read -r -d '' -t 2 -n 262144 i 2>/dev/null #
re='"agent_id"[[:space:]]*:[[:space:]]*"[^"]' #
if [[ $i =~ $re ]]; then #
  re='"agent_type"[[:space:]]*:[[:space:]]*"(workflow-subagent|general-purpose)"' #
  [[ $i =~ $re ]] && [ -r "$d/subagent-context-compact.json" ] && cat -- "$d/subagent-context-compact.json" #
  exit 0 #
fi #
q="${CLAUDE_CODE_REMOTE:-}" #
q="${q//[[:space:]]/}" #
e="${CLAUDE_PLUGIN_OPTION_EXEC_HOST:-auto}" #
e="${e//[[:space:]]/}" #
c= #
case "${q,,}:${CLAUDE_CODE_ENVIRONMENT_KIND:-}:${e,,}" in 1:bridge:*|true:bridge:*|yes:bridge:*|on:bridge:*|1:?*:local|true:?*:local|yes:?*:local|on:?*:local) ;; 1:*|true:*|yes:*|on:*) c=1 ;; esac #
u="$(uname -s 2>/dev/null)" #
if [ -n "$c" ]; then #
  case "$u" in MINGW*|MSYS*) c= ;; esac #
  [ -n "${WSL_DISTRO_NAME:-}" ] && c= #
  for w in "${CX_DETECT_ROOT:-}"/proc/sys/fs/binfmt_misc/WSLInterop*; do [ -e "$w" ] && c=; done #
  case "$(uname -r 2>/dev/null)" in *[Mm]icrosoft*) c= ;; esac #
fi #
if [ -n "$c" ]; then [ -r "$d/policy-context-cloud.json" ] && cat -- "$d/policy-context-cloud.json"; exit 0; fi #
f="$d/policy-context.json" #
case "$u" in MINGW*|MSYS*) f="$d/policy-context-gitbash.json" ;; esac #
for c in "$d/../bin/cx-doctor" "$d/../scripts/lib/common.sh" "$d/../scripts/host/forward-wsl.sh"; do #
  l= #
  { IFS= read -r l < "$c"; } 2>/dev/null #
  case "$l" in *$'\r') f="$d/policy-context-crlf.json"; break ;; esac #
done #
o="${CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER:-}" #
o="${o//[[:space:]]/}" #
o="${o,,}" #
case "$o" in ""|*[!a-z,]*|,*|*,|*,,*) o=agy,copilot,claude ;; esac #
case ",$o," in *,claude,*) ;; *) o="$o,claude" ;; esac #
r= #
s=, #
for x in ${o//,/ }; do #
  case "$s" in *",$x,"*) r=; break ;; esac #
  s="$s$x," #
  case "$x" in agy) y='agy (raw)' ;; copilot) y='Copilot' ;; claude) y='own subagents' ;; *) r=; break ;; esac #
  r="${r:+$r, then }$y" #
done #
[ -n "$r" ] || r='agy (raw), then Copilot, then own subagents' #
[ -r "$f" ] || exit 0 #
t="$(cat -- "$f" 2>/dev/null)" || exit 0 #
a= #
case "${CLAUDE_CODE_SESSION_ATTENDED:-}:${CLAUDE_CODE_ENVIRONMENT_KIND:-}" in 0:bridge) ;; 0:*) a=' UNATTENDED RUN: nobody approves prompts or reads a later turn, so commands outside the allow rules are denied; wait for jobs with consecutive foreground waits of at most 9 minutes (not background Bash) and report any job still running by its id.' ;; esac #
k='{ORDER}' #
t="${t//"$k"/$r}" #
k='{ATTN}' #
printf '%s\n' "${t//"$k"/$a}" #
exit 0 #
```

Each hook JSON file is `json.dumps(obj, indent=2, ensure_ascii=True) + "\n"`, generated from
the blocks of this file: `hooks/policy-context.json` and `hooks/policy-context-gitbash.json` are
`{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": POLICY}}`, where
POLICY is the §10.3 or §10.4 block with its lines joined by `\n` and no trailing newline;
`hooks/policy-context-crlf.json` and `hooks/policy-context-cloud.json` are the same shape plus a
top-level `"systemMessage"` (user visible), from the two §10.5 or §10.6 blocks; the two subagent
files are §10.7. Tests compare every file with its block (P20, P47, P55) and render every order
(P21). If live check L10 shows that Windows hooks run through `cmd.exe` and WSL's `bash.exe`
(§20 item 12), the host test above must change with the hook command.

### 10.3 Policy text, WSL and Linux (final; at most 2,771 characters rendered, ASCII; limit 2,800)

Phase 2 (§15) routes every lane through `cx-run` and `cx-job` (`cx-fanout` joins in Phase 3):
the policy names their forms and makes Claude load the skill, whose commands are complete
(§12.2), before the first delegation. `cx-run` registers agy directories itself, so the Phase 1
inline registration command is gone; the hand steps that remain (commit and gate, GitHub) live in
the skill. These blocks change in the same commit as the JSON files. `{ORDER}` and `{ATTN}` are rendered by
`policy.sh` (§10.2). Every lane it names is one the conductor may use outside Docker:
`agy-media`, `/antigravity:research` and `agy-handoff` always pass `--yolo` (machine-wide, §0.3,
G10) and are named only to forbid them, as are the proactive `antigravity-delegate` and
`grok-delegate` subagents (§6.6). `ghcp-delegate --github` adds every GitHub MCP tool acting as
the user, so triage fetches with `gh` and runs a read-only `ghcp-delegate` instead (§12.2 step
5). A background Bash call is stopped at its `timeout` too (default 30 minutes, §1.1), so the
policy names the 2-hour maximum.

The Workflows line (§1.7 "Workflows and ultracode") tells the main loop, which alone receives
the ultracode reminders ("use the Workflow tool on every substantive task"), that ultracode
changes thoroughness, not who executes: workflows run Claude stages and the own-subagent pool;
executor lanes start from the main turn between workflows (the hybrid, §12.1), a workflow agent
runs one only through `cx-run --background` and `cx-job wait` when its task says so (the Phase
2 guard, §10.7), and the pool slots are shared by every session and Work locally thread of the
computer (§15.3, the first item of Phase 2; Phase 1's line said "one agy run at a time"): a full
pool waits `CX_SLOT_WAIT_SECS` (10 minutes), then exits 28 and the next pool takes the work.
The limit is 2,800 rendered
characters (the 2.1.316 binary caps `additionalContext` at 8,000 [docs-only]). P20 and P57
assert these items.

<!-- policy:begin -->
```text
CONDUCTOR POLICY (replaces sibling policies). You own spec, gates and merge; executors draft. Without asking you may spend Copilot credits and agy quota, push cx/* branches, open PRs and request @copilot reviews. No spend caps.
- Before your first delegation, load the conductor skill and copy its commands verbatim. Delegate through cx-run: it makes the cx/<id> worktree under worktree_root (default ~/.cx-wt), runs setup, takes the shared pool slot, scrubs the env, registers agy dirs (--new-project), checks denials and served model; you commit and gate (skill Step 3).
- Do yourself: architecture, one-way doors, xhigh/max reasoning, debugging hypotheses, merge conflicts, small or judgement-heavy edits.
- Opus 5.5 offload at high, strong acceptance tests required, in order: {ORDER} (cx-run --exec auto). One task, one cx-run id, contract .conductor/task.md.
- Workflows (ultracode too): use them for Claude stages (scouting, design panels, reviews, verification) and for own-subagent Opus tasks at effort high in a cx-run --exec claude worktree, never with isolation worktree or remote. Start executor runs from your own turn between workflows; a workflow agent runs one only through cx-run --background and cx-job wait, when its task says so. Pool slots are shared by all sessions and threads on this computer: a full pool waits up to 10 minutes, then exits 28 (use the next pool).
- Exploration, mechanical edits, tests to your contract, reference docs: cx-run --exec grok (never the grok-build plugin).
- PRs, CI: gh pr edit N --add-reviewer @copilot; cx-wsl ghcp-ci-debug without --apply. Triage: gh fetch + cx-run --mode read --exec copilot (ghcp-delegate --github acts as you).
- Second opinion: cx-run --mode review --family gemini on Opus-written code, plus --family gpt on high-risk paths; you review Grok/Gemini code. Opus on Opus is not independent. Security: you + GPT + CodeQL, never Grok alone.
- Digests over 200k tokens: cx-run --mode read --exec agy with Argon. Never agy-media, agy-handoff or /antigravity:research (always --yolo).
- Results are claims: exit 0 is not success (read CX_RESULT and VERIFY THIS); rerun the tests yourself on a clean checkout; read digests, not transcripts.
- Long runs: cx-run --background, then one background Bash call with timeout 7200000 running cx-job wait <id> (default: 30 min); never wait across turns.
- cx-run, cx-job, gh and git push run outside the Bash sandbox. Never use the antigravity-delegate or grok-delegate agents.{ATTN}
```
<!-- policy:end -->

### 10.4 Policy text, Windows / Git Bash (final; at most 2,680 characters rendered, ASCII; limit 2,800)

Injected when Claude Code runs in Git Bash (the Windows app). Nothing that the WSL variant names
exists on the Windows side, so every executor run goes through `cx-run`/`cx-job` (they forward
themselves) and every other WSL tool through `cx-wsl` (§7.7); the policy also forbids the two
tempting wrong fixes (installing the siblings natively, worktrees made with Git for Windows
under `C:\Users`). It shows no raw command: the hand steps run as files through `cx-wsl bash
-s`, and `gh` and `ghcp-ci-debug` carry the `cx-wsl` prefix, since a native Windows `gh` would
act on the wrong side. Its Workflows line is the §10.3 one with the WSL worktree reached through
its `\\wsl.localhost` path (file tools) and `cx-wsl bash -c` (commands), the same forms as the
skill's claude lane. It names only the `cx-wsl` uses that are left (`gh`, `git`, `ghcp-cloud
list`/`view`, `ghcp-ci-debug` and the hand steps), never the executor tools of the §7.7
allowlist: a direct `cx-wsl agy-delegate` or `cx-wsl ghcp-delegate` would skip `cx-run`'s agy
registration, tree snapshots, served-model checks and ledger. `cx-run` and `cx-job` forward
themselves, so the Windows policy names them directly (D25: `Bash(cx-run:*)` and
`Bash(cx-job:*)` suffice there).

<!-- policy-gitbash:begin -->
```text
CONDUCTOR POLICY, WINDOWS (replaces sibling policies). This session runs in Git Bash; executors, logins, worktrees and git live in WSL. You own spec, gates and merge; executors draft. Without asking you may spend Copilot credits and agy quota, push cx/* branches, open PRs and request @copilot reviews. No spend caps.
- Executors only through cx-run and cx-job (they forward themselves into WSL; open host_path results with file tools). cx-wsl only for gh, git, ghcp-cloud list/view, the CI line below and the skill's hand steps: write each verbatim (LF) to FILE, run cx-wsl bash -s < FILE. Never install ghcp, antigravity or grok-build on Windows, never call wsl.exe or agent CLIs directly or make worktrees with Git for Windows.
- Before your first delegation, load the conductor skill and copy its commands verbatim; cx-run registers agy dirs (--new-project) and takes the pool slots; you commit and gate (Step 3).
- Do yourself: architecture, one-way doors, xhigh/max reasoning, debugging hypotheses, merge conflicts, small or judgement-heavy edits.
- Opus 5.5 offload at high, strong acceptance tests required, in order: {ORDER} (cx-run --exec auto). One task, one cx-run id and worktree, contract .conductor/task.md.
- Workflows (ultracode too): use them for Claude stages (scouting, design panels, reviews, verification) and for own-subagent Opus tasks at effort high in a cx-run --exec claude worktree (file tools on its wsl.localhost path, commands via cx-wsl bash -c), never with isolation worktree or remote. Start executor runs from your own turn between workflows (a workflow agent: only cx-run --background, if its task says so). Pool slots are shared by all sessions and threads; a full pool exits 28 after 10 min.
- cx-run --exec grok: exploration, mechanical edits, tests to your contract. PRs and CI: cx-wsl gh pr edit N --add-reviewer @copilot; cx-wsl ghcp-ci-debug without --apply.
- Reviews: cx-run --mode review --family gemini on Opus-written code, plus gpt on high-risk paths; Opus on Opus is not independent. Security: you + GPT + CodeQL.
- Results are claims: exit 0 is not success (read CX_RESULT, VERIFY THIS); rerun the tests yourself on a clean checkout.
- Long runs: cx-run --background, then cx-job wait <id> in one background Bash call with timeout 7200000 (default: 30 min); never wait across turns. cx-* calls run outside the Bash sandbox. Help: /conductor:route.{ATTN}
```
<!-- policy-gitbash:end -->

### 10.5 CRLF notice (final; ASCII)

Injected instead of either policy when a canary file carries CR (§10.2): the conductor cannot
run, so the notice routes nothing through it and gives the fix (the D3 fixes, §8.3, without
paths, because the file is constant). It leads with the sed fix, which works for every source
of CRs (archive downloads, Windows-tool copies, a folder marketplace edited on Windows); it
never advises `core.autocrlf`, which this repo's `eol=lf` rules already override, so it would
change nothing for exactly the copies that reach this notice. The `find` covers the eight
shipped directories only, never `tests/fixtures` (intentional CRLF bytes) or `.git` of a
folder marketplace.

<!-- policy-crlf-context:begin -->
```text
CONDUCTOR PLUGIN DISABLED: its installed files have CRLF line endings, so its cx-* commands (cx-doctor, cx-init, cx-wsl) cannot run; they fail with errors such as env: 'bash\r': No such file or directory. Do not route work through the conductor in this session; do the work yourself. The user has been shown the fix; apply it only when the user asks: in the plugin's install folder (the installPath of conductor@conductor-for-claude-code in ~/.claude/plugins/installed_plugins.json, or under CLAUDE_CONFIG_DIR when that is set) run find .claude-plugin bin scripts hooks worker-shims templates skills commands -type f -exec sed -i 's/\r$//' {} +, then cx-doctor. If the plugin comes from a folder (directory) marketplace edited with Windows tools, convert that source folder the same way, or the next update copies the CRs back; for an archive install, claude plugin marketplace update conductor-for-claude-code && claude plugin update conductor@conductor-for-claude-code (or a reinstall) also works. Never use git commands inside the plugin's install folder to repair it.
```
<!-- policy-crlf-context:end -->

<!-- policy-crlf-system:begin -->
```text
conductor: this plugin copy has CRLF line endings, so its cx-* commands cannot run and its routing policy is off. Fix: in its install folder (the installPath of conductor@conductor-for-claude-code in ~/.claude/plugins/installed_plugins.json) run find .claude-plugin bin scripts hooks worker-shims templates skills commands -type f -exec sed -i 's/\r$//' {} +, then run cx-doctor. A folder (directory) marketplace edited with Windows tools needs the same fix in its source folder; an archive install can instead be refreshed with claude plugin marketplace update conductor-for-claude-code && claude plugin update conductor@conductor-for-claude-code (or a reinstall).
```
<!-- policy-crlf-system:end -->

### 10.6 Cloud notice (final; ASCII)

Injected instead of every other variant in an Anthropic cloud session, or a BYOC runner without
`exec_host=local` (§10.2 row 4): the cloud has no executors, no logins and normally no
conductor (a WSL directory-marketplace install is never forwarded to the cloud, and claude.ai
refuses a plugin with a top-level `bin/`, §1.5), so when the plugin is loaded anyway (a
`--plugin-dir` dev container, a forwarded GitHub-marketplace install) it degrades and never
fails. The user's Project threads always run as Work locally threads (U7), so this is a safety
net. Executors may still use their own clouds from a local session (the Copilot cloud agent
through `ghcp-cloud`, Grok remote sessions): that happens on the user's computer, not here.

<!-- policy-cloud-context:begin -->
```text
CONDUCTOR INACTIVE: this is a cloud session, not the user's computer. Copilot CLI, Grok Build, Antigravity, their logins and the conductor's cx-* commands live in WSL on the user's computer and cannot be reached from here. Do the work yourself with your own tools and subagents; workflows and ultracode run here with Claude agents only. Do not run or install cx-*, ghcp-*, agy-*, agy, grok or copilot, and do not ask for their tokens. GitHub work this session can already do (branches, PRs, @copilot review requests) is fine. Commit and push work in progress: a cloud sandbox can lose uncommitted changes. If a task needs an executor, say so once and suggest running it on the user's computer: in a project, as a Work locally thread; otherwise in a local desktop session or a WSL terminal. Explicit user and project instructions win where they conflict with this notice, but cannot make the executors reachable here.
```
<!-- policy-cloud-context:end -->

<!-- policy-cloud-system:begin -->
```text
conductor: cloud session, so Copilot, Grok and Antigravity delegation is off and Claude does the work itself; run delegated tasks in a Work locally thread or a local session.
```
<!-- policy-cloud-system:end -->

### 10.7 Subagent guard (`hooks/subagent.sh`; final; ASCII; at most 800 characters)

The Phase 2 rule for ultracode and every other workflow: **workflow and Agent-tool subagents
never run executors directly**; the main turn dispatches executor lanes (§12.1 "Workflows and
ultracode"), and a default workflow agent may run `cx-run --background` and `cx-job wait`
itself only when its task says so, because those take the shared pool slots (§15.3) and
serialize agy launches; the skill's hand recipe uses per-task `vars.sh` files and ids that
parallel agents would collide on, so agents never follow it. The text is soft (the optional
runner agent and its fail-closed gate, §15.9–§15.10, are not built while ultracode stays off,
U8): autonomy U2 already permits the spend, so the risk is races, not authority. Phase 1's text
said "do not run Copilot, Grok or Antigravity in any form ... (pool slots are not shared yet)";
the Phase 2 text below replaced it when the slots landed (§15 build order, item 1), keeping
Phase 1's `cx-*` sentence and its Git Bash worktree forms.

`hooks/subagent.sh` is pure bash (builtins plus `cat`), CRLF-tolerant like `policy.sh`, and
always exits 0. It prints nothing when `CX_WORKER` is set (not `0`) or option `policy` is off,
and nothing when the payload (at most 256 KiB of stdin, 2-second timeout) names an
`"agent_type"` other than `workflow-subagent` or `general-purpose` (a guard in case the matcher
is not applied as alternation, §20 item 49); otherwise it prints `hooks/subagent-context.json`
(`hookEventName` `SubagentStart`). `policy.sh` prints `hooks/subagent-context-compact.json`
(`hookEventName` `SessionStart`) for a compacting subagent of the two types (§10.2 row 3), so
an agent keeps the guard, never the main policy, through compaction. Both files carry the
block below as `additionalContext`. The cloud and CRLF cases print the same guard, because it is
true there too. The executor names in it change together with the policy's and, in Phase 2,
with the gate's executor guard. Its worktree sentence covers both hosts: in WSL the agent works
in `~/.cx-wt/<repo>-<id>` with absolute paths; in Git Bash (the Windows app) `~` is the Windows
home, so it uses the worktree's `\\wsl.localhost` path for file tools and `cx-wsl bash -c` for
commands, as §12.2 step 2d and the claude-pool script's `wt_win` say.

<!-- subagent-context:begin -->
```text
CONDUCTOR SUBAGENT RULES (a workflow or the Agent tool started you in a conductor session). Never run Copilot, Grok or Antigravity directly (ghcp-*, agy-*, agy, grok, copilot, or cx-wsl with any of them): executor work goes only through cx-run --background and cx-job wait, which take the shared pool slots, and only when your task says so; otherwise return EXECUTOR_NEEDED: <lane> - <one-line reason>. Other cx-* commands: only cx-wsl bash or cx-wsl git, for your own task. If your task names a conductor worktree (~/.cx-wt/<repo>-<id> in WSL), work only inside it with absolute paths (in Git Bash: file tools on its wsl.localhost path, commands via cx-wsl bash -c, never ~), leave .conductor/ unchanged, and do not commit, push or open PRs. End with the tests you ran and their results.
```
<!-- subagent-context:end -->

The block above is the Phase 2 text (`subagent-context-p2` of the 2026-11-01 drafts, plus the
`cx-*` sentence and the Git Bash worktree forms of Phase 1; 788 characters).

## 11. Worker shims (`worker-shims/`)

Phase 1 ships one file per agent binary name: `claude`, `copilot`, `grok`, `agy`, `codex`,
`gemini`, `cursor-agent`, `agent`. Each is exactly (only `<name>` differs):

```bash
#!/usr/bin/env bash
# worker-shims/<name>: stands in for an agent CLI on a conductor worker's PATH (docs/DESIGN.md section 11).
printf 'blocked: CX_WORKER\n' >&2
exit 126
```

Contract (P24): whatever the arguments, environment or stdin, it writes exactly
`blocked: CX_WORKER` and a newline to stderr, nothing to stdout, reads no stdin, has no other
effect, and exits 126 ("found but not executable": distinct from every executor and conductor
code; no `CX_SIGNAL`, because it runs inside the worker). LF, mode 0755, regular files (no
symlinks). Phase 2 adds the same file for every sibling wrapper and conductor bin:
`ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-cloud ghcp-models ghcp-doctor
agy-delegate agy-handoff agy-job agy-media agy-doctor cx-run cx-job cx-fanout cx-gate cx-doctor
cx-init cx-wsl`.

Built (Phase 2 item 2): the 19 Phase 2 files exist; the agy wrapper lane's set is
`$CX_HOME/shimsets/agy/` (rebuilt when the runtime's shim list or `CX_VERSION` changes, through
a `.stamp` file).

Use (Phase 2, §15.6): every worker runs with `CX_WORKER=1` and
`PATH="<shim dir>:<host record path>"`; executors themselves are started by absolute path, so the
shims only stop what the worker would start. Lanes that go through a wrapper which finds its
executor by name (agy-delegate uses `command -v agy`) get a shim set without that name:
`$CX_HOME/shimsets/<sorted excluded names joined by ->/`, a copy of the runtime's `worker-shims/`
minus the excluded files, built once, atomically. Deny rules in worker settings are a second
layer only.

## 12. Skill and commands

### 12.1 `skills/conductor/SKILL.md`

Frontmatter: `name: conductor`; `description:` one paragraph naming the triggers: which
subscription or model should do a task, delegate or offload work, Opus fan-out, parallel
workers, Copilot / Grok / Antigravity / agy, cross-model or second-opinion review, PR or CI
triage, media or Google-grounded research, cx-doctor, cx-init, cx-wsl, worktree task contracts.

A preface, the first paragraph after the title (P61): "**If you are a subagent or a workflow
agent, do not run anything in this skill: return `EXECUTOR_NEEDED: <lane> - <reason>` and let
the main session dispatch, unless your task names a `cx-run --background` command: then run
only that, and `cx-job wait` for it.**" (the Phase 2 wording; Phase 1 ended at "dispatch").

Body sections (in this order; each cites the DESIGN § it condenses, so a §6 change updates the
skill in the same commit):
1. Roles: Claude owns spec, gates, merge; executors draft; autonomy and no caps (U2, U3).
2. Routing table (§6.2) and lanes (§6.1).
3. Opus pool order, A/B status and effort map (§6.3, §6.7); the order actually in force is the
   one the session-start policy names (rendered from `opus_lane_order`, §10.2).
4. Recipe and exact lane commands (§12.2, verbatim; Phase 2: `cx-run` and `cx-job`): the rules
   for every call, then the headings in this order (P43): Step 1 the contract; Step 2 dispatch
   (`--exec auto` and the explicit lanes, the claude lane with `--finish`, the read lanes,
   commit-message drafting); Step 3 after every run (the hand commit and gate); Step 4 reviews
   (`--mode review`); Step 5 GitHub (hand steps; the Copilot cloud agent through `cx-run --exec
   copilot-cloud` and `--finish`); From Windows (Git Bash). Then two subsections (P61), in this
   order:
   - **Workflows and ultracode** (§1.7, §10.7; U8): the levers; "ultracode changes how
     thorough you are, not who executes"; the hybrid: (1) a Claude-only scout or design
     workflow returns the decomposition with disjoint files per task; (2) the main turn writes
     every contract (Step 1); (3) the main turn starts the executor runs with `cx-run
     --background` and waits with one background `cx-job wait` each (the slots cap them
     across the computer); (4) for the claude-pool tasks the main turn runs `cx-run --exec
     claude` per task (worktree, setup, running mark, dispatch JSON), then a claude-pool
     workflow, in parallel, works in those worktrees at effort high without isolation (on
     Windows each task also gets `wt_win`, the dispatch's `host_path`, and the prompt sends
     file tools there and commands through `cx-wsl bash -c`), then `cx-run --finish` per task;
     (5) the main turn collects, runs Step 3 per task and Step 4. Never `isolation:
     'worktree'` or `'remote'`; no `agentType` and never another plugin's delegate agent;
     `budget` counts Claude output only and never sizes or caps executor work (U3);
     `EXECUTOR_NEEDED` → the main turn dispatches that lane; a default workflow agent may run
     `cx-run --background` and `cx-job wait` when its task names them; the claude-pool script
     (a static `meta` literal, `parallel()` of one `agent()` per task with `effort`, no
     `Date.now`/`Math.random`). `bashCommandClamp` is never mentioned.
   - **In a Claude Code Project** (§1.7, §9.6; U7): every thread is a Work locally thread
     (`session bridge`), the precedence list of §9.6, the shared pool slots (§15.3: caps per
     pool across threads, agy launches one at a time; a full pool waits, then the next pool),
     auto mode relying on the D25 allow rules,
     and the reply tool for a thread's final text.
5. Guardrails checklist (§6.5) and the after-run checklist (§12.2 step 3), which records the
   agy served model as `unverified (wrapper)` unless the raw arm checked it.
6. Hazards (§6.6).
7. Exit codes (§4.1, with a `| 130 | CANCELLED |` row) and the sibling wrappers' codes that
   matter: ghcp 10–16, agy-delegate 12 (partial) and 15 (missing grant), ghcp-handoff 20,
   ghcp-job result 75 (running), agy-job result 2 (running).
8. Troubleshooting: exit 16 → rerun the Bash call outside the sandbox; agy or grok failing with
   permission or `EROFS`/`Read-only file system` text, or agy hanging, inside the sandbox →
   rerun unsandboxed (agy has no exit 16, so this shows as 2, 11 or a hang); exit 130 from ghcp
   after about 2 minutes → the call ran in the foreground and the Bash tool killed it: rerun it
   in the background; 11 → `cx-doctor --login-help <cli>` (logged in from a WSL terminal but not
   through `cx-wsl` → keyring, §8.5); 26 → version pins; `wrong_tree`; `permission required:`;
   gh without `@copilot` reviewer support → the REST fallback of step 5.

### 12.2 Lane commands (exact; Phase 2: `cx-run` and `cx-job`, hand steps where they have no lane)

Phase 2 replaces the Phase 1 hand recipe (one block per lane with its environment prefix, the
registration, the slot line and the `trees` snapshots; kept in the git history of this file,
release 0.1.0) by `cx-run` (§15.1) and `cx-job` (§15.5): they create the worktree, copy the
contract and record its hash, run `setup`, take the pool slot, build the worker environment,
register agy directories, snapshot the other worktrees for agy, classify denials and the served
model and write `result.json`, the ledger line and `CX_RESULT`. `cx-run` also writes
`$OUT/vars.sh` (`ID TOP BASE WT OUT REPO P G_ENV`), the same file Phase 1's Step 1 wrote, so the
hand steps that remain keep their first line: the conductor commit and gate (Step 3, until
§16's `cx-gate`), GitHub (Step 5) and commit-message drafting (Grok with the diff in a prompt
file). The text below is the skill's section 4 verbatim from "Rules for every call" on (P43
compares every bash line). Never export `CLAUDE_PLUGIN_OPTION_*` globally (both siblings read
the same names).

### Rules for every call

- **Background for long calls.** A write run may take 30 minutes or more: start it with
  `cx-run --background …`, which prints `JOB_ID <id>` at once, and wait for it with ONE
  background Bash call `cx-job wait <id>` (that JOB_ID, never the task's `--id`) with
  `run_in_background: true` and `timeout: 7200000` (the 2-hour maximum; the tool notifies you
  when it exits). A background call is stopped at its timeout too, and the default (30
  minutes) is shorter than a 30m run plus setup and agy's grace. Only runs with `--timeout
  9m` or less, `--dry-run`, `--explain`, the claude dispatch and `--finish` may run in the
  foreground. Never wait by re-checking across turns.
- **Outside the sandbox.** `cx-run`, `cx-job` and the hand steps (they touch the worktree,
  `~/.conductor`, `gh` and `git push`) run outside Claude Code's Bash sandbox: Copilot writes
  `~/.copilot`, agy `~/.gemini` and `~/.antigravity`, Grok `~/.grok`, and the worktrees live
  under `worktree_root` (default `~/.cx-wt`).
- **Ids** are unique on this computer: no `cx/<id>` branch in the repo and no
  `~/.conductor/out/<id>` (threads and repos share that directory; `cx-run` refuses a taken id).
  Run `cx-run` from the repository's main checkout, or pass `--repo DIR`: from a checkout under
  `.claude/worktrees/` it exits 1.
- **Results are claims.** Read the `VERIFY THIS:` line and the `CX_RESULT` line (`status`,
  `model_served`, `denied`, `diffstat`, `reason`): exit 0 means the checks `cx-run` can make
  passed, not that the work is right.
- **No exports.** Never export `CX_WORKER` or `CLAUDE_PLUGIN_OPTION_*` (both sibling plugins
  read the same names); `cx-run` builds the worker environment per run. The hand steps' two
  executor calls (Grok for commit messages, `ghcp-ci-debug`) go through `cx-wsl`, in WSL as from
  Windows: it takes their pool slot (shared with every `cx-run`) and adds the per-tool prefix
  (`grok`: `XAI_API_KEY` and `GROK_SANDBOX` unset, `CX_WORKER=1`, `GROK_DISABLE_AUTOUPDATER=1`
  and the five `GROK_CLAUDE_*_ENABLED=false`; `ghcp-*`: `COPILOT_MODEL`, `COPILOT_ALLOW_ALL`,
  `COPILOT_AUTO_TIER` and `COPILOT_PROVIDER_BASE_URL` unset, `CX_WORKER=1`,
  `COPILOT_AUTO_UPDATE=false`, the recorded copilot binary). `XAI_API_KEY` would bill the xAI
  API account instead of the subscription, and the `COPILOT_*` variables can change Copilot's
  model, permissions or endpoint.

**Checks run only through `cx-route`.** At dispatch `cx-run` snapshots the task's commands,
named from `.cx/routes.json` (`test`, `lint`, `typecheck`, ...), into the run's
`~/.conductor/routes/<id>/cx-route`, which is on every executor's PATH: `cx-route test` runs
that snapshot in a clean bash (an edit of the worktree's `routes.json` changes nothing, and a
caller's `BASH_ENV` or exported functions never run), `cx-route` alone lists the names.
Executors may run only `cx-route <name>` and `git status` (agy also `ls`): agy gets exactly
these as per-run `--settings` grants (its first other command ends the run), Copilot as
`--allow-shell` rules, and grok runs inside its repository's sandbox profile (in every mode,
read and review included). Never `git diff`, `git log` or `git show`: their `--output=<path>`
writes any file, and a prefix rule cannot forbid an option. Name the checks in the contract as
`cx-route <name>`.
`cx-init --user-grants` (optional, from inside the repo) writes that repository's grok profile
ahead of its first grok run and removes the invalid profile conductor 0.2.0 wrote; agy needs no
user-level grant any more. Never use the yolo / skip-permissions flags (`--yolo`,
`--dangerously-skip-permissions`) outside Docker, and never `agy-handoff`, `agy-media` or
`/antigravity:research` for conductor work (they always pass them: a grant over the whole
machine).

### Step 1: the contract

Write the contract to a file with the Write tool (any path, e.g. `/tmp/cx-t1.md`; `cx-run`
copies it to `~/.conductor/out/<id>/task.md`, its canonical place, and into the worktree as
`.conductor/task.md`). Line 1 is machine-readable, the rest is prose for the executor:

```markdown
<!-- cx-task {"id": "t1", "base": "<sha>", "lane": "agy-opus", "effort": "high", "allowed_paths": ["src/feature/**"], "lockfiles": false, "commands": ["npm test"]} -->
# Task t1: <one-line goal>
## Goal
## Context
Files and pointers (paths, functions). No pasted file contents beyond short excerpts.
## Acceptance tests
- Must pass: `cx-route test` (`npm test`) …
- Existing tests that must not change: `tests/foo.test.ts` …
## Allowed changes
Only paths matching: `src/feature/**`. Lockfiles: no.
## Allowed commands
Run checks only through cx-route: `cx-route test` (`npm test`), snapshotted from .cx/routes.json
at dispatch (`cx-route` alone lists them). Also allowed: git status. Read files, and your own
changes, with your file tools. No other shell command.
## Forbidden
Editing .conductor/task.md, the tests listed above, CI config, .cx/routes.json or git hooks;
installing, upgrading or patching dependencies; committing, pushing or branching; starting
subagents or other coding agents.
## Output contract
Reply with a compact digest: what changed (file:line), what you ran and its result, open
issues. No full file contents, no raw logs. End with exactly one line: DIGEST: <one sentence>.
```

`id` and `base` may be left out (`--id`, `--base`, else a generated id and `HEAD`); `commands`
are the checks the executor may run through `cx-route` (default: the routes commands; a
command that is not a routes command gets the name `cmd-1`, `cmd-2`, ...);
`"subagents": true` lets a Grok task use subagents. A one-line task may go as quoted text
instead of `--task-file` (wrapped into the same template with the routes commands and no
`allowed_paths`); prefer task files.

### Step 2: dispatch

One lane per task (G2). `--exec auto` (the default) takes the first lane of the policy's order
whose pool is on in `routes.json`, is not paused, passes the free preflight, supports the
effort and has a free slot (agy in raw mode, which verifies the served model); when every
eligible pool is full it waits up to 10 minutes for a slot, then gives you the claude lane:

```bash
cx-run --background --task-file /tmp/cx-t1.md --id t1 --effort high
cx-job wait '<job id>'   # the id after JOB_ID; one background Bash call with timeout: 7200000
```

`cx-run --dry-run …` creates nothing and starts no executor; `--explain` also says why each
lane was chosen or skipped and which preflight results came from the cache. An explicit lane,
each started the same way and waited for with `cx-job wait`:

```bash
cx-run --background --exec agy --task-file /tmp/cx-t1.md --id t1                        # agy Opus (raw mode: served model verified)
cx-run --background --exec copilot --effort high --task-file /tmp/cx-t1.md --id t1      # Copilot Opus
cx-run --background --exec copilot --fusion standard --task-file /tmp/cx-t1.md --id t1  # mechanical fallback (Fusion Standard)
cx-run --background --exec copilot --fusion max --task-file /tmp/cx-t1.md --id t1       # both Opus pools drained (Fusion Max)
cx-run --background --exec grok --task-file /tmp/cx-t1.md --id t1                       # Grok grok-4.7, mechanical work
```

An explicit lane whose pool stays full exits 28 (`NO_CAPACITY`) after 10 minutes, or at once
with `--no-wait`: use the next pool in the order. `cx-job status <id>` says `queued` while a job
waits for its slot; `cx-job kill <id>` cancels one; `cx-job list` shows them. agy runs in raw
mode by default (option `agy_opus_mode`; `--agy-mode wrapper` uses `agy-delegate`, whose served
model is recorded as unverified). A `GHCP_FALLBACK` on a Fusion lane is a model mismatch (21).

The claude lane (your own subagent, Opus 5.5 at the task's effort): `cx-run` creates the
worktree, runs `setup` and prints a dispatch JSON (`worktree`, `host_path`, `prompt`,
`effort`); give a Task/Agent subagent that prompt, told that its working directory is the
`worktree` (every command runs there, every path is under it) and that it must not commit.
Then finish it:

```bash
cx-run --exec claude --task-file /tmp/cx-t1.md --id t1
cx-run --finish t1
```

On Windows give the subagent the `host_path` (`\\wsl.localhost\<distro>\…`) for Read, Edit,
Write, Glob and Grep, and `cx-wsl bash -c 'cd "<worktree>" && <command>'` for every command;
never `~` (on Windows that is `C:\Users\<you>`), and never Git Bash's own git, npm or test tools
on those files.

Read-only lanes (no worktree: a detached checkout of `--base`, removed afterwards; the text is
the question):

```bash
cx-run --mode read --exec grok --effort medium '<question>'                           # exploration: [{file, line, why}]
cx-run --mode read --exec agy '<digest request>'                                      # gemini-3.8-flash-high: logs, digests under ~200k tokens
cx-run --mode read --exec agy --model 'Gemini 4 Argon (High)' '<digest request>'      # digests above ~200k tokens
cx-run --mode read --exec copilot '<question>'                                        # gpt-6.1-sol (option review_model_gpt)
```

Not lanes: `agy-media` and `/antigravity:research` (both always pass `--yolo`); research goes
to your own WebSearch and Grok, media waits for the v1.1 Docker lane. Commit messages, PR text
and changelogs go to Grok with the diff inside the prompt file (one call; `vars.sh` is written
by `cx-run`). Grok runs under its built-in `strict` profile in a directory of its own that holds
only the prompt (`$OUT/msg/`, emptied first): it may write only there, in `~/.grok/sessions` and
the temp directories, and nothing the conductor later sources or runs (`vars.sh`, the routes)
lives there. Never `--sandbox read-only` (it lets grok write `~/.grok`: its own binary, ripgrep
and plugins) and never `--cwd "$TOP"`:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
rm -rf -- "${OUT:?}/msg" && mkdir -p -- "$OUT/msg"                                       # holds only the prompt
{ printf '%s\n\n' 'Write a commit message (a subject under 72 characters, a blank line, a short body) for the diff below. Describe only what the diff shows.'; git -C "$TOP" diff "$BASE" "cx/$ID"; } > "$OUT/msg/prompt.txt"
cx-wsl grok --prompt-file "$OUT/msg/prompt.txt" -m grok-4.7 --effort low --cwd "$OUT/msg" --sandbox strict --always-approve --no-subagents --output-format plain </dev/null   # a grok slot
```

### Step 3: after every run (the conductor commits; the gate never runs in `$WT`)

After a write run ended with exit 0 (for the claude lane, after `cx-run --finish`); background
when the checks are slow:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
rm -f "$OUT/running"                                                                    # the lane is done
[ "$(sha256sum "$WT/.conductor/task.md" | cut -d' ' -f1)" = "$(cat "$OUT/task.sha")" ] || { echo SPEC_TAMPERED; exit 23; }
[ "$(git -C "$WT" symbolic-ref -q --short HEAD)" = "cx/$ID" ] || { echo BRANCH_TAMPERED; exit 24; }        # the executor left cx/$ID
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || git -C "$WT" reset -q --soft "$BASE"   # squash executor commits
git -C "$WT" add -A
git -C "$WT" diff --cached --quiet && { echo NO_CHANGES; exit 3; }                    # empty result: status empty
git -C "$WT" diff --cached --stat "$BASE"; git -C "$WT" diff --cached --name-only "$BASE"   # tamper review (G4)
git -C "$WT" commit -qm "cx/$ID: <executor>/<served model>"
C=$(git -C "$WT" rev-parse HEAD); [ "$(git -C "$TOP" rev-parse "cx/$ID")" = "$C" ] || { echo BRANCH_TAMPERED; exit 24; }
G="$HOME/.conductor/gate/$ID.1"; git -C "$TOP" worktree add -q --detach "$G" "$C"         # gate the exact commit
(cd "$G" && npm ci --prefer-offline && npm test && npm run lint && npx tsc --noEmit)   # routes setup + commands
```

The served model in the commit message is `CX_RESULT`'s `model_served` (`unverified` for agy's
wrapper mode and the claude lane). `SPEC_TAMPERED` (exit 23), `BRANCH_TAMPERED` (exit 24: the
executor created or switched branches, so a squash and commit would land on its branch while
`cx/$ID` stays at BASE) and `NO_CHANGES` (exit 3) stop the step before the commit: nothing is
committed or gated; inspect the worktree, then fail over or re-dispatch. The gate checks out the
exact commit `C`, never a branch name. A second gate attempt uses `$ID.2`. Failover to the next
lane: `git -C "$WT" reset -q --hard "$BASE" && git -C "$WT" clean -ffdxq -e /.conductor/`
(inside the conductor's own worktree only), then `cx-run --reuse-worktree --exec <next lane>
--task-file /tmp/cx-t1.md --id t1`. Never let two lanes write to one worktree.

### Step 4: reviews (read-only, on a gate checkout of the committed branch; only after Step 3)

Each reviewer is one background call (or `--background` plus `cx-job wait`); the diff of
`cx/t1` against its base is in `.conductor/change.diff` of a fresh checkout of the branch:

```bash
cx-run --mode review --family gemini --branch cx/t1    # Argon (option review_model_gemini) on Opus-written code
cx-run --mode review --family gpt --branch cx/t1       # GPT (option review_model_gpt) on high_risk paths and security-relevant changes
```

Review Grok- or Gemini-written code yourself. Confirm every accepted finding at file:line and
give a reason for every rejected one. A Claude-family reviewer of Claude-written code
(`CX_NOTE same_family_as_conductor`) is not independent. Clean up Step 3's gate checkout with
`git -C "$TOP" worktree remove --force "$G"` once the reviews are in.

### Step 5: GitHub (only after a green gate)

Write the PR body to `$OUT/pr-body.md` first (Step 2's Grok call drafts it), then:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
git -C "$WT" push -u origin "cx/$ID"
gh pr create -R "$REPO" --head "cx/$ID" --title '<title>' --body-file "$OUT/pr-body.md"
gh pr edit "cx/$ID" -R "$REPO" --add-reviewer @copilot
```

`REPO` (`host/owner/repo` as gh resolves the checkout's remote, ssh host aliases included; from
the origin URL when gh is not logged in; `cx-run` writes it into `vars.sh`) lets every `gh` call
name the repo with `-R`, so each line starts with an allow-listed command (`cx-doctor`'s D25
lists the rules) and none needs a `cd`. `--add-reviewer @copilot` needs a gh whose `gh pr edit
--help` mentions `@copilot` (`cx-doctor` checks it); otherwise use the REST fallback (reviewer
login unverified; `<N>` from `gh pr view "cx/$ID" -R "$REPO" --json number --jq .number`):
`gh api -X POST "repos/{owner}/{repo}/pulls/<N>/requested_reviewers" -f 'reviewers[]=copilot-pull-request-reviewer[bot]'`.
CI failures:

```bash
cx-wsl ghcp-ci-debug --pr 123   # the PR number; a copilot slot
```

(or `--run <run id>`), read-only. Its apply mode creates and switches to a branch
`ghcp/ci-fix-<run id>` in its directory, whose default is the cwd (normally the user's main
checkout), and leaves the edits uncommitted, so use it only inside the task's conductor
worktree, and hand the edits back to `cx/<id>` before Step 3 (which otherwise stops with
`BRANCH_TAMPERED`). One background call:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
printf '%s\n' "$WT" "$(cd "$WT" && pwd -P)" > "$OUT/running"
cx-wsl ghcp-ci-debug --pr 123 --apply --dir "$WT" > "$OUT/ci-fix.txt" 2> "$OUT/ci-fix.err"; echo $? > "$OUT/rc"
F=$(git -C "$WT" symbolic-ref -q --short HEAD); case "$F" in ghcp/ci-fix-*) git -C "$WT" switch -q "cx/$ID" && git -C "$WT" branch -q -D "$F" ;; esac   # hand the edits back to cx/$ID
printf 'BASE=%q\n' "$(git -C "$WT" rev-parse "cx/$ID")" >> "$OUT/vars.sh"   # Step 3 commits the fix on top of the pushed commit
```

Both branches point at the same commit, so the switch carries the uncommitted edits; the new
`BASE` makes Step 3 commit the fix on top of `cx/<id>` (no squash into the pushed commit, so
Step 5's push stays a fast-forward). Then Step 3 (gate `$ID.2` when `$ID.1` still exists),
Step 4 and the push. Issue and PR triage is read-only: fetch first (`gh issue view N --json
title,body,comments,labels`, `gh pr view N`, `gh pr diff N`), then `cx-run --mode read --exec
copilot '<question about the fetched text>'`. Never use `ghcp-delegate --github` for triage: it
adds every GitHub MCP tool acting as you (comment, label, close, merge); keep it for a task that
is meant to act on GitHub. Copilot approvals count only after the user opts in; you adjudicate
every review comment.

Copilot cloud agent (an executor's own cloud, welcome from a local session, U7): it works in
GitHub Actions and opens a pull request, billed in Copilot premium requests and Actions
minutes. `cx-run` renders the contract for it (the ban on committing, pushing and branching is
dropped: the pull request is its output) and records the task and the pull request; `--finish`
fetches the pull request head into a gate checkout and runs `setup` and every routes command
there (exit 20 `GATE_FAILED` when one fails, 25 when `setup` does):

```bash
cx-run --exec copilot-cloud --task-file /tmp/cx-t1.md --id t1
ghcp-cloud list                          # follow the agent
ghcp-cloud view '<PR number>' --log      # one task's log
cx-run --finish t1 --pr '<PR number>'
```

`ghcp-cloud list` and `ghcp-cloud view <PR number> --log` follow the agent (`--pr` is needed
only when gh printed no pull request URL at creation). `--finish` fetches the head from the
task's repository (the `--gh-repo` the task ran in, never a fork's `origin` by default) and gates
it only when GitHub names that commit as the pull request's head; a gated task is gated again
only with `--pr N` (a re-gate after new commits; the ledger books it once). Read `changed.txt` in the out directory
against `allowed_paths` and the protected set (G4), then Step 4 with `--branch <the commit
--finish names>`. Post your findings on the PR; it merges only after a green gate and your
adjudication, never on the agent's own word. Grok remote sessions are not a conductor command:
grok 1.0.70 can only resume one (`--resume`); the user starts them.

### From Windows (Git Bash)

The Windows desktop app's Bash tool is Git Bash, and nothing above exists on the Windows side:
the work runs inside WSL, and nothing is installed on Windows (never install ghcp, antigravity
or grok-build there, never call `wsl.exe` or agent CLIs directly, and never make worktrees with
Git for Windows).

- Run `cx-doctor` once first: the conductor resolves every tool from the host record it writes
  (exit 13 without it). For the user's full interactive PATH they run `/conductor:doctor` in a
  Claude Code session in WSL, or `~/.conductor/runtime/current/bin/cx-doctor` in a WSL terminal.
- `cx-run` and `cx-job` forward themselves into WSL: run the same commands as above, except the
  task file. Write the contract with the Write tool to a Windows-side path (e.g.
  `C:\Users\<you>\AppData\Local\Temp\cx-t1.md`) and pass `--task-file` as that path or its
  `/c/Users/<you>/AppData/Local/Temp/cx-t1.md` form, never a Git Bash `/tmp/…` path: it has no
  WSL form, so `cx-run` exits 42 `PATH_UNMAPPABLE` (with `--background` before any job starts).
  Path options (`--task-file`, `--repo`, `--diff`) may be Windows paths (`C:\…`, `/c/…`) or
  `\\wsl.localhost\…` paths; they are mapped. `CX_RESULT`'s `host_path` fields and the claude
  dispatch's `host_path` are Windows paths you can open with the file tools. A job keeps
  running when its forwarded `cx-job start` returns; waiting with `cx-job wait <id>` in one
  background call also keeps WSL running.
- The hand steps (Step 3, Step 5, commit-message drafting): write the step text verbatim (its
  `vars.sh` line included) to a Windows-side scratch file with the Write tool, with LF line
  endings, and run `cx-wsl bash -s < FILE` (FILE in its Git Bash form, e.g.
  `/c/Users/<you>/AppData/Local/Temp/cx-t1-3.sh`), as one background Bash call with
  `timeout: 7200000` when the step is long. `cx-wsl` strips CRLF from such a step and says so
  on stderr: a CR would end up in every word.
- Single commands may go direct: `cx-wsl gh pr view <N>`, `cx-wsl git -C /home/<you>/<repo>
  status`, `cx-wsl ghcp-ci-debug --pr <N>` (read-only), `cx-wsl ghcp-cloud list` and
  `cx-wsl ghcp-cloud view <N> --log`. Executors run only through `cx-run` and `cx-job` (and the
  hand steps' `cx-wsl grok` and `cx-wsl ghcp-ci-debug` lines), never as other `cx-wsl` calls.
  Paths inside steps and `cx-wsl` arguments are WSL paths (`$HOME`, `~/.cx-wt`,
  `/home/<you>/…`), never `C:\…` or `/c/…`; `cx-wsl` passes arguments byte for byte. Read results
  from `CX_RESULT`'s `host_path` or with `cx-wsl bash -c 'cat "$HOME/.conductor/out/t1/answer.txt"'`.
- With the Copilot token file (`cx-doctor --login-help copilot`; the keyring is unreachable
  through wsl.exe), `cx-run`'s Copilot lanes and `cx-wsl ghcp-*` export `COPILOT_GITHUB_TOKEN`
  for that run only; a `cx-wsl bash -s` step does not get it.
- `cx-wsl` runs exactly these tools: `ghcp-delegate`, `ghcp-job`, `ghcp-handoff`,
  `ghcp-ci-debug`, `ghcp-models`, `ghcp-cloud`, `agy-delegate`, `agy-job`, `agy`, `grok`, `gh`,
  `git` and `bash`; anything else exits 1. Its executor calls take the same pool slots as
  `cx-run`. `cx-run`, `cx-job` and `cx-wsl` calls run outside the sandbox.

### 12.3 Commands

Each `commands/*.md` has frontmatter `description` and `argument-hint`, and its body uses
`$ARGUMENTS`. Every frontmatter value that starts with `[` or `{` is double-quoted (an
unquoted `[--pools] [--windows] …` is a YAML flow sequence followed by text, which strict
parsers reject, dropping the whole frontmatter; `claude plugin validate` does not catch it; ghcp
quotes every hint). P43 asserts it.

| File | Frontmatter | Body requirements |
|---|---|---|
| `doctor.md` | `description: Check conductor hosts, CLIs, logins and sibling plugins (free probes only)`; `argument-hint: "[--pools] [--windows] [--login-help <cli>] [--json]"` | Run `cx-doctor $ARGUMENTS` as one Bash call outside the sandbox (the Copilot, agy and grok probes need it). Explain each ✗ and ! with its fix; never run a paid command; offer the `claude plugin configure` fixes but run them only when the user agrees (they change user settings) |
| `init.md` | `description: Write the conductor repo bundle (AGENTS.md, .cx/routes.json, .github/copilot-instructions.md)`; `argument-hint: "[--dir <repo>] [--only agents\|routes\|copilot] [--force] [--test <cmd>] …"` | Run `cx-init --dry-run $ARGUMENTS` first and show the plan and detected commands; then run without `--dry-run` when the user asked for it. Never pass `--force` unless the user asked. Never touch `CLAUDE.md` or `.claude/` |
| `route.md` | `description: Explain where a described task should go (lane, model, effort, exact command, gates); read-only`; `argument-hint: "<task description>"`; `allowed-tools: Read, Glob, Grep` | Classify `$ARGUMENTS` against the conductor skill's routing table and answer with: lane and why, model and effort, the exact Phase 1 command(s) (the `cx-wsl` form when the session runs in Git Bash), fallback, gate, cost note (which pool). Run nothing and dispatch nothing |

## 13. Repository documents

### 13.1 Manifests

`plugin.json`: `name`, `version` `0.1.0`, `description` (one paragraph: Claude conducts; routes
work to Copilot (ghcp), Grok Build and Antigravity; Opus 5.5 fan-out to the included pools;
Claude judges), `author`, `homepage`, `repository`, `license` `MIT`, `keywords` (`orchestration`,
`multi-agent`, `model-routing`, `github-copilot`, `grok`, `antigravity`, `wsl`, `delegation`),
`userConfig` (§5.1). `marketplace.json`:
`{"$schema": "https://anthropic.com/claude-code/marketplace.schema.json", "name":
"conductor-for-claude-code", "owner": {"name": "40chalk"}, "metadata": {"description": "…"},
"plugins": [{"name": "conductor", "source": "./", "description": "…", "version": "0.1.0"}]}`.

### 13.2 README.md, CLAUDE.md, CHANGELOG.md

- `README.md`: what and why; the routing summary (§6.2 condensed); install, one step:
  `claude plugin install conductor --marketplace 40chalk/conductor-for-claude-code` [measured
  2026-11-01: `claude plugin install --help` on 2.1.316], or two steps: `/plugin marketplace add
  40chalk/conductor-for-claude-code` (or a local folder), then `/plugin install
  conductor@conductor-for-claude-code`; in WSL, and on the Windows app as the only Claude-side
  plugin there; on Windows, run `git config --global core.autocrlf input` before installing
  (belt and braces: this repo's `eol=lf` rules already keep git checkouts LF, §3.5), and never
  install ghcp, antigravity or grok-build on the Windows side; prerequisites (WSL with python3 ≥ 3.8, bash ≥ 4.4, coreutils/util-linux, git ≥
  2.31; copilot 1.0.105, grok 1.0.70, agy, gh; the ghcp and antigravity plugins in WSL); first
  run (`/conductor:doctor`, `cx-doctor --login-help`, the sibling option fixes, `/conductor:init`);
  options table (§5.1); exit codes (§4.1, with a ``| 130 | `CANCELLED` |`` row); Windows/Git Bash
  forwarding and `cx-wsl` (§7.7) with the Windows allow rules (D25); status by phase;
  attribution (none needed: original work; MIT).
- `CLAUDE.md` (repo guidance in the style of ghcp's): What this is; Commands (`bash
  tests/run-tests.sh`, how to run one script by hand against the stubs with the isolation
  variables, `claude plugin validate .`); Never spend credits by accident (stubs first on PATH,
  `GHCP_COPILOT_BIN` pointing at the stub, isolated `XDG_CACHE_HOME`, no `claude -p`);
  Architecture (§2); Options (§5); Exit codes (§4.1); Forwarding (§7); Invariants (§3);
  Changes that touch many files (below); Tests (§14); Unverified (§20).
- Changes that touch many files (to list in `CLAUDE.md`): **exit code** (§4.1 table,
  `common.sh` tables incl. the constant reasons, `cxlib.py`, README, SKILL.md, each script
  header, tests); **option** (`plugin.json`, `CX_OPT_DEFAULTS`, the forwarder allowlist (derived),
  §5.1, README, SKILL.md if user-facing, `options-check`); **policy text** (§10.3–§10.5, the
  three `hooks/policy-context*.json` files, the order phrases in `policy.sh`, P20, P21);
  **`cx-wsl` tool allowlist or prefixes** (§7.7, the §12.2 prefix table, SKILL.md, the Git Bash
  policy, P43, P45); **version bump** (`plugin.json`, `marketplace.json`, `CX_VERSION`,
  CHANGELOG heading, P2); **verified-version bump** (`CX_VERIFIED_*`, §1, §5.4, D9–D11, README); **duplicated
  regexes** (`AUTH_RE`/`SANDBOX_RE` copied from ghcp into `cx-doctor.sh`); **new shipped file**
  (§13.4 list, `cx-doctor` D3 list, `install-runtime.sh` dirs and D4's subset, the forwarder
  CMD allowlist when it is a `cx-*` bin, P41); **Git Bash tool use** (§3.1's list and P42's
  mini bin).
- `CHANGELOG.md`: `## 0.1.0 — 2026-11-01` with the Phase 1 bullets; later phases add entries.

### 13.3 LICENSE

Exists (MIT, Copyright (c) 2026 40chalk). No third-party code is copied; ghcp is the user's own
work and its conventions are reused by design.

### 13.4 Shipped file list (Phase 1)

`.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `bin/cx-doctor`, `bin/cx-init`,
`bin/cx-wsl`, `scripts/cx-doctor.sh`, `scripts/cx-init.sh`, `scripts/cx-wsl.sh`,
`scripts/lib/common.sh`, `scripts/lib/options.sh`,
`scripts/lib/cxlib.py`, `scripts/host/detect.sh`, `scripts/host/pathmap.sh`,
`scripts/host/forward-wsl.sh`, `scripts/host/wsl-entry.sh`, `scripts/host/install-runtime.sh`,
`hooks/hooks.json`, `hooks/policy.sh`, `hooks/policy-context.json`,
`hooks/policy-context-gitbash.json`, `hooks/policy-context-crlf.json`,
`hooks/policy-context-cloud.json`, `hooks/subagent.sh`, `hooks/subagent-context.json`,
`hooks/subagent-context-compact.json`, the 8 Phase 1 `worker-shims/*`,
`templates/repo-bundle/AGENTS.md`, `templates/repo-bundle/routes.json`,
`templates/repo-bundle/copilot-instructions.md`, `templates/projects-instructions.md`,
`skills/conductor/SKILL.md`, `commands/doctor.md`, `commands/init.md`, `commands/route.md`;
Phase 2 adds, item by item of the §15 build order: `scripts/lib/locks.sh` (item 1, a sourced
library, not executable); `scripts/lib/adapter.sh` (sourced), `scripts/lib/normalize.py`,
`scripts/lib/ledger.py`, `scripts/adapters/copilot.sh`, `scripts/adapters/grok.sh`,
`scripts/adapters/agy.sh`, `scripts/adapters/claude.sh`, `scripts/adapters/copilot-cloud.sh`,
`templates/cx-worker.json` and the 19 Phase 2 worker shims of §11 (items 2 and 3); `bin/cx-run`,
`bin/cx-job`, `scripts/cx-run.sh`, `scripts/cx-job.sh`, `scripts/lib/worktree.sh` and
`scripts/lib/taskfile.sh` (both sourced), `templates/task.md` and `templates/grok-sandbox.toml`
(items 2 and 3, and cx-init's user grants). All of them live in the six runtime directories,
so the runtime installer's directories and D4's subset are unchanged.
Executable: `bin/*`, `scripts/*.sh`, `scripts/host/*.sh`, `scripts/adapters/*.sh`,
`hooks/policy.sh`, `hooks/subagent.sh`, `worker-shims/*`. The runtime copy (§7.5) holds the subset under `.claude-plugin bin scripts
hooks worker-shims templates`; D3 checks the installed copy against the whole list, D4 the
runtime against that subset. The Phase 2 `agents/` and `workflows/` directories are read by
Claude Code from the installed plugin, never from the runtime copy, so that subset does not
change when they land.

## 14. Phase 1 tests

### 14.1 Harness and isolation

`bash tests/run-tests.sh` runs everything, needs no network, spends nothing, and runs inside
Claude Code's Bash sandbox. Style as ghcp's: `check "[P7] name" cmd args…`, `section`, PASS /
FAIL / SKIP counters, non-zero exit on any FAIL, `bash tests/run-tests.sh 2>&1 | grep -v '^PASS  '`
for failures only. Tags: `[P1]`–`[P63]` (plus `[P22b]`) are the Phase 1 cases below (later phases use `[A…]`,
`[G…]`, `[W…]`, `[K…]`); `[X]` is extra coverage.

Isolation (set before any case): one `TMP=$(mktemp -d)`; `HOME=$TMP/home`,
`CLAUDE_CONFIG_DIR=$TMP/claude-config`, `XDG_CACHE_HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`,
`TMPDIR`, `CX_HOME=$HOME/.conductor` all under it; `CX_DETECT_ROOT=$TMP/root` (an empty fake
root, so the build container's own `/.dockerenv` cannot leak in); unset every
`CLAUDE_PLUGIN_OPTION_*`, `STUB_*`, `CX_*` (other than those just set), `GHCP_*`, `COPILOT_*`,
`GROK_*`, `AGY_*`, `WSL_DISTRO_NAME`, `WSL_INTEROP`, `WSLENV`, `MSYSTEM`, `container`,
`CLAUDE_PLUGIN_ROOT`, `GH_TOKEN`, `GITHUB_TOKEN`, every `CLAUDE_CODE_*`, and by name (P62) the
session, Work locally and workflow signals: `CLAUDE_CODE_REMOTE`, `CLAUDE_CODE_ENVIRONMENT_KIND`,
`CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE`, `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_PROJECTS_SESSION`,
`CLAUDE_CODE_DESKTOP_APP_VERSION`, `CLAUDE_CODE_HOSTED_DESKTOP`, `CLAUDE_CODE_IS_COWORK`,
`CLAUDE_CODE_USE_COWORK_PLUGINS`, `CLAUDE_PROJECT_UUID`, `CLAUDE_PROJECT_DIR`,
`DISABLE_GROWTHBOOK`, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `ANTHROPIC_BASE_URL`,
`CLAUDE_CODE_SESSION_ATTENDED`, `CLAUDE_CODE_SESSION_KIND`, `CLAUDE_CODE_DISABLE_WORKFLOWS`,
`CLAUDE_CODE_WORKFLOWS`, `CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL`, `CLAUDE_CODE_SUBAGENT_MODEL_FORCE`,
`CLAUDE_CODE_SUBAGENT_MODEL`, `CLAUDE_CODE_SUBAGENT_EFFORT`,
`CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS`, `CLAUDE_CODE_REMOTE_TOOLS_FORWARD`, `CLAUDE_EFFORT`,
`AI_AGENT`, `CLAUDE_CODE_SESSION_ID`, `NUMBER_OF_PROCESSORS`, `ProgramFiles`/`PROGRAMFILES`
(the build container is itself a cloud session, `CLAUDE_CODE_REMOTE=true` measured: without
this every policy case would flip to the cloud notice); `GHCP_COPILOT_BIN=$ROOT/tests/stubs/copilot`;
`PATH=$ROOT/tests/stubs:$REAL_PATH`; git identity variables and `GIT_CONFIG_NOSYSTEM=1`; the
suite runs from a scratch cwd. A fake Claude config is generated per section:
`installed_plugins.json` pointing at fake plugin install dirs the suite creates under
`$TMP/plugins/{ghcp,antigravity}/bin/` (two-line scripts that `exec` `tests/stubs/ghcp-models`,
or `tests/stubs/billable` for every other wrapper) and a `settings.json` built from
`tests/fixtures/settings/`.

A case that needs a PATH without some agent CLI (the missing-CLI doctor runs) uses a copy of
the stub directory without it plus a directory of links to named system tools (bash,
coreutils, git, python3, `timeout`, `setsid`, `flock`, `ps`, …), never `$REAL_PATH`: a real
`copilot`, `grok` or `agy` installed on the developer's host would otherwise run (network calls,
an agy self-update), and the stub-log audit (P30) cannot see real binaries; a check asserts
that such a PATH resolves none of them. The suite prints its wall time; only with
`CX_TEST_STRICT_TIME=1` does a run over 60 s fail (wall time alone never turns a functionally
green run red on a slow or loaded machine).

Git Bash simulation: `STUB_UNAME_S=MINGW64_NT-10.0-26100`, `STUB_WIN_ROOT=$TMP/win` (stub
`cygpath` maps `$TMP/win/<x>/rest` ↔ `X:\rest`, `$TMP/unc/<rest>` ↔ `\\wsl.localhost\Ubuntu\<rest>`,
`$TMP/share/<rest>` ↔ `\\server\share\<rest>`), `USERPROFILE=C:\Users\me` (its Git Bash form under
`$TMP/win/c/Users/me`), `TMPDIR` under `$TMP/win/c/Users/me/AppData/Local/Temp`, and a PATH made
of the stub dir plus a mini bin holding exactly the tools of §3.1 (symlinks to the real ones)
and a `python3` trap that logs `PYTHON_CALLED` and exits 9009 (P42). The stub `wsl.exe` runs the
WSL side with `HOME=$TMP/wslhome` and `CX_MNT_ROOT=$TMP/win/`, so a Windows path maps to the
same directory on both sides.

### 14.2 Stubs (`tests/stubs/`) and fixtures

Every stub appends its argv (one argument per line, then `--`) to `$STUB_LOG` when set. Any
invocation that would be billable on the real CLI (a prompt to copilot other than the doctor
probe, `grok -p`/`--single`/`--prompt-file`, `agy -p` other than `/usage`, `/model`, `/config`,
`claude -p`) writes `BILLABLE` to the log and exits 99; the suite fails if `BILLABLE` ever
appears (P30).

| Stub | Behaviour (env knobs) |
|---|---|
| `uname` | `-s`/`-r`/`-m`/`-n` from `STUB_UNAME_S/_R/_M/_N`, else the real `uname` (found on PATH minus the stub dir) |
| `cygpath` | `-w`/`-u`/`-m` with the mapping above, `-l` (long form: a path component listed in `STUB_CYGPATH_SHORT`, e.g. `JOHNSM~1=John Smith`, is replaced by its long name; without `-l` it stays short), `--version`; any other POSIX path → rc 1; logs its flags, so P13/P15 assert `-l` was passed |
| `wsl.exe` | Parses `-d`, `--cd`, `--exec PROG ARGS…`, `-l -v`/`--list --verbose`, `-l -q`/`--list --quiet`. Own messages are UTF-16LE with a BOM unless `WSL_UTF8=1` (`STUB_WSL_IGNORE_UTF8=1` forces UTF-16LE). `STUB_WSL_DISTROS` (`*Ubuntu-24.04:Running:2,Debian:Stopped:2`; `*` marks the default, used when `-d` is absent; a STATE may contain spaces). `STUB_WSL_FAIL=nodistro` → "There is no distribution with the supplied name." rc 255; `=launch` → "The Windows Subsystem for Linux instance has terminated." rc 1 before running the child; `=crash` → runs the child, then prints that message and `Error code: Wsl/Service/E_UNEXPECTED`, rc 1. The child runs under `env -i` with `HOME=$STUB_WSL_HOME`, `USER`, `LOGNAME`, `SHELL=/bin/bash`, `TERM=dumb`, `LANG=C.UTF-8`, `WSL_DISTRO_NAME=<D>`, `WSL_INTEROP`, `CX_MNT_ROOT=$STUB_WSL_MNT`, `CX_DETECT_ROOT`, `PATH=$STUB_WSL_PATH` (default includes python3's dir, the stub dir and `/mnt/c/Windows/System32`), `STUB_WSL_EXTRA_ENV` names (e.g. `DBUS_SESSION_BUS_ADDRESS`, `XAI_API_KEY`), plus each name listed in `WSLENV` (verbatim; flags are an error in the stub). `--cd ~` → `$STUB_WSL_HOME`. `--exec /bin/kill …` runs the real `kill` in the same process space. stdin passes through; exit = the child's. Logs its argv and the env names it passed |
| `wslpath` | `-u 'X:\rest'` → `$CX_MNT_ROOT<x>/rest`; `-w /p` → `\\wsl.localhost\<D>\p` with `D` = `STUB_WSLPATH_DISTRO` when set (empty → "Invalid argument", exit 1), else `$WSL_DISTRO_NAME`, else `Ubuntu`; `STUB_WSLPATH_LEGACY=1` prints `\\wsl$\`; `STUB_WSLPATH_ROOT` overrides the mount root (mismatch test) |
| `copilot` | `--version` → `GitHub Copilot CLI ${STUB_COPILOT_VERSION:-1.0.105}.`; the doctor probe (`-p . --model __cx_doctor_probe__ …`) → the real stderr shape for `STUB_COPILOT_AUTH=ok\|none\|rofs` with rc 1; anything else billable. Logs its cwd (`cwd=<pwd>`) and whether `GH_TOKEN`/`GITHUB_TOKEN` were set; `STUB_COPILOT_TOKEN_ONLY=GH_TOKEN` → the probe reports logged in only when that variable is set |
| `grok` | `--version` → `grok ${STUB_GROK_VERSION:-1.0.70} (f50904eaee6c)`; `models` → `fixtures/grok-models-auth.txt` when `STUB_GROK_AUTH=1`, else the verified unauthenticated text, rc `${STUB_GROK_MODELS_RC:-0}` (`STUB_GROK_MODELS_FAIL=network` → one error line, no ids, rc 1); `usage` → fixture; prompts billable; `STUB_ENV_FILE` receives its environment (P45 prefix checks) |
| `agy` | `--version` → `${STUB_AGY_VERSION:-1.4.12}`; `models [--output-format json]` → fixtures, empty when `STUB_AGY_AUTH=0`, a `{"status": "ERROR", …}` envelope or a "not signed in" line (rc 0) when `STUB_AGY_AUTH=envelope`, `sleep 60` when `STUB_AGY_HANG=1`; `-p /usage\|/model\|/config` → fixture JSON; other prompts billable |
| `claude` | `--version` → `${STUB_CLAUDE_VERSION:-2.1.316} (Claude Code)`; `auth status --json` → `{"loggedIn": ${STUB_CLAUDE_LOGGED_IN:-true}, "authMethod": "oauth_token"}`; `-p` billable. (P3 uses the real `claude` from `REAL_PATH`.) |
| `gh` | `--version` → `gh version ${STUB_GH_VERSION:-2.89.0} (2026-03-26)`; `pr edit --help` → help text that mentions `@copilot` unless `STUB_GH_NO_COPILOT=1`; `auth status` rc `${STUB_GH_AUTH:-0}` |
| `gitbash/git` (only on the simulated Git Bash PATH) | `rev-parse --show-toplevel` with `STUB_GIT_DUBIOUS=1` → Git for Windows' dubious-ownership message including a `git config --global --add safe.directory '…'` line, rc 128; otherwise the real git |
| `ghcp-models` | `--json` → `fixtures/ghcp-models.json` rc 0; `STUB_GHCP_MODELS=auth\|sandbox\|timeout\|catalog` → rc 11\|16\|12\|2; exits 98 unless `GHCP_COPILOT_BIN` is an absolute path; logs whether `--refresh` was given and its cwd. Reached only through the fake ghcp install dir (the doctor resolves wrappers from `installed_plugins.json`) |
| `billable` | Logs `BILLABLE` and its own name, exits 99 (stands in for every other sibling wrapper) |
| `nproc` | Prints `STUB_NPROC` when set, else the real `nproc`; logs nothing (free; D32) |
| `ghcp-delegate`, `agy-delegate`, `ghcp-cloud` (Phase 2) | The sibling wrappers for the adapters (named directly by the adapter tests' host record): `--help` from the real captures; a run needs `STUB_GHCP_RUN` (a real capture name, or `ok`, `mismatch`, `5149`, `sleep`), `STUB_AGY_DELEGATE_RUN` (`ok`, `denied`, `partial`, `quota`, `wrongtree`; it finds agy with `command -v` and fails on a shim), or reaches the `gh` stub; else billable |
| Phase 2 run scenarios of `agy`, `grok`, `claude`, `gh` | `STUB_AGY_RUN` (`ok`, `hang`, `wrongtree`, `denied`, `mismatch`, `partial`, `subagent`, `quota`, `auth`, `noinit`, `sleep`; SYNTHETIC stream-json), the registration form `--new-project --output-format json -p /model`; `STUB_GROK_RUN` (`ok`, `denied`, `mismatch`, `error`, `auth`, `quota`, `sleep`); `STUB_CLAUDE_RUN` (`ok`, `mismatch`); `gh agent-task --help`, and `agent-task create -F -` with `STUB_GH_AGENT_TASK=ok\|fail` (stdin to `STUB_GH_TASK_FILE`). Each header lists them; without the knob a prompt stays billable |

Fixtures: `grok-models-unauth.txt` (verified, §1.3); `grok-models-auth.txt`, `agy-models.txt`,
`agy-models.json`, `agy-usage.json`, `ghcp-models.json` (synthetic, shapes as in §1; replaced by
Phase 0 captures when they exist); `wsl-l-v.utf16le` (BOM + UTF-16LE + CRLF listing, a
multi-word localized STATE included); `settings/*.json`, among them `settings/win-bom-crlf.json`
(a Windows-edited file: UTF-8 BOM and CRLF) and `settings/enabled-first.json` (`enabledPlugins`
lists the conductor before its `pluginConfigs` entry, and a later foreign plugin block has a
`wsl_distro` option). `.gitattributes` marks `tests/fixtures/**` `-text` and `*.utf16le`
`binary`, so intentional CRLF and UTF-16 bytes survive `git add` (§2.2).
`tests/fixtures/README.md` labels each file verified or synthetic.
`tests/fixtures/real/<cli>/` is reserved for Phase 0 captures.

Real captures (Phase 0, `tests/live/`) are sanitized before they are committed: session and
conversation ids, account names and logins, emails, home paths and tokens are replaced by fixed
placeholders (`00000000-0000-4000-8000-000000000000`, `user`, `user@example.com`, `/home/user`,
`REDACTED`), and tests pin the sanitized values. Third-party or proprietary code never enters
the repo: the A/B's raw records stay under `$CX_HOME/ab/` (§6.7).

### 14.3 Cases

| ID | § | Case |
|---|---|---|
| P1 | §13.1 | `plugin.json` and `marketplace.json` parse; name, version, ids, author, repository, license exact; the marketplace entry has `source: "./"` and the same version |
| P2 | §5.1, §13.2 | `userConfig` keys = exactly the 24 options; each `type: "string"` with non-empty title and description; defaults = §5.1 = `CX_OPT_DEFAULTS` (incl. `wsl_distro` = `auto`, `review_model_gemini`, `review_model_gpt`, `copilot_reserve_pct` = `0`); `CX_VERSION` = plugin.json = marketplace = top CHANGELOG heading |
| P3 | §13.1 | `claude plugin validate .` passes with the real CLI (SKIP when absent; validate a `git ls-files` copy when a stray root `.mcp.json` exists) |
| P4 | §5.2 | Loader: settings value exported; an env value (even empty) wins; key fallbacks `conductor` and `conductor@x`; invalid JSON, missing file or no python3 → silent no-op; non-scalars skipped; bools → `true`/`false`; a planted `json.py` in the cwd is not imported |
| P5 | §5.2, §3.3 | `CX_WIN_SETTINGS` beats the WSL settings value; env beats both; a Windows settings file with a UTF-8 BOM and CRLF (`settings/win-bom-crlf.json`) still loads (`utf-8-sig`) |
| P6 | §5.3 | `cap_agy=abc` → note + `2`; `worktree_root=/` and `exec_host=docker` invalid; `opus_lane_order=copilot,agy` → `copilot,agy,claude`; D7 lists each as ! |
| P7 | §5.2 | `cx_opt_lite` finds `wsl_distro` inside the conductor's `pluginConfigs` entry; ignores the same key in an earlier plugin block AND in a later foreign block when `enabledPlugins` lists the conductor first (`settings/enabled-first.json`); handles a leading BOM and CRLF; braces inside strings do not end the span; rejects a value with a space; `cx_opt_lite` and `cx_lite_top` read an 80 KB BOM+CRLF settings file (a long `permissions.allow`, the conductor entry last) with the right values in under 3 s (linear readers: the text is split at its quotes once, and every key search is a `${x%%"KEY"*}` longest-suffix match; `${x#*"KEY"}` and `${s:i:1}` loops are quadratic in bash) |
| P8 | §4.2 | `cx_emit`: one line, `CX_NAME ` prefix, default separators, `ensure_ascii`, typed keys; `reason` sanitizing (CR/LF/TAB/U+2028 collapse, 200-char cut ending `...`) |
| P9 | §4.2 | `cx_signal` with no python3 on PATH: the hand-built line parses as JSON, holds only constant text, is the last stderr line, and the exit code is the given one |
| P10 | §4.1 | `cx_status_for_exit` covers every row; each script header lists exactly the codes the script can return |
| P11 | §7.2 | Every row of the pathmap example table, in CLI and sourced form; refusals exit 42 with a `pathmap:` reason; `--mnt-root` and `/etc/wsl.conf` under `CX_DETECT_ROOT` honoured; with no `--distro`, `WSL_DISTRO_NAME` or `CX_WSL_DISTRO`, T6 and `to-win /home/me` refuse with "distro unknown" while drive mappings still work |
| P12 | §7.1 | Detection matrix: `MINGW64_NT…`/`MSYS_NT…` → gitbash; `CYGWIN_NT…` → cygwin; `Darwin` → macos; Linux + `WSL_DISTRO_NAME` + `6.6.87.2-microsoft-standard-WSL2` → wsl/2; Linux + `WSLInterop` only → wsl; `4.4.0-19041-Microsoft` → wsl/1; Linux + `.dockerenv` + WSL2 kernel → docker; cgroup `docker` → docker; plain → linux; os-release quoting; hostkey sanitizing; WSL without `WSL_DISTRO_NAME`: the name from `wslpath -w /` (both prefixes), else os-release |
| P13 | §7.3, §7.7 | Argv fidelity through the forwarder: simulated Git Bash runs `bin/cx-init --dry-run --json --test "$WEIRD"` where WEIRD holds spaces, `"`, `'`, `$HOME`, backslashes, a newline, `é—✓` and a leading `-`; `detected.test` equals it byte for byte; `--lint ''` arrives as an empty argument (→ null); with `CX_DEBUG=1` the kept `argv` file equals `printf '%s\0'` of the arguments; `cx-wsl bash -c 'printf "%s\0" "$@"' _ "$WEIRD" ''` prints exactly those two arguments; every Windows path in `meta` came from `cygpath -w -l` |
| P14 | §7.3, §7.4 | Env allowlist: with `CX_DEBUG=1 CLAUDE_PLUGIN_OPTION_POLICY=off GH_TOKEN=x COPILOT_MODEL=y FOO=z` the kept `env` file holds only `CX_DEBUG` and `CLAUDE_PLUGIN_OPTION_POLICY` (`CX_SLOT_WAIT_SECS` crosses too when set, A25); the stub logged only `CX_FWD_WIN` crossing via `WSLENV` |
| P15 | §7.3, §7.4 | cwd mapping: a drive cwd and a `\\wsl.localhost\Ubuntu\…` cwd reach the same repo on the WSL side (`CX_FORWARD.cwd`); a `\\server\share` cwd → `cx-init` and `cx-wsl` exit 42 (one `CX_SIGNAL`, from wsl-entry.sh), `cx-doctor` runs from `$HOME` with `cwd: null`; a `TMPDIR` with a short-name component (`JOHNSM~1`, `STUB_CYGPATH_SHORT`) still maps because the forwarder passed `-l` |
| P16 | §7.3, §7.4 | Exit propagation (forwarded `cx-init` 5, `cx-doctor` 4 and 0, `cx-wsl bash -c 'exit 37'` 37 with no `CX_*` line); no `wsl.exe` → 40 with the constant reason; `STUB_WSL_FAIL=nodistro` with `STUB_WSL_IGNORE_UTF8=1` → 40 and the note shows the decoded English message; `STUB_WSL_FAIL=crash` (after `started`) → 40 `FORWARD_FAILED`; wsl-entry.sh version mismatch → 41; in every failure exactly one `CX_SIGNAL` line in total; invalid `wsl_distro` → 40 without invoking wsl.exe; `wsl_distro=auto` → the wsl.exe argv has no `-d` and `CX_FORWARD.distro` is the stub's default; stdin reaches the child (`printf x \| cx-wsl bash -c 'cat'` prints `x`); INT during a forwarded call whose WSL-side child sleeps → 130, and the Linux-side child (and its process group) is gone within 6 s; under a pty (python3 `pty.fork`) a forwarded `cx-wsl bash -c 'read -r x; echo "got:$x"'` reads the terminal and prints `got:hello` within 15 s (no SIGTTIN stop) |
| P17 | §7.3, §7.5 | Runtime auto-install: an empty WSL home → the first call installs (`installed: true`, stamp, `current` link) and succeeds; the second call does not reinstall; `CX_NO_AUTO_INSTALL=1` → 41 (one `CX_SIGNAL`, from the forwarder) |
| P18 | §7.5 | `install-runtime.sh`: copies only the six directories; exec bits; a mid-line CR → exit 44 and the old runtime stays; identical reinstall → `changed: false`; a changed source replaces the copy and moves `current`; two concurrent installs of one source → one `changed: true`, one `changed: false`, a single clean tree (no copy nested inside `runtime/<version>/`); bootstrap mode (`bash -s` with `CX_STAGE_WIN`) from a cwd that holds a file named `main` still installs from the stage |
| P19 | §7.4, §7.6 | WSL-side environment: the host record's `.path` is used when present; the fallback has `$HOME/.local/bin`, `/snap/bin`, `$HOME/.bun/bin`, `$HOME/.cargo/bin` and no `/mnt/` entry although the stub appended `/mnt/c/Windows/System32`; `DBUS_SESSION_BUS_ADDRESS` and `XDG_RUNTIME_DIR` from the stub survive; the three auto-update pins are set; a forwarded doctor never replaces an `interactive` record `path`; host-record wrappers come from the `scope: "user"` entry when a project entry is listed first, and a moved `installPath` is re-resolved once |
| P20 | §10.2–§10.6 | Each of the four policy JSON files parses; `hookEventName` = `SessionStart`; each `additionalContext` equals its block in this file (`policy`, `policy-gitbash`, `policy-crlf-context`, `policy-cloud-context`), and the CRLF and cloud files' `systemMessage` equals `policy-crlf-system` / `policy-cloud-system`; all ASCII; the WSL and Git Bash texts are ≤ 2,800 characters with the longest `{ORDER}` phrase and the unattended sentence substituted, end with exactly one `{ATTN}`, contain `--new-project` and the skill-first rule (`load the conductor skill`), and the Git Bash text contains `cx-wsl`; both texts name the background timeout (`background Bash call with timeout 7200000`); `agy-media`, `/antigravity:research` and `agy-handoff` appear only in a `Never` clause; the WSL text keeps the inline agy registration, forbids both `antigravity-delegate` and `grok-delegate`, and says `--github acts as you`; the Git Bash text shows no raw agy command and prefixes `gh pr edit` and `ghcp-ci-debug` with `cx-wsl`; the CRLF notice gives no `core.autocrlf` advice |
| P21 | §10.2 | `policy.sh` prints exactly the selected file with `{ORDER}` replaced and never prints `{ORDER}`; orders: unset → `agy (raw), then Copilot, then own subagents`; `copilot,agy` and ` COPILOT, AGY ` → Copilot first; `copilot` → `Copilot, then own subagents`; `agy,agy`, `bogus`, `*` → the default phrase; `STUB_UNAME_S=MINGW64_NT-10.0-26100` (and `MSYS_NT-…`) → the Git Bash variant; `CLAUDE_PLUGIN_OPTION_POLICY` = `off`, `OFF`, ` no `, `disabled`, `0`, `false` → nothing; `CX_WORKER=1` → nothing, `CX_WORKER=0` → printed; stdin `not json` or closed → exit 0 with output; missing JSON file → exit 0, nothing; stderr empty every time; works with a PATH holding only `bash` and `cat` (no `uname`: the WSL variant); empty segments (`copilot,,agy`, `copilot,agy,`, `,copilot`, `,`) → the default phrase, the same order `cx_opt opus_lane_order` uses |
| P22 | §10.2, §3.5 | A CRLF-converted copy of `hooks/` run as `bash <copy>/hooks/policy.sh`: exit 0, empty stderr, stdout parses with the same `additionalContext`; with the option off, nothing |
| P22b | §10.2, §3.5 | A fully CRLF-converted copy of the plugin (every file) run as `bash <copy>/hooks/policy.sh`: exit 0, empty stderr, stdout parses and is the CRLF notice (`systemMessage` present, `additionalContext` = `policy-crlf-context`); the same with only `bin/cx-doctor` converted; with the option off, nothing; the `find … -exec sed` fix the notice prints, run in a fully CRLF copy, restores it (normal policy, `cx-doctor --version` runs) |
| P23 | §10.1 | Replaced by P53 |
| P24 | §11 | Exactly the 8 shims; each a regular executable LF file; with arguments, stdin and env: stdout empty, stderr exactly `blocked: CX_WORKER\n`, exit 126; `PATH="worker-shims:$PATH" CX_WORKER=1 claude -p x` exits 126 and the claude stub logged nothing |
| P25 | §8.1–§8.3, §7.6 | All-green doctor (stubs ok, fake plugins, sibling options off, deny rules, pins exported, grok config) → exit 0, no ✗, `CX_DOCTOR.fail` 0; host record with absolute bins (wrappers from the fake installPaths) and a `.path` without `/mnt/`; `--no-record` writes nothing |
| P26 | §8.3 | One failure at a time (0.2.1: no pins): copilot `1.0.106-1` → ✓ D9 plus the last-verified info line, D16 through ghcp-models, exit 0, the copilot stub never saw `-p`; copilot 1.0.106 without ghcp → ! D16 "login not probed"; grok `1.0.73` → ✓ D10 plus the info line; claude `2.1.300` → ! D8 (exit 0); agy `1.1.9` → ✗ D11; grok unauthenticated → ✗ D17 naming `grok login --device-auth`; grok models rc 1 with a network error and no ids → ! D17 with that line (not ✓); ghcp-models rc 11 / 16 → ✗ D16 with the login / sandbox text; ghcp absent → the copilot stub saw `--model __cx_doctor_probe__` and `--disable-builtin-mcps`; agy models empty → ✗ D18; agy hang (with `CX_PROBE_TIMEOUT=2`) → ! D18 "hung"; `loggedIn: false` → ! D15 (exit 0); gh auth rc 1 → ✗ D19; gh without `@copilot` in `pr edit --help` → ! D12; agy `models` printing a status envelope or a "not signed in" line with rc 0 → ✗ D18 (never "logged in"); with `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `XAI_API_KEY`, `GROK_SANDBOX` exported and no pins, every agy and grok probe runs without the keys and with its auto-update pin; on WSL, copilot, grok and claude found only under the automount root never resolve (their lines name the Windows path, the record stores `null`), and a `GHCP_COPILOT_BIN` there is ignored with ! D9; WSL without `WSL_DISTRO_NAME` and a non-default `CX_HOME` → ! D1 each; forwarded in a repo with an SSH origin and `commit.gpgsign=true` → ! D5 each; the missing-CLI cases run on the stub copy plus a directory of system-tool links, never `$REAL_PATH`, and a check asserts that PATH resolves no copilot, grok or agy |
| P27 | §8.3 | Siblings: ghcp options unset (default on) → ! D21 with the exact `claude plugin configure` command; both off → ✓; antigravity default timeout → ! D22; grok-build installed → both D23 warnings; deny rules missing → ! D24, the `Agent(...)` spelling accepted; allow rules missing → D25 info; forwarded (`CX_FORWARDED=1`) → D25 reads `CX_WIN_SETTINGS` and lists the `Bash(cx-wsl <tool>:*)` rules, never `Bash(cx-wsl:*)`; `Bash(cx-wsl:*)` present → ! D25 (forwarded: replace it; in WSL: remove it); conductor `policy=off` → no overlap warning; a `grok leader` process → no D27 line, a `grok worker` process → ! D27 |
| P28 | §8.3 | `COPILOT_AUTO_UPDATE` unset → ! D14, set → ✓; forwarded with the three exports present in `~/.profile` → ✓ D14 although the env was not read from it; grok `[cli] auto_update = false` → ✓; `COPILOT_MODEL`, `GH_TOKEN`, `XAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY` or `ANTHROPIC_API_KEY` set → ! D28 each (API keys with "bills an API account instead of the subscription"); Copilot logged in only through `GH_TOKEN` (`STUB_COPILOT_TOKEN_ONLY`) → ✓ D16, `copilot_token_env` recorded, D28 info for it |
| P29 | §8.3 | A plugin copy with a CRLF `hooks/policy.sh` → ✗ D3 naming the file with the sed fix and the autocrlf + update fix; no fix text anywhere in the doctor contains `reset --hard` or `rm -r --cached`; a fake marketplace clone that is not its own git toplevel (inside an enclosing repo) → no git-based fix printed; a real toplevel clone → the `checkout-index` fix; a forwarded doctor running from the runtime copy checks the installed copy, not the runtime (no ✗ D3 for `skills/` or `commands/`); the last fix is the folder-marketplace / archive fallback, never autocrlf advice; a plugin root with spaces: the sed and `chmod` fix lines quote each path and, run as printed, repair the copy; the clone's `checkout-index` fix ends with `claude plugin update` |
| P30 | §3.7 | Across the suite no stub logged `BILLABLE`; copilot saw only `--version` or the doctor probe; grok only `--version` and `models`; agy only `--version`, `models`, and `-p /usage` when `--agy-usage` was given; claude only `--version` and `auth status`; ghcp-models always got an absolute `GHCP_COPILOT_BIN` and `--refresh` for D16; every copilot and ghcp-models probe ran with cwd `$CX_HOME/probe` |
| P31 | §8.4 | `--pools`: agy Opus slugs from the fixture; `claude-opus-5.5` enabled → ✓, removed from the fixture → ✗; `--set-copilot-mtd 1234` writes `pools.json`; an old or missing figure → info with `copilot_reserve_pct=0` and ! with `copilot_reserve_pct=10`; reserve 0 reported as off; D16 not probed (unpinned copilot) → the copilot pool comes from ghcp's cache file with its age and ghcp-models never runs; `--agy-usage` adds exactly one `agy -p /usage` call and none without it; `CX_POOLS` parses |
| P32 | §8.5 | `--login-help` for each CLI contains its exact command (`copilot login`, `grok login --device-auth`, `agy`, `gh auth login --web`, `claude auth login`); runs without python3; the Git Bash variant starts with the WSL-terminal sentence; no stub invoked; exit 0 |
| P33 | §8.7 | `--json` parses, matches §8.7, statuses in the enum, same exit as text mode |
| P34 | §8.6 | Simulated Git Bash without python3: W1–W9 with stubs (W1 fails when `timeout` resolves to a non-GNU stub; distro list from the UTF-16LE fixture with a multi-word STATE; W2 with `wsl_distro=auto` takes the `*` row, an explicit missing distro ✗ W2; drive cwd ! W3; dubious ownership ✗ W5 with git's own suggested command; CR in `templates/` of the Windows-side copy ✗ W6; natively installed ghcp in the fake `%USERPROFILE%\.claude` ! W7; W8 prints `cx-doctor 0.1.0`; W9 with a `direct` logged-in record and a forwarded logged-out probe → ! "keyring unreachable through wsl.exe" with the token-file fix); default Git Bash `cx-doctor` shows a "Windows (Git Bash)" section in the forwarded report and returns the WSL side's exit; W6 covers every shipped file (`bin/cx-wsl`, `scripts/cx-init.sh`), and its sed fix for a copy under a path with spaces, run as printed, removes every CR; with `--json` a forwarding failure leaves stdout empty, the W report on stderr and one `CX_SIGNAL` last; `--windows --json` → exit 1 |
| P35 | §9.3 | Detection matrix on generated repos: npm (lock / no lock → `npm install --no-audit --no-fund --no-package-lock` / default test script), pnpm (lockfile, `packageManager`), yarn classic, yarn berry, bun (`bun.lock` → setup null with a note, `bun run test`), python plain with pytest+ruff+mypy, uv, poetry, go with and without golangci config, rust with a tracked `Cargo.lock` (`cargo fetch --locked`) and without (setup null with a note), Makefile only, `tests/run-tests.sh` only, node+go (joined with ` && `), nothing; after each detected `setup` runs in a fresh worktree, `git status --porcelain` is empty (where the tool is installed; SKIP otherwise) |
| P36 | §9.1, §9.2, §9.4, §9.5 | Write rules: fresh repo → 3 files, exit 0, `/.conductor/` once in `info/exclude` after two runs; rerun → all `same`; edited block → exit 5, nothing written; `--force` replaces only the block (outside text byte-identical); an `AGENTS.md` without a block → `update` without `--force`, block appended, earlier text byte-identical; `--only agents --force` never touches an edited `routes.json` (`skipped`); JSON-equal routes.json with other whitespace → `same`; `--dry-run` writes nothing, same exit; not a repo → 1; subdirectory → toplevel; `CLAUDE.md`, `.claude/`, `.gitignore`, `.gitattributes` checksums unchanged; routes.json keys and order per §9.4, pools all true; the AGENTS.md block contains the sentence `If \`.conductor/task.md\` exists in your working directory (you are a conductor worker):` and no worker-only rule above it; copilot-instructions.md says the worker-only rules do not apply to Copilot coding agent tasks assigned on GitHub; the Setup line reads `Setup (run by the caller before you start; do not run it unless your task says so):`; committed `.github`/`.cx` symlinks to directories outside the repo, or a regular file `.cx` → conflicts, exit 5, nothing written anywhere (not even `AGENTS.md`) |
| P37 | §9.1 | Notes for a missing `.gitattributes` and `core.autocrlf=true` |
| P38 | §3 | Every `*.sh` passes `bash -n`; shellcheck clean (SKIP when absent); `python3 -I -m py_compile scripts/lib/cxlib.py` |
| P39 | §3.5, §2.2 | Every shipped text file is LF-only and ends with a newline; `.gitattributes` content as in §2.2, with `tests/fixtures/** -text` and `*.utf16le binary` as its last two lines; `git check-attr text eol -- tests/fixtures/settings/win-bom-crlf.json` reports `text: unset` |
| P40 | §3 | No `python3 -c`; every `python3` call is `python3 -I`; no `jq` or `node` calls; no `set -e`; every script (`worker-shims/*`, `hooks/policy.sh` and `scripts/host/wsl-entry.sh` included) has the bash shebang and a header comment; `--help` prints the header and `--version` prints `<prog> 0.1.0` for `bin/*`, `scripts/*.sh` and `scripts/host/{detect,pathmap,forward-wsl,install-runtime}.sh` only (P24 and P21 own the shims' and the hook's output); bin shims are 3 lines, not symlinks, executable, and work from a relative path with `CDPATH=.` exported |
| P41 | §13.4, §7.5 | Every listed file exists; the doctor's D3 list equals §13.4; `install-runtime.sh` copies exactly the subset under `.claude-plugin bin scripts hooks worker-shims templates` (and D4 accepts exactly that subset plus `RUNTIME_STAMP`) |
| P42 | §3.1, §7.3 | Git Bash code paths run on the simulated Git Bash PATH (stub dir + the §3.1 mini bin + a `python3` trap): forwarding, `cx-wsl` forwarding, `--windows`, `--login-help`, `cx_signal`, `cx_opt_lite`, `policy.sh`; the case fails if the trap logged `PYTHON_CALLED`; a script that needs a tool missing from the mini bin fails the case; `CX_FORWARDED=1` leaked into the Git Bash environment still forwards (the wsl.exe stub was invoked) |
| P43 | §12 | SKILL and commands frontmatter present; every frontmatter value that starts with `[` or `{` is double-quoted (all three `argument-hint`s are); `route.md` has `allowed-tools: Read, Glob, Grep`; SKILL exit table has `\| 130 \| CANCELLED \|`, README has ``\| 130 \| `CANCELLED` \|``; SKILL contains the §12.2 commands verbatim (`agy-delegate --model claude-opus-5-5-high`, `ghcp-delegate --model claude-opus-5.5 --effort high`, `--new-project`, `timeout -k 5 60 agy`, `--no-subagents`, `--test-cmd`), every `grok`, `agy-delegate`/`agy-job` and `ghcp-delegate`/`ghcp-job`/`ghcp-handoff`/`ghcp-ci-debug` command line in it carries its §12.2 prefix or runs through `cx-wsl` (`env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1`, `env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1`, `env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1`), no `export CX_WORKER`; the recipe headings appear in the order of §12.1 item 4 (Step 3 after-run before Step 4 reviews before Step 5 GitHub); no `ghcp-ci-debug … --apply` without `--dir "$WT"`; every non-comment line of every bash block of §12.2 appears in the SKILL verbatim; every executor and GitHub simple command of the SKILL's bash blocks (the `vars.sh` line, prefixed wrappers, raw agy and grok, `git push`, `gh pr`) starts with a `cxlib.D25_HOST_RULES` rule and every rule matches one of them (both ways; each `cxlib.D25_WIN_RULES` `cx-wsl` form is one the SKILL's Windows section names, none for `cx-wsl bash`, `agy` or `ghcp-delegate`), and no `gh` or `git push` runs in a `(cd … && …)` subshell; no SKILL code block runs `agy-media`, `agy-handoff`, `/antigravity:research` or `--yolo`, and the `agy-media` lane row is not marked read-only; the rules for every call name `timeout: 7200000`; the SKILL's `trees` snapshot, run in a scratch repo, ignores `$WT` and flags a write in a previous task's worktree and a second edit to an already-modified file; the SKILL's Step 3, run in a scratch repo, exits 24 `BRANCH_TAMPERED` after an executor switched branches (cx/t1 still at BASE, nothing gated) and otherwise gates the exact squashed commit; after a simulated `ghcp-ci-debug --apply` (switched to `ghcp/ci-fix-99`, edits uncommitted) the SKILL's two hand-back lines plus Step 3 commit the fix on top of the pushed commit and gate it, while Step 3 alone exits 24; every block of the SKILL and §12.2 that registers or runs agy has the slot line (§15.3) before it, and no block starts an `agy-job`; the slot line, run in a scratch home with `CX_SLOT_WAIT_SECS=1`, exits 28 with one `CX_SIGNAL NO_CAPACITY` while every agy slot is held, also while a Phase 1 step holds `~/.conductor/locks/agy`, and proceeds once they are free; the D25 and prefix checks also cover `ghcp-cloud`, `ghcp-ci-debug` and `gh repo` |
| P44 | U5 | No Cursor option, adapter or doctor check: a case-insensitive grep for `cursor` over every shipped file outside `docs/`, README and CHANGELOG matches only the `worker-shims/cursor-agent` file name (and references to it) and the two message constants `CURSOR_WORKER_MSG` and `CURSOR_POOL_MSG`, defined once in `cxlib.py`; the test names those constants and checks each is defined exactly once |
| P45 | §7.7 | `cx-wsl`: tools outside the allowlist (`copilot`, `claude`, `agy-handoff`, `agy-media`, `rm`, `cx-doctor`) → exit 1 without running anything; `ghcp-cloud` is allow-listed and resolves from the record; the token route: a 0600 `$CX_HOME/secrets/copilot-token` becomes `COPILOT_GITHUB_TOKEN` for `cx-wsl ghcp-*` only (a caller's own token wins, `cx-wsl bash` never gets it, a 0644 file or a symlink is ignored with a note); an allow-listed tool resolves from the host record (`ghcp-models` via the fake install dir; a PATH entry of the same name is never used); no record → 13 with one `CX_SIGNAL`; the passed-through tool's exit status and stderr are unchanged and no `CX_*` line is added; `cx-wsl grok --version` with `XAI_API_KEY` and `GROK_SANDBOX` set → the grok stub's env dump lacks both and has `CX_WORKER=1` and the `GROK_CLAUDE_*` / `GROK_DISABLE_AUTOUPDATER` values; the same prefix checks for `ghcp-models` and `agy`; `cx-wsl bash` sees the sibling wrapper dirs on PATH; `agy-media` is refused too (it always passes `--yolo`); `cx-wsl bash -s` with a CRLF step on stdin runs it with LF and prints a `cx-wsl:` note, an LF step runs unchanged with empty stderr |
| P46 | §10.2 | `policy.sh` cloud matrix: `CLAUDE_CODE_REMOTE` = `true`, `TRUE`, ` 1 `, `yes`, `on`, `On` → exactly `policy-context-cloud.json`; kinds `byoc` (also with `exec_host=wsl`) and `self_hosted` → cloud; plain Linux → cloud; kind `bridge` (with or without REMOTE), REMOTE `false`, `0`, empty, `CLAUDE_CODE_HOSTED_DESKTOP=1` or `CLAUDE_CODE_ENTRYPOINT=remote_projects` alone, any non-bridge kind (`byoc`, `self_hosted`, `BYOC`) with `exec_host=local` (any case, spaces) → the normal policy; REMOTE without a kind (or byoc) on WSL (`uname -r` with `microsoft`, `WSL_DISTRO_NAME`, a `WSLInterop` file under `CX_DETECT_ROOT`) → the WSL policy, on simulated Git Bash → the Git Bash policy; a bridge child on Git Bash → the Git Bash policy; cloud with `CX_WORKER=1` or the option off → nothing; the cloud file unreadable → nothing, exit 0; CRLF copies and a CR canary still select the cloud notice |
| P47 | §10.6 | `policy-context-cloud.json` parses; `SessionStart`; equals `policy-cloud-context` and `policy-cloud-system`; ASCII; ≤ 1,000 and 200 characters; contains `CONDUCTOR INACTIVE`, `Work locally` and `Claude agents only`; no `cx-wsl`, `agy --new-project`, `{ORDER}` or `{ATTN}` |
| P48 | §7.1 | `cx_session` truth table (empty, `true`, `TRUE`, ` 1 `, `yes`, `On`, ` true `; kinds `byoc`, `self_hosted` → byoc, `bridge` with and without REMOTE; `false`, `0`, `false`+byoc → local); never cloud or byoc on Git Bash (`MINGW*`, `MSYS*`) or WSL (`uname -r` with `microsoft`, `WSL_DISTRO_NAME`, a `WSLInterop` file under `CX_DETECT_ROOT`), with no kind, `byoc` or `self_hosted` → local. The suite's default host is plain Linux even on a WSL machine (`STUB_UNAME_R` pinned when the real kernel is WSL's), so the cloud cases stay cloud there |
| P49 | §7.3, §8.3 | With `CLAUDE_CODE_REMOTE=true`: `cx-wsl ghcp-models --json`, `cx-wsl agy-delegate …`, `cx-init --dry-run` exit 43 with the `cloud session` note and exactly one `CX_SIGNAL HOST_UNSUPPORTED` last, empty stdout, no stub ran; byoc too; `cx-doctor` prints its header, ✗ D30 and the summary and exits 43 (with `--json`: stdout empty), `--pools` probes nothing, no host record; byoc with `exec_host=local` runs the full doctor; on simulated Git Bash the same variables do not count (a Git Bash host is never cloud): `cx-init`, `cx-doctor` and `cx-wsl` forward into WSL as usual and the doctor says `session local`; `--help`, `--version` and `--login-help` still exit 0; a bridge child is never refused |
| P50 | §7.3, §8.6 | `CLAUDE_CODE_ENVIRONMENT_KIND=bridge` on simulated Git Bash: argv fidelity (P13) and exit propagation (P16) unchanged; the env file still holds only its allowlisted variable (no `CLAUDE_CODE_*` crosses); W10 reports `bridge`, the WSL side prints no D30 and no D32, the header and `CX_DOCTOR` say `session bridge` |
| P51 | §8.3, §8.6 | D30 `local` (entrypoint, desktop version, `CLAUDE_PROJECT_UUID`), `bridge` (the shared pool slots, never unattended, no desktop warning), byoc + `exec_host=local`, attended 0 (info, `--json` `attended` 0); the desktop WSL-session ! on a WSL host with entrypoint `claude-desktop`; D31 and W10: each blocker (environment, settings `env`, `disableRemoteControl`, claude 2.1.279, a gateway `ANTHROPIC_BASE_URL`, `ANTHROPIC_API_KEY`) is an info line and never ! or ✗, `https://api.anthropic.com/` is no blocker, the doctor exits 0 |
| P52 | §9.6, §12.1 | `templates/projects-instructions.md` equals the §9.6 block; ASCII, LF, ≤ 2,000 characters; says every thread runs Work locally, `these win`, the conductor shares its pool slots between threads (`cap_agy`), the executors' own clouds (`ghcp-cloud`), a cloud thread works with Claude alone; the SKILL has its Projects subsection; README says where to paste it |
| P53 | §10.1 | `hooks.json` parses; exactly `SessionStart` and `SubagentStart`; matchers exactly `startup\|clear\|compact` and `workflow-subagent\|general-purpose`; commands exact; both `"onFailure": "continue"`; no `PreToolUse` in Phase 1; both scripts exist |
| P54 | §10.7 | `subagent.sh` prints `subagent-context.json` byte-equal for both agent types and whatever the stdin (none, `not json`, closed, 1 MiB in < 3 s), also in the cloud; silent with the option off (six spellings), `CX_WORKER=1` or another `agent_type`; `CX_WORKER=0` prints; works with only `bash` and `cat` on PATH; a CRLF copy gives the same text |
| P55 | §10.7 | Both subagent JSON files parse; `hookEventName` `SubagentStart` / `SessionStart`; `additionalContext` equals the `subagent-context` block; ASCII, ≤ 800 characters; contains `EXECUTOR_NEEDED`, `cx-wsl` and every executor name; no `"`, `\` or `&` |
| P56 | §10.2 | Compaction: `{"source":"compact","agent_id":"a1","agent_type":"workflow-subagent"}` and `general-purpose` → the compact guard; `conductor:cx-runner` or `ghcp:ghcp-delegate` with `agent_id` → nothing; `agent_type` without `agent_id`, no or an empty `agent_id`, closed stdin, 1 MiB of stdin (< 3 s) → the main policy; cloud plus a subagent payload → the guard; a CRLF copy agrees |
| P57 | §10.2–§10.4 | `{ATTN}`: `CLAUDE_CODE_SESSION_ATTENDED=0` → both variants end with the unattended sentence; `1`, empty, or `0` with kind `bridge` → none; the output never holds `{ATTN}` or `{ORDER}`; both texts carry the Workflows line (`Workflows (ultracode too)`, `isolation worktree or remote`, `cx-run --background`, the pool slots shared by all sessions and threads); the Git Bash text says `cx-wsl bash -s`; the P21 matrix still passes |
| P58 | §7.1 | `cx_attended`: `1`, `0`, `0` + bridge (empty), empty, `yes` (empty); `detect.sh --field session` and `--field ATTENDED`; `--shell` lists both on simulated Git Bash with a silent `python3` trap; `--json` and `--emit` have both |
| P59 | §8.3, §8.6 | D32 matrix through `cxlib.py doctor-session`: ultracode in user, project over user, local `enableWorkflows: false`, a managed file (BOM + CRLF) and a drop-in `disableWorkflows`, `CLAUDE_CODE_DISABLE_WORKFLOWS`, `CLAUDE_CODE_WORKFLOWS=false`, keyword trigger off, guideline `small`, each model and effort variable, nproc 8/3/64/1 → 6/2/16/2, the env override wins, a forwarded run has D31 only; every line info. W11 over a BOM + CRLF Windows file (a nested `disableWorkflows` ignored) and Program Files' managed file (wins) with no python |
| P60 | §12.2 | Snapshot exclusion: `trees` is defined once (in step 1's `vars.sh`, SKILL and §12.2) and carries `':!.claude/worktrees'`; in a scratch repo, a file under `.claude/worktrees/x/` and a `git worktree add .claude/worktrees/y` (with an edit inside it) between two snapshots → no `WRONG_TREE`; an edit to a tracked file of the main checkout still → `WRONG_TREE`; with `TOP` itself a Claude worktree (`<main>/.claude/worktrees/A`), an edit in the sibling `B` → no `WRONG_TREE`, a worktree named in a `~/.conductor/out/<id>/running` mark → ignored, flagged again once the mark is gone, the main checkout and `TOP` → flagged |
| P61 | §12.1 | SKILL: the subagent preface is the first paragraph after the title; "Workflows and ultracode" then "In a Claude Code Project" before section 5; the claude-pool js block is static (starts `export const meta = {`, a pure-literal `meta` with `name` and `description`, no `Date.now`, `Math.random`, `new Date(`, `isolation`, `agentType`, `import`, `require`; `effort` set; the WSL path quoted, `cd "${t.wt}" &&`; a `t.wt_win` prompt with file tools on `${t.wt_win}` and commands through `cx-wsl bash -c 'cd "${t.wt}" && <command>'`); the SKILL never mentions `bashCommandClamp`; P43 still passes |
| P62 | §14.1 | The suite's environment has none of the session, attended, Work locally and workflow variables of §14.1 (each by name); no file under `bin/` or `scripts/` reads `CLAUDE_PROJECT_DIR`, `CLAUDE_CODE_VERSION` or `CLAUDE_CODE_ENTRYPOINT` (the D30 wording lines allow-listed) |
| P63 | §13.4 | The new Phase 1 files are in §13.4, `CX_SHIPPED_FILES` (D3, W6) and, for `hooks/subagent.sh`, `CX_SHIPPED_EXEC`; the runtime subset is unchanged; no `agents/` or `workflows/` yet |

`CX_PROBE_TIMEOUT=<secs>` (env, any value ≥ 1) caps every doctor probe timeout; it exists for
the suite and for slow machines and is documented in the doctor's `--help`.

### 14.4 Live checks (manual, Phase 1; not in the suite)

None spends Copilot or agy credits. Run the Projects and workflow checks first, in this order:
L11 (the user's top question, U7), then L13–L15 (free), L16 and L18 before closing Phase 1, L19
with L11's thread, L17 and L20 before Phase 2's optional workflow work. The checks after L15 cost
a few Haiku turns: set model `haiku` and effort `low` first (for Projects, the thread model and
effort in Project settings). Delete every probe file afterwards; the probe log holds ids and
paths.

| ID | Where | Check | Decides |
|---|---|---|---|
| L11 | WSL terminal | **First:** `cd ~/<repo> && claude remote-control --spawn worktree` (answer the trust prompt), then start a Work locally thread on that folder from the desktop app's Projects; in it run `cx-doctor --version`, then `cx-doctor` outside the sandbox (free probes), and quote the first line of any CONDUCTOR POLICY in its context | §20 item 40: whether `claude remote-control` inside WSL serves Work locally threads and loads the WSL user-scope plugins (policy, skill, `cx-*` on PATH, D30 `session bridge`); if it does, it becomes the recommended Projects route (no Git Bash, no forwarder, no `/mnt/c`) |
| L8 | Desktop app | Open Projects (BETA) in the Code tab sidebar: New project or Get started? | Which feature the user has; eligibility |
| L9 | One cloud thread of a test project (a safety-net check only, U7) | `env \| grep -E '^CLAUDE_CODE_(ENTRYPOINT\|REMOTE\|ENVIRONMENT_KIND\|REMOTE_ENVIRONMENT_TYPE\|PROJECTS_SESSION)=\|^CLAUDE_PROJECT_UUID='; uname -sr; command -v cx-doctor copilot grok agy wsl.exe` | §20 item 41; confirms a cloud thread has no conductor and no executors |
| L10 | Windows desktop app | A probe SessionStart hook (both `%USERPROFILE%\.claude\settings.json` and WSL `~/.claude/settings.json`) that appends `uname -a`, `$0 $SHELL $BASH_VERSION $MSYSTEM $PWD` and the `CLAUDE_CODE_*`/`WSL_*` variables to `~/cx-probe.log`; then (a) a local session on a `C:\` folder, (b) a `\\wsl.localhost\…` folder from the picker, (c) a Work locally thread on a `C:\` folder; in each, `command -v cx-doctor && cx-doctor --version` | §20 items 42–45 and 12: Work locally on Windows, the hook shell, the entrypoint, `bridge`, plugin loading (also in WSL sessions), the `$PWD` form; supersedes L2 and L3 |
| L12 | The L10c thread | `cx-wsl ghcp-models --json --refresh` and `cx-doctor --windows` (free probes) | Forwarding from a Windows Remote Control child; §20 item 46 (does auto mode prompt?) |
| L13 | WSL | `claude plugin validate` on a `git ls-files` copy with the Phase 1 `hooks.json` (done 2026-11-01: `onFailure: continue` and `SubagentStart` accepted, a bogus `onFailure` reported), then with a dummy `agents/cx-runner.md` and `workflows/opus-pools.js` | §20 item 50; whether `agents/` and `workflows/` validate |
| L14 | WSL scratch repo | `git worktree add .claude/worktrees/probe -b probe && git status --porcelain; git worktree remove .claude/worktrees/probe` | §20 item 55 |
| L15 | One of the user's cloud sessions | Ask Claude to call `list_computer_folders` (read-only) and quote `folders` and `cannot_be_used` | §20 item 57 |
| L16 | WSL terminal, `claude --plugin-dir <copy> --model haiku --effort low` | "Use the Workflow tool: 2 agents, each replies with the first 40 characters of any text starting CONDUCTOR SUBAGENT RULES in its context, and the output of echo $CLAUDE_EFFORT." Both should quote the guard; note whether a launch prompt appeared | §20 item 49 |
| L17 | Same, with a Phase 2 copy (`agents/cx-runner.md`, `gate.sh`) | `RUN: cx-doctor --version` → blocked by the gate; `RUN: cx-job status 20261101-000000-abcd` passes it; the same with `bashCommandClamp`; a 5-minute stub job waited through three waits | §20 items 52, 53, 58, 59 (Phase 2 prerequisite) |
| L18 | WSL | Extend L10's probe with `CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_SESSION_KIND AI_AGENT`; start (a) an interactive session, (b) `claude -p --model haiku 'Reply OK'`, (c) the L11 thread | §20 item 51; the `{ATTN}` condition |
| L19 | The L11 thread | (a) type "ultracode: list the top-level files with a 2-agent workflow"; (b) `"ultracode": true` in WSL `~/.claude/settings.json`, a new thread, ask whether ultracode is on, then remove the key | §20 item 56 |
| L20 | WSL, default permission mode | `/conductor:opus-pools` with `{"tasks": []}` (throws before any agent): an approval prompt? Again with `Workflow(conductor:opus-pools)` allowed | §20 item 54 (Phase 2) |
| L21 | WSL, optional | A probe agent forced to compact, with L18's hook logging stdin on `compact` | §20 item 60 |
| L22 | Windows desktop app, optional | An SSH session into the WSL distro (needs sshd): is the conductor policy in context, does `cx-doctor --version` work? | §20 item 61 |
| L1 | Windows box, Git Bash | `wsl.exe -d Ubuntu --exec /usr/bin/setsid -f /usr/bin/sleep 900`; make sure no `wsl.exe` remains; wait 2 minutes; `wsl.exe -d Ubuntu --exec /usr/bin/pgrep -x sleep` | Whether detached jobs survive WSL idle shutdown; if not, §15.5's keepalive is mandatory and `.wslconfig` idle settings get tested |
| L2, L3 | Windows app | Folded into L10 | — |
| L4 | Windows app | `cx-doctor`, `cx-doctor --windows`, `cx-init --dry-run` in a `\\wsl.localhost` repo and in a `C:\` repo; an argument with spaces and quotes; Ctrl-C during `cx-doctor` and during `cx-wsl bash -c 'sleep 300'` (then `wsl.exe --exec pgrep -f 'sleep 300'` finds nothing); the same from an account whose `%TEMP%` contains an 8.3 short name (`JOHNSM~1`) | The forwarder end to end, signal handling and cancellation reaching Linux, long-path handling |
| L5 | Git Bash | `git -C '\\wsl.localhost\Ubuntu\home\<you>\<repo>' status` | The exact safe.directory hint W5 extracts |
| L6 | WSL | The A/B (§6.7) | `opus_lane_order` |
| L7 | Windows app | `cx-doctor --windows` (W9) right after `cx-doctor` in a WSL terminal shows every CLI logged in | Whether the D-Bus/keyring variables kept by wsl-entry.sh (§7.4) suffice, or the token-file route of §8.5 is needed |

## 15. Phase 2: adapters, `cx-run`, `cx-job`, ledger, locks

Sources: plan §6.3 (exact commands), §6.4 (caps), §6.5 (results, served-model checks), §7.3
(job lifetime), §8 (guardrails), §12.1 (adapters), §12.2 (Phase 2 tests).

Waits for Phase 0 captures (`tests/fixtures/real/<cli>/`: `agy --help`, `copilot --help`, grok
JSON output, agy stream-json) before the parsers are final; build against the shapes below and
mark every unverified field in code.

**Build order** (U7, U8). Several Work locally threads and sessions on one computer are the
normal case, so Phase 2 starts with what makes them safe together:
1. **First: cross-process pool slots** (`scripts/lib/locks.sh`, §15.3; built), taken by every executor
   path: `cx-run`, `cx-job` and the adapters, and `cx-wsl` whenever its tool is an executor
   (`ghcp-*`, `agy-delegate`, `agy-job`, `agy`, `grok`), which closes the passthrough bypass.
   Calls forwarded from Git Bash share the WSL side's `$CX_HOME/locks`. When this lands, the
   Projects template's agy line, the policy's Workflows line and the subagent guard switch to
   their Phase 2 texts (§9.6, §10.3, §10.7), and the "one agy run at a time" rule becomes
   `cap_agy` with serialized launches.
2. Then adapters, `cx-run`, `cx-job`, normalizer, ledger, locks' callers and the worker
   environment (§15.1–§15.7; built, with `cx-init --user-grants`), with these changes: the `claude` lane also emits `CX_RESULT` with
   `lane: "claude"`, `status: "dispatched"` and `dispatch: {worktree, host_path, prompt, effort,
   task_file}`; `cx-run` refuses (exit 1) when the cwd's toplevel lies under `.claude/worktrees/`
   and `--repo` is absent (the base would be wrong); ledger lines gain `claude_session`
   (`CLAUDE_CODE_SESSION_ID`) and `claude_effort` (`CLAUDE_EFFORT`); the `--headless` claude
   worker also unsets `CLAUDE_CODE_ENTRYPOINT`, `CLAUDE_CODE_REMOTE*`,
   `CLAUDE_CODE_ENVIRONMENT_KIND`, `CLAUDE_CODE_CHILD_SESSION`, `CLAUDE_CODE_SESSION_*`,
   `CLAUDE_CODE_SESSION_ID`, `CLAUDECODE`, `AI_AGENT` and `CLAUDE_EFFORT` (a nested `claude` that
   inherits a hosted entrypoint can be refused login [docs-only, binary]); `cx-job status` gains
   `queued`; the env knob `CX_SLOT_WAIT_SECS` (default 600, for tests) sets the slot wait.
3. **The Copilot cloud agent lane as an adapter** (`copilot-cloud`; welcome under U7; built:
   `cx-run --exec copilot-cloud`, then `cx-run --finish <id> [--pr N]` gates the PR head). Phase 1
   already has the hand recipe (§12.2 step 5: `ghcp-cloud create -R "$REPO" -` from the main
   turn of a local session, the PR head gated in a gate checkout before anything merges), and
   `cx-wsl` and D25 already allow `ghcp-cloud`. Phase 2 makes it a `cx-run` lane: the adapter
   renders the task from the §6.4 contract (goal, acceptance tests, allowed changes), records the
   task and PR in the ledger, and gates the PR branch like every other lane (fetch it into a gate
   checkout, step 3's tamper and test checks, then §16); reviews and the merge stay Claude's.
   The 59-minute cap and the `model`/`reasoning_effort` fields of REST tasks or Automations are
   [docs-only].
4. **Optional** (U8: ultracode is normally off; not built in 0.2.0): the workflow stage runner
   `conductor:cx-runner` (§15.9), its fail-closed PreToolUse gate (§15.10) and the shipped
   workflow `conductor:opus-pools` (§15.11). Without them the Phase 1 hybrid stays the
   ultracode recipe, with `cx-run --background` from the main turn, and the Phase 2 subagent
   guard (§10.7) lets a default workflow agent run `cx-run --background` and `cx-job wait`
   itself when its task says so, because the slots are shared by then.

### 15.1 `cx-run`

```
cx-run [--exec auto|agy|copilot|grok|claude] [--mode write|read|review|ci] [--family gemini|gpt]
       [--model M] [--effort low|medium|high|xhigh|max] [--fusion standard|max]
       [--task-file F | "<task>" | - | -- "<task>"] [--id ID] [--repo DIR] [--base REF] [--reuse-worktree]
       [--allow CMD]… [--timeout DUR] [--background] [--no-wait] [--headless]
       [--dry-run] [--explain] [--finish ID] [-h|--help] [--version]
```

- Task: `--task-file` is a complete task.md (§6.4, line-1 JSON required). Free text (or `-`) is
  wrapped into the template with routes.json `commands` and no `allowed_paths`; Claude should
  prefer task files.
- `--exec auto`: the first lane in `opus_lane_order` whose pool is enabled in routes.json, is not
  paused, has a slot, passes preflight and supports the effort (§6.3). The agy Opus lane always
  runs in raw mode under `--exec auto`, whatever `agy_opus_mode` says, because only raw mode
  verifies the served model (§6.5 G6); wrapper mode is used only for an explicit `--exec agy`. `claude` prints the
  dispatch JSON (§15.2) and exits 0.
- `--mode`: `write` (default: worktree, then the commit step in Phase 3); `read` (answer only,
  on a read-only gate checkout of `--base`); `review` (§17.2); `ci` (§17.3).
- `--background`: starts the same command through `cx-job` and prints `JOB_ID <id>` on stdout.
- `--dry-run`: no side effects (no worktree, no executor; Copilot argv via
  `ghcp-delegate --print-command`); prints lane, model, effort, argv (`printf '%q '`), env names
  and the worktree path that would be used. `--explain` adds why the lane was chosen and which
  preflight results came from the cache.
- `--no-wait`: no slot → exit 28 at once (default: wait up to 10 minutes, then 28).
- `--finish ID`: run the post-run steps (hash check, commit, gate) for a task executed outside
  `cx-run` (the claude lane, or a Phase 1 manual run).

Flow (write mode): load options, routes.json (absent → defaults and a note to run `cx-init`),
the runtime copy (§7.5) and the host record (refresh when stale) → resolve and validate lane,
model, effort (`max` never leaves Claude; Copilot `xhigh` only with `copilot_xhigh_ok`) →
free preflight (cached 10 minutes in `$CX_HOME/state/preflight.json`): the flag contract (26,
§5.4; no version pin), login (11), model in the catalog (14), pool switch, agy pause → worktree
(`worktree.sh create`; refuse an existing branch or path unless `--reuse-worktree`) → the run's
`cx-route` snapshot (below) → render (`taskfile.sh render`) → `setup`
(25, not charged to the executor) → slot (`locks.sh`) → adapter `run` in the worker environment
(§15.6) under `setsid` and `timeout --kill-after=30s <limit>` → `parse` → post-checks → result
and ledger (§15.4) → output: stdout = the digest, a final `VERIFY THIS: <what to check>` line
(G8) and the diffstat; stderr = notes, `CX_DENIED`, `CX_NOTE`, `CX_RESULT`, `CX_SIGNAL`.

**`cx-route` (the 2026-11-06 probes, decision 2).** Executors run checks only through the run's
`cx-route`. At dispatch, right after the worktree (or gate checkout) exists, `normalize.py
route-snapshot` writes `$OUT/routes.json` (`{"version": 1, "id", "dir", "source", "created_at",
"routes": [{"name", "command"}], "also": ["git status"]}`) and the generated, self-contained
`$CX_HOME/routes/<id>/cx-route` (bash only: no runtime file and no python, so it also runs
inside grok's strict sandbox, whose profile grants `$CX_HOME/routes` read-only: the one
directory of a run grok may read, never the out directories with other runs' tasks, diffs and
digests; grok's own session store `~/.grok/sessions`, which every grok run reads and writes,
still holds other grok runs' transcripts, §20 item 75).
The routes are the task's commands (the task file's `commands`, else the routes commands, plus
`--allow`), each named after its key in the main checkout's `.cx/routes.json` (`test`, `lint`,
`typecheck`, then other keys in sorted order) or `cmd-1`, `cmd-2` … when no key holds it.
`cx-route <name>` cds into the worktree and runs that command with `bash -p -o pipefail -c`;
its exit status passes through. Whoever calls it controls its environment, so it runs under
`#!/bin/bash -p` (no `BASH_ENV`, `SHELLOPTS`, `BASHOPTS` or imported functions) and hands the
check the caller's exported variables through `env -i`, without `BASH_ENV`, `ENV`,
`SHELLOPTS`, `BASHOPTS`, `CDPATH`, `GLOBIGNORE` and the `BASH_FUNC_*` strings exported
functions travel in. `cx-route` alone (or `-l`, `--list`, `-h`, `--help`) lists the
snapshot; any other name, or anything after the name, exits 127 and runs nothing. Nothing reads
the worktree's `.cx/routes.json` afterwards, so an executor that edits it changes no check.
`$CX_HOME/routes/<id>` is on the worker PATH right after the worker shims (§15.6); the task template names
each check as `` `cx-route <name>` (`<command>`) ``, the default prompt says to run checks only
as `cx-route <name>`, and `--dry-run` prints the names. A `--reuse-worktree` re-dispatch writes
a fresh snapshot; the cloud lane has none (no local executor).

Classification, first match: `wrong_tree` 22 → `spec_tampered` 23 → `tampered` 24 (the
worktree's `.git` link) → `cancelled` 130 →
`timeout` 12 → `sandbox` 16 → `auth` 11 → `model_unavailable` 14 → `quota` 10 →
`model_mismatch` 21 → `denied` 15 (any denied write; any denial with no answer and no diff) →
`partial` 27 → `failed` 2 → `empty` 3 (write mode: no diff; read mode: no answer) → `ok` 0.
Preflight statuses (13, 25, 26, 28) stop before the run.

**As built (§15 build order items 2 and 3).** `scripts/cx-run.sh` with the sourced
`scripts/lib/worktree.sh` (worktree root, worktrees, gate checkouts, the change of a worktree
through a scratch index, the running mark; git in a worktree an executor wrote only through
`cx_wt_git`, its git directory taken from the repository's admin files) and `scripts/lib/taskfile.sh` (the contract, its
install and hash), `templates/task.md` for free text. Choices the spec left open:
- **Lanes.** `--exec` also takes `copilot-cloud`. `--mode read` defaults to `grok` (read lanes:
  grok, agy with `gemini-3.8-flash-high` unless `--model`, copilot with `review_model_gpt`,
  claude); its text is the question (the prompt), on a detached gate checkout of `--base`
  (`$CX_HOME/gate/<id>.<n>`, removed after the run). `--mode review` needs `--branch REF` or
  `--diff FILE` (§17.2's flags): `--family gemini` = agy wrapper with `review_model_gemini`,
  `gpt` = copilot with `review_model_gpt` and effort high, or `--exec grok`/`claude`; the base
  is `--base` or the merge base of HEAD and REF; the diff goes to `$OUT/change.diff` and to
  `.conductor/change.diff` in the checkout, which the §17.2 prompt names (relative, so every
  lane reads it); an empty diff exits 3 before any executor. `--mode ci` exits 1 (Phase 4).
  Finding parsing into `review.json` is Phase 4.
- **`--exec auto`.** The order of `opus_lane_order`; a lane is skipped when its effort is not
  offered (agy and Copilot: medium, high; Copilot xhigh with `copilot_xhigh_ok`; low and max go
  to claude at once), its routes pool is off, agy is paused, its cap is 0 or its free probe is
  not green; a lane with a free slot (taken and released at once, `cx_lock_try`) is chosen;
  when every eligible executor lane is full, `cx-run` polls them every 2 s for up to
  `CX_SLOT_WAIT_SECS` (the job's `queued` marker holds `auto`), then takes `claude` (always
  last in the order, §5.1); `--no-wait` skips the wait. agy always runs raw under auto.
  `--model`/`--fusion` need an explicit lane.
- **Ids.** `--id`, else the task's `id`, else `t<UTC date>-<time>-<4 hex>` (`r…` for read and
  review); taken (an `$CX_HOME/out/<id>`, a `cx/<id>` branch or the worktree path) → exit 1
  unless `--reuse-worktree`, checked before the dry run too, so `cx-job start`'s `--dry-run`
  preflight refuses it before a job starts. A task file's `id` that differs from `--id` → exit
  1. One `cx-run` per task: `$OUT/.run.lock` (flock, held for cx-run's whole life including
  `--finish`; its first line names the holder, its `rt=` line the runtime copy) → a second
  `cx-run` of a running task exits 1 (`task <id> is running`), also as a dry run.
- **Arguments.** `--` ends the options: the one argument after it is the task text, even when
  it starts with `-`. `--background` passes the text to `cx-job start` after `--`, and the
  adapters put it after `--` for `ghcp-delegate` and `claude -p` (agy-delegate gets a
  dash-leading prompt on stdin, its `-` form).
- **Order of work.** Validation and the free preflight (the adapter's `probe` and
  `normalize.py verdict`: 13, 26, 11, 14, 28) come before anything is created; a usage error of
  the lane (`max` on Copilot, `xhigh` on agy) is exit 1 with nothing created. Then the out dir,
  the worktree (or gate checkout), the contract and its hash, `$OUT/cx-run.json` (cx-run's own
  state for `--finish`) and `$OUT/vars.sh` (the Phase 1 variables: Steps 3 and 5 of §12.2 keep
  working), `setup` (25: the adapter's argv files are written, then `checks.json` `stop`), the
  adapter's `run` (it writes argv and takes the slot) as a child in its own process group, the
  post-checks, `parse`, `emit`, `report` and the ledger line. A lane stopped before its executor
  ran (the adapter's 28, 13, 26, 11, 14) gets a result too (`checks.json` `stop`), so
  `CX_RESULT` and the ledger see `no_capacity`, `env_failed` and the like.
- **Post-checks** (`checks.json`): `spec_ok` (the worktree's task hash), `git_link_ok` (the
  worktree's `.git` still the link file git wrote, naming the git directory the main
  repository's `worktrees/<n>/gitdir` records for it; false → 24 `tampered`, and no git runs in
  the worktree), `diff`/`diffstat`
  (committed or not, untracked files included, against the base, through a scratch index so
  the worktree's own index is untouched; the name-status list in `$OUT/changed.txt`; a file git
  cannot index, such as an embedded repository without a commit, is a note and hides no other
  change), `branch`
  (a note when the executor left `cx/<id>`: Step 3 then stops with `BRANCH_TAMPERED`). Nothing
  is committed (the conductor commit is §16.2, Phase 3); after a write run classified `ok` with
  a diff the worktree is marked `running` again until Step 3, except for agy tasks (their trees
  stay in later agy snapshots, §12.2's rule); any other status (failed, denied, cancelled,
  empty, …) drops the mark, so agy's snapshots watch that tree again. The mark is set when
  `cx-run` creates the worktree (the adapter keeps it through its run), so a sibling task's
  setup and executor never show in another agy run's snapshots as agy writing into a foreign
  tree. agy's adapter also ignores a stale mark: one whose task has a final status other than
  `ok`/`dispatched`, or no result and a free `.run.lock` (a killed `cx-run`).
- **Gate checkouts** (read, review, the cloud lane's `--finish`) are removed on every exit of
  the run (an EXIT trap), unless kept on purpose: the claude dispatch works in its checkout
  until `--finish`, and a red cloud gate stays for inspection.
- **Host record and runtime.** A missing record, or one older than 7 days or from another
  plugin version, is refreshed with `cx-doctor --record-only`; adapters run from the runtime
  copy (`cx_runtime_ensure` in `common.sh`: installed when missing or older than the plugin's
  files).
- **`--finish ID`** needs cx-run's own `cx-run.json` (a Phase 1 hand run finishes with §12.2
  Step 3). The claude dispatch: the post-checks with `finished: true` (the dispatch is then
  classified like a run: `ok`, `empty`, `spec_tampered`), the final `CX_RESULT` and the ledger
  line (none was written for `dispatched`). The copilot-cloud lane: the PR number from
  `result.json` or `--pr N`; the adapter's `fetch`, a gate checkout of the head, the change
  `BASE...head`, then `setup` and every task/routes command there (logs in `$OUT/gate/`): green
  → `gate: green`, the checkout removed; a failing command → 20 `GATE_FAILED`
  (`checks.json` `gate: red`), the checkout kept; `setup` → 25. A finished task is refused
  (exit 1): a claude task no longer `dispatched`, a local lane's task whose run ended inside
  `cx-run`, a gated cloud task unless `--pr N` is given again (a re-gate after new commits).
  The ledger books a run once and its `--finish` once (`$OUT/ledger.done`,
  `ledger.finish.done`), so a re-gate never books the run again. `--finish --dry-run` checks
  the request only (`cx-job start`'s preflight).
- **Signals.** `cx-run` exports `CX_SIGNAL_OWNER`, so only its own `CX_SIGNAL` is printed;
  INT/TERM/HUP reach the adapter's process group (the adapter kills the executor's session) and
  the run ends 130 with a `cancelled` result; before the executor starts it exits 130 at once.
  A cancellation delivers several signals (`cx-job kill` signals the runner's session, `timeout`
  forwards its own): the adapter keeps its trap until its `rc` and run.json are written, a
  signal after the adapter returned only marks the result cancelled (`checks.json`
  `cancelled`), and an adapter that a signal ended without an `rc` is `cancelled` too, never a
  run that "stopped before its executor".

### 15.2 Adapters (`scripts/adapters/<lane>.sh probe|argv|run|parse`)

Common options: `--out DIR --wt DIR --model M --effort E --mode M --timeout SECS --allow CMD…`.
`probe` prints `{"lane", "bin", "version", "version_ok", "verified", "logged_in", "models",
"model_ok", "contract", "cached"}` (free; `contract` = `{"ok", "checked", "missing",
"unreadable"}`, the flag contract of §5.4; the version is recorded, never judged); `argv` writes `$OUT/<lane>.argv` (NUL-separated) and `$OUT/<lane>.env`
(`NAME=VALUE` NUL-separated, `NAME=` with no value meaning unset); `run` executes them and
writes `$OUT/<lane>.out`, `$OUT/<lane>.err`, `$OUT/rc`; `parse` runs `normalize.py <lane>`.

| Lane | Environment | Argv (write mode) | Parse and checks |
|---|---|---|---|
| copilot | unset `COPILOT_ALLOW_ALL COPILOT_AUTO_TIER COPILOT_MODEL COPILOT_PROVIDER_BASE_URL GH_TOKEN GITHUB_TOKEN`, except the one variable the host record names as `copilot_token_env` (§7.6, D16), and `COPILOT_HOME` when it differs from the host record; `COPILOT_AUTO_UPDATE=false`, `GHCP_COPILOT_BIN=<record bin.copilot>`, `GHCP_USAGE_LOG=$CX_HOME/raw-usage.log`, `COPILOT_GITHUB_TOKEN` from `$CX_HOME/secrets/copilot-token` when that file exists | `<ghcp_delegate> --model <copilot_opus_id> --effort <E> --dir "$WT" --write --allow-shell cx-route --allow-shell 'git status' --timeout <T> --digest -- "$P"` (ghcp turns each into `--allow-tool 'shell(<it>)'`; Copilot matches a shell call by its command name, so the routes commands run through `cx-route` and `shell(python3)` / `shell(:*)` are never granted; nor `git diff`, `log` or `show`, approved by first-level subcommand: their `--output=<path>` writes any file); Fusion: `--fusion standard\|max` instead of `--model/--effort`; read/review: no `--write`, `--dir "$GATE" --add-dir "$OUT"`, the same `--allow-shell` list | answer = stdout; `GHCP_SESSION`, `GHCP_USAGE` (`models_used`, `ai_credits`, tokens), `GHCP_DENIED`, `GHCP_FALLBACK`, `GHCP_NOTE`, `GHCP_SIGNAL`. Served: every `models_used[].model` equals the request (Fusion: any `GHCP_FALLBACK` → 21). #5149: effort xhigh, ≥ 30,000 output tokens and an empty answer → 2 with reason `copilot#5149`. ghcp exits pass through |
| grok | `GROK_DISABLE_AUTOUPDATER=1`, `GROK_CLAUDE_{HOOKS,SKILLS,MCPS,RULES,AGENTS}_ENABLED=false`, `GIT_CONFIG_GLOBAL=/dev/null` (strict cannot read `~/.gitconfig`); unset `XAI_API_KEY`, `GROK_SANDBOX` | `<grok> --prompt-file "$WT/.conductor/prompt.txt" -m <grok_bulk_model> --effort <E> --cwd "$WT" -s <uuid> --output-format json --sandbox <the repository's profile cx-<repo>-<hash>, §15.7> --always-approve --no-subagents --max-turns 60` (the sandbox is the boundary: `--permission-mode acceptEdits` denied the first edit headless, and no `--allow` rules are needed inside it); read/review: the same profile, `--sandbox <it> --always-approve --no-subagents --json-schema <the schema text, inline>` with `--cwd` the gate checkout and the prompt file in its `.conductor/` (never grok's built-in `read-only`: it lets grok write `~/.grok/bin`, `vendor/` and `installed-plugins/`, measured, §1.3; a custom `grok_sandbox_profile` is used in every mode). Every file a run reads lies inside its checkout: `--prompt-file`, `.conductor/task.md` and a review's `.conductor/change.diff` (whether grok reads `--prompt-file` before its sandbox applies or under it is unverified, §20 item 77; under `strict` both work). Before the slot, in every mode: a per-project `.grok/sandbox.toml` in the run's checkout refuses the run, 2 (a writer may leave one, and a review's gate checkout is a checkout of an executor-written branch, which can carry one); the profile is written under `$CX_HOME/locks/grok-sandbox.lock` when missing or different, and again once the slot is held (no conductor grok run can write `sandbox.toml`, which grok write-denies under its profiles, measured: the rewrite guards against everything else); then the per-run profile check, free: `grok --sandbox <the run's profile> models` in the run's checkout (the preflight's probe machinery, worker environment and 30 s bound) and `normalize.py grok-check` on the bytes it appended to grok's sandbox log: a `ProfileApplied` event for the checkout with `enforced` false, or a `read_write_paths` entry that grants write to grok's home (`${GROK_HOME:-~/.grok}` itself, a directory above it or one inside it, compared as given and resolved, but `~/.grok/sessions` and below), refuses the run, 2, before any prompt, as do a line saying the sandbox was not applied and a built-in that writes grok's home (`off`, `devbox`, `workspace`, `read-only`) whatever the log says; the reason names the profile, the path and the log; no log or no event changes nothing; the facts (the event's platform included) go into `grok.run.json` as `sandbox_check`. The preflight runs `grok --sandbox strict models`, free, and a line saying the sandbox was not applied refuses the lane, 2, as does a `ProfileApplied` event with `enforced` false that this probe appended to grok's sandbox log for its cwd, §1.3; `enforced` true records the platform in the probe JSON, and no log or event, or a host without GNU `stat` (macOS), changes nothing. `GROK_MAX_CONCURRENT_SUBAGENTS=4` and no `--no-subagents` only when the task JSON says `"subagents": true` | JSON `text`, `sessionId`, `modelUsage`, `usage`, `stopReason` (verified on 1.0.70, §1.3; `text` joins every turn's message, so with `--json-schema` the answer is `structuredOutput` as JSON; when grok gives none, `text` stays the answer, with a note that it is not the structured one); any `permission required:` on stderr → denied; rc 1 with an error object and no `sessionId` → 2; `You are not authenticated` → 11; `rate.?limit\|quota\|\b429\b` → 10; a stderr line saying the sandbox was not applied → 2 (when grok went on anyway, the reason says it ran unconfined). Served: every `modelUsage` key is the model or the model plus a suffix of the explicit alias table (`-build` only: `grok-4.7` serves `grok-4.7-build`; `grok-4.7-build-fast` or another model → 21); `model_served` is the key, with a note when it is the alias. Tokens also from `grok usage <uuid>` (free) |
| agy (raw, default) | `AGY_CLI_DISABLE_AUTO_UPDATE=true`; unset `GEMINI_API_KEY`, `GOOGLE_API_KEY` | `/usage` before (free); `flock` on `$CX_HOME/locks/agy-launch`; registration `(cd "$WT" && <agy> --new-project --output-format json -p /model </dev/null)`; tree snapshot (`git status --porcelain=v1` of the main checkout and every other worktree, through each worktree's git directory as the repository's admin files name it, never a worktree's own `.git`, with no fsmonitor, hooks, textconv or submodules; plus each worktree's `.git` link hash); `(cd "$WT" && exec setsid timeout --kill-after=15s <T+5m> <agy> --model <slug> --add-dir "$WT" --settings "$OUT/agy-settings.json" --print-timeout <T> --output-format stream-json --disable-slash-commands -p "$P" </dev/null) > agy.ndjson 2> agy.err &`, where `agy-settings.json` (written before the slot, session-only) is `{"permissions": {"allow": ["write_file(<WT>)", "command(cx-route)", "command(git status)", "command(ls)"]}}` (never `--dangerously-skip-permissions`, never a global grant; never `command(git diff|log|show)`: a token-prefix rule would also allow their `--output=<path>` and `diff --no-index`, a write and a read anywhere, and agy has no filesystem sandbox) and `$P` is the agy prompt (read with agy's own file tools; any other command ends the run); the new session id is appended to `$CX_JOB_DIR/sids` | Wait ≤ 120 s for the `init` event: `init.model` ≠ slug → kill, 21; release the launch lock after `init`; SIGKILL the process group 5 s after the `result` event (#1313); snapshot again: any change outside `$WT` → 22 and `touch $CX_HOME/state/agy-paused` (agy dispatch stops until a human runs `cx-job unpause agy`; the main checkout is never auto-reset); `subagent_info` or a non-Opus model in events → 2 (`subagent`); `denied_actions` (each named after the tool step it stopped: `run_command`'s `tool_info.parameters.CommandLine` in `denied[].command` and `CX_DENIED.commands`) / permission `finished_reason` → 15; expired print timeout → 27; `/usage` after → `cost.quota_delta`. `agy_claude_floor_pct` > 0 and the bucket below it → lane ineligible |
| agy (wrapper) | as above plus `AGY_USAGE_LOG=$CX_HOME/raw-usage.log`; PATH shim set without `agy` | registration as above, then `<agy_delegate> --model <slug> --dir "$WT" --timeout <T> --digest "$P"` | `model_served: null` plus the note `agy wrapper: AGY_USAGE.model echoes the request; served model unverified` (§1.4); such a run never counts as G6-verified and never yields 21; agy-delegate exits pass through |
| claude | — | Default: no process; stdout `{"dispatch": "claude-subagent", "id", "worktree", "host_path", "prompt", "effort", "task_file"}`, then `cx-run --finish <id>`. `--headless`: `cd "$WT" && <claude> -p --model claude-opus-5-5 --effort <E> --output-format json --session-id <uuid> --permission-mode acceptEdits --settings "$OUT/cx-worker.json" "$P"` | JSON `result`, `session_id`, `usage`, `modelUsage` [assumption; pin with a capture]. `cx-worker.json` (from `templates/cx-worker.json`) allows `Bash(cx-route:*)`, `Bash(git status)` and `Bash(<cmd>)` per routes command and denies `Bash(claude:*)`, `Bash(copilot:*)`, `Bash(grok:*)`, `Bash(agy:*)`, every `Bash(ghcp-<x>:*)`, `Bash(agy-<x>:*)`, `Bash(cx-<x>:*)`. `--safe-mode` is added only after §20 item 18 passes |

Gemini lanes (digest, research, Argon review) always register the directory first and call
`agy-delegate --model '<label>' --dir <dir> --timeout 30m --digest`.

**The built interface (§15 build order item 2; what `cx-run` and `cx-job` call).** Every adapter
is `scripts/adapters/<lane>.sh ACTION [OPTIONS]` (lanes `copilot`, `grok`, `agy`, `claude`,
`copilot-cloud`; shared code in the sourced `scripts/lib/adapter.sh`), run from the runtime copy
(§7.5), never from PATH. Options: `--out DIR` (`$CX_HOME/out/<id>`; its basename is the id unless
`--id`), `--wt DIR` (the worktree, or the gate checkout in read/review mode), `--model M`,
`--effort E`, `--mode write|read|review`, `--timeout SECS` (or `30m`; default option
`default_timeout`), `--allow CMD` (repeatable: the routes commands), `--prompt TEXT` (default the
§6.4 fixed prompt), `--repo DIR` (the task's main checkout: kept in agy snapshots even under
`.claude/worktrees`), `--base SHA`, `--task-file F`, `--no-wait` (slot wait 0), `--refresh`
(skip the probe cache), `--dry-run` (argv only); per lane `--fusion standard|max` and `--add-dir
DIR` (copilot; read/review pass `--add-dir "$OUT"`), `--json-schema S` and `--subagents` (grok),
`--agy-mode raw|wrapper` and `--add-dir DIR` (agy), `--headless` (claude), `--gh-repo
HOST/OWNER/REPO` and `--base-branch B` (copilot-cloud).
- `probe`: the JSON above plus `paused`, `wrapper`, `model`, `detail`; free (§3.7). The flag
  contract (§5.4) per lane: grok `grok --help` for the argv; agy `agy --help` for the raw argv
  plus `--new-project`, `--output-format`, `-p` (wrapper: `agy-delegate --help` for its argv);
  copilot `ghcp-delegate --help` for its argv, `copilot --help` for the argv
  `ghcp-delegate --print-command` builds (with `--dir` the probe directory), `copilot help
  permissions` for `shell(` (and `write(` in write mode); claude `--headless` `claude --help`;
  copilot-cloud `ghcp-cloud --help`. The probe builds the argv itself when it runs alone (cx-run's
  preflight, before the worktree exists). Copilot's login and catalog come from `ghcp-models
  --json` on every version. Only a green probe (binary, flag contract, login, model all fine,
  agy not paused) is cached, for 10 minutes in `$CX_HOME/state/preflight.json` (`cached: true`),
  keyed by lane, variant, binaries (resolved path, mtime and size), model, mode and the argv's
  flags.
- `argv`: writes `<lane>.argv`, `<lane>.env` and `<lane>.meta.json` (what was requested: lane,
  executor, pool, variant, model, effort, mode, timeout, worktree and its `host_path`, prompt,
  allow, session uuid for grok/claude, the claude dispatch); `--dry-run` writes nothing and
  prints `lane:`, `model:`, `effort:`, `mode:`, `argv:` (`printf %q`), `env set:`, `env unset:`,
  `cwd:`, `worktree:`, `slot:` lines (copilot adds ghcp-delegate's `--print-command` line, the
  cloud lane the rendered task).
- `run`: builds argv when its files are missing (else they win: the meta's timeout, prompt,
  worktree and model are restored); the preflight from the probe: 13 `CLI_MISSING`, 26
  `VERSION_MISMATCH` (the flag contract, before any executor call, A9), 28 for a paused agy, 11,
  14; `lane_prepare` (grok, every mode: no per-project `.grok/sandbox.toml`, the repository's
  sandbox profile, the per-run profile check; agy raw: `agy-settings.json`), whose refusal, like
  any stop before the executor, leaves its reason in `$OUT/adapter.why` (cx-run appends it to
  the result's reason); the
  `running` mark `$OUT/running` (write mode; kept for the claude dispatch until `--finish`);
  the pool slot (`cx_lock_acquire`, an inherited one reused; 28 at cap); then the lane's
  executor under `setsid timeout --kill-after=30s <limit>` in the worker environment, with a
  keeper subshell that owns it (so no shell job notice reaches stderr) and its session id in
  `<lane>.sid` and `$CX_JOB_DIR/sids`; INT/TERM/HUP kill that session (TERM, KILL after 10 s;
  agy KILL at once) and exit 130, also while still queued for the slot (the `queued` marker is
  removed). Writes `<lane>.out`, `<lane>.err`, `rc` (atomically) and `<lane>.run.json` (`rc`,
  times, `sid`, `cancelled`, `timed_out`, `slot`, `cli_version`, and for agy `register_rc`,
  `init_model`, `init_timeout`, `mismatch_killed`, `killed_after_result`, `tree_changed`).
  Exit 0 whenever the executor ran, whatever its own status.
- `parse --out DIR`: `normalize.py parse`, reading the files above plus an optional
  `$OUT/checks.json` that `cx-run` writes first (`spec_ok`, `diff`, `diffstat`, `commit`,
  `branch`, `base`, `gate`, `batch`, `cancelled`, `timed_out`); writes `result.json` and
  `answer.txt`; prints `<exit> <status>` and exits 0 (1 for an unknown lane).
- Then `normalize.py emit --out DIR` prints `CX_DENIED`, `CX_NOTE` and `CX_RESULT` (stderr),
  `normalize.py report --out DIR` the digest, the `VERIFY THIS:` line and the diffstat (stdout),
  `ledger.py append --ledger <ledger_path> DIR/result.json` the ledger line; the caller prints the
  run's one `CX_SIGNAL`.
- Signals: every adapter exit outside {0, 1} prints one `CX_SIGNAL` (`cmd: adapter`) unless
  `CX_SIGNAL_OWNER` is set, which `cx-run` sets so that its own signal stays the only one.
- `copilot-cloud.sh fetch --out DIR --repo TOP --pr N --gh-repo HOST/OWNER/REPO` fetches
  `pull/N/head` from the task's repository (the remote of `TOP` whose URL names it, else
  `https://HOST/OWNER/REPO.git`; never a fork's `origin` by default), requires `gh pr view N -R
  <repo> --json headRefOid` to name the fetched commit (else exit 2, nothing gated), and prints
  the commit for the gate checkout (also `$OUT/copilot-cloud.head`).
- Process hygiene (every adapter): the executor's keeper subshell records the session id before
  anything else (`$OUT/<lane>.sid`, `$CX_JOB_DIR/sids`), closes the slot, agy and launch lock
  descriptors (only the adapter holds them) and exports the Copilot token into the environment
  (never an argument of `env` or `timeout`, whose argv is world-readable); a signal during the
  start waits up to 5 s for the session id and then stops that session; after a cancellation
  the adapter polls and sends KILL to the whole session after `CX_KILL_GRACE_SECS` (10) s and once
  more at the end; after every run it kills what is left of the executor's session.
- Lane specifics as built: copilot runs `ghcp-delegate` (a background run is `cx-job` around
  `cx-run`, not `ghcp-job`), sets `COPILOT_HOME` to the recorded value (unset when none) and reads
  the token file at run time only (never into `copilot.env`); grok writes the prompt file into
  `<WT>/.conductor/` in every mode and runs `grok usage <uuid>` afterwards; agy raw holds the
  launch lock from `/usage` through registration to the `init` event (the child is started with
  the launch descriptor closed), agy wrapper holds it for the whole call, and both snapshot the
  other worktrees and pause on a change; the claude dispatch and the cloud lane take no pool slot
  (no local executor process); `max` is refused everywhere but the claude lane, `xhigh` on
  Copilot without `copilot_xhigh_ok` and on agy.

### 15.3 Locks (`scripts/lib/locks.sh`; built, §15 build order item 1)

`cx_lock_acquire POOL CAP [WAIT_SECS]`: try `flock -n` on `$CX_HOME/locks/<POOL>.<n>` for n in
1..CAP, holding the descriptor for the life of the run (children inherit it; a killed process
group releases it); poll every 2 s up to WAIT_SECS; rc 0 with the slot number, or 28. Pools:
`agy` (`cap_agy`), `copilot` (`cap_copilot`), `grok` (`cap_grok`). The agy launch lock is
separate and held only from launch to the `init` event by `cx-run`'s raw agy lane; a
hand-dispatched agy run (`cx-wsl agy*`) cannot see that event and holds it for its whole call.
Only the holder keeps the descriptors: an adapter closes the slot, the agy shared lock and the
launch lock in the executor's keeper, so nothing the executor leaves behind can hold a slot, and
it kills the executor's session after the run; `cx-wsl`, which `exec`s the tool, hands its
descriptors to the tool on purpose.

Library contract (sourced, never run; it sources `common.sh` and `options.sh`; the acquiring
functions `cx_lock_acquire`, `cx_lock_try`, `cx_lock_launch` and `cx_slot_take` must run in the
caller's shell, never in `$(…)` or a pipeline, or the descriptor closes with the subshell; rc 0
ok, 28 no capacity, 2 unusable lock directory or unknown pool):

| Function | Contract |
|---|---|
| `cx_lock_acquire POOL CAP [WAIT_SECS]` | Sets `CX_SLOT_POOL`, `CX_SLOT_N` (1..CAP), `CX_SLOT_FD`, `CX_SLOT_FILE`; `CX_SLOT_WHY` on 28/2. WAIT_SECS defaults to `cx_lock_wait_secs`; CAP 0 → 28 at once ("disabled"). For `agy` it first takes `$CX_HOME/locks/agy` **shared** (`flock -s`), the Phase 1 skill's whole-run lock, which an older skill copy's step still takes exclusively, so the two never overlap while both copies are in use. One `<prog>: … waiting up to N s` note when it has to wait; while it waits and `CX_JOB_DIR` is a directory, `$CX_JOB_DIR/queued` holds the pool name (cx-job's `queued` status). `flock` missing → one note, rc 0, `CX_SLOT_N=0` (unguarded; D2 reports it) |
| `cx_lock_try POOL CAP` | The same with WAIT_SECS 0 (`cx-run --no-wait`, `--exec auto` probing each lane in order) |
| `cx_lock_release` | Closes the slot and the agy shared lock it took |
| `cx_lock_launch [WAIT_SECS]` | `flock -w` on `$CX_HOME/locks/agy-launch`; sets `CX_LAUNCH_FD`; rc 0 or 28 |
| `cx_lock_launch_release` | Closes it (`cx-run`'s raw agy lane, right after the `init` event) |
| `cx_lock_cap POOL` | Prints `cap_<pool>` from the options, validated (§5.3), loaded in a subshell so no `CLAUDE_PLUGIN_OPTION_*` leaks into the caller's environment and the sibling wrappers it runs |
| `cx_lock_wait_secs` | Prints `CX_SLOT_WAIT_SECS` (an integer of seconds, 0 = no wait) or 600; an invalid value prints one note |
| `cx_slot_take POOL [WAIT_SECS]` | For `cx-wsl` (and build item 1's interim slot line): the cap from the options, the slot, and for `agy` the launch lock too (for the whole call); on failure one note and one `CX_SIGNAL` (`NO_CAPACITY` 28, or `FAILED` 2), printed from a subshell so it returns the code instead of exiting |

Lock order everywhere: `agy` (shared), then the slot, then `agy-launch`, so no two holders wait
on each other. Nesting: every lock taken is recorded in the exported `CX_SLOT_FDS`
(`NAME=FD …`); a process that inherited such a descriptor (its `/proc/<pid>/fd/<FD>` names the
lock file) reuses the slot instead of waiting for a second one, so `cx-job`'s runner, `cx-run`
inside it and a step that already holds an agy slot never deadlock on their own slot. The lock
files live in `$CX_HOME/locks` (mode 0700, created on first use); a forwarded call's WSL side
uses the WSL user's `$CX_HOME`, so Git Bash and WSL callers share one set. Build item 1's interim
slot line for the skill's hand-dispatched agy steps (`CXB=$(command -v cx-wsl); source
"${CXB%/bin/cx-wsl}/scripts/lib/locks.sh" && cx_slot_take agy || exit $?`) is gone from §12.2
since build item 2 (kept in the git history; P43 checks the library contract still holds): no
hand step runs agy, and the two remaining hand executor calls run through `cx-wsl`.

`locks.sh` is the cross-process semaphore of every executor path on the executor host (§15
build order, item 1): `cx-run` takes the slot before the adapter starts; `cx-job`'s detached
runner takes it inside the job, so `cx-job start` and `cx-run --background` return `JOB_ID` at
once and the job shows `queued` until it gets a slot (`cx-job wait` exits 75 for queued and
running jobs); `cx-wsl` takes the same slot for its executor calls of `ghcp-*`, `agy*` and
`grok` before it `exec`s the tool (§7.7 lists the free forms that take none; `gh`, `git` and
`bash` are unchanged), waiting `CX_SLOT_WAIT_SECS` (default 600) and then exiting 28; the
skill's two hand executor calls (`cx-wsl grok`, `cx-wsl ghcp-ci-debug`) take it through `cx-wsl`. With `cap_agy` 2 and
`cap_copilot` 3, ten workflow runners or five Work locally threads still run at most five Opus
executors; the rest queue, then fall to the Claude pool on 28. D32 prints the slot caps next to
the workflow concurrency (built). These slots replace the Phase 1 skill's whole-run agy lock
(`$HOME/.conductor/locks/agy`, §12.2 step 2a); while Phase 1 steps (an older skill copy that a
running session still holds) and Phase 2 runs coexist, `cx_lock_acquire agy` also takes that
file, shared (`flock -s` on it before the slot, within the same wait), so a Phase 1 step, which
takes it exclusively, never overlaps a slot holder, while slot holders do not exclude each
other. The skill's Copilot and Grok hand steps (the commit-message Grok call, `ghcp-ci-debug`)
run through `cx-wsl` in WSL as from Windows (built in item 2), so they take the same slots as
`cx-run`; every other executor run is a `cx-run`.

### 15.4 `result.json` and the ledger

`$OUT/result.json`:

```json
{"version": 1, "ts": "2026-11-05T10:00:00Z", "id": "fan-3", "batch": null, "lane": "agy-opus",
 "host": "wsl", "caller": "gitbash", "executor": "agy", "cli_version": "1.4.12",
 "pool": "google-claude-bucket", "mode": "write",
 "model_requested": "claude-opus-5-5-high", "model_served": "claude-opus-5-5-high",
 "effort_requested": "high", "effort_applied": "high", "exit": 0, "status": "ok",
 "finished_reason": null, "session": "…",
 "usage": {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "reasoning": 0},
 "cost": {"ai_credits": null, "usd_est": null, "quota_delta": null, "estimated": false},
 "denied": [], "worktree": {"path": "…", "host_path": "…"}, "branch": "cx/fan-3", "base": "<sha>",
 "commit": null, "diffstat": "+212 -40, 7 files", "gate": null,
 "digest": {"path": "…/answer.txt", "host_path": "…"}, "duration_s": 512,
 "raw": {"stdout": "…", "stderr": "…"}, "notes": []}
```

As built (item 2) result.json also carries `reason` (the classification's reason, sanitized,
or null), `models_seen` (every model the executor named), `claude_session`
(`CLAUDE_CODE_SESSION_ID`) and `claude_effort` (`CLAUDE_EFFORT`), and when they apply
`dispatch` (the claude lane), `cloud` (`{state, task, pr, pr_url, urls, repo, base}`), `fusion`
(ghcp's `GHCP_USAGE.fusion`) and `fallback` (`GHCP_FALLBACK`). `denied` is a list of
`{kind, detail}` (`write`, `shell`, `url`, `mcp`, `other`); an agy denial also has `action`
(agy's), `tool` (the tool step it stopped) and, for a command, `command` (its command line,
also `detail`); `cost.quota_delta` is the
percentage points per `/usage` bucket (agy raw). `CX_RESULT` is result.json without `raw`,
`notes` and `models_seen`, plus `path` and `host_path`.

Pools: `google-claude-bucket`, `google-gemini`, `copilot-credits`, `xai-weekly`, `claude-plan`.
The ledger (`ledger_path`) gets one line per run: result.json without `raw` and `notes`.
`ledger.py append FILE` (under `flock "<ledger>.lock"`, then `fsync`), `ledger.py month --pool P
[--month YYYY-MM]` (sum of `cost.ai_credits`, booked review estimates included), `ledger.py tail
[-n N]`. The ledger is append-only and never rewritten.

### 15.5 `cx-job`

```
cx-job start [cx-run args…]       # stdout: JOB_ID <id>; returns at once
cx-job status <id>                # running | done rc=N | failed rc=N | cancelled | unknown
cx-job wait <id> [--timeout DUR]  # blocks; then like result; exit = job rc, or 75 on expiry
cx-job result <id>                # stdout digest, then the job's CX_* lines; exit = job rc; 75 while running
cx-job kill <id>
cx-job list [--all]
cx-job unpause agy
```

- Registry `$CX_HOME/jobs/<id>/{meta,pid,pid_start,sids,out,err,rc}`; id
  `YYYYmmdd-HHMMSS-<4 hex>`, abbreviable by unique prefix; every call site uses
  `jd="$(jobdir "$id")" || exit 1` (ghcp's lesson). A task id (`--id X` or `--id=X` in a job's
  stored arguments, before the task text) is never taken for a job: one that names no job
  still exits 1, with the note "X is the task id of job <JOB_ID>; cx-job takes the JOB_ID that
  cx-run --background printed" when exactly one job has it; a prefix of one JOB_ID that is also
  another job's task id (cx-run takes ids of digits alone, such as `20261106`) is ambiguous,
  exit 1, and nothing acts on either job. A full JOB_ID always names its own job.
- start: preflight with `cx-run --dry-run <args>` (exit 1 → refuse), then
  `setsid nohup bash "$RT/scripts/cx-job.sh" __runner "$jd" <args> </dev/null >/dev/null 2>&1 &`.
  The runner is a session and process-group leader: it records `$$` (pid = pgid = sid) and its
  `/proc/<pid>/stat` start time, exports `CX_JOB_DIR`, runs `timeout --kill-after=30s
  <limit + 2m> bash "$RT/scripts/cx-run.sh" <args>` with output to `out`/`err`, and writes `rc`
  atomically (`rc.tmp` → `rc`) unless `rc` exists.
- kill: signal only a pid proven to be the runner (start time matches, else `ps` shows
  `cx-job.sh __runner <jd>`); write `rc` 130 first; `kill -TERM -- -<pgid>`, `pkill -TERM -s
  <sid>`, and the same for every sid in `sids` (adapters that `setsid` their executor leave the
  runner's session, so they record it there); poll up to 10 s; then the same with KILL. Never
  rely on killing `wsl.exe` or a docker client; agy ignores TERM (#1313), so only KILL ends it.
- As built: `start` reads a task given as `-` from stdin into the job's argv and stores every
  task text after `--` (the job's `cx-run` never parses it as an option), preflights with
  `cx-run --dry-run` (also for `--finish`, which has a dry run of its own: exit 1 or 42 → refuse,
  start nothing; a taken id, a `cx/<id>` branch, a running task and an unmappable path are
  refused there), and launches the runner from the runtime copy
  (`cx_runtime_ensure`); the runner reads its argv from `$jd/argv` (NUL-separated, so prompts
  never show in `ps`), and its wall clock is the run's timeout + `default_timeout` (setup) +
  `CX_SLOT_WAIT_SECS` + 7 minutes (agy's grace and 2 minutes). `rc` is written with a hard link
  (`ln rc.tmp rc`), so a kill's 130 is never overwritten. `status`: `queued` while
  `$jd/queued` exists (the slot wait, or `--exec auto` polling), `unknown` when the runner is
  gone without an `rc`; a runner is proven by `/proc/<pid>/stat` field 22 (else `ps` shows
  `cx-job.sh __runner <jd>`); an executor session in `sids` is signalled only while one of its
  processes carries `CX_JOB_DIR=<jd>` in its environment (pid-reuse guard for sessions too).
  `result` prints the job's stdout, a note naming the full log, the job's `CX_*` lines and
  exits with the job's rc; the job's last `CX_SIGNAL` is relayed only when it names that rc,
  else one is printed for it (124/137 → `TIMEOUT` 12, 130 → `CANCELLED`); rc 1 (the job's
  `cx-run` refused the request) prints the job's notes and no `CX_SIGNAL`. `list` shows queued, running and the last 24 hours' jobs (`--all`: every job).
  `unpause agy` removes `$CX_HOME/state/agy-paused` and prints what it held. Forwarded from
  Git Bash, `start` prints a note that one background `cx-job wait` keeps WSL running.
- Waiting: Claude runs `cx-job wait <id>` as one background Bash call (`run_in_background`),
  which notifies on exit; never by re-checking across turns (the Phase 1 equivalent for the
  sibling job tools is the wait one-liner of §12.2). From Git Bash that forwarded `wsl.exe … cx-job wait`
  also keeps WSL alive. If L1 shows detached jobs die when no `wsl.exe` runs, `cx-job start`
  forwarded from Git Bash prints a note that a background `cx-job wait` must stay running for
  every job, and `.wslconfig` idle settings are tested [docs-only].

### 15.6 Worker environment

Every executor run: `CX_WORKER=1`; `PATH="<shim dir>:$CX_HOME/routes/<id>:<host record path>"`
(that directory holds the run's `cx-route`, §15.1; the shims stay first); executors by absolute
path;
`COPILOT_AUTO_UPDATE=false`, `GROK_DISABLE_AUTOUPDATER=1`, `AGY_CLI_DISABLE_AUTO_UPDATE=true`
(a CLI never replaces itself mid-run; outside the runs auto-update is the user's choice, §5.4),
`NO_COLOR=1`, `PYTHONDONTWRITEBYTECODE=1` (Python checks would leave `__pycache__` in the
worktree; the 2026-11-06 probes, decision 7); grok also `GIT_CONFIG_GLOBAL=/dev/null`;
`ANTHROPIC_API_KEY`, `XAI_API_KEY`,
`GEMINI_API_KEY`, `GOOGLE_API_KEY` unset (they would bill APIs instead of subscriptions); cwd
`$WT` or the gate checkout. Shim dir = the full set, except the agy wrapper lane (set without
`agy`). Doctor check D29 (Phase 2, free): `PATH="$RT/worker-shims:$PATH" <abs cli> --version`
succeeds for copilot, grok and agy (a CLI that re-execs itself by name would hit its shim)
[unverified].

### 15.7 `cx-init --user-grants` and the grok sandbox profiles

0.2.1 (the 2026-11-06 probes, decisions 3 and 4): agy needs no user-level grant (each raw run
passes its own `--settings`, §15.2), and grok writers run under their repository's own sandbox
profile, so `--user-grants` only writes that profile ahead of the repository's first grok run.
0.2.2: every conductor grok run, read and review included, runs under that profile (0.2.1 ran
those under the built-in `read-only`, which lets grok write `~/.grok/bin`, `vendor/` and
`installed-plugins/`, §1.3).

- **The profile.** `cx-<repo>-<8 hex>`: `<repo>` the main checkout's directory name (lower-case,
  `[a-z0-9-]`, at most 24 characters), the hex the start of the sha256 of the repository's git
  common directory (resolved). Its block in `~/.grok/sandbox.toml` (`${GROK_HOME:-~/.grok}`),
  rendered from `templates/grok-sandbox.toml` between `# cx:begin <name>` and `# cx:end <name>`:
  `extends = "strict"`, `read_only = ["<git common dir>", "<$CX_HOME/routes>"]` (git status in a
  worktree or a gate checkout; each run's `cx-route`, never the out directories). It writes only
  the run's checkout, `~/.grok/sessions`, `/tmp` and `/var/tmp` (the sandbox log of every start,
  §1.3). Written by the grok lane before the slot in every mode (`cxlib.py grok-profile`, under
  `flock` on `$CX_HOME/locks/grok-sandbox.lock`) when missing or different, again once the run
  holds its slot (only the moment before grok reads it at startup stays open), and by `cx-init
  --user-grants`; the block is rewritten between its markers, and, since the name is
  conductor's own (no person writes it), any other `[profiles.<name>]` table (or sub-table) is
  replaced too; a definition left another way (dotted keys, an inline table) is a conflict (the
  parsed profile must equal the rendered one), which refuses the run; the file is first copied
  to `sandbox.toml.cx-bak`, written atomically (through a symlinked dotfile to its target) with
  its own mode, and a result that would not parse (tomllib, Python 3.11 and newer) is a
  conflict: nothing is written. Both writers remove the exact block conductor 0.2.0 appended
  (the `cx-workspace` profile with glob deny paths, which grok's literal `deny` cannot take).
  What the rewrite guards: no conductor grok run can change `sandbox.toml` (grok write-denies it
  under `read-only` and `strict`, measured, §1.3; 0.2.1 said the built-in `read-only` could),
  so it guards against everything else that can: the user's own grok sessions without a sandbox
  (grok's default) or under `devbox`, other tools, and code planted where 0.2.1's `read-only`
  runs could write (grok's binary, its ripgrep, its plugins), which runs outside any sandbox.
- **The per-run check** (§15.2 grok) confirms, from grok's own sandbox log, that the profile a
  run is about to use is enforced and grants no write into grok's home but `~/.grok/sessions`;
  it runs for the repository's profile and for a profile of the user's own alike.
- **Option `grok_sandbox_profile`**: `auto` (default; the 0.2.0 default `cx-workspace` counts as
  `auto`) uses the repository's profile; any other value names a profile of the user's own,
  used as it is for every mode, write, read and review (one boundary per repository; a read or
  review reads executor-written code, so it gets no weaker profile than the writers). It must
  let grok read the git common directory and `$CX_HOME/routes`, and must not let grok write its
  home: the per-run check refuses a run whose profile's logged grants do, and a built-in that
  writes `~/.grok` (`off`, `devbox`, `workspace`, `read-only`) is always refused. Outside a git
  checkout the lane uses the built-in `strict`.
- **`cx-init --user-grants [--dir D] [--dry-run] [--json]`** (`cxlib.py user-grants`): the
  profile of the repository at `--dir` (default the cwd); `update`/`create`/`same`/`CONFLICT`
  lines or `--json`, notes on stderr and one `CX_INIT` line with `detected: {user_grants,
  commands, worktree_root, grok_profile}`; exit 0 or 5 (`EXISTS`). It never writes agy's
  `~/.gemini/antigravity-cli/settings.json`: a note (and `cx-doctor` D18) names the global
  `write_file(...)` / `command(...)` grants 0.2.0 left there, for the user to remove. It never
  touches grok's `[cli] auto_update` (nothing is pinned, §5.4).

### 15.8 Phase 2 tests

| ID | Case |
|---|---|
| A1 | Adapter argv per lane via `--dry-run`; every emitted flag appears in the captured help (`tests/fixtures/real/<cli>/help.txt`) or the hidden-flag allowlist (grok `--trust` only) |
| A2 | Success per lane with stubs: result.json schema, ledger line, `CX_RESULT`, `VERIFY THIS` line |
| A3 | rc 0 with a denial: Copilot `GHCP_DENIED` write, grok `permission required:`, agy `denied_actions` → 15 |
| A4 | agy result-then-hang (stub ignores TERM after the result event) → killed 5 s after the result; status ok |
| A5 | agy writes into another worktree → 22, `agy-paused` set, the next agy dispatch refused until `cx-job unpause agy` |
| A6 | Copilot #5149 usage file (32k output, empty answer, xhigh) → 2 `copilot#5149` |
| A7 | Quota/rate-limit text per CLI → 10 |
| A8 | `init.model` mismatch, `GHCP_FALLBACK` on a Fusion lane, grok `modelUsage` with another model → 21 |
| A9 | Flag contract (0.2.1): a stub help without a flag the lane emits (grok `--always-approve`, agy `--settings`, Copilot's `shell(` kind) → 26 with no executor invocation; a newer version with the flags runs |
| A10 | grok error object without `sessionId` → 2; `You are not authenticated` → 11 |
| A11 | Parsers on ghcp's real fixtures (`ok-pong`, `denied-write`, `autodenied-shell`, `fusion-max-pong`, copied into `tests/fixtures/real/copilot/`) and on every Phase 0 capture |
| A12 | cx-job lifecycle; kill of a TERM-ignoring stub (TERM, then KILL after 10 s, recorded sids included); rc 130 written before the kill; pid-reuse protection |
| A13 | Caps under parallel `cx-run` with sleeping stubs; `--no-wait` → 28 |
| A14 | Worker env: shims first, `CX_WORKER=1`, scrubbed variables absent from the stub's env dump; the agy-wrapper shim set lacks `agy` |
| A15 | Task hash mismatch → 23; no diff → 3; setup failure → 25 with no executor invocation |
| A16 | Forwarded `cx-run`/`cx-job` from simulated Git Bash: `host_path` fields are Windows paths; a background job outlives the forwarder |
| A17 | `--dry-run`/`--explain` create nothing and call no executor (stub logs show free probes only) |
| A18 | `cx-init --user-grants` merges JSON and TOML idempotently with a backup |

Built: every case but A19–A24 and A29 (the optional item 4, not built). A1, A3–A11 and A14 at
the adapter level (three background sections: probes, argv and lanes; classification, the real
captures, the cloud lane, slots and the ledger; the agy lane): A1 also compares each lane's
`argv --dry-run` with the argv files of the same options, A11 also cross-checks every real
Copilot recording (session id, `totalNanoAiu`, served models) against what the parser made of
ghcp's real output for it, and A14 checks every executor call of each lane against §15.6 (the
four API keys, `CLAUDE_PLUGIN_OPTION_*`, the auto-update switches over a caller's wrong value).
A2, A5, A9, A12, A13, A14, A15, A17, A18, A27, A28 and A30 through `cx-run`/`cx-job` (five
background sections): A2 validates result.json, `CX_RESULT` and the ledger line of every lane
against §15.4; A5 runs the pause end to end and checks that a sibling task's setup is no false
`wrong_tree`; A12 checks that `rc` is 130 before the first TERM lands; A17 audits the stub calls
of dry runs of every lane and mode against the free forms. A25 runs both halves: the `cx-wsl`
half (build item 1) and twelve concurrent `cx-run --background` (six from a WSL terminal, six
forwarded) with `cap_agy=2` and `cap_copilot=3`, measured from the stubs' start/end events
(`STUB_EVENTS`), then the overflow (28). A26 and A30's `cx-wsl ghcp-cloud` run against held
slots. The stub `grok` gained the `nodiff` and `tamper` scenarios for A15.

Phase 2 additions for the session kinds, the shared slots and the optional workflow pieces:

| ID | Case |
|---|---|
| A19 | Gate runner grammar (§15.10): the allowed `cx-run …`/`cx-job wait\|status\|result` forms → 0; `;`, `&&`, `\|`, `>`, `$(…)`, backticks, `$HOME`, a double-quoted argument, a newline, `*`, `--allow`, `--model`, `--fusion`, `--reuse-worktree`, `--headless`, `--effort max`, a free-text task, `-`, `--repo /`, `cx-job kill/start/list`, `cx-doctor`, `bash`, `ls`, `env cx-run …` → 2, each with its reason |
| A20 | Gate attribution: main-session payloads (no `agent_type`) → 0 even for `rm -rf /` text; non-object, empty, no `tool_input`, two `agent_type` keys → 2; `foo:cx-runner` gated, `conductor:cx-runner2` → 0; `_host` blocks the runner only; stderr never echoes the command; a 2,000-payload fuzz exits only 0 or 2; a CRLF copy agrees; no python on simulated Git Bash |
| A21 | Executor guard for `workflow-subagent` and `general-purpose`: `agy-delegate …`, `env -u COPILOT_MODEL CX_WORKER=1 ghcp-delegate …`, `cd /x && grok -p y`, `timeout 60 agy …`, `cx-wsl ghcp-job start …`, `(copilot -p z)` blocked; `grep -r grok src`, `echo agy`, `cx-run --background …`, `cx-wsl bash -c 'npm test'` pass; option `policy` off → everything passes; `ghcp:ghcp-delegate` → 0 |
| A22 | Agents: every Bash-capable `agents/**/*.md` derives its type as Claude Code does (`<plugin>:<subdirs>:<name>`) and the gate blocks a forbidden command for it; `cx-runner.md` frontmatter contract; no `hooks`, `permissionMode`, `mcpServers` or `initialPrompt` |
| A23 | `hooks.json` Phase 2: the first key is `PreToolUse`, `PreToolUse[0]` is matcher `Bash` with exactly `bash "${CLAUDE_PLUGIN_ROOT}/hooks/gate.sh"` and no `onFailure`; P53's entries unchanged |
| A24 | `workflows/opus-pools.js` static contract: pure-literal `meta`, `name` `opus-pools` (no clash with `commands/*.md`), phase titles equal the used `phase` strings, every `agentType` the derived runner type, every runner command `cx-run `/`cx-job `, `SAFE` = `CX_GATE_SAFE`, a `bashCommandClamp` fallback, no `isolation`/`Date.now`/`Math.random`/`import`/`require`, `TO_CLAUDE` as documented |
| A25 | Concurrency: 12 concurrent `cx-run --background` (6 direct, 6 forwarded through the stub `wsl.exe`), sleeping stubs, `cap_agy=2`, `cap_copilot=3`: the caps hold, agy launches never overlap, `queued` then running; `CX_SLOT_WAIT_SECS=2` → overflow ends 28. Build item 1 runs the half without `cx-run`: concurrent `cx-wsl` executor calls (direct and forwarded through the stub `wsl.exe`) against sleeping wrappers share one set of slots, the caps hold, agy calls never overlap (launch lock), overflow ends 28 with one `CX_SIGNAL NO_CAPACITY`, cap 0 → 28 at once, a Phase 1 holder of `locks/agy` blocks agy slots, an inherited slot is reused, free forms take none, the skill's slot line exits 28 while every agy slot is held |
| A26 | `cx-wsl ghcp-delegate` while every copilot slot is held → 28 after `CX_SLOT_WAIT_SECS`; `cx-wsl gh --version` unaffected |
| A27 | `--exec claude` emits the `dispatched` `CX_RESULT`; `--finish` the final one; the `--headless` stub env lacks every scrubbed variable |
| A28 | `cx-run` with its cwd in a `.claude/worktrees/x` checkout and no `--repo` → 1; ledger lines carry `claude_session` and `claude_effort`; the agy adapter snapshot ignores `.claude/worktrees` |
| A29 | D33 (runner and gate wiring) self-test green with the real gate, ✗ with an allow-all copy; D32 Phase 2 ! for `CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL`; D25 lists `Workflow(conductor:opus-pools)` |
| A30 | `copilot-cloud` lane: the stub `gh agent-task` receives the rendered contract; the PR branch is gated like a local lane; the ledger records task and PR; `cx-wsl ghcp-cloud` allowed |

### 15.9 `agents/cx-runner.md` (optional, U8)

Agent type `conductor:cx-runner` (the last segment is the frontmatter `name`). Frontmatter:
`name: cx-runner`, a description that says it is an internal stage runner used only when a
workflow script or the policy names it, `tools: Bash`, `model: haiku`, `effort: low`,
`maxTurns: 40`, `omitClaudeMd: true`; never `hooks`, `permissionMode` or `mcpServers` (ignored
for plugin agents; a test fails if present). Body: run the one `RUN: <command>` line exactly
as written, as one foreground Bash call outside the sandbox, adding nothing (no `cd`, pipes,
redirections, `&&`); if it printed `JOB_ID <id>`, run `cx-job wait <id> --timeout 100s` and
repeat while the exit is 75 (100 s fits the Bash tool's default 2-minute timeout); never sleep,
poll `cx-job status`, kill or background anything; return `exit`, `job`, `result` (the last
`CX_RESULT ` line verbatim), `signal`, `verify`; when the gate blocks a command, return `exit` 1
and `blocked` with its reason and never rephrase it. A runner turn costs a small Haiku context;
the Opus work happens in agy or Copilot. `CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL` and
`CLAUDE_CODE_SUBAGENT_MODEL_FORCE` would override `haiku` (D32 !). The doctor never recommends
denying it; a user who does makes `opus-pools` throw, and the main turn uses the hybrid.

### 15.10 `hooks/gate.sh` (optional, U8; PreToolUse[0], matcher Bash, no `onFailure`)

Ported from ghcp's `validate-delegate-bash.sh`, with `policy.sh`'s conventions: pure bash with
builtins only, every line ending in ` #`, no heredocs or blank lines, `set -o pipefail` without
`-u`, and a final `exit 2` backstop, so the only exits are 0 and 2.
1. Read at most 1 MiB of stdin (`read -r -d '' -n 1048576 -t 5`). Exactly one
   `"agent_type"[[:space:]]*:[[:space:]]*"([^"\\]*)"` match gives the type; no `"agent_type"` key
   plus a `"tool_input"` key is the main session → exit 0; anything else (empty or non-object
   payload, no `tool_input`, two or more `agent_type` keys) blocks everyone (ghcp's C16).
2. Runner (`cx-runner` or any type ending in `:cx-runner`), gated even with option `policy`
   off: exactly one `"command"` string with no JSON escape, no `"_host"` key, and the grammar
   `^(cx-run|cx-job)( +ARG)*$` with `ARG` = `[A-Za-z0-9._/:@=,+%-]+` (`CX_GATE_SAFE`, repeated in
   the workflow) or `'[^']*'`. `cx-job`: only `wait <id> [--timeout <n>(s|m)]`, `status <id>`,
   `result <id>`. `cx-run`: must carry `--background`, `--finish <id>` or `--exec claude`; flags
   only `--exec auto|agy|copilot|grok|claude`, `--mode write|read|review`, `--family
   gemini|gpt`, `--effort low|medium|high|xhigh` (never `max`), `--task-file <absolute .md>`,
   `--id`, `--repo <absolute>`, `--base`, `--timeout`, `--no-wait`, `--dry-run`, `--explain`;
   `--repo`/`--task-file` never `/`, `$HOME` or an ancestor. Phase 3 adds `cx-gate <id>` and
   `cx-fanout --plan <absolute .json> --background` / `--status <batch>`.
3. Executor guard (`workflow-subagent`, `general-purpose`; only while option `policy` is on):
   split on `;`, `&&`, `||`, `|`, `&`, `(`, `)`, newline and `$(`; skip `VAR=value`, `env` (with
   `-u NAME`, `-i`), `command`, `exec`, `nohup`, `setsid`, `time`, `timeout` and its options;
   block when the next word's basename is `agy`, `grok`, `copilot`, a `ghcp-*` or `agy-*`
   wrapper, or `cx-wsl` followed by one ("run executors through cx-run --background (shared pool
   slots), or return EXECUTOR_NEEDED"). It never matches inside arguments and lets a call through
   when it cannot scan: it guards against races, not a security boundary.
4. Every other agent type exits 0, `ghcp:ghcp-delegate` included. A block prints
   `[conductor gate] blocked: <reason>` on stderr and never echoes the command.

### 15.11 `workflows/opus-pools.js` → `/conductor:opus-pools` (optional, U8)

Plain JavaScript, `meta` a pure literal (`name: 'opus-pools'`, phases Dispatch, Claude pool,
Check). `args` is the `cx-fanout` plan object (§16.3) `{batch, repo, base, tasks: [{id,
task_file, effort}]}`, passed as JSON, never as a string; ids match `^[a-z0-9][a-z0-9-]{0,40}$`,
efforts `low|medium|high|xhigh` (max never leaves Claude, §6.3), every value the gate would
refuse throws first. Per task (a `pipeline()`): a runner runs `cx-run --exec auto --mode write
--background --effort E --task-file F --id ID --repo R --base B`; when no included pool
delivered (exits 10–14, 21, 22, 26–28, 43) a Claude-pool agent works in a fresh conductor
worktree (`cx-run --exec claude`, then a runner's `cx-run --finish`), at the task's effort,
never with isolation; then a Claude Check stage runs the contract's acceptance tests read-only.
Codes 15, 20, 23, 24 and 25 return to the main turn. `budget` is checked only before Claude
stages (estimates `CLAUDE_POOL_TOKENS` 150,000 and `CHECK_TOKENS` 40,000 [assumption]) and
never sizes executor fan-out; every task left `unplaced` or `unchecked` is logged; the result
lists job ids, and after a lost runner the main turn runs `cx-job list`. An undocumented
per-spawn `bashCommandClamp: ['Bash(cx-run:*)', 'Bash(cx-job:*)']` is used as defence in depth
with a fallback when this build refuses it, and never appears in model-facing text. The Check
stage is not the independent review (Opus on Opus); Phase 4 adds a Gemini review stage. Phase 3
rewrites it to hand placement, failover and gating to `cx-fanout` and `cx-gate`. A
`Workflow(conductor:opus-pools)` allow rule removes the launch prompt (D25).

## 16. Phase 3: `cx-gate`, conductor commit, `cx-fanout`, integration queue

Sources: plan §6.3 (after every run), §6.6 (dispatch algorithm), §8.3–§8.5 (gates, tamper,
denials), §10 (verdict-parser borrowing), §12.2 (Phase 3 tests).

### 16.1 `cx-gate`

```
cx-gate <worktree> <base> [--id ID] [--task-sha FILE] [--json]   # full gate on the conductor's commit
cx-gate --tamper-only <worktree> <base> [--task-sha FILE]        # staged changes, before the commit
cx-gate --integrated <repo> <branch> [--batch B]                 # integration queue
```

1. C = the worktree's HEAD (≠ base, else exit 1). Fresh checkout
   `git -C <repo> worktree add --detach $CX_HOME/gate/<id>.<n> C` (no untracked files, no
   installed dependencies). Never gate in the worker's tree (agy has patched installed packages to
   pass).
2. routes.json `setup` in the checkout → 25.
3. Tamper (`git diff --name-status --no-renames BASE C`; `--tamper-only` uses the worktree
   index): classes tests (`tests/**`, `test/**`, `**/__tests__/**`, `**/*_test.*`,
   `**/test_*.*`, `**/*.test.*`, `**/*.spec.*`); lockfiles (`package-lock.json`,
   `npm-shrinkwrap.json`, `pnpm-lock.yaml`, `yarn.lock`, `poetry.lock`, `uv.lock`,
   `Pipfile.lock`, `Cargo.lock`, `go.sum`, `Gemfile.lock`, `composer.lock`); CI
   (`.github/workflows/**`, `.gitlab-ci.yml`, `.circleci/**`, `azure-pipelines.yml`,
   `Jenkinsfile`); test-runner config (`jest.config.*`, `vitest.config.*`, `playwright.config.*`,
   `karma.conf.*`, `.mocharc*`, `pytest.ini`, `**/conftest.py`, `tox.ini`, `setup.cfg`,
   `pyproject.toml`, `package.json`, `Makefile`); `.cx/routes.json`; `.gitignore`,
   `.gitattributes`, `.gitmodules`, gitlinks; agent config (`AGENTS.md`, `CLAUDE.md`,
   `.claude/**`, `.github/copilot-instructions.md`, `.github/copilot/**`, `.grok/**`,
   `.gemini/**`, `.cursor/**`); routes `protected`; anything outside the task's
   `allowed_paths` (class `scope`); `.git/hooks/*`, `.git/config`, `.git/info/exclude`
   fingerprints recorded at worktree creation (`$OUT/git.fp`). Exemptions: task JSON
   `"lockfiles": true` (lockfiles), `"tests_writable": true` (tests), or a path listed literally
   (not by glob) in `allowed_paths`. Findings → 24. Task hash mismatch → 23.
4. Diff budget: added + removed lines (`--numstat`; binary files count 0 with a note) ≤ the task's
   budget, else routes `diff_budget` → else 20 (`diff_budget`).
5. Checks: each non-null routes command in the checkout with `bash -o pipefail -c`, under
   `default_timeout`, logged to `$OUT/gate/<name>.log`. `verdict.py` marks a check red when rc ≠
   0, when the output reports failures despite rc 0 (pytest `N failed`/`N error(s)`, jest/vitest
   `Tests: … N failed`, go `--- FAIL`/`FAIL\t`, cargo `test result: FAILED`, mocha `N failing`,
   `npm ERR!`), or when the command text is masked (`|| true`, `|| :`, `; true`, `|| exit 0`,
   `set +e`), reported as `masked_command`. (Idea borrowed from TokenEconomizer's
   `loopguard/turn.py`; no code copied.)
6. Mutation (routes `mutation`): the last `(\d+(\.\d+)?)%` in the output below `threshold` → 20.
7. Bench (task JSON `"bench": true` and routes `bench`): before on a BASE checkout and after on C,
   same host; red only when the task sets `bench_max_regression_pct` and it is exceeded.
8. `$OUT/gate.json` and `CX_GATE {"id", "commit", "verdict": "green|red", "checks": [{"name",
   "rc", "verdict", "summary"}], "tamper": [{"path", "class"}], "diff": {"added", "removed",
   "files"}, "report", "host_report"}`. Exit 0, 12, 20, 23, 24 or 25. The checkout is removed on
   green and kept (path in the report) on red.

### 16.2 Conductor commit (`worktree.sh commit <id>`)

Run by `cx-run` after the adapter and by `cx-run --finish`: task hash (23) → when HEAD ≠ BASE,
`git reset -q --soft BASE` (executor commits are squashed; their messages are discarded) → `git
add -A` (`.conductor/` is excluded) → `cx-gate --tamper-only` (24: no commit, status `tampered`)
→ `git commit -q -m "cx/<id>: <lane>/<model_served>" -m "Cx-Executor: <executor> <cli_version>"
-m "Cx-Task-Sha: <sha>"` with the user's git identity → `commit` in result.json → `cx-gate`
(Phase 3 default; `--no-gate` skips it). Nothing staged → 3.

### 16.3 `cx-fanout`

```
cx-fanout --plan plan.json [--background | --wait] [--dry-run] [--integrate] [--land --reviewed]
cx-fanout --status <batch>
```

`plan.json` (Claude writes the decomposition):

```json
{"batch": "b1", "repo": "/home/me/repo", "base": "HEAD",
 "tasks": [{"id": "t1", "task_file": "/abs/t1.md", "class": "opus", "effort": "high",
            "files": ["src/a/**"], "depends_on": []}]}
```

1. Validate: ids unique (`^[a-z0-9][a-z0-9-]{0,40}$`); task files carry the line-1 JSON; `files`
   globs pairwise disjoint (conservative: two globs overlap when their literal prefixes up to the
   first wildcard are equal or one is a prefix of the other; overlap → exit 1 naming the pair).
2. Classify: `claude` (architecture, xhigh/max) → unplaced at once; `mechanical` → grok;
   `opus` → Opus lanes at the task's effort (§6.3).
3. Free preflights once per lane.
4. Per placed task: worktree, render, `setup` (25 is reported, not charged, not moved to another
   lane).
5. Fill pools in `opus_lane_order` up to the caps. Copilot is skipped only while
   `copilot_reserve_pct` > 0 and the month-to-date figure plus the ledger month sum reaches
   (100 − pct) % of 20,000 credits; with the default 0 it never is. Opus tasks that do not fit
   are unplaced (worktree already rendered).
6. Run each through `cx-job`; on completion: hash check, conductor commit, `cx-gate`.
7. Failover on 10, 11, 12, 14, 21, 22, 26: `git -C "$WT" reset -q --hard "$BASE" && git -C "$WT"
   clean -ffdxq -e /.conductor/`, re-render, next lane (the Opus chain ends at `claude` →
   unplaced); `CX_FAILOVER` per hop; one lane writes a worktree at a time. 15 and 20 are not
   failed over: the task returns to Claude with its report (a missing grant or a wrong solution
   is not fixed by switching pools).
8. stdout: `{"batch", "placed": [{"id", "lane", "job"}], "unplaced": [{"id", "worktree",
   "host_path", "prompt", "effort", "task_file"}]}` at once with `--background`; with `--wait`
   also one row per task (id, lane, model_served, status, gate, diffstat, digest path). Claude
   reads digests and diffs, never transcripts.
9. Exit 0 when every placed task ended green (unplaced tasks are not failures), 20 when any is
   red, 2 on internal errors.

### 16.4 Integration queue

1. Branch `cx/int/<batch>` from BASE in a fresh worktree `<worktree_root>/<repo>-int-<batch>`.
2. For each green task in completion order (respecting `depends_on`): `git merge --no-ff -q
   cx/<id>`; a conflict → `git merge --abort`, mark `conflict` (merge conflicts are Claude's
   lane), continue.
3. After each merge: `cx-gate --integrated` on the merged tree. Red → `git reset -q --hard
   HEAD~1` (k reverted), mark `integration_red`, re-dispatch k once with the failing output
   appended to its task.md as `## Integration failure` (attempt id `<id>.r1`); red again →
   Claude. `CX_QUEUE` per step.
4. A final integrated gate on the tip; report.
5. `--land --reviewed` (U2, no confirmation step): `git push -u origin cx/int/<batch>`,
   `gh pr create --base <default branch> --head cx/int/<batch> --title "<batch>: <summary>"
   --body-file $OUT/pr.md`, `gh pr edit <N> --add-reviewer @copilot` (ledger booking, §17.3).
   Merging into the default branch stays Claude's explicit act after every review finding is
   adjudicated and the final gate is green (`gh pr merge --squash`).

### 16.5 Phase 3 tests

| ID | Case |
|---|---|
| G1 | Toy repos with seeded tampering (edited test, lockfile, CI, routes.json, agent config, `.git/hooks`) → 24 with the right class; literal `allowed_paths` and `lockfiles`/`tests_writable` exemptions |
| G2 | `\|\| true` masking and rc-0 failure outputs for pytest, jest, vitest, go, cargo, mocha → red |
| G3 | task.md edited by the executor → 23 |
| G4 | Failover keeps `.conductor/` (`clean -ffdx -e /.conductor/`) and re-renders; one lane per worktree |
| G5 | Two branches, each green, conflicting semantically → integrated gate red, k reverted and re-dispatched once |
| G6 | Scheduler simulation with sleeping/failing stubs: caps, failover order, unplaced list, exit codes |
| G7 | Diff budget, mutation threshold parsing, bench before/after |
| G8 | Disjointness validator (overlapping and disjoint glob pairs) |
| G9 | `--land`: recorded `gh` calls (push, pr create, add-reviewer), ledger booking |

## 17. Phase 4: live cross-environment, review lane, GitHub

Sources: plan §5 (review and GitHub rows), §6.4 (review cost averages), §7.2–§7.3, §8.7
(cross-family review), §12.2 (Phase 4).

### 17.1 Windows end to end

From the Windows desktop app: forwarded `cx-run`, `cx-job`, `cx-fanout` with `host_path`
results Claude opens directly; job survival per L1; `cx-doctor --windows` green; all from a
`\\wsl.localhost` repo and from a `C:\` repo. Fix whatever L2–L5 revealed (hook command form,
`$PWD` form, safe.directory hint).

### 17.2 Review lane (`cx-run --mode review --family gemini|gpt [--branch cx/<id> | --diff FILE]`)

- A read-only gate checkout of the branch plus `$OUT/change.diff`; prompt R: `Review the change
  in <diff> against the code in this checkout. List findings as file:line - severity - issue,
  most severe first. Do not edit files.`
- Family: routes `review_family` (first glob matching the most changed paths), else by author:
  Opus-written → `gemini` (`review_model_gemini`, Argon); Grok- or Gemini-written → the dispatch
  JSON for Claude's own review; any `high_risk` path → also `gpt` (`review_model_gpt`).
- gemini: register the checkout, `agy-delegate --model '<review_model_gemini>' --dir "$G" --dir
  "$OUT" --timeout 30m --digest "$R"`; gpt: `ghcp-delegate --model <review_model_gpt> --effort
  high --dir "$G" --add-dir "$OUT" --digest "$R"` (each with its §12.2 environment).
- Findings parsed best-effort into `$OUT/review.json` (`[{"file", "line", "severity", "issue",
  "source"}]`); Claude adjudicates every one (accept with a confirmed file:line, reject with a
  reason) in `$OUT/adjudication.md`. A Claude-family reviewer of Claude-written code →
  `CX_NOTE same_family_as_conductor` and not counted as independent.

### 17.3 GitHub

- `cx-run --pr <id>`: push `cx/<id>`, `gh pr create`, `gh pr edit <N> --add-reviewer @copilot`
  (U2: no confirmation). Each requested Copilot review appends a ledger line with `executor:
  "copilot-review"`, pool `copilot-credits`, `cost.ai_credits` = 25 / 150 / 1,000 per routes
  `copilot_review_tier`, `cost.estimated: true` [docs-only averages]. Copilot approvals never
  count as approval in v1; Claude adjudicates its comments like any review.
- `cx-run --mode ci (--run ID | --pr N) [--apply]`: `ghcp-ci-debug --dir <dir> …`; with
  `--apply` the fix branch is made in a conductor worktree (`--dir "$WT"`), never the main
  checkout, and the result goes through the same commit and gate steps.

### 17.4 Two-way fan-out end to end

agy + Copilot on a toy repo through gates and the integration queue, first from WSL, then from
the Windows app.

### 17.5 Live tests (`tests/live/`, opt-in, billed, never run by `run-tests.sh`)

`CX_LIVE=1 bash tests/live/<name>.sh`: `copilot-opus.sh` (~15 credits), `agy-opus.sh`,
`grok.sh`, `fanout-2way.sh`; each saves raw outputs under `tests/fixtures/real/<cli>/<date>/`.

### 17.6 Phase 4 tests

| ID | Case |
|---|---|
| W1 | Recorded `gh` outputs (pr create/edit/view, run list/view) and dry-run `gh api` calls |
| W2 | Review normalization from digest text; family selection from `review_family`/`high_risk`; same-family note |
| W3 | Ledger booking per `copilot_review_tier` |
| W4 | `--mode ci` argv and the worktree-only `--apply` |

## 18. v1.1: Docker

Sources: plan §7.1, §7.4–§7.6, §9 (container hazards), docker-reader notes (DR).

- **Topology** (plan §7.4): `exec_host=docker` or `cx-run --host docker` runs, from WSL,
  `docker compose -f <docker_compose_file> exec -T -e CX_CALLER=wsl -u agent -w /work/<rel>
  <docker_service> bash --noprofile --norc -c 'exec "$HOME/.conductor/runtime/current/bin/cx-run"
  "$@"' cx-run …` (`scripts/host/forward-docker.sh`; the caller travels as `CX_CALLER`, §0.3). `docker compose exec` passes argv as an
  exec vector, so nothing is re-quoted. From Git Bash the chain is Git Bash → WSL forwarder →
  docker. Never `up.sh` for machine calls; `-T` always.
- **Paths**: `/work` = `<cad>/$PROJECT_ROOT` (`PROJECT_ROOT` from `<cad>/.env`); a WSL path P
  under that root R maps to `/work/${P#R/}`; outside R → 42; the reverse uses the same root
  (`$AGENTS_HOST_ROOT` exists only when `up.sh` started the container, so it is not used).
- **Clones, not worktrees**: container workers `git clone -q /work/<repo> /work/.cx-wt/<id>`;
  the host fetches `cx/<id>` from `<root>/.cx-wt/<id>`. `cx-doctor --host docker` refuses repos
  with `worktree.useRelativePaths` or `extensions.relativeWorktrees` while Docker lanes are on
  (the image's bookworm git predates relative worktrees) [docs-only].
- **Shared state**: WSL `~/.conductor` bind-mounted at `/home/agent/.conductor`
  (`CX_HOME_HOST`); host records are per host key already (§7.6); ledger and locks are shared
  (`flock` across the bind mount is [unverified]); container state keyed by
  `COMPOSE_PROJECT_NAME` plus the origin URL (every project mounts at `/work`).
- **Image and compose changes** (in `coding-agents-docker`, no fork of its logic): build args
  `GROK_VERSION: "1.0.70"` and `COPILOT_VERSION: "1.0.105"` (compose.yaml:23 overrides the
  Dockerfile:117 default); Dockerfile `ARG COPILOT_VERSION=1.0.105` and `RUN npm install -g
  --no-fund --no-audit "@github/copilot@${COPILOT_VERSION}" && npm cache clean --force`, plus
  `${HOME}/.copilot` in the `mkdir -p` list (Dockerfile:199-217); environment
  `COPILOT_GITHUB_TOKEN:` (null value: passed only when set on the host; not `${X:-}`, which
  would set an empty string at the top of Copilot's auth order), `COPILOT_AUTO_UPDATE: "false"`,
  `GROK_DISABLE_AUTOUPDATER: "1"`, `AGY_CLI_DISABLE_AUTO_UPDATE: "true"`; volumes
  `copilot-config:/home/agent/.copilot` (external `agents-shared-copilot`) and
  `${CX_HOME_HOST}:/home/agent/.conductor`; `.githubcopilot.com` in `egress/allowlist.conf`;
  SSH `SetEnv` forwards `COPILOT_GITHUB_TOKEN` (Dockerfile:1202-1206); `--hardened`: `GHCP_JOBS`
  and `ANTIGRAVITY_JOBS` under `~/.conductor/jobs/{ghcp,agy}`.
- **Plugins in the container, Claude only**: `claude plugin marketplace add … && claude plugin
  install` for `conductor@`, `ghcp@`, `antigravity@`; sibling `coding_policy` and
  `delegation_nudge` off in the container's `~/.claude/settings.json`; never `PLUGIN_REPOS`
  (it would also install them into grok and codex); after a rebuild rerun `agents-skills-sync &&
  agents-plugins-sync`.
- **Docker-only permissions**: skip-permissions writers only here (agy
  `--dangerously-skip-permissions`, grok `--always-approve` with the profile); repos with
  `docker_only: true` send writers only to Docker lanes.
- **`cx-doctor --host docker`**: compose file readable, service running (`docker compose ps
  --format json`), versions, logins and wrappers inside the container (no silent fallback to raw
  CLIs, except agy Opus raw mode, which is raw by design), `.githubcopilot.com` allowlisted,
  `ghcp-models --json` rc 0 with `COPILOT_GITHUB_TOKEN` absent or empty, and a recorded per-lane
  decision on the ponytail/supermemory/serena hooks and MCP servers that start inside delegated
  runs.
- **Tests [K1…]**: the stub suite through a stubbed `docker` (exec argv fidelity, `/work`
  mapping, refusal outside the root, clone/fetch flow).

## 19. v2 notes

- Cursor: an adapter only for a distinct non-Opus need (Composer 2.5 lanes, Cloud Agents). On
  the X Subscription Opus costs list price, and Cursor's Grok/Composer use the Grok Build weekly
  pool; `-p` hangs, exit codes are unreliable, and it imports `~/.claude` hooks with no opt-out.
- Expiry-aware override (Copilot month end, Grok week end).
- TokenEconomizer: shadow trial; borrow learned timeouts, stream-level loop detection, owned
  reversible settings writes. Never install it into Copilot.
- Cloud threads as an executor host (setup-script installs and a `COPILOT_GITHUB_TOKEN` secret;
  grok and agy device logins in a cloud sandbox are untested); a self-hosted runner inside WSL
  as a Projects environment (`exec_host=local` already marks such a runner as this machine);
  prompt-marker detection of relayed coordinator turns if a UserPromptSubmit hook returns. (The
  Copilot cloud agent lane moved to Phase 2, §15 build order item 3.)
- Image lane (agy `image-generator` once headless is confirmed; Grok `/imagine`; Copilot GPT
  Image).
- A UserPromptSubmit nudge with a `nudge` option.
- `grok agent stdio` (ACP) only if interactive approvals become necessary.

## 20. Unverified register

Each item says how it gets settled; settle it, record the evidence (fixture or note), then
update the § it affects and drop its tag.

| # | Item | Status | Settled by | Affects |
|---|---|---|---|---|
| 1 | `copilot --version` exact text | assumption | Phase 0 capture | D9 (parser takes the first semver anyway) |
| 2 | `claude auth status --json` logged-out shape | assumption | Run with an empty scratch `CLAUDE_CONFIG_DIR` and no token | D15 |
| 3 | `grok models` exit code and logged-in listing | unverified | Phase 0 capture | D17, parse-models |
| 4 | agy `--add-dir`, `--disable-slash-commands`, `--print-timeout`, `--new-project`, `--project`, `--output-format stream-json`, `--settings` on 1.4.12 and 1.5.1 | **verified** 2026-11-02 (`agy --help` 1.4.12 on the user's machine, `tests/fixtures/real/agy/help.txt`) and 2026-11-06 (1.5.1 in the build container, `help-1.5.1.txt`: 1.4.12's plus `--remote-agent` and `acp`). `--settings` (session-only settings JSON) carries the raw lane's per-run grants since 0.2.1, verified by live probes (§1.4); A1 checks the argv against both helps, and the flag contract against the live one before every run (§5.4). `--effort`, `--mode`, `--sandbox`, `--json-schema`, `--input-format stream-json` and `remote-control` stay unused (item 67) | — | §12.2, §15.2 |
| 5 | `agy models --output-format json` shape; `-p /usage` shape and zero cost | docs-only | Phase 0 capture; `/usage` before/after a `/usage` | D18, §8.4 |
| 6 | agy `init.model`, `result`, `denied_actions`, `subagent_info` event shapes | **verified** except `subagent_info`: the real run `tests/fixtures/real/agy/sbx-agy-1/agy.out` (1.4.12) shows `{"event": "init"\|"step_update"\|"result", …}` (§1.4); the parser reads it and names a denied command from its `step_update`. A subagent's own event is still unseen (a `step_update` whose tool name contains `subagent` counts as one) | A run that spawns one | §15.2 |
| 7 | grok JSON fields, `permission required:`, `Bash(<cmd>)` rules, `workspace`/`read-only` profiles, `sandbox.toml` syntax, `GROK_CLAUDE_*_ENABLED`, `GROK_DISABLE_AUTOUPDATER`, `[cli] auto_update` | partly **verified**: the JSON result's keys on 1.0.70 (§1.3: `text`, which joins every turn's message with no separator, `stopReason`, `sessionId`, `usage`, `num_turns`, `total_cost_usd`, `modelUsage`, and `structuredOutput` with `--json-schema`) by the real runs sbx-grok-1, -2 and -3 (2026-11-02, 2026-11-06), and `permission required:` by sbx-grok-1; the built-in profiles, `sandbox.toml` keys (`extends`, `read_only` directories, literal `deny`), `strict` with `--always-approve` and the git-dir `read_only` grant by the 2026-11-06 probes (§1.3). Still docs-only: `GROK_CLAUDE_*_ENABLED`, `GROK_DISABLE_AUTOUPDATER`, `[cli] auto_update` | A grok release note, or a probe per variable | §12.2, §15.2, §15.7 |
| 8 | `--trust` on 1.0.70 | parse-verified on 1.0.73 only | `grok --trust --version` (free) | §15.2 (only if trust is ever needed) |
| 9 | Copilot accepts `claude-opus-5.5 --reasoning-effort high`; cost; #5149 on 1.0.105 | unverified | Copilot paid check #1 (~15 credits); optional xhigh (~200) | `copilot_xhigh_ok` |
| 10 | `--fusion standard` resolves to Standard or High | open | ~0.1-credit check | informational |
| 11 | `WSL_UTF8`, `WSLENV` passthrough, `--cd ~`, `--exec`, exit-status propagation, stdin and Ctrl-C relay | docs-only | L4 | §7.3 |
| 12 | Desktop app: `\\wsl.localhost` projects and `$PWD`; hook shell (the Git Bash policy variant relies on `uname -s` in the hook's shell) | unverified | L2, L3 | §7.3, §10.1, §10.2 |
| 13 | WSL idle shutdown kills detached jobs | unverified | L1 | §15.5 |
| 14 | Git for Windows safe.directory hint for UNC repos | unverified | L5 | W5 |
| 15 | `MSYS_NO_PATHCONV`/`MSYS2_ARG_CONV_EXCL` behaviour; Git for Windows has no python3 | docs-only / assumption | L4 | §3.1, §7.3 |
| 16 | `Task(...)` (or `Agent(...)`) deny syntax on 2.1.316 | unverified | Add the rule, ask Claude to use the agent, observe | D24 |
| 17 | `sandbox.excludedCommands` key | docs-only | Settings schema / a test session | D26 |
| 18 | `claude -p --safe-mode` keeps OAuth | unverified | `claude -p --safe-mode --model haiku "Reply with exactly: OK"` (paid, tiny) | §15.2 claude lane |
| 19 | `AGY_CLI_DISABLE_AUTO_UPDATE` | community-only | Watch agy's version across a release | D14 |
| 20 | CLIs start with worker shims first on PATH | unverified | D29 (free) | §15.6 |
| 21 | `flock` across the Docker bind mount | unverified | v1.1 test | §18 |
| 22 | Copilot review average costs (Lite 25, Balanced 150, Max 1,000) | docs-only | GitHub billing after a few reviews | §17.3 |
| 23 | Copilot `--fleet` concurrency on Max (8 or 32) | docs-only | Measure | `cap_copilot` stays 3 |
| 24 | agy as an Opus harness | unmeasured | The A/B (§6.7) | `opus_lane_order` |
| 25 | A billing API for Copilot month-to-date credits | unverified | Investigate before automating | §8.4 |
| 26 | `copilot login` device flow; agy headless URL + code | docs-only | First fresh login on the Windows box | §8.5 |
| 27 | `claude -p` JSON result shape | assumption | Capture with the paid check of item 18 | §15.2 |
| 28 | agy served-model source in wrapper mode | none: `AGY_USAGE.model` echoes the request (`agy-delegate.sh:552`, read 2026-11-01) | Settled as a gap; raw mode's `init` event (item 6) is the only source | §6.5 G6, §12.2 step 2a, §15.2 |
| 29 | Minimum gh version for `gh pr edit --add-reviewer @copilot` | measured on 2.89.0 only | `gh pr edit --help` on older releases or the gh changelog; then lower `CX_MIN_GH_COPILOT_REVIEW` | D12 |
| 30 | REST fallback reviewer login `copilot-pull-request-reviewer[bot]` | unverified | One request on a test PR | §12.2 step 5 |
| 31 | `wsl.exe --exec /bin/kill -- -<pgid>` reaches the forwarded process group; what the Linux side sees when wsl.exe is killed (the watchdog's parent change) | unverified | L4 | §7.3 step 7, §7.4 step 8 |
| 32 | `claude plugin update` re-copies an unchanged version | unverified | Run it on a CRLF-corrupted cache copy | D3 fixes, §10.5 |
| 33 | The kept D-Bus/XDG variables make keyring logins work through wsl.exe | unverified | L7 | §7.4, D15–D19, W9 |
| 34 | `cygpath -w -l` expands 8.3 components; DrvFs resolution of short names | docs-only | L4 | §7.3 step 4 |
| 35 | `agy-job status` prints `  state=running` while running | verified (read 2026-11-01), not a stable API | Re-read on every antigravity update | skill hazards (no Phase 1 form waits on `agy-job`) |
| 36 | How Claude Code 2.1.316 matches `Bash(...)` allow rules against commands that start with `env -u … VAR=1`, hold literal `$VAR` text, or form multi-line steps | unverified | Add the D25 rules, run one Phase 1 step of each kind, observe whether it prompts | D25, U2 |
| 37 | `wslpath -w /` names the distribution in shells without `WSL_DISTRO_NAME` (ssh, `su -`, cron, systemd units) | unverified | Run it over ssh into WSL | §7.1 `CX_DISTRO`, D1 |
| 38 | `cygpath -w` prints the extended-length `\\?\UNC\…` form for a `\\wsl.localhost` path over `MAX_PATH` | unverified | `cygpath -w -l` of a deep `//wsl.localhost/<D>/…` directory in Git Bash | §7.2 T3, §7.3 step 5 |
| 39 | A forwarded call from a console gets a pty whose foreground group is wsl-entry.sh's (measured only under a Linux pty, not through wsl.exe) | unverified | L4 from Windows Terminal: `cx-wsl bash -c 'read -r x; echo "$x"'` | §7.4 step 8 |
| 40 | **`claude remote-control` started inside WSL serves Work locally threads and loads the WSL user-scope plugins** (policy, skill, `cx-*` on PATH): the preferred Projects route (U7) | unverified (tool serving refuses WSL; no refusal found for Remote Control itself) | **L11, first** | §1.5, §7.1 `bridge`, D31, README |
| 41 | The entrypoint of cloud threads and the coordinator; whether any host sets `CLAUDE_CODE_PROJECTS_SESSION` | unverified | L9 | D30 wording only |
| 42 | The Windows desktop app hosts Work locally threads; which CLI version it bundles | unverified (no OS refusal in 2.1.316) | L10c | §7.1 `bridge` on Git Bash |
| 43 | User-scope plugins and hooks load in bridge children | docs-only plus binary (no `--setting-sources`) | L10c, L11 | §1.7, §10 |
| 44 | The Windows hook shell, and what `bash` in the hook command resolves to | binary: bash when Git Bash is found | L10 | §10.1, §10.2 (item 12) |
| 45 | A `\\wsl.localhost` folder from the picker becomes a WSL session with no plugins; the same folder in the Remote Control folder list | docs-only | L10b | §1.5, W3, D30 |
| 46 | Auto mode in Work locally threads versus U2's allow rules (spending, pushing, `cx-wsl`) | unverified | L12 | U2, D25 |
| 47 | How the Projects instructions are injected (system text or first message) | docs silent | none needed: the template states its own precedence | §9.6 |
| 48 | Shared projects (binary text) versus one user per project (docs) | conflicting | later docs | U2 for project members |
| 49 | The SubagentStart matcher `workflow-subagent\|general-purpose` matches as alternation and the text reaches workflow agents before their first turn | binary (fires and injects); matcher syntax unverified (`subagent.sh` also filters on `agent_type`) | L16 | §10.1, §10.7 |
| 50 | `onFailure` in a plugin's `hooks.json`: accepted by `claude plugin validate`; its behaviour on Windows without Git Bash | validate: measured 2026-11-01; runtime: binary | L13 (done); a Windows observation is optional | §10.1 |
| 51 | `CLAUDE_CODE_SESSION_ATTENDED` in bridge children; whether `claude -p` waits for background Bash tasks | binary; unverified | L18 | `cx_attended`, `{ATTN}` |
| 52 | Workflow PreToolUse payloads carry `agent_type: conductor:cx-runner` for `agentType` spawns; plugin-agent `effort: low` and `omitClaudeMd` apply in workflows | binary | L17 | §15.9, §15.10 |
| 53 | `bashCommandClamp` syntax and stability | binary (undocumented) | L17 | §15.11 |
| 54 | A `Workflow(conductor:opus-pools)` allow rule suppresses the launch prompt; the desktop card's "Always" covers plugin workflows | docs-only | L20 | D25 Phase 2 |
| 55 | `git status` of the main checkout shows `.claude/worktrees/`; where `claude remote-control --spawn worktree` and the folder card's Worktree option put worktrees | unverified (the `trees` exclusion is harmless either way) | L14 | §12.2 `trees`, P60 |
| 56 | The ultracode keyword typed in a Work locally thread triggers a workflow; `"ultracode": true` in machine settings starts new threads in ultracode; relayed coordinator briefs do not trigger | docs silent | L19 | §12.1, D32 |
| 57 | `_host` and computer folders are refused for this user's Windows and WSL machines | binary (`windows` gate, platform text) | L15 | §1.7 (never routed) |
| 58 | The default workflow-agent stall timeout against the runner's 100 s waits (`stallMs: 1200000`) | docs-only | L17 | §15.11 |
| 59 | The `haiku` alias resolves to an available model on the user's plan | assumption | L17 | §15.9 |
| 60 | SessionStart(`compact`) for a compacting subagent carries `agent_id` and `agent_type` | binary | optional L21 | §10.2 row 3 |
| 61 | A desktop SSH session into WSL loads the WSL user-scope plugin (a forwarding-free alternative to Git Bash) | docs (SSH supports plugins); untested for WSL | optional L22 | §1.5, README |
| 62 | Copilot CLI 1.0.105 signs in with `COPILOT_GITHUB_TOKEN` (a fine-grained PAT with "Copilot Requests") ahead of an unreachable keyring | docs-only | L7 with the token file: `cx-wsl ghcp-models --json` from Git Bash | §7.7, §8.5 |
| 63 | `gh repo view --json url` resolves an SSH host alias (`git@github-work:…`) and, with several remotes, picks the repo `gh pr create` would | docs-only (gh translates remotes through `ssh -G`) | One run in a multi-account checkout | §12.2 step 1 |
| 64 | `agy-delegate`, agy, the ghcp wrappers, Copilot and grok keep the inherited pool-slot descriptors (`$CX_HOME/locks/<pool>.<n>`, `agy-launch`; fd 10 and up) for the whole run, and a detached `ghcp-job`/`agy-job` keeps them for the job (so an orphaned agy still holds its slot) | bash, `env`, `exec` and `timeout` keep inherited fds (the suite's sleepers and a detached `ghcp-job` stand-in show it, A25); the wrappers' and CLIs' internals are not a stable API (a CLI that closes foreign fds, or a daemon that inherits one and outlives the run, would end or extend the slot early or late) | `ls -l /proc/<pid>/fd` of each executor during a run | §12.2 step 2a, §15.3 |
| 65 | `ghcp-cloud create -R HOST/OWNER/REPO -` (`gh agent-task create`, a gh preview) accepts a host-qualified repo, and the agent's PR head is fetchable as `pull/<N>/head` | docs-only | One cloud task on a test repo | §12.2 step 5 |
| 66 | Desktop app sessions in WSL load user-scope plugins (contradicting `desktop-wsl.md`) | observed once: 2026-11-01 on ChalkDesk, a Remote Control session in `~/ai-folders` (WSL) with the desktop app's signals loaded the conductor and ran `/conductor:doctor`, whose old D30 then warned falsely | Repeat in a session opened on `\\wsl.localhost` from the desktop folder picker, and in a Work locally project thread | §1.5, D30 |
| 67 | Whether `agy --effort xhigh` or `max` applies to `claude-opus-5-5-*` on Google AI Ultra (the 1.4.12 help offers the values; `agy models` lists only the -low/-medium/-high slugs, so the Opus lane keeps effort in the slug and sends xhigh/max to the next pool) | unverified | One tiny `agy -p` run with `--model claude-opus-5-5-high --effort xhigh --output-format stream-json`, reading the init event's model and effort | §6.2, §15.2 |
| 68 | Whether agy's print-mode slash commands (`agy -p /model`, `/usage`, `/config`, used by the free probes, the doctor's `--agy-usage` and the per-worktree registration `--new-project -p /model`) cost quota | **settled 2026-11-06**: `agy -p /model` and `-p /usage` report `num_turns` 0 and 0 tokens (agy 1.5.1, build container): free | — | §8.2 D18, §15.2 registration |
| 69 | grok's `strict` profile plus `read_only = [<git common dir>, $CX_HOME/routes]` lets a worktree run `cx-route <name>` (bash, the check's own toolchain) and `git status`; a check whose toolchain lives under `$HOME` (`~/.nvm`, `~/.cargo`) cannot run in it | **settled 2026-11-06** for `cx-route`: the real run sbx-grok-2 (`--sandbox cx-textutil-78d1f9c2 --always-approve`, grok 1.0.70, build container) ran `cx-route test` (`python3 -m unittest`, 3 tests OK, in grok's own session log) and exited 0; its sandbox log line shows the profile enforced with `~/.grok` read-only (§1.3). A toolchain under `$HOME` is still unreadable by construction | — | §15.2 grok, §15.7 |
| 70 | Copilot approves `shell(cx-route)` for a PATH-resolved script named `cx-route`, and `shell(git status)` for `git status --short` | docs (`copilot help permissions`: command name; git first-level subcommand) | One `cx-run --exec copilot` on the user's machine (Copilot cannot sign in from the build container) | §15.2 copilot |
| 71 | agy's `command(cx-route)` grant covers `cx-route test` (a token-prefix rule, as measured for multi-word rules) | **settled 2026-11-06**: the real run sbx-agy-2 (agy 1.5.1, build container, per-run `--settings` with `write_file(<worktree>)`, `command(cx-route)`, `command(git status)`, `command(ls)`) ran `ls -R`, `cx-route test` (3 tests OK) and `git status` as `run_command` steps, none denied, exit 0 | — | §15.2 agy |
| 72 | grok on a kernel without Landlock: whether 1.0.70 refuses to start (as for a profile it cannot apply) or warns and goes on unconfined (its README), and what its sandbox log says then | a profile it cannot apply refuses (measured 2026-11-06); a start where Landlock applies logs `ProfileApplied` with `enforced` true (§1.3). No Landlock is unverified, and so is whether grok then logs `enforced` false. Now checked: the preflight and D17 refuse on a line saying the sandbox was not applied and on a `ProfileApplied` event with `enforced` false that their own strict probe appended for its cwd, and so does every grok run's per-run check of its own profile in its checkout (0.2.2, §15.2); with neither (no log, no event, or no GNU `stat`: macOS) nothing changes, and D17 still reports the Landlock ABI | `grok --sandbox strict models` on such a kernel (WSL with an old kernel), reading its stderr and the new line of `~/.grok/sessions/sandbox-events.jsonl` | §1.3, §15.2 grok, D17 |
| 73 | Which definition grok uses when the run's checkout's `.grok/sandbox.toml` and `~/.grok/sandbox.toml` both define the run's profile | docs-only (`~/.grok/docs/user-guide/18-sandbox.md`: the user's file wins, with a startup warning, when the two differ); not measured | `grok --sandbox <p> models` with both files and an invalid grant in one | §15.2 grok (the lane refuses a checkout that holds one, in every mode since 0.2.2), §15.7 |
| 74 | The agy and Copilot lanes have no OS sandbox: `cx-route` runs the repository's own checks, whose code is in the worktree, so their grants keep an executor to the routes but do not contain a hostile one (grok's sandbox does) | by construction | — | §15.2, §15.6 |
| 75 | grok's session store `~/.grok/sessions` (every grok session's transcript: the prompt, the files read, tool output and the answer, for every repository) is readable and writable by every grok run, under every profile, so a grok run can read and change other grok runs' tasks and answers there; R6 keeps `$CX_HOME/out` from grok runs, not grok's own store | measured 2026-11-06: `~/.grok/sessions` is in the `read_write_paths` of every logged strict-based start (§1.3), it was WRITABLE under `strict` as under `read-only` (`tests/fixtures/real/grok/write-probe-*`), and it held the live runs' `chat_history.jsonl` with their task text. The per-run check exempts it on purpose (every grok run must write its session) | — (a known limit of grok's profiles) | §1.3, §15.2 grok, §15.6, §15.7 |
| 76 | What a conductor grok run can write in grok's home `~/.grok`: 0.2.1 ran read and review runs and the skill's Step 3 commit-message call under the built-in `read-only`, and its docs said that profile writes all of `~/.grok`, `sandbox.toml` and `config.toml` included | **settled 2026-11-06** (grok 1.0.70, linux/landlock plus bubblewrap, enforced; `tests/fixtures/real/grok/write-probe.sh` run by grok's agent, results `write-probe-read-only-1.0.70.txt` and `write-probe-strict-1.0.70.txt`): under `read-only` grok's protected set (`config.toml`, `sandbox.toml`, `trusted_folders.toml`, `managed_config.toml`, `requirements.toml`, `hooks-paths`, `hooks/`, `bundled/`, `bundles/`) is write-denied (0.2.1 was wrong there), while grok's binary `bin/grok-1.0.70`, its ripgrep `vendor/rg-15.0.0-override`, `installed-plugins/`, `auth.json` and `~/.grok` itself are writable: code that later runs outside any sandbox (0.2.1 missed that exposure); under `strict` all of it is denied but `sessions/`. Resolved for every conductor-launched grok run (0.2.2): read, review and write runs use the repository's strict-based profile, the commit-message call the built-in `strict` in a directory that holds only its prompt, and each lane run first checks its own profile's logged grants (§15.2). The tamper-safe profile rewrite stays: it now guards `sandbox.toml` against what is outside conductor's runs. What remains: the user's own grok sessions (grok's default is no sandbox; `workspace` writes `~/.grok` too) and anything they run can still change `~/.grok`, and a 0.2.1 read or review may have planted code there already | — (the user's own sessions are theirs; check `~/.grok/bin`, `vendor/` and `installed-plugins/` after 0.2.1 read or review runs on untrusted code) | §1.3, §12.2, §15.2 grok, §15.7 |
| 77 | Whether grok reads `--prompt-file` (and loads its configuration) in its own process before the sandbox applies, or under it | unverified (grok's `--json-schema` takes the schema text itself, so only the prompt file matters). Moot for conductor's runs: every prompt file lies inside the run's cwd (`<checkout>/.conductor/prompt.txt`, `$OUT/msg/prompt.txt`), which every strict-based profile reads | One `grok --sandbox strict --prompt-file <a file outside the cwd>` run (the parent's live verification) | §12.2, §15.2 grok |
| 78 | Whether grok's daemon backend ever runs a conductor grok run (headless `--prompt-file` or `models`): its docs say `strict` then also writes `~/.grok/daemon/run/strict`, a custom profile `~/.grok/daemon/run/<name>`, which the per-run check would refuse as a write into grok's home | unseen: no logged start of a conductor run (write, read, probe) listed such a path (§1.3, 2026-11-06) | A per-run check refusal naming `~/.grok/daemon/run/...` (it says so), then a decision whether that directory may be exempted | §15.2 grok |

## Appendix A. Spec revision log

### A.1 Revision 2026-11-01b (spec review of the 2026-11-01 draft)

Every item was checked against this file, the sibling sources (`ghcp-for-claude-code`,
`antigravity-for-claude-code`) and the CLIs in the build container before it was applied.
"Adapted" means the problem was confirmed and fixed differently from the review's proposal.

| # | Topic | Action |
|---|---|---|
| R1 | Windows app had no working delegation path | Applied: `cx-wsl` passthrough (§7.7) plus a Git Bash policy variant (§10.4) chosen by `uname -s` (§10.2). Adapted: `bash` joins the allowlist (shell steps run as `cx-wsl bash -s < FILE`), and arguments are never rewritten (no `wsl:` stripping) |
| R2 | agy served-model check checked nothing | Applied (confirmed at `agy-delegate.sh:552`): §1.4, G6, step 2a `unverified (wrapper)`, optional raw arm with an `init` check, §15.1/§15.2, §20 item 28 |
| R3 | CRLF detection unreachable | Applied: canary in `policy.sh` and `policy-context-crlf.json` (§10.2, §10.5), P22b, W6/D3 scoped, README note. Adapted: the notice routes nothing (the conductor cannot run), and §3.5 records that `eol=lf` already protects git checkouts |
| R4 | D3's `reset --hard` fix | Applied: ordered fixes, marketplace-clone-only `checkout-index` fix after a toplevel check, P29 |
| R5 | Billing/permission variables not scrubbed | Applied: per-command prefixes (§12.2 table), D28 extended, P28, P43 |
| R6 | D16 probe on unpinned versions, in the user's cwd, from cache | Applied: pin-gated, `$CX_HOME/probe`, `--disable-builtin-mcps`, `--refresh`; `--pools` reads the cache file when not probed (extra); P26, P30, P31 |
| R7 | Bash tool kills foreground runs; no `wait` subcommand | Applied: background rule, exact wait one-liners (adapted: `grep -qx` because `agy-job status` prints the task text), policy wording, §1.1 |
| R8 | Sandbox blocks agy, grok, worktrees too | Applied: policy line, skill troubleshooting, D26, §6.6 |
| R9 | Reviews diffed an uncommitted branch; two `worktree add` on one path | Applied: steps renumbered (3 after-run, 4 reviews on the same `$G`, 5 GitHub), `EMPTY_DIFF` stop, P43 order |
| R10 | AGENTS.md bound the conductor and the Copilot coding agent | Applied: general vs worker-only rules (§9.5), P36 |
| R11 | Partial inline commands in the policy | Applied option (a): skill-first rule and the bounded registration command in the policy; lane rationale cut; P20 |
| R12 | Policy ignored `opus_lane_order` and `worktree_root` | Adapted: `policy.sh` substitutes a constants-only `{ORDER}` phrase (no per-order files); `worktree_root` named as an option; P21 |
| R13 | Forwarder cancellation could not work | Applied: background wsl.exe with fd-3 stdin, remote `kill` of the target's process group, wsl-entry.sh `set -m` launch, watchdog, exit with the target's rc; P16 |
| R14 | Keyring variables dropped when forwarded | Applied: D-Bus/XDG/display variables kept, bus derived, per-side login results, forwarded comparison, W9, L7 |
| R15 | D3 ran against the runtime copy | Applied: D3 checks the installed copy, D4 checks the runtime subset, P29, P41 |
| R16 | P44 undefined | Applied: exact grep and two named constants |
| R17 | P40 contradicted P24 | Applied: scope in §3.2 and P40 |
| R18 | Unquoted `argument-hint` YAML | Applied: quoting rule and P43; README one-step install (verified with `claude plugin install --help`) |
| R19 | `wsl_distro` default `Ubuntu`; localized STATE | Applied: default `auto`, `-l -q`, VERSION as last field, `CX_WSL_DISTRO`; pathmap's distro default |
| R20 | 8.3 short names | Applied: `cygpath -w -l` everywhere, stub `-l`, L4 |
| R21 | Windows python on Git Bash | Applied: `cx_py_ok` false on MINGW/MSYS/CYGWIN; P42 trap always present |
| R22 | Incomplete Git Bash tool list | Applied: authoritative list (§3.1), W1 GNU `timeout` check, P42 mini bin |
| R23 | Concurrent runtime installs | Applied: `flock`, stamp re-read under the lock, `mv -T`, P18 |
| R24 | D15/D17/D27 verdicts | Applied |
| R25 | D14 always ! when forwarded | Applied: wsl-entry.sh exports the pins; forwarded D14 greps the rc files; P28 |
| R26 | D25 read the wrong settings on Windows | Applied. Adapted: explicit `Bash(cx-doctor:*)`, `Bash(cx-init:*)`, `Bash(cx-wsl:*)` rules instead of a `cx-*` wildcard, whose syntax is not verified |
| R27 | Lockfile churn from setup commands; Setup line; append needed `--force` | Applied: npm `--no-package-lock`, `cargo fetch --locked` or null, bun detection, Setup wording, `update` classification, `--only`; P35, P36 |
| R28 | Stale-MTD warning with no reserve | Applied: ! only when `copilot_reserve_pct` > 0; P31 |
| R29 | A/B records and unsanitized captures in the repo | Applied: `$CX_HOME/ab/`, aggregate `docs/ab-2026-11.md`, sanitization rule (§14.2) |
| R30 | Unlisted deviations; `--caller` in §18 | Applied: three §0.3 items; §18 uses `-e CX_CALLER=wsl` |
| R31 | `@copilot` reviewer gh version | Applied with evidence: gh 2.89.0's `gh pr edit --help` documents `@copilot`; D12 checks the help text, `CX_MIN_GH_COPILOT_REVIEW` = 2.89.0, stub moved to 2.89.0, REST fallback [unverified], §20 items 29–30 |
| R32 | BOM in Windows settings | Applied: `utf-8-sig` (§3.3), lite reader strips the BOM, P5 |
| R33 | `review_models` mixed namespaces | Applied: `review_model_gemini`, `review_model_gpt` (24 options) |
| R34 | Unbounded registration; handoff without `--test-cmd`; ci-debug `--apply` | Applied |
| R35 | Signal ownership of 40/41/42; VM crash after start | Applied: §7.3 step 8, §7.4 steps 1–3, §4.1, P16 |
| R36 | Leaked `CX_FORWARDED` on Git Bash | Applied: step 0 detects first and never reads it; P42 |
| R37 | `GH_TOKEN` exception lost | Applied: D16 probes without the tokens, `copilot_token_env`, adapter keeps it, D28 info |
| R38 | Wrapper scope, stale `installPath`, forwarded PATH | Applied: user scope first, `-x` re-resolve, wider fallback PATH, `path_source` merge rule, D2 note |
| R39 | `.gitattributes` would normalize CRLF fixtures | Applied: `tests/fixtures/** -text`, `*.utf16le binary` (§2.2), P39 |
| X1 | Found while revising: Bash tool calls share no variables, so the multi-call recipe lost `$WT`/`$OUT` | Added `$OUT/vars.sh`, sourced at the top of every step (§12.2) |
| X2 | Found while revising: R5's `env -u …` prefixes stop `Bash(ghcp-delegate:*)`-style allow rules from matching, which U2's prompt-free autonomy relies on | D25 lists the prefixed rules; §20 item 36 |

None of the 39 items was skipped.

### A.2 Revision 2026-11-01c (Phase 1 code review, 28 findings, some duplicates)

Each finding was reproduced or checked against the code before it was applied, and each fix
came with a test that fails on the old code.

| # | Topic | Action |
|---|---|---|
| C1 | A forwarded call from a console stopped on SIGTTIN (target in a background group) | §7.4 step 8: foreground in wsl-entry's group when it leads the terminal's foreground group; P16 pty case |
| C2 | Missing-CLI doctor cases ran real CLIs from `$REAL_PATH` | §14.1: stub copy plus system-tool links; guard check |
| C3 | cx-init wrote through committed `.cx`/`.github` symlinks; a file `.cx` left a partial bundle | §9.2 path checks before any write, `O_NOFOLLOW` |
| C4 | agy and grok probes kept API keys and ran unpinned | §8.2 prefixes on every agy and grok probe |
| C5 | An agy status envelope read as "logged in" | §4.4 `parse-models` slug rule, D18 |
| C6 | Fix lines split paths with spaces; W6 skipped `bin/cx-wsl` and friends | `cx_shell_words`; W6 over `CX_SHIPPED_FILES` |
| C7 | `policy.sh` accepted empty order segments that `cx_opt` rejects | §10.2 grammar; P21 agreement case |
| C8 | Windows npm shims under `/mnt/c` became recorded CLIs | §7.6 PATH walk skips the automount root; wsl-resolve refuses it |
| C9 | `bash -s` bootstrap misdetected when the WSL home holds a file `main` | §7.5 file-scope `BASH_SOURCE` |
| C10 | `\\?\UNC\wsl.localhost\…` refused | §7.2 T3, four table rows |
| C11 | `--json` printed plain text on a Git Bash forwarding failure | §8.1, §8.7 |
| C12 | The CRLF fixes led with `core.autocrlf`, which cannot help the copies that reach them | §8.3 D3 fixes, §10.5 notice, P22b runs the notice's fix |
| C13 | The Git Bash policy showed raw `agy`, `gh` and `ghcp-ci-debug` commands | §10.4 |
| C14 | Shells without `WSL_DISTRO_NAME`, and an exported `CX_HOME`, split the host record silently | §7.1 `wslpath -w /`; D1 notes |
| C15 | A CRLF `cx-wsl bash -s` step ran with CRs | §7.7 strip with a note |
| C16 | Forwarded git had no ssh-agent or passphrase tty, unreported | D5 notes; a live `SSH_AUTH_SOCK` is kept (§7.4) |
| C17 | Background calls are stopped at 30 minutes by default | §1.1, §10.3/§10.4, §12.2 `timeout: 7200000`; P20, P43 |
| C18 | `agy-media` and `/antigravity:research` always pass `--yolo` yet were read-only lanes | §0.3: not Phase 1 lanes; §6.1, §6.2, §7.7, D25; P20, P43, P45 |
| C19 | WRONG_TREE watched only the main checkout's porcelain status | §12.2 step 2a `trees` over every other worktree, with content |
| C20 | An executor that switched branches got BASE gated | §12.2 step 3 `BRANCH_TAMPERED` and the exact-commit gate; §4.1 row 24 |
| C21 | `ghcp-delegate --github` presented as a triage lane | §6.1, §6.2, §10.3, §12.2 step 5 |
| C22 | DESIGN step 3 and `grok usage` drifted from the SKILL | §12.2 synced; P43 compares every bash line |
| C23 | The policy did not forbid `grok-delegate` | §10.3; P20 |
| C24 | D25's rules did not match the skill's command forms | D25 = `cxlib.D25_HOST_RULES`; step 5 uses `gh … -R "$REPO"`; P43 checks every command |
| C25 | "Run cx-doctor from a WSL terminal" named a command a plain terminal lacks | the runtime copy's `cx-doctor` in every message, §7.6, §7.7, §8.5 |
| C26 | Wall time alone failed the suite | §14.1 informational, `CX_TEST_STRICT_TIME=1` |

None of the 28 findings was skipped (C1 and C6 each merge two findings).

### A.3 Revision 2026-11-01d (Claude Code Projects and ultracode, Phase 1 parts)

Sources: the Projects (beta) research note and its Projects + ultracode addendum (2026-11-01,
kept outside the repo), adjusted for two user decisions: every Project thread runs as a Work
locally thread (U7) and ultracode is normally off (U8).

| # | Change | Where |
|---|---|---|
| R1 | Session kinds `local`, `bridge`, `cloud`, `byoc` and the attended flag, decided before the host; never the entrypoint | §1.7, §7.1, `detect.sh` |
| R2 | Cloud safety net: the cloud notice instead of any policy, step 0a exit 43 in every `cx-*` (BYOC with `exec_host=local` runs locally), ✗ D30 | §7.3, §10.2, §10.6, §8.3 |
| R3 | SubagentStart guard for `workflow-subagent` and `general-purpose`: subagents never run executors in Phase 1; a compacting subagent gets the guard again, never the main policy; both hooks `onFailure: continue` | §10.1, §10.2, §10.7 |
| R4 | Policy: a Workflows line (ultracode changes thoroughness, not who executes; one agy run at a time across sessions and threads) and `{ATTN}` for unattended runs; limit 2,800 rendered | §10.2–§10.4 |
| R5 | `templates/projects-instructions.md` rewritten for local-only threads; README and SKILL say where it goes and what wins | §9.6, §12.1 |
| R6 | Doctor D30, D31, D32, W10, W11, the D24 workflow note, the desktop WSL-session warning, W3 drive case info, `session` in the header, `CX_HOST`, `CX_DOCTOR` and `--json` | §8 |
| R7 | `trees` snapshots exclude `.claude/worktrees` | §12.2, P60 |
| R8 | Phase 2 order: shared slots first (every executor path, `cx-wsl` included), then `cx-run`/`cx-job`/adapters, the Copilot cloud agent lane, and the optional runner agent, gate and `opus-pools` workflow | §15 |
| R9 | Live checks L8–L22 with `claude remote-control` in WSL (L11) first; §20 items 40–61 | §14.4, §20 |

### A.4 Revision 2026-11-01e (final Phase 1 review, 18 findings)

Each finding was reproduced against the code or the skill text first; every one held and was
applied (some in the form the finding offered as its alternative). F2 and F9, and F3 and F10,
overlap and were applied together.

| # | Finding | Change | Where |
|---|---|---|---|
| F1 | The Windows-side filter matched the whole automount root (`root = /` hid every CLI) and `/mnt/data` | Only drive directories `<root><letter>/` and `/mnt/<letter>/`, in `on_windows_side`, `record_path` and `wsl-resolve` | §7.6, §7.7; doctor and wsl-resolve cases |
| F2, F9 | The agy job form had no registration, no snapshots and no lock; the hybrid recipe sent agy work there while other lanes wrote the same repo | No agy job form in Phase 1; agy runs as step 2a's background call; non-agy dispatches mark their worktree `running` and `trees` leaves marked worktrees out | §12.1, §12.2; P43, P60 |
| F3, F10 | The Claude lane and the claude-pool script had no Windows form; the Git Bash policy said `bash -s` where the skill said `bash -c` | Step 2d and the claude-pool `wt_win` prompt: file tools on the `\\wsl.localhost` path, commands through `cx-wsl bash -c`; the WSL path quoted; the guard and the Git Bash policy say the same | §10.4, §10.7, §12.1, §12.2; P55, P57, P61 |
| F4 | `policy.sh` exempted only kind `byoc` with `exec_host=local` | Any non-empty kind but `bridge` with `exec_host=local` gets the normal policy | §7.1, §10.2 row 4; P46 |
| F5 | `REPO` from the origin URL kept SSH host aliases and ports, which `gh -R` cannot resolve | `REPO` from `gh repo view` (aliases resolved), the URL with `:port` stripped as the fallback; D25 `Bash(gh repo view:*)` | §8.3 D25, §12.2 steps 1 and 5 |
| F6 | The Git Bash lite readers were quadratic (seconds on a 70 KB settings file) | Split at quotes once; key searches by `${x%%"KEY"*}`; W10 and W11 share one parse | §5.2, §8.6; P7 |
| F7 | A false cloud verdict on the user's own computer would switch the conductor off | `cx_session` and `policy.sh` never answer cloud or byoc on Git Bash or WSL | §1.7, §7.1, §10.2; P46, P48, P49 |
| F8 | `trees` keyed its `.claude/worktrees` exclusion on `TOP` and its remedy said "restore that tree" | The exclusion keys on the main checkout (TOP itself stays in); `running` marks; the remedy reports and never restores a tree the task did not create | §12.2 step 2a; P60 |
| F11 | U7 invited `ghcp-cloud`, which `cx-wsl` refused and no recipe covered | `cx-wsl`, `CX_WSL_KEYS` and D25 allow `ghcp-cloud`; step 5 has the recipe and the PR gate; Grok remote sessions are the user's | §7.7, §8.3, §12.2 step 5, §15 item 3; P45 |
| F12 | "One agy run at a time" had no mechanism | Every agy step takes `flock -w 4800` on `~/.conductor/locks/agy` first (`AGY_BUSY`, exit 28) | §12.2; P43 |
| F13 | `ghcp-ci-debug --apply` left `$WT` on `ghcp/ci-fix-*`, so step 3 exited 24 | Step 5's hand-back: switch to `cx/<id>`, delete the fix branch, append the new `BASE` | §12.2 step 5; P43 |
| F14 | D5 told a Windows user to move the repo into WSL | Forwarded: an info line with W3's wording | §8.3 D5 |
| F15 | D13's install fix needed marketplaces that were never added; forwarded fixes looked like Git Bash commands | `claude plugin install NAME --marketplace SOURCE`; README prerequisites; the forwarded report's header note | §8.2, §8.3 D13, §13.2 |
| F16 | The token file was read by nothing in Phase 1 | `cx-wsl ghcp-*` exports `COPILOT_GITHUB_TOKEN` from a 0600 file for that call only | §7.7, §8.5; P45 |
| F17 | `Bash(cx-wsl:*)` was presented as the U2 rule without its scope | D25 always prints the scope line; README names the narrower rules | §8.3 D25 |
| F18 | Messages sent WSL-only users to a runtime copy they may not have | `/conductor:doctor` in a Claude Code session in WSL first, the runtime copy with `--install-runtime` second | §7.7, §8.5, `common.sh`, D30 |

### A.5 Revision 2026-11-06 (0.2.1: the first real runs and the live probes)

One small `cx-run` per lane on the user's machine (2026-11-02, `tests/fixtures/real/*/sbx-*`)
and cheap live probes of agy 1.5.1, grok 1.0.70 and Copilot CLI 1.0.105 in the build container
(2026-11-06) settled these decisions (the first one the user's).

| # | Finding | Change | Where |
|---|---|---|---|
| 1 | Pins refused a working Copilot (the user's machine auto-updated to 1.0.106) | No version pins: the flag contract checks every flag a lane emits in the live `--help` before each run (26 only for a missing flag); the versions last verified are doctor info lines; no advice to disable auto-update | §5.4, §8.3 D9–D16, §15.2 |
| 2 | Executors could not run the repo's checks within their permission models (agy denied a command, Copilot matched `python3`, grok had no grant) | `cx-route`: the run's checks snapshotted at dispatch into `$CX_HOME/routes/<id>/cx-route`, the only check command any executor runs | §6.4, §15.1, §15.6 |
| 3 | agy: one denial ends a headless run; the global grants were machine-wide | Per-run `--settings` (`write_file(<worktree>)`, `command()` for cx-route, `git status`, `ls`); no global grant; the real stream-json parsed, the denied command named | §1.4, §15.2, §15.7 |
| 4 | grok: `acceptEdits` denied the first edit headless; `strict` blocks git; glob deny paths are invalid | Per-repository profiles (extends `strict`, `read_only` the git dir and `$CX_HOME/routes`) under a lock, `--sandbox <it> --always-approve`, `GIT_CONFIG_GLOBAL=/dev/null`; the 0.2.0 block removed; bubblewrap in D17 | §1.3, §15.2, §15.7, §8.3 |
| 5 | Copilot: `shell(<full command>)` never matches | `--allow-shell cx-route` and `git status` only | §1.2, §15.2 |
| 6 | grok serves `grok-4.7` as `grok-4.7-build` (21 in 0.2.0) | An explicit alias table: `-build` only | §15.2 |
| 7 | Python checks left `__pycache__` in worktrees | `PYTHONDONTWRITEBYTECODE=1` in every worker environment | §15.6 |

A security review of that build (2026-11-06) changed it before release:

| # | Finding | Change | Where |
|---|---|---|---|
| R1 | The conductor's own git (`git -C "$WT" add -A`, `diff`, the agy snapshots' `status`) found the repository from the worktree's `.git`, which every write lane may rewrite: a repointed git directory's `core.fsmonitor` ran as the conductor | `worktree.sh`: the git directory from the main repository's admin files (`cx_wt_admin`, `cx_wt_gitdir`), `cx_wt_git` with `--git-dir`/`--work-tree` and no fsmonitor, hooks, pager, textconv or submodules; a rewritten link is 24 `tampered` and no git runs there; `--reuse-worktree` refuses it | §4.1, §15.1, §15.2 agy |
| R2 | grok may rewrite `~/.grok/sandbox.toml`; a `[profiles.cx-…]` without the markers was left as "the user's" | The name is conductor's own: every other definition is replaced, one that still differs in the parsed file refuses the run; a worktree `.grok/sandbox.toml` refuses it too | §15.2 grok, §15.7 |
| R3 | `command(git diff)` (agy) and `shell(git diff)` (Copilot) also allow `--output=<path>` and `--no-index` | `git status` only (agy also `ls`), in the grants, the contract and the prompts | §1.2, §6.4, §12.2, §15.2 |
| R4 | `cx-route` honoured its caller's `BASH_ENV` and exported functions | `#!/bin/bash -p`, the check through `env -i` without the startup variables and `BASH_FUNC_*` | §15.1 |
| R5 | grok approves every tool inside its sandbox; where the sandbox does not apply it may go on unconfined | The preflight's `grok --sandbox strict models` (2 when a line says the sandbox was not applied), the same line in a run's stderr → 2; D17 also probes it and reports the Landlock ABI | §1.3, §8.3 D17, §15.2 |
| R6 | The grok profile granted all of `$CX_HOME/out` (other runs' tasks, diffs, digests) | `cx-route` lives in `$CX_HOME/routes/<id>/`; the profile grants `$CX_HOME/routes` | §15.1, §15.6, §15.7 |

The first live runs in the build container (2026-11-06, conductor 0.2.1 after the review; a
scratch repository whose `slugify` raised `NotImplementedError`; fixtures `real/agy/sbx-agy-2`,
`real/grok/sbx-grok-2`, `real/grok/sbx-grok-3` and `real/grok/sandbox-events-1.0.70.jsonl`)
verified the agy and grok write lanes, a grok read through `cx-job` and the skill's Step 3 by
hand (GATE_OK on both write runs), and changed (with the review of those changes):

| # | Finding | Change | Where |
|---|---|---|---|
| L1 | grok's `text` joins every turn's message with no separator: a read with `--json-schema` answered `[ ][{…}]`, not valid JSON, while `structuredOutput` held the answer | With `--json-schema` the answer is `structuredOutput` as JSON (without one, `text` with a note); the stub answers the same way | §1.3, §15.2 grok |
| L2 | grok logs a `ProfileApplied` event per sandboxed start (`platform`, `enforced`); strict keeps `~/.grok` read-only but `~/.grok/sessions` (its README says it writes `~/.grok`), while the built-in `read-only` of the read and review runs writes `~/.grok` (all of it, this row said; corrected by A.6 item G1: all but grok's write-denied protected set, `bin/`, `vendor/` and `installed-plugins/` included) | The preflight and D17 read the event their strict probe appended: `enforced` false refuses the lane; the lane writes the repository's profile again once a run holds its slot; the docs say what was measured, with the session store and `read-only`'s writes as known limits | §1.3, §8.3 D17, §15.2, §15.7, §20 items 69, 72, 75, 76 |
| L3 | `cx-job wait <task id>` said only "no job" | A task id (`--id`) of exactly one job names that JOB_ID in the note (exit 1 still; nothing acts on it); a prefix of one JOB_ID that is another job's task id is ambiguous (exit 1) | §15.5 |
| L4 | agy's `command(cx-route)` covers `cx-route test`; grok's profile runs it | §20 items 69 and 71 settled; item 70 (Copilot) stays open for the user's machine | §20 |

### A.6 Revision 2026-11-06b (0.2.2: no conductor grok run under the built-in `read-only`)

A live write probe in the build container (grok 1.0.70, linux/landlock plus bubblewrap,
enforced; `tests/fixtures/real/grok/write-probe*`) measured what grok's agent can write in
`~/.grok` under the built-in `read-only` and `strict`, and changed:

| # | Finding | Change | Where |
|---|---|---|---|
| G1 | Under the built-in `read-only` (0.2.1's read and review runs and the skill's commit-message call) grok write-denies its protected set (`config.toml`, `sandbox.toml`, `hooks/`, …), against 0.2.1's docs, but writes the rest of `~/.grok`: its own binary in `bin/`, its ripgrep in `vendor/`, `installed-plugins/`, `auth.json`. A run steered by the executor-written or repository content it reads could plant code that later runs outside any sandbox | Read and review runs use the repository's strict-based profile (the same as writers; a custom `grok_sandbox_profile` in every mode); every file they read lies in their checkout; a built-in that writes `~/.grok` is refused | §1.3, §15.2 grok, §15.7, §20 item 76 |
| G2 | The preflight checked only the built-in `strict`, never the profile a run actually uses | A free per-run check before the slot: `grok --sandbox <the run's profile> models` in the run's checkout and the bytes it appended to grok's sandbox log; `enforced` false or a `read_write_paths` entry that grants write to grok's home (but `~/.grok/sessions`) refuses the run (2); the facts go into `grok.run.json` | §1.3, §15.2 grok, §20 items 77, 78 |
| G3 | The skill's commit-message call ran `--sandbox read-only --cwd "$TOP"` | `--sandbox strict` with `--cwd "$OUT/msg"`, a directory emptied first that holds only the prompt (nothing the conductor later sources or runs lives there) | §12.2 |
| G4 | A review's gate checkout (an executor-written branch) could carry a `.grok/sandbox.toml`; only write runs refused one | Every mode refuses it | §15.2 grok |
| G5 | A refusal before the executor reached the result only as "stopped before its executor ran" | The adapter leaves its reason in `$OUT/adapter.why`; cx-run appends it to the result's reason | §15.2 |
