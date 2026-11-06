# conductor-for-claude-code

**conductor** is a Claude Code plugin that makes Claude Code the conductor across the coding
subscriptions you already pay for. It routes each piece of work to the executor best suited to
it, sends Opus 5.5 fan-out to the included pools, and keeps Claude the judge of quality: Claude
owns the spec, the gates and the merge; executors draft.

| Executor | How the conductor reaches it | Used for |
|---|---|---|
| GitHub Copilot CLI | your `ghcp` plugin (`ghcp-delegate`, `ghcp-job`, `ghcp-handoff`, `ghcp-ci-debug`, `ghcp-models`, `ghcp-cloud`) | Opus 5.5 at high effort, Fusion, GPT-family review, PR review, CI triage, the Copilot cloud agent (its pull requests go through the same gate) |
| Grok Build | the raw `grok` CLI (last verified 1.0.70; never the grok-build bridge plugin) | exploration, mechanical edits, tests to a contract, docs, commit and PR text |
| Antigravity | the raw `agy` CLI for Opus, the `antigravity` plugin (`agy-delegate`, `agy-job`) for Gemini | Opus 5.5 at high effort, Gemini-family review, long digests (media and research wait for the v1.1 Docker lane: `agy-media` and `/antigravity:research` always pass `--yolo`) |
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
| Exploration, "where is X" | grok `grok-4.7` medium, read mode | Gemini flash, read-only | Claude spot-checks cited lines |
| Small or judgement-heavy change | Claude | — | normal tests |
| Spec'd feature, design-sensitive | Opus lanes in `opus_lane_order`, high | next Opus lane, Fusion Max, Claude | clean-checkout tests, tamper check, cross-family review |
| Spec'd feature, mechanical; bulk edits | grok `grok-4.7` high | Copilot Fusion standard | the same gate plus the `permission required:` scan |
| Exhaustive tests | grok high against Claude's contract | Gemini flash high | tests pass on current code, no source changes |
| First-pass review | grok (local diff) or Copilot code review (GitHub PR) | Gemini flash | Claude confirms every finding at file:line |
| Security review | Claude + GPT (`gpt-6.1-sol`) + CodeQL; never Grok alone | Gemini Argon | Claude adjudicates |
| Second opinion on Opus-written code | Gemini Argon High (+ GPT on high-risk paths) | grok xhigh | Opus reviewing Opus is not independent |
| PR, issue and CI triage | Copilot (`cx-wsl ghcp-ci-debug`); issues and PRs fetched with `gh`, then `cx-run --mode read --exec copilot` (ghcp's `--github` acts as you on GitHub, so never for triage) | grok digest | fixes go through the same gates |
| Research; digests over 200k tokens | Claude WebSearch, grok; `cx-run --mode read --exec agy` with Argon | agy flash on fetched text | Claude re-checks what it relies on |

## Using it: `cx-run` and `cx-job`

Every executor run is one `cx-run`: one task, one id, one worktree `~/.cx-wt/<repo>-<id>` on
branch `cx/<id>`, the task contract (`.conductor/task.md`, hashed), the repo's `setup`, the
shared pool slot, the worker environment (worker shims first on PATH, then the run's
`cx-route`; `CX_WORKER=1`, API keys and `CLAUDE_PLUGIN_OPTION_*` unset, self-updates off for the
run, `PYTHONDONTWRITEBYTECODE=1`), then the denial, served-model and tree
checks, `~/.conductor/out/<id>/result.json`, one ledger line and one `CX_RESULT` line. `cx-job`
runs the same in the background (`JOB_ID`, `status`, `wait`, `result`, `kill`, `list`,
`unpause agy`). Claude still commits and gates by hand (the skill's Step 3) until Phase 3's
`cx-gate`. The session-start policy and the `conductor` skill give the exact commands
(`/conductor:route <task>` explains one):

```
cx-run --background --task-file ~/.conductor/tasks/t1.md --id t1 --effort high   # --exec auto: agy (raw), then Copilot, then Claude
cx-job wait <job id>                                                  # one background Bash call, timeout 7200000
cx-run --exec grok --id t2 -- '- add a greeting file'                  # free text; after -- it may start with -
cx-run --mode read --exec grok '<question>'                           # an answer only, on a detached checkout
cx-run --mode review --family gemini --branch cx/t1                    # a cross-family review
cx-run --exec claude --task-file ~/.conductor/tasks/t3.md --id t3      # a dispatch JSON for your own subagent ...
cx-run --finish t3                                                     # ... then its checks, CX_RESULT and ledger line
cx-run --exec copilot-cloud --task-file ~/.conductor/tasks/t4.md --id t4  # the Copilot cloud agent opens a PR ...
cx-run --finish t4 --pr 42                                             # ... whose head is gated on a clean checkout
```

- `--exec auto|agy|copilot|grok|claude|copilot-cloud`, `--mode write|read|review`, `--effort`,
  `--fusion standard|max`, `--dry-run` (the plan and the executor's argv, nothing created) and
  `--explain` (why each lane was chosen or skipped). Ids are unique on the computer; one
  `cx-run` per task at a time (a re-dispatch while the first still runs exits 1).
- **Pool slots.** `cap_agy`, `cap_copilot` and `cap_grok` (default 2, 3, 5) hold for every
  session, Work locally thread, workflow agent and forwarded call on the computer: `cx-run`
  takes the slot for every executor run (a job shows `queued` until it gets one), and `cx-wsl`
  takes one for its executor calls. agy launches never overlap. A pool that stays full for
  `CX_SLOT_WAIT_SECS` (600 s) exits 28 `NO_CAPACITY`; `--exec auto` then takes the next lane.
- **Results are claims.** Exit 0 means the checks `cx-run` can make passed; read the
  `VERIFY THIS:` line and `CX_RESULT` (`status`, `model_served`, `denied`, `diffstat`).
- **agy's tree check.** After an agy run every other worktree of the repo, its refs, config,
  hooks and ignored files are compared with a snapshot; a change there ends the run 22
  `WRONG_TREE` and pauses agy dispatch until `cx-job unpause agy`.
- **The worktree's `.git` is the executor's to rewrite, so the conductor never trusts it.** Its
  own git (the change of a run, the agy snapshots) takes each worktree's git directory from the
  repository's own records and runs no configured program (fsmonitor, hooks, textconv,
  submodules). A rewritten link ends the run 24 `TAMPERED`: run no git in that worktree, remove
  it with `rm -rf`.

- **Checks run only through `cx-route`.** At dispatch `cx-run` snapshots the task's checks from
  `.cx/routes.json` into the run's `~/.conductor/routes/<id>/cx-route` (`cx-route test`,
  `cx-route lint`, ...; `cx-route` alone lists them; editing the worktree's `routes.json`
  changes nothing; the check runs in a clean bash, so a caller's `BASH_ENV` or exported
  functions never run). Executors may run only that and `git status` (agy also `ls`): agy gets
  exactly these as per-run `--settings` grants (one denied command ends a headless agy run),
  Copilot as `--allow-shell` rules (it matches a shell call by its command name), and grok runs
  in its repository's sandbox profile. Never `git diff`, `git log` or `git show`: their
  `--output=<path>` writes any file, and a prefix rule cannot forbid an option. agy and Copilot
  have no OS sandbox: their grants keep an executor to the routes, but the routes run the
  repository's own code, so they do not contain a hostile executor; grok's sandbox does.
- **No version pins.** Before every run each lane checks that the CLI's live `--help` (and
  `copilot help permissions`) still lists every flag it is about to pass; a missing one refuses
  the lane with exit 26 before anything runs. `cx-doctor` shows the versions the lanes were last
  verified against as information; auto-update is your choice.

