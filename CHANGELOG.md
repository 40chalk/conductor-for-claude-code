# Changelog

## 0.1.0 — 2026-11-01

Phase 1: skeleton and host layer (docs/DESIGN.md sections 2 to 14). Nothing in this release
calls a model.

- Plugin manifest with 24 string options (`copilot_reserve_pct` and `agy_claude_floor_pct`
  default to `0`: no spend caps) and a self-marketplace `conductor-for-claude-code`.
- Shared libraries: `scripts/lib/common.sh` (version and pins, the exit-code table, `CX_*`
  emitters with a constant-only fallback for Git Bash), `scripts/lib/options.sh` (settings.json
  re-read, defaults, validation, the pure-bash Git Bash reader) and `scripts/lib/cxlib.py`.
- Host layer: `detect.sh`, the two-way `pathmap.sh`, the Git Bash to WSL forwarder
  (`forward-wsl.sh`, `wsl-entry.sh`) with NUL-separated argv, an env allowlist, cwd mapping,
  exit propagation and cancellation, and the runtime copy installer.
- `cx-doctor`: host, prerequisites, plugin files (CRLF), runtime copy, options, CLI versions
  against the pins, free login probes, sibling plugin overlap, deny and allow rules, billing
  switches, `--pools`, `--login-help`, `--windows`, `--json`; writes the host record.
- `cx-init`: the repo bundle (`AGENTS.md`, `.cx/routes.json`, `.github/copilot-instructions.md`)
  with per-ecosystem command detection; never touches `CLAUDE.md` or `.claude/`.
- `cx-wsl`: an allow-listed passthrough to one WSL-side tool with the per-tool environment
  prefixes, so the Windows app can delegate before `cx-run` exists.
- SessionStart policy hook (WSL/Linux, Git Bash and CRLF-notice variants), worker shims, the
  `conductor` skill and `/conductor:doctor`, `/conductor:init`, `/conductor:route`.
- Hermetic test suite (`tests/run-tests.sh`) with stubs for every CLI, `uname`, `cygpath`,
  `wsl.exe` and `wslpath`.
