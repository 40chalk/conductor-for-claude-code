<!-- cx-task {"id": "live-agy-1", "base": "e138589306e6c0cd0576fc5bc9b87d95fd183be1", "lane": "agy", "effort": "high", "allowed_paths": [], "lockfiles": false, "commands": ["python3 -m unittest discover -s tests"]} -->
# Task live-agy-1: Implement slugify in textutil.py so that cx-route test passes. Do not change the tests.
## Goal
Implement slugify in textutil.py so that cx-route test passes. Do not change the tests.
## Context
The goal above is all the conductor wrote; read the code it names before you change anything.
## Acceptance tests
- Must pass: `cx-route test` (`python3 -m unittest discover -s tests`)
- Existing tests must not change.
## Allowed changes
Only what the goal needs. Lockfiles: no.
## Allowed commands
Run checks only through cx-route: `cx-route test` (`python3 -m unittest discover -s tests`), snapshotted from .cx/routes.json at
dispatch (`cx-route` alone lists them). Also allowed: git status. Read files, and your own
changes, with your file tools. No other shell command.
## Forbidden
Editing .conductor/task.md, tests, CI config, .cx/routes.json or git hooks;
installing, upgrading or patching dependencies; committing, pushing or branching; starting
subagents or other coding agents.
## Output contract
Reply with a compact digest: what changed (file:line), what you ran and its result, open
issues. No full file contents, no raw logs. End with exactly one line: DIGEST: <one sentence>.
