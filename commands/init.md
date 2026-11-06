---
description: Write the conductor repo bundle (AGENTS.md, .cx/routes.json, .github/copilot-instructions.md)
argument-hint: "[--dir <repo>] [--only agents|routes|copilot] [--force] [--test <cmd>] …"
---

Bootstrap the conductor's repo bundle in a git repository.

Arguments: $ARGUMENTS

`cx-init` writes three files at the repository's top level, and nothing else:

- `AGENTS.md`: the rules for coding agents and the repo's commands, inside a
  `<!-- cx:begin … -->` / `<!-- cx:end -->` block. General rules bind everyone; the
  worker-only rules apply only where `.conductor/task.md` exists (a conductor worktree). Text
  outside the block is never changed.
- `.cx/routes.json`: the repo's `setup`, `test`, `lint` and `typecheck` commands (the gate
  runs them, and they are the only shell commands executors may run), plus `protected`,
  `high_risk`, `diff_budget` and the per-repo `pools` switches (all on by default).
- `.github/copilot-instructions.md`: code-review and coding-agent rules for GitHub Copilot,
  inside the same block markers.

It also adds `/.conductor` to the repository's `info/exclude` so task contracts are never
committed. It detects the commands for npm, pnpm, yarn, bun, Python (pytest, ruff, mypy; uv
and poetry), Go and Cargo where they are obvious; `--setup`, `--test`, `--lint` and
`--typecheck` override a detected command, and an empty value (`--lint ''`) means none.

Do this:

1. Run `cx-init --dry-run $ARGUMENTS` (one Bash call; it writes nothing, not even the
   exclude line). Show the user the plan (`create`, `update`, `same`, `skipped`, `CONFLICT`
   lines), the `detected:` commands and the notes. Point out any slot with no command and any
   detected command that looks wrong for this repository (`setup` must not create or modify
   tracked files in a fresh worktree).
2. If the user's arguments include `--dry-run`, stop here. If the dry run exited 5
   (`EXISTS`), an existing bundle file was edited by hand: list the conflicts and stop; never
   add `--force` unless the user asked for it (`--force` rewrites only the cx block of
   `AGENTS.md` and `.github/copilot-instructions.md`, but the whole `.cx/routes.json`; with
   `--only` it touches only the named files). Otherwise run `cx-init $ARGUMENTS` (the same
   arguments without `--dry-run`) and report what it wrote.
3. Suggest committing the three files; do not commit them yourself unless asked.

Never create or edit `CLAUDE.md`, anything under `.claude/`, `.gitignore` or
`.gitattributes` for the conductor: nothing conductor-specific belongs there (a worker that
runs Claude would read it). If the notes say `.gitattributes` is missing or
`core.autocrlf=true`, explain the note and leave the change to the user.

Exit codes: 0 ok; 1 usage error or not inside a git work tree; 5 `EXISTS` (a bundle file
differs; nothing written); 42 `PATH_UNMAPPABLE` (from Git Bash: the repository path has no
WSL equivalent, for example a `\\server\share` path; open the repository from the WSL
filesystem or a drive path instead); 40 and 41 come from Git Bash to WSL forwarding (run
`/conductor:doctor`).
