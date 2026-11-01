---
name: conductor
description: Route work across the subscriptions Claude Code conducts - GitHub Copilot CLI (through the ghcp plugin), Grok Build (raw CLI) and Antigravity (raw agy for Opus, the antigravity plugin for Gemini) - while Claude owns the spec, the gates and the merge. Use when deciding which subscription or model should do a task, when delegating or offloading work, for Opus 5.5 fan-out or parallel workers, when Copilot, Grok, Antigravity or agy is mentioned, for cross-model or second-opinion review, PR or CI triage, media understanding or Google-grounded research, for cx-doctor, cx-init or cx-wsl, and for worktree task contracts (.conductor/task.md).
---

# conductor: Claude conducts, the subscriptions execute

**If you are a subagent or a workflow agent, do not run anything in this skill: return `EXECUTOR_NEEDED: <lane> - <reason>` and let the main session dispatch.**

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
- **Phase 1.** There is no `cx-run` yet. You dispatch by hand with the exact commands of
  section 4, through the sibling plugins' wrappers (ghcp, antigravity) and the raw Grok and agy
  CLIs. The conductor never uses the grok-build plugin.

## 2. Routing (§6.1, §6.2)

### Lanes

| Lane id | Executor and model | Pool | Writes | Phase 1 command |
|---|---|---|---|---|
| `claude` | Claude Code, `claude-opus-5-5`, effort up to `max` | Claude plan (the pool to conserve) | yes | Your own Task/Agent subagents (Step 2d) |
| `agy-opus` | agy, `claude-opus-5-5-{medium,high}` | Ultra Claude/GPT bucket | yes (static grant) | Step 2a, after registering the directory |
| `copilot-opus` | ghcp, `claude-opus-5.5` at effort high | Copilot credits | yes | Step 2b |
| `copilot-fusion` | ghcp Fusion Standard / Max | Copilot credits | yes | Step 2b (mechanical fallback; both Opus pools drained) |
| `copilot-gpt` | ghcp, `gpt-6.1-sol` (`gpt-6-astra` critique, `gpt-6-luna` text) | Copilot credits | no | Step 2e, Step 4 |
| `copilot-github` | Copilot code review, `ghcp-ci-debug`, the Copilot cloud agent (`ghcp-cloud`); ghcp's GitHub mode (`--github`) only for a task meant to act on GitHub | Copilot credits (the cloud agent also Actions minutes) | via PR; `--github` writes on GitHub as you | Step 5 |
| `grok` | Grok Build 1.0.70, `-m grok-4.7` | xAI weekly first-party pool | yes (acceptEdits + allow-list) | Step 2c |
| `agy-gemini` | `agy-delegate`, `Gemini 4 Argon (High)` / `gemini-3.8-flash-high` | Ultra Gemini quota (not the Claude/GPT bucket) | no | Step 2e, Step 4 |
| `agy-media` | `agy-media`, `/antigravity:research` | Ultra Gemini quota | machine-wide: both always pass `--yolo` | none: not used outside Docker (v1.1 lane) |

### Routing table

Rules for every writing task: one task, one executor, one worktree, one `cx/<id>` branch; the
contract is `.conductor/task.md`; the repo's `setup` runs first; the conductor commits and
gates. "Gate" = you rerun the repo's checks on a clean checkout of your commit, then the
integrated gate at merge.

| Task type | Primary (lane · model · effort) | Fallback | Verification |
|---|---|---|---|
| Architecture / hard reasoning | `claude` · xhigh (max for one-way doors) | `copilot-opus` high | You write the ADR; read-only alternatives from `agy-opus` and a critique from `copilot-gpt` (`gpt-6-astra`) are input only |
| Exploration / "where is X" | `grok` · `grok-4.7` medium, read-only, JSON schema `[{file,line,why}]` (Step 2c) | `agy-gemini` flash, read-only (register the dir) | Spot-check the cited lines |
| Small (under ~200 lines) or judgement-heavy change | `claude` | — | Normal tests (delegating below the break-even is a measured loss) |
| Debugging / root cause | `claude` owns the hypotheses; `grok` high writes repro scripts, `git bisect run`, log digests | `agy-gemini` flash for logs over 200k tokens | See the test fail before and pass after |
| Spec'd feature, design-sensitive | Opus lanes in the pool order (section 3), high, only with strong acceptance tests until the A/B | Next Opus lane; Fusion Max (`ghcp-handoff`, tier `pro`) when both pools are drained; then `claude` | Clean-checkout tests, tamper check, diff budget, cross-family review, integrated gate |
| Spec'd feature, mechanical | `grok` · `grok-4.7` high, no subagents, 60 turns max (Step 2c) | `copilot-fusion` standard; `agy-gemini` flash high | Same gate plus the `permission required:` stderr scan |
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
| Commit messages, PR text, changelogs | `grok` low/medium, read-only, the diff in a prompt file (Step 2e) | `copilot-gpt` (`gpt-6-luna`) | You edit; nothing that is not in the diff |
| Merge conflicts / integration fixes | `claude` | — | Integrated gate |
| UI / frontend code | `claude` designs; Opus lanes make 2–3 parallel variants (one worktree each) | `claude` subagent | Screenshots, a11y lint; you pick and say why |
| Media understanding | v1.1 Docker lane (`agy-media` always passes `--yolo`); in Phase 1 you read what you can (images, transcripts) | — | Check the timestamps you rely on |
| Web-grounded research | your own WebSearch / WebFetch; `grok` (real time, X) | `agy-gemini` flash on text you fetched (headless agy web search needs `--yolo`, so `/antigravity:research` waits for Docker) | Re-fetch load-bearing citations; at least 2 sources per claim |
| Long-file / codebase digest | `agy-gemini` Argon High above ~200k tokens, flash below (register the dir) | `grok`; Copilot long-context | Spot-check 3–5 file:line references |
| Docs | `grok` medium for reference docs; `claude` for narrative and architecture | `agy-gemini` flash; `copilot-fusion` | Examples and doctests run; you edit |
| Images (v2 lane) | agy's image generator, interactive until headless is confirmed | — | Open each file |
| N-way Opus fan-out | `cx-fanout` (Phase 3); in Phase 1 dispatch by hand in the pool order | Fail over down the chain after a worktree reset | Section 5 gates and an integration step per merge |

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
BASE: agy-opus-high (Step 2a, preferably the raw arm), copilot-opus-high (Step 2b) and a
Claude subagent at high (Step 2d), each one background call. Commit and gate each (Step 3);
record gate result, diffstat, wall time, credits/quota, served model and how it was verified,
tamper findings. A fresh Claude subagent scores the diffs, copied to files `A`, `B`, `C` in a
random order kept in a sealed file, 1–5 on correctness, minimality, test integrity and
style. agy stays first only if its gate passes are at least Copilot's and its mean score is at
least Copilot's minus 0.3; otherwise the order becomes `copilot,agy,claude`. Raw records stay
under `~/.conductor/ab/2026-11/` (never in a repo); only an aggregate table goes to
`docs/ab-2026-11.md`. Set the result with
`printf '%s' '{"opus_lane_order":"copilot,agy,claude"}' | claude plugin configure conductor@conductor-for-claude-code --values-stdin`
(it takes effect at the next session start).

