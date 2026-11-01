# conductor — Claude Code conducts Copilot, Grok Build and Antigravity (design spec, v0.1.0)

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
| Plugin name / version | `conductor` / `0.1.0` |
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

Deviations from the plan that this spec makes on its own authority, each for a stated reason:
- The plan's `nudge` option is not declared: v1 has no UserPromptSubmit hook, and an option
  nothing reads is dead config. It returns with the hook in v2 (§19).
- `agy-handoff` is not used for conductor write lanes outside Docker: it always passes `--yolo`
  (`--dangerously-skip-permissions`, machine-wide; `agy-handoff.sh:143`), which §6.5 G10
  forbids. Phase 1 agy writes use `agy-delegate` plus a static grant (§12.2).
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
  read-only sandbox plus `--always-approve` already fence those runs, and a per-type model pin
  for `explore` in the user's grok config could override `-m`/`--effort` [assumption]. It
  returns only after a Phase 0 check shows `-m` and `--effort` still apply under it.
- The plan's `--caller` flag is the environment variable `CX_CALLER` instead: the caller is a
  property of the transport (set by `wsl-entry.sh`, §7.4, or by the Docker forwarder, §18), not
  something a user types, and one variable serves every `cx-*` command.
- Phase 1 adds `cx-wsl` (§7.7), a forwarded passthrough the plan does not have, so that the
  Windows app can delegate before `cx-run` lands (Phase 2).

### 0.4 Scope by phase

| Phase | Deliverable | § |
|---|---|---|
| 0 (outside the repo, already run or run by hand) | Free checks and tiny paid checks of plan §13.2–13.3; raw outputs sanitized (§14.2) and saved under `tests/fixtures/real/<cli>/` when they land | §20 |
| **1 Skeleton + host layer** | `plugin.json`, `marketplace.json`, `scripts/lib` (options, common, `cxlib.py`), `scripts/host` (detect, pathmap, forward-wsl, wsl-entry, install-runtime), `cx-doctor`, `cx-init` + `templates/repo-bundle/`, `cx-wsl` passthrough, SessionStart policy hook (WSL, Git Bash and CRLF variants), worker shims, skill + 3 commands, tests + stubs, README, CLAUDE.md, CHANGELOG. In parallel (live, paid, by hand): the blinded Opus A/B (§6.7) and the Windows job-survival check (§14.4) | §2–§14 |
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
  Bash call (`run_in_background`), which notifies on exit (§12.2). ghcp forwards TERM to
  Copilot on a kill (billed tokens, exit 130); agy ignores TERM and is orphaned (antigravity
  `SKILL.md:319-325`).
- `claude -p` worker flags: `--model`, `--effort low|medium|high|xhigh|max`,
  `--output-format json|stream-json`, `--session-id`, `--settings <file>`, `--permission-mode`,
  `--json-schema` [verified, cli-help]. `--safe-mode` disables plugins, hooks and CLAUDE.md;
  whether it keeps OAuth is [unverified]. `--bare` needs an API key [verified].
- `claude plugin validate <dir>` checks manifests [measured: help].

### 1.2 GitHub Copilot CLI 1.0.105 and ghcp 0.1.0