Every conductor grok run (write, read and review) runs under its repository's own sandbox
profile `cx-<repo>-<hash>` in `~/.grok/sandbox.toml` (extends grok's `strict`; read-only access
to the repository's git directory, `~/.conductor/routes` and this host's resolver directories,
below; never the out directories), which the first grok run of a repository writes; option
`grok_sandbox_profile` can name a profile of your own instead, used for every mode. The skill's
commit-message call uses conductor's `cx-strict` (`strict` plus the resolver directories only)
in a directory that holds only its prompt (`cx-wsl` refuses a grok run without `--sandbox
cx-strict` or an absolute `--cwd`, writes and checks `cx-strict` first, and runs grok from that
directory). Measured on grok
1.0.70: `strict` grants write to its working directory, `~/.grok/sessions`, `/tmp` and
`/var/tmp` only (grok's sandbox log, `tests/fixtures/real/grok/sandbox-events-1.0.70.jsonl`),
and inside `~/.grok` it write-denies everything but `sessions/` (the write probe,
`tests/fixtures/real/grok/write-probe-strict-1.0.70.txt`). grok's built-in `read-only`, which
0.2.1 used for read and review runs and the commit-message call, write-denied an append-open of
grok's protected set (`config.toml`, `sandbox.toml`, `trusted_folders.toml`,
`managed_config.toml`, `requirements.toml`, `hooks-paths`, `hooks/`, `bundled/`, `bundles/`)
and let grok write the rest of `~/.grok` (`write-probe-read-only-1.0.70.txt`): its binary in
`~/.grok/bin` (which runs whenever grok is launched from there), its ripgrep in
`~/.grok/vendor`, `~/.grok/installed-plugins` and `auth.json`, code and credentials used later
outside any sandbox. Before each grok run (and before its pool slot) the lane checks the run's own profile
for free: `grok --sandbox <profile> models` in the run's checkout, then the line it adds to
grok's sandbox log (`~/.grok/sessions/sandbox-events.jsonl`, read where GNU `stat` is
available). The run is refused (exit 2, before any prompt) when that line says the profile was
not enforced or grants write to `~/.grok` itself, a directory above it or one inside it (all
but `~/.grok/sessions`), and always, before grok starts, for a built-in profile that writes
`~/.grok` (`off`, `devbox`, `workspace`, `read-only`); with no log the check changes nothing.
The preflight refuses the whole lane the same way when grok's built-in `strict` would grant
`~/.grok` (grok's README says it does; 1.0.70 does not). The profile's name
is conductor's own: before each run, and again once it holds its slot, any other definition of
it is replaced, and a file that would still define it another way (or a `.grok/sandbox.toml` in
the run's checkout, a review's included) refuses the run. A read or review of a commit that
tracks anything at `.conductor` (where the conductor writes the diff, the task and the prompt
file) is refused before the checkout, and the conductor never writes through a symlink there.
Known limits: `~/.grok/sessions` holds every grok session's transcript and every grok run can
read and write it, so a grok run can see other grok runs' tasks and answers there; every grok
run can write `/tmp` and `/var/tmp`, so the conductor keeps its scratch files in
`~/.conductor/tmp` and the skill its task contracts in `~/.conductor/tasks/`, and nothing you
will run or re-read belongs in `/tmp` while grok runs go on. Every grok run approves every tool inside its sandbox,
so its preflight also checks that grok can apply one here (`grok --sandbox strict models`, free;
on Linux and WSL it needs Landlock and bubblewrap, `cx-doctor` D17).

grok's name lookups and TLS under those profiles (measured on WSL, grok 1.0.70): `strict` reads
only its system directories (`/usr`, `/lib`, `/lib64`, `/bin`, `/sbin`, `/etc`, `/dev`, `/proc`,
`/sys`, `/tmp`, `/run`, `/var`), the working directory and `~/.grok`, and the sandbox checks a
file's resolved path. On WSL `/etc/resolv.conf` links to `/mnt/wsl/resolv.conf`, so under plain
`strict` grok resolved no host name: a write run retried its API for 28 minutes, then failed
(`error sending request for url`, no model call), while every `cx-doctor` check passed. Every
conductor profile therefore adds, read-only, the directory of each resolver and TLS file
(`/etc/resolv.conf`, `/etc/hosts`, `/etc/nsswitch.conf`, `/etc/host.conf`, `/etc/gai.conf`, the
usual CA bundles, `SSL_CERT_FILE`, `SSL_CERT_DIR`) whose resolved path lies outside that list:
`/mnt/wsl` on WSL (a directory WSL shares between distributions), nothing on most other hosts.
It never grants `/`, a directory that is or contains your home, `~/.grok`, `~/.conductor` or a
checkout, nor one inside `~/.conductor`; `cx-doctor` D17 lists the files, the grants and
anything it could not grant (then grok cannot resolve names under any conductor profile: make
`/etc/resolv.conf` resolve elsewhere), and warns about a profile in `sandbox.toml` written
before this release (the repository's next grok run rewrites it). A grok run that fails this
way says so: "grok could not reach its API (a connection or DNS failure; cx-doctor D17)", or
"could not resolve its API's host name (DNS …)" when grok's own log (`~/.grok/logs/unified.jsonl`,
the lines the run added) says so; the exit stays 2 (12 when the timeout ended grok's retries).
That grok then works end to end on WSL is not yet measured. D17 retries a failed `grok models`
login probe once, 2 s later, before it warns.
`cx-init --user-grants` (optional, from inside the repository) writes the
repository's profile ahead of time and removes the invalid `cx-workspace` profile 0.2.0 wrote,
with a `.cx-bak` backup (`--dry-run` shows what it would change). agy needs no global grant any more: remove the `write_file(...)` and
`command(...)` rules 0.2.0 put into `~/.gemini/antigravity-cli/settings.json` if you do not
want them (`cx-doctor` lists them).

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
`setsid`, `flock`, `sha256sum`), git ≥ 2.31, bubblewrap (`bwrap`) and a kernel with Landlock
(Linux 5.13 or newer; a current WSL kernel) for grok's sandbox; Copilot
CLI, grok, agy, gh (any version whose help still lists the flags the lanes use; last verified:
Copilot 1.0.105, grok 1.0.70, agy 1.5.1); Claude
Code itself, logged in (`claude auth login`; the sibling plugins install into it, also when you
work from the Windows app); and the two sibling plugins, each with its marketplace:

```
claude plugin install ghcp --marketplace 40chalk/ghcp-for-claude-code
claude plugin install antigravity --marketplace yuting0624/antigravity-for-claude-code
```

No jq, no node, no pip packages.

## First run

1. `/conductor:doctor` in a Claude Code session (or `cx-doctor` from its Bash tool, outside the
   sandbox): host, prerequisites, CLI versions (with the versions last verified), free login probes, sibling
   plugin overlap. It never calls a model. In a plain WSL terminal `cx-doctor` is not on PATH:
   use `~/.conductor/runtime/current/bin/cx-doctor` there, after `/conductor:doctor
   --install-runtime` (or any call forwarded from Windows) has created that copy.
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
| `cx-doctor --windows` | Git Bash only: the Windows-side checks W1–W11 |
| `cx-doctor --login-help [cli]` | Fresh-login commands per CLI |
| `cx-init [--dry-run] [--force] [--only agents\|routes\|copilot]` | The repo bundle |
| `cx-init --user-grants [--dry-run]` | The repository's grok sandbox profile (optional: its first grok run writes it); removes 0.2.0's invalid `cx-workspace` profile; never writes agy grants |
| `cx-run [OPTIONS] (--task-file F \| '<task>' \| - \| -- '<task>')` | One task on one executor lane (above); `--finish ID [--pr N]`, `--dry-run`, `--explain`, `--background` |
| `cx-job start\|status\|wait\|result\|kill\|list\|unpause agy` | Background `cx-run` jobs (`cx-run --background` is `cx-job start`) |
| `cx-wsl TOOL [ARG...]` | One allow-listed WSL-side tool with the per-tool environment prefixes and its pool slot: exactly `ghcp-delegate`, `ghcp-job`, `ghcp-handoff`, `ghcp-ci-debug`, `ghcp-models`, `ghcp-cloud`, `agy-delegate`, `agy-job`, `agy`, `grok`, `gh`, `git`, `bash` (never `agy-handoff` or `agy-media`, which always pass `--yolo`). The skill uses it for `gh`, `git`, `ghcp-cloud list`/`view`, its two hand executor calls (`cx-wsl grok` for commit messages, `cx-wsl ghcp-ci-debug`) and, from Windows, the hand steps (`cx-wsl bash -s < FILE`); every other executor run is a `cx-run` |
| `/conductor:doctor`, `/conductor:init`, `/conductor:route` | The same from Claude Code; `route` explains where a task should go and runs nothing |

## Options

Set with `printf '%s' '{"<name>":"<value>"}' | claude plugin configure conductor@conductor-for-claude-code --values-stdin`.
Every option is a string; an empty value means the default.

| Option | Default | Meaning |
|---|---|---|
| `policy` | `on` | Inject the routing policy at SessionStart (startup, clear, compact) and the subagent rules at SubagentStart |
| `exec_host` | `auto` | Where executors run: `auto` (Git Bash forwards into WSL), `wsl`, `local` (refused on Git Bash; on a BYOC runner it means "this runner is the executor host") |
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
| `grok_sandbox_profile` | `auto` | grok sandbox profile every conductor grok run (write, read and review) runs under: `auto` = each repository's own `cx-<repo>-<hash>` (extends `strict`, plus this host's resolver directories); `cx-workspace` counts as `auto`; any other name is your own profile (refused when its logged grants let grok write `~/.grok`); grok's built-ins that write `~/.grok` are refused, and `strict` cannot read a worktree's git directory or the routes (`cx-doctor` D17 warns) |
| `review_model_gemini` | `Gemini 4 Argon (High)` | Gemini-family reviewer |
| `review_model_gpt` | `gpt-6.1-sol` | GPT-family reviewer |
| `cap_agy` / `cap_copilot` / `cap_grok` | `2` / `3` / `5` | Concurrency limits (throughput, not spend): pool slots shared by every session, thread and forwarded call on the computer (`~/.conductor/locks`); `0` turns a pool off |
| `copilot_reserve_pct` | `0` | Percent of the month to leave unused; 0 = off (no reserve) |
| `copilot_mtd_max_age_days` | `3` | Age at which the entered month-to-date figure is reported stale |
| `agy_claude_floor_pct` | `0` | Stop agy Opus below this Claude/GPT bucket percent; 0 = off |
| `worktree_root` | `~/.cx-wt` | Root for task worktrees (never inside a repo, `/` or `$HOME`) |
| `ledger_path` | `~/.conductor/ledger.jsonl` | One JSON line per executor run (`cx-run`) |
| `default_timeout` | `30m` | Wall clock per executor run unless `--timeout` |

