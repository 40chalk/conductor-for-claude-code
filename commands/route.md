---
description: Explain where a described task should go (lane, model, effort, exact command, gates); read-only
argument-hint: "<task description>"
allowed-tools: Read, Glob, Grep
---

Explain how the conductor would route this task. Read-only: run nothing, dispatch nothing,
write nothing.

Task: $ARGUMENTS

Use the conductor skill (`conductor:conductor`): its routing table, lanes, Opus pool order,
effort map and exact Phase 1 commands are the source. If it is not loaded, read
`${CLAUDE_PLUGIN_ROOT}/skills/conductor/SKILL.md`. You may Read, Glob or Grep the current
repository to size the task (how many files, whether tests exist, whether
`.cx/routes.json` defines the commands), but do not open more than you need.

If the task description is empty, ask for one and stop.

Classify the task against the routing table (if it spans several task types, split it and
route each part), then answer with these headings:

1. **Lane and why**: the lane id (`claude`, `agy-opus`, `copilot-opus`, `copilot-fusion`,
   `copilot-gpt`, `copilot-github`, `grok`, `agy-gemini`, `agy-media`) and the routing-table
   row that decides it. Say so plainly when the task is small (under about 200 lines) or
   judgement-heavy and Claude should just do it: delegating below the break-even is a
   measured loss.
2. **Model and effort**: the exact model id or label and the effort. For Opus 5.5 work, name
   the pool order in force (the session-start policy states it; the default is agy, then
   Copilot, then Claude's own subagents) and the effort map: high is the offload default,
   xhigh and max stay with Claude, low does not spend Opus.
3. **Commands**: the exact Phase 1 commands from the skill's recipe, with their environment
   prefixes (Step 1 worktree and contract, the Step 2 lane, Step 3 commit and gate), filled
   in with this task's id and the repo's commands from `.cx/routes.json` when it exists. If
   this session runs in Git Bash (the Windows desktop app; the session-start policy then says
   `CONDUCTOR POLICY, WINDOWS`), give the `cx-wsl` form instead: single commands as
   `cx-wsl TOOL ARGS`, shell steps written to a file and run as `cx-wsl bash -s < FILE`, with
   WSL paths only.
4. **Fallback**: the next lane if this one is drained, refused or fails its gate, and what
   to reset before failing over.
5. **Gate**: what Claude checks before accepting the result (tests rerun on a clean
   checkout, tamper check, diff budget, served-model check, cross-family review where the
   table asks for it).
6. **Cost**: which pool pays (Claude plan, Antigravity Ultra Claude/GPT bucket, Ultra Gemini
   quota, Copilot credits, the xAI weekly pool) and the rough size (for Copilot, 13–18k
   overhead tokens per call, so batch work into large calls). Do not suggest spend caps.

Keep it short. End by saying that nothing was run.
