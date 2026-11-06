# Changelog

## 0.2.2 — 2026-11-06

A security fix: no conductor grok run uses grok's built-in `read-only` sandbox any more.
conductor's strict-based grok profiles now add the system directories WSL's
`/etc/resolv.conf` needs (grok end to end on WSL is not yet measured, DESIGN §20 item 81), and
W6 and D3 look for CRs in a way that avoids the false positive measured on Git Bash (not yet
re-measured there, §20 item 82). Copilot Fusion lanes no longer pay for a plain-`auto` re-run
whose answer conductor discards.

- **Security: grok read, review and commit-message runs could plant code that runs unsandboxed
  later.** 0.2.1 ran every grok read and review (`--sandbox read-only --always-approve`) and the
  skill's Step 3 commit-message call (`--sandbox read-only --cwd "$TOP"`) under grok's built-in
  `read-only` profile. Measured live on grok 1.0.70 (the build container, 2026-11-06,
  linux/landlock plus bubblewrap, enforced; grok's agent ran a probe script through its shell
  tool): `read-only` write-denies only grok's protected set (`config.toml`, `sandbox.toml`,
  `trusted_folders.toml`, `managed_config.toml`, `requirements.toml`, `hooks-paths`, `hooks/`,
  `bundled/`, `bundles/`: an append-open of each was denied) and lets grok write the rest of
  `~/.grok`: grok's binary in `~/.grok/bin` (`grok-1.0.70`, which runs whenever grok is
  launched from there: the curl installer's PATH, npm's node launcher; an npm install on Linux
  may run a copy of its own), the ripgrep it runs (`~/.grok/vendor/`),
  `~/.grok/installed-plugins/`, `auth.json`, `logs/`, `docs/` and `~/.grok` itself. Those runs
  read executor-written or repository content that could steer them into replacing grok's
  binary or ripgrep, planting a grok plugin or replacing `auth.json`: code that later runs
  outside any sandbox, or later grok sessions signed in to another account. The fix: read and
  review runs now run
  under the repository's own profile `cx-<repo>-<hash>` (extends `strict`, the same profile as
  writers; a custom `grok_sandbox_profile` is used in every mode), which writes only the run's
  checkout, `~/.grok/sessions`, `/tmp` and `/var/tmp`; every file they read (the prompt file, the
  task, a review's diff) lies inside their gate checkout, and the schema travels inline. The
  lane writes the profile before every run in every mode, again once the slot is held, and
  refuses a `.grok/sandbox.toml` in a read's or review's checkout too (a review checks out an
  executor-written branch, which can commit one), not only in a writer's worktree. A built-in
  that writes `~/.grok` (`off`, `devbox`, `workspace`, `read-only`) is refused, and `cx-doctor`
  D17 fails when `grok_sandbox_profile` names one. If you ran 0.2.1 grok reads or reviews on
  code you do not trust: reinstall grok (its binary, `vendor/`), log out of grok and log in
  again (a new `auth.json`), and look for anything in `~/.grok` newer than the first such run,
  `find ~/.grok -newer <a file from before it> -not -path '*/sessions/*'`
  (`installed-plugins/`, new top-level files and directories, `logs/`, `docs/`; and, since only
  an append-open of them was measured denied, `config.toml`, which can name a command grok
  runs, `sandbox.toml`, `hooks-paths` and its targets).
- **A per-run profile check** (free): before its slot and before any prompt, every grok run of
  a lane (`cx-run`, `cx-job`) refuses a built-in that writes `~/.grok` by its name, before grok
  starts at all, then runs `grok --sandbox <its profile> models` in its checkout, through the
  preflight's probe
  machinery and worker environment, and reads only the line that call added to grok's sandbox
  log: a `ProfileApplied` event for the checkout with `enforced` false, or with a
  `read_write_paths` entry that grants write to grok's home (`${GROK_HOME:-~/.grok}` itself, a
  directory above it or one inside it, compared as given and resolved, but `~/.grok/sessions`),
  refuses the run with 2 `FAILED`, naming the profile, the path and the log; so does a line
  saying the sandbox was not applied. No log or no event (macOS, another version) changes
  nothing. The facts, the event's platform included, go into `grok.run.json` as
  `sandbox_check`. The preflight's `grok --sandbox strict models` stays. A run that stops
  before its executor now leaves its reason in `$OUT/adapter.why`, and `cx-run` puts it into
  the result's reason (before: only "the grok lane stopped before its executor ran").