## Windows (Git Bash) and WSL

WSL is the executor host: every CLI, login and git operation lives there. From Git Bash each
`cx-*` command forwards into WSL through `wsl.exe` (arguments cross as a NUL-separated file,
only the conductor's own variables cross, the working directory is mapped from its Windows
form, exit codes and Ctrl-C propagate). The first forwarded call installs a runtime copy into
`~/.conductor/runtime/<version>` in WSL.

`cx-run` and `cx-job` forward themselves, so the Windows app runs the same commands as WSL; path
options may be Windows paths, and the `host_path` fields of `CX_RESULT` and of the claude
dispatch are Windows (`\\wsl.localhost\…`) paths. Write task files to a Windows-side path
(`C:\Users\<you>\AppData\Local\Temp\cx-t1.md`, or its `/c/Users/…` form), never Git Bash's
`/tmp`: that path has no WSL form, so `cx-run` exits 42 `PATH_UNMAPPABLE` (with `--background`
before any job starts). A job keeps running in WSL after its forwarded `cx-job start` returns.
Executors run only through `cx-run` and `cx-job`; `cx-wsl` is for `gh`, `git` (`cx-wsl gh pr
view 12`), `ghcp-cloud list`/`view`, `ghcp-ci-debug` and the hand steps (the commit and gate,
Step 5) written to a file and run with `cx-wsl bash -s < FILE` (step files must be LF; `cx-wsl`
strips CRLF with a note). Every executor call through `cx-wsl` first takes a slot of its pool,
shared with every other session and thread on the computer; a pool that stays full for
`CX_SLOT_WAIT_SECS` (600 s) exits 28. Paths in
arguments are WSL paths (`/home/<you>/...`). Run `cx-doctor` once first: `cx-wsl` takes its tool
paths from the host record. From the Windows session it forwards into WSL and records what it
finds; for your full interactive PATH, run `/conductor:doctor` in a Claude Code session in WSL,
or `~/.conductor/runtime/current/bin/cx-doctor` in a WSL terminal (a plain terminal has no
plugin `bin/` on its PATH; the copy exists after the first forwarded call). The fixes of a
forwarded report act on WSL: run them in a WSL terminal, never in Git Bash.

