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
    is the binary the doctor checked, and an unset or invalid value makes ghcp
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

## Phase 2, build item 1: pool slots (`scripts/lib/locks.sh`)

Folded into DESIGN §7.7, §15.3 and §12.2 already; kept here as the record of what the spec left
open.

67. **Free forms take no slot.** §15.3 says `cx-wsl` takes the slot "for `ghcp-*`, `agy*` and
    `grok`". Taken literally, `cx-wsl ghcp-job status` would wait behind running jobs (and the
    job wait loop would stall), so only executor calls take one: `ghcp-delegate`,
    `ghcp-handoff`, `ghcp-ci-debug`, `ghcp-job start`, `agy-delegate`, `agy-job start`, agy and
    grok runs. `ghcp-models` (a free probe) and `ghcp-cloud` (the agent runs on GitHub, no local
    Copilot process) take none; nor do `--help`/`--version`, `--print-command`, the other job
    subcommands, `agy models` and its zero-quota `-p /usage|/model|/config` probes, and
    `grok models|usage|inspect|login|logout`. An agy registration (`--new-project`) is a launch.
68. **Hand-dispatched agy holds the launch lock for the whole call.** Only `cx-run`'s raw lane
    sees agy's `init` event; the skill's steps and `cx-wsl agy*` cannot, and their `trees`
    snapshots (and the deleted `running` mark) assume no other agy launch during the run. So
    those runs never overlap any other agy launch, while `cap_agy` counts them; `cx-run`'s raw
    lanes (build item 2) are the ones that run up to `cap_agy` at once.
69. **Phase 1's whole-run lock is taken shared.** §15.3 said `cx_lock_acquire agy` "also takes
    that file (`flock -w` on it before the slot)"; exclusive would make `cap_agy` 1, so it is
    `flock -s`: a step of an older skill copy (which a running session may still hold) excludes
    every slot holder and vice versa, and slot holders coexist. Same wait budget.
70. **The skill's slot line** sources `locks.sh` next to `cx-wsl` (`command -v cx-wsl`): the
    plugin's `bin/` in a WSL session, `$RT/bin` inside `cx-wsl bash` steps. A `vars.sh` function
    was rejected because Step 2e's readers have no `vars.sh`. It uses `source`, not `.`, so the
    P43 D25 checker does not mistake it for the `vars.sh` line (no allow rule covers it, like
    the Phase 1 `flock` line). The wait is `CX_SLOT_WAIT_SECS` (600 s), not Phase 1's 80 minutes:
    a full pool falls to the next pool, as everywhere in Phase 2.
71. **`CX_SLOT_WAIT_SECS` crosses the forwarder** (§7.3 step 5 allowlist), so a forwarded call
    waits like a local one and A25's forwarded overflow can be tested.
72. **Nesting through `CX_SLOT_FDS`.** A process that inherited a lock descriptor (verified in
    `/proc/<pid>/fd`) reuses it: `cx-job`'s runner, `cx-run` inside it, or a step holding a slot
    that calls `cx-wsl`, never wait for a second slot of their own pool.
73. **`queued` marker.** `cx_lock_acquire` writes `$CX_JOB_DIR/queued` (the pool name) while it
    waits, for `cx-job status` → `queued` (build item 2).
74. **Options stay out of the caller's environment.** `cx_lock_cap` loads the options in a
    subshell, so a skill step that sources the library does not export `CLAUDE_PLUGIN_OPTION_*`
    to the sibling wrappers it then runs (both siblings read option variables of their own).
75. **Subagent guard text.** The Phase 2 draft (`subagent-context-p2`) dropped Phase 1's `cx-*`
    sentence and the Git Bash worktree forms (file tools on the `\\wsl.localhost` path, commands
    via `cx-wsl bash -c`, never `~`), which P55 and the Windows lane need; the shipped block keeps
    both and drops "the main session verifies your work" to stay under 800 characters (788).
