# conductor-for-claude-code

A Claude Code plugin that makes Claude Code the conductor across GitHub Copilot CLI, Grok Build
and Antigravity: it routes each task to the subscription best suited to it, sends Opus 5.5
fan-out to the included pools, and keeps Claude as the judge of code quality.

Work in progress. See the build plan in `docs/DESIGN.md` once Phase 1 lands.
