# conductor-for-claude-code

**conductor** is a Claude Code plugin that makes Claude Code the conductor across the coding
subscriptions you already pay for. It routes each piece of work to the executor best suited to
it, sends Opus 5.5 fan-out to the included pools, and keeps Claude the judge of quality: Claude
owns the spec, the gates and the merge; executors draft.

| Executor | How the conductor reaches it | Used for |
|---|---|---|
| GitHub Copilot CLI | your `ghcp` plugin (`ghcp-delegate`, `ghcp-job`, `ghcp-handoff`, `ghcp-ci-debug`, `ghcp-models`) | Opus 5.5 at high effort, Fusion, GPT-family review, PR review, CI triage |
| Grok Build | the raw `grok` 1.0.70 CLI (never the grok-build bridge plugin) | exploration, mechanical edits, tests to a contract, docs, commit and PR text |
| Antigravity | the raw `agy` CLI for Opus, the `antigravity` plugin (`agy-delegate`, `agy-job`, `agy-media`) for Gemini | Opus 5.5 at high effort, Gemini-family review, media, Google-grounded research, long digests |
| Claude | your own subagents | architecture, one-way doors, xhigh/max reasoning, merge conflicts, small or judgement-heavy edits |

Opus 5.5 offload fills the pools in the order of option `opus_lane_order` (default
`agy,copilot,claude`): Antigravity `claude-opus-5-5-high`, then Copilot `claude-opus-5.5` at
`--reasoning-effort high`, then Claude's own subagents. The conductor may spend Copilot credits
and agy quota without asking, push `cx/*` branches, open pull requests and request `@copilot`
reviews. There are no spend caps: `copilot_reserve_pct` defaults to `0` (off).

The full build spec is `docs/DESIGN.md`; this README condenses it.

## Routing in one table

| Task | Primary | Fallback | Verification |
|---|---|---|---|
| Architecture, hard reasoning | Claude (xhigh, max for one-way doors) | Copilot Opus high | Claude writes the ADR |
| Exploration, "where is X" | grok `grok-4.7` medium, read-only | Gemini flash, read-only | Claude spot-checks cited lines |
| Small or judgement-heavy change | Claude | — | normal tests |
| Spec'd feature, design-sensitive | Opus lanes in `opus_lane_order`, high | next Opus lane, Fusion Max, Claude | clean-checkout tests, tamper check, cross-family review |
| Spec'd feature, mechanical; bulk edits | grok `grok-4.7` high | Copilot Fusion standard | the same gate plus the `permission required:` scan |
| Exhaustive tests | grok high against Claude's contract | Gemini flash high | tests pass on current code, no source changes |
| First-pass review | grok (local diff) or Copilot code review (GitHub PR) | Gemini flash | Claude confirms every finding at file:line |
| Security review | Claude + GPT (`gpt-6.1-sol`) + CodeQL; never Grok alone | Gemini Argon | Claude adjudicates |
| Second opinion on Opus-written code | Gemini Argon High (+ GPT on high-risk paths) | grok xhigh | Opus reviewing Opus is not independent |
| PR, issue and CI triage | Copilot (`ghcp-ci-debug`, `ghcp-delegate --github`) | grok digest | fixes go through the same gates |
| Media, Google-grounded research, digests over 200k tokens | `agy-media`, `/antigravity:research`, `agy-delegate --digest` | grok, Claude WebSearch | Claude re-checks what it relies on |

Phase 1 has no `cx-run` yet: the session-start policy and the `conductor` skill give the exact
commands for each lane through the sibling wrappers (`/conductor:route <task>` explains one).

## Install

