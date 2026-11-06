<!-- cx-task {"id": "ca-copilot-1", "base": "36712314523c3e4d0a39079e105d3d83bfe2870a", "lane": "copilot-opus", "effort": "high", "allowed_paths": ["textutil.py"], "lockfiles": false, "commands": ["python3 -m unittest discover -s tests"]} -->
# Task ca-copilot-1: implement slugify
## Goal
Implement slugify in textutil.py so that the tests in tests/test_textutil.py pass. Run the tests with cx-route test. Change only textutil.py.
## Context
`textutil.py`: `slugify(text)` currently raises NotImplementedError; its docstring is the specification. `tests/test_textutil.py` holds the tests.
## Acceptance tests
- Must pass: `cx-route test` (`python3 -m unittest discover -s tests`).
- Existing tests that must not change: `tests/test_textutil.py`.
## Allowed changes
Only paths matching: `textutil.py`. Lockfiles: no.
## Allowed commands
Run checks only through cx-route: `cx-route test` (`python3 -m unittest discover -s tests`), snapshotted from .cx/routes.json at dispatch (`cx-route` alone lists them). Also allowed: git status. Read files, and your own changes, with your file tools. No other shell command.
## Forbidden
Editing .conductor/task.md, the tests listed above, CI config, .cx/routes.json or git hooks; installing, upgrading or patching dependencies; committing, pushing or branching; starting subagents or other coding agents.
## Output contract
Reply with a compact digest: what changed (file:line), what you ran and its result, open issues. No full file contents, no raw logs. End with exactly one line: DIGEST: <one sentence>.