## 4. Phase 1 recipe and exact lane commands (§12.2)

Copy these commands verbatim, prefixes included. They are written for a Bash tool running in
WSL, where the sibling wrappers are on the Bash tool's PATH; from the Windows app see "From
Windows (Git Bash)" below. Replace `t1` with the task's id, and `npm ci --prefer-offline` /
`npm test` / `npm run lint` / `npx tsc --noEmit` with the repo's `setup` and `commands` from
`.cx/routes.json` (written by `cx-init`; one `--allow-shell` or `--allow 'Bash(...)'` per
command).

### Rules for every call

- **Fresh shell per call.** Each Bash tool call starts a fresh shell. Step 1 writes the task's
  variables to `$OUT/vars.sh`; every later call starts with
  `. "$HOME/.conductor/out/<id>/vars.sh"`.
- **Background for long calls.** Any call that may run longer than 9 minutes (every executor
  run with `--timeout 30m`, `ghcp-handoff`, a slow gate) is ONE background Bash call with
  `run_in_background: true` and `timeout: 7200000` (the tool notifies you when it exits), or is
  started as a `ghcp-job` and waited for inside one such background call with the wait lines
  below (agy has no job form: its lock and tree snapshots must span the whole run). A background call is stopped at its timeout too, and the default (30
  minutes) is shorter than a 30m run plus registration, the raw arm's 35m bound or
  `ghcp-handoff`'s delegation, tests and fix-up: pass `timeout: 7200000` (the 2-hour maximum)
  on every background executor or wait call, and keep each lane's own clock below it.
  Only calls with `--timeout 9m` or less may run in the foreground. A foreground call killed at
  the Bash tool's timeout wastes the run: ghcp forwards TERM to Copilot (billed tokens, exit
  130), and agy ignores TERM and is orphaned. Never wait by re-checking across turns.
- **Outside the sandbox.** Executor calls (`ghcp-*`, `agy-*`, `agy`, `grok`, `gh`, `git push`)
  and every step that writes under `worktree_root` (default `~/.cx-wt`) or `~/.conductor` run
  outside Claude Code's Bash sandbox: Copilot writes `~/.copilot`, agy `~/.gemini` and
  `~/.antigravity`, Grok `~/.grok`.
- **Environment prefixes**, written in front of each command and never exported (an export
  would turn your own shell into a "worker" and leak into unrelated commands). Never export
  `CLAUDE_PLUGIN_OPTION_*` either: both sibling plugins read the same names.

  | Commands | Prefix |
  |---|---|
  | `grok` | `env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1 "${G_ENV[@]}"` (`G_ENV` from `vars.sh`: `GROK_DISABLE_AUTOUPDATER=1` and the five `GROK_CLAUDE_*_ENABLED=false`) |
  | `agy`, `agy-delegate`, `agy-job` | `env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true` |
  | `ghcp-delegate`, `ghcp-job`, `ghcp-handoff`, `ghcp-ci-debug` | `env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false` |

  `XAI_API_KEY` would bill the xAI API account instead of the subscription, `GEMINI_API_KEY` /
  `GOOGLE_API_KEY` the Gemini key instead of the plan, and the `COPILOT_*` variables can
  change Copilot's model, permissions or endpoint. `GH_TOKEN` / `GITHUB_TOKEN` are left alone
  (they may be how Copilot signs in).

**Once per machine (agy writes):** merge into `~/.gemini/antigravity-cli/settings.json`:

```json
{"permissions": {"allow": ["write_file(/home/<you>/.cx-wt)", "command(npm test)"]}}
```

