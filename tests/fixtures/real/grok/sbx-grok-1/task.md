<!-- cx-task {"id": "sbx-grok-1", "base": "89dd430454f49a62525c0776931e7bd20aac2d59", "lane": "grok", "effort": "high", "allowed_paths": [], "lockfiles": false, "commands": ["python3 -m unittest discover -s tests"]} -->
# Task sbx-grok-1: add a docstring to every function in src/calc.py
## Goal
add a docstring to every function in src/calc.py
## Context
The goal above is all the conductor wrote; read the code it names before you change anything.
## Acceptance tests
- Must pass: `python3 -m unittest discover -s tests`
- Existing tests must not change.
## Allowed changes
Only what the goal needs. Lockfiles: no.
## Allowed commands
Exactly: `python3 -m unittest discover -s tests` (from .cx/routes.json).
## Forbidden
Editing .conductor/task.md, tests, CI config, .cx/routes.json or git hooks;
installing, upgrading or patching dependencies; committing, pushing or branching; starting
subagents or other coding agents.
## Output contract
Reply with a compact digest: what changed (file:line), what you ran and its result, open
issues. No full file contents, no raw logs. End with exactly one line: DIGEST: <one sentence>.
