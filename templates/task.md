<!-- cx-task {{json}} -->
# Task {{id}}: {{title}}
## Goal
{{goal}}
## Context
The goal above is all the conductor wrote; read the code it names before you change anything.
## Acceptance tests
{{must_pass}}
- Existing tests must not change.
## Allowed changes
Only what the goal needs. Lockfiles: no.
## Allowed commands
Run checks only through cx-route: {{commands}}, snapshotted from .cx/routes.json at
dispatch (`cx-route` alone lists them). Also allowed: git status. Read files, and your own
changes, with your file tools. No other shell command.
## Forbidden
Editing .conductor/task.md, tests, CI config, .cx/routes.json or git hooks;
installing, upgrading or patching dependencies; committing, pushing or branching; starting
subagents or other coding agents.
## Output contract
Reply with a compact digest: what changed (file:line), what you ran and its result, open
issues. No full file contents, no raw logs. End with exactly one line: DIGEST: <one sentence>.