- **The skill's Step 3 commit-message call** (SKILL section 4 and DESIGN §12.2, identically):
  `cx-wsl grok … --cwd "$OUT/msg" --sandbox cx-strict` (conductor's `strict` plus the resolver
  directories, below), with the prompt at `$OUT/msg/prompt.txt` in a directory the step empties
  first, which holds nothing the conductor later reads, sources or runs. `cx-wsl`'s grok arm
  now refuses (exit 1, before the slot) a grok run that names a `--sandbox` other than
  `cx-strict` (plain `strict` included), or none (grok's default is no sandbox), or no
  absolute `--cwd` directory, and runs grok from that directory, so grok's working directory
  and `--cwd` are the same (DESIGN §20 item 80). The D25 rule `Bash(cx-wsl grok:*)` and the
  Windows path rules are unchanged.
- **Security: a `.conductor` symlink could redirect the conductor's own writes.** The conductor
  writes the diff, the task and grok's prompt file into `<checkout>/.conductor/` unsandboxed. A
  reviewed branch (or a read's base) that tracked `.conductor` as a symlink, or a symlink below
  it, made `cx-run` write the diff (text the branch shapes) to any file of the user's (a shell
  rc file, for one: reproduced with the stubs), for every review lane; `/.conductor/` in
  `info/exclude` matched directories only, so Step 3's `git add -A` committed a `.conductor`
  symlink an executor left. Now a read or review of a commit that tracks anything at
  `.conductor` exits 2 before its checkout; a writer's worktree whose `.conductor` is a
  symlink, no directory or holds a symlink exits 2 (a re-dispatch); every file there is written
  as a new file; the hash check never follows a link (a `.conductor` or `task.md` symlink is
  23 `SPEC_TAMPERED`); `info/exclude` and `cx-init` write `/.conductor`.
- **Security: nothing the conductor re-reads lives in `/tmp` any more.** Every strict-based grok
  run can write `/tmp` and `/var/tmp`. `cx-wsl bash -s` buffered the step it runs there (lines a
  grok run appended would run unsandboxed), `cx_wt_changes` kept the scratch index behind the
  allowed-paths check there, the probes and the doctor (whose facts become the host record
  `cx-wsl` runs binaries from) kept their outputs there, and the skill's contract
  `/tmp/cx-t1.md` was re-read by a failover after a grok run. Scratch files now live in
  `~/.conductor/tmp` (0700) on the executor host, and the skill writes contracts under
  `~/.conductor/tasks/`. DESIGN §20 item 79 records the limit.
- **The preflight and D17 also check `strict`'s grants**: a strict probe event whose
  `read_write_paths` grants write to grok's home refuses the grok lane and fails D17 (grok's
  README says strict writes `~/.grok`; 1.0.70 measured it does not, and grok is not pinned).
  D17 warns for `grok_sandbox_profile=strict` that worktrees' `git status` and `cx-route` fail
  under it, instead of claiming grok runs fail to start.
- **Docs corrected, measured.** 0.2.1 said that grok's built-in `read-only` "writes all of
  `~/.grok`", `sandbox.toml` and `config.toml` included, so a read or review run could change
  `sandbox.toml` and `config.toml` for later grok runs, and that the tamper-safe rewrite of the
  repository's profile was the guard against that (grok.sh, the cxlib docstrings, the profile
  template, README, DESIGN §1.3, §15.2, §15.7, §20 items 75 and 76, A.5 row L2, SPEC-NOTES
  items 12 and 15, this changelog's 0.2.1 entry). Wrong for those files (an append-open of them
  is write-denied under `read-only`; a rename in the writable `~/.grok` was not tried, and
  grok's docs say it is denied too), and it missed the real exposure above. DESIGN §1.3 now lists each built-in profile's
  measured write set and grok's protected set, §20 item 76 is settled for every
  conductor-launched grok run (what remains: your own grok sessions), new items 77 (whether
  grok reads `--prompt-file` before or under its sandbox) and 78 (grok's daemon backend), and
  revision A.6. The tamper-safe profile rewrite stays: it now guards `sandbox.toml` against what
  is outside conductor's runs (your own grok sessions, which run without a sandbox by default,
  other tools, code planted by an earlier read-only run). The profile template's comment
  changed, so each repository's profile is rewritten once, with a note, on its next grok run.