Before 0.2.2, `cx-doctor --windows` could fail W6 with every plugin file listed as CRLF on a
Git Bash whose bash expands an ANSI-C `$'\r'` inside a substitution to empty (measured with
bash 5.3.15, x86_64-pc-cygwin, and grep 3.0): a false positive. 0.2.2 checks for CRs with
`grep -U` and a CR held in a variable, so W6 lists only files that really hold a CR; if it
still lists every file, check one by hand with `od -c FILE | grep -m1 '\\r'`.

When Copilot's keyring login is unreachable through `wsl.exe`, the doctor's token-file fix
(`~/.conductor/secrets/copilot-token`, mode 0600, a fine-grained PAT) makes `cx-run`'s Copilot
lanes and `cx-wsl ghcp-*` export `COPILOT_GITHUB_TOKEN` for that run only; shell steps through
`cx-wsl bash -s` do not get it.

### Allow rules (no permission prompts, U2)

The rules are narrow: one per command form the skill runs, and nothing that would start an
executor outside `cx-run` (no `agy`, `agy-delegate`, `ghcp-delegate` or job rule). `cx-doctor`
(D25) lists the missing ones; it never edits settings itself.

- **In WSL** (`~/.claude/settings.json`): `Bash(cx-doctor:*)`, `Bash(cx-init:*)`,
  `Bash(cx-run:*)`, `Bash(cx-job:*)`, `Bash(cx-wsl grok:*)`, `Bash(cx-wsl ghcp-ci-debug:*)`,
  `Bash(ghcp-cloud list:*)`, `Bash(ghcp-cloud view:*)`, `Bash(. "$HOME/.conductor/out/:*)` (the
  line that starts every hand step), `Bash(git -C "$WT" push:*)` and `Bash(gh pr:*)`.