76. **Copilot and Grok hand steps in WSL** (§12.2 steps 2b, 2c) take no slot in item 1: they move
    to `cx-run` in item 2; from Git Bash their direct `cx-wsl` forms take one already.

## Phase 2, build item 2 (part): adapters, normalizer, ledger, worker environment

The interface is written into DESIGN §15.2 ("The built interface"); these are the choices the
spec left open.

77. **Adapter signals.** §4.1 puts the adapters in the one exit table, and a standalone adapter
    prints its `CX_SIGNAL` like any command (`cmd: adapter`, added to the constant command
    list). `cx-run` sets `CX_SIGNAL_OWNER`, and the adapter then exits with the code and its note
    only, so a run still has exactly one signal.
78. **`run` exits 0 whenever the executor ran**; the executor's own status is in `rc` and only
    `parse` classifies it. Preflight refusals (13, 26, 28, 11, 14), a busy pool (28) and a
    cancellation (130) are the adapter's own exits.
79. **Keeper subshell.** The executor is started under `setsid timeout` by a subshell whose stderr
    is `/dev/null` and which waits for it: killing the executor's session would otherwise make the
    adapter's bash print a "Killed" job notice into its stderr (the caller's protocol stream).
    The session id is still the executor's (`<lane>.sid`, `$CX_JOB_DIR/sids`).
80. **Cancellation while queued.** A TERM/INT/HUP before the executor started (waiting for a slot
    or the launch lock, registering agy) exits 130 at once, writes `rc` 130 and removes
    `$CX_JOB_DIR/queued` (locks.sh has no trap of its own).
81. **Only green probes are cached.** A refused preflight (wrong version, logged out, missing
    model, paused agy) is probed again next time, so a fix the user just made takes effect at
    once; the agy pause also keys the cache entry.
82. **Running marks for every write lane.** `run` writes `$OUT/running` (the worktree and its
    `pwd -P` form) for the run of any write-mode lane, not only agy, and removes it at the end;
    the claude dispatch keeps it for `cx-run --finish`. The agy snapshots skip every marked tree.
