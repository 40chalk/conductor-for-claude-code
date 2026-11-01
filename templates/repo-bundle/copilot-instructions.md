<!-- cx:begin conductor bundle v1: written by cx-init; edit freely, cx-init --force rewrites this block -->
## Code review

- Put correctness, security and data loss first; style last. Cite file:line for every finding.
- Flag tests that were weakened, deleted or rewritten to pass, and changes to lockfiles, CI or test configuration.
- Flag new options, flags or configuration the change does not need, and dead or duplicated code.
- Say when you are unsure. Do not invent APIs or behaviour.

## Coding agent

- Follow the general rules in AGENTS.md.
- In a conductor run (`.conductor/task.md` exists in the working directory), also follow AGENTS.md's worker-only rules.
- The worker-only rules do not apply to Copilot coding agent tasks assigned on GitHub: branch, commit and open a pull request as usual.
- Checks: test {{test}}, lint {{lint}}, typecheck {{typecheck}}.
<!-- cx:end -->
