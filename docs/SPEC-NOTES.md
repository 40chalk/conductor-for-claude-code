# Spec notes (Phase 1, builder A: host layer and bins)

Where `docs/DESIGN.md` was silent, ambiguous or self-contradictory, the code follows the plan's
intent and records the choice here. Each item names the § it touches. Fold the ones you accept
into DESIGN.md and delete them here.

## Additions (helpers the spec did not list)

1. **cxlib.py subcommands beyond §4.4.** `json` (the `emit` object without the prefix),
   `emit-obj NAME FILE`, `toml-table FILE NAME` (D17 profile check), `const NAME` (prints
   `CURSOR_WORKER_MSG` / `CURSOR_POOL_MSG`, so the doctor never spells the text), `conductor-options
   FILE…` (the real parse W7 compares with), `tsv-to-json FILE` (builds the host-record description
   from dotted `key[:type]<TAB>value` facts, so bash never hand-builds JSON), `agy-grant FILE PATH`
   (D18), `doctor-siblings` (D13, D20–D26 as doctor records, plus the resolved wrapper paths),
   `doctor-pools` (§8.4 records plus the `CX_POOLS` payload file), `init-plan` (detection plus
   cx-init's overrides; its output is `init-apply --plan`). `emit` also accepts a `:num` suffix.
2. **`options-check` inputs.** The defaults reach it as `--default name=value` from
   `CX_OPT_DEFAULTS`, so every default stays written exactly twice (§5.1). `--settings FILE`
   (repeatable) supplies the files whose unknown conductor keys D7 reports; `--repo DIR` enables the
   "worktree_root inside the current repo" rule; `--tsv` prints D7's doctor records directly.
   Result entries carry `effective` and `source` besides the §4.4 keys.
3. **`doctor-render` flags.** `--host-json`, `--caller`, `--record`, `--bare` (check lines only:
   the `--logins-only` output W9 relays) and `--emit-doctor` (prints `CX_DOCTOR` to stderr after
   the report). `init-apply` likewise prints its notes and `CX_INIT` to stderr itself.
4. **Doctor records** may hold more than one fix: TSV fields 5, 6, … are one `fix:` line each;
   `--json` joins them with `\n` in `fix`. A record with status `meta` (`meta<TAB>lite<TAB>NAME<TAB>VALUE`)
   carries the Git Bash lite-reader values to the WSL side for W7 and is never rendered.
5. **Section and ID assignment (§8.2).** Host: D1, D2, D5, D6, D27, D28. Runtime: D3, D4.
   Options: D7. CLIs: D8–D12. Version pins: D14. Logins: D15–D19. Sibling plugins: D13, D20–D26.
   Pools records use the IDs `pools-agy`, `pools-copilot`, `pools-grok`, `pools-claude`.
6. **`forward-wsl.sh --bootstrap-install`** is the internal mode behind `cx-doctor
   --install-runtime` on Git Bash (§8.1); it exits with the installer's code, or 40 when wsl.exe
   could not run it.
7. **`common.sh` exports** `CX_SHIPPED_FILES` (§13.4), `CX_SHIPPED_EXEC`, `CX_RUNTIME_DIRS`,
   `CX_FORWARD_CMDS`, `cx_path_in_var VAR VALUE` (the no-subshell form of `cx_path_in`),
   `cx_help_version`, `cx_trim`, `cx_have_timeout`, `cx_is_windows_shell`, `cx_win_config_dir`
   and `cx_win_settings_file`. `detect.sh` also sets `CX_WSL_INTEROP` (1, 0, or empty off WSL) for
   D1's "interop disabled" note.

## Choices where the spec was ambiguous

8. **wsl-entry.sh keeps `CX_MNT_ROOT` and `CX_DETECT_ROOT`** for the target when wsl.exe provided
   them (§7.4 step 4 does not list them). They are unset in production; the suite's wsl.exe stub
   sets both (§14.2), and dropping them would make the target map paths and detect the host
   differently from wsl-entry.sh itself (the build container's `/.dockerenv` would turn a
   forwarded doctor into host `docker`).
9. **One signal owner during the bootstrap install (§7.3 step 8).** The installer's stdout and
   stderr are captured; its lines are relayed to stderr minus any `CX_SIGNAL` line, so a failed
   install still ends in exactly one signal (the forwarder's 41) and the forwarded command's
   stdout stays clean (`cx-init --json` on first use).
10. **Bounded tee drain.** The forwarder waits at most 5 s for the stderr `tee` after wsl.exe
    exits (2 s on cancel), so a detached grandchild holding stderr cannot hang it.
11. **`cx_signal` details (§4.2).** The hand-built line takes `exit` from the status's table row,
    and an unknown status falls back to the row of the given exit (else `FAILED`); `cmd` falls back
    to `cx` outside the fixed list. `CX_SIGNAL_CMD` overrides `cmd`, so the forwarder and
    wsl-entry.sh report the forwarded command (`cx-init`), while their notes keep the
    `forward-wsl:` / `wsl-entry:` prefix. With RETRY omitted the status's constant retry (or null)
    is used on both paths.
12. **`cx_status_for_exit`** prints nothing and returns 1 for 0, 1, 126 and codes outside §4.1.
    **`cx_bool`** returns 2 for a word outside both lists (callers treat any non-zero as false).
13. **`cx_opt` validates and normalizes** (§5.3): it prints the default plus the "ignoring invalid
    option" note (once per process when not called in a subshell) for an invalid value, appends
    `claude` to `opus_lane_order`, lowercases enum words. The "worktree_root inside the current
    repo" rule needs git and is only applied by `options-check` (D7).
14. **cx-init output.** `excluded` (CX_INIT and `--json`) means `/.conductor/` is in
    `info/exclude` after this run (in a dry run: already). `written` lists the files written, or
    in a dry run the files that would be written; it is empty on exit 5. Text-mode notes go to
    stderr as `cx-init: <note>`. A conflict line reads `CONFLICT <file> (<why>; --force to <action>)`.
15. **cx-init refusals --force does not override:** a target that is a symlink (an `AGENTS.md`
    linked to `CLAUDE.md` would otherwise edit `CLAUDE.md`, §9.1), a non-regular file, and a
    `cx:begin` line without `cx:end` ("fix the markers by hand"). Exit 2 (not in §9.1's list)
    when python3 or git is missing on the executor host.
16. **cx-doctor on Cygwin or an unknown host** exits 43 (forwarding step 0) instead of rendering
    D1 as ✗. `--host wsl` on plain Linux, macOS or Docker exits 43 (§8.1 "other hosts").
    INT/TERM/HUP end the doctor with `CX_SIGNAL CANCELLED` (130).
17. **Git Bash `--windows`** always prints plain text (no python3 there, so `--json` cannot
    apply) and its `CX_DOCTOR` becomes the plain note `cx_emit` prints without python3. W9 is one
    line followed by the relayed WSL-side lines; the WSL side's `--logins-only` exits 4 (with
    `CX_SIGNAL CHECKS_FAILED`) when a login line failed, which W9 still counts as "ran". W7 reports
    a missing Windows-side conductor install as info.
18. **W6 runs `git config --global --get core.autocrlf`** as §8.6 asks, although §3.1 lists git
    "for W5 only". W6's fixes are the sed fix and fix 2 of D3; fix 3 (marketplace clone) is not
    offered on Windows because Git Bash never runs git on a repository.
19. **D3 fix 3** compares `git -C X rev-parse --show-toplevel` with X after resolving symlinks
    (`pwd -P`), since git prints the physical path.
20. **D16 raw-probe order:** "from --model flag is not available" (logged in), then killed
    (timeout), then `SANDBOX_RE`, then `AUTH_RE`, else "other" (✗ with the first output line).
    With ghcp, rc 0 whose output does not parse as a catalog is reported like rc 2 (!). A second
    probe keeps `GH_TOKEN`, then `GITHUB_TOKEN`, whichever is set.
21. **D17/D18/D10 probes** are exactly the §8.3 ones (D17 does not unset `XAI_API_KEY`; D28 warns
    about it). D18's grant check ignores a trailing slash inside `write_file(...)`.
22. **D25 forwarded without a Windows-side settings file** prints an info line ("not checked").
    D26 prints nothing unless `sandbox.enabled` is true.
23. **install-runtime.sh** copies the six directories that exist in the source, refuses (exit 1)
    a source without `scripts/lib/common.sh`, checks CR in every copied file (text or not), and
    restores a missing `current` link when the same sha256 is already installed.
24. **pathmap.sh** accepts `--` before PATH (paths may start with `-`). T7 also refuses `//x` for
    `--caller wsl`, following the table's order.

## Things the tests (P38, P40, P44) should know

25. **shellcheck.** Every `*.sh` is clean under `shellcheck -x` from any cwd: line 2 of each
    script is `# shellcheck source-path=SCRIPTDIR` (the `--help` printer skips lines 1–2). Without
    `-x`, shellcheck reports SC1091 ("not following") and SC2034 for variables used across
    files, so P38 should run `shellcheck -x`. `detect.sh` and `pathmap.sh` source `common.sh` with
    `# shellcheck source=/dev/null`: `common.sh` sources them, and following the cycle makes
    `shellcheck -x` run for minutes. The §3.6 shim text (`CDPATH= cd`) triggers SC1007; P38 covers
    `*.sh` only, so `bin/*` keep the exact spec text.
26. **P40 greps.** `cxlib.py` contains the string `python3 -m ` (§9.3's runner for detected
    Python commands, never executed) and `cx-doctor.sh` resolves `node` with `command -v` for the
    host record's `path` (§7.6). A "no node calls / python3 always -I" check must look at
    invocations, not at every occurrence.
27. **P44.** The only shipped occurrences of the word are `worker-shims/cursor-agent` in
    `CX_SHIPPED_FILES` / `CX_SHIPPED_EXEC`, and `CURSOR_WORKER_MSG` / `CURSOR_POOL_MSG`, each
    assigned once in `cxlib.py` (referenced by name elsewhere).

## Not built by builder A

28. `scripts/cx-wsl.sh` and `bin/cx-wsl` (§7.7) were outside builder A's file list; the test
    engineer built them (item 29).

## Test engineer (Phase 1 suite, `tests/run-tests.sh`)

29. **cx-wsl (§7.7).** The TOOL name is validated before forwarding (a usage error never starts
    wsl.exe). Every tool, `bash` included, needs the host record (no record → 13), because the
    PATH it builds comes from it. A sibling wrapper that moved is re-resolved once from
    `installed_plugins.json` for the call, but the record is not rewritten (`cx-doctor` does
    that). For `ghcp-*`, `GHCP_COPILOT_BIN` is set to the record's `bin.copilot` when unset: it
    is the binary the doctor checked against the pin, and an unset or invalid value makes ghcp
    fall back to whatever `copilot` is on PATH. The lookup is `cxlib.py wsl-resolve` (no Python
    in bash).
30. **No `CX_FORWARD` for cx-wsl.** §7.4 step 7 emits `CX_FORWARD` for every forwarded command,
    while §4.1, §7.7 and P16 say `cx-wsl` adds no `CX_*` line to the tool's output.
    `wsl-entry.sh` now skips `CX_FORWARD` for `cx-wsl` (its failures still print their one
    `CX_SIGNAL`).
31. **Stub log format (§14.2).** One line per call, `NAME<TAB>cwd=<pwd><TAB>extras<TAB>argv:
    <printf %q of each argument>`, instead of one argument per line (an argument holding a
    newline would break that record format). Extra stub knobs: `STUB_GHCP_MODELS_FILE`,
    `STUB_WSL_LIST_V_FILE` (raw `-l -v` bytes), `STUB_WSL_DETECT_ROOT`, `STUB_UNC_DISTRO`,
    `STUB_GIT_DUBIOUS_PATH`, `STUB_REAL_GIT`. Knobs that must reach stubs on the WSL side of a
    forwarded call (where `wsl-entry.sh` rebuilds the environment with `env -i`) are read from
    `$HOME/.stub.env`; `uname` never reads it.
32. **P44** greps every shipped file outside `docs/`, `tests/` (the suite itself names
    `cursor-agent` and the constants), `README.md` and `CHANGELOG.md`.
33. **P10** checks that every code a script returns (`cx_signal X N`, `exit N` at statement
    position) is listed in its header; not the converse (forwarding codes reach a script only
    through `cx_forward_if_needed`).
34. **Precedence "flag > env".** No Phase 1 option has a CLI flag; P4/P5 cover environment >
    Windows-side settings > executor-host settings > default.
35. **A forwarded login failure is a warning when the record says "direct: logged in"** (§8.3,
    the keyring comparison), so P16's forwarded "cx-doctor 4" case uses a version failure.
36. **Speed.** The static, cx-init and doctor sections run in the background and doctor and Git
    Bash runs go through a pool of 4: about 45 s on 4 cores (about 80 s sequentially), under
    §14.1's 60 s.
37. `README.md`, `CLAUDE.md` and `CHANGELOG.md` (§13.2) were written so P2 and P43 can check
    them; `.gitattributes` got its two fixture lines (§2.2).