- **On Windows** (the Windows-side settings): `Bash(cx-doctor:*)`, `Bash(cx-init:*)`,
  `Bash(cx-run:*)` and `Bash(cx-job:*)` (they forward themselves, so these two cover every
  executor run), `Bash(cx-wsl ghcp-ci-debug:*)`, `Bash(cx-wsl ghcp-cloud list:*)`,
  `Bash(cx-wsl ghcp-cloud view:*)` and `Bash(cx-wsl gh pr:*)`.

Never add `Bash(cx-wsl:*)`: it also allows `cx-wsl bash -c` and `-s`, that is any command in
WSL, without a prompt, which is more than U2's spending, pushing, PRs and `@copilot` reviews;
the doctor warns when it finds it. The skill's `cx-wsl bash -s` steps on Windows (the commit
and gate, Step 5) therefore ask each time.

## Claude Code Projects (beta), cloud sessions and ultracode

Run every thread of a Claude Code Project as a **Work locally** thread on your computer (the
desktop app's "Use this computer from your phone and claude.ai" with the folder added, or
`claude remote-control` running in the folder): such a thread is a Remote Control child that
loads this machine's plugins, hooks and settings, so the conductor works there exactly as in a
local session (`cx-doctor` shows `session bridge`). The executors may still use their own clouds
from it: the skill starts the Copilot cloud agent through `ghcp-cloud` and gates its pull request
like any executor's draft; Grok remote sessions are yours to start (grok 1.0.70 can only resume
one).

