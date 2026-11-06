# Test fixtures

Each file is labelled **verified** (captured from the real CLI, sanitized as in DESIGN §14.2) or
**synthetic** (shape as described in DESIGN §1; replaced by a Phase 0 capture under
`tests/fixtures/real/<cli>/` when one exists). `.gitattributes` marks this directory `-text` and
`*.utf16le` `binary`, so the intentional CRLF and UTF-16 bytes survive `git add`.

| File | Kind | Used by |
|---|---|---|
| `grok-models-unauth.txt` | verified (grok 1.0.70, isolated `GROK_HOME`, DESIGN §1.3) | grok stub, D17 |
| `grok-models-auth.txt` | synthetic (bullet list shape of the unauthenticated text) | grok stub, D17, `--pools` |
| `grok-usage.txt` | synthetic | grok stub (`grok usage`) |
| `agy-models.txt` | synthetic (`<slug>\t<Label>` lines after `Fetching available models...`, DESIGN §1.4) | agy stub, D18 |
| `agy-models.json` | synthetic (`--output-format json` shape is unverified) | agy stub, D18, `--pools` |
| `agy-usage.json` | synthetic (`/usage` shape is unverified) | agy stub, `--pools --agy-usage` |
| `ghcp-models.json`, `ghcp-models-no-opus.json` | synthetic (`ghcp-models --json` shape, DESIGN §1.2) | ghcp-models stub, D16, `--pools` |
| `wsl-l-v.utf16le` | synthetic (BOM + UTF-16LE + CRLF `wsl.exe -l -v` listing with localized multi-word STATE values) | wsl.exe stub, W2 |
| `settings/green.json` | synthetic | all-green doctor |
| `settings/siblings-default.json` | synthetic (sibling options unset) | D21, D22, D24 |
| `settings/options*.json` | synthetic | option loader (P4) |
| `settings/win-bom-crlf.json` | synthetic (a Windows-edited file: UTF-8 BOM and CRLF) | P5, P7 |
| `settings/enabled-first.json` | synthetic (`enabledPlugins` lists the conductor before its `pluginConfigs` entry; braces and quotes inside strings; foreign blocks before and after) | P7 |
| `real/agy/help.txt` | **verified** (`agy --help`, agy 1.4.12, captured 2026-11-02 on the user's machine, relayed through chat; a provenance comment on top) | A1 (agy adapter argv), the agy stub's `--help` |


## Real captures (`tests/fixtures/real/`)

| File | Kind | Used by |
|---|---|---|
| `real/copilot/help.txt` | verified (`copilot --help`, @github/copilot 1.0.105, isolated HOME, 2026-11-01) | A1 (the Copilot argv ghcp-delegate prints) |
| `real/copilot/{ok-pong,denied-write,autodenied-shell,fusion-max-pong}.{jsonl,usage.json}` | verified (ghcp's sanitized Copilot CLI 1.0.105 recordings) | provenance of `real/ghcp/*` |
| `real/grok/help.txt` | verified (`grok help` and subcommand help, grok 1.0.70 from npm) | A1 (grok adapter argv) |
| `real/agy/agy-help.txt` | verified (the same agy 1.4.12 `--help`, as committed by the user with the real runs, 92c4df8; no comment line) | A1 (the 0.2.1 raw argv) |
| `real/agy/help-1.5.1.txt` | verified (`agy --help`, agy 1.5.1, captured 2026-11-06 in the build container; = 1.4.12 plus `--remote-agent` and the `acp` subcommand) | A1 (the 0.2.1 raw argv), A9 (a copy without `--settings` makes the flag contract refuse) |
| `real/copilot/help-permissions.txt` | verified (`copilot help permissions`, Copilot CLI 1.0.105, isolated HOME, no login, 2026-11-06: the `shell(command:*?)` and `write(path?)` kinds) | the copilot stub's `help permissions` (the flag contract), A1, A9 |
| `real/ghcp/print-command-cx-route.txt` | verified (the real ghcp 0.1.0 `ghcp-delegate --print-command --write --allow-shell cx-route --allow-shell 'git status'` … over ghcp's test stub binary, 2026-11-06, recaptured after git diff, log and show were dropped; paths replaced by `/home/user/...`) | A1 (every Copilot flag in `real/copilot/help.txt`; `shell(cx-route)`, never `shell(python3 …)` or `shell(git diff\|log\|show)`) |
| `real/agy/sbx-agy-1/` | **verified real run** (conductor 0.2.0, the user's machine, WSL, 2026-11-02: `cx-run --exec agy`; agy 1.4.12 stream-json `{"event": "init"\|"step_update"\|"result"}`; one `run_command` auto-denied in headless mode, result `SUCCESS` with an empty response, rc 0; exit 15) | the 0.2.1 parsers (15, the denied command from `step_update`), the agy stub's `STUB_AGY_RUN=replay` |
| `real/copilot/sbx-copilot-1/` | **verified real run** (the same day: `cx-run --exec copilot`, claude-opus-5.5, 19.5569 AI credits, the routes command denied by Copilot's command-name matching; exit 0) | the 0.2.1 parsers |
| `real/grok/sbx-grok-1/` | **verified real run** (the same day: `cx-run --exec grok -m grok-4.7`, served `grok-4.7-build`, the first edit denied under `--permission-mode acceptEdits`; exit 21 in 0.2.0) | the 0.2.1 parsers (15; the `-build` alias accepted), the alias table's negative cases (copies with other served names stay 21) |
| `real/review/sbx-review-1/` | **verified real run** (a review of an empty diff: exit 3 before any executor, so no adapter files) | the parser loop (nothing to parse) |
| `real/review/sbx-review-2/` | **verified real run** (`cx-run --mode review --family gpt`, gpt-6.1-sol, 5.3197 AI credits; exit 0) | the 0.2.1 parsers |
| `real/ghcp/{ok-pong,denied-write,autodenied-shell,fusion-max-pong,fusion-fallback,auth}.{out,err,rc}` | verified derivation: the real ghcp 0.1.0 `ghcp-delegate` (`--model claude-opus-5.5 --effort high --write --allow-shell 'npm test'`, or `--fusion max`) run over ghcp's test stub replaying the real recordings above (`STUB_MODE=ok`, `denied`, `autodenied`, `fusion`, `fusion_then_ok`, `auth`), 2026-11-01; temp paths replaced by `/home/user/...` | ghcp-delegate stub (`STUB_GHCP_RUN=<name>`), A11 |
| `real/ghcp/quota.{out,err,rc}` | the same derivation over ghcp's **synthetic** quota stub text (Copilot's quota wording is unverified) | A7 |
| `real/ghcp/print-command-*.txt` | verified: the real `ghcp-delegate --print-command` output (Opus write, Fusion write, GPT read) | A1 (every Copilot flag is in `real/copilot/help.txt`) |
| `real/ghcp/ghcp-delegate-help.txt`, `real/ghcp/ghcp-cloud-help.txt` | verified (`--help` of ghcp 0.1.0) | A1 (copilot and copilot-cloud adapter argv), the wrapper stubs |
| `real/antigravity/agy-delegate-help.txt` | verified (`agy-delegate.sh --help`, antigravity plugin 0.30.2) | A1 (agy wrapper argv), the agy-delegate stub |
| `real/claude/help.txt` | verified (`claude --help`, Claude Code 2.1.316, isolated HOME, 2026-11-01; no model call) | A1 (the `--headless` claude worker argv) |

Each `sbx-*` directory holds a run's `~/.conductor/out/<id>/` files (`<lane>.argv` and `.env`
NUL-separated, `.meta.json`, `.out`, `.err`, `.run.json`, `result.json` as 0.2.0 wrote it), the
`cx-job` logs and its `CX_*` lines; the suite copies one before parsing it again.

The stubs answer `--help` (and copilot `help permissions`) with the real captures above;
`STUB_AGY_HELP`, `STUB_GROK_HELP`, `STUB_COPILOT_HELP`, `STUB_COPILOT_HELP_PERMS` and
`STUB_CLAUDE_HELP` name another file (the suite's flag-contract cases pass copies with a flag
removed).

The run scenarios of the stubs (`STUB_GHCP_RUN=ok|mismatch|5149|sleep`, `STUB_AGY_RUN`,
`STUB_GROK_RUN`, `STUB_CLAUDE_RUN`, `STUB_AGY_DELEGATE_RUN`, `STUB_GH_AGENT_TASK`) print
**synthetic** output in the shapes DESIGN section 15.2 documents; each stub's header lists them.
`STUB_EVENTS=<file>` makes the agy and ghcp-delegate stubs append `start|end NAME PID TIME`
lines (the agy launch from registration to the init event, and each run), which the suite's
`overlap` helper turns into the largest number of runs at once (A13, A25).
