---
name: conductor
description: Route work across the subscriptions Claude Code conducts - GitHub Copilot CLI (through the ghcp plugin), Grok Build (raw CLI) and Antigravity (raw agy for Opus, the antigravity plugin for Gemini) - while Claude owns the spec, the gates and the merge. Use when deciding which subscription or model should do a task, when delegating or offloading work, for Opus 5.5 fan-out or parallel workers, when Copilot, Grok, Antigravity or agy is mentioned, for cross-model or second-opinion review, PR or CI triage, media understanding or Google-grounded research, for cx-run, cx-job, cx-doctor, cx-init or cx-wsl, and for worktree task contracts (.conductor/task.md).
---

# conductor: Claude conducts, the subscriptions execute

**If you are a subagent or a workflow agent, do not run anything in this skill: return `EXECUTOR_NEEDED: <lane> - <reason>` and let the main session dispatch, unless your task names a `cx-run --background` command: then run only that, and `cx-job wait` for it.**

Section numbers (§) refer to `docs/DESIGN.md` in this plugin; a change there updates this file
in the same commit.

## 1. Roles (§0.3)

- **Claude owns the spec, the gates and the merge.** Executors draft. Claude writes the
  acceptance tests and the task contract before delegating, commits the result itself, reruns
  the checks on a clean checkout and decides what merges.
- **Autonomy (U2).** Without asking, you may spend Copilot credits and agy quota, push `cx/*`
  branches, open pull requests and request `@copilot` reviews.
- **No spend caps (U3).** There is no per-call or per-session credit cap and you never add or
  suggest one. `copilot_reserve_pct` defaults to `0` (off); the `cap_*` options are
  concurrency limits, not spend caps.
- **No data restrictions (U4).** Every pool is enabled for every repo (`.cx/routes.json`
  `pools` all true) unless the repo's `routes.json` says otherwise.
- **Phase 2.** You dispatch with `cx-run` and `cx-job` (section 4), which reach the sibling
  plugins' wrappers (ghcp, antigravity) and the raw Grok and agy CLIs for you; you still commit
  and gate by hand (Step 3) until Phase 3. The conductor never uses the grok-build plugin.

## 2. Routing (§6.1, §6.2)

### Lanes