One `command(<cmd>)` per routes command; the `write_file` grant is recursive and covers only
the worktree root (use `worktree_root`'s value when it is not the default). Never use the
yolo / skip-permissions flags (`--yolo`, `--dangerously-skip-permissions`) outside Docker,
and never use `agy-handoff`, `agy-media` or `/antigravity:research` for conductor work (they
always pass them: a grant over the whole machine).

### Step 1: worktree and contract

Outside the sandbox; foreground unless `setup` is slow, run from inside the repo. Pick a short
id that is unused on this computer: no `cx/<id>` branch in the repo and no
`~/.conductor/out/<id>` (other threads and repos share that directory). `vars.sh` also defines
`trees`, the snapshot Step 2a compares.

```bash
ID=t1
TOP=$(git rev-parse --show-toplevel); BASE=$(git -C "$TOP" rev-parse HEAD)
WT="$HOME/.cx-wt/$(basename "$TOP")-$ID"; OUT="$HOME/.conductor/out/$ID"; mkdir -p "$OUT"
REPO=$(gh repo view --json url --jq .url 2>/dev/null | sed -E 's#^https?://##')   # host/owner/repo for gh -R; gh resolves ssh host aliases
[ -n "$REPO" ] || REPO=$(git -C "$TOP" remote get-url origin 2>/dev/null | sed -E 's#^[a-z+]+://([^@/]*@)?##; s#^[^@/]*@([^:/]+):#\1/#; s#^([^/:]+):[0-9]+/#\1/#; s#\.git$##')   # gh not logged in: from the URL
P='Read .conductor/task.md in the working directory and do exactly what it says. Do not spawn subagents. End with the DIGEST: line it specifies.'
{ printf '%s=%q\n' ID "$ID" TOP "$TOP" BASE "$BASE" WT "$WT" OUT "$OUT" REPO "$REPO" P "$P"
  echo 'G_ENV=(GROK_DISABLE_AUTOUPDATER=1 GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_SKILLS_ENABLED=false GROK_CLAUDE_MCPS_ENABLED=false GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false)'
  cat <<'SH'
trees() { local m; m=$(git -C "$TOP" worktree list --porcelain | sed -n '1s/^worktree //p'); git -C "$TOP" worktree list --porcelain | sed -n 's/^worktree //p' | grep -vxF -e "$WT" -e "$(cd "$WT" && pwd -P)" | grep -vxF -f <(cat "$HOME"/.conductor/out/*/running 2>/dev/null) | while IFS= read -r d; do case "$d" in "$TOP") ;; "$m"/.claude/worktrees/*) continue ;; esac; printf '== %s\n' "$d"; git -C "$d" status --porcelain=v1 --untracked-files=all -- . ':!.claude/worktrees'; git -C "$d" diff HEAD | sha256sum; (cd "$d" && git ls-files -z -o --exclude-standard -- . ':!.claude/worktrees' | xargs -0r sha256sum); done; }
SH
} > "$OUT/vars.sh"
git -C "$TOP" worktree add -q -b "cx/$ID" "$WT" "$BASE"
EX="$(git -C "$TOP" rev-parse --path-format=absolute --git-common-dir)/info/exclude"
grep -qx '/.conductor/' "$EX" 2>/dev/null || echo '/.conductor/' >> "$EX"
```

`~/.cx-wt` is `worktree_root`'s default; use the option's value when `cx-doctor` lists it.

Then write the contract to `$OUT/task.md` (the Write tool with the absolute path, or a quoted
heredoc `cat > "$OUT/task.md" <<'TASK'` … `TASK`). `$OUT/task.md` is canonical. Line 1 is
machine-readable, the rest is prose for the executor:

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

Before EVERY dispatch (also after a failover reset), copy the contract into the worktree,
record its hash and mark the worktree `running` (a lane may write there, so other agy runs'
snapshots leave it out until Step 3); the first time, also run the repo's `setup`:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
mkdir -p "$WT/.conductor" && cp "$OUT/task.md" "$WT/.conductor/task.md" \
  && sha256sum "$OUT/task.md" | cut -d' ' -f1 > "$OUT/task.sha"
printf '%s\n' "$WT" "$(cd "$WT" && pwd -P)" > "$OUT/running"   # a lane may write here: agy snapshots skip it until Step 3
(cd "$WT" && npm ci --prefer-offline) > "$OUT/setup.log" 2>&1 || echo ENV_FAILED   # routes.json setup
```

`ENV_FAILED` is the repo's problem, not the executor's: fix the setup before dispatching.

### Step 2a: agy Opus (lane `agy-opus`)

One background Bash call. It takes the machine-wide agy lock first (flock on
`~/.conductor/locks/agy`: one agy run at a time across every session and Work locally thread on
this computer, because pool slots are not shared yet; it waits up to 80 minutes, then prints
`AGY_BUSY` and exits 28: use the next pool in the order), registers the directory (free,
bounded: print mode can hang), and snapshots every other worktree of the repo (the main
checkout, previous tasks' worktrees, gate checkouts), with content, not just status. Left out of
the snapshot: Claude Code's worktrees under the main checkout's `.claude/worktrees/` (other
threads and agents at work; your own checkout `$TOP` stays in) and every worktree marked
`running` by its dispatch (another lane at work there, in any thread):

```bash
. "$HOME/.conductor/out/t1/vars.sh"
rm -f "$OUT/running"   # an agy task's tree stays in later agy runs' snapshots
mkdir -p "$HOME/.conductor/locks"; exec 9>> "$HOME/.conductor/locks/agy"; flock -w 4800 9 || { echo AGY_BUSY; exit 28; }   # one agy run at a time on this computer
(cd "$WT" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY AGY_CLI_DISABLE_AUTO_UPDATE=true timeout -k 5 60 agy --new-project --output-format json -p /model </dev/null) > "$OUT/agy-model.json"
trees > "$OUT/trees.before"
(cd "$WT" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true \
  agy-delegate --model claude-opus-5-5-high --dir "$WT" --timeout 30m --digest "$P") \
  > "$OUT/answer.txt" 2> "$OUT/agy.err"; echo $? > "$OUT/rc"
trees > "$OUT/trees.after"; cmp -s "$OUT/trees.before" "$OUT/trees.after" || echo WRONG_TREE
grep -E '^AGY_(USAGE|SIGNAL)' "$OUT/agy.err"
```

`AGY_USAGE`'s `model` only echoes the requested model: record the served model as
`unverified (wrapper)`, never as verified. Exit 15 = missing grant (report it, never retry with
the yolo flag); exit 12 = timeout or PARTIAL output. `WRONG_TREE` = a tree in the snapshot
changed while agy ran, usually because agy wrote into its last project root, often a previous
task's worktree under `~/.cx-wt` (the `write_file` grant covers all of them); `diff
"$OUT/trees.before" "$OUT/trees.after"` names the tree. Report the tree and that diff, stop
using agy for this task, and never reset or restore a tree you did not create in this task:
when it may belong to another thread or lane, ask the user. Known false alarms: a worktree of
the repo added or removed meanwhile (another task's Step 1, a gate checkout) and a lane of
another thread writing here without a `running` mark.

agy has no job form in Phase 1: the lock, the registration and both snapshots must span the
whole run, which only one background call can do (an `agy-job` started in one call and waited
for in another would release the lock early, and the next agy run would land in its snapshot).

Raw arm (served model verified; preferred for the A/B). Its flags are documented but not yet
captured from `agy --help`, and the init event shape is unverified. The same lock,
registration and tree snapshots, as one background call:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
rm -f "$OUT/running"   # an agy task's tree stays in later agy runs' snapshots
mkdir -p "$HOME/.conductor/locks"; exec 9>> "$HOME/.conductor/locks/agy"; flock -w 4800 9 || { echo AGY_BUSY; exit 28; }   # one agy run at a time on this computer
(cd "$WT" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY AGY_CLI_DISABLE_AUTO_UPDATE=true timeout -k 5 60 agy --new-project --output-format json -p /model </dev/null) > "$OUT/agy-model.json"
trees > "$OUT/trees.before"
(cd "$WT" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true \
  timeout -k 15s 35m agy --model claude-opus-5-5-high --add-dir "$WT" --print-timeout 30m \
  --output-format stream-json -p "$P" </dev/null) > "$OUT/agy.ndjson" 2> "$OUT/agy.err"; echo $? > "$OUT/rc"
trees > "$OUT/trees.after"; cmp -s "$OUT/trees.before" "$OUT/trees.after" || echo WRONG_TREE
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
mismatch for the A/B record. `timeout -k 15s 35m` bounds the hang after the result.

### Step 2b: Copilot Opus (lane `copilot-opus`)

One background Bash call:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false \
  ghcp-delegate --model claude-opus-5.5 --effort high --dir "$WT" --write --allow-shell 'npm test' \
  --timeout 30m --digest "$P" > "$OUT/answer.txt" 2> "$OUT/ghcp.err"; echo $? > "$OUT/rc"
grep -E '^GHCP_(SESSION|DENIED|NOTE|USAGE|SIGNAL|FALLBACK)' "$OUT/ghcp.err"
```

One `--allow-shell` per routes command. `GHCP_USAGE` `models_used[].model` must be
`claude-opus-5.5`; any `GHCP_DENIED` of kind `write` fails the run; about 32k output tokens
with an empty answer is the #5149 signature.

Job form: the same prefix and options, with `ghcp-job`'s `start` subcommand in place of
`ghcp-delegate`:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false \
  ghcp-job start --model claude-opus-5.5 --effort high --dir "$WT" --write --allow-shell 'npm test' --timeout 30m --digest "$P"
```

It prints `JOB_ID <id>`; wait in one background call (exit = the job's rc):

```bash
J='<job id>'   # the id after JOB_ID
while env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false ghcp-job status "$J" | grep -qx running; do sleep 15; done
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false ghcp-job result "$J"
```

Mechanical fallback (lane `copilot-fusion`, same prefix, background):

```bash
. "$HOME/.conductor/out/t1/vars.sh"
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false \
  ghcp-delegate --fusion standard --write --allow-shell 'npm test' --dir "$WT" --timeout 30m --digest "$P" > "$OUT/answer.txt" 2> "$OUT/ghcp.err"; echo $? > "$OUT/rc"
```

Both Opus pools drained (Fusion Max; same prefix, background). `--test-cmd` is the routes
`test` command, so `ghcp-handoff` does not detect its own:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false \
  ghcp-handoff --dir "$WT" --tier pro --test-cmd 'npm test' --timeout 30m "$P" > "$OUT/answer.txt" 2> "$OUT/ghcp.err"; echo $? > "$OUT/rc"
```

A `GHCP_FALLBACK` line on a Fusion lane means the answer came from a billed plain-`auto`
re-run: treat it as a model mismatch.

### Step 2c: Grok (lane `grok`)

The raw CLI, never the grok-build plugin's bridge; one background Bash call:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
UUID=$(cat /proc/sys/kernel/random/uuid); printf '%s\n' "$P" > "$WT/.conductor/prompt.txt"
env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1 "${G_ENV[@]}" grok --prompt-file "$WT/.conductor/prompt.txt" \
  -m grok-4.7 --effort high --cwd "$WT" -s "$UUID" --output-format json --sandbox workspace \
  --permission-mode acceptEdits --allow 'Bash(npm test)' --allow 'Bash(git status)' --allow 'Bash(git diff)' \
  --no-subagents --max-turns 60 </dev/null > "$OUT/grok.json" 2> "$OUT/grok.err"; echo $? > "$OUT/rc"
grep -n 'permission required:' "$OUT/grok.err" && echo DENIED     # a hit means denied, even with rc 0
env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1 "${G_ENV[@]}" grok usage "$UUID"
```

Read-only exploration (no worktree needed; `TOP` from `vars.sh` or `git rev-parse
--show-toplevel`):

```bash
env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1 "${G_ENV[@]}" grok -p "<question>" -m grok-4.7 --effort medium --cwd "$TOP" --sandbox read-only --always-approve --no-subagents --output-format json --json-schema '{"type":"array","items":{"type":"object","properties":{"file":{"type":"string"},"line":{"type":"integer"},"why":{"type":"string"}},"required":["file","line","why"]}}' </dev/null
```

Without a task's `vars.sh`, define `G_ENV` in the same call first (the `G_ENV=(…)` line of
Step 1). `--sandbox workspace` becomes `cx-workspace` (option `grok_sandbox_profile`) once
Phase 2 writes that profile; `--always-approve` is only ever combined with `read-only` outside
Docker. The `Bash(<cmd>)` rule syntax and the `workspace` profile name are documented but not
yet verified, so the `permission required:` scan is mandatory.

### Step 2d: Claude (lane `claude`)

A Task/Agent subagent (Opus 5.5, effort high unless the task needs more) with prompt `$P`,
told that its working directory is `$WT` (every command runs there, every path is under it)
and that it must not commit. It is still an executor: Step 3 applies unchanged.

On Windows (Git Bash) the worktree is in WSL, so give the subagent two paths and say which is
for what: the `\\wsl.localhost\<distro>\home\<you>\.cx-wt\<repo>-<id>` form for Read, Edit,
Write, Glob and Grep (`cx-wsl bash -c '. "$HOME/.conductor/out/t1/vars.sh"; wslpath -w "$WT"'`
prints it), and `cx-wsl bash -c 'cd "/home/<you>/.cx-wt/<repo>-<id>" && <command>'` for every
command. Never `~` (on Windows that is `C:\Users\<you>`), and never Git Bash's own git, npm or
test tools on those files.

### Step 2e: read-only lanes (no worktree, no task contract)

Same rules (prefixes, background, outside the sandbox); `DIR` is the checkout to read. An agy
reader is one call: the lock line, the registration, then one `agy-delegate` line:

```bash
mkdir -p "$HOME/.conductor/locks"; exec 9>> "$HOME/.conductor/locks/agy"; flock -w 4800 9 || { echo AGY_BUSY; exit 28; }   # one agy run at a time on this computer
(cd DIR && env -u GEMINI_API_KEY -u GOOGLE_API_KEY AGY_CLI_DISABLE_AUTO_UPDATE=true timeout -k 5 60 agy --new-project --output-format json -p /model </dev/null) > /dev/null
(cd DIR && env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true agy-delegate --model gemini-3.8-flash-high --dir DIR --timeout 30m --digest "<question>")
(cd DIR && env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true agy-delegate --model 'Gemini 4 Argon (High)' --dir DIR --timeout 30m --digest "<digest request>")
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false ghcp-delegate --model gpt-6.1-sol --effort high --dir DIR --digest "<question>"
```

The first `agy-delegate` line is flash (exploration fallback, long logs, digests under ~200k
tokens), the second Argon (digests above ~200k tokens, synthesis); then the GPT-family
reader. Not in Phase 1: `agy-media` and `/antigravity:research` (both always pass `--yolo`,
machine-wide); research goes to your own WebSearch and grok, media waits for the v1.1 Docker
lane. Commit messages, PR text and changelogs go to Grok with the diff inside the prompt file
(one call; `ID`, `TOP`, `BASE`, `OUT` from `vars.sh`):

```bash
. "$HOME/.conductor/out/t1/vars.sh"
{ printf '%s\n\n' 'Write a commit message (a subject under 72 characters, a blank line, a short body) for the diff below. Describe only what the diff shows.'; git -C "$TOP" diff "$BASE" "cx/$ID"; } > "$OUT/msg-prompt.txt"
env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1 "${G_ENV[@]}" grok --prompt-file "$OUT/msg-prompt.txt" -m grok-4.7 --effort low --cwd "$TOP" --sandbox read-only --always-approve --no-subagents --output-format plain </dev/null
```

### Step 3: after every run (the conductor commits; the gate never runs in `$WT`)

Background when the checks are slow:

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

The served model in the commit message is the verified one, or `unverified (wrapper)` (Step
2a). `SPEC_TAMPERED` (exit 23), `BRANCH_TAMPERED` (exit 24: the executor created or switched
branches, so a squash and commit would land on its branch while `cx/$ID` stays at BASE) and
`NO_CHANGES` (exit 3) stop the step before the commit: nothing is committed or gated; inspect
the worktree, then fail over or re-dispatch. The gate checks out the exact commit `C`, never a
branch name. A second
gate attempt uses `$ID.2`. Failover to the next lane: `git -C "$WT" reset -q --hard "$BASE" &&
git -C "$WT" clean -ffdxq -e /.conductor/` (inside the conductor's own worktree only), re-copy
`task.md` (Step 1), dispatch. Never let two lanes write to one worktree.

### Step 4: reviews (read-only, on the same gate checkout `$G`; only after Step 3 committed)

No second `worktree add`: Step 3 created `$G`. Each reviewer is one background call: the
first four lines, then either the agy lines (lock, registration, reviewer) or the ghcp line:

```bash
. "$HOME/.conductor/out/t1/vars.sh"; G="$HOME/.conductor/gate/$ID.1"
git -C "$TOP" diff "$BASE" "cx/$ID" > "$OUT/change.diff"
[ -s "$OUT/change.diff" ] || { echo EMPTY_DIFF; exit 3; }     # nothing committed: do not review
R="Review the change in $OUT/change.diff against the code in this checkout. List findings as file:line - severity - issue, most severe first. Do not edit files."
mkdir -p "$HOME/.conductor/locks"; exec 9>> "$HOME/.conductor/locks/agy"; flock -w 4800 9 || { echo AGY_BUSY; exit 28; }   # one agy run at a time on this computer
(cd "$G" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY AGY_CLI_DISABLE_AUTO_UPDATE=true timeout -k 5 60 agy --new-project --output-format json -p /model </dev/null) > /dev/null
(cd "$G" && env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true \
  agy-delegate --model 'Gemini 4 Argon (High)' --dir "$G" --dir "$OUT" --timeout 30m --digest "$R")
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false \
  ghcp-delegate --model gpt-6.1-sol --effort high --dir "$G" --add-dir "$OUT" --digest "$R"     # high_risk paths
```

The model names are the defaults of options `review_model_gemini` and `review_model_gpt`. Run
the Argon reviewer on Opus-written code; add the GPT reviewer on `high_risk` paths and
security-relevant changes; review Grok- or Gemini-written code yourself. Confirm every
accepted finding at file:line and give a reason for every rejected one. Clean up the gate
checkout with `git -C "$TOP" worktree remove --force "$G"` once the reviews are in.

### Step 5: GitHub (only after a green gate)

Write the PR body to `$OUT/pr-body.md` first (Step 2e drafts it), then:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
git -C "$WT" push -u origin "cx/$ID"
gh pr create -R "$REPO" --head "cx/$ID" --title '<title>' --body-file "$OUT/pr-body.md"
gh pr edit "cx/$ID" -R "$REPO" --add-reviewer @copilot
```

`REPO` (`host/owner/repo` as gh resolves the checkout's remote, ssh host aliases included;
from the origin URL when gh is not logged in, Step 1) lets every `gh` call name the repo with
`-R`, so each line starts with an allow-listed command (`cx-doctor`'s D25 lists the rules) and
none needs a `cd`. `--add-reviewer @copilot` needs a gh whose `gh pr edit --help` mentions
`@copilot` (`cx-doctor` checks it); otherwise use the REST fallback (reviewer login unverified;
`<N>` from `gh pr view "cx/$ID" -R "$REPO" --json number --jq .number`):
`gh api -X POST "repos/{owner}/{repo}/pulls/<N>/requested_reviewers" -f 'reviewers[]=copilot-pull-request-reviewer[bot]'`.
CI failures:

```bash
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false ghcp-ci-debug --pr 123   # the PR number
```

(or `--run <run id>`), read-only. Its apply mode creates and switches to a branch
`ghcp/ci-fix-<run id>` in its directory, whose default is the cwd (normally the user's main
checkout), and leaves the edits uncommitted, so use it only inside the task's conductor
worktree, and hand the edits back to `cx/<id>` before Step 3 (which otherwise stops with
`BRANCH_TAMPERED`). One background call:

```bash
. "$HOME/.conductor/out/t1/vars.sh"
printf '%s\n' "$WT" "$(cd "$WT" && pwd -P)" > "$OUT/running"
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false \
  ghcp-ci-debug --pr 123 --apply --dir "$WT" > "$OUT/ci-fix.txt" 2> "$OUT/ci-fix.err"; echo $? > "$OUT/rc"
F=$(git -C "$WT" symbolic-ref -q --short HEAD); case "$F" in ghcp/ci-fix-*) git -C "$WT" switch -q "cx/$ID" && git -C "$WT" branch -q -D "$F" ;; esac   # hand the edits back to cx/$ID
printf 'BASE=%q\n' "$(git -C "$WT" rev-parse "cx/$ID")" >> "$OUT/vars.sh"   # Step 3 commits the fix on top of the pushed commit
```

Both branches point at the same commit, so the switch carries the uncommitted edits; the new
`BASE` makes Step 3 commit the fix on top of `cx/<id>` (no squash into the pushed commit, so
Step 5's push stays a fast-forward) and Step 4 review only the fix. Then Step 3 (gate
`$ID.2` when `$ID.1` still exists), Step 4 and the push. Issue and PR triage is read-only: fetch
first (`gh issue view N --json title,body,comments,labels > "$OUT/issue.json"`, or
`gh pr view N` / `gh pr diff N`), then run `ghcp-delegate --model gpt-6.1-sol --effort medium
--add-dir "$OUT" --digest "<question about $OUT/issue.json>"` with the ghcp prefix. Never use
`ghcp-delegate --github` for triage: it adds every GitHub MCP tool acting as you (comment,
label, close, merge); keep it for a task that is meant to act on GitHub. Copilot approvals
count only after the user opts in; you adjudicate every review comment.

Copilot cloud agent (lane `copilot-github`; an executor's own cloud, welcome from a local
session, U7): the agent works in GitHub Actions and opens a pull request, billed in Copilot
premium requests and Actions minutes. Run Step 1 for the task (its worktree stays unused) and
write `$OUT/task.md`, with "committing, pushing or branching" taken out of its Forbidden list
(the agent's pull request is its output), then start it (one call; the task text goes on stdin):

```bash
. "$HOME/.conductor/out/t1/vars.sh"
env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1 COPILOT_AUTO_UPDATE=false ghcp-cloud create -R "$REPO" - < "$OUT/task.md" > "$OUT/cloud.txt"
```

`ghcp-cloud list` and `ghcp-cloud view <PR number> --log` (same prefix) follow it. Its pull
request is an executor's draft like any other: gate it before anything merges, on a gate
checkout of the PR head (`N` = the PR number):

```bash
. "$HOME/.conductor/out/t1/vars.sh"; N='<PR number>'
git -C "$TOP" fetch -q origin "pull/$N/head" && C=$(git -C "$TOP" rev-parse FETCH_HEAD) || { echo FETCH_FAILED; exit 2; }
git -C "$TOP" diff --stat "$BASE...$C"; git -C "$TOP" diff --name-only "$BASE...$C"   # tamper review (G4)
G="$HOME/.conductor/gate/$ID.1"; git -C "$TOP" worktree add -q --detach "$G" "$C"         # gate the exact commit
(cd "$G" && npm ci --prefer-offline && npm test && npm run lint && npx tsc --noEmit)   # routes setup + commands
```

Read the name-only list against `allowed_paths` and the protected set (G4), then Step 4 on `$G`
with `git -C "$TOP" diff "$BASE...$C" > "$OUT/change.diff"` as its diff line. Post your
findings on the PR; it merges only after a green gate and your adjudication, never on the
agent's own word. Grok remote sessions are not a Phase 1 command: grok 1.0.70 can only resume
one (`--resume`); the user starts them.

### From Windows (Git Bash)

The Windows desktop app's Bash tool is Git Bash, and nothing above exists on the Windows side:
every step runs inside WSL through `cx-wsl`, and nothing is installed on Windows (never
install ghcp, antigravity or grok-build there, never call `wsl.exe` or agent CLIs directly, and
never make worktrees with Git for Windows).

- Run `cx-doctor` once first: `cx-wsl` resolves every tool from the host record it writes
  (exit 13 without it). From this session it forwards into WSL and records what it finds; for
  the user's full interactive PATH they run `/conductor:doctor` in a Claude Code session in
  WSL, or `~/.conductor/runtime/current/bin/cx-doctor` in a WSL terminal (a plain terminal has
  no plugin `bin/` on its PATH; the copy exists after the first forwarded call or
  `cx-doctor --install-runtime`).
- Shell steps: write the step text verbatim (its `vars.sh` line included) to a Windows-side
  scratch file with the Write tool, with LF line endings, and run `cx-wsl bash -s < FILE` (FILE
  in its Git Bash form, e.g. `/c/Users/<you>/AppData/Local/Temp/cx-t1-2b.sh`), as one
  background Bash call with `timeout: 7200000` when the step is long. `cx-wsl` strips CRLF
  from such a step and says so on stderr: a CR would end up in every word. In Step 1 the `task.md` text goes into the step as a quoted heredoc
  (`cat > "$OUT/task.md" <<'TASK'` … `TASK`).
- Single commands may go direct: `cx-wsl ghcp-job status <id>`, `cx-wsl gh pr view <N>`,
  `cx-wsl git -C /home/<you>/<repo> status`. `cx-wsl` adds the environment prefixes above
  for `ghcp-*`, `agy-*`, `agy` and `grok` itself.
- Paths inside steps and arguments are WSL paths (`$HOME`, `~/.cx-wt`, `/home/<you>/…`),
  never `C:\…` or `/c/…`; `cx-wsl` passes arguments byte for byte.
- Read results with `cx-wsl bash -c 'cat "$HOME/.conductor/out/t1/answer.txt"'` (the WSL
  home; replace `t1` with the task's id).
- The Claude lane (Step 2d, the claude-pool script): file tools on the task's
  `\\wsl.localhost\<distro>\…` path, commands through `cx-wsl bash -c 'cd "<WSL path>" && …'`.
- With the Copilot token file (`cx-doctor --login-help copilot`; the keyring is unreachable
  through wsl.exe), `cx-wsl ghcp-*` exports `COPILOT_GITHUB_TOKEN` for that call only and a
  `cx-wsl bash -s` step does not get it: run Copilot lanes as direct calls with literal WSL
  paths, e.g. `cx-wsl ghcp-job start --model claude-opus-5.5 --effort high --dir
  /home/<you>/.cx-wt/<repo>-t1 --write --allow-shell 'npm test' --timeout 30m --digest '<the
  $P text of Step 1>'`, then wait in one background call with `while cx-wsl ghcp-job status
  "$J" | grep -qx running; do sleep 15; done; cx-wsl ghcp-job result "$J"`.
- `cx-wsl` calls run outside the sandbox. `cx-wsl` runs exactly these tools: `ghcp-delegate`,
  `ghcp-job`, `ghcp-handoff`, `ghcp-ci-debug`, `ghcp-models`, `ghcp-cloud`, `agy-delegate`,
  `agy-job`, `agy`, `grok`, `gh`, `git` and `bash`; anything else exits 1. Copilot is reached
  only through ghcp, and `claude`, `agy-handoff` and `agy-media` (both always `--yolo`) are
  left out on purpose. `cx-*` commands forward themselves.

### Workflows and ultracode (§12.1)

Ultracode is a session setting, normally off: the `ultracode` settings key, `--effort
ultracode`, `/effort ultracode`, or the word "ultracode" typed in a prompt. The plugin can
neither detect nor force it; `cx-doctor` D32 shows what the settings files say. **Ultracode
changes how thorough you are, not who executes.** In Phase 1 every workflow and Agent-tool
subagent gets the conductor's subagent rules (a SubagentStart hook): it never runs Copilot,
Grok or Antigravity, in any form, and returns `EXECUTOR_NEEDED: <lane> - <reason>` instead,
because pool slots are not shared between processes yet. The hybrid recipe for a fan-out:

1. **Scout or design workflow (Claude only).** It returns the decomposition, with disjoint
   `files` per task.
2. **Main turn: worktrees.** Step 1 for every task, with unique ids `t1`…`tn`.
3. **Main turn: executor runs**, in the policy's order, each with `timeout: 7200000`: agy tasks
   as Step 2a, one background Bash call each (the lock runs them one at a time across the
   computer; agy has no job form); Copilot tasks as Step 2b's job form, each waited on in one
   background Bash call.
4. **Claude-pool workflow, in parallel with them**, for the remaining Opus tasks: the script
   below, one agent per task at effort `high` (the §6.3 map, not the inherited xhigh), in the
   task's `~/.cx-wt` worktree (Step 1 marked it `running`, so agy's snapshots leave it out). On
   Windows pass `wt_win` too: the prompt then names that `\\wsl.localhost\<distro>\…` path for
   file tools and `cx-wsl bash -c 'cd "<wt>" && …'` for commands.
5. **Main turn: collect and review.** Collect the jobs, then Step 3 per task (the claude-pool
   tasks too) and Step 4; Claude-side reviews may be another workflow, executor reviews run
   from the main turn.

Rules:
- Never `isolation: 'worktree'` or `isolation: 'remote'` for conductor tasks: remote throws in
  workflows, and worktree isolation fences the agent inside `<repo>/.claude/worktrees/`, away
  from `~/.cx-wt` and from Step 3.
- No `agentType` for conductor stages in Phase 1, and never another plugin's delegate agent
  (`antigravity:antigravity-delegate`, `grok-build:grok-delegate`, `ghcp:ghcp-delegate`): they
  bypass the conductor's contract and gates.
- `budget` counts Claude output tokens only (the main loop plus every workflow). Never size
  executor fan-out by it, and never add an executor cap (U3).
- An agent that returns `EXECUTOR_NEEDED`: dispatch that lane from the main turn for that
  task's worktree (Step 2), then Step 3. Executor runs started by the main turn keep running
  when a workflow stops early; collect them with `ghcp-job status <id>` and from the agy
  background calls' notifications.

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
- **Several threads run at once, but Phase 1 has no shared pool slots:** Antigravity runs one
  agy job at a time across every thread and session on this computer, enforced by the lock
  every agy step takes first (`~/.conductor/locks/agy`); a step that waits 80 minutes for it
  prints `AGY_BUSY` (exit 28): use the next pool in the order instead. Copilot and Grok jobs
  may run in parallel. Threads that share a folder use the folder card's Worktree option, and
  ids are unique per computer (Step 1).
- Threads run in auto mode, and a workflow agent's prompt gets no user-intent credit there, so
  executor commands rely on the allow rules `cx-doctor` D25 prints.
- A thread's final text does not reach the project conversation by itself: report through the
  host's reply tool.
- A cloud thread, if one ever happens, gets the cloud notice instead of this skill: Claude does
  the task alone there.

## 5. Guardrails (§6.5) and the after-run checklist

| # | Guardrail | In Phase 1 |
|---|---|---|
| G1 | Spec first: acceptance tests and `task.md` before delegating | Step 1 |
| G2 | One task, one executor, one worktree, one branch; two executors only for an explicit cross-model review | Steps 1–2 |
| G3 | The conductor commits; checks rerun on a fresh checkout with fresh `setup`; never gate in the worker's tree | Step 3 |
| G4 | Tamper check: tests, lockfiles (unless exempt), CI, test-runner config, `.cx/routes.json`, `.git/*`, `.gitignore`, submodules, agent config, the `task.md` hash; executors may not install dependencies | Step 3 name-only list |
| G5 | Exit 0 is not success: agy denials / finish reason / exit 15; Grok's `permission required:`; Copilot `GHCP_DENIED` / exit 15; and a diff must exist | Step 2 checks |
| G6 | Check the served model every run; any mismatch (including `GHCP_FALLBACK` on a Fusion lane) fails the run | Copilot: `GHCP_USAGE` `models_used`. agy wrapper runs: `unverified (wrapper)`; only the raw arm's init event verifies it |
| G7 | Cross-family review; your own review scaled to risk; every accepted finding confirmed at file:line, every rejected one gets a reason | Step 4 |
| G8 | No self-reported success: a digest you relay ends with "VERIFY THIS" until you verified it | always |
| G9 | Versions pinned at install level; model and effort passed explicitly every time | `cx-doctor`; the commands above |
| G10 | Workers fenced by the environment: `CX_WORKER=1`, worker shims, `GROK_CLAUDE_*_ENABLED=false`, scrubbed `COPILOT_*` and API keys; no skip-permissions outside Docker; no conductor content in a repo's `CLAUDE.md` or `.claude/` | the prefixes (never exported); `cx-init` writes nothing there |
| G11 | Secrets: repos with secrets use Docker lanes (v1.1) or exclude pools in `.cx/routes.json` (default all on); Grok always runs under a sandbox profile | routes.json `pools` |

After every run, before you accept anything:

1. `rc` read from the file, not assumed; the lane's denial signals checked (G5).
2. Served model checked (G6); agy wrapper runs recorded as `unverified (wrapper)`.
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
  over 128 KiB and calls an import command 1.0.70 lacks: use the raw CLI (Step 2c).
- **Ungated proactive subagents** `grok-build:grok-delegate` and
  `antigravity:antigravity-delegate`: never use them; `cx-doctor` checks the user-level deny
  rules.
- **Wrappers that hard-code `--yolo`** (`agy-handoff`, `agy-media`, `/antigravity:research`):
  a grant over the whole machine; not Phase 1 lanes, whatever their own docs suggest.
- **Two sibling policies and two nudges**: turn off ghcp's and antigravity's `coding_policy`
  and `delegation_nudge` at user level (and set antigravity's `timeout` to `30m`); the
  conductor injects one policy. `cx-doctor` prints the `claude plugin configure` commands.
- **Shared option names**: both siblings read `CLAUDE_PLUGIN_OPTION_{TIER_PRO,TIMEOUT,…}`:
  never export those; prefix single commands only.
- **Grok imports `~/.claude`** hooks, skills, MCP servers and plugins: the
  `GROK_CLAUDE_*_ENABLED=false` prefix on every Grok run.
- **`/antigravity:migrate` and agy's plugin import** copy every Claude plugin into agy: never
  run them on conductor machines.
- **agy works in its last project root** for a directory it has never seen: register with
  `--new-project -p /model` first, one run at a time under the agy lock, compare tree
  snapshots (`WRONG_TREE`; never restore a tree you did not create in this task).
- **agy print mode hangs** (after the result, without a TTY, with long prompts): keep prompts
  tiny (the fixed `$P`), bound every raw run with `timeout`, and pass `--timeout 30m` to the
  wrapper (its 5-minute default returns PARTIAL output).
- **`agy-job`** is not a Phase 1 form (the agy lock and snapshots must span the run). If you
  meet one: its `result` exits 0 whatever the job's rc (read `<jobdir>/rc`), and its status
  output contains the job's task text (match `  state=running` exactly).
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
  `COPILOT_MODEL`): the per-command `env -u` prefixes; `cx-doctor` warns.
- **`AGENTS.md` imported into `CLAUDE.md`** would bind you to worker rules: the worker-only
  rules apply only where `.conductor/task.md` exists.
- **A git-based line-ending fix** run in a plugin cache copy resolves the enclosing repo:
  never use `git reset` there; use `cx-doctor`'s fixes.

## 7. Exit codes (§4.1)

Every `cx-*` command uses one table. Every exit other than 0, 1 and 126 prints exactly one
`CX_SIGNAL {json}` line, the last line on stderr; exit 1 prints a `<prog>: …` message only.
`cx-wsl` returns the passed-through tool's own status and adds no `CX_*` line to it.

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
| 28 | NO_CAPACITY | Every eligible lane at its cap, disabled or paused |
| 40 | FORWARD_FAILED | Git Bash to WSL: `wsl.exe` or the distro missing, or wsl.exe failed or died |
| 41 | RUNTIME_MISSING | No conductor runtime copy in WSL, or a version mismatch |
| 42 | PATH_UNMAPPABLE | A path has no equivalent on the other side (e.g. `\\server\share`) |
| 43 | HOST_UNSUPPORTED | This host cannot do this (Cygwin, `exec_host=local` on Git Bash, `--host docker` before v1.1) |
| 44 | CRLF_CORRUPT | A runtime file still contains CR after stripping |
| 75 | RUNNING | Job still running (Phase 2 `cx-job`) |
| 126 | — | A worker shim: `blocked: CX_WORKER` (no `CX_SIGNAL`) |
| 130 | CANCELLED | INT / TERM / HUP, or a job kill |

Codes 2, 3, 10–16 and 130 equal ghcp's and agy-delegate's. Sibling codes that matter in
Phase 1:

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
- **Exit 130 from ghcp after about 2 minutes**: the call ran in the foreground and the Bash
  tool killed it (billed tokens). Rerun it in the background.
- **Exit 11**: `cx-doctor --login-help <cli>` prints the fresh-login command; the user runs it
  in a WSL terminal. Logged in from a WSL terminal but not through `cx-wsl`: the keyring is
  unreachable through wsl.exe (no D-Bus); `cx-doctor --windows` explains the token-file route.
- **Exit 26 / version pins**: `cx-doctor` prints the install command for the pinned version
  (Copilot 1.0.105, Grok 1.0.70) and the auto-update exports for `~/.profile`.
- **`WRONG_TREE`**: a worktree of the repo changed while agy ran, usually agy writing into its
  last project root (the main checkout or a previous task's worktree). `diff` the two
  snapshots to find it and report it with its diff; restore only a tree you created in this
  task, and ask the user when it may belong to another thread or lane. Register before every
  run (`--new-project`) and keep agy runs under the lock.
- **`AGY_BUSY`** (exit 28): another agy run held the lock for 80 minutes; use the next pool in
  the order.
- **`BRANCH_TAMPERED`** (Step 3, exit 24): the executor created or switched branches. Nothing
  was committed or gated; fail over after the reset. After a CI fix in apply mode
  (`ghcp-ci-debug --apply --dir "$WT"`), hand its edits back to `cx/<id>` first (Step 5).
- **`permission required:`** on Grok's stderr: a denied tool (even with rc 0). Add the needed
  routes command to the allow list or change the task; never widen to `--always-approve` on a
  writer.
- **gh without `@copilot` reviewer support**: upgrade gh or use the REST fallback of Step 5.
- **Exit 13 from `cx-wsl`**: no host record yet; run `cx-doctor` from this session (it
  forwards and records), or have the user run `/conductor:doctor` in a Claude Code session in
  WSL (or `~/.conductor/runtime/current/bin/cx-doctor` in a WSL terminal, once the runtime copy
  exists).
- **A background call ended after exactly 30 minutes**: it ran with the default `timeout`;
  rerun it with `timeout: 7200000`.
- **The session-start notice says the plugin copy has CRLF line endings**: the conductor
  cannot run; do the work yourself, and give the user the fix the notice names.
