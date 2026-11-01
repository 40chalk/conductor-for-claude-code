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