In WSL (today's setup), one step:

```
claude plugin install conductor --marketplace 40chalk/conductor-for-claude-code
```

or two: `/plugin marketplace add 40chalk/conductor-for-claude-code` (or a local folder), then
`/plugin install conductor@conductor-for-claude-code`.

On the Windows desktop app (whose Bash tool is Git Bash), install the conductor as the only
Claude-side plugin there; every `cx-*` command forwards into WSL. Run
`git config --global core.autocrlf input` first (belt and braces: this repo's `eol=lf` rules
already keep git checkouts LF). Never install ghcp, antigravity or grok-build on the Windows
side: their policies would send Claude to run their wrappers in Git Bash, bypassing WSL.

Prerequisites, all in WSL: python3 ≥ 3.8, bash ≥ 4.4, coreutils and util-linux (`timeout`,
`setsid`, `flock`, `sha256sum`), git ≥ 2.31; Copilot CLI 1.0.105, grok 1.0.70, agy, gh; the
ghcp and antigravity plugins. No jq, no node, no pip packages.

## First run

1. `/conductor:doctor` (or `cx-doctor` outside Claude Code's Bash sandbox): host, prerequisites,
   CLI versions against the pins, free login probes, sibling plugin overlap. It never calls a
   model.
2. `cx-doctor --login-help [copilot|grok|agy|gh|claude]` prints the exact fresh-login commands
   for each CLI (device-code flows where they exist: `grok login --device-auth`,
   `copilot login`, `gh auth login --web`).
3. Turn the sibling policies off so the conductor's single policy replaces them (the doctor
   prints these):
   ```
   printf '%s' '{"coding_policy":"off","delegation_nudge":"off"}' | claude plugin configure ghcp@ghcp-for-claude-code --values-stdin
   printf '%s' '{"coding_policy":"off","delegation_nudge":"off","timeout":"30m"}' | claude plugin configure antigravity@antigravity-for-claude-code --values-stdin
   ```
4. `/conductor:init` in a repository writes `AGENTS.md`, `.cx/routes.json` and
   `.github/copilot-instructions.md` (it detects test, lint and typecheck commands for npm,
   pnpm, yarn, bun, Python, Go and Rust, and never touches `CLAUDE.md` or `.claude/`).

## Commands

| Command | What it does |
|---|---|
| `cx-doctor [--pools] [--json] [--no-record]` | Health check with free probes; writes the host record `~/.conductor/hosts/<hostkey>.json` |
| `cx-doctor --windows` | Git Bash only: the Windows-side checks W1–W9 |
| `cx-doctor --login-help [cli]` | Fresh-login commands per CLI |
| `cx-init [--dry-run] [--force] [--only agents\|routes\|copilot]` | The repo bundle |
| `cx-wsl TOOL [ARG...]` | One allow-listed WSL-side tool (`ghcp-*`, `agy-*`, `agy`, `grok`, `gh`, `git`, `bash`) with the per-tool environment prefixes |
| `/conductor:doctor`, `/conductor:init`, `/conductor:route` | The same from Claude Code; `route` explains where a task should go and runs nothing |

## Options

Set with `printf '%s' '{"<name>":"<value>"}' | claude plugin configure conductor@conductor-for-claude-code --values-stdin`.
Every option is a string; an empty value means the default.

| Option | Default | Meaning |
|---|---|---|
| `policy` | `on` | Inject the routing policy at SessionStart (startup, clear, compact) |
| `exec_host` | `auto` | Where executors run: `auto` (Git Bash forwards into WSL), `wsl`, `local` (refused on Git Bash) |
| `wsl_distro` | `auto` | WSL distribution for forwarding; `auto` = wsl.exe's default |
| `docker_compose_file` | (empty) | v1.1: the coding-agents-docker `compose.yaml` |
| `docker_service` | `agents` | v1.1: the compose service |
| `opus_lane_order` | `agy,copilot,claude` | Order in which Opus 5.5 work fills the pools; `claude` is appended when missing |
| `agy_opus_slug_tpl` | `claude-opus-5-5-{effort}` | agy model slug for the Opus lane |
| `agy_opus_mode` | `raw` | `raw` agy CLI or `wrapper` (agy-delegate) |
| `copilot_opus_id` | `claude-opus-5.5` | Copilot model id for the Opus lane |
| `copilot_xhigh_ok` | `false` | Allow `--reasoning-effort xhigh` on Copilot Opus (`max` is never sent) |
| `grok_bulk_model` | `grok-4.7` | Grok model for mechanical lanes |
| `grok_bulk_effort` | `high` | Grok effort for mechanical lanes |
| `grok_sandbox_profile` | `cx-workspace` | grok sandbox profile every grok writer runs under |
| `review_model_gemini` | `Gemini 4 Argon (High)` | Gemini-family reviewer |
| `review_model_gpt` | `gpt-6.1-sol` | GPT-family reviewer |
| `cap_agy` / `cap_copilot` / `cap_grok` | `2` / `3` / `5` | Concurrency limits (throughput, not spend) |
| `copilot_reserve_pct` | `0` | Percent of the month to leave unused; 0 = off (no reserve) |
| `copilot_mtd_max_age_days` | `3` | Age at which the entered month-to-date figure is reported stale |
| `agy_claude_floor_pct` | `0` | Stop agy Opus below this Claude/GPT bucket percent; 0 = off |
| `worktree_root` | `~/.cx-wt` | Root for task worktrees (never inside a repo, `/` or `$HOME`) |
| `ledger_path` | `~/.conductor/ledger.jsonl` | One JSON line per executor run (Phase 2) |
| `default_timeout` | `30m` | Wall clock per executor run (Phase 2) |

## Windows (Git Bash) and WSL

WSL is the executor host: every CLI, login and git operation lives there. From Git Bash each
`cx-*` command forwards into WSL through `wsl.exe` (arguments cross as a NUL-separated file,
only the conductor's own variables cross, the working directory is mapped from its Windows
form, exit codes and Ctrl-C propagate). The first forwarded call installs a runtime copy into
`~/.conductor/runtime/<version>` in WSL.

Before `cx-run` exists, the Windows app delegates through `cx-wsl`: `cx-wsl ghcp-job status <id>`,
`cx-wsl gh pr view 12`, or a whole shell step written to a file and run with
`cx-wsl bash -s < FILE`. Paths in arguments are WSL paths (`/home/<you>/...`). Run
`cx-doctor` once from a WSL terminal first: `cx-wsl` takes its tool paths from the host record.

To remove the permission prompts (U2), add these allow rules to the Windows-side Claude Code
settings: `Bash(cx-doctor:*)`, `Bash(cx-init:*)`, `Bash(cx-wsl:*)`. In WSL the doctor lists the
rules for the sibling wrappers too; it never edits settings itself.

## Exit codes

| Exit | Status | Meaning |
|---|---|---|
| 0 | — | Success |
| 1 | — | Usage error, invalid argument, refused request (no `CX_SIGNAL`) |
| 2 | `FAILED` | Unexpected failure |
| 3 | `EMPTY_OUTPUT` | Executor exited 0 with no answer and no diff |
| 4 | `CHECKS_FAILED` | `cx-doctor`: at least one check failed |
| 5 | `EXISTS` | `cx-init`: a bundle file differs; nothing written |
| 10 | `QUOTA_EXHAUSTED` | Quota or rate limit |
| 11 | `AUTH_REQUIRED` | Executor not logged in |
| 12 | `TIMEOUT` | Wall clock expired |
| 13 | `CLI_MISSING` | Executor binary or sibling wrapper not found (`cx-wsl`: run `cx-doctor` in WSL first) |
| 14 | `MODEL_UNAVAILABLE` | Model, slug or effort refused before any model call |
| 15 | `PERMISSION_DENIED` | A denied write, or a denial with no answer or diff |
| 16 | `SANDBOX_BLOCKED` | Claude Code's Bash sandbox blocks the executor: rerun outside it |
| 20–28 | `GATE_FAILED` … `NO_CAPACITY` | Gates, model mismatch, wrong tree, tampering, setup, version pin, partial output, no capacity (Phases 2–3) |
| 40 | `FORWARD_FAILED` | `wsl.exe` missing or failed, distribution missing, or the WSL VM stopped |
| 41 | `RUNTIME_MISSING` | No runtime copy in WSL (or a version mismatch): `cx-doctor --install-runtime` |
| 42 | `PATH_UNMAPPABLE` | A path (or the working directory) has no equivalent on the other side |
| 43 | `HOST_UNSUPPORTED` | This host cannot do this (Cygwin, `exec_host=local` on Git Bash, Docker before v1.1) |
| 44 | `CRLF_CORRUPT` | A runtime file still contains CR |
| 75 | `RUNNING` | Job still running (Phase 2) |
| 126 | — | A worker shim blocked an agent CLI inside a conductor worker |
| 130 | `CANCELLED` | INT, TERM or HUP |

Every exit outside 0, 1 and 126 prints exactly one `CX_SIGNAL {json}` line, last on stderr;
`cx-wsl` passes the tool's own status and output through unchanged.

## Status

| Phase | Deliverable | State |
|---|---|---|
| 1 | Manifests, libraries, host layer and forwarding, `cx-doctor`, `cx-init`, `cx-wsl`, policy hook, worker shims, skill and commands, hermetic tests | this release (0.1.0) |
| 2 | Adapters, `cx-run`, `cx-job`, ledger, locks | specified |
| 3 | `cx-gate`, conductor commit, `cx-fanout`, integration queue | specified |
| 4 | Windows end to end, review lane, GitHub | specified |
| v1.1 | Docker lanes | specified |

Development: `bash tests/run-tests.sh` (stubs only; no network, no credits). See `CLAUDE.md`.

## Attribution

None needed: original work. The engineering conventions follow the author's own ghcp plugin.
MIT licensed (`LICENSE`).
