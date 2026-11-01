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

Phase 0 captures go to `tests/fixtures/real/<cli>/` (none yet).