- Pinned version 1.0.105 (the 1.0.106-1 prerelease lacks the `DYNAMIC_AUTO_TIERS` /
  `HYDRAFUSION_PLAN_V2` strings ghcp's Fusion path sets [strings verified; effect inferred]).
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
  through to the billed default model, so the conductor probes Copilot only when D9 reports the
  pin (§8.3 D16). ghcp-delegate passes `--disable-builtin-mcps` on every run [verified].
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

### 1.3 Grok Build 1.0.70

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
- [docs-only]: `GROK_DISABLE_AUTOUPDATER=1` and `[cli] auto_update = false` in
  `~/.grok/config.toml`; `GROK_CLAUDE_{HOOKS,SKILLS,MCPS,RULES,AGENTS}_ENABLED=false` stop grok
  importing `~/.claude`; sandbox profiles in `~/.grok/sandbox.toml` (built-ins include
  `read-only` and `workspace`); allow-rule syntax `Bash(<cmd>)`; a denied tool exits 0 with
  `permission required:` on stderr; an `-m` id missing from the catalog silently drops
  `--effort`; `-p` waits up to 10 minutes for background subagents and can exit 1 with an error
  object that has no `sessionId`; folder trust gates project config (worktrees are untrusted).

### 1.4 Antigravity: agy 1.4.12 and the antigravity plugin 0.30.2

- `agy --version` prints the version on its first line [docs-only; the plugin's doctor parses
  it that way]. `agy models` prints `<slug>\t<Label>` lines, sometimes after
  `Fetching available models...`; `--output-format json` exists since 1.1.12 with a shape that
  is [unverified]. Opus slugs `claude-opus-5-5-{low,medium,high}` (labels `Claude Opus 5.5
  (High)` etc.); nothing above `high` [docs-only]. The catalog differs per account.
- Zero-quota probes: `agy -p /model`, `-p /usage`, `-p /config`, each with
  `--output-format json </dev/null` [docs-only].
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
- Unverified (§20): whether the desktop app opens `\\wsl.localhost` projects and what `$PWD`
  then looks like; which shell runs hook commands on Windows; whether WSL's idle shutdown kills
  detached jobs after the last `wsl.exe` exits; whether wsl.exe relays stdin and Ctrl-C.

### 1.6 Sibling plugins

| Plugin id | Facts that matter | Conductor response |
|---|---|---|
| `ghcp@ghcp-for-claude-code` 0.1.0 (user's own) | SessionStart policy (`coding_policy`, on) and UserPromptSubmit nudge (`delegation_nudge`, on); PreToolUse(Bash) gate fails closed on malformed payloads; options read from user settings only | Recommend both options off (§8.3 D21); call its bins by absolute path; parse its `GHCP_*` lines |
| `antigravity@antigravity-for-claude-code` 0.30.2 | Same two options (on); policy on startup and compact; `antigravity-delegate` agent has no working gate; `timeout` default 5m returns PARTIAL (exit 12) | Recommend both options off and `timeout` 30m (§8.3 D22); deny the agent (D24) |
| `grok-build@xai-grok-build` 0.2.1 | SessionStart/SessionEnd hooks (node, no matcher); SessionEnd also fires on `/clear` and kills and erases session-tagged bridge jobs in the hook's cwd workspace; `grok-build:grok-delegate` (Sonnet, writes by default, ungated); bridge caps effort at low/medium/high, writes unsandboxed with `--always-approve`, fails on prompts over 128 KiB, calls the missing `grok import` | Never used by the conductor; doctor warns (D23) and recommends denying the agent (D24) |

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
| `bin/cx-run`, `bin/cx-job` | 2 | B | shims | §15 |
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
| `scripts/adapters/{copilot,grok,agy,claude}.sh` | 2 | W | probe / argv / run / parse | §15.2 |
| `scripts/cx-run.sh`, `scripts/cx-job.sh` | 2 | W | One task; background jobs | §15 |
| `scripts/lib/{normalize.py,ledger.py,worktree.sh,taskfile.sh,locks.sh}` | 2 | W | Result normalizer, ledger, worktrees, task rendering, pool locks | §15 |
| `scripts/cx-gate.sh`, `scripts/lib/verdict.py` | 3 | W | Gate + test-verdict parser | §16 |
| `scripts/cx-fanout.sh` | 3 | W | N tasks, failover, integration queue | §16 |
| `hooks/hooks.json`, `hooks/policy.sh`, `hooks/policy-context.json`, `hooks/policy-context-gitbash.json`, `hooks/policy-context-crlf.json` | 1 | B | SessionStart policy (WSL/Linux, Git Bash and CRLF-corruption variants) | §10 |
| `worker-shims/{claude,copilot,grok,agy,codex,gemini,cursor-agent,agent}` | 1 | W | Block agent CLIs inside workers | §11 |
| `worker-shims/{ghcp-*,agy-*,cx-*}` | 2 | W | Block sibling wrappers and conductor bins inside workers | §11, §15.6 |
| `templates/repo-bundle/{AGENTS.md,routes.json,copilot-instructions.md}` | 1 | W | Bundle templates | §9.5 |
| `templates/task.md`, `templates/cx-worker.json`, `templates/grok-sandbox.toml` | 2 | W | Task contract, Claude worker settings, grok profile | §6.4, §15 |
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
listings, `auth status` and ghcp's invalid-model probe (§8.3), the last only on the pinned
Copilot version and from an empty scratch directory (D16); agy's `-p /usage` runs only with
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
| 20 | `GATE_FAILED` | `gate_failed` | cx-gate, cx-fanout | Tests, lint, typecheck, verdict parser, diff budget or integrated gate red |
| 21 | `MODEL_MISMATCH` | `model_mismatch` | cx-run | Served model ≠ requested (incl. `GHCP_FALLBACK` on a Fusion lane, agy `init.model`) |
| 22 | `WRONG_TREE` | `wrong_tree` | cx-run (agy) | Files changed outside the task's worktree |
| 23 | `SPEC_TAMPERED` | `spec_tampered` | cx-run, cx-gate | `.conductor/task.md` hash mismatch |
| 24 | `TAMPERED` | `tampered` | cx-gate | Protected path changed (tests, lockfiles, CI, routes.json, agent config, …) |
| 25 | `ENV_FAILED` | `env_failed` | cx-run, cx-gate | The repo's `setup` command failed (not charged to the executor) |
| 26 | `VERSION_MISMATCH` | `version_mismatch` | cx-run | CLI version ≠ pin; lane refused before running |
| 27 | `PARTIAL` | `partial` | cx-run (agy) | Partial output (agy print-timeout expired with rc 0) |
| 28 | `NO_CAPACITY` | `no_capacity` | cx-run | Every eligible lane at its cap, disabled or paused |
| 40 | `FORWARD_FAILED` | — | forward-wsl.sh (also for a `wsl-entry.sh` step-1 failure) | `wsl.exe` missing, distro missing, wsl.exe failed before the command started, or wsl.exe died after it started (VM terminated) |
| 41 | `RUNTIME_MISSING` | — | forward-wsl.sh, wsl-entry.sh | No runtime copy in WSL and auto-install is off or failed; or the runtime's version/meta mismatch |
| 42 | `PATH_UNMAPPABLE` | — | pathmap.sh, wsl-entry.sh, any path option | A path has no equivalent on the other side |
| 43 | `HOST_UNSUPPORTED` | — | all | This host cannot do this (Cygwin, `exec_host=local` on Git Bash, `--host docker` before v1.1, `--windows` merge without Git Bash) |
| 44 | `CRLF_CORRUPT` | — | install-runtime.sh | A runtime file still contains CR after stripping |
| 75 | `RUNNING` | — | cx-job result/wait | Job still running |
| 126 | — (no `CX_SIGNAL`) | — | worker shims | `blocked: CX_WORKER` (§11) |
| 130 | `CANCELLED` | `cancelled` | all long-running | INT/TERM/HUP, or `cx-job kill` |

Every exit not in {0, 1, 126} prints exactly one `CX_SIGNAL` line, and it is the last stderr
line. Exit 1 prints `<prog>: <message>` (and `<prog>: try --help`) only. One exception:
`cx-wsl` (§7.7) exits with the passed-through tool's own status (0–255) and adds no `CX_*` line
to it (the tool's `GHCP_*`/`AGY_*` lines are the protocol); only its own failures (1, 13, and
40–42 from the forwarder) follow this table. In a forwarded call each failure has exactly one
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
| `CX_HOST` | `host` (`wsl\|linux\|gitbash\|docker\|macos\|cygwin\|unknown`), `hostkey` str, `distro` str\|null, `os_id` str\|null, `os_version` str\|null, `wsl_version` int\|null, `arch` str, `kernel` str | `detect.sh --emit`; `cx-doctor` (once) |
| `CX_FORWARD` | `caller` (`gitbash`), `host` (`wsl`), `distro` str (`WSL_DISTRO_NAME`, also when `wsl_distro=auto`), `cmd` str, `cwd` str\|null (WSL path), `cwd_win` str, `runtime` str (version), `installed` bool | `wsl-entry.sh`, once, before it starts the target |
| `CX_RUNTIME` | `version` str, `path` str, `changed` bool, `stripped_cr` int (files) | `install-runtime.sh` |
| `CX_DOCTOR` | `ok` int, `warn` int, `fail` int, `host` str, `caller` str, `record` str\|null (host record path), `pools` bool | `cx-doctor`, last line before any `CX_SIGNAL` |
| `CX_POOLS` | `agy` {`opus_slugs` [str], `usage` obj\|null}, `copilot` {`opus_id_enabled` bool, `review_ids` [str], `mtd_credits` num\|null, `mtd_age_days` num\|null, `ledger_month_credits` num\|null, `reserve_pct` int}, `grok` {`bulk_model_listed` bool, `claude_ids` [str]} | `cx-doctor --pools` |
| `CX_INIT` | `repo` str, `dry_run` bool, `written` [str], `unchanged` [str], `conflicts` [str], `excluded` bool, `detected` obj (§9.3) | `cx-init` |
| `CX_RESULT` | the result.json summary (§15.4) plus `path`, `host_path` | `cx-run`, `cx-job wait/result` (Phase 2) |
| `CX_DENIED` | `count` int, `kinds` [str], `hint` str | `cx-run` when the executor denied anything (Phase 2) |
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
| `CX_VERSION`, `CX_PIN_COPILOT`, `CX_PIN_GROK`, `CX_MIN_CLAUDE`, `CX_MIN_AGY`, `CX_MIN_GH_COPILOT_REVIEW` | Constants `0.1.0`, `1.0.105`, `1.0.70`, `2.1.316`, `1.1.12` (§5.4), `2.89.0` (oldest gh measured to accept `--add-reviewer @copilot`; §20 item 29) |
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
| `parse-models --cli copilot\|grok\|agy FILE` | Model ids per CLI (§8.3 D16–D18); never fails, returns `{"ids": [...], "authenticated": bool\|null, "shape": "..."}` |
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
| `policy` | `on` | Inject the conductor routing policy at SessionStart (startup, clear, compact). off/false/0/no/disabled suppress it. | boolean words | `hooks/policy.sh`, `cx-doctor` D21–D22 |
| `exec_host` | `auto` | Where executors run. `auto`: Git Bash forwards into WSL, every other host runs locally. `wsl`: always WSL. `local`: run here (refused on Git Bash). `docker` arrives in v1.1. | `auto\|wsl\|local` (v1.1: `\|docker`) | `common.sh` forwarding step 0 (every `cx-*`; lite reader on Git Bash), `cx-doctor`, `cx-run` |
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
| `grok_sandbox_profile` | `cx-workspace` | User-level grok sandbox profile (in `~/.grok/sandbox.toml`) that every grok writer runs under. | profile name | `adapters/grok.sh`, `cx-init --user-grants`, `cx-doctor` D17 |
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
(lite reader) and `hooks/policy.sh` (env) load options; adapters receive them from `cx-run`.

### 5.3 Validation

Readers validate the options they use against §5.1. An invalid value prints
`<prog>: ignoring invalid option <name>='<value>'; using '<default>'` once and the default is
used (never a hard failure: a typo must not break a session). `cx-doctor` D7 lists every invalid
value as `!`, every unknown key under the conductor's `options` as `!` (probable typo), and the
effective non-default values as info. Special cases: `exec_host=local` on Git Bash exits 43;
`exec_host=docker` before v1.1 is treated as invalid; a `worktree_root` that is relative, `/`,
`$HOME`, or inside the current repo is invalid.

### 5.4 Version pins

Pins are constants in `common.sh`, not options: Copilot `1.0.105` (exact), grok `1.0.70`
(exact), Claude Code `>= 2.1.316`, agy `>= 1.1.12` (any newer). Changing a pin is a plugin
release (version bump + CHANGELOG + the pinned test, §13). Install-level pinning is the user's:
`COPILOT_AUTO_UPDATE=false`, `GROK_DISABLE_AUTOUPDATER=1`, `[cli] auto_update = false` in
`~/.grok/config.toml`, and `AGY_CLI_DISABLE_AUTO_UPDATE=true` ([unverified] variable) exported
in WSL `~/.profile`; `cx-doctor` D14 checks them, the Phase 1 command prefixes (§12.2) and Phase 2
adapters set them on every run, and `wsl-entry.sh` exports all three for every forwarded command
(which runs `bash --noprofile --norc` and so never reads `~/.profile`, §7.4).

## 6. Routing model

This section is the single source for the skill (§12), the policy (§10.3), `/conductor:route`
and, from Phase 2, `cx-run --explain`.

### 6.1 Lanes

| Lane id | Executor and model | Pool | Writes | Phase 1 invocation | From Phase 2 |
|---|---|---|---|---|---|
| `claude` | Claude Code, `claude-opus-5-5`, effort up to `max` | Claude plan (the pool to conserve) | yes | Your own Task/Agent subagents | Same; `cx-fanout` returns unplaced tasks; `claude -p` worker optional |
| `agy-opus` | agy, `claude-opus-5-5-{medium,high}` | Ultra Claude/GPT bucket | yes (static grant) | `agy-delegate --model claude-opus-5-5-high` after registration (§12.2) | `cx-run --exec agy` (raw mode) |
| `copilot-opus` | ghcp, `claude-opus-5.5 --effort high` | Copilot credits | yes | `ghcp-delegate --model claude-opus-5.5 --effort high --write …` | `cx-run --exec copilot` |
| `copilot-fusion` | ghcp Fusion Standard/Max | Copilot credits | yes | `ghcp-delegate --fusion standard\|max`, `ghcp-handoff --tier pro` | `cx-run --exec copilot --fusion …` |
| `copilot-gpt` | ghcp, `gpt-6.1-sol` (`gpt-6-astra` critique, `gpt-6-luna` text) | Copilot credits | no | `ghcp-delegate --model gpt-6.1-sol --effort high --digest` | `cx-run --mode review --family gpt` |
| `copilot-github` | Copilot code review, `/pr fix`, ghcp `--github`, ghcp-ci-debug | Copilot credits | via PR | `gh pr edit N --add-reviewer @copilot`; `ghcp-ci-debug` without `--apply` (§12.2 step 5) | §17 |
| `grok` | grok 1.0.70, `-m grok-4.7` | xAI weekly first-party pool | yes (acceptEdits + allow-list) | raw `grok` (§12.2) | `cx-run --exec grok` |
| `agy-gemini` | agy-delegate, `Gemini 4 Argon (High)` / `gemini-3.8-flash-high` | Ultra Gemini quota (not the Claude/GPT bucket) | no | `agy-delegate --model '<label>' --digest` | `cx-run --mode review --family gemini` |
| `agy-media` | agy-media, `/antigravity:research` | Ultra Gemini quota | no | as named | unchanged |

### 6.2 Routing table

Rules for every writing task: one task, one executor, one worktree, one `cx/<id>` branch; the
task contract is `.conductor/task.md` (§6.4); the repo's `setup` runs first; the conductor
commits and gates (§6.5). "Gate" = Claude reruns the repo's checks on a clean checkout of the
conductor's commit, then the integrated gate at merge.

| Task type | Primary (lane · model · effort) | Fallback | Verification |
|---|---|---|---|
| Architecture / hard reasoning | `claude` · xhigh (max for one-way doors) | `copilot-opus` high | Claude writes the ADR; optional read-only alternatives from `agy-opus`, critique from `copilot-gpt` (`gpt-6-astra`) are input only |
| Exploration / "where is X" | `grok` · `grok-4.7` medium, read-only, `--json-schema` returning `[{file,line,why}]` | `agy-gemini` flash, read-only (register the dir) | Claude spot-checks cited lines |
| Small (<~200 lines) or judgement-heavy change | `claude` | — | Normal tests (delegating below break-even is a measured loss) |
| Debugging / root cause | `claude` owns hypotheses; `grok` high writes repro scripts, `git bisect run`, log digests | `agy-gemini` flash for logs >200k tokens | Claude sees the test fail before and pass after |
| Spec'd feature, design-sensitive | Opus lanes in `opus_lane_order` (§6.3), high, only with strong acceptance tests until the A/B | next Opus lane; Fusion Max (`ghcp-handoff --tier pro`) when both pools are drained; then `claude` | Clean-checkout tests, tamper check, diff budget, cross-family review, integrated gate |
| Spec'd feature, mechanical | `grok` · `grok-4.7` high, `--no-subagents`, `--max-turns 60` | `copilot-fusion` standard; `agy-gemini` flash high | Same gate plus the `permission required:` stderr scan |
| Bulk edits / migrations | `claude` writes a codemod; `grok` high does the remainder, one worktree per directory shard, 4–6 lanes | `copilot-fusion` standard | Full checks; grep for leftovers; Claude reads a 5–10 % sample of hunks |
| Dependency upgrades | `grok` mechanical (lockfiles exempt; only this task type may run `setup`) | `copilot-fusion` standard | Integrated gate; Claude reads the upstream changelog; `audit` when routes defines it |
| Exhaustive tests | `grok` high against a contract Claude wrote | `agy-gemini` flash high; `copilot-gpt` medium | Tests pass on current code, zero source changes, opt-in mutation threshold, Claude samples for tautologies |
| Performance | `claude` profiles and picks the hotspot; Opus lane (design) or `grok` (mechanical) implements | `claude` | `bench` before/after on the same host; tests still pass |
| First-pass review, local diff | `grok` high, read-only, `--json-schema review.schema.json`, on a read-only gate checkout + diff file | `agy-gemini` flash read-only | Claude confirms every accepted finding at file:line |
| First-pass review, GitHub PR | `copilot-github` code review | `grok` review of `gh pr diff N` | Claude adjudicates; Copilot approvals count only after explicit opt-in |
| Security review | `claude` + `copilot-gpt` (`gpt-6.1-sol` high) + CodeQL/secret scanning; never Grok alone | `agy-gemini` Argon | Claude adjudicates every finding at file:line |
| Second opinion on Opus-written code | `agy-gemini` Argon High; `copilot-gpt` also on `high_risk` paths | `grok` xhigh | Never count Opus reviewing Opus as independent (`same_family_as_conductor`) |
| Second opinion on Grok/Gemini-written code | `claude`, depth scaled by risk | — | — |
| PR / issue / CI triage | `copilot-github` (`ghcp-ci-debug`, `ghcp-delegate --github --digest`) | `grok` digest of `gh run view <id> --log-failed` | Fixes go through the same gates |
| Commit messages, PR text, changelogs | `grok` low/medium, read-only, diff in a prompt file | `copilot-gpt` (`gpt-6-luna`) | Claude edits; nothing not in the diff |
| Merge conflicts / integration fixes | `claude` | — | Integrated gate |
| UI / frontend code | `claude` designs; Opus lanes make 2–3 parallel variants (one worktree each) | `claude` subagent | Screenshots (setup [unverified]), a11y lint; Claude picks and says why |
| Media understanding | `agy-media` | — | Claude checks timestamps it relies on |
| Web-grounded research | `agy-gemini` flash high (`/antigravity:research`), Argon for synthesis | `grok` (real time, X); Claude WebSearch | Claude re-fetches load-bearing citations; ≥2 sources per claim |
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
  #1313): `Read .conductor/task.md in the working directory and do exactly what it says. Do not
  spawn subagents. End with the DIGEST: line it specifies.`
- `templates/task.md` (Phase 2; Claude writes the same structure by hand in Phase 1). Line 1 is
  machine-readable JSON in an HTML comment, the rest is prose for the executor:

```markdown
<!-- cx-task {"id": "t1", "base": "<sha>", "lane": "agy-opus", "effort": "high", "allowed_paths": ["src/feature/**"], "lockfiles": false, "commands": ["npm test"]} -->
# Task t1: <one-line goal>
## Goal
## Context
Files and pointers (paths, functions). No pasted file contents beyond short excerpts.
## Acceptance tests
- Must pass: `npm test` …
- Existing tests that must not change: `tests/foo.test.ts` …
## Allowed changes
Only paths matching: `src/feature/**`. Lockfiles: no.
## Allowed commands
Exactly: `npm test` (from .cx/routes.json).
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
| G9 | Pin versions at install level and pass model and effort explicitly every time | doctor D9–D14 | Phase 2 preflight (exit 26) |
| G10 | Fence workers in the environment: `CX_WORKER=1`, worker shims first on PATH, `GROK_CLAUDE_*_ENABLED=false`, scrubbed `COPILOT_*` and API keys (`XAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`; each would bill an API account instead of the subscription); no skip-permissions outside Docker; no conductor content in repo `CLAUDE.md` or `.claude/` | per-command env prefixes on every executor command (§12.2), never exported; shims shipped; cx-init writes nothing there | Phase 2 adapters |
| G11 | Secrets: repos with secrets use Docker lanes (v1.1) or exclude pools in routes.json (default: all pools on, U4); grok always runs the `cx-workspace` deny profile | — | Phase 2, v1.1 |

### 6.6 Hazards and how they are neutralized (no forks)

| Hazard | Neutralization | Where |
|---|---|---|
| grok-build SessionEnd kills and erases bridge jobs on `/clear` | Never use the bridge for conductor work; conductor jobs live in `$CX_HOME/jobs` | D23 warning |
| grok-build bridge: effort capped, unsandboxed `--always-approve` writes, prompt re-tokenizing, 128 KiB E2BIG, missing `grok import` | Call raw `grok` with `--prompt-file`, explicit `-m`/`--effort`, `--sandbox` profile | §12.2, adapters |
| Ungated proactive subagents `grok-build:grok-delegate`, `antigravity:antigravity-delegate` | User-level deny rules (`Task(...)` syntax [unverified] on 2.1.316) | D24; policy says don't use them |
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
| Copilot 1.0.106-1 lacks the Fusion flag strings | Pin 1.0.105 | D9, Phase 2 preflight |
| Fusion refusal → billed re-run on plain auto | `GHCP_FALLBACK` on a Fusion lane = `model_mismatch` | Phase 2 copilot adapter |
| `grok worker` registers the machine with Cursor | Never run it; warn when a `grok worker` process runs (leader processes are normal grok leader mode) | D27 |
| Executors cannot run in Claude Code's Bash sandbox: Copilot writes `~/.copilot` (exit 16), agy `~/.gemini` and `~/.antigravity` (no exit 16: shows as 2/11 or a hang), grok `~/.grok`; worktrees under `worktree_root` and `~/.conductor` writes fail too | Executor calls, `gh`, `git push` and worktree setup use the unsandboxed Bash mode; exit 16 is reported, never retried silently; agy/grok permission or EROFS text inside the sandbox → rerun unsandboxed | policy, skill, D26 |
| The Bash tool kills foreground calls at 2–10 minutes (ghcp: billed tokens, exit 130; agy: orphaned) | Every call that may exceed 9 minutes is one background Bash call, or a `ghcp-job`/`agy-job` start waited for inside one background call | §12.2, policy |
| `agy-job status` prints the job's task text, so a bare `grep running` can match it | Wait with `grep -qx '  state=running'` | §12.2 |
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
CX_ARCH CX_KERNEL`. `--shell` prints `KEY=value` lines (`printf '%s=%q\n'`, pure bash);
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

`CX_DISTRO`: `$WSL_DISTRO_NAME` on WSL, else `ID` from os-release. `CX_OS_ID`/`CX_OS_VERSION`:
os-release `ID`/`VERSION_ID` (quotes stripped, pure bash). `CX_HOSTKEY`: `wsl-<distro>`,
`linux-<hostname>`, `docker-<COMPOSE_PROJECT_NAME or hostname>`, `macos-<hostname>`,
`gitbash-<hostname>`, with every character outside `[A-Za-z0-9._-]` replaced by `_`.

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
| T3 | `\\?\UNC\…` or `//?/UNC/…` | refuse (network share) |
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
     Allowlist: `CX_WORKER`, `CX_DEBUG`, `NO_COLOR`, and `CLAUDE_PLUGIN_OPTION_<UPPER>` for the
     24 options of §5.1 (names taken from `CX_OPT_DEFAULTS`). Nothing else crosses: not PATH,
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
     as `unix:path=/run/user/<uid>/bus`;
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
   `cx-init cx-run cx-fanout cx-gate cx-wsl` → note + `CX_SIGNAL PATH_UNMAPPABLE`, exit 42
   (`cx-wsl` must never run git or a shell step in `$HOME` by accident); for `cx-doctor cx-job`
   → `cd "$HOME"`, export `CX_CALLER_CWD_UNMAPPED=1`.
6. `mapfile -d '' -t ARGV < "$FWD/argv"` (bash ≥ 4.4; empty records preserved).
7. Emit `CX_FORWARD` (§4.3; `distro` = `WSL_DISTRO_NAME`; a note instead when python3 is
   missing).
8. Run the target in its own process group and stay its parent (not `exec`):

   ```bash
   exec 3<&0
   set -m
   env -i "${KEEP[@]}" /bin/bash "$RT/scripts/$CMD.sh" "${ARGV[@]+"${ARGV[@]}"}" <&3 & tpid=$!
   set +m
   printf '%s\n' "$tpid" > "$FWD/pgid.tmp" && mv -f "$FWD/pgid.tmp" "$FWD/pgid"
   ```

   With `set -m` the background job leads its own process group (pgid = `tpid`) and its stdin
   is the explicit `<&3`, not `/dev/null` [measured 2026-11-01: bash 5 without a tty]. A
   watchdog subshell polls every 2 s: when wsl-entry.sh's parent changed (field 4 of
   `/proc/$$/stat` ≠ the `$PPID` recorded at start, i.e. the wsl.exe relay is gone) it sends
   TERM to `-$tpid` and KILL 5 s later; it exits as soon as `tpid` is gone. wsl-entry.sh traps
   INT/TERM/HUP and forwards TERM to `-$tpid`. It then waits for `tpid` (retrying while
   interrupted, as in §7.3 step 6), stops the watchdog and exits with the target's status.

### 7.5 Runtime copy (`install-runtime.sh`)

```
install-runtime.sh [--from DIR]          # normal mode (WSL / Linux)
bash -s < install-runtime.sh             # bootstrap mode: needs CX_STAGE_WIN
```

- Source: `--from DIR`, default the plugin root that contains the script; in bootstrap mode
  `wslpath -u "$CX_STAGE_WIN"` (fallback: `X:\rest` → `/mnt/x/rest`).
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
  `GHCP_COPILOT_BIN` (only if it is an executable file), else `command -v copilot`, else
  `${XDG_DATA_HOME:-$HOME/.local/share}/gh/copilot/copilot` (ghcp's order); the others =
  `command -v`. Sibling wrappers come only from `installed_plugins.json`
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
  note "run cx-doctor once from a WSL terminal or a WSL Claude session so the record captures
  your interactive PATH".
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
  lookup): `ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models` → `bin.ghcp_*`;
  `agy-delegate agy-job agy-media` → `bin.agy_*`; `agy grok gh git` → `bin.<name>`; `bash` →
  `/bin/bash` (for the shell steps of §12.2, run as `cx-wsl bash -s < FILE`). Anything else →
  exit 1 (`cx-wsl: not allowed: <tool>`). Left out on purpose: `copilot` (always through ghcp),
  `claude`, `agy-handoff` (always `--yolo`, §0.3), `ghcp-cloud`, and `cx-*` (call them
  directly; they forward themselves).
- No host record, or the entry is `null` or not executable after the §7.6 re-resolve →
  `CX_SIGNAL CLI_MISSING`, exit 13, `retry`: `cx-doctor` (run it from a WSL terminal first,
  §7.6).
- Environment: `PATH` = the directories of the resolved sibling wrappers, then the conductor's
  own `bin/` (`$RT/bin` when forwarded, else the plugin root's), then the record's `path` (so a `cx-wsl bash -s` step sees the same commands as a Bash tool in a WSL
  Claude Code session). Per-tool prefixes, identical to §12.2: `ghcp-*` → unset `COPILOT_MODEL
  COPILOT_ALLOW_ALL COPILOT_AUTO_TIER COPILOT_PROVIDER_BASE_URL`, set `CX_WORKER=1
  COPILOT_AUTO_UPDATE=false`; `agy-*`, `agy` → unset `GEMINI_API_KEY GOOGLE_API_KEY`, set
  `CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true`; `grok` → unset `XAI_API_KEY GROK_SANDBOX`,
  set `CX_WORKER=1 GROK_DISABLE_AUTOUPDATER=1 GROK_CLAUDE_{HOOKS,SKILLS,MCPS,RULES,AGENTS}_ENABLED=false`;
  `gh`, `git`, `bash`: unchanged (a shell step carries its own prefixes).
- Run: `exec env <prefix> "<abs tool>" "$@"`. The tool's stdout, stderr and exit status are the
  result; `cx-wsl` adds no `CX_*` line to them (§4.1 exception). Its own failures: 1 (usage,
  not allowed), 13 (tool missing), and from forwarding 40–42 (an unmappable cwd is 42, §7.4
  step 5).
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
| (none) | On the executor host: every D check, writes the host record. On Git Bash: W1–W7 locally, then forwards `cx-doctor <same flags> --windows-report <win path of the W results>` into WSL, which merges the W lines under a "Windows (Git Bash)" heading. If forwarding fails, Git Bash prints its W lines in plain text (no python), adds ✗ W8, and exits 40/41 |
| `--pools` | Adds §8.4 and the `CX_POOLS` line |
| `--agy-usage` | With `--pools`: also run `agy -p /usage` (documented as zero-quota but [docs-only]; opt-in until §20 item 5 is settled) |
| `--json` | The report as one JSON document on stdout (§8.7) instead of text |
| `--no-record` | Do not write the host record |
| `--host wsl` | Git Bash: forward without running W checks. WSL: run locally. Other hosts: exit 43 |
| `--host docker` | v1: exit 43 ("Docker host arrives in v1.1"); v1.1: §18.5 |
| `--windows` | Git Bash: W1–W9 only (W8 = forwarder smoke, W9 = forwarded login probes). Elsewhere: prints `! --windows checks only run from Git Bash` and exits 0 |
| `--windows-report FILE` | Internal (set by the Git Bash side; mapped with `cx_path_in`) |
| `--logins-only` | Internal (W9): D15–D19 only, with the forwarded comparison of §8.3; never writes `path` or `bin` into the host record, only its `logins.forwarded` values |
| `--login-help [cli]` | Prints §8.5 for one or every CLI; no probes; runs locally on any host (pure bash), exit 0 |
| `--install-runtime` | §7.5 (Git Bash: bootstrap into WSL; executor host: from the installed plugin) and exit with its code |
| `--record-only` | Resolution and `--version` probes only, writes the host record, prints nothing on success (exit 0, or 2) |
| `--set-copilot-mtd N` | Records the month-to-date Copilot credits you read on GitHub's billing page, with the current time, in `$CX_HOME/pools.json`; implies `--pools` |

Exit: 0 (no ✗), 4 `CHECKS_FAILED`, 1 usage, 40/41 forwarding, 43 host. The doctor writes
nothing except the host record, `pools.json` (`--set-copilot-mtd`), the runtime copy
(`--install-runtime`), the empty probe directory `$CX_HOME/probe` and temp files.

### 8.2 Output

Text on stdout: a header `conductor doctor <version>: host <host> (<distro> <os_version>,
WSL<n>), caller <caller>`, then sections Host, Runtime, Options, CLIs, Version pins, Logins (free
probes), Sibling plugins, Windows (Git Bash), Pools; one line per check, `  ✓ <text> [<ID>]`,
`  ! <text> [<ID>]`, `  ✗ <text> [<ID>]`, followed by `      fix: <command>` lines for ✗/! that
have a fix, and 6-space-indented info lines; then `Summary: <n> ✓, <n> !, <n> ✗`. Checks are
collected as TSV records (`status<TAB>id<TAB>section<TAB>text<TAB>fix`, with TAB/CR/LF in fields
replaced by spaces) and rendered once by `cxlib.py doctor-render`. stderr: `CX_HOST`, `CX_POOLS`
(with `--pools`), `CX_DOCTOR`, and `CX_SIGNAL CHECKS_FAILED` on exit 4.

Every probe runs under `cx_timeout` with stdin from `/dev/null` and with cwd `$CX_HOME/probe`, a
directory the doctor creates and keeps empty (never a repo, so no CLI loads repo-level config or
MCP servers from the user's cwd). Without `timeout`, D2 fails and the agy probes are skipped with
`!` (they can hang). The doctor must run outside Claude Code's Bash sandbox (the Copilot probe
fails with exit 16, agy and grok probes with permission errors); `commands/doctor.md` says so
and D16 explains exit 16.

### 8.3 Checks and free probes

| ID | Check | Free probe (exact) | Expected → status |
|---|---|---|---|
| D1 | Host | `scripts/host/detect.sh` | `wsl`, `linux` ✓; `docker` ! (plain Linux host in v1); `macos` ! (untested); `cygwin`/`unknown` ✗ |
| D2 | Prerequisites | `BASH_VERSINFO`; `python3 -I -V`; `command -v timeout setsid flock sha256sum git`; `git --version` | bash ≥ 4.4, `Python 3.x` ≥ 3.8, each tool present, git ≥ 2.31 (`rev-parse --path-format`) → ✓ each; else ✗; forwarded (`CX_FORWARDED=1`) with no host record or `path_source: forwarded` → info "run cx-doctor once from a WSL terminal or a WSL Claude session so the record captures your interactive PATH" (§7.6) |
| D3 | Plugin files | The INSTALLED plugin copy on this host: `CLAUDE_PLUGIN_ROOT` when set, else the conductor's `installPath` from `installed_plugins.json` (the `scope: "user"` entry first, §7.6); never `cx_root` when it lies under `$CX_HOME/runtime/` (a forwarded doctor runs from the runtime copy, which lacks `skills/` and `commands/`). Presence + exec bits of the shipped list (§13.4); `grep -l $'\r'` over it | all present, executables executable, no CR → ✓; no installed copy on this host (a Windows-only install whose runtime came from Git Bash) → info "plugin files are checked on Windows by W6". CR found → ✗ `CRLF line endings in: <files>` with the fixes below |
| D4 | Runtime copy | `$CX_HOME/runtime/<CX_VERSION>/RUNTIME_STAMP`; the top-level entries of that directory | present with this version ✓; missing ! (`cx-doctor --install-runtime`; the forwarder installs it on first use); entries other than exactly `.claude-plugin bin scripts hooks worker-shims templates` plus `RUNTIME_STAMP` (the §13.4 subset of §7.5) → ! (`cx-doctor --install-runtime`) |
| D5 | Repo location | `git rev-parse --show-toplevel` in cwd | under `/mnt/<letter>/` → ! (slow; keep repos on the WSL filesystem); else no line |
| D6 | Path mapping (WSL) | `wslpath -u 'C:\'` vs `pathmap.sh to-wsl --caller win 'C:\'`; `wslpath -w /` | equal ✓ else ✗ (automount root differs: set `CX_MNT_ROOT` or fix `/etc/wsl.conf`); the `\\wsl.localhost\` vs `\\wsl$\` prefix → info |
| D7 | Options | `cxlib.py options-check` | invalid value or unknown key → ! each; non-default values → info |
| D8 | claude | `timeout -k 5 15 claude --version </dev/null` | `^(\d+\.\d+\.\d+) \(Claude Code\)` ≥ 2.1.316 ✓; lower !; missing ! (only `claude -p` workers need it on this host) |
| D9 | copilot | `COPILOT_AUTO_UPDATE=false NO_COLOR=1 timeout -k 5 15 <copilot> --version </dev/null` | first semver = `1.0.105` ✓; other ✗ (Copilot lanes refuse with exit 26), fix `npm install -g @github/copilot@1.0.105`; missing ✗ |
| D10 | grok | `GROK_DISABLE_AUTOUPDATER=1 timeout -k 5 15 grok --version </dev/null` | `grok 1.0.70 (<hash>)` ✓; other ✗, fix `grok update --version 1.0.70`; missing ✗ |
| D11 | agy | `timeout -k 5 10 agy --version </dev/null` | first-line semver ≥ 1.1.12 ✓; 1.1.10–1.1.11 !; < 1.1.10 ✗ (ignores `--model` headless); killed ! (hang); missing ✗ |
| D12 | gh | `timeout -k 5 10 gh --version </dev/null`; `timeout -k 5 10 gh pr edit --help </dev/null` (offline, free) | `gh version X.Y.Z` ✓; missing ✗ (PRs, Copilot review and ghcp-ci-debug need it). The help text mentions `@copilot` → ✓ "can request @copilot reviews"; else ! "gh <X.Y.Z> cannot request @copilot reviews (measured on ≥ `CX_MIN_GH_COPILOT_REVIEW` = 2.89.0); upgrade gh or use the skill's REST fallback" |
| D13 | Sibling wrappers | `installed_plugins.json` → `<installPath>/bin/<name>` (the `scope: "user"` entry first, §7.6) | ghcp: `ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models ghcp-cloud`; antigravity: `agy-delegate agy-handoff agy-job agy-media`; all executable ✓; plugin missing ✗ (`claude plugin install ghcp@ghcp-for-claude-code` / `antigravity@antigravity-for-claude-code`) |
| D14 | Auto-update pins | Not forwarded: env `COPILOT_AUTO_UPDATE`, `GROK_DISABLE_AUTOUPDATER`, `AGY_CLI_DISABLE_AUTO_UPDATE`. Forwarded (`CX_FORWARDED=1`, where wsl-entry.sh sets all three itself, §7.4): grep `~/.profile`, `~/.bashrc` and `/etc/environment` for the three export lines instead. Both: `cxlib.py toml-get ~/.grok/config.toml cli auto_update` | `false`, `1`, `true`, `false` → ✓ each, else ! with fix `printf '%s\n' 'export COPILOT_AUTO_UPDATE=false' 'export GROK_DISABLE_AUTOUPDATER=1' 'export AGY_CLI_DISABLE_AUTO_UPDATE=true' >> ~/.profile` and `[cli]` / `auto_update = false` in `~/.grok/config.toml` (the agy variable is [unverified]) |
| D15 | claude login | `timeout -k 5 15 claude auth status --json </dev/null` | `"loggedIn": true` ✓; `false` or missing → ! (`claude auth login`; only `claude -p` workers need it, so it never turns the doctor red); unparseable ! |
| D16 | copilot login | Only when D9 reported exactly `CX_PIN_COPILOT`; see "D16 details" below | rc 0 ✓ (catalog kept for `--pools`); 11 ✗ (`copilot login`, unless a rule below applies); 16 ✗ (re-run this Bash call outside Claude Code's sandbox); 12 ! (timed out); 13 ✗; 2 ! (catalog unparseable); other ✗. Raw probe: stderr `from --model flag is not available` ✓; `AUTH_RE` ✗; `SANDBOX_RE` ✗; else !. D9 not exactly the pin → ! "login not probed: the free probe is only verified on 1.0.105" with D9's fix, and no Copilot process starts |
| D17 | grok login, model, profile | `GROK_DISABLE_AUTOUPDATER=1 GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_SKILLS_ENABLED=false GROK_CLAUDE_MCPS_ENABLED=false GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false timeout -k 5 30 grok models </dev/null 2>&1` | contains `You are not authenticated` ✗ (`grok login --device-auth`); rc 0, no such phrase and ≥ 1 id parsed → ✓; killed → ! (hung); anything else (non-zero rc, crash, network error, no ids) → ! with the first output line. `grok_bulk_model` among the ids (`cxlib.py parse-models --cli grok`: `^\s*[*-]\s+(\S+)` lines, else bare-id lines) ✓ else ! (an unlisted `-m` id silently drops `--effort`). `grok_sandbox_profile` defined in `~/.grok/sandbox.toml` ✓ else ! (Phase 2 `cx-init --user-grants` writes it; Phase 1 commands use `--sandbox workspace`) |
| D18 | agy login, grant | `timeout -k 5 30 agy models --output-format json </dev/null`; if rc ≠ 0 or unparseable, `timeout -k 5 30 agy models </dev/null` | ≥ 1 id ✓; 0 ids, not killed ✗ (run `agy` once in a terminal and sign in); killed ! (hang: not an auth problem, #318 or MCP startup). `~/.gemini/antigravity-cli/settings.json` `permissions.allow` contains `write_file(<worktree_root, expanded>)` ✓ else ! with the JSON to add (§12.2) |
| D19 | gh login | `timeout -k 5 15 gh auth status </dev/null` | rc 0 ✓; else ✗ (`gh auth login --web`) |
| D20 | conductor install | `installed_plugins.json`, `enabledPlugins` | installed → info with version; disabled → ! |
| D21 | ghcp policy overlap | `cxlib.py plugins`: ghcp `coding_policy`, `delegation_nudge` (saved value, else the ghcp default `on`) | with conductor `policy` on: both `off` ✓; either on ! with fix `printf '%s' '{"coding_policy":"off","delegation_nudge":"off"}' \| claude plugin configure ghcp@ghcp-for-claude-code --values-stdin`; ghcp `usage_log` empty → info |
| D22 | antigravity overlap | same for antigravity, plus `timeout` (default `5m`) | both off and timeout ≥ 30m ✓; else ! with fix `printf '%s' '{"coding_policy":"off","delegation_nudge":"off","timeout":"30m"}' \| claude plugin configure antigravity@antigravity-for-claude-code --values-stdin` |
| D23 | grok-build bridge | installed and enabled | ! "its SessionEnd hook also fires on /clear and kills and erases its session-tagged bridge jobs in the current workspace; the conductor never uses the bridge"; ! "grok-build:grok-delegate is a proactive subagent that writes by default without a gate"; info: `/grok-build:import` calls a `grok import` that 1.0.70 lacks |
| D24 | Deny rules | `settings.json` `permissions.deny` | for each installed plugin: `Task(antigravity:antigravity-delegate)` and `Task(grok-build:grok-delegate)` (the `Agent(...)` spelling is accepted too; syntax [unverified] on 2.1.316) ✓; missing ! with the JSON to add |
| D25 | Autonomy allow rules (U2) | `permissions.allow` of the settings of the host where Claude Code runs: not forwarded, the executor host's `settings.json`; forwarded (`CX_FORWARDED=1`), the Windows-side file `CX_WIN_SETTINGS` | info listing any missing rule. Executor host: `Bash(cx-doctor:*)`, `Bash(cx-init:*)`, `Bash(cx-wsl:*)`, `Bash(ghcp-delegate:*)`, `Bash(ghcp-job:*)`, `Bash(ghcp-handoff:*)`, `Bash(ghcp-ci-debug:*)`, `Bash(ghcp-models:*)`, `Bash(agy-delegate:*)`, `Bash(agy-job:*)`, `Bash(agy-media:*)`, `Bash(gh pr:*)`, `Bash(git push:*)`. Windows side: `Bash(cx-doctor:*)`, `Bash(cx-init:*)`, `Bash(cx-wsl:*)` (cx-wsl reaches every allow-listed WSL tool, §7.7). Phase 2 adds `cx-run`, `cx-job`, `cx-fanout`, `cx-gate` on both. Because the Phase 1 commands begin with their §12.2 `env -u …` prefix, the info also lists the prefixed rule for each executor wrapper (e.g. `Bash(env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false ghcp-delegate:*)`); how 2.1.316 matches such prefixes and multi-command steps is [unverified] (§20 item 36). On Windows `cx-wsl` applies the prefixes itself, so `Bash(cx-wsl:*)` covers it. Never written by the doctor. D24's deny rules stay checked on the executor host's settings, where the siblings live |
| D26 | Sandbox exclusion | `settings.json` `sandbox` (of the host where Claude Code runs, as in D25) | sandbox enabled and `sandbox.excludedCommands` [docs-only key] lacks any of `ghcp-*`, `agy-*`, `agy`, `grok`, `gh`, `git`, `copilot`, `cx-*` → info with the JSON, noting that worktree setup writes `worktree_root` (default `~/.cx-wt`) and `~/.conductor`, which the sandbox also blocks |
| D27 | Stray grok worker | `ps -eo args` | a line matching `(^\|/)grok(\.js)? worker( \|$)` → ! (`CURSOR_WORKER_MSG` in `cxlib.py`: "registers this machine with Cursor; stop it"). `grok leader` processes are normal grok leader mode and are not reported |
| D28 | Billing and account switches | env `COPILOT_MODEL`, `COPILOT_ALLOW_ALL`, `COPILOT_AUTO_TIER`, `COPILOT_PROVIDER_BASE_URL`, `GH_TOKEN`, `GITHUB_TOKEN`, `XAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY`, `ANTHROPIC_API_KEY` | each `COPILOT_*` set → ! (it can silently change the model, permissions or endpoint of every Copilot run; `COPILOT_MODEL` with an unknown id bills the default model); each API key set → ! "bills an API account instead of the subscription"; `GH_TOKEN`/`GITHUB_TOKEN` set → ! (can change the account Copilot uses), except the variable recorded as `copilot_token_env` (D16) → info "Copilot signs in through <VAR>". The Phase 1 command prefixes (§12.2) and Phase 2 adapters unset them per command |

**D3 fixes**, printed in this order (P29 asserts that no fix text contains `reset --hard` or
`rm -r --cached`: the install path is normally a copy under `~/.claude/plugins/cache/…`, not a
work tree, so `git -C <it>` would resolve an ENCLOSING repository, such as a dotfiles repo
holding `~/.claude`, and discard its uncommitted work):
1. `sed -i 's/\r$//' <files>` (the files D3 listed, absolute paths).
2. `git config --global core.autocrlf input`, then `claude plugin marketplace update
   conductor-for-claude-code && claude plugin update conductor@conductor-for-claude-code`
   (whether `update` re-copies an unchanged version is [unverified], §20 item 32; otherwise
   uninstall and reinstall the plugin).
3. Only for the marketplace clone `X=${CLAUDE_CONFIG_DIR:-~/.claude}/plugins/marketplaces/conductor-for-claude-code`,
   and only after `git -C "$X" rev-parse --show-toplevel` printed exactly `X`:
   `git -C "$X" -c core.autocrlf=input checkout-index -a -f` (rewrites tracked files from the
   index with this repo's `eol=lf` rules; HEAD and untracked files are untouched).

Reachability: a CRLF copy of the doctor's own files cannot run (§3.5), so D3 and W6 only ever
see CR in files outside the doctor's execution path; the session-start canary (§10.2) covers
the rest.

**D16 details.** Both paths run only when D9 printed exactly `CX_PIN_COPILOT`, from the empty
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
- `--pools` takes the catalog from this probe. When D16 did not probe (D9 not the pin),
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
| agy | D18's ids; with `--agy-usage` only: `timeout -k 5 45 agy -p /usage --output-format json </dev/null` (zero quota [docs-only]) | Opus slugs matching `^claude-opus-5-5-(low\|medium\|high)$`; `agy_opus_slug_tpl` at `high` listed ✓, else ✗ ("Opus not offered: Ultra must be billed directly, U1"). With `--agy-usage`: bucket percentages when the `/usage` JSON has recognizable keys, else its first 5 lines as info, and `agy_claude_floor_pct` > 0 with the Claude bucket below it → !; without it: info naming the flag |
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
| copilot | `copilot login` (device flow: open https://github.com/login/device and enter the code it prints) [docs-only] | `ghcp-models --json --refresh` (rc 0 logged in, rc 11 not; without `--refresh` a cached catalog answers) | If the keyring is unreachable through `wsl.exe` (no D-Bus): create a fine-grained PAT with the "Copilot Requests" permission and store it with `install -d -m 700 ~/.conductor/secrets && install -m 600 /dev/null ~/.conductor/secrets/copilot-token`, then paste the token into that file; Phase 2 exports it as `COPILOT_GITHUB_TOKEN` for Copilot lanes only. Avoid classic `ghp_` tokens and a stray `GH_TOKEN`/`GITHUB_TOKEN` (they can change the account Copilot uses) |
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
| W3 | `command -v cygpath`; `cygpath -w -l "$PWD"` | cygpath present ✓ else ✗; cwd under `\\wsl.localhost\` or `\\wsl$\` ✓; on a drive ! (slow `/mnt/<x>` access from WSL; prefer the WSL filesystem); other UNC ✗ (unmappable) |
| W4 | `[ -d "//wsl.localhost/$D/" ]`, else `[ -d "//wsl\$/$D/" ]` (`D` from W2: the explicit `wsl_distro`, or the default row's name) | first ✓; only the legacy prefix ! (host paths use `\\wsl.localhost`); neither ! (distro not running yet) |
| W5 | cwd on a WSL UNC path: `git rev-parse --show-toplevel` (Git for Windows) | success ✓; output contains `dubious ownership` ✗, fix = the `git config --global --add safe.directory …` line git prints (extracted verbatim), else `git config --global --add safe.directory '%(prefix)///wsl.localhost/<D>/<path>'` [unverified form]; not a repo → no line. All conductor git operations still run in WSL git |
| W6 | `grep -l $'\r'` over the Windows-side plugin files outside the Git Bash execution path (`.claude-plugin/*`, `hooks/*.json`, `templates/**`, `skills/**`, `commands/*`, `worker-shims/*`, `scripts/host/{wsl-entry,install-runtime}.sh`, `scripts/lib/*.py`); `git config --global --get core.autocrlf` | no CR ✓, else ✗ with the D3 fixes; `autocrlf=true` ! (repos touched from both sides need `* text=auto eol=lf` in `.gitattributes`; this plugin's own `eol=lf` rules already protect its git checkouts). CR in the execution path itself (`bin/`, `scripts/cx-*.sh`, `scripts/lib/*.sh`, the forwarder) means this check cannot run; the session-start canary reports that case (§10.2) |
| W7 | Windows-side `plugins/installed_plugins.json` and `settings.json` (grep after stripping a BOM and CRs, no python) | conductor installed ✓; ghcp, antigravity or grok-build installed natively ! each ("its policy would send Claude to run its wrappers in Git Bash, bypassing WSL; install it in WSL only"). The lite-read `exec_host`/`wsl_distro` are passed along; the WSL side compares them with its real parse of the same file (`CX_WIN_SETTINGS`) and reports a disagreement as ! |
| W8 | `bash scripts/host/forward-wsl.sh cx-doctor --version` (`--windows` mode only) | prints `cx-doctor <CX_VERSION>` ✓; exit 41 ✗ (runtime could not be installed); exit 40 ✗ with the decoded wsl.exe message |
| W9 | `bash scripts/host/forward-wsl.sh cx-doctor --logins-only` (`--windows` mode only) | relays the forwarded D15–D19 lines verbatim (rendered on the WSL side). A CLI that is logged out through wsl.exe while the host record's last `direct` result says logged in → ! "keyring unreachable through wsl.exe" with the token-file fix of §8.5 instead of the login command (§8.3, forwarded login comparison); no `direct` result yet → info "run cx-doctor once in a WSL terminal to compare" |

### 8.7 `--json`

```json
{"version": 1, "plugin_version": "0.1.0",
 "host": {"host": "wsl", "hostkey": "wsl-Ubuntu", "distro": "Ubuntu", "os_id": "ubuntu", "os_version": "24.04", "wsl_version": 2, "arch": "x86_64", "kernel": "..."},
 "caller": "gitbash",
 "checks": [{"id": "D9", "section": "CLIs", "status": "fail", "text": "copilot 1.0.106-1 (pinned 1.0.105)", "fix": "npm install -g @github/copilot@1.0.105"}],
 "pools": null,
 "record": "/home/me/.conductor/hosts/wsl-Ubuntu.json",
 "summary": {"ok": 24, "warn": 3, "fail": 1}}
```

`status` ∈ `ok|warn|fail|info`; `pools` holds the `CX_POOLS` payload with `--pools`; exit codes
as in text mode.

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

## 10. Hooks and the policy

### 10.1 `hooks/hooks.json`

```json
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup|clear|compact",
        "hooks": [
          { "type": "command", "command": "bash \"${CLAUDE_PLUGIN_ROOT}/hooks/policy.sh\"" }
        ]
      }
    ]
  }
}
```

No other hook events in v1: no PreToolUse gate (v1 ships no forwarder subagent; if one is ever
added, its gate must fail CLOSED for that agent type), no UserPromptSubmit nudge, no SessionEnd.
`resume` is not matched because a resumed transcript already carries the policy.

### 10.2 `hooks/policy.sh`

Bash builtins plus `cat` and `uname`; never reads stdin; always exits 0 and prints either
nothing or one whole policy JSON document. No-op when `CX_WORKER` is set to anything but empty
or `0` (a conductor worker running Claude) or when option `policy` is off. It reads options only
from `CLAUDE_PLUGIN_OPTION_POLICY` and `CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER`, which Claude Code
injects into hooks; it does not re-read settings files. It chooses one of three constant files:

| Condition (first match wins) | File | § |
|---|---|---|
| The first line of `bin/cx-doctor`, `scripts/lib/common.sh` or `scripts/host/forward-wsl.sh` ends in CR (`IFS= read -r l < "$f"; [[ $l == *$'\r' ]]`, builtins only) | `hooks/policy-context-crlf.json` | §10.5 |
| `uname -s` matches `MINGW*` or `MSYS*` (missing `uname` = no match: fail open to the default) | `hooks/policy-context-gitbash.json` | §10.4 |
| otherwise | `hooks/policy-context.json` | §10.3 |

It then replaces the placeholder `{ORDER}` with a phrase composed only of constants, so the
JSON stays valid without escaping and no option text ever reaches it: the trimmed, lowercased
`opus_lane_order` must consist of `[a-z,]` only (else the default), `claude` is appended when
missing, each distinct token maps to `agy (agy-delegate)`, `Copilot (ghcp-delegate)` or
`own subagents`, and the pieces are joined with `, then `; an unknown or repeated token gives the
default phrase `agy (agy-delegate), then Copilot (ghcp-delegate), then own subagents`. The A/B's result (§6.7) therefore takes effect at the next session
start without regenerating any file. The phrases contain no `&` (bash 5.2's
`patsub_replacement` would expand it in the replacement).

CRLF-tolerant by construction: no blank lines, and every line after the shebang either is a
comment or ends with ` #`, so a CR from a CRLF checkout lands inside a comment (the shebang does
not matter: hooks.json runs `bash <file>`). Reference text:

```bash
#!/usr/bin/env bash
# hooks/policy.sh - SessionStart (startup|clear|compact): print the conductor policy as #
# hookSpecificOutput.additionalContext (docs/DESIGN.md section 10). Bash builtins plus cat and #
# uname; never reads stdin; always exits 0 (fails open). Silent when CX_WORKER is set (a #
# conductor worker) or option policy is off. Every line ends in " #" so a CRLF copy works. #
set -uo pipefail #
case "${CX_WORKER:-}" in ""|0) ;; *) exit 0 ;; esac #
p="${CLAUDE_PLUGIN_OPTION_POLICY:-on}" #
p="${p//[[:space:]]/}" #
shopt -s nocasematch #
case "$p" in off|false|0|no|disabled) exit 0 ;; esac #
shopt -u nocasematch #
d="${BASH_SOURCE[0]%/*}" #
[ "$d" != "${BASH_SOURCE[0]}" ] || d=. #
f="$d/policy-context.json" #
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*) f="$d/policy-context-gitbash.json" ;; esac #
for c in "$d/../bin/cx-doctor" "$d/../scripts/lib/common.sh" "$d/../scripts/host/forward-wsl.sh"; do #
  l= #
  { IFS= read -r l < "$c"; } 2>/dev/null #
  case "$l" in *$'\r') f="$d/policy-context-crlf.json"; break ;; esac #
done #
o="${CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER:-}" #
o="${o//[[:space:]]/}" #
o="${o,,}" #
case "$o" in ""|*[!a-z,]*) o=agy,copilot,claude ;; esac #
case ",$o," in *,claude,*) ;; *) o="$o,claude" ;; esac #
r= #
s=, #
for x in ${o//,/ }; do #
  case "$s" in *",$x,"*) r=; break ;; esac #
  s="$s$x," #
  case "$x" in agy) y='agy (agy-delegate)' ;; copilot) y='Copilot (ghcp-delegate)' ;; claude) y='own subagents' ;; *) r=; break ;; esac #
  r="${r:+$r, then }$y" #
done #
[ -n "$r" ] || r='agy (agy-delegate), then Copilot (ghcp-delegate), then own subagents' #
[ -r "$f" ] || exit 0 #
t="$(cat -- "$f" 2>/dev/null)" || exit 0 #
k='{ORDER}' #
printf '%s\n' "${t//"$k"/$r}" #
exit 0 #
```

Each policy JSON file is `json.dumps(obj, indent=2, ensure_ascii=True) + "\n"`, generated from
the blocks of this file: `hooks/policy-context.json` and `hooks/policy-context-gitbash.json` are
`{"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": POLICY}}`, where
POLICY is the §10.3 or §10.4 block with its lines joined by `\n` and no trailing newline;
`hooks/policy-context-crlf.json` is the same shape plus a top-level `"systemMessage"` (user
visible), from the two §10.5 blocks. Tests compare every file with its block (P20) and render
every order (P21). If live check L3 shows that Windows hooks run through `cmd.exe` and WSL's
`bash.exe` (§20 item 12), the host test above must change with the hook command.

### 10.3 Policy text, WSL and Linux (final; at most 1,993 characters rendered, ASCII; limit 2,000)

Phase 1 has no `cx-run`, so the policy routes through the sibling wrappers and makes Claude load
the skill, whose commands are complete (§12.2), before the first delegation; inline commands
here are limited to the agy registration, the one step that silently goes wrong when skipped
(§6.6). When Phase 2 lands, the lane lines change to `cx-run`/`cx-fanout` and these blocks are
updated in the same commit as the JSON files. `{ORDER}` is rendered by `policy.sh` (§10.2).

<!-- policy:begin -->
```text
CONDUCTOR POLICY (replaces the ghcp and antigravity policies). You own spec, gates and merge; executors draft. Without asking you may spend Copilot credits and agy quota, push cx/* branches, open PRs and request @copilot reviews. No spend caps.
- Before your first delegation, load the conductor skill and copy its commands verbatim (env prefixes too). Run agy/agy-delegate only in a directory registered with (cd DIR && timeout -k 5 60 agy --new-project --output-format json -p /model </dev/null).
- Do yourself: architecture, one-way doors, xhigh/max reasoning, debugging hypotheses, merge conflicts, small or judgement-heavy edits.
- Opus 5.5 offload at high, strong acceptance tests required, in order: {ORDER}. One task, one worktree under option worktree_root (default ~/.cx-wt), one cx/<id> branch, contract .conductor/task.md.
- Exploration, mechanical edits, tests to your contract, reference docs, commit/PR text: raw grok (not the grok-build plugin).
- PRs, issues, CI: gh pr edit N --add-reviewer @copilot; ghcp-ci-debug without --apply; ghcp-delegate --github.
- Second opinion: Argon (agy-delegate) on Opus-written code, plus GPT (ghcp-delegate) on high-risk paths; you review Grok/Gemini code. Opus on Opus is not independent. Security: you + GPT + CodeQL, never Grok alone.
- Media, Google-grounded research, >200k-token digests: agy-media, /antigravity:research, agy-delegate --digest.
- Results are claims: exit 0 is not success (check denials, served model); rerun the tests yourself on a clean checkout; read digests, not transcripts.
- Calls that may exceed 9 minutes: one background Bash call, or ghcp-job/agy-job start; wait inside one background call, never by re-checking across turns.
- Executor calls (ghcp-*, agy-*, agy, grok, gh, git push) and worktree setup (worktree_root, ~/.conductor) run outside the Bash sandbox. Never use the antigravity-delegate agent. Help: /conductor:route, /conductor:doctor.
```
<!-- policy:end -->

### 10.4 Policy text, Windows / Git Bash (final; at most 1,997 characters rendered, ASCII; limit 2,000)

Injected when Claude Code runs in Git Bash (the Windows app). Nothing that the WSL variant names
exists on the Windows side, so every executor step goes through `cx-wsl` (§7.7); the policy also
forbids the two tempting wrong fixes (installing the siblings natively, worktrees made with Git
for Windows under `C:\Users`).

<!-- policy-gitbash:begin -->
```text
CONDUCTOR POLICY, WINDOWS (replaces sibling policies). This session runs in Git Bash; executors, logins, worktrees and git work live in WSL. You own spec, gates and merge; executors draft. Without asking you may spend Copilot credits and agy quota, push cx/* branches, open PRs and request @copilot reviews. No spend caps.
- Reach WSL only through cx-wsl: cx-wsl TOOL ARGS for ghcp-*, agy-*, agy, grok, gh, git (it adds the skill's env prefixes); for the skill's shell steps, write each step verbatim to FILE and run cx-wsl bash -s < FILE. Pass WSL paths (/home/...). Never install ghcp, antigravity or grok-build on Windows, never call wsl.exe or agent CLIs directly or make worktrees with Git for Windows.
- Before your first delegation, load the conductor skill and copy its commands verbatim. Run agy/agy-delegate only in a directory registered with (cd DIR && timeout -k 5 60 agy --new-project --output-format json -p /model </dev/null).
- Do yourself: architecture, one-way doors, xhigh/max reasoning, debugging hypotheses, merge conflicts, small or judgement-heavy edits.
- Opus 5.5 offload at high, strong acceptance tests required, in order: {ORDER}. One task, one worktree under option worktree_root (default ~/.cx-wt), one cx/<id> branch, contract .conductor/task.md.
- Raw grok: exploration, mechanical edits, tests to your contract, docs, commit/PR text. PRs and CI: gh pr edit N --add-reviewer @copilot; ghcp-ci-debug without --apply.
- Second opinion: Argon (agy-delegate) on Opus-written code, plus GPT (ghcp-delegate) on high-risk paths; Opus on Opus is not independent. Security: you + GPT + CodeQL.
- Results are claims: exit 0 is not success (check denials, served model); rerun the tests yourself on a clean checkout.
- Calls that may exceed 9 minutes: one background Bash call; wait inside it, never by re-checking across turns. cx-wsl calls run outside the Bash sandbox. Help: /conductor:route, /conductor:doctor.
```
<!-- policy-gitbash:end -->

### 10.5 CRLF notice (final; ASCII)

Injected instead of either policy when a canary file carries CR (§10.2): the conductor cannot
run, so the notice routes nothing through it and gives the fix (the D3 fixes, §8.3, without
paths, because the file is constant).

<!-- policy-crlf-context:begin -->
```text
CONDUCTOR PLUGIN DISABLED: its installed files have CRLF line endings, so its cx-* commands (cx-doctor, cx-init, cx-wsl) cannot run; they fail with errors such as env: 'bash\r': No such file or directory. Do not route work through the conductor in this session; do the work yourself. The user has been shown the fix; apply it only when the user asks: git config --global core.autocrlf input, then claude plugin marketplace update conductor-for-claude-code && claude plugin update conductor@conductor-for-claude-code (or reinstall the plugin), then cx-doctor. Never use git commands inside the plugin's install folder to repair it.
```
<!-- policy-crlf-context:end -->

<!-- policy-crlf-system:begin -->
```text
conductor: this plugin copy has CRLF line endings, so its cx-* commands cannot run and its routing policy is off. Fix: git config --global core.autocrlf input, then claude plugin marketplace update conductor-for-claude-code && claude plugin update conductor@conductor-for-claude-code (or reinstall the plugin), then run cx-doctor.
```
<!-- policy-crlf-system:end -->

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

Body sections (in this order; each cites the DESIGN § it condenses, so a §6 change updates the
skill in the same commit):
1. Roles: Claude owns spec, gates, merge; executors draft; autonomy and no caps (U2, U3).
2. Routing table (§6.2) and lanes (§6.1).
3. Opus pool order, A/B status and effort map (§6.3, §6.7); the order actually in force is the
   one the session-start policy names (rendered from `opus_lane_order`, §10.2).
4. Phase 1 recipe and exact lane commands (§12.2, verbatim): the rules for every call, then the
   headings in this order (P43): Step 1 worktree and contract; Step 2a–2d lanes; Step 3 after
   every run (commit and gate); Step 4 reviews; Step 5 GitHub; From Windows (Git Bash).
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

### 12.2 Phase 1 lane commands (exact; until `cx-run` lands)

These commands are written for a Bash tool running in WSL (today's setup), where the sibling
wrappers are on the Bash tool's PATH. From the Windows app (Git Bash) the same text runs inside
WSL through `cx-wsl` (last paragraph). Never export `CLAUDE_PLUGIN_OPTION_*` globally (both
siblings read the same names).

**Rules for every call.**
- Each Bash tool call starts a fresh shell (§1.1). Step 1 writes the task's variables to
  `$OUT/vars.sh`; every later call starts with `. "$HOME/.conductor/out/<id>/vars.sh"`.
- Any call that may run longer than 9 minutes (every executor run with `--timeout 30m`,
  `ghcp-handoff`, a slow gate) is ONE background Bash call (`run_in_background: true`; the tool
  notifies on exit), or is started with `ghcp-job start` / `agy-job start` and waited for inside
  one background call with the one-liners below. Only calls with `--timeout 9m` or less may run
  in the foreground. A foreground call killed at the Bash tool's timeout wastes the run: ghcp
  forwards TERM to Copilot (billed tokens, exit 130); agy ignores TERM and is orphaned.
- Executor calls (`ghcp-*`, `agy-*`, `agy`, `grok`, `gh`, `git push`) and every step that writes
  under `worktree_root` (default `~/.cx-wt`) or `~/.conductor` run outside Claude Code's Bash
  sandbox: Copilot writes `~/.copilot`, agy `~/.gemini` and `~/.antigravity`, grok `~/.grok`.
- Environment prefixes, written in front of each command and NEVER exported (an export would
  turn the conductor's own shell into a "worker" and would leak into unrelated commands):

  | Commands | Prefix |
  |---|---|
  | `grok` | `env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1 "${G_ENV[@]}"` (`G_ENV` from `vars.sh`: `GROK_DISABLE_AUTOUPDATER=1` and the five `GROK_CLAUDE_*_ENABLED=false`) |
  | `agy`, `agy-delegate`, `agy-job`, `agy-media` | `env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true` |
  | `ghcp-delegate`, `ghcp-job`, `ghcp-handoff`, `ghcp-ci-debug` | `env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false` |

  `XAI_API_KEY` would bill the xAI API account instead of the subscription, `GEMINI_API_KEY` /
  `GOOGLE_API_KEY` the Gemini key instead of the plan, and the `COPILOT_*` variables can change
  Copilot's model, permissions or endpoint. `GH_TOKEN`/`GITHUB_TOKEN` are left alone in Phase 1
  (they may be how Copilot signs in; D16, D28). P43 checks these prefixes in the skill.

**Once per machine (agy writes):** merge into `~/.gemini/antigravity-cli/settings.json`:

```json
{"permissions": {"allow": ["write_file(/home/<you>/.cx-wt)", "command(npm test)"]}}
```

One `command(<cmd>)` per routes command; the `write_file` grant is recursive and covers only
the worktree root (use `worktree_root`'s value when it is not the default). Never use `--yolo` /
`--dangerously-skip-permissions` outside Docker.

**Step 1: worktree and contract** (outside the sandbox; foreground unless `setup` is slow).

```bash
ID=t1
TOP=$(git rev-parse --show-toplevel); BASE=$(git -C "$TOP" rev-parse HEAD)
WT="$HOME/.cx-wt/$(basename "$TOP")-$ID"; OUT="$HOME/.conductor/out/$ID"; mkdir -p "$OUT"
P='Read .conductor/task.md in the working directory and do exactly what it says. Do not spawn subagents. End with the DIGEST: line it specifies.'
{ printf '%s=%q\n' ID "$ID" TOP "$TOP" BASE "$BASE" WT "$WT" OUT "$OUT" P "$P"
  echo 'G_ENV=(GROK_DISABLE_AUTOUPDATER=1 GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_SKILLS_ENABLED=false GROK_CLAUDE_MCPS_ENABLED=false GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false)'
} > "$OUT/vars.sh"
git -C "$TOP" worktree add -q -b "cx/$ID" "$WT" "$BASE"
EX="$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
grep -qx '/.conductor/' "$EX" 2>/dev/null || echo '/.conductor/' >> "$EX"
# write $OUT/task.md (section 6.4); then before EVERY dispatch:
mkdir -p "$WT/.conductor" && cp "$OUT/task.md" "$WT/.conductor/task.md" \
  && sha256sum "$OUT/task.md" | cut -d' ' -f1 > "$OUT/task.sha"
(cd "$WT" && npm ci --prefer-offline) > "$OUT/setup.log" 2>&1 || echo ENV_FAILED   # routes.json setup
```

`~/.cx-wt` is `worktree_root`'s default; use the option's value when `cx-doctor` D7 lists it.

**Step 2a: agy Opus (lane `agy-opus`)**, one background Bash call. Register first (free,
bounded: print mode can hang, #1313/#318), launch agy runs one at a time, snapshot the main
checkout:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
(cd "$WT" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY AGY_CLI_DISABLE_AUTO_UPDATE=true timeout -k 5 60 agy --new-project --output-format json -p /model </dev/null) > "$OUT/agy-model.json"
git -C "$TOP" status --porcelain > "$OUT/trees.before"
(cd "$WT" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true \
  agy-delegate --model claude-opus-5-5-high --dir "$WT" --timeout 30m --digest "$P") \
  > "$OUT/answer.txt" 2> "$OUT/agy.err"; echo $? > "$OUT/rc"
git -C "$TOP" status --porcelain > "$OUT/trees.after"; cmp -s "$OUT/trees.before" "$OUT/trees.after" || echo WRONG_TREE
grep -E '^AGY_(USAGE|SIGNAL)' "$OUT/agy.err"
```

`AGY_USAGE`'s `model` only echoes the requested model (§1.4): record the served model as
`unverified (wrapper)`, never as verified. Exit 15 = missing grant (report it, never retry with
`--yolo`); exit 12 = timeout or PARTIAL. Job form: `cd "$WT" && env -u GEMINI_API_KEY -u
GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true agy-job start --model
claude-opus-5-5-high --dir "$WT" --timeout 30m --digest "$P"` prints the job id `J`; wait in one
background call with
`while agy-job status "$J" | grep -qx '  state=running'; do sleep 15; done; agy-job result "$J"; cat "${ANTIGRAVITY_JOBS:-$HOME/.antigravity-jobs}/$J/rc"`
(`agy-job result` exits 0 whatever the job's rc; the `rc` file is the verdict).

Raw arm (served model verified; preferred for the A/B, §6.7; flags [docs-only] until `agy
--help` is captured, §20 item 4; the init event shape is [unverified], item 6). Same
registration and tree snapshots, then, as one background call:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
(cd "$WT" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true \
  timeout -k 15s 35m agy --model claude-opus-5-5-high --add-dir "$WT" --print-timeout 30m \
  --output-format stream-json -p "$P" </dev/null) > "$OUT/agy.ndjson" 2> "$OUT/agy.err"; echo $? > "$OUT/rc"
python3 -I - "$OUT/agy.ndjson" <<'PY'
import json, sys
served = None
for line in open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n"):
    try:
        ev = json.loads(line)
    except ValueError:
        continue
    if isinstance(ev, dict) and (ev.get("type") == "init" or "init" in ev):
        body = ev.get("init") if isinstance(ev.get("init"), dict) else ev
        served = body.get("model") or (body.get("data") or {}).get("model")
        break
print("served model:", served if served else "unknown (no init event with a model)")
PY
```

The served model must be `claude-opus-5-5-high`; anything else (or `unknown`) is a model
mismatch for the A/B record. `timeout -k 15s 35m` bounds the #1313 hang after the result.

**Step 2b: Copilot Opus (lane `copilot-opus`)**, one background Bash call:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false \
  ghcp-delegate --model claude-opus-5.5 --effort high --dir "$WT" --write --allow-shell 'npm test' \
  --timeout 30m --digest "$P" > "$OUT/answer.txt" 2> "$OUT/ghcp.err"; echo $? > "$OUT/rc"
grep -E '^GHCP_(SESSION|DENIED|NOTE|USAGE|SIGNAL|FALLBACK)' "$OUT/ghcp.err"
```

One `--allow-shell` per routes command. `GHCP_USAGE` `models_used[].model` must be
`claude-opus-5.5`; any `GHCP_DENIED` of kind `write` fails the run; ~32k output tokens with an
empty answer is the #5149 signature. Job form: the same prefix and options with `ghcp-job start`
instead of `ghcp-delegate` print `JOB_ID <id>`; wait in one background call with
`while ghcp-job status "$J" | grep -qx running; do sleep 15; done; ghcp-job result "$J"` (exit =
the job's rc). Mechanical fallback (same prefix, background): `ghcp-delegate --fusion standard
--write --allow-shell 'npm test' --dir "$WT" --timeout 30m --digest "$P"`; both Opus pools
drained (same prefix, background): `ghcp-handoff --dir "$WT" --tier pro --test-cmd 'npm test'
--timeout 30m "$P"` (Fusion Max; `--test-cmd` is the routes `test` command, so ghcp-handoff
does not detect its own). A `GHCP_FALLBACK` line on a Fusion lane means the answer came from a
billed plain-`auto` re-run: treat it as a model mismatch.

**Step 2c: Grok (lane `grok`).** Raw CLI, never the bridge plugin; one background Bash call:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
UUID=$(cat /proc/sys/kernel/random/uuid); printf '%s\n' "$P" > "$WT/.conductor/prompt.txt"
env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1 "${G_ENV[@]}" grok --prompt-file "$WT/.conductor/prompt.txt" \
  -m grok-4.7 --effort high --cwd "$WT" -s "$UUID" --output-format json --sandbox workspace \
  --permission-mode acceptEdits --allow 'Bash(npm test)' --allow 'Bash(git status)' --allow 'Bash(git diff)' \
  --no-subagents --max-turns 60 </dev/null > "$OUT/grok.json" 2> "$OUT/grok.err"; echo $? > "$OUT/rc"
grep -n 'permission required:' "$OUT/grok.err" && echo DENIED     # a hit means denied, even with rc 0
env -u XAI_API_KEY "${G_ENV[@]}" grok usage "$UUID"
```

Read-only exploration (same prefix): `env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1
"${G_ENV[@]}" grok -p "<question>" -m grok-4.7 --effort medium --cwd "$TOP" --sandbox read-only
--always-approve --no-subagents --output-format json
--json-schema '{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"why":{"type":"string"}},"required":["file","line","why"]}}'
</dev/null`. Commit/PR text: the diff in a prompt file, `--effort low --sandbox read-only
--always-approve --no-subagents`. `--sandbox workspace` becomes `cx-workspace` once Phase 2
writes that profile; `--always-approve` is only ever combined with `read-only` outside Docker.
The `Bash(<cmd>)` rule syntax and the `workspace` profile name are [docs-only].

**Step 2d: Claude (lane `claude`).** A Task/Agent subagent with prompt `$P`, told to work only
in `$WT`.

**Step 3: after every run (the conductor commits; the gate never runs in `$WT`).** Background
when the checks are slow:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
[ "$(sha256sum "$WT/.conductor/task.md" | cut -d' ' -f1)" = "$(cat "$OUT/task.sha")" ] || echo SPEC_TAMPERED
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || git -C "$WT" reset -q --soft "$BASE"   # squash executor commits
git -C "$WT" add -A
git -C "$WT" diff --cached --quiet && echo NO_CHANGES                                  # empty result: status empty
git -C "$WT" diff --cached --stat "$BASE"; git -C "$WT" diff --cached --name-only "$BASE"   # tamper review (G4)
git -C "$WT" commit -qm "cx/$ID: <executor>/<served model>"
G="$HOME/.conductor/gate/$ID.1"; git -C "$TOP" worktree add -q --detach "$G" "cx/$ID"
(cd "$G" && npm ci --prefer-offline && npm test && npm run lint && npx tsc --noEmit)   # routes setup + commands
```

The served model in the commit message is the verified one, or `unverified (wrapper)` (step
2a). Failover to the next lane: `git -C "$WT" reset -q --hard "$BASE" && git -C "$WT" clean
-ffdxq -e /.conductor/` (inside the conductor's own worktree only), re-copy `task.md` (step 1),
dispatch. Never let two lanes write to one worktree.

**Step 4: reviews (read-only, on the same gate checkout `$G`; only after step 3 committed).**
No second `worktree add`: step 3 created `$G`. Each reviewer is one background call:

```bash
. "$HOME/.conductor/out/t1/vars.sh"; G="$HOME/.conductor/gate/$ID.1"
git -C "$TOP" diff "$BASE" "cx/$ID" > "$OUT/change.diff"
[ -s "$OUT/change.diff" ] || { echo EMPTY_DIFF; exit 3; }     # nothing committed: do not review
R="Review the change in $OUT/change.diff against the code in this checkout. List findings as file:line - severity - issue, most severe first. Do not edit files."
(cd "$G" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY AGY_CLI_DISABLE_AUTO_UPDATE=true timeout -k 5 60 agy --new-project --output-format json -p /model </dev/null) > /dev/null
(cd "$G" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true \
  agy-delegate --model 'Gemini 4 Argon (High)' --dir "$G" --dir "$OUT" --timeout 30m --digest "$R")
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false \
  ghcp-delegate --model gpt-6.1-sol --effort high --dir "$G" --add-dir "$OUT" --digest "$R"     # high_risk paths
```

The model names are the defaults of `review_model_gemini` and `review_model_gpt` (§5.1). Clean
up gate checkouts with `git -C "$TOP" worktree remove --force "$G"` once the reviews are in.

**Step 5: GitHub (only after a green gate).** `git -C "$WT" push -u origin "cx/$ID"`; `gh pr
create --head "cx/$ID" --title … --body-file …`; `gh pr edit <N> --add-reviewer @copilot` (needs
a gh whose `gh pr edit --help` mentions `@copilot`, D12; otherwise the REST fallback
`gh api -X POST "repos/{owner}/{repo}/pulls/<N>/requested_reviewers" -f 'reviewers[]=copilot-pull-request-reviewer[bot]'`
[unverified], §20 item 30). CI failures: `ghcp-ci-debug --pr <N>` or `--run <id>` (with the
ghcp prefix) WITHOUT `--apply`; `--apply` creates and switches to a branch in its `--dir`, whose
default is the cwd (normally the user's main checkout), so use it only as `--apply --dir "$WT"`
inside a conductor worktree.

**From Windows (Git Bash).** Every step above runs inside WSL through `cx-wsl` (§7.7); nothing
runs on the Windows side, and nothing is installed there. Write the step text verbatim (its
`vars.sh` line included) to a Windows-side scratch file with the Write tool and run
`cx-wsl bash -s < FILE`, as one background Bash call when the step is long; in step 1 the
`task.md` text goes into the step as a quoted heredoc (`cat > "$OUT/task.md" <<'TASK'` …
`TASK`). Single commands may go direct: `cx-wsl ghcp-job status <id>`, `cx-wsl gh pr view <N>`,
`cx-wsl git -C /home/<you>/<repo> status` (`cx-wsl` adds the prefixes above for `ghcp-*`,
`agy-*`, `agy` and `grok`). Paths inside steps and arguments are WSL paths (`$HOME`, `~/.cx-wt`,
`/home/<you>/…`), never `C:\…` or `/c/…`. Read results with `cx-wsl bash -c 'cat "$1"' _
/home/<you>/.conductor/out/<id>/answer.txt`. `cx-wsl` calls run outside the sandbox.

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
  CHANGELOG heading, P2); **pin bump** (`CX_PIN_*`, §1, §5.4, D9–D11, README); **duplicated
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
`hooks/policy-context-gitbash.json`, `hooks/policy-context-crlf.json`, the 8 `worker-shims/*`,
`templates/repo-bundle/AGENTS.md`, `templates/repo-bundle/routes.json`,
`templates/repo-bundle/copilot-instructions.md`, `skills/conductor/SKILL.md`,
`commands/doctor.md`, `commands/init.md`, `commands/route.md`. Executable: `bin/*`,
`scripts/*.sh`, `scripts/host/*.sh`, `hooks/policy.sh`, `worker-shims/*`. The runtime copy
(§7.5) holds the subset under `.claude-plugin bin scripts hooks worker-shims templates`; D3
checks the installed copy against the whole list, D4 the runtime against that subset.

## 14. Phase 1 tests

### 14.1 Harness and isolation

`bash tests/run-tests.sh` runs everything, needs no network, spends nothing, and runs inside
Claude Code's Bash sandbox. Style as ghcp's: `check "[P7] name" cmd args…`, `section`, PASS /
FAIL / SKIP counters, non-zero exit on any FAIL, `bash tests/run-tests.sh 2>&1 | grep -v '^PASS  '`
for failures only. Tags: `[P1]`–`[P45]` (plus `[P22b]`) are the Phase 1 cases below (later phases use `[A…]`,
`[G…]`, `[W…]`, `[K…]`); `[X]` is extra coverage.

Isolation (set before any case): one `TMP=$(mktemp -d)`; `HOME=$TMP/home`,
`CLAUDE_CONFIG_DIR=$TMP/claude-config`, `XDG_CACHE_HOME`, `XDG_DATA_HOME`, `XDG_CONFIG_HOME`,
`TMPDIR`, `CX_HOME=$HOME/.conductor` all under it; `CX_DETECT_ROOT=$TMP/root` (an empty fake
root, so the build container's own `/.dockerenv` cannot leak in); unset every
`CLAUDE_PLUGIN_OPTION_*`, `STUB_*`, `CX_*` (other than those just set), `GHCP_*`, `COPILOT_*`,
`GROK_*`, `AGY_*`, `WSL_DISTRO_NAME`, `WSL_INTEROP`, `WSLENV`, `MSYSTEM`, `container`,
`CLAUDE_PLUGIN_ROOT`, `GH_TOKEN`, `GITHUB_TOKEN`; `GHCP_COPILOT_BIN=$ROOT/tests/stubs/copilot`;
`PATH=$ROOT/tests/stubs:$REAL_PATH`; git identity variables and `GIT_CONFIG_NOSYSTEM=1`; the
suite runs from a scratch cwd. A fake Claude config is generated per section:
`installed_plugins.json` pointing at fake plugin install dirs the suite creates under
`$TMP/plugins/{ghcp,antigravity}/bin/` (two-line scripts that `exec` `tests/stubs/ghcp-models`,
or `tests/stubs/billable` for every other wrapper) and a `settings.json` built from
`tests/fixtures/settings/`.

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
| `wslpath` | `-u 'X:\rest'` → `$CX_MNT_ROOT<x>/rest`; `-w /p` → `\\wsl.localhost\$WSL_DISTRO_NAME\p`; `STUB_WSLPATH_ROOT` overrides the mount root (mismatch test) |
| `copilot` | `--version` → `GitHub Copilot CLI ${STUB_COPILOT_VERSION:-1.0.105}.`; the doctor probe (`-p . --model __cx_doctor_probe__ …`) → the real stderr shape for `STUB_COPILOT_AUTH=ok\|none\|rofs` with rc 1; anything else billable. Logs its cwd (`cwd=<pwd>`) and whether `GH_TOKEN`/`GITHUB_TOKEN` were set; `STUB_COPILOT_TOKEN_ONLY=GH_TOKEN` → the probe reports logged in only when that variable is set |
| `grok` | `--version` → `grok ${STUB_GROK_VERSION:-1.0.70} (f50904eaee6c)`; `models` → `fixtures/grok-models-auth.txt` when `STUB_GROK_AUTH=1`, else the verified unauthenticated text, rc `${STUB_GROK_MODELS_RC:-0}` (`STUB_GROK_MODELS_FAIL=network` → one error line, no ids, rc 1); `usage` → fixture; prompts billable; `STUB_ENV_FILE` receives its environment (P45 prefix checks) |
| `agy` | `--version` → `${STUB_AGY_VERSION:-1.4.12}`; `models [--output-format json]` → fixtures, empty when `STUB_AGY_AUTH=0`, `sleep 60` when `STUB_AGY_HANG=1`; `-p /usage\|/model\|/config` → fixture JSON; other prompts billable |
| `claude` | `--version` → `${STUB_CLAUDE_VERSION:-2.1.316} (Claude Code)`; `auth status --json` → `{"loggedIn": ${STUB_CLAUDE_LOGGED_IN:-true}, "authMethod": "oauth_token"}`; `-p` billable. (P3 uses the real `claude` from `REAL_PATH`.) |
| `gh` | `--version` → `gh version ${STUB_GH_VERSION:-2.89.0} (2026-03-26)`; `pr edit --help` → help text that mentions `@copilot` unless `STUB_GH_NO_COPILOT=1`; `auth status` rc `${STUB_GH_AUTH:-0}` |
| `gitbash/git` (only on the simulated Git Bash PATH) | `rev-parse --show-toplevel` with `STUB_GIT_DUBIOUS=1` → Git for Windows' dubious-ownership message including a `git config --global --add safe.directory '…'` line, rc 128; otherwise the real git |
| `ghcp-models` | `--json` → `fixtures/ghcp-models.json` rc 0; `STUB_GHCP_MODELS=auth\|sandbox\|timeout\|catalog` → rc 11\|16\|12\|2; exits 98 unless `GHCP_COPILOT_BIN` is an absolute path; logs whether `--refresh` was given and its cwd. Reached only through the fake ghcp install dir (the doctor resolves wrappers from `installed_plugins.json`) |
| `billable` | Logs `BILLABLE` and its own name, exits 99 (stands in for every other sibling wrapper) |

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
| P7 | §5.2 | `cx_opt_lite` finds `wsl_distro` inside the conductor's `pluginConfigs` entry; ignores the same key in an earlier plugin block AND in a later foreign block when `enabledPlugins` lists the conductor first (`settings/enabled-first.json`); handles a leading BOM and CRLF; braces inside strings do not end the span; rejects a value with a space |
| P8 | §4.2 | `cx_emit`: one line, `CX_NAME ` prefix, default separators, `ensure_ascii`, typed keys; `reason` sanitizing (CR/LF/TAB/U+2028 collapse, 200-char cut ending `...`) |
| P9 | §4.2 | `cx_signal` with no python3 on PATH: the hand-built line parses as JSON, holds only constant text, is the last stderr line, and the exit code is the given one |
| P10 | §4.1 | `cx_status_for_exit` covers every row; each script header lists exactly the codes the script can return |
| P11 | §7.2 | Every row of the pathmap example table, in CLI and sourced form; refusals exit 42 with a `pathmap:` reason; `--mnt-root` and `/etc/wsl.conf` under `CX_DETECT_ROOT` honoured; with no `--distro`, `WSL_DISTRO_NAME` or `CX_WSL_DISTRO`, T6 and `to-win /home/me` refuse with "distro unknown" while drive mappings still work |
| P12 | §7.1 | Detection matrix: `MINGW64_NT…`/`MSYS_NT…` → gitbash; `CYGWIN_NT…` → cygwin; `Darwin` → macos; Linux + `WSL_DISTRO_NAME` + `6.6.87.2-microsoft-standard-WSL2` → wsl/2; Linux + `WSLInterop` only → wsl; `4.4.0-19041-Microsoft` → wsl/1; Linux + `.dockerenv` + WSL2 kernel → docker; cgroup `docker` → docker; plain → linux; os-release quoting; hostkey sanitizing |
| P13 | §7.3, §7.7 | Argv fidelity through the forwarder: simulated Git Bash runs `bin/cx-init --dry-run --json --test "$WEIRD"` where WEIRD holds spaces, `"`, `'`, `$HOME`, backslashes, a newline, `é—✓` and a leading `-`; `detected.test` equals it byte for byte; `--lint ''` arrives as an empty argument (→ null); with `CX_DEBUG=1` the kept `argv` file equals `printf '%s\0'` of the arguments; `cx-wsl bash -c 'printf "%s\0" "$@"' _ "$WEIRD" ''` prints exactly those two arguments; every Windows path in `meta` came from `cygpath -w -l` |
| P14 | §7.3, §7.4 | Env allowlist: with `CX_DEBUG=1 CLAUDE_PLUGIN_OPTION_POLICY=off GH_TOKEN=x COPILOT_MODEL=y FOO=z` the kept `env` file holds only `CX_DEBUG` and `CLAUDE_PLUGIN_OPTION_POLICY`; the stub logged only `CX_FWD_WIN` crossing via `WSLENV` |
| P15 | §7.3, §7.4 | cwd mapping: a drive cwd and a `\\wsl.localhost\Ubuntu\…` cwd reach the same repo on the WSL side (`CX_FORWARD.cwd`); a `\\server\share` cwd → `cx-init` and `cx-wsl` exit 42 (one `CX_SIGNAL`, from wsl-entry.sh), `cx-doctor` runs from `$HOME` with `cwd: null`; a `TMPDIR` with a short-name component (`JOHNSM~1`, `STUB_CYGPATH_SHORT`) still maps because the forwarder passed `-l` |
| P16 | §7.3, §7.4 | Exit propagation (forwarded `cx-init` 5, `cx-doctor` 4 and 0, `cx-wsl bash -c 'exit 37'` 37 with no `CX_*` line); no `wsl.exe` → 40 with the constant reason; `STUB_WSL_FAIL=nodistro` with `STUB_WSL_IGNORE_UTF8=1` → 40 and the note shows the decoded English message; `STUB_WSL_FAIL=crash` (after `started`) → 40 `FORWARD_FAILED`; wsl-entry.sh version mismatch → 41; in every failure exactly one `CX_SIGNAL` line in total; invalid `wsl_distro` → 40 without invoking wsl.exe; `wsl_distro=auto` → the wsl.exe argv has no `-d` and `CX_FORWARD.distro` is the stub's default; stdin reaches the child (`printf x \| cx-wsl bash -c 'cat'` prints `x`); INT during a forwarded call whose WSL-side child sleeps → 130, and the Linux-side child (and its process group) is gone within 6 s |
| P17 | §7.3, §7.5 | Runtime auto-install: an empty WSL home → the first call installs (`installed: true`, stamp, `current` link) and succeeds; the second call does not reinstall; `CX_NO_AUTO_INSTALL=1` → 41 (one `CX_SIGNAL`, from the forwarder) |
| P18 | §7.5 | `install-runtime.sh`: copies only the six directories; exec bits; a mid-line CR → exit 44 and the old runtime stays; identical reinstall → `changed: false`; a changed source replaces the copy and moves `current`; two concurrent installs of one source → one `changed: true`, one `changed: false`, a single clean tree (no copy nested inside `runtime/<version>/`) |
| P19 | §7.4, §7.6 | WSL-side environment: the host record's `.path` is used when present; the fallback has `$HOME/.local/bin`, `/snap/bin`, `$HOME/.bun/bin`, `$HOME/.cargo/bin` and no `/mnt/` entry although the stub appended `/mnt/c/Windows/System32`; `DBUS_SESSION_BUS_ADDRESS` and `XDG_RUNTIME_DIR` from the stub survive; the three auto-update pins are set; a forwarded doctor never replaces an `interactive` record `path`; host-record wrappers come from the `scope: "user"` entry when a project entry is listed first, and a moved `installPath` is re-resolved once |
| P20 | §10.2–§10.5 | Each of the three policy JSON files parses; `hookEventName` = `SessionStart`; each `additionalContext` equals its block in this file (`policy`, `policy-gitbash`, `policy-crlf-context`), and the CRLF file's `systemMessage` equals `policy-crlf-system`; all ASCII; the WSL and Git Bash texts are ≤ 2000 characters with the longest `{ORDER}` phrase substituted, contain `--new-project` and the skill-first rule (`load the conductor skill`), and the Git Bash text contains `cx-wsl` |
| P21 | §10.2 | `policy.sh` prints exactly the selected file with `{ORDER}` replaced and never prints `{ORDER}`; orders: unset → `agy (agy-delegate), then Copilot (ghcp-delegate), then own subagents`; `copilot,agy` and ` COPILOT, AGY ` → Copilot first; `copilot` → `Copilot (ghcp-delegate), then own subagents`; `agy,agy`, `bogus`, `*` → the default phrase; `STUB_UNAME_S=MINGW64_NT-10.0-26100` (and `MSYS_NT-…`) → the Git Bash variant; `CLAUDE_PLUGIN_OPTION_POLICY` = `off`, `OFF`, ` no `, `disabled`, `0`, `false` → nothing; `CX_WORKER=1` → nothing, `CX_WORKER=0` → printed; stdin `not json` or closed → exit 0 with output; missing JSON file → exit 0, nothing; stderr empty every time; works with a PATH holding only `bash` and `cat` (no `uname`: the WSL variant) |
| P22 | §10.2, §3.5 | A CRLF-converted copy of `hooks/` run as `bash <copy>/hooks/policy.sh`: exit 0, empty stderr, stdout parses with the same `additionalContext`; with the option off, nothing |
| P22b | §10.2, §3.5 | A fully CRLF-converted copy of the plugin (every file) run as `bash <copy>/hooks/policy.sh`: exit 0, empty stderr, stdout parses and is the CRLF notice (`systemMessage` present, `additionalContext` = `policy-crlf-context`); the same with only `bin/cx-doctor` converted; with the option off, nothing |
| P23 | §10.1 | `hooks.json` parses; only `SessionStart`; matcher exactly `startup\|clear\|compact`; command exactly `bash "${CLAUDE_PLUGIN_ROOT}/hooks/policy.sh"`; the file exists |
| P24 | §11 | Exactly the 8 shims; each a regular executable LF file; with arguments, stdin and env: stdout empty, stderr exactly `blocked: CX_WORKER\n`, exit 126; `PATH="worker-shims:$PATH" CX_WORKER=1 claude -p x` exits 126 and the claude stub logged nothing |
| P25 | §8.1–§8.3, §7.6 | All-green doctor (stubs ok, fake plugins, sibling options off, deny rules, pins exported, grok config) → exit 0, no ✗, `CX_DOCTOR.fail` 0; host record with absolute bins (wrappers from the fake installPaths) and a `.path` without `/mnt/`; `--no-record` writes nothing |
| P26 | §8.3 | One failure at a time: copilot `1.0.106-1` → ✗ D9, ! D16 "login not probed", exit 4, `CX_SIGNAL CHECKS_FAILED`, and neither the copilot stub saw `-p` nor ghcp-models ran; grok `1.0.73` → ✗ D10; claude `2.1.300` → ! D8 (exit 0); agy `1.1.9` → ✗ D11; grok unauthenticated → ✗ D17 naming `grok login --device-auth`; grok models rc 1 with a network error and no ids → ! D17 with that line (not ✓); ghcp-models rc 11 / 16 → ✗ D16 with the login / sandbox text; ghcp absent → the copilot stub saw `--model __cx_doctor_probe__` and `--disable-builtin-mcps`; agy models empty → ✗ D18; agy hang (with `CX_PROBE_TIMEOUT=2`) → ! D18 "hung"; `loggedIn: false` → ! D15 (exit 0); gh auth rc 1 → ✗ D19; gh without `@copilot` in `pr edit --help` → ! D12 |
| P27 | §8.3 | Siblings: ghcp options unset (default on) → ! D21 with the exact `claude plugin configure` command; both off → ✓; antigravity default timeout → ! D22; grok-build installed → both D23 warnings; deny rules missing → ! D24, the `Agent(...)` spelling accepted; allow rules missing → D25 info; forwarded (`CX_FORWARDED=1`) → D25 reads `CX_WIN_SETTINGS` and lists `Bash(cx-wsl:*)`; conductor `policy=off` → no overlap warning; a `grok leader` process → no D27 line, a `grok worker` process → ! D27 |
| P28 | §8.3 | `COPILOT_AUTO_UPDATE` unset → ! D14, set → ✓; forwarded with the three exports present in `~/.profile` → ✓ D14 although the env was not read from it; grok `[cli] auto_update = false` → ✓; `COPILOT_MODEL`, `GH_TOKEN`, `XAI_API_KEY`, `GEMINI_API_KEY`, `GOOGLE_API_KEY` or `ANTHROPIC_API_KEY` set → ! D28 each (API keys with "bills an API account instead of the subscription"); Copilot logged in only through `GH_TOKEN` (`STUB_COPILOT_TOKEN_ONLY`) → ✓ D16, `copilot_token_env` recorded, D28 info for it |
| P29 | §8.3 | A plugin copy with a CRLF `hooks/policy.sh` → ✗ D3 naming the file with the sed fix and the autocrlf + update fix; no fix text anywhere in the doctor contains `reset --hard` or `rm -r --cached`; a fake marketplace clone that is not its own git toplevel (inside an enclosing repo) → no git-based fix printed; a real toplevel clone → the `checkout-index` fix; a forwarded doctor running from the runtime copy checks the installed copy, not the runtime (no ✗ D3 for `skills/` or `commands/`) |
| P30 | §3.7 | Across the suite no stub logged `BILLABLE`; copilot saw only `--version` or the doctor probe; grok only `--version` and `models`; agy only `--version`, `models`, and `-p /usage` when `--agy-usage` was given; claude only `--version` and `auth status`; ghcp-models always got an absolute `GHCP_COPILOT_BIN` and `--refresh` for D16; every copilot and ghcp-models probe ran with cwd `$CX_HOME/probe` |
| P31 | §8.4 | `--pools`: agy Opus slugs from the fixture; `claude-opus-5.5` enabled → ✓, removed from the fixture → ✗; `--set-copilot-mtd 1234` writes `pools.json`; an old or missing figure → info with `copilot_reserve_pct=0` and ! with `copilot_reserve_pct=10`; reserve 0 reported as off; D16 not probed (unpinned copilot) → the copilot pool comes from ghcp's cache file with its age and ghcp-models never runs; `--agy-usage` adds exactly one `agy -p /usage` call and none without it; `CX_POOLS` parses |
| P32 | §8.5 | `--login-help` for each CLI contains its exact command (`copilot login`, `grok login --device-auth`, `agy`, `gh auth login --web`, `claude auth login`); runs without python3; the Git Bash variant starts with the WSL-terminal sentence; no stub invoked; exit 0 |
| P33 | §8.7 | `--json` parses, matches §8.7, statuses in the enum, same exit as text mode |
| P34 | §8.6 | Simulated Git Bash without python3: W1–W9 with stubs (W1 fails when `timeout` resolves to a non-GNU stub; distro list from the UTF-16LE fixture with a multi-word STATE; W2 with `wsl_distro=auto` takes the `*` row, an explicit missing distro ✗ W2; drive cwd ! W3; dubious ownership ✗ W5 with git's own suggested command; CR in `templates/` of the Windows-side copy ✗ W6; natively installed ghcp in the fake `%USERPROFILE%\.claude` ! W7; W8 prints `cx-doctor 0.1.0`; W9 with a `direct` logged-in record and a forwarded logged-out probe → ! "keyring unreachable through wsl.exe" with the token-file fix); default Git Bash `cx-doctor` shows a "Windows (Git Bash)" section in the forwarded report and returns the WSL side's exit |
| P35 | §9.3 | Detection matrix on generated repos: npm (lock / no lock → `npm install --no-audit --no-fund --no-package-lock` / default test script), pnpm (lockfile, `packageManager`), yarn classic, yarn berry, bun (`bun.lock` → setup null with a note, `bun run test`), python plain with pytest+ruff+mypy, uv, poetry, go with and without golangci config, rust with a tracked `Cargo.lock` (`cargo fetch --locked`) and without (setup null with a note), Makefile only, `tests/run-tests.sh` only, node+go (joined with ` && `), nothing; after each detected `setup` runs in a fresh worktree, `git status --porcelain` is empty (where the tool is installed; SKIP otherwise) |
| P36 | §9.1, §9.2, §9.4, §9.5 | Write rules: fresh repo → 3 files, exit 0, `/.conductor/` once in `info/exclude` after two runs; rerun → all `same`; edited block → exit 5, nothing written; `--force` replaces only the block (outside text byte-identical); an `AGENTS.md` without a block → `update` without `--force`, block appended, earlier text byte-identical; `--only agents --force` never touches an edited `routes.json` (`skipped`); JSON-equal routes.json with other whitespace → `same`; `--dry-run` writes nothing, same exit; not a repo → 1; subdirectory → toplevel; `CLAUDE.md`, `.claude/`, `.gitignore`, `.gitattributes` checksums unchanged; routes.json keys and order per §9.4, pools all true; the AGENTS.md block contains the sentence `If \`.conductor/task.md\` exists in your working directory (you are a conductor worker):` and no worker-only rule above it; copilot-instructions.md says the worker-only rules do not apply to Copilot coding agent tasks assigned on GitHub; the Setup line reads `Setup (run by the caller before you start; do not run it unless your task says so):` |
| P37 | §9.1 | Notes for a missing `.gitattributes` and `core.autocrlf=true` |
| P38 | §3 | Every `*.sh` passes `bash -n`; shellcheck clean (SKIP when absent); `python3 -I -m py_compile scripts/lib/cxlib.py` |
| P39 | §3.5, §2.2 | Every shipped text file is LF-only and ends with a newline; `.gitattributes` content as in §2.2, with `tests/fixtures/** -text` and `*.utf16le binary` as its last two lines; `git check-attr text eol -- tests/fixtures/settings/win-bom-crlf.json` reports `text: unset` |
| P40 | §3 | No `python3 -c`; every `python3` call is `python3 -I`; no `jq` or `node` calls; no `set -e`; every script (`worker-shims/*`, `hooks/policy.sh` and `scripts/host/wsl-entry.sh` included) has the bash shebang and a header comment; `--help` prints the header and `--version` prints `<prog> 0.1.0` for `bin/*`, `scripts/*.sh` and `scripts/host/{detect,pathmap,forward-wsl,install-runtime}.sh` only (P24 and P21 own the shims' and the hook's output); bin shims are 3 lines, not symlinks, executable, and work from a relative path with `CDPATH=.` exported |
| P41 | §13.4, §7.5 | Every listed file exists; the doctor's D3 list equals §13.4; `install-runtime.sh` copies exactly the subset under `.claude-plugin bin scripts hooks worker-shims templates` (and D4 accepts exactly that subset plus `RUNTIME_STAMP`) |
| P42 | §3.1, §7.3 | Git Bash code paths run on the simulated Git Bash PATH (stub dir + the §3.1 mini bin + a `python3` trap): forwarding, `cx-wsl` forwarding, `--windows`, `--login-help`, `cx_signal`, `cx_opt_lite`, `policy.sh`; the case fails if the trap logged `PYTHON_CALLED`; a script that needs a tool missing from the mini bin fails the case; `CX_FORWARDED=1` leaked into the Git Bash environment still forwards (the wsl.exe stub was invoked) |
| P43 | §12 | SKILL and commands frontmatter present; every frontmatter value that starts with `[` or `{` is double-quoted (all three `argument-hint`s are); `route.md` has `allowed-tools: Read, Glob, Grep`; SKILL exit table has `\| 130 \| CANCELLED \|`, README has ``\| 130 \| `CANCELLED` \|``; SKILL contains the §12.2 commands verbatim (`agy-delegate --model claude-opus-5-5-high`, `ghcp-delegate --model claude-opus-5.5 --effort high`, `--new-project`, `timeout -k 5 60 agy`, `--no-subagents`, `--test-cmd`), every `grok`, `agy-delegate`/`agy-job` and `ghcp-delegate`/`ghcp-job`/`ghcp-handoff` command line in it carries its §12.2 prefix (`env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1`, `env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1`, `env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1`), no `export CX_WORKER`; the recipe headings appear in the order of §12.1 item 4 (Step 3 after-run before Step 4 reviews before Step 5 GitHub); no `ghcp-ci-debug … --apply` without `--dir "$WT"` |
| P44 | U5 | No Cursor option, adapter or doctor check: a case-insensitive grep for `cursor` over every shipped file outside `docs/`, README and CHANGELOG matches only the `worker-shims/cursor-agent` file name (and references to it) and the two message constants `CURSOR_WORKER_MSG` and `CURSOR_POOL_MSG`, defined once in `cxlib.py`; the test names those constants and checks each is defined exactly once |
| P45 | §7.7 | `cx-wsl`: tools outside the allowlist (`copilot`, `claude`, `agy-handoff`, `rm`) → exit 1 without running anything; an allow-listed tool resolves from the host record (`ghcp-models` via the fake install dir; a PATH entry of the same name is never used); no record → 13 with one `CX_SIGNAL`; the passed-through tool's exit status and stderr are unchanged and no `CX_*` line is added; `cx-wsl grok --version` with `XAI_API_KEY` and `GROK_SANDBOX` set → the grok stub's env dump lacks both and has `CX_WORKER=1` and the `GROK_CLAUDE_*` / `GROK_DISABLE_AUTOUPDATER` values; the same prefix checks for `ghcp-models` and `agy`; `cx-wsl bash` sees the sibling wrapper dirs on PATH |

`CX_PROBE_TIMEOUT=<secs>` (env, any value ≥ 1) caps every doctor probe timeout; it exists for
the suite and for slow machines and is documented in the doctor's `--help`.

### 14.4 Live checks (manual, Phase 1; not in the suite)

| ID | Where | Check | Decides |
|---|---|---|---|
| L1 | Windows box, Git Bash | `wsl.exe -d Ubuntu --exec /usr/bin/setsid -f /usr/bin/sleep 900`; make sure no `wsl.exe` remains; wait 2 minutes; `wsl.exe -d Ubuntu --exec /usr/bin/pgrep -x sleep` | Whether detached jobs survive WSL idle shutdown; if not, §15.5's keepalive is mandatory and `.wslconfig` idle settings get tested |
| L2 | Windows app | Open a `\\wsl.localhost\Ubuntu\…` project; run `pwd; cygpath -w "$PWD"` in the Bash tool | The `$PWD` form; whether W3/P15's UNC path is what the app produces |
| L3 | Windows app | A temporary SessionStart hook that writes `uname -s`, `$SHELL`, `$0` to a file | Which shell runs hooks (if `cmd.exe` and `bash` resolves to `C:\Windows\System32\bash.exe`, the hook command needs changing) |
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

### 15.1 `cx-run`

```
cx-run [--exec auto|agy|copilot|grok|claude] [--mode write|read|review|ci] [--family gemini|gpt]
       [--model M] [--effort low|medium|high|xhigh|max] [--fusion standard|max]
       [--task-file F | "<task>" | -] [--id ID] [--repo DIR] [--base REF] [--reuse-worktree]
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
free preflight (cached 10 minutes in `$CX_HOME/state/preflight.json`): version pin (26), login
(11), model in the catalog (14), pool switch, agy pause → worktree (`worktree.sh create`; refuse
an existing branch or path unless `--reuse-worktree`) → render (`taskfile.sh render`) → `setup`
(25, not charged to the executor) → slot (`locks.sh`) → adapter `run` in the worker environment
(§15.6) under `setsid` and `timeout --kill-after=30s <limit>` → `parse` → post-checks → result
and ledger (§15.4) → output: stdout = the digest, a final `VERIFY THIS: <what to check>` line
(G8) and the diffstat; stderr = notes, `CX_DENIED`, `CX_NOTE`, `CX_RESULT`, `CX_SIGNAL`.

Classification, first match: `wrong_tree` 22 → `spec_tampered` 23 → `cancelled` 130 →
`timeout` 12 → `sandbox` 16 → `auth` 11 → `model_unavailable` 14 → `quota` 10 →
`model_mismatch` 21 → `denied` 15 (any denied write; any denial with no answer and no diff) →
`partial` 27 → `failed` 2 → `empty` 3 (write mode: no diff; read mode: no answer) → `ok` 0.
Preflight statuses (13, 25, 26, 28) stop before the run.

### 15.2 Adapters (`scripts/adapters/<lane>.sh probe|argv|run|parse`)

Common options: `--out DIR --wt DIR --model M --effort E --mode M --timeout SECS --allow CMD…`.
`probe` prints `{"lane", "bin", "version", "version_ok", "logged_in", "models", "model_ok",
"cached"}` (free); `argv` writes `$OUT/<lane>.argv` (NUL-separated) and `$OUT/<lane>.env`
(`NAME=VALUE` NUL-separated, `NAME=` with no value meaning unset); `run` executes them and
writes `$OUT/<lane>.out`, `$OUT/<lane>.err`, `$OUT/rc`; `parse` runs `normalize.py <lane>`.

| Lane | Environment | Argv (write mode) | Parse and checks |
|---|---|---|---|
| copilot | unset `COPILOT_ALLOW_ALL COPILOT_AUTO_TIER COPILOT_MODEL COPILOT_PROVIDER_BASE_URL GH_TOKEN GITHUB_TOKEN`, except the one variable the host record names as `copilot_token_env` (§7.6, D16), and `COPILOT_HOME` when it differs from the host record; `COPILOT_AUTO_UPDATE=false`, `GHCP_COPILOT_BIN=<record bin.copilot>`, `GHCP_USAGE_LOG=$CX_HOME/raw-usage.log`, `COPILOT_GITHUB_TOKEN` from `$CX_HOME/secrets/copilot-token` when that file exists | `<ghcp_delegate> --model <copilot_opus_id> --effort <E> --dir "$WT" --write --allow-shell <cmd>… --timeout <T> --digest "$P"`; Fusion: `--fusion standard\|max` instead of `--model/--effort`; read/review: no `--write`, `--dir "$GATE" --add-dir "$OUT"` | answer = stdout; `GHCP_SESSION`, `GHCP_USAGE` (`models_used`, `ai_credits`, tokens), `GHCP_DENIED`, `GHCP_FALLBACK`, `GHCP_NOTE`, `GHCP_SIGNAL`. Served: every `models_used[].model` equals the request (Fusion: any `GHCP_FALLBACK` → 21). #5149: effort xhigh, ≥ 30,000 output tokens and an empty answer → 2 with reason `copilot#5149`. ghcp exits pass through |
| grok | `GROK_DISABLE_AUTOUPDATER=1`, `GROK_CLAUDE_{HOOKS,SKILLS,MCPS,RULES,AGENTS}_ENABLED=false`; unset `XAI_API_KEY`, `GROK_SANDBOX` | `<grok> --prompt-file "$WT/.conductor/prompt.txt" -m <grok_bulk_model> --effort <E> --cwd "$WT" -s <uuid> --output-format json --sandbox <grok_sandbox_profile> --permission-mode acceptEdits --allow 'Bash(<cmd>)'… --allow 'Bash(git status)' --allow 'Bash(git diff)' --no-subagents --max-turns 60`; read/review: `--sandbox read-only --always-approve --json-schema <schema>` on the gate checkout. `GROK_MAX_CONCURRENT_SUBAGENTS=4` and no `--no-subagents` only when the task JSON says `"subagents": true` | JSON `text`, `sessionId`, `modelUsage`, `usage`, `stopReason` [docs-only]; any `permission required:` on stderr → denied; rc 1 with an error object and no `sessionId` → 2; `You are not authenticated` → 11; `rate.?limit\|quota\|\b429\b` → 10. Served: `modelUsage` keys = {model}. Tokens also from `grok usage <uuid>` (free) |
| agy (raw, default) | `AGY_CLI_DISABLE_AUTO_UPDATE=true`; unset `GEMINI_API_KEY`, `GOOGLE_API_KEY` | `/usage` before (free); `flock` on `$CX_HOME/locks/agy-launch`; registration `(cd "$WT" && <agy> --new-project --output-format json -p /model </dev/null)`; tree snapshot (`git status --porcelain=v1 -z` of the main checkout and every other worktree); `(cd "$WT" && exec setsid timeout --kill-after=15s <T+5m> <agy> --model <slug> --add-dir "$WT" --print-timeout <T> --output-format stream-json --disable-slash-commands -p "$P" </dev/null) > agy.ndjson 2> agy.err &`; the new session id is appended to `$CX_JOB_DIR/sids` | Wait ≤ 120 s for the `init` event: `init.model` ≠ slug → kill, 21; release the launch lock after `init`; SIGKILL the process group 5 s after the `result` event (#1313); snapshot again: any change outside `$WT` → 22 and `touch $CX_HOME/state/agy-paused` (agy dispatch stops until a human runs `cx-job unpause agy`; the main checkout is never auto-reset); `subagent_info` or a non-Opus model in events → 2 (`subagent`); `denied_actions` / permission `finished_reason` → 15; expired print timeout → 27; `/usage` after → `cost.quota_delta`. `agy_claude_floor_pct` > 0 and the bucket below it → lane ineligible |
| agy (wrapper) | as above plus `AGY_USAGE_LOG=$CX_HOME/raw-usage.log`; PATH shim set without `agy` | registration as above, then `<agy_delegate> --model <slug> --dir "$WT" --timeout <T> --digest "$P"` | `model_served: null` plus the note `agy wrapper: AGY_USAGE.model echoes the request; served model unverified` (§1.4); such a run never counts as G6-verified and never yields 21; agy-delegate exits pass through |
| claude | — | Default: no process; stdout `{"dispatch": "claude-subagent", "id", "worktree", "host_path", "prompt", "effort", "task_file"}`, then `cx-run --finish <id>`. `--headless`: `cd "$WT" && <claude> -p --model claude-opus-5-5 --effort <E> --output-format json --session-id <uuid> --permission-mode acceptEdits --settings "$OUT/cx-worker.json" "$P"` | JSON `result`, `session_id`, `usage`, `modelUsage` [assumption; pin with a capture]. `cx-worker.json` (from `templates/cx-worker.json`) allows `Bash(<cmd>)` per routes command and denies `Bash(claude:*)`, `Bash(copilot:*)`, `Bash(grok:*)`, `Bash(agy:*)`, every `Bash(ghcp-<x>:*)`, `Bash(agy-<x>:*)`, `Bash(cx-<x>:*)`. `--safe-mode` is added only after §20 item 18 passes |

Gemini lanes (digest, research, Argon review) always register the directory first and call
`agy-delegate --model '<label>' --dir <dir> --timeout 30m --digest`.

### 15.3 Locks (`scripts/lib/locks.sh`)

`cx_lock_acquire POOL CAP [WAIT_SECS]`: try `flock -n` on `$CX_HOME/locks/<POOL>.<n>` for n in
1..CAP, holding the descriptor for the life of the run (children inherit it; a killed process
group releases it); poll every 2 s up to WAIT_SECS; rc 0 with the slot number, or 28. Pools:
`agy` (`cap_agy`), `copilot` (`cap_copilot`), `grok` (`cap_grok`). The agy launch lock is
separate and held only from launch to the `init` event.

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
  `jd="$(jobdir "$id")" || exit 1` (ghcp's lesson).
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
- Waiting: Claude runs `cx-job wait <id>` as one background Bash call (`run_in_background`),
  which notifies on exit; never by re-checking across turns (the Phase 1 equivalent for the
  sibling job tools is the wait one-liner of §12.2). From Git Bash that forwarded `wsl.exe … cx-job wait`
  also keeps WSL alive. If L1 shows detached jobs die when no `wsl.exe` runs, `cx-job start`
  forwarded from Git Bash prints a note that a background `cx-job wait` must stay running for
  every job, and `.wslconfig` idle settings are tested [docs-only].

### 15.6 Worker environment

Every executor run: `CX_WORKER=1`; `PATH="<shim dir>:<host record path>"`; executors by
absolute path; `COPILOT_AUTO_UPDATE=false`, `GROK_DISABLE_AUTOUPDATER=1`,
`AGY_CLI_DISABLE_AUTO_UPDATE=true`, `NO_COLOR=1`; `ANTHROPIC_API_KEY`, `XAI_API_KEY`,
`GEMINI_API_KEY`, `GOOGLE_API_KEY` unset (they would bill APIs instead of subscriptions); cwd
`$WT` or the gate checkout. Shim dir = the full set, except the agy wrapper lane (set without
`agy`). Doctor check D29 (Phase 2, free): `PATH="$RT/worker-shims:$PATH" <abs cli> --version`
succeeds for copilot, grok and agy (a CLI that re-execs itself by name would hit its shim)
[unverified].

### 15.7 `cx-init --user-grants`

User-level, once per machine, idempotent, `--dry-run` supported, never per run (parallel runs
would race on these files): (1) merge `write_file(<worktree_root absolute>)` and one
`command(<cmd>)` per routes command into `~/.gemini/antigravity-cli/settings.json`
`permissions.allow` (backup `settings.json.cx-bak`; other keys preserved; never an empty
`command()`); (2) add the `grok_sandbox_profile` profile from `templates/grok-sandbox.toml` to
`~/.grok/sandbox.toml` when absent (extends `workspace`; denies `**/.env`, `**/.env.*`,
`**/*.pem`, `**/*.key`, `**/id_rsa*`; syntax [docs-only], verified with `grok inspect --json` in
a worktree); (3) `[cli] auto_update = false` in `~/.grok/config.toml` when absent.

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
| A9 | Version-pin mismatch → 26 with no executor invocation |
| A10 | grok error object without `sessionId` → 2; `You are not authenticated` → 11 |
| A11 | Parsers on ghcp's real fixtures (`ok-pong`, `denied-write`, `autodenied-shell`, `fusion-max-pong`, copied into `tests/fixtures/real/copilot/`) and on every Phase 0 capture |
| A12 | cx-job lifecycle; kill of a TERM-ignoring stub (TERM, then KILL after 10 s, recorded sids included); rc 130 written before the kill; pid-reuse protection |
| A13 | Caps under parallel `cx-run` with sleeping stubs; `--no-wait` → 28 |
| A14 | Worker env: shims first, `CX_WORKER=1`, scrubbed variables absent from the stub's env dump; the agy-wrapper shim set lacks `agy` |
| A15 | Task hash mismatch → 23; no diff → 3; setup failure → 25 with no executor invocation |
| A16 | Forwarded `cx-run`/`cx-job` from simulated Git Bash: `host_path` fields are Windows paths; a background job outlives the forwarder |
| A17 | `--dry-run`/`--explain` create nothing and call no executor (stub logs show free probes only) |
| A18 | `cx-init --user-grants` merges JSON and TOML idempotently with a backup |

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
- Copilot cloud agent through REST tasks / Automations (`model`, `reasoning_effort`; 59-minute
  cap).
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
| 4 | agy `--add-dir`, `--disable-slash-commands`, `--print-timeout`, `--new-project`, `--project`, `--output-format stream-json` on 1.4.12 | docs-only | `agy --help` capture | §12.2, §15.2 |
| 5 | `agy models --output-format json` shape; `-p /usage` shape and zero cost | docs-only | Phase 0 capture; `/usage` before/after a `/usage` | D18, §8.4 |
| 6 | agy `init.model`, `result`, `denied_actions`, `subagent_info` event shapes | unverified | agy paid checks #1, #2 | §15.2 |
| 7 | grok JSON fields, `permission required:`, `Bash(<cmd>)` rules, `workspace`/`read-only` profiles, `sandbox.toml` syntax, `GROK_CLAUDE_*_ENABLED`, `GROK_DISABLE_AUTOUPDATER`, `[cli] auto_update` | docs-only | grok paid checks #1–#3; `grok inspect --json` in a worktree | §12.2, §15.2, §15.7 |
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
| 35 | `agy-job status` prints `  state=running` while running | verified (read 2026-11-01), not a stable API | Re-read on every antigravity update | §12.2 wait one-liner |
| 36 | How Claude Code 2.1.316 matches `Bash(...)` allow rules against commands that start with `env -u … VAR=1` and against multi-command steps | unverified | Add the prefixed rule, run one Phase 1 step, observe whether it prompts | D25, U2 |

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
