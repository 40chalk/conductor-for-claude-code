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
    Bash runs go through a pool of 4: about 50 s on 4 cores (about 80 s sequentially). The
    wall time is printed as an `INFO` line; only `CX_TEST_STRICT_TIME=1` makes a run of 60 s or
    more a FAIL (§14.1), so a slow or loaded machine never turns a functionally green run red.
37. `README.md`, `CLAUDE.md` and `CHANGELOG.md` (§13.2) were written so P2 and P43 can check
    them; `.gitattributes` got its two fixture lines (§2.2).

## Phase 1 review (2026-11-01, 28 findings): choices where a finding offered alternatives

38. **wsl-entry.sh terminal test (§7.4 step 8).** "Terminal mode" is decided by `/proc/$$/stat`
    fields 5 and 8 (`pgrp` = `tpgid`), not by `[ -t 0 ]` or opening `/dev/tty`: a process with a
    controlling terminal that is not in its foreground group (a developer running the suite in
    the background of a terminal) keeps the `set -m` launch, so P16's cancellation case still
    sees a separate group. In terminal mode the target runs in the foreground (not a background
    job without job control, which would ignore SIGINT), and the watchdog, a member of the group,
    ignores TERM only once it has started its own TERM/KILL sequence.
39. **Media and research lanes (§0.3, option a of the finding).** Dropped until the v1.1 Docker
    lane instead of documenting a G10 exception: an exception would need the user's consent (U2
    covers spending, not skipping permissions). Research goes to Claude's WebSearch and grok.
40. **`cx-doctor --json` on a Git Bash forwarding failure (§8.1, §8.7).** stdout stays empty
    and the W report goes to stderr before the forwarder's lines, instead of a constant JSON
    object chosen by exit code: the only hand-built JSON stays `cx_signal`'s fallback, and the
    `CX_SIGNAL` remains the last stderr line because the forwarder's stderr is held back in
    JSON mode. `--windows --json` is a usage error (no python on Git Bash to encode the report).
41. **CRLF steps through `cx-wsl bash -s` (§7.7).** Stripped with a note rather than refused
    with exit 44: the Windows-side Write tool may produce CRLF for every step, and a CR before LF
    has no meaning in a bash step.
42. **Forwarded git environment (§8.3 D5).** Folded into D5 rather than a new D29, so the check
    ids stay D1–D28; wsl-entry.sh keeps an `SSH_AUTH_SOCK` that names a live socket but starts no
    agent and guesses no socket path.
43. **D25 rules (§8.3).** Rules are written as the literal leading text of the skill's simple
    commands (`$VAR` text and `"${G_ENV[@]}"` included), the same assumption the earlier
    prefixed rules made; how 2.1.316 matches them stays [unverified] (§20 item 36). Step 5 uses
    `gh … -R "$REPO"` so no `gh`/`git push` runs inside a `(cd … && …)` subshell, which P43
    rejects. `REPO` is parsed from the origin URL in Step 1 (no network call).
44. **WRONG_TREE snapshot (§12.2 step 2a).** Every other worktree of the repo is compared, so a
    second lane writing in the same repo during an agy run also trips it; the skill therefore runs
    agy lanes while no other lane of the repo writes (in the A/B, agy first). `$WT` is excluded
    by its given and its physical path (`pwd -P`).
45. **Windows-side binaries (§7.6).** The automount-root skip in `abs_cmd` applies on WSL hosts
    only; `cxlib.py wsl-resolve` always refuses a path under its `--mnt-root` (cx-wsl passes the
    pathmap root) or `/mnt/`.
46. **The WSL-terminal doctor command.** Messages name `~/.conductor/runtime/current/bin/cx-doctor`
    (present once any call was forwarded) and `/conductor:doctor`; a plain WSL terminal has no
    plugin `bin/` on its PATH.

## Projects (beta) and ultracode, Phase 1 parts (DESIGN Appendix A.3)

These choices were made while folding the Projects + ultracode addendum into DESIGN.md, adjusted
for the user's 2026-11-01 decisions (U7: every Project thread runs locally; U8: ultracode is
normally off). DESIGN.md already states each of them; they are listed so a reviewer can find what
departs from the addendum.

47. **`subagent.sh` reads stdin (§10.7).** The addendum said it never reads stdin. It reads at
    most 256 KiB with a 2-second timeout, like `policy.sh`, and stays silent when the payload
    names an `agent_type` other than `workflow-subagent` or `general-purpose`: if the matcher
    were not applied as alternation (§20 item 49), the guard must never reach another plugin's
    agent (`ghcp:ghcp-delegate` has to keep calling ghcp).
48. **Guard text (§10.7).** Adds "no other cx-* command than cx-wsl bash or cx-wsl git for your
    own task", so the guard names every executor surface (`cx-*`, `ghcp-*`, `agy*`, `grok`,
    `copilot`) while a Windows claude-pool agent can still run its tests through `cx-wsl bash`.
    764 of 800 characters.
49. **Workflows line (§10.3, §10.4).** Ends with "Pool slots are not shared yet: one agy run at a
    time on this computer, across all sessions and threads" (U7: concurrent Work locally threads
    are the normal case). The rendered texts are 2,662 and 2,664 of 2,800 characters.
50. **Projects instructions (§9.6).** Rewritten for local-only threads instead of the addendum's
    "run everything else as cloud threads" and "at most one Work locally conductor thread"; the
    Phase 1 agy rule is phrased for the coordinator ("give agy work to one thread at a time") and
    for a thread ("waits for it or uses the next Opus pool"), since no Phase 1 mechanism lets a
    thread see another thread's agy run.