| Lane id | Executor and model | Pool | Writes | Command |
|---|---|---|---|---|
| `claude` | Claude Code, `claude-opus-5-5`, effort up to `max` | Claude plan (the pool to conserve) | yes | Your own Task/Agent subagents: `cx-run --exec claude`, then `--finish` (Step 2) |
| `agy-opus` | agy, `claude-opus-5-5-{medium,high}` | Ultra Claude/GPT bucket | yes (static grant) | `cx-run --exec agy` (Step 2) |
| `copilot-opus` | ghcp, `claude-opus-5.5` at effort high | Copilot credits | yes | `cx-run --exec copilot` (Step 2) |
| `copilot-fusion` | ghcp Fusion Standard / Max | Copilot credits | yes | `cx-run --exec copilot --fusion standard\|max` (mechanical fallback; both Opus pools drained) |
| `copilot-gpt` | ghcp, `gpt-6.1-sol` (`gpt-6-astra` critique, `gpt-6-luna` text) | Copilot credits | no | `cx-run --mode read --exec copilot`, `--mode review --family gpt` (Steps 2, 4) |
| `copilot-github` | Copilot code review, `ghcp-ci-debug`, the Copilot cloud agent (`cx-run --exec copilot-cloud`, through ghcp's `ghcp-cloud`); ghcp's GitHub mode (`--github`) only for a task meant to act on GitHub | Copilot credits (the cloud agent also Actions minutes) | via PR; `--github` writes on GitHub as you | Step 5 |
| `grok` | Grok Build 1.0.70, `-m grok-4.7` | xAI weekly first-party pool | yes (acceptEdits + allow-list) | `cx-run --exec grok` (Step 2) |
| `agy-gemini` | `agy-delegate`, `Gemini 4 Argon (High)` / `gemini-3.8-flash-high` | Ultra Gemini quota (not the Claude/GPT bucket) | no | `cx-run --mode read --exec agy`, `--mode review --family gemini` (Steps 2, 4) |
| `agy-media` | `agy-media`, `/antigravity:research` | Ultra Gemini quota | machine-wide: both always pass `--yolo` | none: not used outside Docker (v1.1 lane) |

### Routing table

Rules for every writing task: one task, one executor, one worktree, one `cx/<id>` branch; the
contract is `.conductor/task.md`; the repo's `setup` runs first; the conductor commits and
gates. "Gate" = you rerun the repo's checks on a clean checkout of your commit, then the
integrated gate at merge.

| Task type | Primary (lane · model · effort) | Fallback | Verification |
|---|---|---|---|
| Architecture / hard reasoning | `claude` · xhigh (max for one-way doors) | `copilot-opus` high | You write the ADR; read-only alternatives from `agy-opus` and a critique from `copilot-gpt` (`gpt-6-astra`) are input only |
| Exploration / "where is X" | `grok` · `grok-4.7` medium, read-only, JSON schema `[{file,line,why}]` (Step 2) | `agy-gemini` flash, read-only (register the dir) | Spot-check the cited lines |
| Small (under ~200 lines) or judgement-heavy change | `claude` | — | Normal tests (delegating below the break-even is a measured loss) |
| Debugging / root cause | `claude` owns the hypotheses; `grok` high writes repro scripts, `git bisect run`, log digests | `agy-gemini` flash for logs over 200k tokens | See the test fail before and pass after |
| Spec'd feature, design-sensitive | Opus lanes in the pool order (section 3), high, only with strong acceptance tests until the A/B (`cx-run --exec auto`) | Next Opus lane; Fusion Max (`--fusion max`) when both pools are drained; then `claude` | Clean-checkout tests, tamper check, diff budget, cross-family review, integrated gate |
| Spec'd feature, mechanical | `grok` · `grok-4.7` high, no subagents, 60 turns max (Step 2) | `copilot-fusion` standard; `agy-gemini` flash high | Same gate plus the `permission required:` stderr scan |
| Bulk edits / migrations | `claude` writes a codemod; `grok` high does the remainder, one worktree per directory shard, 4–6 lanes | `copilot-fusion` standard | Full checks; grep for leftovers; read a 5–10 % sample of hunks |
| Dependency upgrades | `grok` mechanical (lockfiles exempt; only this task type may run `setup`) | `copilot-fusion` standard | Integrated gate; read the upstream changelog; `audit` when routes defines it |
| Exhaustive tests | `grok` high against a contract you wrote | `agy-gemini` flash high; `copilot-gpt` medium | Tests pass on current code, zero source changes, opt-in mutation threshold, sample for tautologies |
| Performance | `claude` profiles and picks the hotspot; an Opus lane (design) or `grok` (mechanical) implements | `claude` | `bench` before and after on the same host; tests still pass |
| First-pass review, local diff | `grok` high, read-only, review JSON schema, on a read-only gate checkout plus a diff file | `agy-gemini` flash read-only | Confirm every accepted finding at file:line |
| First-pass review, GitHub PR | `copilot-github` code review | `grok` review of `gh pr diff N` | You adjudicate; Copilot approvals count only after explicit opt-in |
| Security review | `claude` + `copilot-gpt` (`gpt-6.1-sol` high) + CodeQL / secret scanning; never Grok alone | `agy-gemini` Argon | Adjudicate every finding at file:line |
| Second opinion on Opus-written code | `agy-gemini` Argon High; `copilot-gpt` too on `high_risk` paths | `grok` xhigh | Opus reviewing Opus is never independent (`same_family_as_conductor`) |
| Second opinion on Grok/Gemini-written code | `claude`, depth scaled by risk | — | — |
| PR / issue / CI triage | `copilot-github` (`ghcp-ci-debug`); issues and PRs: fetch with `gh`, then a read-only `copilot-gpt` digest (Step 5; never `--github` for triage) | `grok` digest of `gh run view <id> --log-failed` | Fixes go through the same gates |
| Commit messages, PR text, changelogs | `grok` low/medium, read-only, the diff in a prompt file (Step 2) | `copilot-gpt` (`gpt-6-luna`) | You edit; nothing that is not in the diff |
| Merge conflicts / integration fixes | `claude` | — | Integrated gate |
| UI / frontend code | `claude` designs; Opus lanes make 2–3 parallel variants (one worktree each) | `claude` subagent | Screenshots, a11y lint; you pick and say why |
| Media understanding | v1.1 Docker lane (`agy-media` always passes `--yolo`); until then you read what you can (images, transcripts) | — | Check the timestamps you rely on |
| Web-grounded research | your own WebSearch / WebFetch; `grok` (real time, X) | `agy-gemini` flash on text you fetched (headless agy web search needs `--yolo`, so `/antigravity:research` waits for Docker) | Re-fetch load-bearing citations; at least 2 sources per claim |
| Long-file / codebase digest | `agy-gemini` Argon High above ~200k tokens, flash below (register the dir) | `grok`; Copilot long-context | Spot-check 3–5 file:line references |
| Docs | `grok` medium for reference docs; `claude` for narrative and architecture | `agy-gemini` flash; `copilot-fusion` | Examples and doctests run; you edit |
| Images (v2 lane) | agy's image generator, interactive until headless is confirmed | — | Open each file |
| N-way Opus fan-out | `cx-fanout` (Phase 3); until then one `cx-run --background` per task in the pool order (section 4, Workflows and ultracode) | Fail over down the chain after a worktree reset | Section 5 gates and an integration step per merge |

## 3. Opus 5.5 pool order, A/B status and effort map (§6.3, §6.7)

The order in force is the one the session-start policy names, rendered from option
`opus_lane_order` (default `agy,copilot,claude`: agy, then Copilot, then your own subagents).

- **agy** is flat-fee Ultra quota that refreshes every 5 hours and weekly (unused capacity is
  lost), but its harness has only been measured with Flash and it is the least reliable lane
  (print mode can hang). Until the A/B lands, agy Opus takes only tasks with strong acceptance
  tests, and every agy task contract forbids subagents (they cannot be pinned to Opus).
- **Copilot** is exactly metered (Opus 5.5: 400 / 20 / 500 / 2,000 AI credits per 1M input /
  cached / cache-write / output tokens, from the 20,000-credit month) and also pays for
  reviews and CI triage. Each call carries 13–18k overhead tokens: batch work into large
  calls.
- **Claude** (your own subagents) is the default home for xhigh and max, architecture and
  anything unplaced.

| Requested effort | agy | Copilot (ghcp `--effort`) | Claude |
|---|---|---|---|
| low | Do not spend Opus: Grok low/medium or `gemini-3.8-flash-low` | — | low |
| medium | `claude-opus-5-5-medium` | `--effort medium` | medium |
| high (offload default) | `claude-opus-5-5-high` | `--effort high` | high |
| xhigh | not offered: next pool | only when option `copilot_xhigh_ok` is `true` | **default home** |
| max | not offered | never (issue #5149: hidden reasoning burns the output budget and bills empty turns) | **max** |

Never switch model or effort inside one executor session (it invalidates the cache).

**A/B status: pending.** The Phase 1 blinded A/B decides the order. For each of 3 real tasks
with acceptance tests written first, one identical `task.md`, three worktrees from the same
BASE: `cx-run --exec agy` (raw mode: the served model is verified), `cx-run --exec copilot` and
`cx-run --exec claude`, all at effort high, each its own id and worktree. Commit and gate each (Step 3);
record gate result, diffstat, wall time, credits/quota, served model and how it was verified,
tamper findings. A fresh Claude subagent scores the diffs, copied to files `A`, `B`, `C` in a
random order kept in a sealed file, 1–5 on correctness, minimality, test integrity and
style. agy stays first only if its gate passes are at least Copilot's and its mean score is at
least Copilot's minus 0.3; otherwise the order becomes `copilot,agy,claude`. Raw records stay
under `~/.conductor/ab/2026-11/` (never in a repo); only an aggregate table goes to
`docs/ab-2026-11.md`. Set the result with
`printf '%s' '{"opus_lane_order":"copilot,agy,claude"}' | claude plugin configure conductor@conductor-for-claude-code --values-stdin`
(it takes effect at the next session start).

## 4. Recipe and exact lane commands (§12.2)

`cx-run` runs one task on one lane; `cx-job` runs it in the background. Copy their commands
verbatim. They create the task's worktree, copy the contract and record its hash, run the repo's
`setup`, take the shared pool slot, set every environment prefix, register agy directories and
snapshot the other worktrees for agy, check denials and the served model, and write
`result.json`, one ledger line and one `CX_RESULT` line. You write the contract, commit, gate and
merge. Hand steps remain only where `cx-run` has no lane yet: the commit and gate (Step 3, until
Phase 3's `cx-gate`), GitHub (Step 5) and commit-message drafting. They are written for a Bash
tool in WSL; from the Windows app see "From Windows (Git Bash)" below. Replace `t1` with the
task's id, and `npm ci --prefer-offline` / `npm test` / `npm run lint` / `npx tsc --noEmit`
with the repo's `setup` and `commands` from `.cx/routes.json` (written by `cx-init`).

### Rules for every call

- **Background for long calls.** A write run may take 30 minutes or more: start it with
  `cx-run --background …`, which prints `JOB_ID <id>` at once, and wait for it with ONE
  background Bash call `cx-job wait <id>` with `run_in_background: true` and `timeout: 7200000`
  (the 2-hour maximum; the tool notifies you when it exits). A background call is stopped at
  its timeout too, and the default (30 minutes) is shorter than a 30m run plus setup and agy's
  grace. Only runs with `--timeout 9m` or less, `--dry-run`, `--explain`, the claude dispatch
  and `--finish` may run in the foreground. Never wait by re-checking across turns.
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

**Once per machine** (and again after adding routes commands), from inside the repo:
`cx-init --user-grants` merges `write_file(<worktree_root>)` and one `command(<cmd>)` per routes
command into `~/.gemini/antigravity-cli/settings.json` (agy's write grant), adds the
`cx-workspace` sandbox profile to `~/.grok/sandbox.toml` and `[cli] auto_update = false` to
`~/.grok/config.toml`, keeping a `.cx-bak` copy of every file it changes (`--dry-run` shows
what it would do). Never use the yolo / skip-permissions flags (`--yolo`,
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

`id` and `base` may be left out (`--id`, `--base`, else a generated id and `HEAD`); `commands`
are the only shell commands the executor may run (default: the routes commands);
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
by `cx-run`):

```bash
. "$HOME/.conductor/out/t1/vars.sh"
{ printf '%s\n\n' 'Write a commit message (a subject under 72 characters, a blank line, a short body) for the diff below. Describe only what the diff shows.'; git -C "$TOP" diff "$BASE" "cx/$ID"; } > "$OUT/msg-prompt.txt"
cx-wsl grok --prompt-file "$OUT/msg-prompt.txt" -m grok-4.7 --effort low --cwd "$TOP" --sandbox read-only --always-approve --no-subagents --output-format plain </dev/null   # a grok slot
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

### Workflows and ultracode (§12.1)

Ultracode is a session setting, normally off: the `ultracode` settings key, `--effort
ultracode`, `/effort ultracode`, or the word "ultracode" typed in a prompt. The plugin can
neither detect nor force it; `cx-doctor` D32 shows what the settings files say. **Ultracode
changes how thorough you are, not who executes.** Every workflow and Agent-tool subagent gets
the conductor's subagent rules (a SubagentStart hook): it never runs Copilot, Grok or
Antigravity directly and never follows this skill's recipes; it returns `EXECUTOR_NEEDED:
<lane> - <reason>` instead, unless its task names a `cx-run --background` command (Phase 2),
which takes the shared pool slots. The hybrid recipe for a fan-out:

1. **Scout or design workflow (Claude only).** It returns the decomposition, with disjoint
   `files` per task.
2. **Main turn: contracts.** Step 1 for every task, with unique ids `t1`…`tn`.
3. **Main turn: executor runs**, in the policy's order: `cx-run --background` per task (Step 2),
   each waited on with one background `cx-job wait <id>` call (`timeout: 7200000`). The pool
   slots cap them across the computer; a job shows `queued` until it gets one.
4. **Claude-pool workflow, in parallel with them**, for the remaining Opus tasks: the main turn
   first runs `cx-run --exec claude --task-file <F> --id <id>` per task (it creates the
   worktree, runs `setup`, marks it `running` so agy's snapshots leave it out, and prints the
   dispatch JSON), then the script below, one agent per task at effort `high` (the §6.3 map,
   not the inherited xhigh), with `wt` = the dispatch's `worktree`; on Windows also `wt_win` =
   its `host_path`, so the prompt names that `\\wsl.localhost\<distro>\…` path for file tools
   and `cx-wsl bash -c 'cd "<wt>" && …'` for commands. Then `cx-run --finish <id>` per task.
5. **Main turn: collect and review.** `cx-job result <id>` per job, then Step 3 per task (the
   claude-pool tasks too) and Step 4; Claude-side reviews may be another workflow, executor
   reviews run from the main turn.

Rules:
- Never `isolation: 'worktree'` or `isolation: 'remote'` for conductor tasks: remote throws in
  workflows, and worktree isolation fences the agent inside `<repo>/.claude/worktrees/`, away
  from `~/.cx-wt` and from Step 3.
- No `agentType` for conductor stages (the optional runner agent is not built while ultracode
  stays off), and never another plugin's delegate agent (`antigravity:antigravity-delegate`,
  `grok-build:grok-delegate`, `ghcp:ghcp-delegate`): they bypass the conductor's contract and
  gates.
- `budget` counts Claude output tokens only (the main loop plus every workflow). Never size
  executor fan-out by it, and never add an executor cap (U3).
- An agent that returns `EXECUTOR_NEEDED`: dispatch that lane from the main turn for that
  task (Step 2), then Step 3. A default workflow agent may run `cx-run --background` and
  `cx-job wait` itself when its task names them (the subagent rules allow it, because those take
  the shared slots); it never runs the hand steps. Jobs keep running when a workflow stops
  early: `cx-job list` shows them.

Claude-pool script (`args`: an array of `{id, wt, effort, wt_win?}` passed as JSON, not as a
string; `wt` is the WSL path, `wt_win` its `\\wsl.localhost` form, set only from Windows):

```js
export const meta = {
  name: 'cx-claude-pool',
  description: 'Conductor own-subagent pool: Claude does Opus tasks in worktrees the main session prepared',
  phases: [{ title: 'Claude pool', detail: 'one agent per task, inside its ~/.cx-wt worktree' }],
}
const tasks = Array.isArray(args) ? args : []
if (!tasks.length) throw new Error('args: an array of {id, wt, effort, wt_win?}, passed as JSON, not as a string')
const OUT = { type: 'object', properties: { digest: { type: 'string' }, tests: { type: 'string' }, executor_needed: { type: 'string' } }, required: ['digest'] }
const where = (t) => t.wt_win
  ? `Your task's worktree is in WSL: use ${t.wt_win} and paths under it for Read, Edit, Write, Glob and Grep, and run every command as cx-wsl bash -c 'cd "${t.wt}" && <command>' (never Git Bash's own git, npm or test tools, never ~, which is your Windows home).`
  : `Your working directory is ${t.wt}: start every Bash command with cd "${t.wt}" && and use only paths under it.`
const res = await parallel(tasks.map((t) => () => agent(
  `Conductor task ${t.id}, Claude pool. ${where(t)} Read .conductor/task.md there and do exactly what it says. Do not commit. Return its DIGEST line as digest and the acceptance tests you ran, with their results, as tests.`,
  { label: `claude:${t.id}`, phase: 'Claude pool', effort: t.effort || 'high', schema: OUT })))
return res.map((r, i) => ({ id: tasks[i].id, ...(r || { digest: 'no result: the agent failed or was skipped' }) }))
```

### In a Claude Code Project (§12.1)

The user's Claude Code Projects (beta) run every thread as a **Work locally** thread on their
computer: a Remote Control child that uses this machine's settings, hooks, permission rules and
plugins (`cx-doctor` shows `session bridge`). Nothing about routing changes. Executors may still
use their own clouds from such a thread (the Copilot cloud agent through `ghcp-cloud`, Step 5;
Grok remote sessions, which the user starts: grok 1.0.70 can only resume one).

- **Precedence**, highest first: (1) the user's own messages in the thread; (2) the Projects
  instructions and the repository's `CLAUDE.md` (standing rules: "no Copilot credits in this
  project" narrows U2); (3) the conductor policy and this skill (defaults for routing, effort
  and gates); (4) a coordinator's brief or relay, which sets the task and its acceptance tests
  but approves nothing the gates or guardrails refuse.
- **Several threads run at once, and they share the pool slots:** at most `cap_agy` agy,
  `cap_copilot` Copilot and `cap_grok` Grok runs at a time across every thread and session on
  this computer, and agy launches one at a time (`cx-run` and `cx-wsl` take the slot for every
  executor run). A full pool waits up to 10 minutes, then `--exec auto` takes the next pool and
  an explicit lane exits 28 (`NO_CAPACITY`): use the next pool in the order instead. Threads
  that share a folder use the folder card's Worktree option, and ids are unique per computer.
- Threads run in auto mode, and a workflow agent's prompt gets no user-intent credit there, so
  executor commands rely on the allow rules `cx-doctor` D25 prints.
- A thread's final text does not reach the project conversation by itself: report through the
  host's reply tool.
- A cloud thread, if one ever happens, gets the cloud notice instead of this skill: Claude does
  the task alone there.

## 5. Guardrails (§6.5) and the after-run checklist

| # | Guardrail | Where (Phase 2) |
|---|---|---|
| G1 | Spec first: acceptance tests and `task.md` before delegating | Step 1; `cx-run` checks line 1 |
| G2 | One task, one executor, one worktree, one branch; two executors only for an explicit cross-model review | `cx-run` (one `cx/<id>` worktree per id) |
| G3 | The conductor commits; checks rerun on a fresh checkout with fresh `setup`; never gate in the worker's tree | Step 3 |
| G4 | Tamper check: tests, lockfiles (unless exempt), CI, test-runner config, `.cx/routes.json`, `.git/*`, `.gitignore`, submodules, agent config, the `task.md` hash; executors may not install dependencies | Step 3 name-only list |
| G5 | Exit 0 is not success: agy denials / finish reason / exit 15; Grok's `permission required:`; Copilot `GHCP_DENIED` / exit 15; and a diff must exist | `cx-run` (15, 3) |
| G6 | Check the served model every run; any mismatch (including `GHCP_FALLBACK` on a Fusion lane) fails the run | `cx-run` (21): Copilot `models_used`, agy raw mode's init event, Grok `modelUsage`; agy wrapper mode and the claude lane record `unverified` |
| G7 | Cross-family review; your own review scaled to risk; every accepted finding confirmed at file:line, every rejected one gets a reason | Step 4 |
| G8 | No self-reported success: a digest you relay ends with "VERIFY THIS" until you verified it | `cx-run`'s `VERIFY THIS:` line |
| G9 | Versions pinned at install level; model and effort passed explicitly every time | `cx-doctor`; `cx-run`'s preflight (26) |
| G10 | Workers fenced by the environment: `CX_WORKER=1`, worker shims, `GROK_CLAUDE_*_ENABLED=false`, scrubbed `COPILOT_*` and API keys; no skip-permissions outside Docker; no conductor content in a repo's `CLAUDE.md` or `.claude/` | `cx-run`'s worker environment; the hand steps' prefixes (never exported); `cx-init` writes nothing there |
| G11 | Secrets: repos with secrets use Docker lanes (v1.1) or exclude pools in `.cx/routes.json` (default all on); Grok always runs under a sandbox profile | routes.json `pools`; the `cx-workspace` profile (`cx-init --user-grants`) |

After every run, before you accept anything:

1. `CX_RESULT` read: `status`, `denied` (G5), `model_served` (G6; `unverified` for agy's
   wrapper mode and the claude lane), `reason`.
2. The `VERIFY THIS:` line followed.
3. `task.md` hash equal (else `SPEC_TAMPERED`); the worktree still on `cx/<id>` (else
   `BRANCH_TAMPERED`); executor commits squashed; a diff exists; the gate on that exact commit.
4. The name-only list read against `allowed_paths`, the protected set (G4) and the repo's
   `diff_budget` (default 400 added + removed lines).
5. Committed by you, with the executor and served model in the message.
6. Gate on the clean checkout `$G`: `setup`, then every routes command, all green.
7. Reviews per Step 4, findings confirmed at file:line.
8. The digest treated as a claim; you read digests, not transcripts.

## 6. Hazards and how they are neutralized (§6.6)

- **The grok-build plugin's SessionEnd hook** also fires on `/clear` and kills and erases its
  session-tagged bridge jobs in the current workspace: never use that bridge for conductor
  work. Its bridge also caps effort, writes unsandboxed with always-approve, fails on prompts
  over 128 KiB and calls an import command 1.0.70 lacks: `cx-run --exec grok` uses the raw CLI.
- **Ungated proactive subagents** `grok-build:grok-delegate` and
  `antigravity:antigravity-delegate`: never use them; `cx-doctor` checks the user-level deny
  rules.
- **Wrappers that hard-code `--yolo`** (`agy-handoff`, `agy-media`, `/antigravity:research`):
  a grant over the whole machine; not conductor lanes, whatever their own docs suggest.
- **Two sibling policies and two nudges**: turn off ghcp's and antigravity's `coding_policy`
  and `delegation_nudge` at user level (and set antigravity's `timeout` to `30m`); the
  conductor injects one policy. `cx-doctor` prints the `claude plugin configure` commands.
- **Shared option names**: both siblings read `CLAUDE_PLUGIN_OPTION_{TIER_PRO,TIMEOUT,…}`:
  never export those; prefix single commands only.
- **Grok imports `~/.claude`** hooks, skills, MCP servers and plugins: the
  `GROK_CLAUDE_*_ENABLED=false` prefix on every Grok run.
- **`/antigravity:migrate` and agy's plugin import** copy every Claude plugin into agy: never
  run them on conductor machines.
- **agy works in its last project root** for a directory it has never seen: `cx-run` registers
  every directory first (`--new-project -p /model`), launches one agy at a time and compares
  tree snapshots (22 `WRONG_TREE` pauses agy dispatch until `cx-job unpause agy`; never restore
  a tree you did not create in this task).
- **agy print mode hangs** (after the result, without a TTY, with long prompts): `cx-run` keeps
  the prompt tiny (the contract is a file), kills the session 5 seconds after the result event
  and bounds every run.
- **`agy-job`** is not a conductor form (`cx-job` is). If you meet one: its `result` exits 0
  whatever the job's rc (read `<jobdir>/rc`), and its status output contains the job's task
  text (match `  state=running` exactly).
- **Parallel `--continue` races**: resume only by explicit session or conversation id.
- **Copilot 1.0.106-1** lacks the Fusion flag strings: stay on 1.0.105.
- **A Fusion refusal** re-runs on plain `auto` (billed) and prints `GHCP_FALLBACK`: a model
  mismatch on a Fusion lane.
- **Grok's `worker` subcommand** registers this machine as a remote worker for a third-party
  service: never run it (`cx-doctor` warns when one is running; leader-mode processes are
  normal).
- **Claude Code's Bash sandbox** blocks every executor (Copilot exits 16; agy and Grok fail
  with permission or read-only-file-system errors, or hang) and the worktree and
  `~/.conductor` writes: run them outside the sandbox; report exit 16, never retry silently.
- **The Bash tool kills foreground calls** at 2–10 minutes and background calls at their
  `timeout` (default 30 minutes): background calls with `timeout: 7200000` (section 4).
- **Billing switches in the environment** (`XAI_API_KEY`, `GEMINI_API_KEY`,
  `GOOGLE_API_KEY`, `COPILOT_ALLOW_ALL`, `COPILOT_PROVIDER_BASE_URL`, `COPILOT_AUTO_TIER`,
  `COPILOT_MODEL`): `cx-run` unsets them per run, the hand steps' `env -u` prefixes; `cx-doctor`
  warns.
- **`AGENTS.md` imported into `CLAUDE.md`** would bind you to worker rules: the worker-only
  rules apply only where `.conductor/task.md` exists.
- **A git-based line-ending fix** run in a plugin cache copy resolves the enclosing repo:
  never use `git reset` there; use `cx-doctor`'s fixes.

## 7. Exit codes (§4.1)

Every `cx-*` command uses one table. Every exit other than 0, 1 and 126 prints exactly one
`CX_SIGNAL {json}` line, the last line on stderr; exit 1 prints a `<prog>: …` message only.
`cx-wsl` returns the passed-through tool's own status and adds no `CX_*` line to it. `cx-run`
prints one `CX_RESULT` line per run (also on most failures) before its `CX_SIGNAL`; `cx-job
result` and `wait` relay the job's `CX_*` lines and exit with its code.

| Exit | Status | Meaning |
|---|---|---|
| 0 | — | Success |
| 1 | — | Usage error, invalid argument, refused request (no `CX_SIGNAL`) |
| 2 | FAILED | Unexpected failure, unparseable or unclassified executor output |
| 3 | EMPTY_OUTPUT | Executor exited 0 with no answer and (write mode) no diff |
| 4 | CHECKS_FAILED | `cx-doctor`: at least one ✗ check |
| 5 | EXISTS | `cx-init`: a bundle file exists and differs; nothing written |
| 10 | QUOTA_EXHAUSTED | Quota or rate limit |
| 11 | AUTH_REQUIRED | Executor not logged in |
| 12 | TIMEOUT | Wall clock expired |
| 13 | CLI_MISSING | Executor binary or sibling wrapper not found (`cx-wsl`: no host record) |
| 14 | MODEL_UNAVAILABLE | Model, slug or effort refused before any model call |
| 15 | PERMISSION_DENIED | A denied write, or any denial with no answer or diff |
| 16 | SANDBOX_BLOCKED | Claude Code's Bash sandbox blocks the executor |
| 20 | GATE_FAILED | Tests, lint, typecheck, verdict parser, diff budget or integrated gate red |
| 21 | MODEL_MISMATCH | Served model differs from the requested one (incl. `GHCP_FALLBACK` on a Fusion lane) |
| 22 | WRONG_TREE | Files changed outside the task's worktree |
| 23 | SPEC_TAMPERED | `.conductor/task.md` hash mismatch |
| 24 | TAMPERED | A protected path changed, or the executor left the task branch (`BRANCH_TAMPERED`) |
| 25 | ENV_FAILED | The repo's `setup` command failed (not charged to the executor) |
| 26 | VERSION_MISMATCH | CLI version is not the pin; lane refused before running |
| 27 | PARTIAL | Partial output (agy print timeout expired with rc 0) |
| 28 | NO_CAPACITY | Every eligible lane at its cap, disabled or paused (an explicit `cx-run` lane or `cx-wsl`: no pool slot within `CX_SLOT_WAIT_SECS`, 10 minutes) |
| 40 | FORWARD_FAILED | Git Bash to WSL: `wsl.exe` or the distro missing, or wsl.exe failed or died |
| 41 | RUNTIME_MISSING | No conductor runtime copy in WSL, or a version mismatch |
| 42 | PATH_UNMAPPABLE | A path has no equivalent on the other side (e.g. `\\server\share`) |
| 43 | HOST_UNSUPPORTED | This host cannot do this (Cygwin, `exec_host=local` on Git Bash, `--host docker` before v1.1) |
| 44 | CRLF_CORRUPT | A runtime file still contains CR after stripping |
| 75 | RUNNING | Job still running (Phase 2 `cx-job`) |
| 126 | — | A worker shim: `blocked: CX_WORKER` (no `CX_SIGNAL`) |
| 130 | CANCELLED | INT / TERM / HUP, or a job kill |

Codes 2, 3, 10–16 and 130 equal ghcp's and agy-delegate's. Sibling codes that matter when
you meet the wrappers directly (`cx-wsl`, the hand steps):

- ghcp (`ghcp-delegate`, `ghcp-job`'s `result`, `ghcp-handoff`): 10 quota, 11 not logged in, 12
  timeout, 13 `copilot` missing, 14 model or Fusion unavailable, 15 permission denied, 16
  sandbox, 130 cancelled.
- `agy-delegate`: 12 timeout or PARTIAL output; 15 a missing write grant (report it, never
  add the yolo flag).
- `ghcp-handoff`: 20 the tests stayed red.
- `ghcp-job`'s `result`: 75 while the job runs; otherwise the job's rc.
- `agy-job`'s `result`: 2 while the job runs; 0 whatever the finished job's rc (read its `rc`
  file).

## 8. Troubleshooting

- **Exit 16** (Copilot, or a `cx-doctor` probe): the Bash call ran inside Claude Code's
  sandbox. Rerun the same call outside the sandbox.
- **agy or Grok fails with permission, `EROFS` or `Read-only file system` text, or agy
  hangs**, inside the sandbox: rerun unsandboxed. agy has no exit 16, so this shows as 2, 11
  or a hang.
- **Exit 130 after about 2 minutes**: a `cx-run` (or ghcp) call ran in the foreground and the
  Bash tool killed it (billed tokens). Rerun it with `--background` and wait with `cx-job wait`.
- **Exit 11**: `cx-doctor --login-help <cli>` prints the fresh-login command; the user runs it
  in a WSL terminal. Logged in from a WSL terminal but not through `cx-wsl`: the keyring is
  unreachable through wsl.exe (no D-Bus); `cx-doctor --windows` explains the token-file route.
- **Exit 26 / version pins**: `cx-doctor` prints the install command for the pinned version
  (Copilot 1.0.105, Grok 1.0.70) and the auto-update exports for `~/.profile`.
- **`WRONG_TREE`** (exit 22): a worktree of the repo changed while agy ran, usually agy writing
  into its last project root (the main checkout or a previous task's worktree). The changed
  trees are in `~/.conductor/state/agy-paused` and the run's `agy.trees.changed`; report them
  with their diff; restore only a tree you created in this task, and ask the user when it may
  belong to another thread or lane. agy dispatch stays paused (`--exec auto` skips agy, `--exec
  agy` exits 28) until `cx-job unpause agy`. Known false alarm: someone editing the main
  checkout during the run.
- **`NO_CAPACITY`** (exit 28): every slot of the pool (or the agy launch lock) stayed busy for
  `CX_SLOT_WAIT_SECS` (10 minutes), the pool's cap is 0, it is off in `routes.json`, or agy is
  paused; use the next pool in the order. A step of an older skill copy may still hold Phase 1's
  `~/.conductor/locks/agy`; agy slots wait for it too.
- **Exit 25 `ENV_FAILED`**: the repo's `setup` failed in the fresh worktree (`setup.log` in the
  out directory); the executor never started: fix `setup` in `.cx/routes.json`, then re-dispatch
  with `--reuse-worktree`.
- **Exit 23 `SPEC_TAMPERED`** from `cx-run`: the executor edited `.conductor/task.md`; do not
  commit; fail over (Step 3).
- **Exit 1 from `cx-run`** with "is one of Claude Code's own worktrees": run it from the main
  checkout or pass `--repo`.
- **`BRANCH_TAMPERED`** (Step 3, exit 24): the executor created or switched branches. Nothing
  was committed or gated; fail over after the reset. After a CI fix in apply mode
  (`ghcp-ci-debug --apply --dir "$WT"`), hand its edits back to `cx/<id>` first (Step 5).
- **`permission required:`** on Grok's stderr: a denied tool (even with rc 0). Add the needed
  routes command to the allow list or change the task; never widen to `--always-approve` on a
  writer.
- **gh without `@copilot` reviewer support**: upgrade gh or use the REST fallback of Step 5.
- **Exit 13 from `cx-run` or `cx-wsl`**: no host record yet (`cx-run` refreshes a stale one); run `cx-doctor` from this session (it
  forwards and records), or have the user run `/conductor:doctor` in a Claude Code session in
  WSL (or `~/.conductor/runtime/current/bin/cx-doctor` in a WSL terminal, once the runtime copy
  exists).
- **A background call ended after exactly 30 minutes**: it ran with the default `timeout`;
  rerun it with `timeout: 7200000`.
- **The session-start notice says the plugin copy has CRLF line endings**: the conductor
  cannot run; do the work yourself, and give the user the fix the notice names.
