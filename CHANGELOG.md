# Changelog

## 0.1.0 — 2026-11-01

Phase 1: skeleton, host layer and hand-dispatched lanes (docs/DESIGN.md sections 2 to 14),
including support for Claude Code Projects (beta) Work locally threads and for ultracode.
Nothing in this release calls a model.

- Plugin manifest with 24 string options (`copilot_reserve_pct` and `agy_claude_floor_pct`
  default to `0`: no spend caps) and a self-marketplace `conductor-for-claude-code`.
- Shared libraries: `scripts/lib/common.sh` (version and pins, the exit-code table, `CX_*`
  emitters with a constant-only fallback for Git Bash), `scripts/lib/options.sh` (settings.json
  re-read, defaults, validation, and the pure-bash Git Bash readers, linear in the size of the
  settings file) and `scripts/lib/cxlib.py`.
- Host layer: `detect.sh`, the two-way `pathmap.sh`, the Git Bash to WSL forwarder
  (`forward-wsl.sh`, `wsl-entry.sh`) with NUL-separated argv, an env allowlist, cwd mapping,
  exit propagation and cancellation, and the runtime copy installer. On WSL only the drive
  directories of the automount root (`/mnt/c/`, or `/c/` with `[automount] root = /`) count as
  the Windows side, so Linux mounts such as `/mnt/data` resolve.
- `cx-doctor`: host, prerequisites, plugin files (CRLF), runtime copy, options, CLI versions
  against the pins, free login probes, sibling plugin overlap (with one-step
  `claude plugin install NAME --marketplace SOURCE` fixes), deny and allow rules (D25 states that
  `Bash(cx-wsl:*)` also allows any command in WSL), billing switches, `--pools`, `--login-help`,
  `--windows`, `--json`; writes the host record. A report forwarded from Windows says that its
  fixes run in a WSL terminal, and a repository on a Windows drive is an info line there.
- `cx-init`: the repo bundle (`AGENTS.md`, `.cx/routes.json`, `.github/copilot-instructions.md`)
  with per-ecosystem command detection; never touches `CLAUDE.md` or `.claude/`.
- `cx-wsl`: an allow-listed passthrough to one WSL-side tool (`ghcp-delegate`, `ghcp-job`,
  `ghcp-handoff`, `ghcp-ci-debug`, `ghcp-models`, `ghcp-cloud`, `agy-delegate`, `agy-job`,
  `agy`, `grok`, `gh`, `git`, `bash`) with the per-tool environment prefixes, so the Windows app
  can delegate before `cx-run` exists (never `agy-handoff` or `agy-media`, which always pass
  `--yolo`). `cx-wsl ghcp-*` signs in with `~/.conductor/secrets/copilot-token` (a 0600 file you
  own) when Copilot's keyring is unreachable through `wsl.exe`, for that call only.
- SessionStart policy hook (WSL/Linux, Git Bash, CRLF-notice and cloud-notice variants, a
  Workflows line and an unattended-run sentence), worker shims, the `conductor` skill and
  `/conductor:doctor`, `/conductor:init`, `/conductor:route`.
- The skill's Phase 1 recipe: worktree and contract, the agy, Copilot, Grok and Claude lanes,
  commit and clean-checkout gate, cross-family reviews, GitHub. Every agy step takes a
  machine-wide lock (`~/.conductor/locks/agy`; `AGY_BUSY`, exit 28, after 80 minutes), so agy
  runs one job at a time across sessions and threads; agy has no job form. The `trees` snapshot
  behind `WRONG_TREE` skips Claude Code's worktrees and every worktree another lane marked
  `running`, and its remedy never restores a tree the task did not create. `REPO` comes from
  `gh repo view` (SSH host aliases resolved). A CI fix with `ghcp-ci-debug --apply` is handed
  back to the task branch before the gate. The Copilot cloud agent (`ghcp-cloud`) has a recipe,
  and its pull request goes through the same gate. From Windows the Claude lane uses the
  worktree's `\\wsl.localhost` path for file tools and `cx-wsl bash -c` for commands.
- Session kinds (`local`, `bridge`, `cloud`, `byoc`) and the attended flag in `detect.sh`, decided
  before the host: in a cloud session the hook prints the cloud notice and every `cx-*` exits 43
  before probing anything; a BYOC or self-hosted runner (any kind but `bridge`) with
  `exec_host=local` runs as this machine, in the policy hook too; a Git Bash or WSL host is never
  a cloud session.
- Claude Code Projects (beta): every Project thread runs as a Work locally thread (a Remote
  Control child with this machine's plugins, `session bridge`, local behaviour);
  `templates/projects-instructions.md` for Project settings > Memory says so, sets the
  precedence, and carries the Phase 1 rule that agy runs one job at a time across threads.
- Ultracode and workflows: a SubagentStart hook (`hooks/subagent.sh`) gives workflow and
  general-purpose subagents the Phase 1 rule that only the main session runs executors (with
  the Windows path rule for conductor worktrees); a compacting subagent gets that guard again,
  never the main policy. The skill's hybrid fan-out runs executors from the main turn and the
  own-subagent pool as a static claude-pool workflow (with a Windows `wt_win` prompt).
- `cx-doctor` D30 (session; a desktop WSL session warning), D31 (Work locally readiness), D32
  (workflows and ultracode), and W10/W11 on the Windows side; the header, `CX_HOST`, `CX_DOCTOR`
  and `--json` carry the session.
- Hermetic test suite (`tests/run-tests.sh`) with stubs for every CLI, `uname`, `cygpath`,
  `wsl.exe`, `wslpath` and `nproc`; the skill's snapshot, lock, Step 3 and CI hand-back run in
  scratch repositories.