51. **Doctor layout (§8.2).** D30, D31 and D32 go into a new first section, Session, instead of
    the first lines of Host (D31 needs D8's version, which is probed later; a section keeps them
    together). D32 does not run on a forwarded call: it describes the machine where Claude Code
    runs, which W11 covers for Git Bash. W11 takes the CPU count from `NUMBER_OF_PROCESSORS`
    (no `nproc` on the §3.1 list).
52. **The desktop WSL-session warning (D30).** Detected heuristically on a WSL host in a
    `local` session whose entrypoint starts with `claude-desktop` or that has
    `CLAUDE_CODE_DESKTOP_APP_VERSION` (the H8 entrypoint is [unverified]); W10 always carries the
    note on the Windows side, and W3's drive case became info without `\\wsl.localhost` advice.
53. **Cloud doctor (§7.3 step 0a).** Renders the header, ✗ D30 and the summary with the pure-bash
    renderer (no python, no probes, no host record) on every host, on stderr with `--json`.
54. **`.claude/worktrees` exclusion (§12.2, P60).** Implemented in Phase 1 (the addendum's P60)
    because concurrent Work locally threads with the folder card's Worktree option are the normal
    case: `trees` skips worktrees under `$TOP/.claude/worktrees/` and excludes that directory from
    every status and untracked-file list.
55. **§20 numbering.** The addendum's items 37–58 collided with items 37–39 already in DESIGN; they
    are 40–61 there, with `claude remote-control` inside WSL first (item 40, live check L11).

## Final Phase 1 review (2026-11-01, 18 findings; DESIGN Appendix A.4)

56. **No agy job form.** The lock, the registration and both `trees` snapshots must span the
    whole agy run, and a lock held by one Bash call cannot outlive it without relying on
    `agy-job`'s fd handling; so agy runs only as step 2a's single background call (the hybrid
    recipe included) and the policy names only `ghcp-job start` as a job form.
57. **`running` marks instead of serializing the fan-out.** Each dispatch writes `$OUT/running`
    (the worktree's path and its `pwd -P` form); agy steps delete their own task's mark first (a
    finished agy task's worktree is agy's likely last project root and must stay in later
    snapshots); step 3 deletes it for every lane. `trees` drops marked worktrees, so Copilot jobs
    and the claude pool keep running in parallel with agy, also across threads. Residual false
    alarms (a worktree added or removed during the run) are documented; the remedy never
    restores a tree the task did not create.
58. **`trees` lives in `vars.sh`.** Defined once in step 1 (a quoted heredoc), so the snapshot is
    the same in every step that sources `vars.sh`; P60's count is now one per file. The
    `.claude/worktrees` exclusion keys on the main checkout (the first `worktree list` entry, not
    `git-common-dir`, which is wrong for submodules), and `$TOP` itself stays in.
59. **The agy lock.** `exec 9>> "$HOME/.conductor/locks/agy"; flock -w 4800 9` (80 minutes, so the
    wait plus registration plus agy-delegate's guard stays under the 2-hour background limit);
    `$HOME`, not `$CX_HOME`, like every other path in the steps; exit 28 `NO_CAPACITY` with
    `AGY_BUSY`. No D25 rule for `flock` (`flock FILE CMD` would allow any command).
60. **Session hardening.** `cx_session` and `policy.sh` treat Git Bash (`MINGW*`, `MSYS*`) and WSL
    (`WSL_DISTRO_NAME`, a `WSLInterop*` file under `CX_DETECT_ROOT`, `uname -r` with
    `microsoft`) as the user's computer for both `cloud` and `byoc`. The suite pins
    `STUB_UNAME_R` to a plain kernel when it runs on a real WSL kernel, so its cloud cases stay
    cloud there.
61. **`REPO`.** `gh repo view --json url` in step 1 (run from inside the repo, which step 1 already
    requires), with the URL parse (`:port` stripped) as the fallback when gh is not logged in;
    `Bash(gh repo view:*)` joins D25 and the P43 checker covers `gh repo`.
62. **CI fix hand-back.** Appending `BASE=<cx/id head>` to `vars.sh` (rather than a new task id)
    keeps the PR branch: step 3 then commits the fix on top of the pushed commit and step 4
    reviews only the fix.
63. **Copilot cloud agent in Phase 1.** A hand recipe in step 5 (`ghcp-cloud create -R "$REPO" -`
    with the contract on stdin, its Forbidden list without "committing, pushing or branching"),
    gated on a gate checkout of `pull/<N>/head`; the Phase 2 item becomes the adapter. Grok
    remote sessions stay the user's (grok 1.0.70 only resumes them).
64. **Token route.** Only the `ghcp-*` arm of `cx-wsl` exports `COPILOT_GITHUB_TOKEN`, and only
    from a regular, non-symlink, user-owned 0600 file, so a `bash -s` step (which also runs grok
    and agy) never carries the secret; the skill tells Windows users with the token file to run
    Copilot lanes as direct `cx-wsl ghcp-*` calls.
65. **Lite readers.** `IFS='"' read -d '' -a` splits the text at quotes once and only the parts
    outside strings are scanned for brackets; `_cx_lite_obj` finds keys with `${x%%"KEY"*}`
    (bash scans longest-suffix matches linearly, while `${x#*"KEY"}` is quadratic). On an 80 KB
    file `cx_opt_lite` went from 3.8 s to 0.09 s and `cx_lite_top` to 0.07 s (the review measured
    10 s per parse of a 66 KB file before).
66. **Forwarded report note.** One header line ("Fixes run inside WSL, in a WSL terminal …")
    rather than a prefix on every fix; D13's fix also gets an explicit `in a WSL terminal:` when
    forwarded, and TOKEN_FIX always starts with it.