83. **Snapshot comparison.** Both agy snapshots cover every other worktree (no mark filtering at
    snapshot time); `normalize.py trees-diff` compares only trees present in both snapshots and
    drops every tree named in a mark read before OR after the run. A worktree added or removed
    during the run (another task's step 1, a gate checkout) and a mark that disappears mid-run
    are therefore no false alarm. Writes into the main checkout during a run still are (as in
    Phase 1).
84. **agy raw details.** No `init` event within 120 s (`CX_AGY_INIT_SECS`, a test knob) kills
    the session and classifies 2 (a headless hang, #318); an `init` without a model, or a
    result with no `init` at all, is 21 (unverified served model). Registration failure stops
    the run (2) before launch. `/usage` runs before and after (the §15.2 row) from
    `$CX_HOME/probe`, under the launch lock; with `agy_claude_floor_pct` > 0 a bucket below it is
    28. `$CX_HOME/state/agy-paused` holds `{id, at, worktree, changed}`.
85. **Classification.** §15.1's order, with `missing` (13, a wrapper's own exit) after
    `sandbox`. Denials: grok and agy fail on any denial (G5: "permission required:" and
    `denied_actions` mean the task was not done as asked); Copilot uses ghcp's own rule (exit 15
    for a denied write) plus the general "any denial with no answer and no diff"; claude fails on
    a denied write. Text classes (quota, auth, sandbox, model) are read from stderr and error
    fields only, and only when the executor failed or left no answer (ghcp's rule).
86. **Served-model rules as built.** Copilot: every `models_used[].model` equals the request
    (an empty list is a note, not a mismatch); Fusion: `GHCP_FALLBACK` is 21 and the served
    model is `fusion.final_model`. grok: the `modelUsage` keys must be exactly the model. claude
    (assumption): the requested model must be among the `modelUsage` keys, and any other key that
    is not a Haiku helper is a mismatch.
87. **Worker environment additions.** Every `CLAUDE_PLUGIN_OPTION_*` is unset for the child
    (both siblings read option variables of their own, and a job runner may carry the
    conductor's); Copilot's `COPILOT_HOME` is set to the recorded value rather than only unset;
    the Copilot token is read at run time and never written into `copilot.env`. The claude
    worker's unset list is one array (`CLAUDE_WORKER_SCRUB`) plus every `CLAUDE_CODE_REMOTE*` and
    `CLAUDE_CODE_SESSION_*` present; P62 allow-lists that array line (it unsets, never reads).
88. **No pool slot for the claude dispatch and the cloud lane**: no local executor process runs
    (like `cx-wsl ghcp-cloud`). The cloud lane renders the task with `normalize.py render-cloud`
    and records task and PR from the URLs in gh's output (shape [docs-only]); `fetch` gives the
    PR head for the gate.
89. **Python stays in `scripts/lib/*.py`.** The adapters call `normalize.py` subcommands
    (`obj`, `json-list`, `verdict`, `meta-env`, `json-extract`, `worker-settings`, `uuid`) instead
    of heredocs. `normalize.py` loads `cxlib.py` by file path only for the probe, with bytecode
    writing off: a `__pycache__` in the plugin made `install-runtime.sh` refuse the copy (a
    `.pyc` holds CR bytes), which broke every forwarded call in the suite.
90. **The doctor's month-to-date ledger sum** also reads the Phase 2 lines' `cost.ai_credits`.
91. **Fixtures.** `tests/fixtures/real/ghcp/` holds the real ghcp 0.1.0 wrapper's output over
    ghcp's real Copilot recordings (a derivation, labelled in the fixtures README), its
    `--print-command` captures and `--help`; `real/antigravity/agy-delegate-help.txt` and
    `real/claude/help.txt` are real `--help` captures. agy's help and stream-json remain
    synthetic (`tests/fixtures/agy-help.synthetic.txt`, the agy stub's events).

## Phase 2, build items 2 and 3: `cx-run`, `cx-job`, `cx-init --user-grants`

Folded into DESIGN §12.2, §15.1 ("As built"), §15.5, §15.7 and §15.8; these are the choices the
spec left open.

92. **No conductor commit in Phase 2.** §15.1's flow ends in "post-checks", and §16.2's commit
    is a Phase 3 step (with `cx-gate`). `cx-run` leaves the change uncommitted, reports the
    diff (a scratch index, so the worktree's index is untouched) and writes `$OUT/vars.sh` with
    the Phase 1 variables, so the skill's Step 3 (commit and gate) and Step 5 (GitHub) keep
    working unchanged; P43 still runs Step 3 in scratch repos.
93. **Running marks after the run.** A write run with a diff re-marks its worktree `running`
    until Step 3 removes the mark, so the conductor's own commit in that tree is never a false
    `WRONG_TREE` for a concurrent agy run; agy tasks are left unmarked (their trees must stay in
    later agy snapshots, Phase 1's rule).
94. **`--exec auto` waits, then takes claude.** "has a slot" is a non-holding probe
    (`cx_lock_try` and release); when every eligible executor lane is full it polls them for
    `CX_SLOT_WAIT_SECS`, then takes the next lane in the order, which is always `claude`
    (appended to `opus_lane_order`), so auto itself never exits 28. `--no-wait` skips the wait.
    Effort low and max go to claude at once (§6.3).
95. **Read and review modes.** Read runs take the question as the prompt on a gate checkout of
    `--base`; review runs need `--branch` or `--diff` (§17.2's flags, in scope here) and put the
    diff into the checkout's `.conductor/change.diff` (relative in the prompt, so grok, agy and
    Copilot all read it without extra `--add-dir` grants). Finding parsing (`review.json`) and
    the author-based family default stay Phase 4; `--family` defaults to gemini.
96. **Stopped runs get a result.** `checks.json` `stop: {status, reason}` makes `normalize.py
    parse` classify a run that never reached its executor (25 setup, the adapter's 28/13/26/11/14,
    a cancel during setup), so `CX_RESULT` and the ledger show `env_failed`, `no_capacity`, …;
    refusals before anything is created (the free preflight, usage errors) only print the note
    and the signal.
97. **`--finish`.** Only for tasks `cx-run` started (`$OUT/cx-run.json`); a Phase 1 hand run
    finishes with Step 3. For the claude dispatch it classifies the subagent's work
    (`finished: true`) and writes the one ledger line (none for `dispatched`). For the cloud lane
    it is the gate: fetch `pull/N/head`, a gate checkout, setup and the task's commands there
    (20 / 25), which makes `cx-run` a raiser of 20 (§4.1 updated).
98. **The runtime copy is refreshed when stale.** `cx_runtime_ensure` reinstalls when a plugin
    file is newer than `RUNTIME_STAMP`, not only when the stamp is missing, so a folder
    marketplace edited in place (no version bump) does not keep running old adapters.
99. **Job runner hygiene.** The runner closes every inherited descriptor above 2 (the
    simulated forwarder's stderr relay kept the forwarded `cx-job start` waiting for the whole
    job) and unsets `CX_SLOT_FDS` (a job takes its own slot); its argv lives in `$jd/argv`, not
    on its command line. A wait interrupted by a trapped signal re-collects the child's real
    status (a TERM during `cx-run`'s wait once turned a clean 130 into "exit 143").
100. **Pid-reuse guard for sessions.** `cx-job kill` signals a recorded executor session only
    while one of its processes carries the job's `CX_JOB_DIR` (the adapters' executors inherit
    it), as the runner is proven by its start time.
101. **User grants.** The routes commands come from the repository at `--dir`/cwd (run it per
    repo; the agy grant list grows); an existing `auto_update` of any value is left alone (with a
    note when it is not `false`); a dotfile that is a symlink is written through to its target.
102. **Version 0.2.0.** The bump replaces existing `runtime/0.1.0` copies on first use (forwarded
    calls need `scripts/cx-run.sh` there); the suite now reads the version from `common.sh`
    (`$CXV`) instead of pinning 0.1.0 in every check.
103. **Policy texts.** The inline agy registration left the WSL policy (cx-run registers); P20
    now asserts `cx-run --background`, `cx-job wait` and `cx-run --mode review` in both texts
    (2,789 and 2,798 rendered characters of 2,800). The order phrase rendered by `policy.sh`
    still names the wrappers (`agy (agy-delegate)`), which P21 pins; shortening it to the lane
    names is a policy.sh change left for later.
104. **Not built in this step:** the optional item 4 (`agents/cx-runner.md`, `hooks/gate.sh`,
    `workflows/opus-pools.js`, D33), Phase 3 and 4 pieces (`cx-gate`, the conductor commit,
    `--mode ci`, `--pr`, `review.json`), and forwarding of `CLAUDE_CODE_SESSION_ID` /
    `CLAUDE_EFFORT` (the forwarder's allowlist keeps every `CLAUDE_CODE_*` out, P50), so ledger
    lines of forwarded runs carry `claude_session: null`.
105. **Running mark from creation.** `cx-run` marks a task worktree `running` as soon as it creates
    it (§15.1 had the mark only during the adapter's run): a sibling task's `setup` (which may
    run for minutes) and executor wrote into an unmarked tree between another agy run's two
    snapshots and gave that run a false `wrong_tree` 22, pausing agy dispatch everywhere. A run
    that stops before its executor drops the mark; a reused worktree that was already marked
    keeps it.
106. **Late cancellation signals.** A `cx-job kill` delivers several TERMs to the adapter
    (`pkill -s` on the runner's session, then one forward from `cx-run` per TERM it gets from
    `pkill` and `timeout`). The adapter used to reset its trap before writing `rc`, so a late
    TERM could end it with 143 and no `rc`, and the job reported `FAILED` ("stopped before its
    executor ran"). The trap now stays until `rc` and run.json are written; `cx-run` records
    `cancelled` in `checks.json` and treats an adapter ended by a cancellation's signal as
    cancelled.
107. **`claude.sh argv --dry-run` without `--out`** showed `--settings /cx-worker.json`; it now
    shows the out directory a run of that id would use (`$CX_HOME/out/<id>`).
108. **Tests (§15.8).** Stubs `agy` and `ghcp-delegate` take `STUB_EVENTS` (start/end lines for
    the suite's overlap count). The suite's background sections start as soon as their inputs
    exist (static at once; init and doctor after the options section, which swaps the shared
    settings file; the Phase 2 sections next to them), shellcheck runs as three processes, and
    each background section prints its end time, so the whole run stays under about two
    minutes on four cores with A25's twelve concurrent jobs.
109. **agy's init event read once.** The raw lane's wait for the init event read
    `agy.events` twice (sed for the model, then `grep -q '^init'`); when the watcher appended the
    line between the two reads, the model came out empty and a correct run was killed as a
    false 21 `MODEL_MISMATCH` (seen once under load in A4). One `grep -m 1` read now gives both.

## Phase 2 final review (2026-11-01, 27 findings): choices where a finding offered alternatives

1. **The hand steps' executor calls run through `cx-wsl`, also in WSL** (§12.2, §15.3). The
   review offered a slot line (`source …/locks.sh && cx_slot_take`) or `cx-run --mode read`
   for the commit-message Grok call and `ghcp-ci-debug`. A read run forces grok's JSON schema
   (wrong for a commit message), and a slot line needs `source` and a function call, which no
   narrow allow rule covers. `cx-wsl grok …` and `cx-wsl ghcp-ci-debug …` take the slot, add the
   per-tool prefix and match one narrow rule each (`Bash(cx-wsl grok:*)`, `Bash(cx-wsl
   ghcp-ci-debug:*)`), the same in a WSL session and inside a Windows `cx-wsl bash -s` step.
   D25's host-side warning for `Bash(cx-wsl:*)` now says a WSL session needs only those rules.
2. **D25 lists exactly the skill's forms.** The Windows list drops `cx-wsl gh repo view` and
   `cx-wsl git push` (the skill runs those only inside `cx-wsl bash -s` steps, which prompt);
   the host list drops bare `git push` and `gh repo view` (no skill line runs them). P43 checks
   both ways.
3. **Runtime copy updates wait instead of going content-addressed** (§7.5). The review suggested
   `runtime/<version>-<sha12>` directories; the build keeps one `runtime/<version>` and refuses
   to swap changed content into it while `cx_runtime_users` counts a live `cx-run` (its held
   `.run.lock` names the copy in an `rt=` line) or a live job runner (its meta names it). The
   next call after they end installs the update; meanwhile `cx_runtime_ensure` keeps using the
   consistent old copy and says so. Same layout, no pruning logic, the same guarantee.
4. **The policy labels** are `agy (raw)`, `Copilot` and `own subagents`: no label names a
   wrapper to call (§10.2).
5. **`CX_KILL_GRACE_SECS`** (default 10) is the adapter's KILL grace after a cancellation; the
   suite sets 2. Not an option and not forwarded (a forwarded run uses the default).
6. **agy-delegate prompts starting with `-`** go on stdin (its documented `-` form) instead of
   after `--`, which agy-delegate's help does not document.

## 0.2.1 (2026-11-06): choices the live-probe decisions left open

1. **`cx-route` is generated, self-contained bash** (`$CX_HOME/routes/<id>/cx-route`, written by
   `normalize.py route-snapshot` with the commands inlined), not a shipped script reading a
   snapshot: grok's `strict` profile reads only the worktree, system paths and its `read_only`
   grants, so the command must need no runtime file and no python. Its own refusals exit 127
   (a name not in the snapshot, any argument after the name); every other status is the
   check's. Names: the `.cx/routes.json` key holding the command, else `cmd-N`. Its shebang is
   `#!/bin/bash -p` (else cx-run's own bash), and it hands the check the caller's exported
   variables through `env -i` minus the shell startup ones and `BASH_FUNC_*`: whoever calls it
   controls its environment, but a full `env -i` would break checks that need toolchain
   variables.
2. **The grok profile grants `$CX_HOME/routes` read-only** besides the git common directory: a
   per-repository profile cannot name a per-run directory, so each run's `cx-route` lives in its
   own `$CX_HOME/routes/<id>/` (only the script: the checks' commands and paths), never in the
   out directory. Other runs' digests, task files and diffs, `$CX_HOME/secrets` and the ledger
   stay unreadable to grok writers (until the 2026-11-06 review the profile granted all of
   `$CX_HOME/out`). `$OUT/routes.json` stays in the out directory: only the conductor reads it.
3. **`$CX_HOME/routes/<id>` comes right after the worker shims on PATH**, so the shims still win
   over any CLI name and nothing on the record path can shadow `cx-route`.
4. **The flag contract is cached with the probe** (10 minutes) and keyed by the argv's flags
   and the binaries' resolved path, mtime and size, so a CLI that updated itself is checked
   again on the next run, while a help text change without a new binary waits for the cache.
5. **Option `grok_sandbox_profile` defaults to `auto`**; the 0.2.0 default `cx-workspace` (which
   Claude Code may have saved into settings) counts as `auto`, so no saved value keeps the
   invalid profile in use.
6. **agy wrapper mode keeps no grants** (agy-delegate has no `--settings`): a write in wrapper
   mode is denied unless the user's own agy settings allow it; the adapter says so. Raw mode,
   the default, carries the per-run grants; the Gemini review lane only reads.
7. **The review prompt is lane-aware**: agy (agy-delegate, no grants) is told to read with its
   own file tools and run no shell command; the other executors may run `cx-route <name>`.

### The 2026-11-06 security review (choices it left open)

8. **`git diff`, `git log` and `git show` are out of every grant** (agy, Copilot, the headless
   Claude worker), against decisions 3 and 5 of the probes: their `--output=<path>` writes any
   file and `git diff --no-index` reads any file, and neither agy's token-prefix rules nor
   Copilot's first-level-subcommand approvals can forbid an option. `git status` (and agy's
   `ls`) stay; executors read their own changes with their file tools. Whether Copilot's path
   verification would have caught `--output=/abs` is not tested (moot now).
9. **A rewritten worktree `.git` is `tampered` (24)**, the §4.1 row for "a protected path
   changed": the closest existing status, and no new exit code. The conductor-side git keeps
   the user's global and system git configuration (only the worktree's own link is untrusted:
   grok cannot write `~/.gitconfig`, and the lanes without an OS sandbox can already run any
   code through the repository's checks), overriding only the keys that run programs
   (`core.fsmonitor`, `core.hooksPath`, `core.pager`, `core.sshCommand`) and never entering
   submodules or embedded repositories (`-c diff.ignoreSubmodules=all`, which git passes on to
   every git it starts, and `--ignore-submodules=all` for status and diff).
10. **The grok profile name is conductor's own**: any `[profiles.<name>]` table outside the
    markers is replaced (a writer may have stripped them); with tomllib (Python 3.11 and
    newer) the parsed profile must then equal the rendered one, else the run is refused
    (dotted keys or an inline table defining it again). Without tomllib only the tables are
    swept. A worktree `.grok/sandbox.toml` refuses a grok write run outright, since which
    definition grok prefers is unverified (DESIGN §20 item 73).
11. **grok's sandbox is checked with grok itself**: the preflight runs `grok --sandbox strict
    models` (free) and refuses the lane (2 `FAILED`, not a new code) on a line saying the
    sandbox was not applied; a run's stderr with that line is 2 as well, with a reason saying
    it ran unconfined when grok went on. The doctor also reports the Landlock ABI
    (`cxlib.py landlock`; a warning when the kernel has none), but grok's own answer decides
    the lane.
