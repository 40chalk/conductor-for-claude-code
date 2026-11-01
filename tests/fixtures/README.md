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
| `agy-help.synthetic.txt` | **synthetic** (the agy flags DESIGN documents [docs-only]; `agy --help` was not capturable) | A1 (agy adapter argv) |


## Real captures (`tests/fixtures/real/`)

| File | Kind | Used by |
|---|---|---|
| `real/copilot/help.txt` | verified (`copilot --help`, @github/copilot 1.0.105, isolated HOME, 2026-11-01) | A1 (the Copilot argv ghcp-delegate prints) |
| `real/copilot/{ok-pong,denied-write,autodenied-shell,fusion-max-pong}.{jsonl,usage.json}` | verified (ghcp's sanitized Copilot CLI 1.0.105 recordings) | provenance of `real/ghcp/*` |
| `real/grok/help.txt` | verified (`grok help` and subcommand help, grok 1.0.70 from npm) | A1 (grok adapter argv) |
| `real/agy/README.txt` | placeholder (agy help not capturable here) | — |
| `real/ghcp/{ok-pong,denied-write,autodenied-shell,fusion-max-pong,fusion-fallback,auth}.{out,err,rc}` | verified derivation: the real ghcp 0.1.0 `ghcp-delegate` (`--model claude-opus-5.5 --effort high --write --allow-shell 'npm test'`, or `--fusion max`) run over ghcp's test stub replaying the real recordings above (`STUB_MODE=ok`, `denied`, `autodenied`, `fusion`, `fusion_then_ok`, `auth`), 2026-11-01; temp paths replaced by `/home/user/...` | ghcp-delegate stub (`STUB_GHCP_RUN=<name>`), A11 |
| `real/ghcp/quota.{out,err,rc}` | the same derivation over ghcp's **synthetic** quota stub text (Copilot's quota wording is unverified) | A7 |
| `real/ghcp/print-command-*.txt` | verified: the real `ghcp-delegate --print-command` output (Opus write, Fusion write, GPT read) | A1 (every Copilot flag is in `real/copilot/help.txt`) |
| `real/ghcp/ghcp-delegate-help.txt`, `real/ghcp/ghcp-cloud-help.txt` | verified (`--help` of ghcp 0.1.0) | A1 (copilot and copilot-cloud adapter argv), the wrapper stubs |
| `real/antigravity/agy-delegate-help.txt` | verified (`agy-delegate.sh --help`, antigravity plugin 0.30.2) | A1 (agy wrapper argv), the agy-delegate stub |
| `real/claude/help.txt` | verified (`claude --help`, Claude Code 2.1.316, isolated HOME, 2026-11-01; no model call) | A1 (the `--headless` claude worker argv) |

The run scenarios of the stubs (`STUB_GHCP_RUN=ok|mismatch|5149|sleep`, `STUB_AGY_RUN`,
`STUB_GROK_RUN`, `STUB_CLAUDE_RUN`, `STUB_AGY_DELEGATE_RUN`, `STUB_GH_AGENT_TASK`) print
**synthetic** output in the shapes DESIGN section 15.2 documents; each stub's header lists them.
`STUB_EVENTS=<file>` makes the agy and ghcp-delegate stubs append `start|end NAME PID TIME`
lines (the agy launch from registration to the init event, and each run), which the suite's
`overlap` helper turns into the largest number of runs at once (A13, A25).