Paste `templates/projects-instructions.md` into **Project settings > Memory** (the Projects
instructions, up to 16,000 characters). It tells every thread to run locally, sets the
precedence (your messages, then those instructions and `CLAUDE.md`, then the conductor policy,
then coordinator briefs), and says that the conductor shares its pool slots between threads: at
most `cap_agy` agy, `cap_copilot` Copilot and `cap_grok` Grok runs at a time on the computer,
agy launches one at a time (`cx-run` takes the slot for every executor run, and `cx-wsl` for
its executor calls), and a full pool gives up with `NO_CAPACITY`, exit 28,
after 10 minutes (`CX_SLOT_WAIT_SECS`), so the next pool takes the work. Do not add
the conductor under Project settings > Plugins: claude.ai refuses plugins with a top-level
`bin/`, and the cloud has no executors anyway.

Anthropic's docs say desktop app sessions opened on a `\\wsl.localhost\...` folder (or in the
WSL environment) run inside WSL and load no plugins, but on this setup a desktop session in WSL
did load the conductor (2026-11-01). `cx-doctor` checks the session it runs in: ✓ D30 when the
plugin is loaded, ! when it is not. If it shows !, use a desktop session on a Windows folder (it
forwards into WSL), `claude` in a WSL terminal, or `claude remote-control` in WSL for Work
locally threads on a repo that lives in WSL (a Remote Control session in WSL loaded the plugin
in the 2026-11-01 run; a Work locally project thread is still to be checked).

In a cloud session (`CLAUDE_CODE_REMOTE`, a cloud thread, claude.ai/code) the conductor never
fails the session: the session-start hook injects a short "conductor inactive" notice instead of
the policy, and every `cx-*` command exits 43 with a one-line note before probing anything. A
BYOC or self-hosted runner (any `CLAUDE_CODE_ENVIRONMENT_KIND` but `bridge`) counts as cloud
unless option `exec_host` is `local`. A Git Bash or WSL host is never treated as a cloud
session, whatever the variables say: Anthropic's cloud containers are plain Linux, and the
conductor must not switch itself off on your own computer.