- **grok could resolve no host name on WSL under conductor's strict-based profiles** (a real-use
  breakage, measured live 2026-11-06 with 0.2.1 on a Windows 11 machine, Git Bash forwarding to
  WSL Ubuntu, grok 1.0.70, Landlock enforced). `strict` reads only its system directories
  (`/usr /lib /lib64 /bin /sbin /etc /dev /proc /sys /tmp /run /var`), the working directory
  and `~/.grok`, and on WSL `/etc/resolv.conf` links to `/mnt/wsl/resolv.conf`: a throwaway
  Landlock child with that read list got EACCES on it and `getaddrinfo` failed (with `/mnt/wsl`
  added it resolved). A grok write run under the repository's profile failed after 1657 s of
  grok's own retries (rc 1, `error sending request for url`, no model call; `dns error: failed
  to lookup address information` in `~/.grok/logs/unified.jsonl`); its retry hit the 180 s
  timeout. Every D17 check had passed: the free probes make no API call. 0.2.2's move of read,
  review and commit-message runs to strict-based profiles would have spread this to every grok
  call on WSL. Now every conductor profile (each repository's `cx-<repo>-<hash>`, written by the
  lane and `cx-init --user-grants`) adds, read-only, the directory that holds each resolver or
  TLS file of a fixed list (`/etc/resolv.conf`, `/etc/hosts`, `/etc/nsswitch.conf`,
  `/etc/host.conf`, `/etc/gai.conf`, the usual CA bundles) whose resolved path lies outside that
  read set: `/mnt/wsl` on WSL, nothing on most hosts. Directories only, and only system
  directories: never `/`, a directory that is or contains your home, `~/.grok`, `~/.conductor`
  or a checkout, one inside your home, `~/.conductor` or the run's checkout, one on a Windows
  drive (`/mnt/<letter>` or the `[automount]` root of `/etc/wsl.conf`), nor one reached through
  a link in `/tmp`, `/var/tmp`, a home or a checkout, where a grok run or your own programs could
  replace the link (a note on every profile write says so, and D17 for everything but the
  checkout, which it does not know). `SSL_CERT_FILE` and `SSL_CERT_DIR` are never granted: every
  caller shares these profiles (a call forwarded from Git Bash starts without them, a WSL
  session inherits yours), so they depend on no caller's environment; D17 warns when its own
  environment names a bundle grok cannot read, and the per-run check notes one. The
  commit-message call and a grok
  lane run outside a git checkout use conductor's new `cx-strict` (strict plus those
  directories only), which `cx-wsl` writes, under the same lock and rewrite rules, and checks
  (`grok --sandbox cx-strict models` and its sandbox-log line: the per-run check) before each
  call. The per-run check also notes each resolver file the logged profile cannot read
  (`sandbox_check.resolver_unreadable` in `grok.run.json`; never a refusal). Files are read
  under `CX_DETECT_ROOT` (a test tree, empty in production), as `detect.sh` reads its own.
  Not yet measured: that grok works end to end on WSL after the fix (DESIGN §20 item 81).
- **D17 checks grok's resolver and TLS files**: it lists them, the directories conductor's
  profiles add and any that cannot be granted (! grok cannot resolve any host name under any
  conductor profile, with the fix), a dangling `/etc/resolv.conf`, `SSL_CERT_FILE` /
  `SSL_CERT_DIR` of its environment that grok cannot read (! never granted), conductor profiles
  in `~/.grok/sandbox.toml` that still lack a directory (written before this release: the
  repository's next grok run, or the next `cx-wsl grok` call for `cx-strict`, rewrites them), and
  `grok_sandbox_profile=strict` or a profile of yours that lacks one. Its info line counts the
  repositories' profiles only (`cx-strict` is not one), and its fix text for `strict` names the
  resolver directories too.
- **A grok run that cannot reach its API says so**: rc not 0, no model call (grok usage's
  `modelCalls` 0, or, when grok usage recorded nothing, no token at all) and `error sending
  request for url` (or another connect or DNS phrase) on the run's own stderr or error object is
  2 `FAILED` with the reason "grok could not reach its API (a connection or DNS failure;
  cx-doctor D17): …", or "could not resolve its API's host name (DNS; …)" when stderr or grok's
  own log, only the bytes appended to `~/.grok/logs/unified.jsonl` during the run (searched as
  text, kept in `grok.netlog.txt`), says DNS; 12 when the timeout ended grok's retries first. A
  note says grok's own retries can hold a run for about 28 minutes (the run's timeout bounds
  it). Every grok process on the computer appends to that log, so a DNS line there alone is a
  note, never the reason. grok usage's JSON (`session.inputTokens`, `cachedReadTokens`,
  `modelCalls`, …) now fills a failed run's usage; the old text patterns never matched it.
- **Fusion lanes never pay for a discarded fallback.** ghcp's option `fusion_fallback` (default
  on) re-runs a task once on plain `auto`, billed, when Copilot refuses Fusion before any model
  call, and conductor discarded that answer: `GHCP_FALLBACK` on a Fusion lane is 21. The copilot
  adapter now sets `CLAUDE_PLUGIN_OPTION_FUSION_FALLBACK=off` for `--fusion` runs only (ghcp's
  options loader lets the environment win over `settings.json`; verified with ghcp 0.1.2 over
  its own test stub), so a refusal ends as ghcp's free exit 14 (`MODEL_UNAVAILABLE`) and the next
  lane follows. Not a spend cap: nothing else changes, your other ghcp calls keep your setting,
  and `COPILOT_CLI_ENABLED_FEATURE_FLAGS` is untouched (ghcp merges the feature flags its
  headless Fusion needs). A `GHCP_FALLBACK` that still appears stays 21.
- **DESIGN §1.2 no longer infers anything from a binary string search**: the 1.0.106-1
  prerelease's missing Fusion feature-flag strings proved nothing, since the 1.0.105 binary, on
  which those flags work, has none either (its app code is compressed). No check searches a
  binary for strings.
- **Docs**: §7.7 and the skill name `cx-wsl`'s refusal of a `.grok/sandbox.toml` in `--cwd`
  (exit 2); SPEC-NOTES 26 says the per-run check refuses only when grok says the profile was not
  applied (an unenforced or home-writing event too), any other start-up error being the call's
  own failure; README no longer says plain `strict` failed or that every doctor check passed on
  that machine (W6 had failed there; every D17 check passed).
- **D17 retries the grok login probe once**, 2 s after a `grok models` that listed no models or
  said "You are not authenticated" (a one-off "not logged in" was seen once and did not recur),
  never after a hang; the line says when it retried.
- **D24 and D25 no longer name a Claude Code version** in their notes ("the Task(...) rule
  syntax is unverified", "how Claude Code matches env -u prefixes and multi-line steps is
  unverified"); D13's measured-with note stays.
- **Git Bash: W6 reported every shipped file as CRLF-corrupted** (a false positive, measured live
  2026-11-06 with 0.2.1 on a Windows 11 machine whose Git Bash is bash 5.3.15
  (x86_64-pc-cygwin) with grep 3.0). There an ANSI-C `$'\r'` written inside a command or process
  substitution expanded to empty, so W6's `grep -l $'\r' FILES` inside `< <( )` matched every
  file; and that grep sees a CR byte only with `-U`. W6, D3, `install-runtime.sh` (its CR strip
  and refusal) and `cx-wsl bash -s` (its CRLF note) now use `grep -U -e "$CX_CR"`, with `CX_CR`
  assigned in `common.sh`, outside any substitution, and no shipped shell file writes an ANSI-C
  string inside `$( )`, `<( )`, `>( )` or backticks (DESIGN §3.1; only `$'\r'` was measured
  broken, the rule covers them all). Git Bash's `sed` was not measured with CRs (the bootstrap's
  strip is followed by `install-runtime.sh`'s own in WSL).
- **Fixtures**: `tests/fixtures/real/grok/write-probe.sh` and its verbatim results
  `write-probe-read-only-1.0.70.txt` and `write-probe-strict-1.0.70.txt` (live, 2026-11-06,
  $0.032164 and $0.021666). The live runs of 0.2.1 on that Windows 11 machine (Git Bash
  forwarding to WSL Ubuntu, 2026-11-06), `tests/fixtures/real/*/sbx-*-ca-*`: copilot write 0
  (15 s, 16.7113 AI credits), copilot read 0 (12 s, 3.9574 AI credits), agy write 0 (47 s), the
  grok write that failed after 1657 s because grok resolved no host name, and the
  grok write stopped at its 180 s timeout (12); 0.2.1's out-directory layout, the Linux user
  name in their home paths replaced by `user`. The older real runs (`sbx-agy-1`,
  `sbx-copilot-1`, `sbx-grok-1`, `sbx-review-1`, `sbx-review-2`) still held that name in their
  home paths: now `/home/user` too (nothing else changed; no e-mail address, Windows user name
  or token was in any fixture). The stub's `grok usage` answer now has the JSON keys grok
  1.0.70 prints (synthetic values, no model call).
- **Tests**: read and review argv name the repository's profile and never `read-only`; a read
  run writes the profile and runs under it after the per-run check; a `.grok/sandbox.toml` in a
  read's or review's checkout refuses (2, no prompt run), also through `cx-run --mode review`
  of a branch that commits one; the per-run check refuses an event granting write to grok's
  home, to a directory inside it or above it, and an unenforced one, accepts
  `~/.grok/sessions` and ignores other workspaces; the built-in `read-only` through the option
  is refused; every file a read or review reads lies in its checkout; the write probes' facts
  are pinned. The grok stub's sandbox probe takes `STUB_GROK_SANDBOX_EVENT=homewrite` and
  `STUB_GROK_EVENT_RW`. From the review: both `.conductor` shapes for read and review (grok,
  gemini), a re-dispatch into a symlinked `.conductor`, the `relink` scenario (23), the prompt
  file through a symlink; the per-run check on its own after a cached preflight (`warn`,
  `refuse`), a custom profile's logged grants, whole path components and resolved links
  (direct `grok-check` calls), the four home-writing built-ins refused before grok starts; the
  preflight's and D17's strict home-write, D17 for `strict` and an undefined name; `cx-wsl
  grok`'s refused forms and its cwd, `cx-wsl bash -s` with a missing `TMPDIR`; the grok stub
  records the review diff it found (`STUB_GROK_SEEN`); static checks for the commit-message
  lines of the SKILL and DESIGN §12.2, the home-writer list in `normalize.py` and D17, and
  scratch files outside `$TMPDIR`. For the resolver work: the repository's profile on a
  simulated WSL tree gains `/mnt/wsl` and loses it again off WSL; `cx-wsl grok` writes `cx-strict`
  (empty `read_only` here, `/mnt/wsl` and an `SSL_CERT_FILE` directory on the WSL tree, `/`
  never), replaces a widened definition, runs the per-run check first and refuses on it; the
  per-run check's note for an event that lacks `/mnt/wsl`; `root_realpath` against
  `os.path.realpath`; D17's resolver records (grants, the stale profile, the option, home and
  `~/.conductor` refusals, a dangling link) and its login retry; grok's connect, DNS and
  timeout reasons, and an earlier run's log line not counted. The grok stub takes
  `STUB_GROK_RUN=connect|dns|dnstimeout`, `STUB_GROK_MODELS_ONCE` and `STUB_GROK_EVENT_RO`, and its
  sandbox-log lines list the profile's `read_only`. For the Git Bash CR checks: a static check
  that no shipped shell file writes an ANSI-C string inside a substitution and that every grep
  for a CR has `-U` (a lexical scanner with a self-test; a file it cannot follow fails the
  check); the simulated Git Bash's grep (P42's mini bin) sees no CR without `-U`, as measured;
  W6 lists exactly the CRLF files of a copy and is ok on the LF plugin, D3 lists exactly the one
  CRLF file. The ChalkAgent runs through the parsers: copilot and agy 0 with their sessions,
  usage and credits, grok 2 with the connection reason, a copy with the day's measured log text
  (through `grok-netlog`) 2 with the DNS reason, grok 12; caller `gitbash` and host `wsl` in
  each; every home path in them `/home/user`. From the follow-up review: the resolver plan on a
  tree whose fixed files link into the home, inside it, onto a Windows drive, through a link in
  `/tmp` and in the home, and inside the conductor's home (D17 and the profile notes name each
  refusal; the one system directory is granted), the same `cx-strict` rendered with and without
  `SSL_CERT_*` in the writer's environment, a directory inside the run's checkout refused, and
  `cx-wsl grok` keeping `cx-strict` unchanged under a caller's `SSL_CERT_*` (the per-run check
  notes them); grok usage's real JSON through the stub (`STUB_GROK_USAGE=calls`) and on copies
  of the live fixtures: a connect or DNS failure after model calls keeps "grok exited 1", and a
  DNS line in grok's log alone is a note; D17's count of repository profiles and its `strict`
  fix text; a Fusion refusal through the adapter is ghcp's 14 with
  `CLAUDE_PLUGIN_OPTION_FUSION_FALLBACK=off` (over the caller's `on`) and the caller's
  `COPILOT_CLI_ENABLED_FEATURE_FLAGS` unchanged, while a non-Fusion run gets no option variable
  (the ghcp stub follows the option as ghcp does, with ghcp 0.1.2's real exit-14 output as a
  new fixture); the home-path check covers every real fixture. Mutation-checked on a scratch
  copy (each mutation below fails at least one check): the resolver directories dropped from
  the repository's profile or from `cx-strict`, a directory inside the home granted, the link
  or drive refusal dropped, the plan reading `SSL_CERT_*` again, the DNS reason broken or firing
  after model calls, D17's login retry removed or its count including `cx-strict`, `$'\r'` back
  inside a substitution, `-U` dropped at each of the four CR checks, one fixture path
  un-sanitized, and the Fusion option left on.

## 0.2.1 — 2026-11-06

Fixes from the first real runs (one small `cx-run` per lane on the user's machine, 2026-11-02),
from live probes of agy 1.5.1, grok 1.0.70 and Copilot CLI 1.0.105 and from live agy and grok
runs in the build container (2026-11-06). No CLI version is pinned any more.

- **No version pins.** `CX_PIN_*` are gone (`CX_VERIFIED_*`: the versions the lanes were last
  verified against, shown by `cx-doctor` as info lines, never a failure). Instead every adapter
  checks a **flag contract** in its free preflight: the CLI's live `--help` (and `copilot help
  permissions`, and the Copilot argv `ghcp-delegate --print-command` builds) must list every flag
  the lane is about to emit; a missing one refuses the lane before it runs with exit 26 (status
  `VERSION_MISMATCH`, reason "flag contract"). The check is cached with the probe (10 minutes,
  keyed by the flags and the binaries' identity, so an update re-probes at once). `cx-doctor`
  no longer tells you to disable auto-update (D14 is one info line); the worker environment still
  turns self-updates off for each run. D16 probes Copilot's login through `ghcp-models` (ghcp's
  free probe) on any version; the raw invalid-model probe runs only on 1.0.105.
- **`cx-route`.** At dispatch `cx-run` snapshots the task's checks, named from `.cx/routes.json`
  (`test`, `lint`, `typecheck`, other keys; `cmd-N` for a task's own command), into
  `$OUT/routes.json` and a generated, self-contained `$CX_HOME/routes/<id>/cx-route` on the
  worker's PATH.
  `cx-route <name>` runs only that snapshot (an edit of the worktree's `routes.json` never reaches
  it), its exit status passes through, an unknown name or any extra argument exits 127. The task
  template, the default prompt and the review prompt tell every executor to run checks only as
  `cx-route <name>`.
- **agy**: each raw run passes `--settings $OUT/agy-settings.json` (session-only): `write_file(<the
  worktree>)` and `command()` for `cx-route`, `git status` and `ls`, never
  `--dangerously-skip-permissions`; its prompt says to read with agy's own file tools
  and that any other command ends the run (one denial ends a headless run). `cx-init
  --user-grants` writes no agy grant any more (a note, and `cx-doctor` D18, name the global grants
  0.2.0 left). The parser reads agy's real stream-json (`{"event": "init"|"step_update"|"result"}`)
  and names a denied command from its `step_update` (`tool_info.parameters.CommandLine`) in
  `result.json` `denied[].command` and `CX_DENIED.commands`; the hint no longer suggests a
  routes edit as the fix for an agy denial.
- **grok**: writers run under their repository's own sandbox profile `cx-<repo>-<hash>` in
  `~/.grok/sandbox.toml` (extends `strict`; `read_only` the repository's git directory and
  `~/.conductor/routes`), written idempotently under a lock by the lane (or `cx-init
  --user-grants`), with `--sandbox <it> --always-approve` instead of `--permission-mode
  acceptEdits` and `--allow` rules (acceptEdits denied the first edit headless);
  `GIT_CONFIG_GLOBAL=/dev/null` in its worker environment. Option `grok_sandbox_profile` now
  defaults to `auto` (the 0.2.0 value `cx-workspace` counts as auto), and the invalid 0.2.0
  `cx-workspace` block (glob deny paths) is removed from `sandbox.toml`. Served-model alias:
  `grok-4.7` served as `grok-4.7-build` is accepted (an explicit suffix table); anything else
  stays 21. `cx-doctor` D17 checks for bubblewrap on Linux and WSL.
- **Copilot**: `--allow-shell cx-route` plus `git status` (Copilot approves a shell call by its
  command name, so `shell(python3 -m unittest …)` never matched and the real run's tests were
  denied); never `shell(python3)` or `shell(:*)`.
- `PYTHONDONTWRITEBYTECODE=1` in every worker environment (Python checks left `__pycache__` in
  the worktree).
- **Security review fixes** (2026-11-06, before release):
  - The conductor's own git never finds the repository from a worktree an executor wrote (a
    worker could repoint `.git` at a git directory whose `core.fsmonitor` ran a command as the
    conductor on `git add -A`): `worktree.sh` takes the worktree's git directory from the main
    repository's admin files and runs git with `--git-dir`/`--work-tree`, no fsmonitor, hooks,
    pager, textconv or submodules (also in agy's tree snapshots, which now hash each worktree's
    `.git` link). A rewritten link ends the run 24 `TAMPERED` (no git runs there) and
    `--reuse-worktree` refuses it; an embedded repository without a commit no longer hides the
    rest of the change (`git add --ignore-errors`, a note).
  - grok's profile `cx-<repo>-<hash>` is conductor's own: a `[profiles.<name>]` outside the
    cx:begin/cx:end lines (a grok run may rewrite `~/.grok/sandbox.toml`: the live runs below
    found that grok's built-in `read-only` profile, used by read and review runs, writes all of
    `~/.grok`, while `strict` keeps it read-only although grok's README says strict writes it;
    corrected in 0.2.2: under `read-only` an append-open of `sandbox.toml`, `config.toml` and
    the rest of grok's protected set is denied, see 0.2.2)
    is replaced instead of being left as "the user's", and a file that still defines it another
    way, or a `.grok/sandbox.toml` in the worktree, refuses the run.
  - `git diff`, `git log` and `git show` left every grant (agy's `--settings`, Copilot's
    `--allow-shell`, the Claude worker's settings) and the contract: their `--output=<path>`
    writes any file and `diff --no-index` reads any file, which no prefix rule can forbid.
  - `cx-route` runs under `#!/bin/bash -p` and passes the check its caller's exported
    variables through `env -i` without `BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`, `CDPATH`,
    `GLOBIGNORE` and exported functions.
  - grok approves every tool inside its sandbox, so its preflight runs `grok --sandbox strict
    models` (free) and refuses the lane (2) when grok says the sandbox was not applied; such a
    line in a run's stderr fails the run (2). `cx-doctor` D17 runs the same probe and reports
    the kernel's Landlock ABI (`cxlib.py landlock`).
  - The run's `cx-route` moved from `$OUT/bin` to `$CX_HOME/routes/<id>/`, and the grok profile
    grants `$CX_HOME/routes` instead of all of `$CX_HOME/out` (other runs' tasks, diffs and
    digests).
- Tests: the parsers on every real run directory (`tests/fixtures/real/*/sbx-*`), A1 against the
  real agy 1.4.12 and 1.5.1, grok 1.0.70, Copilot 1.0.105 and `copilot help permissions` texts,
  the flag contract refusing a stub help without a flag, `cx-route` refusing anything outside the
  snapshot; new fixtures `real/agy/help-1.5.1.txt`, `real/copilot/help-permissions.txt` and
  `real/ghcp/print-command-cx-route.txt` (recaptured without the git diff, log and show rules);
  regressions for each review fix (a repointed `.git` with `core.fsmonitor`, an embedded
  repository, the agy snapshot over both, a stripped or dotted grok profile, a worktree
  `.grok/sandbox.toml`, `cx-route` under `BASH_ENV` and an exported function, grok's sandbox
  refusal in the probe, the run and D17, and its fail-open warning).
- **Verified live** (the build container, 2026-11-06, 0.2.1 before these fixes, b19aacb; a
  scratch repository whose `slugify` raised `NotImplementedError`, three failing tests,
  `commands.test` in `.cx/routes.json`): `cx-doctor` ran for real (25 ok; D17: grok applies its sandbox, Landlock
  ABI 7, bubblewrap present; the host record written). An agy write run (agy 1.5.1, served
  `claude-opus-5-5-high`) ran `ls -R`, `cx-route test` and `git status` under its per-run
  `--settings`, nothing denied, exit 0 in 29 s; a grok write run (`--sandbox
  cx-textutil-78d1f9c2 --always-approve`, served `grok-4.7-build`) ran `cx-route test`, exit 0;
  a grok read through `cx-run --background` and `cx-job wait`/`result` ended 0; the skill's
  Step 3 (commit, then the gate on a clean checkout of that commit) by hand gave GATE_OK on both
  write runs. The Copilot lane could not sign in there (it stays to be run on the user's
  machine). Fixtures `real/agy/sbx-agy-2/`, `real/grok/sbx-grok-2/`, `real/grok/sbx-grok-3/` and
  `real/grok/sandbox-events-1.0.70.jsonl`. Fixes from them:
  - grok with `--json-schema`: the answer is `structuredOutput` (as JSON). grok's `text` joins
    every turn's message with no separator, so the read run's answer was `[ ][{...}]`, not
    valid JSON. A plain digest keeps `text` as it is (documented: turn boundaries cannot be
    recovered from it); a schema run without `structuredOutput` keeps `text` too, with a note.
  - grok's sandbox log: the preflight and `cx-doctor` D17 read the `ProfileApplied` line their
    `grok --sandbox strict models` appends to `~/.grok/sessions/sandbox-events.jsonl` (only
    the bytes added during the probe, for its cwd); `enforced` false refuses the lane (2) and
    fails D17, `enforced` true adds a D17 line with the platform, no log changes nothing (nor
    a host without GNU `stat`, such as macOS).
  - The docs now say what was measured: strict (and the profiles extending it) writes only the
    worktree, `~/.grok/sessions`, `/tmp` and `/var/tmp`, with `~/.grok` read-only (grok's
    README claim is kept, attributed), while the built-in `read-only` of read and review runs
    writes all of `~/.grok` (corrected in 0.2.2: not its protected set, see 0.2.2); the profile
    comment changed, so each repository's profile is
    rewritten once on its next grok run. Known limits (DESIGN §20 items 75, 76): every grok run
    can read and write `~/.grok/sessions`, which holds every grok session's transcript, and
    nothing checks the rest of `~/.grok`.
  - A grok write run writes its repository's profile again once it holds its pool slot, so a
    read or review run that changed `sandbox.toml` while the writer waited is undone first
    (corrected in 0.2.2: no conductor grok run can change `sandbox.toml`, see 0.2.2).
  - `cx-job wait|result|status|kill <task id>` (the `--id`, not the JOB_ID) still exits 1, now
    with a note naming the JOB_ID of the one job that has that task id; a prefix of one JOB_ID
    that is also another job's task id is ambiguous (exit 1) instead of naming the first job.
  - The CX_DENIED hint for a denied grok write names the whole write set (the worktree, `/tmp`,
    `/var/tmp` and `~/.grok/sessions`).

## 0.2.0 — 2026-11-01

Phase 2 (docs/DESIGN.md section 15, build order items 1 to 3): every executor lane runs through
`cx-run` and `cx-job`. Executor runs are billed to the subscriptions as before; the suite still
spends nothing.

- Cross-process pool slots (`scripts/lib/locks.sh`, `flock`): `cap_agy`, `cap_copilot` and
  `cap_grok` hold across every session, Work locally thread and forwarded call on the computer;
  agy launches never overlap. `cx-wsl` takes a slot for its executor calls (free forms take
  none); a pool that stays full for `CX_SLOT_WAIT_SECS` (600 s) exits 28 `NO_CAPACITY`. They
  replace the Phase 1 agy lock (still honoured, shared, while an older skill copy runs).
- Adapters `scripts/adapters/{copilot,grok,agy,claude,copilot-cloud}.sh` (probe, argv, run,
  parse; the shared `scripts/lib/adapter.sh`): free preflight (pins 26, login 11, catalog 14,
  agy paused 28; green probes cached 10 minutes), the worker environment (shims first,
  `CX_WORKER=1`, API keys and `CLAUDE_PLUGIN_OPTION_*` unset, auto-update pins), executors under
  `setsid timeout`, agy raw mode (registration, launch lock until the init event, init-model
  check 21, SIGKILL 5 s after the result, tree snapshots 22 with `state/agy-paused`), Copilot
  through ghcp (`GHCP_FALLBACK` on Fusion 21, #5149), grok's `permission required:` 15, the
  claude dispatch and `--headless`, the Copilot cloud agent through `ghcp-cloud`.
- `normalize.py` (classification, `result.json`, `CX_RESULT`, `CX_DENIED`, `CX_NOTE`, the
  `VERIFY THIS:` line) and `ledger.py` (append-only, flock and fsync; `claude_session`,
  `claude_effort`).
- `cx-run`: one task on one lane (`--exec auto|agy|copilot|grok|claude|copilot-cloud`, `--mode
  write|read|review`, `--family gemini|gpt`, `--dry-run`, `--explain`, `--background`,
  `--finish`): the task contract (line-1 JSON, or free text in `templates/task.md`) and its
  hash (23), a worktree on `cx/<id>` under `worktree_root`, the repo's setup (25), the pool
  slot, the post-checks (no diff 3, diffstat), `vars.sh` for the skill's commit and gate step;
  `--exec auto` follows `opus_lane_order`, waits for a slot, then takes the claude lane; a cwd
  under `.claude/worktrees/` needs `--repo`; `--finish` of the cloud lane gates the pull
  request head (20 `GATE_FAILED`). Forwarded from Git Bash, `host_path` fields are Windows
  paths.
- `cx-job`: `start`, `status` (with `queued`), `wait`, `result`, `kill` (rc 130 first, TERM to
  the runner's group and session and to every recorded executor session, KILL after 10 s,
  pid-reuse guards), `list`, `unpause agy`. Jobs run from the runtime copy in their own
  session and outlive the Git Bash forwarder.
- `cx-init --user-grants`: agy's `write_file(<worktree_root>)` and `command(<cmd>)` grants, the
  grok `cx-workspace` sandbox profile (`templates/grok-sandbox.toml`) and grok's
  `[cli] auto_update = false`, merged idempotently with `.cx-bak` backups.
- The skill's recipe, both policies and the Projects instructions route through `cx-run` and
  `cx-job`; the hand steps left are the conductor commit and gate (until `cx-gate`), GitHub and
  commit-message drafting, and their two executor calls run as `cx-wsl grok` and `cx-wsl
  ghcp-ci-debug` (in WSL as from Windows), so they take the pool slots too. The policy names
  the Opus order `agy (raw), then Copilot, then own subagents`; the Windows policy keeps `cx-wsl`
  to `gh`, `git`, `ghcp-cloud list`/`view`, `ghcp-ci-debug` and the hand steps.
- `cx-doctor` D25 is narrow: one rule per command form the skill runs (`Bash(cx-run:*)`,
  `Bash(cx-job:*)`, `Bash(cx-wsl grok:*)`, `Bash(cx-wsl ghcp-ci-debug:*)`, `Bash(ghcp-cloud
  list:*)`, `Bash(ghcp-cloud view:*)`, the `vars.sh` line, `git -C "$WT" push`, `gh pr`; on
  Windows the `cx-wsl` forms it runs directly), no raw `agy`, `agy-delegate`, `ghcp-delegate` or
  job rule, never `Bash(cx-wsl:*)`; the suite checks the rules against the skill both ways. New
  D29 (free): copilot, grok and agy start with the worker shims first on PATH. D32 prints the
  slot caps next to the workflow concurrency.
- Hardening of the run machinery (final review): a signal while the executor is being started
  still kills and records its session; the Copilot token reaches ghcp-delegate through the
  environment only, never a command line; only the adapter holds the pool slot and the agy
  locks (the executor gets no descriptor of them) and the executor's session is killed after
  every run, so a daemon it leaves behind never keeps a slot; a TERM-ignoring executor is killed
  10 s after a cancellation (`CX_KILL_GRACE_SECS`), every process group of its session too; the
  preflight cache is per caller side (a WSL terminal and a forwarded call never share a login
  verdict); agy's pause is checked again after the slot and launch-lock waits (also in `cx-wsl`);
  agy's tree check also covers HEAD, branches and tags no worktree has checked out, the stash,
  git config (without `branch.*`), `info/exclude`, the hooks and ignored files, so a commit or a
  planted hook outside the worktree is a `wrong_tree`; stale running marks (a failed task's, a
  killed `cx-run`'s) no longer hide a tree from it.
- `cx-run`: `--` ends the options (a task text may start with `-`), and `--background` and
  `cx-job start` always store the text after `--`; a taken id, a `cx/<id>` branch, a running
  task (`$OUT/.run.lock`, one `cx-run` per task) and, forwarded, an unmappable path (42) are
  refused by the `--dry-run` preflight before a job starts; a gate checkout is removed on every
  exit; the running mark stays only for an ok change waiting for Step 3; `--finish` refuses a
  finished task, books a run and its finish once each in the ledger, and fetches a cloud pull
  request from the task's repository (never a fork's `origin`) and gates it only when GitHub
  names that commit as its head. `cx-job result`/`wait` exit with the job's rc and a last
  `CX_SIGNAL` that names it (rc 1: the job's notes, no signal; a wall-clock kill: 12).
- The runtime copy: an unchanged reinstall refreshes the stamp (no re-copy on every call after
  an mtime-only change), and changed content is never swapped into `runtime/<version>` while a
  `cx-run` or a job still uses it (the update waits for the next call after they end). `cx-wsl
  grok -v` is a free form. Worktree creation's error file comes from `mktemp`.
- 19 more worker shims (the sibling wrappers and the `cx-*` bins) and `templates/cx-worker.json`.
- A task worktree is marked running from its creation (setup included), so a sibling task's
  own work never gives a concurrent agy run a false `wrong_tree`; a cancelled run reports
  `cancelled` even when several signals reach it (a late TERM no longer ends the adapter
  before its `rc` is written); the raw agy lane reads agy's init event in one read, so a run is
  never killed as a false model mismatch.
- Tests: the Phase 2 cases A1–A18, A25–A28 and A30 of DESIGN section 15.8, including twelve
  concurrent `cx-run --background` (direct and forwarded) against the shared caps, plus a
  regression check for each fix above; the forwarded `cx-run`/`cx-job` sections check their own
  python3 trap (P42).
- Not built (optional item 4 of the build order, because ultracode is normally off): the
  `conductor:cx-runner` agent, its fail-closed `hooks/gate.sh`, the `workflows/opus-pools.js`
  workflow and doctor check D33 (A19–A24, A29). Phase 3 (`cx-gate`, the conductor commit,
  `cx-fanout`, the integration queue), Phase 4 (`--mode ci`, review findings parsing) and the
  v1.1 Docker lanes are not built either.
- Still to capture: `agy --help` (the raw agy flags `--add-dir`, `--print-timeout`,
  `--output-format stream-json`, `--disable-slash-commands` and `--new-project` are docs-only;
  A1 checks them against the synthetic `tests/fixtures/agy-help.synthetic.txt`), agy's
  stream-json and `/usage` shapes, and grok's JSON result fields (DESIGN section 20).

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
