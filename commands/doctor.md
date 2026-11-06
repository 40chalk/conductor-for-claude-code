---
description: Check conductor hosts, CLIs, logins and sibling plugins (free probes only)
argument-hint: "[--pools] [--windows] [--login-help <cli>] [--json]"
---

Run the conductor's health check and explain what it found.

Arguments: $ARGUMENTS

Run `cx-doctor $ARGUMENTS` as ONE Bash call, outside Claude Code's Bash sandbox (if the sandbox
is on, ask for the unsandboxed mode for this call: the Copilot, agy and grok probes write
`~/.copilot`, `~/.gemini`, `~/.antigravity` and `~/.grok`, and Copilot's probe exits 16 inside
the sandbox). Give the call a 10-minute timeout: the probes are bounded, but several of them
together can exceed the default 2 minutes.

Every probe is free: `--version`, model listings, `claude auth status`, `gh auth status`,
`gh pr edit --help`, and ghcp's invalid-model catalog probe (through ghcp-models on any Copilot
version; the raw form only on Copilot 1.0.105, from the empty directory `~/.conductor/probe`). No model is called and no credit or quota is
spent. `agy -p /usage` runs only with `--pools --agy-usage`. From Git Bash (the Windows app)
the doctor runs its Windows checks (W1–W7, W10, W11) and then forwards itself into WSL; `--windows`
runs the Windows checks only, and `--login-help [cli]` prints the fresh-login commands
without probing anything.

Read the report (`✓` ok, `!` worth knowing, `✗` broken; each `[ID]` is a check in
`docs/DESIGN.md` section 8, and `fix:` lines carry the exact command), then tell the user, in
a few lines per section:

- The host, caller and session (the header's `session local`, `bridge` for a Work locally
  project thread, or `cloud`, where the doctor only reports ✗ D30 and exits 43: the executors
  are on the user's computer), and whether the host record was written. D30, D31 and D32 (W10,
  W11 from Git Bash) are info: the session, Work locally readiness, and what the settings say
  about workflows and ultracode.
- Each `✗`, then each `!`: what it means and its `fix:` command, copied verbatim (in a report
  forwarded from the Windows app, every fix outside the Windows section runs in a WSL terminal,
  never in Git Bash: say so). Typical
  ones: a CLI below its minimum (Claude Code 2.1.316, agy 1.1.12; nothing else is pinned, and
  the versions last verified are info lines: each run checks the live `--help` for its flags);
  missing bubblewrap for grok's sandbox, or grok unable to apply its sandbox at all, or its
  sandbox log saying the profile was not enforced, or option `grok_sandbox_profile` naming a
  built-in that lets grok write `~/.grok` (D17 ✗: every grok run is refused; Landlock needs
  Linux 5.13 or newer, `wsl --update` for WSL; the option goes back to `auto`); a CLI
  not logged in (point to `cx-doctor --login-help <cli>`; logins are interactive, so the user
  runs them in a WSL terminal); the ghcp and antigravity policies and nudges still on next to
  the conductor's policy, and antigravity's `timeout` below 30m; the grok-build plugin's
  SessionEnd hook and its `grok-build:grok-delegate` subagent; missing deny rules for the
  `antigravity:antigravity-delegate` and `grok-build:grok-delegate` agents; billing switches
  in the environment (`COPILOT_*`, `GH_TOKEN`, `XAI_API_KEY`, `GEMINI_API_KEY`,
  `GOOGLE_API_KEY`, `ANTHROPIC_API_KEY`); CRLF line endings in the plugin files.
- The info lines worth acting on: the Claude Code allow rules that let the conductor run
  without permission prompts (the doctor lists them; it never writes settings) and the
  sandbox exclusions.
- With `--pools`: which Opus 5.5 ids each pool offers (agy `claude-opus-5-5-high`, Copilot
  `claude-opus-5.5`), the reviewer models, and the month-to-date Copilot figure if one was
  recorded.

Rules:

- Never run a paid command to test a fix (no `ghcp-delegate`, `agy -p <prompt>`,
  `grok -p`, `claude -p`). Re-run `cx-doctor` instead.
- The `printf '%s' '{...}' | claude plugin configure <plugin id> --values-stdin` fixes change
  the user's settings: offer them and run them only when the user agrees. The same goes for
  installs, version changes, `~/.profile` edits, permission rules and grant files.
- Never use `git reset`, `git rm` or other git commands inside the plugin's install folder to
  repair line endings; use the doctor's own fix lines.
- Exit codes: 0 no `✗`; 4 `CHECKS_FAILED` (at least one `✗`); 1 usage error; 16 from a probe
  means the call ran inside the sandbox (re-run it outside); 40 `FORWARD_FAILED` and
  41 `RUNTIME_MISSING` come from Git Bash to WSL forwarding (wsl.exe missing or failing, or
  the WSL-side runtime copy could not be installed: try `cx-doctor --install-runtime`);
  43 `HOST_UNSUPPORTED` (a cloud session, or for example `--host docker` before v1.1).