Ultracode is normally off and the plugin cannot turn it on. When it is on, workflows run the
Claude stages and the own-subagent pool, while executor lanes start from the main turn between
workflows: a SubagentStart hook gives every workflow and Agent-tool subagent the rule that it
never runs Copilot, Grok or Antigravity directly (`EXECUTOR_NEEDED` otherwise), unless its task
names a `cx-run --background` command, which takes the shared pool slots like any other run. Claude-pool
agents work in the task's `~/.cx-wt` worktree (from Windows: file tools on its `\\wsl.localhost`
path, commands through `cx-wsl bash -c`). `cx-doctor` reports the workflow settings it can see
(D32, W11).

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
| 13 | `CLI_MISSING` | Executor binary or sibling wrapper not found (`cx-wsl`: no host record yet, run `cx-doctor` first) |
| 14 | `MODEL_UNAVAILABLE` | Model, slug or effort refused before any model call |
| 15 | `PERMISSION_DENIED` | A denied write, or a denial with no answer or diff |
| 16 | `SANDBOX_BLOCKED` | Claude Code's Bash sandbox blocks the executor: rerun outside it |
| 20–28 | `GATE_FAILED` … `NO_CAPACITY` | Gate red (`cx-run --finish` of the cloud lane; `cx-gate` in Phase 3), model mismatch (21), wrong tree (22, agy paused until `cx-job unpause agy`), task contract edited (23), tampering (24: the worktree's `.git` rewritten during a run, or the skill's Step 3 `BRANCH_TAMPERED`), the repo's setup failed (25), flag contract (26: the CLI's help lacks a flag the lane passes), partial output (27), no capacity (28: a pool full for `CX_SLOT_WAIT_SECS`, disabled or paused) |
| 40 | `FORWARD_FAILED` | `wsl.exe` missing or failed, distribution missing, or the WSL VM stopped |
| 41 | `RUNTIME_MISSING` | No runtime copy in WSL (or a version mismatch): `cx-doctor --install-runtime` |
| 42 | `PATH_UNMAPPABLE` | A path (or the working directory) has no equivalent on the other side |
| 43 | `HOST_UNSUPPORTED` | This host cannot do this (a cloud session, Cygwin, `exec_host=local` on Git Bash, Docker before v1.1) |
| 44 | `CRLF_CORRUPT` | A runtime file still contains CR |
| 75 | `RUNNING` | `cx-job result`/`wait`: the job is still queued or running |
| 126 | — | A worker shim blocked an agent CLI inside a conductor worker |
| 130 | `CANCELLED` | INT, TERM or HUP |

Every exit outside 0, 1 and 126 prints exactly one `CX_SIGNAL {json}` line, last on stderr;
`cx-wsl` passes the tool's own status and output through unchanged (its own failures, such as
28 for a full pool, follow the table).

## Status

| Phase | Deliverable | State |
|---|---|---|
| 1 | Manifests, libraries, host layer and forwarding, session kinds (cloud refusal, never on Git Bash or WSL), `cx-doctor`, `cx-init`, `cx-wsl`, policy and subagent hooks, Projects instructions template, worker shims, skill and commands (hand-dispatched lanes, the agy lock, the Copilot cloud agent with its gate), hermetic tests | 0.1.0 |
| 2 | The cross-process pool slots (`scripts/lib/locks.sh`, `flock`) taken by every executor path; the adapters, `cx-run`, `cx-job`, the normalizer, the ledger, the worker environment, the `copilot-cloud` lane and `cx-init --user-grants`; the skill and policies route through `cx-run`/`cx-job`. Not built: the optional `conductor:cx-runner` agent, its fail-closed gate, the `opus-pools` workflow and D33 (ultracode is normally off) | this release (0.2.0) |
| 3 | `cx-gate`, conductor commit, `cx-fanout`, integration queue | specified |
| 4 | Windows end to end, review lane, GitHub | specified |
| v1.1 | Docker lanes | specified |

Development: `bash tests/run-tests.sh` (stubs only; no network, no credits). See `CLAUDE.md`.

## Attribution

None needed: original work. The engineering conventions follow the author's own ghcp plugin.
MIT licensed (`LICENSE`).
