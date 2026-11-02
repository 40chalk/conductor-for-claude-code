#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2030,SC2031,SC2034,SC2329  # check arguments are single-quoted eval strings that read variables and call helpers; background sections count in subshells
#
# tests/run-tests.sh - hermetic test suite for the conductor plugin (docs/DESIGN.md section 14).
#
#   bash tests/run-tests.sh
#   bash tests/run-tests.sh 2>&1 | grep -v '^PASS  '     # failures with detail, skips, totals
#   CX_TEST_KEEP=1 bash tests/run-tests.sh                # keep the scratch directory for debugging
#   CX_TEST_STRICT_TIME=1 bash tests/run-tests.sh         # also fail when the run takes 60 s or more
#
# Every agent CLI (copilot, grok, agy, claude, gh), the sibling wrappers, uname, cygpath, wsl.exe
# and wslpath are replaced by the stubs in tests/stubs/, which log their argv; no case calls a
# model, needs the network or spends credits ([P30] audits the stub log at the end). Git Bash
# and WSL are simulated: STUB_UNAME_S, a fake Windows root for cygpath and a wsl.exe stub that
# runs the WSL side locally under env -i. Case tags [P1]..[P63] follow DESIGN.md section 14.3,
# [A1]..[A30] the Phase 2 cases of section 15.8 (all but A19-A24 and A29, the optional item 4
# that is not built); [X] checks are extra coverage. Most sections run in the background (each
# prints its end time as an INFO line). The exit status is non-zero on any FAIL.
#
set -uo pipefail
unset CDPATH

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
STUBS="$HERE/stubs"
FIX="$HERE/fixtures"
DOCTOR="$ROOT/bin/cx-doctor"
INIT="$ROOT/bin/cx-init"
CXWSL="$ROOT/bin/cx-wsl"
POLICY="$ROOT/hooks/policy.sh"
PATHMAP="$ROOT/scripts/host/pathmap.sh"
DETECT="$ROOT/scripts/host/detect.sh"
CXLIB="$ROOT/scripts/lib/cxlib.py"
T_START=$SECONDS
CXV="$(bash -c '. "$1/scripts/lib/common.sh"; printf %s "$CX_VERSION"' _ "$ROOT")"
export CXV

PASS=0; FAIL=0; SKIP=0
pass() { PASS=$((PASS + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL  %s\n' "$1"; [ -z "${2:-}" ] || printf '        %s\n' "$2"; }
skip() { SKIP=$((SKIP + 1)); printf 'SKIP  %s (%s)\n' "$1" "$2"; }
# check "<name>" <command...>: PASS when the command succeeds; on FAIL the last captured
# stdout/stderr are shown (a few lines each).
check() {
  local name="$1"; shift
  if "$@"; then pass "$name"; else fail "$name" "failed: $*"; show_last; fi
}
not() { ! "$@"; }
section() { printf '\n== %s (%ss)\n' "$*" "$((SECONDS - T_START))"; }

# ------------------------------------------------------------------ isolation (section 14.1)
REAL_PATH="$PATH"
KEEP_TMP="${CX_TEST_KEEP:-}"
STRICT_TIME="${CX_TEST_STRICT_TIME:-}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/cx-tests.XXXXXX")" || { echo "mktemp failed" >&2; exit 1; }
BG_PIDS=()
cleanup() {
  local p
  for p in ${BG_PIDS[@]+"${BG_PIDS[@]}"}; do kill -KILL -- "-$p" 2>/dev/null; kill -KILL "$p" 2>/dev/null; done
  if [ "$KEEP_TMP" = 1 ]; then printf 'kept %s\n' "$TMP" >&2; return 0; fi
  chmod -R u+w "$TMP" 2>/dev/null
  rm -rf -- "${TMP:?}"
}
trap cleanup EXIT

# The session-kind, attended, Work locally and workflow signals (DESIGN sections 7.1, 8.3, 14.1)
# are unset by name: the suite may itself run inside a Claude Code cloud session
# (CLAUDE_CODE_REMOTE=true), where every policy case would flip to the cloud notice. [P62] checks
# that each of them is gone.
ISO_VARS=(CLAUDE_CODE_REMOTE CLAUDE_CODE_ENVIRONMENT_KIND CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE CLAUDE_CODE_ENTRYPOINT
  CLAUDE_CODE_PROJECTS_SESSION CLAUDE_CODE_DESKTOP_APP_VERSION CLAUDE_CODE_HOSTED_DESKTOP CLAUDE_CODE_IS_COWORK
  CLAUDE_CODE_USE_COWORK_PLUGINS CLAUDE_PROJECT_UUID CLAUDE_PROJECT_DIR DISABLE_GROWTHBOOK
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC ANTHROPIC_BASE_URL CLAUDE_CODE_SESSION_ATTENDED CLAUDE_CODE_SESSION_KIND
  CLAUDE_CODE_DISABLE_WORKFLOWS CLAUDE_CODE_WORKFLOWS CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL
  CLAUDE_CODE_SUBAGENT_MODEL_FORCE CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_EFFORT
  CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS CLAUDE_CODE_REMOTE_TOOLS_FORWARD CLAUDE_EFFORT AI_AGENT
  CLAUDE_CODE_SESSION_ID CLAUDE_CODE_REMOTE_SESSION_ID CLAUDE_CODE_CONTAINER_ID CLAUDE_CODE_CHILD_SESSION
  NUMBER_OF_PROCESSORS ProgramFiles PROGRAMFILES CLAUDECODE)
unset "${ISO_VARS[@]}"
# The default host is plain Linux, also when the suite runs on a WSL machine: cases that need WSL
# or Git Bash set STUB_UNAME_S/_R themselves, and a real WSL kernel would turn every cloud case
# local (a Git Bash or WSL host is never a cloud session, DESIGN section 7.1). Set after the
# STUB_* unset below.
CX_TEST_UNAME_R=""
case "$(uname -r 2>/dev/null)" in *[Mm]icrosoft*) CX_TEST_UNAME_R=6.1.0-cx-test ;; esac
for v in $(compgen -e); do
  case "$v" in
    CLAUDE_PLUGIN_OPTION_*|STUB_*|CX_*|GHCP_*|COPILOT_*|GROK_*|AGY_*|WSL_DISTRO_NAME|WSL_INTEROP|WSLENV|MSYSTEM|container|\
    CLAUDE_PLUGIN_ROOT|GH_TOKEN|GITHUB_TOKEN|XAI_API_KEY|GEMINI_API_KEY|GOOGLE_API_KEY|ANTHROPIC_API_KEY|COMPOSE_PROJECT_NAME|\
    GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_CONFIG_GLOBAL|USERPROFILE|NO_COLOR|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR|\
    CLAUDE_CODE_*)
      unset "$v" ;;
  esac
done
export HOME="$TMP/home"
export CLAUDE_CONFIG_DIR="$TMP/claude-config"
export XDG_CACHE_HOME="$TMP/cache" XDG_DATA_HOME="$TMP/data" XDG_CONFIG_HOME="$TMP/xdg-config"
export TMPDIR="$TMP/tmp"
export CX_HOME="$HOME/.conductor"
export CX_DETECT_ROOT="$TMP/root"
export GHCP_COPILOT_BIN="$STUBS/copilot"
export STUB_LOG="$TMP/stub.log"
[ -z "$CX_TEST_UNAME_R" ] || export STUB_UNAME_R="$CX_TEST_UNAME_R"
export PATH="$STUBS:$REAL_PATH"
export GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=cx-test GIT_AUTHOR_EMAIL=cx-test@example.invalid \
       GIT_COMMITTER_NAME=cx-test GIT_COMMITTER_EMAIL=cx-test@example.invalid
mkdir -p "$HOME" "$CLAUDE_CONFIG_DIR/plugins" "$XDG_CACHE_HOME" "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" \
         "$TMPDIR" "$CX_DETECT_ROOT" "$TMP/work"
: > "$STUB_LOG"
cd "$TMP/work" || exit 1
REAL_GIT="$(PATH="$REAL_PATH" command -v git)"
REAL_PY="$(PATH="$REAL_PATH" command -v python3)"
PY_DIR="$(dirname -- "$REAL_PY")"

# The fake sibling install dirs: two-line scripts that exec the ghcp-models stub or the
# billable stub (section 14.1).
mk_plugin_dir() {  # DIR NAME...
  local d="$1" n
  shift
  mkdir -p "$d/bin"
  for n in "$@"; do
    if [ "$n" = ghcp-models ]; then
      printf '#!/usr/bin/env bash\nexec %q "$@"\n' "$STUBS/ghcp-models" > "$d/bin/$n"
    else
      printf '#!/usr/bin/env bash\nexec %q %q "$@"\n' "$STUBS/billable" "$n" > "$d/bin/$n"
    fi
    chmod 0755 "$d/bin/$n"
  done
}
GHCP_W=(ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models ghcp-cloud)
AGY_W=(agy-delegate agy-handoff agy-job agy-media)
mk_plugin_dir "$TMP/plugins/ghcp" "${GHCP_W[@]}"
mk_plugin_dir "$TMP/plugins/antigravity" "${AGY_W[@]}"
mkdir -p "$TMP/plugins/grok-build"

# write_installed CFGDIR [conductor_path] [extra JSON entries...]: installed_plugins.json with a
# project-scoped ghcp entry listed first (the user-scoped one must win) and the antigravity entry.
write_installed() {
  local cfg="$1" cpath="${2:-}" extra="${3:-}"
  mkdir -p "$cfg/plugins"
  {
    printf '{"version": 2, "plugins": {\n'
    printf ' "ghcp@ghcp-for-claude-code": [{"scope": "project", "projectPath": "/elsewhere", "installPath": "%s/nonexistent", "version": "0.0.9"},\n' "$TMP"
    printf '   {"scope": "user", "installPath": "%s/plugins/ghcp", "version": "0.1.0", "installedAt": "2026-11-01T00:00:00Z", "lastUpdated": "2026-11-01T00:00:00Z"}],\n' "$TMP"
    printf ' "antigravity@antigravity-for-claude-code": [{"scope": "user", "installPath": "%s/plugins/antigravity", "version": "0.30.2"}]' "$TMP"
    [ -n "$cpath" ] && printf ',\n "conductor@conductor-for-claude-code": [{"scope": "user", "installPath": "%s", "version": "%s"}]' "$cpath" "$CXV"
    [ -n "$extra" ] && printf ',\n %s' "$extra"
    printf '\n}}\n'
  } > "$cfg/plugins/installed_plugins.json"
}
# Green executor-host state: settings, installed plugins, grok and agy config, pins.
green_host() {
  write_installed "$CLAUDE_CONFIG_DIR"
  cp "$FIX/settings/green.json" "$CLAUDE_CONFIG_DIR/settings.json"
  mkdir -p "$HOME/.grok" "$HOME/.gemini/antigravity-cli"
  printf '[cli]\nauto_update = false\n' > "$HOME/.grok/config.toml"
  printf '[profiles.cx-workspace]\nextends = "workspace"\n' > "$HOME/.grok/sandbox.toml"
  printf '{"permissions": {"allow": ["write_file(%s/.cx-wt)", "command(npm test)"]}}\n' "$HOME" \
    > "$HOME/.gemini/antigravity-cli/settings.json"
}
green_host
export COPILOT_AUTO_UPDATE=false GROK_DISABLE_AUTOUPDATER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true STUB_GROK_AUTH=1

# Small python helper (stdlib only, isolated mode) for JSON assertions.
TPY="$TMP/t.py"
cat > "$TPY" <<'PY'
import json, os, re, sys


def load(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)


def dig(v, path):
    for k in [p for p in path.split(".") if p]:
        v = v[int(k)] if isinstance(v, list) else v[k]
    return v


def out(v):
    print(v if isinstance(v, str) else json.dumps(v, ensure_ascii=False))


def lines_with(path, prefix):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return [ln.rstrip("\n") for ln in fh.read().split("\n") if ln.startswith(prefix + " ")]


def main():
    cmd, a = sys.argv[1], sys.argv[2:]
    if cmd == "get":                # get FILE KEY.PATH
        out(dig(load(a[0]), a[1]))
    elif cmd == "line":             # line FILE PREFIX KEY.PATH: the last "PREFIX {json}" line
        ls = lines_with(a[0], a[1])
        if not ls:
            raise SystemExit(3)
        out(dig(json.loads(ls[-1][len(a[1]) + 1:]), a[2] if len(a) > 2 else ""))
    elif cmd == "count":            # count FILE PREFIX
        out(str(len(lines_with(a[0], a[1]))))
    elif cmd == "isjson":
        try:
            load(a[0])
        except Exception:
            raise SystemExit(1)
    elif cmd == "linejson":         # every "PREFIX {json}" line parses, uses default separators, ASCII
        ok = True
        for ln in lines_with(a[0], a[1]):
            body = ln[len(a[1]) + 1:]
            obj = json.loads(body)
            if json.dumps(obj, ensure_ascii=True) != body:
                ok = False
        raise SystemExit(0 if ok else 1)
    elif cmd == "checks":           # checks FILE ID STATUS [TEXT-SUBSTRING]: a doctor --json check exists
        doc = load(a[0])
        for c in doc["checks"]:
            if c["id"] == a[1] and c["status"] == a[2] and (len(a) < 4 or a[3] in c["text"] or a[3] in (c.get("fix") or "")):
                raise SystemExit(0)
        raise SystemExit(1)
    elif cmd == "nul":              # nul FILE: prints each NUL-terminated record with %r
        with open(a[0], "rb") as fh:
            data = fh.read()
        for rec in data.split(b"\0")[:-1]:
            print(repr(rec.decode("utf-8", "surrogateescape")))
    elif cmd == "envnames":         # envnames FILE: the variable names in a NUL-separated env file
        with open(a[0], "rb") as fh:
            data = fh.read()
        print(" ".join(sorted(r.split(b"=", 1)[0].decode() for r in data.split(b"\0") if r)))
    elif cmd == "schema":           # schema RESULT_JSON [ERR_FILE [LEDGER]]: prints each problem (DESIGN 15.4)
        res = load(a[0])
        bad = []
        need = ("version ts id batch lane host caller executor cli_version pool mode model_requested model_served "
                "effort_requested effort_applied exit status finished_reason session usage cost denied worktree branch "
                "base commit diffstat gate digest duration_s raw notes reason models_seen claude_session claude_effort").split()
        bad += ["missing " + k for k in need if k not in res]
        def typ(k, ok):
            if k in res and not ok(res[k]):
                bad.append("bad %s: %r" % (k, res[k]))
        isint = lambda v: isinstance(v, int) and not isinstance(v, bool)
        opt = lambda f: (lambda v: v is None or f(v))
        typ("version", lambda v: v == 1)
        typ("ts", lambda v: isinstance(v, str) and re.fullmatch(r"\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ", v))
        typ("exit", isint)
        typ("duration_s", opt(isint))
        typ("status", lambda v: isinstance(v, str) and v)
        typ("pool", lambda v: v in ("google-claude-bucket", "google-gemini", "copilot-credits", "xai-weekly", "claude-plan"))
        typ("mode", lambda v: v in ("write", "read", "review"))
        typ("usage", lambda v: isinstance(v, dict) and set(v) >= {"input", "output", "cache_read", "cache_write", "reasoning"}
            and all(x is None or isint(x) for x in v.values()))
        typ("cost", lambda v: isinstance(v, dict) and set(v) >= {"ai_credits", "usd_est", "quota_delta", "estimated"}
            and isinstance(v["estimated"], bool))
        typ("denied", lambda v: isinstance(v, list) and all(isinstance(d, dict) and d.get("kind") in
            ("write", "shell", "url", "mcp", "other") and "detail" in d for d in v))
        for k in ("worktree", "digest"):
            typ(k, lambda v: isinstance(v, dict) and set(v) >= {"path", "host_path"})
        typ("raw", lambda v: isinstance(v, dict) and set(v) >= {"stdout", "stderr"})
        typ("notes", lambda v: isinstance(v, list))
        typ("models_seen", lambda v: isinstance(v, list))
        if len(a) > 1 and a[1]:
            ls = lines_with(a[1], "CX_RESULT")
            if not ls:
                bad.append("no CX_RESULT line")
            else:
                cx = json.loads(ls[-1][len("CX_RESULT "):])
                want = {k: v for k, v in res.items() if k not in ("raw", "notes", "models_seen")}
                got = {k: v for k, v in cx.items() if k not in ("path", "host_path")}
                if got != want:
                    bad.append("CX_RESULT differs from result.json in " + ",".join(sorted(k for k in set(got) | set(want) if got.get(k) != want.get(k))))
                if cx.get("path") != os.path.abspath(a[0]):
                    bad.append("CX_RESULT path %r" % cx.get("path"))
                if "host_path" not in cx:
                    bad.append("CX_RESULT has no host_path")
        if len(a) > 2 and a[2]:
            mine = [json.loads(ln) for ln in open(a[2], encoding="utf-8").read().split("\n") if ln.strip()]
            mine = [ln for ln in mine if ln.get("id") == res.get("id")]
            if not mine:
                bad.append("no ledger line for " + str(res.get("id")))
            elif mine[-1] != {k: v for k, v in res.items() if k not in ("raw", "notes")}:
                bad.append("the ledger line differs from result.json without raw and notes")
        print("; ".join(bad))
    else:
        raise SystemExit("unknown helper command " + cmd)


main()
PY
tj() { "$REAL_PY" -I "$TPY" "$@"; }

# ------------------------------------------------------------------ run helpers
SEC_TAG=""
O="$TMP/out" E="$TMP/err" RC=0
show_last() {
  [ -f "$O" ] && [ -s "$O" ] && { printf '        stdout: '; head -c 600 "$O" | head -n 6 | sed '2,$s/^/                /'; printf '\n'; }
  [ -f "$E" ] && [ -s "$E" ] && { printf '        stderr: '; tail -n 6 "$E" | cut -c1-300 | sed '2,$s/^/                /'; printf '\n'; }
  printf '        rc: %s\n' "$RC"
}
# run CMD...: stdin from /dev/null; stdout/stderr in $O/$E, rc in RC.
run() { O="$TMP/out$SEC_TAG" E="$TMP/err$SEC_TAG"; "$@" > "$O" 2> "$E" < /dev/null; RC=$?; }
# runin TEXT CMD...: like run with TEXT on stdin.
runin() { local t="$1"; shift; O="$TMP/out$SEC_TAG" E="$TMP/err$SEC_TAG"; printf '%s' "$t" | "$@" > "$O" 2> "$E"; RC=$?; }
rc_is() { [ "$RC" = "$1" ]; }
out_has() { grep -Fq -- "$1" "$O"; }
err_has() { grep -Fq -- "$1" "$E"; }
out_lacks() { ! grep -Fq -- "$1" "$O"; }
err_lacks() { ! grep -Fq -- "$1" "$E"; }
out_empty() { [ ! -s "$O" ]; }
err_empty() { [ ! -s "$E" ]; }
sig_is() { [ "$(tj line "$E" CX_SIGNAL status 2>/dev/null)" = "$1" ]; }
n_signal() { [ "$(grep -c '^CX_SIGNAL ' "$E")" = "$1" ]; }
no_signal() { n_signal 0; }
# one_signal STATUS: exactly one CX_SIGNAL line, with STATUS, and it is the last stderr line.
one_signal() { n_signal 1 && sig_is "$1" && tail -n 1 "$E" | grep -q '^CX_SIGNAL '; }
out_json() { tj get "$O" "$1" 2>/dev/null; }
outj_is() { [ "$(out_json "$1")" = "$2" ]; }
line_is() { [ "$(tj line "$E" "$1" "$2" 2>/dev/null)" = "$3" ]; }
# line-oriented doctor helpers (text mode): a check line "  <glyph> ... [ID]" containing TEXT.
OKG=$'\xe2\x9c\x93' FAILG=$'\xe2\x9c\x97'
dline() {  # GLYPH ID [TEXT]
  local g="$1" id="$2" t="${3:-}" line
  while IFS= read -r line; do
    case "$line" in
      "  $g "*"[$id]") [ -z "$t" ] || [[ $line == *"$t"* ]] && return 0 ;;
    esac
  done < "$O"
  return 1
}
d_ok() { dline "$OKG" "$@"; }
d_warn() { dline '!' "$@"; }
d_fail() { dline "$FAILG" "$@"; }
d_info() { grep -Fq -- "${2:-}" <(grep -E "^      .*\\[$1\\]\$" "$O"); }
d_none() { ! grep -Eq "\\[$1\\]\$" "$O"; }
no_fail_glyph() { ! grep -q "^  $FAILG " "$O"; }
stublog_mark() { STUB_MARK="$(wc -l < "$STUB_LOG")"; }
stublog_new() { tail -n +"$((STUB_MARK + 1))" "$STUB_LOG"; }
STUB_MARK=0
# Background sections: bg_section NAME FUNC runs FUNC in a subshell with its own $O/$E files and
# counters, its output in a file; join_section NAME prints that output and adds the counts.
declare -A SEC_PID=()
bg_section() {
  local name="$1" fn="$2"
  ( __bg_counts="$TMP/sec-$name.counts" __bg_name="$name" PASS=0 FAIL=0 SKIP=0 SEC_TAG=".$name"
    "$fn"
    printf 'INFO  background section %s ended at %s s\n' "$__bg_name" "$((SECONDS - T_START))"
    printf '%s %s %s\n' "$PASS" "$FAIL" "$SKIP" > "$__bg_counts" ) > "$TMP/sec-$name.out" 2>&1 < /dev/null &
  SEC_PID[$name]=$!
}
join_section() {
  local name="$1" p=0 f=1 s=0
  # A reused pid (pid_max is often 32768 and the suite starts many processes) can make bash drop
  # an exited section's saved status: the counts file below is the real check.
  wait "${SEC_PID[$name]}" 2>/dev/null
  cat "$TMP/sec-$name.out"
  if [ -s "$TMP/sec-$name.counts" ]; then read -r p f s < "$TMP/sec-$name.counts"; else printf 'FAIL  section %s did not finish\n' "$name"; fi
  PASS=$((PASS + p)); FAIL=$((FAIL + f)); SKIP=$((SKIP + s))
}
# A job pool for the doctor and Git Bash runs: pool_go waits while POOL_MAX of DOC_PIDS run.
POOL_MAX=4
DOC_PIDS=()
pool_go() {
  local p n
  while :; do
    n=0
    for p in ${DOC_PIDS[@]+"${DOC_PIDS[@]}"}; do kill -0 "$p" 2>/dev/null && n=$((n + 1)); done
    [ "$n" -lt "$POOL_MAX" ] && return 0
    sleep 0.05
  done
}
doc_wait() { local p; for p in ${DOC_PIDS[@]+"${DOC_PIDS[@]}"}; do wait "$p" 2>/dev/null; done; DOC_PIDS=(); }  # a reused pid may appear twice
# Doctor runs: doc_bg NAME [VAR=VALUE | -u VAR]... -- [ARGS...] starts one (pooled) with its own
# CX_HOME and stub log, in ${DOC_CWD:-$TMP/work}; doc_use NAME points $O/$E/$RC (and $DLOG, $DHOME) at it.
DOCS="$TMP/doc"
mkdir -p "$DOCS"
doc_bg() {
  local name="$1" d
  shift
  local -a envs=() unsets=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    if [ "$1" = -u ]; then unsets+=(-u "$2"); shift 2; else envs+=("$1"); shift; fi
  done
  [ "${1-}" = -- ] && shift
  d="$DOCS/$name"
  mkdir -p "$d/cxhome"
  pool_go
  ( cd "${DOC_CWD:-$TMP/work}" && env ${unsets[@]+"${unsets[@]}"} CX_HOME="$d/cxhome" STUB_LOG="$d/stub.log" ${envs[@]+"${envs[@]}"} "$DOCTOR" "$@" \
      > "$d/out" 2> "$d/err" < /dev/null; printf '%s\n' "$?" > "$d/rc" ) &
  DOC_PIDS+=("$!")
}
doc_use() { O="$DOCS/$1/out"; E="$DOCS/$1/err"; RC="$(cat "$DOCS/$1/rc" 2>/dev/null)"; DLOG="$DOCS/$1/stub.log"; DHOME="$DOCS/$1/cxhome"; }
dlog_has() { grep -E -- "$1" "$DLOG" >/dev/null 2>&1; }
# Git repositories for cx-init and the forwarding cases.
REPOS="$TMP/repos"
mkrepo() {  # NAME: a fresh git repository with a .gitattributes and a .gitignore (node_modules, target)
  local d="$REPOS/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  printf '* text=auto eol=lf\n' > "$d/.gitattributes"
  printf 'node_modules/\ntarget/\n.venv/\n' > "$d/.gitignore"
  printf '%s' "$d"
}
commit_all() { git -C "$1" add -A && git -C "$1" commit -qm init; }

# The static and cx-init sections need nothing set up below this line: they start at once, using
# the cores the serial sections below leave idle.
sec_static() {
# ------------------------------------------------------------------ 8. static checks (section 3)
section "static checks: syntax, shellcheck, line endings, conventions, shipped files"
mapfile -t SH_FILES < <(cd "$ROOT" && find . -path ./.git -prune -o -type f -name '*.sh' -print | sed 's|^\./||' | LC_ALL=C sort)
mapfile -t BASH_FILES < <(cd "$ROOT" && { printf '%s\n' "${SH_FILES[@]}"; ls bin/* worker-shims/* 2>/dev/null; for f in tests/stubs/* tests/stubs/gitbash/*; do [ -f "$f" ] && printf '%s\n' "$f"; done; } | LC_ALL=C sort -u)
SYN_BAD=""
for f in "${BASH_FILES[@]}"; do bash -n "$ROOT/$f" 2>/dev/null || SYN_BAD="$SYN_BAD $f"; done
check "[P38] every shell file passes bash -n (${#BASH_FILES[@]} files)${SYN_BAD:+:$SYN_BAD}" test -z "$SYN_BAD"
if command -v shellcheck >/dev/null 2>&1; then
  # Three shellcheck processes over interleaved thirds of the files (one serial run costs about a
  # minute of CPU, mostly the larger scripts and this suite): the same findings, sooner.
  SC_PIDS=()
  for i in 0 1 2; do
    ( cd "$ROOT" && n=0 && for f in "${SH_FILES[@]}"; do [ $((n++ % 3)) = "$i" ] && printf '%s\0' "$f"; done | xargs -0r shellcheck -x > "$TMP/sc.$i" 2>&1 ) &
    SC_PIDS+=("$!")
  done
  wait "${SC_PIDS[@]}"
  SC_OUT="$(cat "$TMP/sc.0" "$TMP/sc.1" "$TMP/sc.2")"
  check "[P38] shellcheck -x is clean on every *.sh${SC_OUT:+: $(printf '%s' "$SC_OUT" | grep -m3 -E '^In |SC[0-9]+' | tr '\n' ' ')}" test -z "$SC_OUT"
  mapfile -t STUB_FILES < <(cd "$ROOT" && find tests/stubs -type f | LC_ALL=C sort)
  SC_OUT="$(cd "$ROOT" && { shellcheck -x -e SC1007 bin/*; shellcheck -x worker-shims/*; shellcheck -x -s bash "${STUB_FILES[@]}"; } 2>&1)"
  check "[X]   shellcheck is clean on bin/* (SC1007 is the spec's CDPATH= text), worker-shims/* and the stubs${SC_OUT:+: $(printf '%s' "$SC_OUT" | grep -m3 -E '^In |SC[0-9]+' | tr '\n' ' ')}" test -z "$SC_OUT"
else
  skip "[P38] shellcheck" "shellcheck not installed"
fi
check "[P38] cxlib.py, normalize.py and ledger.py compile (python3 -I, without writing __pycache__)" \
  "$REAL_PY" -I - "$CXLIB" "$ROOT/scripts/lib/normalize.py" "$ROOT/scripts/lib/ledger.py" <<'PY'
import sys
for f in sys.argv[1:]:
    compile(open(f, encoding="utf-8").read(), f, "exec")
PY
LF_BAD="$("$REAL_PY" -I - "$ROOT" <<'PY'
import os, sys
root = sys.argv[1]
bad = []
for d, dirs, files in os.walk(root):
    rel = os.path.relpath(d, root)
    dirs[:] = sorted(x for x in dirs if x != ".git" and os.path.join(rel, x).replace("./", "") not in ("tests/fixtures",) and x != "__pycache__")
    for f in files:
        p = os.path.join(d, f)
        r = os.path.relpath(p, root)
        if r.startswith("tests/fixtures/") or os.path.islink(p):
            continue
        data = open(p, "rb").read()
        try:
            data.decode("utf-8")
        except UnicodeDecodeError:
            continue
        if b"\r" in data:
            bad.append(r + " (CR)")
        elif data and not data.endswith(b"\n"):
            bad.append(r + " (no final newline)")
print(" ".join(sorted(bad)))
PY
)"
check "[P39] every shipped text file is LF-only and ends with a newline${LF_BAD:+: $LF_BAD}" test -z "$LF_BAD"
check "[P39] .gitattributes as in section 2.2, tests/fixtures/** -text and *.utf16le binary last" \
  test "$(cat "$ROOT/.gitattributes")" = $'* text=auto eol=lf\n*.sh text eol=lf\nbin/* text eol=lf\nhooks/* text eol=lf\nworker-shims/* text eol=lf\n*.ps1 text eol=crlf\ntests/fixtures/** -text\n*.utf16le binary'
check "[P39] git check-attr: tests/fixtures/settings/win-bom-crlf.json has text: unset" \
  test "$(git -C "$ROOT" check-attr text -- tests/fixtures/settings/win-bom-crlf.json)" = "tests/fixtures/settings/win-bom-crlf.json: text: unset"
check "[X]   git check-attr: wsl-l-v.utf16le is binary; a script keeps eol lf" \
  eval '[ "$(git -C "$ROOT" check-attr binary -- tests/fixtures/wsl-l-v.utf16le)" = "tests/fixtures/wsl-l-v.utf16le: binary: set" ] && [ "$(git -C "$ROOT" check-attr eol -- scripts/cx-init.sh)" = "scripts/cx-init.sh: eol: lf" ]'
CONV_BAD="$("$REAL_PY" -I - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
scripts = []
for d in ("bin", "scripts", "scripts/lib", "scripts/host", "scripts/adapters", "hooks", "worker-shims", "tests", "tests/stubs", "tests/stubs/gitbash"):
    p = os.path.join(root, d)
    if not os.path.isdir(p):
        continue
    for f in sorted(os.listdir(p)):
        q = os.path.join(p, f)
        if os.path.isfile(q) and (f.endswith(".sh") or d in ("bin", "worker-shims", "tests/stubs", "tests/stubs/gitbash")) and not f.startswith("."):
            scripts.append(os.path.relpath(q, root))
pyfiles = ["scripts/lib/cxlib.py", "scripts/lib/normalize.py", "scripts/lib/ledger.py"]
inv = re.compile(r"(?:^|[;|&(!]\s*|\$\(\s*|\b(?:if|then|else|do|exec|env|time)\s+)(python3)(?=\s|$)(?!\s+-I\b)")
tool = re.compile(r"(?:^|[;|&(!]\s*|\$\(\s*|\b(?:if|then|else|do|exec|env)\s+)(jq|node|nodejs)(?=\s|$)")
def unquote(s):
    s = re.sub(r'"(?:[^"\\]|\\.)*"', lambda m: m.group(0) if "$(" in m.group(0) else '""', s)
    return re.sub(r"'[^']*'", "''", s)
for rel in scripts + pyfiles:
    text = open(os.path.join(root, rel), encoding="utf-8", errors="replace").read()
    lines = text.split("\n")
    if rel.endswith(".py"):
        if "python3 -c" in text:
            bad.append(rel + ": python3 -c")
        continue
    if lines[0] != "#!/usr/bin/env bash":
        bad.append(rel + ": shebang")
    if len(lines) < 2 or not lines[1].startswith("#"):
        bad.append(rel + ": no header comment")
    if rel == "tests/run-tests.sh":
        continue
    for n, ln in enumerate(lines, 1):
        s = unquote(ln.strip())
        if s.startswith("#"):
            continue
        if re.search(r"python3\s+(-I\s+)?-c\b", s):
            bad.append("%s:%d: python3 -c" % (rel, n))
        if inv.search(s):
            bad.append("%s:%d: python3 without -I" % (rel, n))
        if tool.search(s):
            bad.append("%s:%d: jq/node call" % (rel, n))
        if re.search(r"(?:^|[;&|]\s*)set\s+-[a-zA-Z]*e[a-zA-Z]*\b|set -o errexit", s):
            bad.append("%s:%d: set -e" % (rel, n))
print("; ".join(bad))
PY
)"
check "[P40] no python3 -c, every python3 call is python3 -I, no jq/node calls, no set -e, bash shebang + header comment everywhere${CONV_BAD:+: $CONV_BAD}" test -z "$CONV_BAD"
hdr() { awk 'NR <= 2 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$1"; }
HV_BAD=""
for f in bin/cx-doctor bin/cx-init bin/cx-wsl scripts/cx-doctor.sh scripts/cx-init.sh scripts/cx-wsl.sh \
         scripts/host/detect.sh scripts/host/pathmap.sh scripts/host/forward-wsl.sh scripts/host/install-runtime.sh; do
  [ -f "$ROOT/$f" ] || { HV_BAD="$HV_BAD $f(missing)"; continue; }
  b="$(basename "$f" .sh)"
  src="$ROOT/$f"
  case "$f" in bin/*) src="$ROOT/scripts/$b.sh" ;; esac
  for gb in "" MINGW64_NT-10.0-26100; do
    run env STUB_UNAME_S="$gb" bash "$ROOT/$f" --version
    { rc_is 0 && [ "$(cat "$O")" = "$b $CXV" ]; } || HV_BAD="$HV_BAD $f${gb:+(gitbash)}(--version)"
    run env STUB_UNAME_S="$gb" bash "$ROOT/$f" --help
    { rc_is 0 && [ "$(cat "$O")" = "$(hdr "$src")" ] && [ -s "$O" ]; } || HV_BAD="$HV_BAD $f${gb:+(gitbash)}(--help)"
  done
  run bash "$ROOT/$f" -h
  [ "$(cat "$O")" = "$(hdr "$src")" ] || HV_BAD="$HV_BAD $f(-h)"
done
check "[P40] --help prints the header and --version prints '<prog> $CXV' (also on Git Bash, answered locally)${HV_BAD:+:$HV_BAD}" test -z "$HV_BAD"
SHIM_BAD=""
for b in cx-doctor cx-init cx-wsl; do
  f="$ROOT/bin/$b"
  { [ -f "$f" ] && [ ! -L "$f" ] && [ -x "$f" ]; } || { SHIM_BAD="$SHIM_BAD $b(file)"; continue; }
  [ "$(cat "$f")" = "$(printf '#!/usr/bin/env bash\n# Plugin bin/ entry point (Claude Code puts bin/ on the Bash tool'"'"'s PATH); forwards to scripts/%s.sh.\nexec "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/scripts/%s.sh" "$@"' "$b" "$b")" ] || SHIM_BAD="$SHIM_BAD $b(text)"
  out="$(cd "$ROOT" && CDPATH=. bash -c 'export CDPATH; bin/'"$b"' --version' 2>&1)"
  [ "$out" = "$b $CXV" ] || SHIM_BAD="$SHIM_BAD $b(relative+CDPATH=.: $out)"
done
check "[P40] bin shims: exactly the 3-line text, not symlinks, executable, work from a relative path with CDPATH=. exported${SHIM_BAD:+:$SHIM_BAD}" test -z "$SHIM_BAD"
SHIPPED="$("$REAL_PY" -I - "$ROOT/docs/DESIGN.md" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
sec = text.split("### 13.4 Shipped file list (Phase 1)", 1)[1].split("## 14.", 1)[0]
lst = sec.split("Executable:", 1)[0]
files = [f for f in re.findall(r"`([^`]+)`", lst) if "*" not in f]
files += ["worker-shims/" + n for n in ("claude", "copilot", "grok", "agy", "codex", "gemini", "cursor-agent", "agent")]
files += ["worker-shims/" + n for n in ("ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-cloud ghcp-models ghcp-doctor "
                                        "agy-delegate agy-handoff agy-job agy-media agy-doctor cx-run cx-job cx-fanout cx-gate "
                                        "cx-doctor cx-init cx-wsl").split()]
print("\n".join(sorted(set(files))))
PY
)"
D3_LIST="$(bash -c '. "$1/scripts/lib/common.sh"; printf "%s\n" "${CX_SHIPPED_FILES[@]}"' _ "$ROOT" | LC_ALL=C sort)"
MISSING_FILES=""
while IFS= read -r f; do [ -f "$ROOT/$f" ] || MISSING_FILES="$MISSING_FILES $f"; done <<< "$SHIPPED"
check "[P41] every file of the section 13.4 list exists${MISSING_FILES:+ (missing:$MISSING_FILES)}" test -z "$MISSING_FILES"
check "[P41] the doctor's D3 list (CX_SHIPPED_FILES) equals section 13.4 ($(printf '%s\n' "$SHIPPED" | wc -l) files)" test "$D3_LIST" = "$(printf '%s\n' "$SHIPPED" | LC_ALL=C sort)"
EXEC_WANT="$(printf '%s\n' "$SHIPPED" | grep -E '^(bin/|scripts/[^/]+\.sh$|scripts/host/[^/]+\.sh$|scripts/adapters/[^/]+\.sh$|hooks/[^/]+\.sh$|worker-shims/)' | LC_ALL=C sort)"
EXEC_LIST="$(bash -c '. "$1/scripts/lib/common.sh"; printf "%s\n" "${CX_SHIPPED_EXEC[@]}"' _ "$ROOT" | LC_ALL=C sort)"
check "[P41] CX_SHIPPED_EXEC = the executable subset of section 13.4" test "$EXEC_LIST" = "$EXEC_WANT"
NOEXEC=""
while IFS= read -r f; do [ -x "$ROOT/$f" ] || NOEXEC="$NOEXEC $f"; done <<< "$EXEC_WANT"
check "[X]   every executable of section 13.4 has its exec bit in the repo${NOEXEC:+ (not:$NOEXEC)}" test -z "$NOEXEC"
P63_BAD=""
for f in hooks/subagent.sh hooks/subagent-context.json hooks/subagent-context-compact.json hooks/policy-context-cloud.json templates/projects-instructions.md; do
  grep -qx "$f" <<< "$SHIPPED" || P63_BAD="$P63_BAD [$f not in 13.4]"
done
[ "$(bash -c '. "$1/scripts/lib/common.sh"; printf "%s " "${CX_RUNTIME_DIRS[@]}"' _ "$ROOT")" = ".claude-plugin bin scripts hooks worker-shims templates " ] || P63_BAD="$P63_BAD [runtime subset changed]"
for d in agents workflows; do [ -e "$ROOT/$d" ] && P63_BAD="$P63_BAD [$d/ exists in Phase 1]"; done
grep -q 'hooks/subagent.sh' <<< "$(bash -c '. "$1/scripts/lib/common.sh"; printf "%s\n" "${CX_SHIPPED_EXEC[@]}"' _ "$ROOT")" || P63_BAD="$P63_BAD [subagent.sh not executable-listed]"
check "[P63] the new Phase 1 files are in section 13.4, D3 and W6 (CX_SHIPPED_FILES; subagent.sh executable); the runtime subset is unchanged; no agents/ or workflows/ yet${P63_BAD:+:$P63_BAD}" test -z "$P63_BAD"

}
bg_section static sec_static

sec_init() {
# ------------------------------------------------------------------ 9. cx-init (section 9)
section "cx-init: detection matrix, write rules, notes"
detect_json() { run "$REAL_PY" -I "$CXLIB" init-detect "$1"; }
det_is() {  # KEY VALUE (VALUE "null" for None)
  local got
  got="$(out_json "$1")"
  [ "$got" = "$2" ] || { printf '        %s = [%s], want [%s]\n' "$1" "$got" "$2"; return 1; }
}
det_all() {  # SETUP TEST LINT TYPECHECK
  local r=0
  det_is setup "$1" || r=1; det_is test "$2" || r=1; det_is lint "$3" || r=1; det_is typecheck "$4" || r=1
  return "$r"
}
SETUP_RUN=()   # "NAME|DIR|SETUP" rows whose setup is run in a fresh worktree below
r="$(mkrepo npm-lock)"
printf '{"name": "a", "version": "1.0.0", "scripts": {"test": "node test.js", "lint": "eslint ."}}\n' > "$r/package.json"
printf '{"name": "a", "version": "1.0.0", "lockfileVersion": 3, "requires": true, "packages": {"": {"name": "a", "version": "1.0.0"}}}\n' > "$r/package-lock.json"
commit_all "$r"; detect_json "$r"
check "[P35] npm with package-lock.json: npm ci, npm test, npm run lint" \
  eval 'det_all "npm ci --prefer-offline" "npm test" "npm run lint" null && det_is package_manager npm && det_is ecosystems "[\"node\"]"'
r="$(mkrepo npm-tsc)"
printf '{"name": "a2", "scripts": {}, "devDependencies": {"typescript": "5.9.0"}}\n' > "$r/package.json"
printf '{}\n' > "$r/tsconfig.json"
commit_all "$r"; detect_json "$r"
check "[P35] npm with tsconfig.json and typescript in devDependencies: npx tsc --noEmit" det_is typecheck "npx tsc --noEmit"
r="$(mkrepo npm-nolock)"
printf '{"name": "b", "version": "1.0.0", "scripts": {"test": "echo \\"Error: no test specified\\" && exit 1"}}\n' > "$r/package.json"
commit_all "$r"; detect_json "$r"
check "[P35] npm without a lock: setup never writes a lockfile; the default test script is not a test" \
  det_all "npm install --no-audit --no-fund --no-package-lock" null null null
SETUP_RUN+=("npm-lock|$REPOS/npm-lock|npm ci --prefer-offline" "npm-nolock|$REPOS/npm-nolock|npm install --no-audit --no-fund --no-package-lock")
r="$(mkrepo pnpm)"
printf '{"name": "c", "scripts": {"test": "vitest", "typecheck": "tsc -p ."}}\n' > "$r/package.json"
printf 'lockfileVersion: 9.0\n' > "$r/pnpm-lock.yaml"
commit_all "$r"; detect_json "$r"
check "[P35] pnpm (lockfile): frozen install, pnpm test, pnpm run typecheck" \
  eval 'det_all "pnpm install --frozen-lockfile --prefer-offline" "pnpm test" null "pnpm run typecheck" && det_is package_manager pnpm'
r="$(mkrepo pnpm-pm)"
printf '{"name": "c", "packageManager": "pnpm@9.12.0", "scripts": {"lint": "x", "check-types": "y"}}\n' > "$r/package.json"
commit_all "$r"; detect_json "$r"
check "[P35] pnpm (packageManager field wins without a lockfile)" \
  eval 'det_all "pnpm install --frozen-lockfile --prefer-offline" null "pnpm run lint" "pnpm run check-types" && det_is package_manager pnpm'
r="$(mkrepo yarn-classic)"
printf '{"name": "d", "scripts": {"test": "jest", "lint": "eslint ."}}\n' > "$r/package.json"
printf '# THIS IS AN AUTOGENERATED FILE.\n# yarn lockfile v1\n' > "$r/yarn.lock"
commit_all "$r"; detect_json "$r"
check "[P35] yarn classic" eval 'det_all "yarn install --frozen-lockfile" "yarn test" "yarn lint" null && det_is package_manager yarn-classic'
r="$(mkrepo yarn-berry)"
printf '{"name": "e", "scripts": {"test": "jest", "type-check": "tsc"}}\n' > "$r/package.json"
printf '__metadata:\n  version: 8\n' > "$r/yarn.lock"
commit_all "$r"; detect_json "$r"
check "[P35] yarn berry (__metadata: in yarn.lock)" eval 'det_all "yarn install --immutable" "yarn test" null "yarn type-check" && det_is package_manager yarn-berry'
r="$(mkrepo yarn-berry-rc)"
printf '{"name": "e2", "scripts": {}}\n' > "$r/package.json"
: > "$r/yarn.lock"; printf 'nodeLinker: node-modules\n' > "$r/.yarnrc.yml"
commit_all "$r"; detect_json "$r"
check "[X]   yarn berry (.yarnrc.yml)" det_is package_manager yarn-berry
r="$(mkrepo bun)"
printf '{"name": "f", "scripts": {"test": "bun test", "lint": "x"}, "dependencies": {"typescript": "5"}}\n' > "$r/package.json"
: > "$r/bun.lock"; printf '{}\n' > "$r/tsconfig.json"
commit_all "$r"; detect_json "$r"
check "[P35] bun (bun.lock): setup null with a note, bun run test, bunx tsc --noEmit" \
  eval 'det_all null "bun run test" "bun run lint" "bunx tsc --noEmit" && det_is package_manager bun && out_has "bun detected: set setup yourself"'
r="$(mkrepo python-plain)"
printf '[project]\nname = "g"\ndependencies = ["requests"]\n\n[tool.pytest.ini_options]\naddopts = "-q"\n\n[tool.ruff]\nline-length = 100\n\n[tool.mypy]\nstrict = true\n' > "$r/pyproject.toml"
commit_all "$r"; detect_json "$r"
check "[P35] python plain with pytest + ruff + mypy: setup null with a note, python3 -m runners" \
  eval 'det_all null "python3 -m pytest -q" "python3 -m ruff check ." "python3 -m mypy ." && det_is ecosystems "[\"python\"]" && out_has "PEP 668"'
r="$(mkrepo python-uv)"
printf '[project]\nname = "h"\n[dependency-groups]\ndev = ["pytest>=8"]\n' > "$r/pyproject.toml"
: > "$r/uv.lock"; printf '[lint]\n' > "$r/ruff.toml"
commit_all "$r"; detect_json "$r"
check "[P35] uv: uv sync --frozen, uv run pytest -q (pytest in the dependency text), ruff.toml" \
  det_all "uv sync --frozen" "uv run pytest -q" "uv run ruff check ." null
r="$(mkrepo python-poetry)"
printf '[tool.poetry]\nname = "i"\n[tool.poetry.group.dev.dependencies]\npytest = "^8"\n' > "$r/pyproject.toml"
: > "$r/poetry.lock"; printf '[mypy]\n' > "$r/mypy.ini"
commit_all "$r"; detect_json "$r"
check "[P35] poetry: poetry install --no-interaction, poetry run pytest -q, mypy.ini" \
  det_all "poetry install --no-interaction" "poetry run pytest -q" null "poetry run mypy ."
r="$(mkrepo python-reqs)"
printf 'pytest==8.3\n' > "$r/requirements-dev.txt"; mkdir -p "$r/tests"; : > "$r/tests/test_x.py"
commit_all "$r"; detect_json "$r"
check "[X]   requirements-dev.txt with pytest -> python3 -m pytest -q" det_all null "python3 -m pytest -q" null null
r="$(mkrepo go-golangci)"
printf 'module example.com/j\n\ngo 1.22\n' > "$r/go.mod"; printf 'run:\n  timeout: 5m\n' > "$r/.golangci.yml"
commit_all "$r"; detect_json "$r"
check "[P35] go with a golangci config" det_all "go mod download" "go test ./..." "golangci-lint run" null
r="$(mkrepo go-plain)"
printf 'module example.com/k\n\ngo 1.22\n' > "$r/go.mod"
commit_all "$r"; detect_json "$r"
check "[P35] go without a golangci config: go vet ./..." det_all "go mod download" "go test ./..." "go vet ./..." null
SETUP_RUN+=("go|$REPOS/go-plain|go mod download")
r="$(mkrepo rust-locked)"
printf '[package]\nname = "l"\nversion = "0.1.0"\nedition = "2021"\n' > "$r/Cargo.toml"
mkdir -p "$r/src"; printf 'fn main() {}\n' > "$r/src/main.rs"
printf '# This file is automatically @generated by Cargo.\nversion = 4\n\n[[package]]\nname = "l"\nversion = "0.1.0"\n' > "$r/Cargo.lock"
commit_all "$r"; detect_json "$r"
check "[P35] rust with a tracked Cargo.lock: cargo fetch --locked" \
  det_all "cargo fetch --locked" "cargo test --quiet" "cargo clippy --all-targets --quiet -- -D warnings" "cargo check --all-targets --quiet"
SETUP_RUN+=("rust|$REPOS/rust-locked|cargo fetch --locked")
r="$(mkrepo rust-unlocked)"
printf '[package]\nname = "m"\nversion = "0.1.0"\n' > "$r/Cargo.toml"
commit_all "$r"; printf 'version = 4\n' > "$r/Cargo.lock"; detect_json "$r"
check "[P35] rust without a tracked Cargo.lock: setup null with a note" eval 'det_is setup null && out_has "Cargo.lock is not tracked"'
r="$(mkrepo make-only)"
printf 'all:\n\ttrue\ntest:\n\t./run\nlint:\n\t./lint\n' > "$r/Makefile"
commit_all "$r"; detect_json "$r"
check "[P35] Makefile only: make test, make lint" eval 'det_all null "make test" "make lint" null && det_is ecosystems "[]"'
r="$(mkrepo run-tests-only)"
mkdir -p "$r/tests"; printf '#!/usr/bin/env bash\n' > "$r/tests/run-tests.sh"
commit_all "$r"; detect_json "$r"
check "[P35] tests/run-tests.sh only: bash tests/run-tests.sh" det_all null "bash tests/run-tests.sh" null null
r="$(mkrepo node-go)"
printf '{"name": "n", "scripts": {"test": "jest"}}\n' > "$r/package.json"
printf '{"lockfileVersion": 3, "packages": {}}\n' > "$r/package-lock.json"
printf 'module example.com/n\n\ngo 1.22\n' > "$r/go.mod"
commit_all "$r"; detect_json "$r"
check "[P35] node + go: each slot joins the commands with ' && ' in the order node, python, go, rust, with a note" \
  eval 'det_all "npm ci --prefer-offline && go mod download" "npm test && go test ./..." "go vet ./..." null && det_is ecosystems "[\"node\", \"go\"]" && out_has "several ecosystems detected"'
r="$(mkrepo nothing)"
printf 'hello\n' > "$r/README.md"
commit_all "$r"; detect_json "$r"
check "[P35] nothing: every slot null" eval 'det_all null null null null && det_is package_manager null && det_is ecosystems "[]"'
r="$(mkrepo bad-package-json)"
printf '{not json\n' > "$r/package.json"
commit_all "$r"; detect_json "$r"
check "[X]   an unparseable package.json is not Node (note, no crash)" eval 'rc_is 0 && det_is ecosystems "[]" && out_has "does not parse"'
# Setup commands must leave a fresh worktree clean (where the tool is installed).
for row in "${SETUP_RUN[@]}"; do
  IFS='|' read -r name dir setup <<< "$row"
  tool="${setup%% *}"
  if ! PATH="$REAL_PATH" command -v "$tool" >/dev/null 2>&1; then
    skip "[P35] $name: '$setup' leaves a fresh worktree clean" "$tool not installed"
    continue
  fi
  wt="$TMP/setup-wt-$name"
  git -C "$dir" worktree add -q --detach "$wt" HEAD 2>/dev/null
  (cd "$wt" && env PATH="$REAL_PATH" npm_config_offline=true npm_config_update_notifier=false npm_config_cache="$TMP/npm-cache" \
     GOPROXY=off GOFLAGS=-mod=mod GOPATH="$TMP/gopath" GOCACHE="$TMP/gocache" CARGO_NET_OFFLINE=true CARGO_HOME="$TMP/cargo" \
     bash -c "$setup" > "$TMP/setup-$name.log" 2>&1 < /dev/null); src=$?
  if [ "$src" != 0 ]; then
    skip "[P35] $name: '$setup' leaves a fresh worktree clean" "setup failed offline (rc $src): $(head -c 120 "$TMP/setup-$name.log" | tr '\n' ' ')"
    continue
  fi
  check "[P35] $name: '$setup' leaves a fresh worktree clean (git status --porcelain empty)" test -z "$(git -C "$wt" status --porcelain)"
done
# Write rules (sections 9.1, 9.2, 9.4, 9.5).
R1="$(mkrepo bundle)"
printf '# Project\nhand-written notes\n' > "$R1/CLAUDE.md"
mkdir -p "$R1/.claude"; printf '{"x": 1}\n' > "$R1/.claude/settings.json"
printf '{"name": "w", "scripts": {"test": "node t.js"}}\n' > "$R1/package.json"
commit_all "$R1"
sums() { (cd "$1" && sha256sum CLAUDE.md .claude/settings.json .gitignore .gitattributes); }
SUMS0="$(sums "$R1")"
EXF="$R1/.git/info/exclude"
cinit() { local d="$1"; shift; (cd "$d" && "$INIT" "$@" > "$O" 2> "$E" < /dev/null); RC=$?; }
cinit "$R1"
check "[P36] fresh repo: create AGENTS.md, .cx/routes.json, .github/copilot-instructions.md, exit 0" \
  eval 'rc_is 0 && out_has "create   AGENTS.md" && out_has "create   .cx/routes.json" && out_has "create   .github/copilot-instructions.md" && [ -f "$R1/AGENTS.md" ] && [ -f "$R1/.cx/routes.json" ] && [ -f "$R1/.github/copilot-instructions.md" ]'
check "[P36] stdout: detected: lines; stderr: CX_INIT with written and excluded, no CX_SIGNAL" \
  eval 'out_has "detected: test = npm test" && out_has "detected: lint = (none)" && no_signal && tj linejson "$E" CX_INIT && line_is CX_INIT excluded true && [ "$(tj line "$E" CX_INIT written)" = "[\"AGENTS.md\", \".cx/routes.json\", \".github/copilot-instructions.md\"]" ]'
cinit "$R1"
check "[P36] rerun: all same, exit 0" eval 'rc_is 0 && [ "$(grep -c "^same     " "$O")" = 3 ] && [ "$(tj line "$E" CX_INIT written)" = "[]" ]'
check "[P36] /.conductor/ is in info/exclude exactly once after two runs" test "$(grep -cx '/.conductor/' "$EXF")" = 1
check "[P36] CLAUDE.md, .claude/, .gitignore and .gitattributes checksums unchanged; no CLAUDE.md content added" test "$(sums "$R1")" = "$SUMS0"
check "[P36] routes.json: the section 9.4 keys in order, detected setup/commands, pools all true, docker_only false" \
  test "$("$REAL_PY" -I - "$R1/.cx/routes.json" <<'PY'
import json, sys
raw = open(sys.argv[1]).read()
d = json.loads(raw)
print(list(d) == ["version", "setup", "commands", "bench", "audit", "mutation", "protected", "high_risk", "diff_budget",
                  "pools", "docker_only", "review_family", "copilot_review_tier"]
      and d["version"] == 1 and d["setup"] == "npm install --no-audit --no-fund --no-package-lock"
      and d["commands"] == {"test": "npm test", "lint": None, "typecheck": None}
      and d["pools"] == {"grok": True, "agy": True, "copilot": True} and d["docker_only"] is False
      and d["diff_budget"] == 400 and d["copilot_review_tier"] == "balanced"
      and raw == json.dumps(d, indent=2) + "\n")
PY
)" = True
WORKER_SENT='If `.conductor/task.md` exists in your working directory (you are a conductor worker):'
check "[P36] AGENTS.md block holds the conditional worker sentence verbatim and no worker-only rule above it" \
  eval 'grep -Fxq "$WORKER_SENT" "$R1/AGENTS.md" && ! sed -n "1,/^If \`.conductor\/task.md\` exists/p" "$R1/AGENTS.md" | grep -Eq "Do not commit|never edit it|Do not start subagents|Do not install"'
check "[P36] AGENTS.md Setup line wording and rendered commands" \
  eval 'grep -Fxq -- "- Setup (run by the caller before you start; do not run it unless your task says so): \`npm install --no-audit --no-fund --no-package-lock\`" "$R1/AGENTS.md" && grep -Fxq -- "- Test: \`npm test\`" "$R1/AGENTS.md" && grep -Fxq -- "- Lint: (none detected; set it in .cx/routes.json)" "$R1/AGENTS.md"'
check "[P36] copilot-instructions.md: the worker-only rules do not apply to Copilot coding agent tasks assigned on GitHub" \
  grep -Fq 'The worker-only rules do not apply to Copilot coding agent tasks assigned on GitHub' "$R1/.github/copilot-instructions.md"
TPL_BAD="$("$REAL_PY" -I - "$ROOT/docs/DESIGN.md" "$ROOT/templates/repo-bundle" <<'PY'
import json, os, sys
text = open(sys.argv[1], encoding="utf-8").read()
sec = text.split("### 9.5 Templates (final text)", 1)[1].split("## 10.", 1)[0]
blocks = [b.split("\n```", 1)[0] for b in sec.split("```markdown\n")[1:]]
bad = []
for name, blk in (("AGENTS.md", blocks[0]), ("copilot-instructions.md", blocks[1])):
    have = open(os.path.join(sys.argv[2], name), encoding="utf-8").read()
    if have.rstrip("\n") != blk.rstrip("\n"):
        bad.append(name)
routes = json.load(open(os.path.join(sys.argv[2], "routes.json")))
s94 = json.loads(text.split("### 9.4 `.cx/routes.json` (schema v1)", 1)[1].split("```json\n", 1)[1].split("\n```", 1)[0])
s94["setup"] = None
s94["commands"] = {k: None for k in s94["commands"]}
if routes != s94 or list(routes) != list(s94):
    bad.append("routes.json")
print(" ".join(bad))
PY
)"
check "[X]   the three templates equal their DESIGN section 9.4/9.5 text${TPL_BAD:+ (differs: $TPL_BAD)}" test -z "$TPL_BAD"
cp "$R1/AGENTS.md" "$TMP/agents.before"; cp "$R1/.github/copilot-instructions.md" "$TMP/copilot.before"
sed -i 's/^- Never weaken, delete or rewrite tests to make them pass\./- Never weaken tests (edited by hand)./' "$R1/AGENTS.md"
printf '\n## My own section\nkeep me\n' >> "$R1/AGENTS.md"
sed -i '1i # Agents\n\nintro text\n' "$R1/AGENTS.md"
cp "$R1/AGENTS.md" "$TMP/agents.edited"
rm -f -- "$R1/.github/copilot-instructions.md"
cinit "$R1"
check "[P36] an edited block -> exit 5, CONFLICT line, CX_SIGNAL EXISTS last, nothing written (not even the deleted file)" \
  eval 'rc_is 5 && out_has "CONFLICT AGENTS.md (" && one_signal EXISTS && cmp -s "$R1/AGENTS.md" "$TMP/agents.edited" && [ ! -e "$R1/.github/copilot-instructions.md" ] && [ "$(tj line "$E" CX_INIT conflicts)" = "[\"AGENTS.md\"]" ] && [ "$(tj line "$E" CX_INIT written)" = "[]" ]'
cinit "$R1" --dry-run
check "[P36] --dry-run with a conflict: same exit 5, nothing written" eval 'rc_is 5 && cmp -s "$R1/AGENTS.md" "$TMP/agents.edited" && [ ! -e "$R1/.github/copilot-instructions.md" ]'
cinit "$R1" --force
check "[P36] --force replaces only the block: text outside it byte-identical" \
  test "$("$REAL_PY" -I - "$TMP/agents.edited" "$R1/AGENTS.md" "$TMP/agents.before" <<'PY'
import sys
def split(t):
    a = t.index("<!-- cx:begin"); b = t.index("<!-- cx:end -->") + len("<!-- cx:end -->")
    return t[:a], t[a:b], t[b:]
e, n, orig = (open(p, encoding="utf-8").read() for p in sys.argv[1:4])
pe, be, se = split(e); pn, bn, sn = split(n); po, bo, so = split(orig)
print(pe == pn and se == sn and bn == bo and be != bo)
PY
)" = True
check "[X]   --force recreated the missing copilot-instructions.md (update/create lines), exit 0" \
  eval 'rc_is 0 && cmp -s "$R1/.github/copilot-instructions.md" "$TMP/copilot.before" && out_has "update   AGENTS.md (replace the conductor block)"'
R2="$(mkrepo noblock)"
printf '# Agents\n\nExisting guidance, no final newline' > "$R2/AGENTS.md"
cp "$R2/AGENTS.md" "$TMP/noblock.before"
cinit "$R2" --only agents
check "[P36] AGENTS.md without a block -> update without --force; block appended; earlier text byte-identical" \
  eval 'rc_is 0 && out_has "update   AGENTS.md (append the conductor block)" && [ "$(head -c "$(wc -c < "$TMP/noblock.before")" "$R2/AGENTS.md")" = "$(cat "$TMP/noblock.before")" ] && grep -q "^<!-- cx:begin conductor bundle v1" "$R2/AGENTS.md" && tail -n 1 "$R2/AGENTS.md" | grep -qx "<!-- cx:end -->"'
check "[P36] --only agents reports the other two as skipped and does not write them" \
  eval 'out_has "skipped  .cx/routes.json" && out_has "skipped  .github/copilot-instructions.md" && [ ! -e "$R2/.cx" ] && [ ! -e "$R2/.github" ]'
cinit "$R2"
printf '{\n  "version": 1, "setup": null, "commands": {"test": "hand edited"}\n}\n' > "$R2/.cx/routes.json"
cp "$R2/.cx/routes.json" "$TMP/routes.edited"
cinit "$R2" --only agents --force
check "[P36] --only agents --force never touches an edited routes.json (skipped)" \
  eval 'rc_is 0 && out_has "skipped  .cx/routes.json" && cmp -s "$R2/.cx/routes.json" "$TMP/routes.edited"'
cinit "$R2"
check "[X]   the edited routes.json is a conflict without --force (exit 5)" eval 'rc_is 5 && out_has "CONFLICT .cx/routes.json"'
"$REAL_PY" -I - "$R1/.cx/routes.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
open(sys.argv[1], "w").write(json.dumps(d, separators=(",", ":")) + "\n\n")
PY
cinit "$R1"
check "[P36] a JSON-equal routes.json with other whitespace -> same" eval 'rc_is 0 && out_has "same     .cx/routes.json"'
R3="$(mkrepo dry)"
cinit "$R3" --dry-run --json
check "[P36] --dry-run writes nothing (no files, no exclude line), exit 0, JSON plan on stdout" \
  eval 'rc_is 0 && [ ! -e "$R3/AGENTS.md" ] && [ ! -e "$R3/.cx" ] && ! grep -q conductor "$R3/.git/info/exclude" && outj_is dry_run true && outj_is files.0.action create && line_is CX_INIT dry_run true'
mkdir -p "$TMP/not-a-repo"
cinit "$TMP/not-a-repo"
check "[P36] not a repo -> exit 1, no CX_SIGNAL" eval 'rc_is 1 && no_signal && err_has "cx-init: try --help"'
mkdir -p "$R3/src/deep"
cinit "$R3/src/deep" --json
check "[P36] a subdirectory -> the toplevel (with a note)" \
  eval 'rc_is 0 && [ -f "$R3/AGENTS.md" ] && [ ! -e "$R3/src/deep/AGENTS.md" ] && outj_is repo "$R3" && grep -Fq "using the repository root" "$O"'
cinit "$TMP" --dir "$R3/src" --dry-run
check "[X]   --dir selects the repository; exit 0" eval 'rc_is 0 && out_has "same     AGENTS.md"'
cinit "$R3" --bogus
check "[X]   an unknown argument -> exit 1" eval 'rc_is 1 && no_signal'
cinit "$R3" --only nope
check "[X]   --only with a bad name -> exit 1" rc_is 1
cinit "$R3" --dry-run --json --test 'pytest -x' --lint '' --setup 'make deps'
check "[X]   --test/--setup override detection; --lint '' means none (null)" \
  eval 'outj_is detected.test "pytest -x" && outj_is detected.setup "make deps" && outj_is detected.lint null'
R4="$(mkrepo notes)"
rm -f -- "$R4/.gitattributes"
git -C "$R4" config core.autocrlf true
cinit "$R4" --dry-run
check "[P37] notes: a missing .gitattributes and core.autocrlf=true (on stderr, never acted on)" \
  eval 'rc_is 0 && err_has "cx-init: no .gitattributes at the repo root" && err_has "core.autocrlf=true" && [ ! -e "$R4/.gitattributes" ]'
check "[X]   notes: nothing detected for a slot" err_has "nothing detected for test"
ln -s CLAUDE.md "$R4/AGENTS.md"; printf 'claude\n' > "$R4/CLAUDE.md"
cinit "$R4" --force
check "[X]   an AGENTS.md symlink is refused even with --force (it would edit its target)" \
  eval 'rc_is 5 && [ "$(cat "$R4/CLAUDE.md")" = claude ] && out_has "CONFLICT AGENTS.md (is a symlink"'
R5="$(mkrepo dirlinks)"
mkdir -p "$REPOS/outside-gh" "$REPOS/outside-cx"
ln -s ../outside-gh "$R5/.github"; ln -s ../outside-cx "$R5/.cx"; commit_all "$R5"
cinit "$R5" --force
check "[X]   committed .github and .cx symlinks (to dirs outside the repo): conflicts, exit 5, nothing written anywhere (not even AGENTS.md)" \
  eval 'rc_is 5 && out_has "CONFLICT .cx/routes.json (.cx is a symlink" && out_has "CONFLICT .github/copilot-instructions.md (.github is a symlink" && [ -z "$(find "$REPOS/outside-gh" "$REPOS/outside-cx" -mindepth 1)" ] && [ ! -e "$R5/AGENTS.md" ]'
R6="$(mkrepo cxfile)"
printf 'not a dir\n' > "$R6/.cx"; commit_all "$R6"
cinit "$R6"
check "[X]   a regular file .cx: a conflict before anything is written (no partial bundle)" \
  eval 'rc_is 5 && out_has "CONFLICT .cx/routes.json (.cx exists and is not a directory" && [ ! -e "$R6/AGENTS.md" ] && [ ! -e "$R6/.github" ]'

# P59: the D32 matrix through cxlib.py doctor-session (layers: managed, local, project, user; env)
SR="$TMP/d32"
mkdir -p "$SR/cfg" "$SR/root/etc/claude-code/managed-settings.d" "$SR/repo/.claude"
d32() {  # [VAR=VALUE...] -- [ARGS...]: D32/D31 TSV of doctor-session into $O
  local -a ev=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done
  shift
  O="$TMP/out.d32"; E="$TMP/err.d32"
  env ${ev[@]+"${ev[@]}"} "$REAL_PY" -I "$CXLIB" doctor-session --config-dir "$SR/cfg" --root "$SR/root" --nproc 8 "$@" > "$O" 2> "$E"; RC=$?
}
d32has() { grep -F -- "$1" "$O" | grep -q "^info	D32	Session	"; }
P59_BAD=""
printf '{"ultracode": true}\n' > "$SR/cfg/settings.json"
printf '{"ultracode": false}\n' > "$SR/repo/.claude/settings.json"
d32 --
d32has "ultracode on for new sessions (user settings, $SR/cfg/settings.json)" || P59_BAD="$P59_BAD [user]"
d32 -- --repo "$SR/repo"
d32has "ultracode not set in the settings files" || P59_BAD="$P59_BAD [project false wins]"
printf '{"ultracode": true}\n' > "$SR/repo/.claude/settings.json"
d32 -- --repo "$SR/repo"
d32has "ultracode on for new sessions (project settings, $SR/repo/.claude/settings.json)" || P59_BAD="$P59_BAD [project]"
printf '{"enableWorkflows": false}\n' > "$SR/repo/.claude/settings.local.json"
d32 -- --repo "$SR/repo"
{ d32has "workflows off (enableWorkflows false in local settings" && d32has "ultracode is set (project settings"; } || P59_BAD="$P59_BAD [local enableWorkflows]"
rm -f -- "$SR/repo/.claude/settings.local.json"
printf '\xef\xbb\xbf{"disableWorkflows": true}\r\n' > "$SR/root/etc/claude-code/managed-settings.json"
d32 -- --repo "$SR/repo"
{ d32has "workflows off (disableWorkflows in managed settings, $SR/root/etc/claude-code/managed-settings.json)" && d32has "but workflows are off, so it has no effect"; } || P59_BAD="$P59_BAD [managed]"
rm -f -- "$SR/root/etc/claude-code/managed-settings.json"
printf '{"disableWorkflows": true}\n' > "$SR/root/etc/claude-code/managed-settings.d/10-x.json"
d32 --
d32has "workflows off (disableWorkflows in managed settings, $SR/root/etc/claude-code/managed-settings.d/10-x.json)" || P59_BAD="$P59_BAD [managed drop-in]"
rm -f -- "$SR/root/etc/claude-code/managed-settings.d/10-x.json"
d32 CLAUDE_CODE_DISABLE_WORKFLOWS=1 --
d32has "workflows off (CLAUDE_CODE_DISABLE_WORKFLOWS is set)" || P59_BAD="$P59_BAD [DISABLE env]"
d32 CLAUDE_CODE_WORKFLOWS=false --
d32has "workflows off (CLAUDE_CODE_WORKFLOWS=false)" || P59_BAD="$P59_BAD [WORKFLOWS=false]"
printf '{"workflowKeywordTriggerEnabled": false, "workflowSizeGuideline": "small"}\n' > "$SR/cfg/settings.json"
d32 CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL=haiku CLAUDE_CODE_SUBAGENT_MODEL_FORCE=sonnet CLAUDE_CODE_SUBAGENT_MODEL=opus CLAUDE_CODE_SUBAGENT_EFFORT=low --
{ d32has "the ultracode keyword trigger is off (user settings" && d32has 'workflow size guideline "small"' && d32has "CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL=haiku overrides the model" \
  && d32has "CLAUDE_CODE_SUBAGENT_MODEL_FORCE=sonnet overrides the model" && d32has "CLAUDE_CODE_SUBAGENT_MODEL=opus overrides the model" \
  && d32has "CLAUDE_CODE_SUBAGENT_EFFORT=low overrides the effort"; } || P59_BAD="$P59_BAD [keyword, guideline, models]"
for np in 8:6 3:2 64:16 1:2; do
  d32 -- --nproc "${np%%:*}"
  d32has "workflow concurrency ${np#*:} agents per workflow (min(16, max(2, ${np%%:*} CPUs - 2))" || P59_BAD="$P59_BAD [nproc ${np%%:*}]"
done
d32 CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS=7 -- --nproc 64
d32has "workflow concurrency 7 agents per workflow (CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS)" || P59_BAD="$P59_BAD [env override]"
d32 -- --forwarded 1
{ ! grep -q "	D32	" "$O" && grep -q "	D31	" "$O"; } || P59_BAD="$P59_BAD [forwarded: D31 only]"
d32 CLAUDE_CODE_DISABLE_WORKFLOWS=1 CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS=x --
{ rc_is 0 && ! grep -qv "^info	" "$O"; } || P59_BAD="$P59_BAD [all info, rc 0]"
check "[P59] D32 matrix: ultracode in user, project over user, local enableWorkflows false, managed file (BOM+CRLF) and drop-in disableWorkflows, CLAUDE_CODE_DISABLE_WORKFLOWS, CLAUDE_CODE_WORKFLOWS=false, keyword trigger off, guideline small, each model and effort variable, nproc 8/3/64/1 -> 6/2/16/2, the env override wins; every line info${P59_BAD:+:$P59_BAD}" test -z "$P59_BAD"
}

# ------------------------------------------------------------------ 1. manifests
section "manifests and versions"
PJ="$ROOT/.claude-plugin/plugin.json" MJ="$ROOT/.claude-plugin/marketplace.json"
check "[P1]  plugin.json and marketplace.json parse; identity, author, repository, license exact; marketplace source ./ and same version" \
  test "$("$REAL_PY" -I - "$PJ" "$MJ" <<'PY'
import json, os, sys
p = json.load(open(sys.argv[1])); m = json.load(open(sys.argv[2]))
ok = (p["name"] == "conductor" and p["version"] == os.environ["CXV"] and p["license"] == "MIT"
      and p["author"] == {"name": "40chalk", "url": "https://github.com/40chalk"}
      and p["repository"] == "https://github.com/40chalk/conductor-for-claude-code"
      and p["homepage"] == "https://github.com/40chalk/conductor-for-claude-code"
      and set(p["keywords"]) >= {"orchestration", "multi-agent", "model-routing", "github-copilot", "grok", "antigravity", "wsl", "delegation"}
      and m["name"] == "conductor-for-claude-code" and m["owner"] == {"name": "40chalk"}
      and m["$schema"] == "https://anthropic.com/claude-code/marketplace.schema.json"
      and len(m["plugins"]) == 1 and m["plugins"][0]["name"] == "conductor" and m["plugins"][0]["source"] == "./"
      and m["plugins"][0]["version"] == p["version"] and bool(m["metadata"]["description"]))
print(ok)
PY
)" = True
OPT_EXPECT='policy=on exec_host=auto wsl_distro=auto docker_compose_file= docker_service=agents opus_lane_order=agy,copilot,claude agy_opus_slug_tpl=claude-opus-5-5-{effort} agy_opus_mode=raw copilot_opus_id=claude-opus-5.5 copilot_xhigh_ok=false grok_bulk_model=grok-4.7 grok_bulk_effort=high grok_sandbox_profile=cx-workspace review_model_gemini=Gemini 4 Argon (High) review_model_gpt=gpt-6.1-sol cap_agy=2 cap_copilot=3 cap_grok=5 copilot_reserve_pct=0 copilot_mtd_max_age_days=3 agy_claude_floor_pct=0 worktree_root=~/.cx-wt ledger_path=~/.conductor/ledger.jsonl default_timeout=30m'
SH_DEFAULTS="$(bash -c '. "$1/scripts/lib/common.sh"; . "$1/scripts/lib/options.sh"; for n in "${CX_OPT_NAMES[@]}"; do printf "%s=%s\n" "$n" "${CX_OPT_DEFAULTS[$n]}"; done' _ "$ROOT")"
check "[P2]  userConfig = exactly the 24 options of section 5.1, each type string with title and description; defaults = section 5.1 = CX_OPT_DEFAULTS" \
  test "$("$REAL_PY" -I - "$PJ" "$OPT_EXPECT" "$SH_DEFAULTS" <<'PY'
import json, re, sys
uc = json.load(open(sys.argv[1]))["userConfig"]
# section 5.1 order and defaults (one name=value per option; values may contain spaces)
want = dict(re.findall(r"(\w+)=(.*?)(?= \w+=|$)", sys.argv[2]))
sh = dict(l.split("=", 1) for l in sys.argv[3].split("\n") if l)
ok = (list(uc) == list(want) and len(uc) == 24
      and all(v.get("type") == "string" and v.get("title", "").strip() and v.get("description", "").strip() for v in uc.values())
      and {k: v.get("default") for k, v in uc.items()} == want and sh == want and list(sh) == list(want))
print(ok)
PY
)" = True
CL_TOP="$(grep -m1 '^## ' "$ROOT/CHANGELOG.md" 2>/dev/null | sed -n 's/^## \([0-9][0-9.]*\).*/\1/p')"
check "[P2]  CX_VERSION = plugin.json = marketplace.json = top CHANGELOG heading ($CXV)" \
  test "$(bash -c '. "$1/scripts/lib/common.sh"; printf %s "$CX_VERSION"' _ "$ROOT")|$(tj get "$PJ" version)|$(tj get "$MJ" plugins.0.version)|$CL_TOP|$("$REAL_PY" -I "$CXLIB" const CURSOR_POOL_MSG >/dev/null && sed -n 's/^VERSION = "\(.*\)"/\1/p' "$CXLIB")" = "$CXV|$CXV|$CXV|$CXV|$CXV"
check "[X]   CHANGELOG top heading reads '## $CXV — 2026-11-01'" grep -qx "## $CXV — 2026-11-01" "$ROOT/CHANGELOG.md"
REAL_CLAUDE="$(PATH="$REAL_PATH" command -v claude 2>/dev/null)"
if [ -z "$REAL_CLAUDE" ]; then
  skip "[P3]  claude plugin validate" "no claude CLI on PATH"
else
  VAL_DIR="$ROOT"
  if [ -e "$ROOT/.mcp.json" ] && ! git -C "$ROOT" ls-files --error-unmatch .mcp.json >/dev/null 2>&1; then
    VAL_DIR="$TMP/validate-copy"
    mkdir -p "$VAL_DIR"
    (cd "$ROOT" && git ls-files -co --exclude-standard -z | grep -zv '^\.mcp\.json$' | xargs -0 cp --parents -t "$VAL_DIR" 2>/dev/null)
  fi
  run env PATH="$REAL_PATH" HOME="$TMP/validate-home" "$REAL_CLAUDE" plugin validate "$VAL_DIR"
  if grep -qiE 'network|ENOTFOUND|EAI_AGAIN' "$E" && ! rc_is 0; then
    skip "[P3]  claude plugin validate" "validate needed the network"
  else
    check "[P3]  claude plugin validate passes (ICON warnings allowed)" \
      eval 'rc_is 0 && ! grep -iE "error|invalid" "$O" "$E" | grep -viE "ICON|0 error"'
  fi
fi

# ------------------------------------------------------------------ 2. options (section 5)
section "options loader, precedence, validation and the Git Bash lite reader"
# optprobe [FILE...]: sources the libraries, runs cx_load_options FILE..., prints NAME=<env>|<cx_opt>.
OPTPROBE="$TMP/optprobe.sh"
cat > "$OPTPROBE" <<'SH'
. "$CX_TEST_ROOT/scripts/lib/common.sh"
. "$CX_TEST_ROOT/scripts/lib/options.sh"
if [ "${1-}" = --default-files ]; then shift; cx_load_options; else cx_load_options "$@"; fi
for n in cap_grok cap_agy cap_copilot policy copilot_reserve_pct grok_bulk_model opus_lane_order review_model_gemini worktree_root wsl_distro exec_host grok_bulk_effort; do
  v="CLAUDE_PLUGIN_OPTION_${n^^}"
  printf '%s=%s|%s\n' "$n" "${!v-<unset>}" "$(cx_opt "$n" 2>/dev/null)"
done
compgen -e | grep '^CLAUDE_PLUGIN_OPTION_' | sort | tr '\n' ' '
printf '\n'
SH
optp() { run env CX_TEST_ROOT="$ROOT" bash "$OPTPROBE" "$@"; }
o_is() { grep -Fxq -- "$1" "$O"; }
optp "$FIX/settings/options.json"
check "[P4]  loader: a settings value is exported (cap_grok=7, not the foreign plugin's 31)" o_is "cap_grok=7|7"
check "[P4]  loader: booleans become true/false, numbers their decimal text (12.0 -> 12)" \
  eval 'o_is "policy=false|false" && o_is "cap_agy=3|3" && o_is "copilot_reserve_pct=12|12"'
check "[P4]  loader: null, list and object values are skipped; an invalid key is skipped" \
  eval 'o_is "grok_bulk_model=<unset>|grok-4.7" && o_is "opus_lane_order=<unset>|agy,copilot,claude" && o_is "review_model_gemini=<unset>|Gemini 4 Argon (High)" && out_lacks "BAD-KEY" && out_lacks "BAD_KEY"'
check "[P4]  loader: a value with a quote survives shlex quoting" o_is "worktree_root=/home/me/it's here|/home/me/it's here"
CLAUDE_PLUGIN_OPTION_CAP_GROK="" optp "$FIX/settings/options.json"
check "[P4]  an environment value wins, even when empty (empty = the default)" o_is "cap_grok=|5"
CLAUDE_PLUGIN_OPTION_CAP_GROK=11 optp "$FIX/settings/options.json"
check "[P4]  an environment value wins over settings.json" o_is "cap_grok=11|11"
optp "$FIX/settings/options-short.json"
check "[P4]  key fallback: pluginConfigs.conductor" o_is "cap_grok=8|8"
optp "$FIX/settings/options-other-market.json"
check "[P4]  key fallback: the first key starting with conductor@" o_is "cap_grok=9|9"
printf '{"pluginConfigs": {"conductor@conductor-for-claude-code": {"options": {"cap_grok": "7"' > "$TMP/broken.json"
optp "$TMP/broken.json"
check "[P4]  invalid JSON: silent no-op" eval 'rc_is 0 && err_empty && o_is "cap_grok=<unset>|5"'
optp "$TMP/does-not-exist.json"
check "[P4]  missing file: silent no-op" eval 'rc_is 0 && err_empty && o_is "cap_grok=<unset>|5"'
NOPY_BIN="$TMP/nopy-bin"
mkdir -p "$NOPY_BIN"
for t in bash env cat grep sed awk tr cut head tail mkdir mktemp rm dirname od wc sort uname sleep kill cp ls chmod date iconv tee timeout; do
  p="$(PATH="$REAL_PATH" command -v "$t" 2>/dev/null)" && ln -sf "$p" "$NOPY_BIN/$t"
done
run env PATH="$NOPY_BIN" CX_TEST_ROOT="$ROOT" bash "$OPTPROBE" "$FIX/settings/options.json"
check "[P4]  no python3: silent no-op (defaults)" eval 'rc_is 0 && err_empty && o_is "cap_grok=<unset>|5"'
mkdir -p "$TMP/planted"
printf 'import os\nopen(os.environ["PLANT_MARK"], "w").write("imported")\nraise SystemExit(7)\n' > "$TMP/planted/json.py"
cp "$TMP/planted/json.py" "$TMP/planted/shlex.py"
run bash -c 'cd "$1" && PLANT_MARK="$2" CX_TEST_ROOT="$3" bash "$4" "$5"' _ "$TMP/planted" "$TMP/planted.mark" "$ROOT" "$OPTPROBE" "$FIX/settings/options.json"
check "[P4]  a planted json.py / shlex.py in the cwd is not imported" eval 'o_is "cap_grok=7|7" && [ ! -e "$TMP/planted.mark" ]'
cp "$FIX/settings/options-host.json" "$CLAUDE_CONFIG_DIR/settings.json"
run env CX_TEST_ROOT="$ROOT" bash "$OPTPROBE" --default-files
check "[X]   no FILE: loads \$CLAUDE_CONFIG_DIR/settings.json" o_is "cap_grok=4|4"
run env CX_WIN_SETTINGS="$FIX/settings/win-bom-crlf.json" CX_TEST_ROOT="$ROOT" bash "$OPTPROBE" --default-files
check "[P5]  CX_WIN_SETTINGS beats the executor host's settings value" eval 'o_is "cap_grok=6|6" && o_is "cap_copilot=2|2"'
check "[P5]  a Windows settings file with a UTF-8 BOM and CRLF still loads (utf-8-sig)" eval 'o_is "wsl_distro=Ubuntu-24.04|Ubuntu-24.04" && o_is "exec_host=wsl|wsl"'
check "[P5]  keys only in the executor host's file still load" o_is "grok_bulk_effort=medium|medium"
run env CLAUDE_PLUGIN_OPTION_CAP_GROK=13 CX_WIN_SETTINGS="$FIX/settings/win-bom-crlf.json" CX_TEST_ROOT="$ROOT" bash "$OPTPROBE" --default-files
check "[P5]  the environment beats both settings files" o_is "cap_grok=13|13"
green_host
# cx_opt validation (section 5.3)
optv() { run env "$@" CX_TEST_ROOT="$ROOT" bash -c '. "$CX_TEST_ROOT/scripts/lib/common.sh"; . "$CX_TEST_ROOT/scripts/lib/options.sh"; CX_PROG=cx-test; cx_opt "$OPTN"; cx_opt "$OPTN"'; }
optv OPTN=cap_agy CLAUDE_PLUGIN_OPTION_CAP_AGY=abc
check "[P6]  cap_agy=abc -> one note and the default 2" \
  eval '[ "$(cat "$O")" = "2"$'"'"'\n'"'"'"2" ] && [ "$(grep -c "ignoring invalid option cap_agy=.abc.; using .2." "$E")" = 1 ]'
optv OPTN=worktree_root CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT=/
check "[P6]  worktree_root=/ is invalid" eval 'err_has "ignoring invalid option worktree_root" && grep -qx "~/.cx-wt" "$O"'
optv OPTN=worktree_root CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT="$HOME"
check "[X]   worktree_root=\$HOME is invalid" err_has "ignoring invalid option worktree_root"
optv OPTN=exec_host CLAUDE_PLUGIN_OPTION_EXEC_HOST=docker
check "[P6]  exec_host=docker is invalid before v1.1" eval 'err_has "ignoring invalid option exec_host" && grep -qx auto "$O"'
optv OPTN=opus_lane_order CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=copilot,agy
check "[P6]  opus_lane_order=copilot,agy -> copilot,agy,claude" eval 'grep -qx "copilot,agy,claude" "$O" && err_empty'
OC_DEF=()
while IFS='=' read -r k v; do OC_DEF+=(--default "$k=$v"); done <<< "$SH_DEFAULTS"
run env CLAUDE_PLUGIN_OPTION_CAP_AGY=abc CLAUDE_PLUGIN_OPTION_WORKTREE_ROOT=/ CLAUDE_PLUGIN_OPTION_EXEC_HOST=docker \
  CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=copilot,agy "$REAL_PY" -I "$CXLIB" options-check --tsv "${OC_DEF[@]}" --settings "$FIX/settings/options.json"
check "[P6]  D7 (options-check) lists cap_agy, worktree_root and exec_host as ! and the lane order as info" \
  eval 'grep -q "^warn	D7	Options	option cap_agy=" "$O" && grep -q "^warn	D7	Options	option worktree_root=" "$O" && grep -q "^warn	D7	Options	option exec_host=" "$O" && grep -q "^info	D7	Options	option opus_lane_order = copilot,agy" "$O"'
check "[X]   D7 lists an unknown key under the conductor's options as ! (probable typo)" grep -q "^warn	D7	Options	unknown option bad-key=x" "$O"
# cx_opt_lite (pure bash, section 5.2)
lite() { run env CX_TEST_ROOT="$ROOT" bash -c '. "$CX_TEST_ROOT/scripts/lib/common.sh"; . "$CX_TEST_ROOT/scripts/lib/options.sh"; cx_opt_lite "$1" "$2"' _ "$1" "$2"; }
lite wsl_distro "$FIX/settings/enabled-first.json"
check "[P7]  cx_opt_lite finds wsl_distro in the conductor's entry (enabledPlugins first, earlier foreign block ignored)" eval '[ "$(cat "$O")" = "Right-1.x_y" ]'
lite exec_host "$FIX/settings/enabled-first.json"
check "[P7]  cx_opt_lite ignores a key in a later foreign block; braces and quotes inside strings do not end the span" eval 'out_empty && rc_is 0'
lite docker_service "$FIX/settings/enabled-first.json"
check "[P7]  cx_opt_lite rejects a value with a space" eval 'out_empty && rc_is 0'
lite wsl_distro "$FIX/settings/win-bom-crlf.json"
check "[P7]  cx_opt_lite handles a leading BOM and CRLF" eval '[ "$(cat "$O")" = "Ubuntu-24.04" ]'
lite exec_host "$TMP/does-not-exist.json"
check "[X]   cx_opt_lite: missing file -> nothing, rc 0" eval 'out_empty && rc_is 0'
# The lite readers are linear (W10/W11 and every forwarded call read the Windows settings file):
# a BOM+CRLF settings file of ~80 KB (a long permissions.allow list, the conductor entry last).
"$REAL_PY" -I - "$TMP/big-settings.json" <<'PY'
import json, sys
d = {"permissions": {"allow": ["Bash(some command number %d with args:*)" % i for i in range(1500)]},
     "env": {"DISABLE_GROWTHBOOK": "1", "Q": "a \\\" } {"}, "ultracode": True,
     "pluginConfigs": {"conductor@conductor-for-claude-code": {"options": {"wsl_distro": "Big-1", "exec_host": "auto"}}}}
open(sys.argv[1], "w", encoding="utf-8", newline="").write("﻿" + json.dumps(d, indent=2).replace("\n", "\r\n"))
PY
T0=$SECONDS
run env CX_TEST_ROOT="$ROOT" bash -c '. "$CX_TEST_ROOT/scripts/lib/common.sh"; . "$CX_TEST_ROOT/scripts/lib/options.sh"
  cx_opt_lite wsl_distro "$1"; cx_opt_lite exec_host "$1"; cx_lite_top "$1" env
  printf "%s|%s|%s\n" "$(cx_lite_value "$CX_LITE_TOP" ultracode)" "$(cx_lite_value "$CX_LITE_OBJ" DISABLE_GROWTHBOOK)" "$(cx_lite_value "$CX_LITE_TOP" allow)"' _ "$TMP/big-settings.json"
LITE_S=$((SECONDS - T0))
check "[X]   cx_opt_lite and cx_lite_top over an 80 KB BOM+CRLF settings file: the right values in under 3 s (linear, not quadratic; took ${LITE_S} s)" \
  eval 'rc_is 0 && [ "$(cat "$O")" = "$(printf "Big-1\nauto\ntrue|1|")" ] && [ "$LITE_S" -lt 3 ]'

# cx-init reads options from the shared settings.json, which the options section above swaps:
# the init section starts only now.
bg_section init sec_init
# The doctor section reads the same shared settings, so it starts here too; the serial sections
# up to the Git Bash part below share nothing with it.
crlf_copy() {  # DEST FILE...|--all: a plugin copy with the given files (or every file) converted to CRLF
  local dest="$1" f
  shift
  mkdir -p "$dest"
  cp -R "$ROOT/.claude-plugin" "$ROOT/bin" "$ROOT/scripts" "$ROOT/hooks" "$ROOT/worker-shims" "$ROOT/templates" "$ROOT/skills" "$ROOT/commands" "$dest/"
  if [ "${1-}" = --all ]; then
    while IFS= read -r -d '' f; do sed -i 's/$/\r/' "$f"; done < <(find "$dest" -type f -print0)
  else
    for f in "$@"; do sed -i 's/$/\r/' "$dest/$f"; done
  fi
}
sec_doctor() {
# ------------------------------------------------------------------ 10. cx-doctor on the executor host (section 8)
section "cx-doctor: green host, one failure at a time, siblings, pins, CRLF, pools, login help, --json"
# doc_cfg NAME SETTINGS [EXTRA_INSTALLED_JSON] [--no-ghcp]: a private CLAUDE_CONFIG_DIR for one case.
doc_cfg() {
  local c="$DOCS/$1/cfg"
  mkdir -p "$c/plugins"
  cp "$2" "$c/settings.json"
  write_installed "$c" "" "${3:-}"
  if [ "${4:-}" = --no-ghcp ]; then
    "$REAL_PY" -I - "$c/plugins/installed_plugins.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["plugins"].pop("ghcp@ghcp-for-claude-code")
open(sys.argv[1], "w").write(json.dumps(d))
PY
  fi
  printf '%s' "$c"
}
GROKB_ENTRY="\"grok-build@xai-grok-build\": [{\"scope\": \"user\", \"installPath\": \"$TMP/plugins/grok-build\", \"version\": \"0.2.1\"}]"
SDEF="$FIX/settings/siblings-default.json"
doc_bg green --
doc_bg green-json -- --json --no-record
doc_bg cop-pre STUB_COPILOT_VERSION=1.0.106-1 -- --no-record
doc_bg cop-pre-json STUB_COPILOT_VERSION=1.0.106-1 -- --no-record --json
doc_bg grok73 STUB_GROK_VERSION=1.0.73 -- --no-record
doc_bg claude300 STUB_CLAUDE_VERSION=2.1.300 -- --no-record
doc_bg agy119 STUB_AGY_VERSION=1.1.9 -- --no-record
doc_bg agy1111 STUB_AGY_VERSION=1.1.11 -- --no-record
doc_bg grok-unauth STUB_GROK_AUTH=0 -- --no-record
doc_bg grok-net STUB_GROK_MODELS_FAIL=network -- --no-record
doc_bg ghcp-auth STUB_GHCP_MODELS=auth -- --no-record
doc_bg ghcp-sandbox STUB_GHCP_MODELS=sandbox -- --no-record
doc_bg ghcp-timeout STUB_GHCP_MODELS=timeout -- --no-record
doc_bg ghcp-catalog STUB_GHCP_MODELS=catalog -- --no-record
doc_bg no-ghcp CLAUDE_CONFIG_DIR="$(doc_cfg no-ghcp "$FIX/settings/green.json" "" --no-ghcp)" -- --no-record
doc_bg no-ghcp-rofs CLAUDE_CONFIG_DIR="$(doc_cfg no-ghcp-rofs "$FIX/settings/green.json" "" --no-ghcp)" STUB_COPILOT_AUTH=rofs -- --no-record
doc_bg no-ghcp-none CLAUDE_CONFIG_DIR="$(doc_cfg no-ghcp-none "$FIX/settings/green.json" "" --no-ghcp)" STUB_COPILOT_AUTH=none -- --no-record
doc_bg agy-empty STUB_AGY_AUTH=0 -- --no-record
doc_bg agy-envelope STUB_AGY_AUTH=envelope -- --no-record
doc_bg agy-hang STUB_AGY_HANG=1 CX_PROBE_TIMEOUT=2 -- --no-record
doc_bg claude-out STUB_CLAUDE_LOGGED_IN=false -- --no-record
doc_bg gh-auth STUB_GH_AUTH=1 -- --no-record
doc_bg gh-nocop STUB_GH_NO_COPILOT=1 -- --no-record
doc_bg sib-default CLAUDE_CONFIG_DIR="$(doc_cfg sib-default "$SDEF" "$GROKB_ENTRY")" -- --no-record
doc_bg sib-policy-off CLAUDE_CONFIG_DIR="$(doc_cfg sib-policy-off "$SDEF")" CLAUDE_PLUGIN_OPTION_POLICY=off -- --no-record
doc_bg pins-unset -u COPILOT_AUTO_UPDATE -- --no-record
doc_bg billing COPILOT_MODEL=claude-opus-5.5 COPILOT_ALLOW_ALL=1 GH_TOKEN=ghp_x GITHUB_TOKEN=y XAI_API_KEY=k GEMINI_API_KEY=k GOOGLE_API_KEY=k ANTHROPIC_API_KEY=k -- --no-record
doc_bg token-only STUB_COPILOT_TOKEN_ONLY=GH_TOKEN GH_TOKEN=github_pat_x --
# Missing CLIs: a copy of the stub dir without copilot, grok and agy (the stubs find their
# fixtures through ../fixtures, so a link sits next to the copy), then a directory of links to
# only the system tools the doctor needs. Never $REAL_PATH: a real copilot, grok or agy there
# would run (network calls, an agy self-update), and the stub-log audit cannot see real binaries.
NOCLI="$TMP/stubs-nocli"
mkdir -p "$NOCLI"
for f in "$STUBS"/* "$STUBS/.stublib"; do [ -f "$f" ] && cp -p "$f" "$NOCLI/"; done
rm -f -- "$NOCLI/grok" "$NOCLI/agy" "$NOCLI/copilot"
ln -s "$FIX" "$TMP/fixtures"
SYS_BIN="$TMP/sys-bin"
mkdir -p "$SYS_BIN"
for t in bash sh env cat grep sed awk tr cut head tail mkdir mktemp rm rmdir dirname basename od wc sort uniq uname sleep \
         kill cp mv ln ls chmod date iconv tee timeout id stat readlink realpath touch find xargs python3 git setsid flock \
         sha256sum ps pgrep seq expr hostname nproc cmp diff; do
  p="$(PATH="$REAL_PATH" command -v "$t" 2>/dev/null)" && ln -sf "$p" "$SYS_BIN/$t"
done
NOCLI_PATH="$NOCLI:$SYS_BIN"
check "[X]   the missing-CLI PATH (stub copy + system tool links) resolves no copilot, grok or agy, real or stub" \
  eval '( PATH="$NOCLI_PATH"; for c in copilot grok agy; do command -v "$c" > /dev/null && exit 1; done; exit 0 )'
doc_bg missing PATH="$NOCLI_PATH" GHCP_COPILOT_BIN= -- --no-record
# D29: a grok that starts a helper by name (here copilot) works on the plain PATH but hits the
# worker shim (126) once the shims come first, as in every cx-run worker.
REEXEC="$TMP/stubs-reexec"
mkdir -p "$REEXEC"
for f in "$STUBS"/* "$STUBS/.stublib"; do [ -f "$f" ] && cp -p "$f" "$REEXEC/"; done
mv "$REEXEC/grok" "$REEXEC/grok-real"
printf '#!/usr/bin/env bash\ncopilot --version > /dev/null 2>&1 || exit 126\nexec "$(dirname -- "$0")/grok-real" "$@"\n' > "$REEXEC/grok"
chmod 0755 "$REEXEC/grok"
doc_bg reexec PATH="$REEXEC:$SYS_BIN" GHCP_COPILOT_BIN="$REEXEC/copilot" -- --no-record
doc_bg record-only -- --record-only
doc_bg install-rt -- --install-runtime
doc_bg missing-json PATH="$NOCLI_PATH" GHCP_COPILOT_BIN= -- --no-record --json
# On WSL a CLI found only on the Windows side (an npm shim under the automount root) never
# resolves; a GHCP_COPILOT_BIN there is ignored. The fakes log WINSIDE_RAN if anything runs them.
W8_MNT="$TMP/w8mnt"
W8_NPM="$W8_MNT/c/Users/me/AppData/Roaming/npm"
mkdir -p "$W8_NPM" "$W8_MNT/c/Windows"
for c in copilot grok claude; do
  printf '#!/bin/sh\necho WINSIDE_RAN %s >> %q\necho 1.0.105\n' "$c" "$TMP/w8.ran" > "$W8_NPM/$c"
  chmod 0777 "$W8_NPM/$c"
done
NOCLAUDE="$TMP/stubs-noclaude"
cp -a "$NOCLI" "$NOCLAUDE"; rm -f -- "$NOCLAUDE/claude"
doc_bg winside PATH="$NOCLAUDE:$SYS_BIN:$W8_NPM:$W8_MNT/c/Windows" GHCP_COPILOT_BIN="$W8_NPM/copilot" CX_MNT_ROOT="$W8_MNT/" \
  STUB_UNAME_S=Linux STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2 WSL_DISTRO_NAME=Ubuntu --
# Only the drive directories of the automount root are the Windows side: with [automount]
# root = / (for /c/... paths) every Linux path starts with the root, and a non-drive directory
# under the mount root (/mnt/data, /mnt/wsl) is a Linux mount. Both must still resolve.
mkdir -p "$TMP/wslconf-slash/etc"
printf '[automount]\nroot = /\n' > "$TMP/wslconf-slash/etc/wsl.conf"
doc_bg rootslash CX_DETECT_ROOT="$TMP/wslconf-slash" STUB_WSLPATH_ROOT=/ STUB_UNAME_S=Linux STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2 WSL_DISTRO_NAME=Ubuntu --
mkdir -p "$W8_MNT/data"
cp -a "$STUBS" "$ROOT/tests/fixtures" "$W8_MNT/data/"
doc_bg mntdata PATH="$W8_MNT/data/stubs:$SYS_BIN" GHCP_COPILOT_BIN="$W8_MNT/data/stubs/copilot" CX_MNT_ROOT="$W8_MNT/" \
  STUB_UNAME_S=Linux STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2 WSL_DISTRO_NAME=Ubuntu --
# WSL without WSL_DISTRO_NAME and with CX_HOME exported (an ssh session, a profile export).
SSHR="$(mkrepo sshremote)"; commit_all "$SSHR"
git -C "$SSHR" remote add origin git@github.com:me/sshremote.git; git -C "$SSHR" config commit.gpgsign true
DOC_CWD="$SSHR" doc_bg ssh-fwd CX_FORWARDED=1 CX_CALLER=gitbash -u SSH_AUTH_SOCK -- --no-record
doc_bg nodistro STUB_UNAME_S=Linux STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2 -u WSL_DISTRO_NAME STUB_WSLPATH_DISTRO= -- --no-record
# Forwarded-mode readers (CX_FORWARDED=1) and CRLF corruption (D3)
printf 'export PATH="$HOME/bin:$PATH"\nexport COPILOT_AUTO_UPDATE=false\nexport GROK_DISABLE_AUTOUPDATER="1"\nexport AGY_CLI_DISABLE_AUTO_UPDATE=true  # pin\n' > "$HOME/.profile"
printf '{"permissions": {"allow": ["Bash(cx-doctor:*)"]}}\n' > "$TMP/win-settings-partial.json"
doc_bg fwd-pins CX_FORWARDED=1 CX_CALLER=gitbash -u COPILOT_AUTO_UPDATE -u GROK_DISABLE_AUTOUPDATER -u AGY_CLI_DISABLE_AUTO_UPDATE CX_WIN_SETTINGS="$TMP/win-settings-partial.json" -- --no-record
crlf_copy "$TMP/crlf-policy" hooks/policy.sh
doc_bg crlf-policy CLAUDE_PLUGIN_ROOT="$TMP/crlf-policy" -- --no-record
SPR="$TMP/sp test/plug root"
crlf_copy "$SPR" hooks/policy.sh
chmod a-x "$SPR/bin/cx-wsl"
doc_bg crlf-space CLAUDE_PLUGIN_ROOT="$SPR" -- --no-record
ENC="$TMP/cfg-enclosing"
mkdir -p "$ENC/plugins/marketplaces"
cp "$FIX/settings/green.json" "$ENC/settings.json"; write_installed "$ENC"
git -C "$ENC" init -q
crlf_copy "$ENC/plugins/marketplaces/conductor-for-claude-code" templates/repo-bundle/AGENTS.md
doc_bg crlf-enclosing CLAUDE_CONFIG_DIR="$ENC" CLAUDE_PLUGIN_ROOT="$ENC/plugins/marketplaces/conductor-for-claude-code" -- --no-record
CLN="$TMP/cfg-clone"
mkdir -p "$CLN/plugins/marketplaces"
cp "$FIX/settings/green.json" "$CLN/settings.json"; write_installed "$CLN"
crlf_copy "$CLN/plugins/marketplaces/conductor-for-claude-code" skills/conductor/SKILL.md
git -C "$CLN/plugins/marketplaces/conductor-for-claude-code" init -q
doc_bg crlf-clone CLAUDE_CONFIG_DIR="$CLN" CLAUDE_PLUGIN_ROOT="$CLN/plugins/marketplaces/conductor-for-claude-code" -- --no-record
# The runtime copy as the doctor's own location (forwarded doctor): D3 checks the installed copy.
RTH="$TMP/rt-doctor-home"
run env CX_HOME="$RTH" bash "$ROOT/scripts/host/install-runtime.sh" --from "$ROOT"
RT_CFG="$DOCS/rt-installed/cfg"; mkdir -p "$RT_CFG"; cp "$FIX/settings/green.json" "$RT_CFG/settings.json"
write_installed "$RT_CFG" "$ROOT"
RT_CFG2="$DOCS/rt-none/cfg"; mkdir -p "$RT_CFG2"; cp "$FIX/settings/green.json" "$RT_CFG2/settings.json"; write_installed "$RT_CFG2"
DOCTOR="$RTH/runtime/$CXV/bin/cx-doctor" doc_bg rt-installed CX_HOME="$RTH" CX_FORWARDED=1 CLAUDE_CONFIG_DIR="$RT_CFG" -- --no-record
DOCTOR="$RTH/runtime/$CXV/bin/cx-doctor" doc_bg rt-none CX_HOME="$RTH" CX_FORWARDED=1 CLAUDE_CONFIG_DIR="$RT_CFG2" -- --no-record
# D27: a grok leader process is normal; a stray grok worker is reported (ps sees the whole
# machine, so the worker only runs after every other doctor run has finished).
( exec -a "/opt/grok/bin/grok leader --port 0" sleep 30 ) &
GL_PID=$!; BG_PIDS+=("$GL_PID")
sleep 0.2
doc_bg ps-leader -- --no-record
# --- P31 pools
mkdir -p "$TMP/pools-old"; printf '{"version": 1, "copilot_mtd_credits": 4321, "copilot_mtd_at": "2026-10-01T00:00:00Z"}\n' > "$TMP/pools-old/pools.json"
doc_bg pools -- --pools --no-record
doc_bg pools-usage -- --pools --agy-usage --no-record --json
doc_bg scrub STUB_ENV_FILE="$DOCS/scrub.env" GEMINI_API_KEY=g GOOGLE_API_KEY=g XAI_API_KEY=x GROK_SANDBOX=off \
  -u AGY_CLI_DISABLE_AUTO_UPDATE -u GROK_DISABLE_AUTOUPDATER -- --pools --agy-usage --no-record
doc_bg pools-noopus STUB_GHCP_MODELS_FILE="$FIX/ghcp-models-no-opus.json" -- --pools --no-record
doc_bg pools-set -- --pools --set-copilot-mtd 1234 --no-record
doc_bg pools-reserve CLAUDE_PLUGIN_OPTION_COPILOT_RESERVE_PCT=10 -- --pools --no-record
mkdir -p "$TMP/xdg-cache-ghcp/ghcp-claude"; cp "$FIX/ghcp-models.json" "$TMP/xdg-cache-ghcp/ghcp-claude/models.json"
touch -d '5 hours ago' "$TMP/xdg-cache-ghcp/ghcp-claude/models.json"
doc_bg pools-cache STUB_COPILOT_VERSION=1.0.106-1 XDG_CACHE_HOME="$TMP/xdg-cache-ghcp" -- --pools --no-record
mkdir -p "$DOCS/pools-old-reserve/cxhome" "$DOCS/pools-old-zero/cxhome"
cp "$TMP/pools-old/pools.json" "$DOCS/pools-old-reserve/cxhome/"; cp "$TMP/pools-old/pools.json" "$DOCS/pools-old-zero/cxhome/"
doc_bg pools-old-reserve CLAUDE_PLUGIN_OPTION_COPILOT_RESERVE_PCT=10 -- --pools --no-record
doc_bg pools-old-zero -- --pools --no-record
# --- session kinds, Work locally readiness (P49, P51): settings with the D31 blockers and D32 keys
mk_settings() {  # OUT KEY=JSON...: green.json plus top-level keys (JSON values)
  "$REAL_PY" -I - "$FIX/settings/green.json" "$@" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
out = sys.argv[2]
for kv in sys.argv[3:]:
    k, v = kv.split("=", 1)
    d[k] = json.loads(v)
open(out, "w").write(json.dumps(d, indent=1) + "\n")
PY
}
mk_settings "$TMP/s-allow.json" 'permissions={"deny": ["Task(antigravity:antigravity-delegate)", "Task(grok-build:grok-delegate)"], "allow": ["Workflow(conductor:opus-pools)", "Bash(cx-doctor:*)"]}'
mk_settings "$TMP/s-block.json" 'env={"DISABLE_GROWTHBOOK": "1"}' 'disableRemoteControl=true' 'ultracode=true'
doc_bg s-local CLAUDE_CONFIG_DIR="$(doc_cfg s-local "$TMP/s-allow.json")" CLAUDE_CODE_ENTRYPOINT=cli CLAUDE_CODE_DESKTOP_APP_VERSION=1.5.0 \
  CLAUDE_PROJECT_UUID=p-1 ANTHROPIC_BASE_URL=https://api.anthropic.com/ STUB_NPROC=8 -- --no-record
doc_bg s-byoc-local CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=byoc CLAUDE_PLUGIN_OPTION_EXEC_HOST=local \
  CLAUDE_CODE_SESSION_ATTENDED=0 STUB_NPROC=64 -- --no-record --json
doc_bg s-cloud CLAUDE_CODE_REMOTE=true CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE=cloud_default --
doc_bg s-cloud-json CLAUDE_CODE_REMOTE=yes -- --json
doc_bg s-byoc CLAUDE_CODE_REMOTE=1 CLAUDE_CODE_ENVIRONMENT_KIND=self_hosted -- --pools
doc_bg s-blockers CLAUDE_CONFIG_DIR="$(doc_cfg s-blockers "$TMP/s-block.json")" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  ANTHROPIC_BASE_URL=https://gw.example STUB_CLAUDE_VERSION=2.1.279 ANTHROPIC_API_KEY=k -- --no-record
mkdir -p "$DOCS/s-wsl/root/etc"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$DOCS/s-wsl/root/etc/os-release"
doc_bg s-wsl CX_DETECT_ROOT="$DOCS/s-wsl/root" WSL_DISTRO_NAME=Ubuntu STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2 \
  CLAUDECODE=1 CLAUDE_CODE_ENTRYPOINT=claude-desktop CLAUDE_CODE_DESKTOP_APP_VERSION=1.5.0 -- --no-record
doc_bg s-wsl-loaded CX_DETECT_ROOT="$DOCS/s-wsl/root" WSL_DISTRO_NAME=Ubuntu STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2 \
  CLAUDECODE=1 PATH="$ROOT/bin:$PATH" CLAUDE_CODE_ENTRYPOINT=claude-desktop CLAUDE_CODE_DESKTOP_APP_VERSION=1.5.0 -- --no-record
doc_bg s-wsl-term CX_DETECT_ROOT="$DOCS/s-wsl/root" WSL_DISTRO_NAME=Ubuntu STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2 \
  CLAUDE_CODE_ENTRYPOINT=claude-desktop CLAUDE_CODE_DESKTOP_APP_VERSION=1.5.0 -- --no-record
mk_settings "$TMP/s-broad.json" 'permissions={"allow": ["Bash(cx-wsl:*)", "Bash(cx-doctor:*)"]}'
doc_bg d25-broad-wsl CLAUDE_CONFIG_DIR="$(doc_cfg d25-broad-wsl "$TMP/s-broad.json")" -- --no-record
doc_bg d25-broad-win CX_FORWARDED=1 CX_CALLER=gitbash CX_WIN_SETTINGS="$TMP/s-broad.json" -- --no-record
doc_bg s-bridge CX_DETECT_ROOT="$DOCS/s-wsl/root" WSL_DISTRO_NAME=Ubuntu STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2 \
  CLAUDE_CODE_ENVIRONMENT_KIND=bridge CLAUDE_CODE_DESKTOP_APP_VERSION=1.5.0 CLAUDE_CODE_SESSION_ATTENDED=0 STUB_NPROC=3 -- --no-record
doc_bg login-help -- --login-help
doc_wait
kill "$GL_PID" 2>/dev/null
( exec -a "grok worker --pool x" sleep 30 ) &
GW_PID=$!; BG_PIDS+=("$GW_PID")
sleep 0.2
doc_bg ps-worker -- --no-record
# --- P25
doc_use green
check "[P25] all-green doctor: exit 0, no cross, CX_DOCTOR fail 0, no CX_SIGNAL" \
  eval 'rc_is 0 && no_fail_glyph && line_is CX_DOCTOR fail 0 && no_signal && tail -n 1 "$E" | grep -q "^CX_DOCTOR "'
check "[P25] the report: header, sections, a check per CLI, Summary line" \
  eval 'head -n 1 "$O" | grep -q "^conductor doctor $CXV: host linux" && out_has "Logins (free probes)" && d_ok D9 "copilot 1.0.105" && d_ok D10 "grok 1.0.70" && d_ok D16 "copilot is logged in" && d_ok D17 "grok is logged in" && d_ok D18 "agy is logged in" && d_ok D19 && d_ok D13 && d_ok D21 && d_ok D22 && d_ok D24 && grep -q "^Summary: [0-9]* ✓, [0-9]* !, 0 ✗$" "$O"'
check "[P25] stderr: CX_HOST, then CX_DOCTOR (with the record path)" \
  eval 'tj linejson "$E" CX_HOST && line_is CX_HOST host linux && line_is CX_DOCTOR record "$DHOME/hosts/$(tj line "$E" CX_HOST hostkey).json"'
REC_F="$DHOME/hosts/$(tj line "$E" CX_HOST hostkey 2>/dev/null).json"
check "[P25] host record: absolute bins (wrappers from the fake installPaths, the user-scoped ghcp entry)" \
  test "$("$REAL_PY" -I - "$REC_F" "$TMP" "$STUBS" <<'PY'
import json, os, sys
r = json.load(open(sys.argv[1])); tmp, stubs = sys.argv[2], sys.argv[3]
b = r["bin"]
print(r["version"] == 1 and r["plugin_version"] == os.environ["CXV"] and r["host"] == "linux" and r["path_source"] == "interactive"
      and all(isinstance(v, str) and v.startswith("/") for k, v in b.items() if k != "node")
      and b["copilot"] == stubs + "/copilot" and b["grok"] == stubs + "/grok"
      and b["ghcp_delegate"] == tmp + "/plugins/ghcp/bin/ghcp-delegate" and b["ghcp_models"] == tmp + "/plugins/ghcp/bin/ghcp-models"
      and b["agy_media"] == tmp + "/plugins/antigravity/bin/agy-media"
      and r["versions"] == {"claude": "2.1.316", "copilot": "1.0.105", "grok": "1.0.70", "agy": "1.4.12", "gh": "2.89.0"}
      and r["logins"]["copilot"]["direct"] is True and r["logins"]["grok"]["forwarded"] is None
      and r["copilot_token_env"] is None and r["plugins"]["ghcp@ghcp-for-claude-code"]["scope"] == "user")
PY
)" = True
check "[P25] host record .path: one line, absolute entries, no /mnt/, no plugin bin/ or worker-shims" \
  eval 'P=$(cat "${REC_F%.json}.path"); [ "$(wc -l < "${REC_F%.json}.path")" = 1 ] && [ -n "$P" ] && ! printf "%s" ":$P:" | grep -Eq ":/mnt/|:[^/:]|/plugins/(ghcp|antigravity)/bin:|worker-shims|$ROOT/bin:" && [ "$P" = "$(tj get "$REC_F" path)" ]'
doc_use green
check "[X]   D29 (free): copilot, grok and agy start with the worker shims first on PATH (one ok line); D32 prints the slot caps next to the workflow concurrency" \
  eval 'd_ok D29 "copilot, grok, agy start with the worker shims first on PATH" && d_info D32 "slot caps: cap_agy=2 cap_copilot=3 cap_grok=5 (shared by every session"'
doc_use reexec
check "[X]   D29: a CLI that starts a tool by name works on the plain PATH (D10 ok) but fails with the worker shims first -> ! D29 naming it, the others ok" \
  eval 'd_ok D10 "grok 1.0.70" && d_warn D29 "grok --version fails with the worker shims first on PATH (exit 126" && d_ok D29 "copilot, agy start with the worker shims first"'
doc_use green-json
check "[P25] --no-record writes nothing (no hosts/ dir), CX_DOCTOR record null" eval '[ ! -e "$DHOME/hosts" ] && line_is CX_DOCTOR record null'
check "[P33] --json parses and matches section 8.7 (keys, statuses in the enum), same exit as text mode (0)" \
  test "$("$REAL_PY" -I - "$O" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
ok = (list(d) == ["version", "plugin_version", "host", "caller", "session", "attended", "checks", "pools", "record", "summary"]
      and d["session"] == "local" and d["attended"] is None
      and d["version"] == 1 and d["plugin_version"] == os.environ["CXV"] and d["pools"] is None and d["record"] is None
      and set(d["host"]) == {"host", "hostkey", "distro", "os_id", "os_version", "wsl_version", "arch", "kernel", "session", "attended"}
      and all(set(c) == {"id", "section", "status", "text", "fix"} and c["status"] in ("ok", "warn", "fail", "info") for c in d["checks"])
      and d["summary"] == {"ok": sum(c["status"] == "ok" for c in d["checks"]), "warn": sum(c["status"] == "warn" for c in d["checks"]),
                           "fail": sum(c["status"] == "fail" for c in d["checks"])}
      and d["summary"]["fail"] == 0 and d["caller"] == "linux")
print(ok)
PY
)" = True
check "[P33] --json: rc 0, stdout is only the document" eval 'rc_is 0 && tj isjson "$O" && line_is CX_DOCTOR fail 0'
doc_use cop-pre-json
check "[P33] --json with a failed check: exit 4 like text mode, CX_SIGNAL CHECKS_FAILED last, fix field present" \
  eval 'rc_is 4 && one_signal CHECKS_FAILED && tj checks "$O" D9 fail "1.0.106-1" && tj checks "$O" D9 fail "npm install -g @github/copilot@1.0.105"'
# --- P26
doc_use cop-pre
check "[P26] copilot 1.0.106-1: cross D9, ! D16 login not probed, exit 4, CX_SIGNAL CHECKS_FAILED" \
  eval 'rc_is 4 && d_fail D9 "copilot 1.0.106-1 (pinned 1.0.105)" && d_warn D16 "login not probed" && one_signal CHECKS_FAILED && grep -q "fix: npm install -g @github/copilot@1.0.105" "$O"'
check "[P26] ... neither the copilot stub saw -p nor ghcp-models ran" \
  eval 'dlog_has "^copilot	.*argv: --version$" && ! dlog_has "^copilot	.*argv: -p" && ! dlog_has "^ghcp-models	"'
doc_use missing
check "[X]   missing CLIs: cross D9 copilot not found, D10 grok not found, D11 agy not found; D16 not probed; no D17/D18 probe" \
  eval 'rc_is 4 && d_fail D9 "copilot not found" && d_fail D10 "grok not found" && d_fail D11 "agy not found" && d_warn D16 "login not probed" && d_none D17 && d_none D18 && one_signal CHECKS_FAILED && ! dlog_has "^(copilot|grok|agy)	"'
doc_use record-only
check "[X]   --record-only: prints nothing, exit 0, writes the host record (versions, no login probes)" \
  eval 'rc_is 0 && out_empty && ! grep -q "^CX_" "$E" && [ "$(tj get "$(ls "$DHOME"/hosts/*.json)" versions.copilot)" = 1.0.105 ] && ! dlog_has "auth status|models|-p "'
doc_use install-rt
check "[X]   cx-doctor --install-runtime on the executor host installs from the plugin copy (CX_RUNTIME, exit 0)" \
  eval 'rc_is 0 && line_is CX_RUNTIME changed true && [ -f "$DHOME/runtime/$CXV/RUNTIME_STAMP" ] && grep -qx "source=$ROOT" "$DHOME/runtime/$CXV/RUNTIME_STAMP"'
doc_use missing-json
check "[X]   missing CLIs in --json: fail checks with their install fixes, exit 4" \
  eval 'rc_is 4 && tj checks "$O" D10 fail "grok not found" && tj checks "$O" D9 fail "npm install -g @github/copilot@1.0.105" && [ "$(tj get "$O" summary.fail)" -ge 3 ]'
doc_use winside
check "[X]   WSL: copilot, grok and claude found only under the automount root (Windows npm shims) do not resolve; their lines name the Windows path; GHCP_COPILOT_BIN there is ignored; nothing ran" \
  eval 'd_fail D9 "copilot not found" && d_fail D9 "only $W8_NPM/copilot on the Windows side" && d_warn D9 "GHCP_COPILOT_BIN=$W8_NPM/copilot is on the Windows side" && d_fail D10 "only $W8_NPM/grok on the Windows side" && d_warn D8 "only $W8_NPM/claude on the Windows side" && [ ! -e "$TMP/w8.ran" ]'
check "[X]   ... and the host record stores null for them (never a /mnt path)" \
  eval 'R="$DHOME/hosts/wsl-Ubuntu.json"; [ "$(tj get "$R" bin.copilot)" = null ] && [ "$(tj get "$R" bin.grok)" = null ] && [ "$(tj get "$R" bin.claude)" = null ] && ! grep -q "$W8_MNT" "$R"'
doc_use rootslash
check "[X]   WSL with [automount] root = / in /etc/wsl.conf: copilot, grok, agy and gh resolve (not 'on the Windows side'); the record stores them" \
  eval 'd_ok D9 "copilot" && d_ok D10 "grok" && d_ok D11 "agy" && ! grep -q "on the Windows side" "$O" && R="$DHOME/hosts/wsl-Ubuntu.json" && [ "$(tj get "$R" bin.copilot)" != null ] && [ "$(tj get "$R" bin.grok)" != null ] && [ "$(tj get "$R" bin.gh)" != null ]'
doc_use mntdata
check "[X]   WSL: CLIs in a non-drive directory under the mount root (<root>data/stubs, like /mnt/data/bin) resolve and are recorded; GHCP_COPILOT_BIN there is honoured" \
  eval 'd_ok D9 "copilot" && d_ok D10 "grok" && ! grep -q "on the Windows side" "$O" && R="$DHOME/hosts/wsl-Ubuntu.json" && [ "$(tj get "$R" bin.copilot)" = "$W8_MNT/data/stubs/copilot" ] && [ "$(tj get "$R" bin.grok)" = "$W8_MNT/data/stubs/grok" ]'
# wsl-resolve (cx-wsl) applies the same rule to recorded paths.
"$REAL_PY" -I - "$TMP/mnt-rec.json" "$W8_MNT/data/stubs/grok" "$W8_NPM/grok" "$STUBS/grok" <<'PY'
import json, sys
for i, p in enumerate(sys.argv[2:]):
    open(sys.argv[1] + ".%d" % i, "w").write(json.dumps({"bin": {"grok": p}, "path": "/usr/bin"}))
PY
MR_OUT=""
for a in "0 $W8_MNT/" "1 $W8_MNT/" "2 /"; do
  "$REAL_PY" -I "$CXLIB" wsl-resolve --record "$TMP/mnt-rec.json.${a%% *}" --tool grok --config-dir "$TMP/none" --conductor-bin "$ROOT/bin" --mnt-root "${a#* }" > /dev/null 2>&1
  MR_OUT="$MR_OUT$?"
done
check "[X]   wsl-resolve: a recorded tool under <root>data/ and, with mount root /, under \$TMP resolves (0); one in a drive directory <root>c/ is refused (4) (got $MR_OUT)" test "$MR_OUT" = 040
doc_use ssh-fwd
check "[X]   forwarded, in a repo with an SSH origin and commit.gpgsign=true: ! D5 no ssh-agent (HTTPS + gh auth setup-git fix) and ! D5 no passphrase prompt" \
  eval 'd_warn D5 "origin is an SSH remote (git@github.com:me/sshremote.git) and calls forwarded from Windows have no ssh-agent" && out_has "fix: use HTTPS with gh'"'"'s credential helper: gh auth setup-git" && d_warn D5 "commit.gpgsign=true: a forwarded call has no terminal"'
doc_use nodistro
check "[X]   WSL without WSL_DISTRO_NAME (wslpath names nothing): ! D1 the hostkey comes from os-release; CX_HOME other than ~/.conductor: ! D1 forwarded calls ignore it" \
  eval 'd_warn D1 "WSL_DISTRO_NAME is unset and wslpath -w / named no distribution" && d_warn D1 "calls forwarded from Windows ignore CX_HOME"'
doc_use grok73
check "[P26] grok 1.0.73: cross D10 with the grok update fix" eval 'rc_is 4 && d_fail D10 "grok 1.0.73" && out_has "fix: grok update --version 1.0.70"'
doc_use claude300
check "[P26] claude 2.1.300: ! D8, exit 0" eval 'rc_is 0 && d_warn D8 "claude 2.1.300 is older than 2.1.316" && no_fail_glyph'
doc_use agy119
check "[P26] agy 1.1.9: cross D11" eval 'rc_is 4 && d_fail D11 "agy 1.1.9"'
doc_use agy1111
check "[X]   agy 1.1.11: ! D11 (1.1.10-1.1.11)" eval 'rc_is 0 && d_warn D11 "agy 1.1.11"'
doc_use grok-unauth
check "[P26] grok unauthenticated: cross D17 naming grok login --device-auth" eval 'rc_is 4 && d_fail D17 "grok is not logged in" && out_has "fix: grok login --device-auth"'
doc_use grok-net
check "[P26] grok models rc 1 with a network error and no ids: ! D17 with that line (not ok)" \
  eval 'd_warn D17 "network is unreachable" && ! d_ok D17 "grok is logged in"'
doc_use ghcp-auth
check "[P26] ghcp-models rc 11: cross D16 with the copilot login fix" eval 'rc_is 4 && d_fail D16 "copilot is not logged in" && out_has "fix: copilot login"'
doc_use ghcp-sandbox
check "[P26] ghcp-models rc 16: cross D16 with the sandbox text" eval 'rc_is 4 && d_fail D16 "Bash sandbox" && out_has "outside Claude Code'"'"'s sandbox"'
doc_use ghcp-timeout
check "[X]   ghcp-models rc 12: ! D16 (timed out)" eval 'd_warn D16 "timed out"'
doc_use ghcp-catalog
check "[X]   ghcp-models rc 2: ! D16 (catalog unparseable)" eval 'd_warn D16 "unparseable"'
doc_use no-ghcp
check "[P26] ghcp absent: the copilot stub saw the free probe with --model __cx_doctor_probe__ and --disable-builtin-mcps" \
  eval 'dlog_has "^copilot	cwd=$DHOME/probe	.*argv: -p \\. --model __cx_doctor_probe__ --no-ask-user --no-auto-update --no-color --disable-builtin-mcps$" && d_ok D16 "copilot is logged in" && d_fail D13 "ghcp plugin is not installed"'
check "[X]   the raw probe unset GH_TOKEN/GITHUB_TOKEN (copilot stub saw neither)" eval 'dlog_has "^copilot	.*gh_token=	github_token=	argv: -p"'
doc_use no-ghcp-rofs
check "[X]   raw probe, Read-only file system: cross D16 (sandbox)" eval 'd_fail D16 "Bash sandbox"'
doc_use no-ghcp-none
check "[X]   raw probe, No authentication information found: cross D16 copilot login" eval 'd_fail D16 "not logged in" && out_has "fix: copilot login"'
doc_use agy-empty
check "[P26] agy models empty: cross D18" eval 'rc_is 4 && d_fail D18 "agy listed no models"'
doc_use agy-envelope
check "[X]   agy models printing a status envelope / a 'not signed in' line with rc 0: cross D18, not 'logged in'" \
  eval 'rc_is 4 && d_fail D18 "agy listed no models" && ! d_ok D18 "logged in"'
printf '%s' '{"status": "ERROR", "message": "You are not signed in..."}' > "$TMP/agy-envelope.json"
run "$REAL_PY" -I "$CXLIB" parse-models --cli agy "$TMP/agy-envelope.json"
check "[X]   parse-models --cli agy: an error envelope yields no ids and is not authenticated; a {slug: label} map still parses" \
  eval 'outj_is ids "[]" && ! outj_is authenticated true && printf "%s" "{\"claude-opus-5-5-high\": \"Claude Opus 5.5 (High)\"}" > "$TMP/agy-map.json" && run "$REAL_PY" -I "$CXLIB" parse-models --cli agy "$TMP/agy-map.json" && outj_is ids "[\"claude-opus-5-5-high\"]" && outj_is authenticated true'
doc_use agy-hang
check "[P26] agy hang (CX_PROBE_TIMEOUT=2): ! D18 hung, not a cross" eval 'd_warn D18 "hung" && ! d_fail D18'
doc_use claude-out
check "[P26] loggedIn false: ! D15, exit 0" eval 'rc_is 0 && d_warn D15 "claude is not logged in" && out_has "fix: claude auth login"'
doc_use gh-auth
check "[P26] gh auth rc 1: cross D19 with gh auth login --web" eval 'rc_is 4 && d_fail D19 "gh is not logged in" && out_has "fix: gh auth login --web"'
doc_use gh-nocop
check "[P26] gh without @copilot in pr edit --help: ! D12" eval 'd_warn D12 "cannot request @copilot reviews" && rc_is 0'
# --- P27
doc_use sib-default
check "[P27] ghcp options unset (default on): ! D21 with the exact claude plugin configure command" \
  eval 'd_warn D21 "coding_policy=on (default)" && grep -Fxq "      fix: printf '"'"'%s'"'"' '"'"'{\"coding_policy\":\"off\",\"delegation_nudge\":\"off\"}'"'"' | claude plugin configure ghcp@ghcp-for-claude-code --values-stdin" "$O"'
check "[P27] antigravity default timeout: ! D22 with its configure fix" \
  eval 'd_warn D22 "timeout=5m" && out_has "claude plugin configure antigravity@antigravity-for-claude-code --values-stdin"'
check "[P27] grok-build installed: both D23 warnings (SessionEnd on /clear, grok-delegate)" \
  eval 'd_warn D23 "SessionEnd hook also fires on /clear" && d_warn D23 "grok-build:grok-delegate is a proactive subagent"'
check "[P27] deny rules: the Agent(...) spelling is accepted; a missing one is ! D24 with the JSON to add" \
  eval 'd_ok D24 "antigravity:antigravity-delegate is denied" && d_warn D24 "grok-build:grok-delegate is not denied" && out_has "{\"permissions\": {\"deny\": [\"Task(grok-build:grok-delegate)\"]}}"'
check "[P27] allow rules missing: D25 info (no warning, never written)" \
  eval 'd_info D25 "autonomy allow rule(s) missing" && d_info D25 "Bash(cx-run:*)" && d_info D25 "Bash(cx-wsl grok:*)" && ! d_info D25 "Bash(ghcp-delegate:*)" && ! d_info D25 "agy:*)" && ! d_warn D25'
doc_use green
check "[P27] both sibling options off: ok D21 and D22" eval 'd_ok D21 && d_ok D22'
doc_use sib-policy-off
check "[P27] conductor policy=off: no overlap warning" eval '! d_warn D21 && d_info D21 "conductor policy is off"'
# --- P28
doc_use pins-unset
check "[P28] COPILOT_AUTO_UPDATE unset: ! D14 with the ~/.profile fix" eval 'd_warn D14 "COPILOT_AUTO_UPDATE is" && out_has "export COPILOT_AUTO_UPDATE=false"'
doc_use green
check "[P28] COPILOT_AUTO_UPDATE set and grok [cli] auto_update = false: ok D14" eval 'd_ok D14 "COPILOT_AUTO_UPDATE=false" && d_ok D14 "grok [cli] auto_update = false"'
doc_use billing
D28_BAD=""
for v in COPILOT_MODEL COPILOT_ALLOW_ALL GH_TOKEN GITHUB_TOKEN; do d_warn D28 "$v is set" || D28_BAD="$D28_BAD $v"; done
for v in XAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY ANTHROPIC_API_KEY; do d_warn D28 "$v is set: it bills an API account instead of the subscription" || D28_BAD="$D28_BAD $v"; done
check "[P28] COPILOT_*, GH_TOKEN/GITHUB_TOKEN and API keys set: ! D28 each (API keys: bills an API account)${D28_BAD:+ (missing:$D28_BAD)}" test -z "$D28_BAD"
doc_use token-only
check "[P28] Copilot logged in only through GH_TOKEN: ok D16, D28 info, copilot_token_env recorded" \
  eval 'd_ok D16 "logged in through GH_TOKEN" && d_info D28 "Copilot signs in through GH_TOKEN" && ! d_warn D28 "GH_TOKEN" && [ "$(tj get "$(ls "$DHOME"/hosts/*.json)" copilot_token_env)" = GH_TOKEN ]'
check "[X]   ... the first probe ran without GH_TOKEN, the second kept it" \
  eval '[ "$(grep -c "^ghcp-models	" "$DLOG")" = 2 ]'
doc_use fwd-pins
check "[P28] forwarded, the three exports in ~/.profile: ok D14 although the environment lacks them" \
  eval 'd_ok D14 "COPILOT_AUTO_UPDATE=false is exported in your WSL login files" && d_ok D14 "GROK_DISABLE_AUTOUPDATER=1 is exported" && d_ok D14 "AGY_CLI_DISABLE_AUTO_UPDATE=true is exported"'
check "[P27] forwarded: D25 reads CX_WIN_SETTINGS and lists the cx-wsl tool rules, never Bash(cx-wsl:*) (not the executor-host rules)" \
  eval 'd_info D25 "Bash(cx-wsl ghcp-ci-debug:*)" && d_info D25 "Bash(cx-wsl gh pr:*)" && ! d_info D25 "Bash(cx-wsl:*)" && ! d_info D25 "Bash(cx-wsl ghcp-delegate:*)" && ! d_info D25 "Bash(cx-wsl agy" && d_info D25 "the Windows-side settings" && ! d_info D25 "Bash(ghcp-cloud list:*)"'
check "[X]   forwarded with no host record: D2 info naming a doctor command that works in a plain WSL terminal (the runtime copy)" d_info D2 "run ~/.conductor/runtime/current/bin/cx-doctor once in a WSL terminal"
doc_use crlf-policy
check "[P29] a plugin copy with a CRLF hooks/policy.sh: cross D3 naming the file, the sed fix, then the folder-marketplace / archive fallback (no autocrlf advice)" \
  eval 'rc_is 4 && d_fail D3 "CRLF line endings in: $TMP/crlf-policy/hooks/policy.sh" && grep -Fxq "      fix: sed -i '"'"'s/\\r\$//'"'"' $TMP/crlf-policy/hooks/policy.sh" "$O" && grep -A2 "CRLF line endings in" "$O" | tail -n 1 | grep -Fq "fix: if the plugin comes from a folder (directory) marketplace edited with Windows tools, convert that source folder the same way" && out_has "claude plugin marketplace update conductor-for-claude-code && claude plugin update conductor@conductor-for-claude-code" && ! out_has "core.autocrlf input"'
doc_use crlf-space
fixline() { sed -n "s/^      fix: \($1.*\)\$/\1/p" "$O" | head -n 1; }
SP_SED="$(fixline "sed -i")" SP_CHMOD="$(fixline "chmod 0755")"
check "[P29] a plugin root with spaces: the D3 sed and chmod fix lines quote each path, and running them as printed repairs the copy" \
  eval '[ -n "$SP_SED" ] && [ -n "$SP_CHMOD" ] && d_fail D3 "not executable: $SPR/bin/cx-wsl" && bash -c "$SP_SED" && bash -c "$SP_CHMOD" && ! grep -q $'"'"'\r'"'"' "$SPR/hooks/policy.sh" && [ -x "$SPR/bin/cx-wsl" ]'
doc_use crlf-enclosing
check "[P29] a marketplace copy inside an enclosing repo (not its own toplevel): no git-based fix" \
  eval 'd_fail D3 "CRLF line endings in" && ! out_has "checkout-index" && ! grep -q "^      fix: git" "$O"'
doc_use crlf-clone
check "[P29] a real toplevel marketplace clone: the checkout-index fix, then plugin update" \
  eval 'd_fail D3 "CRLF line endings in" && out_has "fix: git -C $CLN/plugins/marketplaces/conductor-for-claude-code -c core.autocrlf=input checkout-index -a -f, then claude plugin update conductor@conductor-for-claude-code"'
check "[P29] no fix text anywhere in the doctor contains reset --hard or rm -r --cached" \
  eval '! grep -rnE "reset --hard|rm -r --cached|rm -rf --cached" "$ROOT/scripts" "$ROOT/hooks" "$ROOT/bin" && ! cat "$DOCS"/*/out | grep -Eq "reset --hard|rm -r --cached"'
doc_use rt-installed
check "[P29] a forwarded doctor running from the runtime copy checks the installed copy (no cross D3 for skills/ or commands/)" \
  eval 'd_ok D3 "plugin files complete, executable and LF ($ROOT)" && d_ok D4 && ! d_fail D3'
doc_use rt-none
check "[X]   ... with no installed copy on this host: D3 info (checked on Windows by W6)" eval 'd_info D3 "plugin files are checked on Windows by W6" && ! d_fail D3'
doc_use pools
check "[P31] --pools: agy Opus slugs from the fixture; Copilot claude-opus-5.5 enabled -> ok" \
  eval 'd_ok pools-agy "agy Opus lane claude-opus-5-5-high offered (Opus slugs: claude-opus-5-5-high, claude-opus-5-5-medium, claude-opus-5-5-low)" && d_ok pools-copilot "Copilot claude-opus-5.5 is enabled (D16 probe)"'
check "[P31] reserve 0 reported as off; a missing figure is info with copilot_reserve_pct=0" \
  eval 'd_info pools-copilot "copilot_reserve_pct=0: no reserve (U3)" && d_info pools-copilot "no Copilot month-to-date figure recorded" && ! d_warn pools-copilot'
check "[P31] without --agy-usage: no agy -p /usage call, an info line names the flag" \
  eval '! dlog_has "^agy	.*argv: -p /usage" && d_info pools-agy "pass --agy-usage"'
check "[P31] CX_POOLS parses (ASCII, default separators) and comes before CX_DOCTOR" \
  eval 'tj linejson "$E" CX_POOLS && line_is CX_POOLS copilot.opus_id_enabled true && line_is CX_POOLS copilot.reserve_pct 0 && line_is CX_POOLS grok.bulk_model_listed true && grep -n "^CX_" "$E" | tr "\n" " " | grep -Eq "CX_HOST .*CX_POOLS .*CX_DOCTOR"'
check "[X]   grok Claude ids are info only; the Cursor pool note is shown" eval 'd_info pools-grok "grok lists Claude ids claude-opus-5.5" && d_info pools-grok "drains the same weekly pool"'
doc_use pools-usage
check "[P31] --agy-usage adds exactly one agy -p /usage call (--json pools payload has the usage)" \
  eval '[ "$(grep -c "^agy	.*argv: -p /usage --output-format json$" "$DLOG")" = 1 ] && tj get "$O" pools.agy.usage.buckets.claude_gpt.remaining_percent | grep -qx 64'
doc_use pools-noopus
check "[P31] claude-opus-5.5 removed from the catalog -> cross pools-copilot" eval 'rc_is 4 && d_fail pools-copilot "Copilot claude-opus-5.5 is not enabled"'
doc_use pools-set
check "[P31] --set-copilot-mtd 1234 writes pools.json" \
  eval '[ "$(tj get "$DHOME/pools.json" copilot_mtd_credits)" = 1234 ] && [ "$(tj get "$DHOME/pools.json" version)" = 1 ] && d_info pools-copilot "recorded 1234 month-to-date" && line_is CX_POOLS copilot.mtd_credits 1234'
doc_use pools-reserve
check "[P31] a missing figure is ! with copilot_reserve_pct=10" eval 'd_warn pools-copilot "copilot_reserve_pct=10 needs one" && line_is CX_POOLS copilot.reserve_pct 10'
doc_use pools-old-reserve
check "[P31] an old figure is ! with copilot_reserve_pct=10" eval 'd_warn pools-copilot "older than copilot_mtd_max_age_days=3"'
doc_use pools-old-zero
check "[P31] ... and info with copilot_reserve_pct=0" eval 'd_info pools-copilot "month-to-date credits 4321 entered" && ! d_warn pools-copilot'
doc_use pools-cache
check "[P31] D16 not probed (unpinned copilot): the copilot pool comes from ghcp's cache file with its age; ghcp-models never runs" \
  eval 'd_ok pools-copilot "ghcp cache file, 5.0 h old" && ! dlog_has "^ghcp-models	" && ! dlog_has "^copilot	.*argv: -p"'
# --- P32 login help
doc_use scrub
SCRUB_BAD="$("$REAL_PY" -I - "$DOCS/scrub.env" <<'PY'
import sys
blocks, cur = {}, None
for ln in open(sys.argv[1], encoding="utf-8", errors="replace").read().split("\n"):
    if ln.startswith("== "):
        cur = ln[3:]
        blocks.setdefault(cur, []).append(set())
    elif cur and "=" in ln:
        blocks[cur][-1].add(ln)
bad = []
for env in blocks.get("agy", []):
    if any(v.startswith(("GEMINI_API_KEY=", "GOOGLE_API_KEY=")) for v in env) or "AGY_CLI_DISABLE_AUTO_UPDATE=true" not in env:
        bad.append("agy")
for env in blocks.get("grok", []):
    if any(v.startswith(("XAI_API_KEY=", "GROK_SANDBOX=")) for v in env) or "GROK_DISABLE_AUTOUPDATER=1" not in env:
        bad.append("grok")
if len(blocks.get("agy", [])) < 3 or len(blocks.get("grok", [])) < 2:
    bad.append("too few probes recorded: agy %d, grok %d" % (len(blocks.get("agy", [])), len(blocks.get("grok", []))))
print(" ".join(sorted(set(bad))))
PY
)"
check "[X]   with GEMINI_API_KEY, GOOGLE_API_KEY, XAI_API_KEY and GROK_SANDBOX exported and no pins: every agy probe (--version, models, -p /usage) and grok probe (--version, models) runs without them and with its auto-update pin${SCRUB_BAD:+: $SCRUB_BAD}" \
  eval 'test -z "$SCRUB_BAD" && dlog_has "^agy	.*argv: -p /usage"'
doc_use login-help
LH_BAD=""
for c in 'copilot login' 'grok login --device-auth' 'fresh login:   agy' 'gh auth login --web' 'claude auth login' 'verify (free): /conductor:doctor in a Claude Code session in WSL' 'runtime/current/bin/cx-doctor (create that copy once with' 'cx-wsl ghcp-* calls export it as' 'install -d -m 700 ~/.conductor/secrets && install -m 600 /dev/null ~/.conductor/secrets/copilot-token'; do
  out_has "$c" || LH_BAD="$LH_BAD [$c]"
done
check "[P32] --login-help contains every CLI's exact command${LH_BAD:+ (missing:$LH_BAD)}" eval '[ -z "$LH_BAD" ] && rc_is 0'
check "[P32] --login-help: no stub invoked, no CX_* line" eval '[ ! -s "$DLOG" ] && ! grep -q "^CX_" "$E"'
run env PATH="$NOPY_BIN" "$NOPY_BIN/bash" "$DOCTOR" --login-help grok
check "[P32] --login-help runs without python3; one CLI only" eval 'rc_is 0 && out_has "grok login --device-auth" && out_lacks "copilot login" && head -n 1 "$O" | grep -q "^Logins are per host: run these on the executor host"'
run env STUB_UNAME_S=MINGW64_NT-10.0-26100 PATH="$STUBS:$NOPY_BIN" "$NOPY_BIN/bash" "$DOCTOR" --login-help
check "[P32] the Git Bash variant starts with the WSL-terminal sentence" \
  eval 'rc_is 0 && head -n 1 "$O" | grep -Fxq "Logins are per host; open a WSL terminal (wsl.exe, or wsl.exe -d <distro> when wsl_distro is set) and run these there. The Windows side'"'"'s logins do not count."'
run "$DOCTOR" --login-help bogus
check "[X]   --login-help bogus -> usage error 1" eval 'rc_is 1 && no_signal'
run "$DOCTOR" --host docker
check "[X]   --host docker -> 43 HOST_UNSUPPORTED (v1.1)" eval 'rc_is 43 && one_signal HOST_UNSUPPORTED'
run "$DOCTOR" --host wsl --no-record
check "[X]   --host wsl on plain Linux -> 43" eval 'rc_is 43 && one_signal HOST_UNSUPPORTED'
run "$DOCTOR" --windows
check "[X]   --windows off Git Bash: '! --windows checks only run from Git Bash', exit 0" eval 'rc_is 0 && out_has "! --windows checks only run from Git Bash"'
run "$DOCTOR" --agy-usage
check "[X]   --agy-usage without --pools -> usage error 1" rc_is 1
run env CLAUDE_PLUGIN_OPTION_EXEC_HOST=wsl "$DOCTOR" --no-record
check "[X]   exec_host=wsl on a plain Linux host -> 43" eval 'rc_is 43 && one_signal HOST_UNSUPPORTED'

doc_wait
kill "$GW_PID" 2>/dev/null
doc_use ps-leader
check "[P27] a grok leader process: no D27 line" d_none D27
doc_use ps-worker
check "[P27] a grok worker process: ! D27 (CURSOR_WORKER_MSG)" d_warn D27 "registers this machine with Cursor"
# --- session kinds (P49, P51) and the D32 matrix (P59)
doc_use s-cloud
check "[P49] cloud session: cx-doctor prints its header, a cross D30 and the summary, a cloud session note, exits 43 with one CX_SIGNAL HOST_UNSUPPORTED last; no stub ran" \
  eval 'rc_is 43 && one_signal HOST_UNSUPPORTED && out_has "session cloud" && d_fail D30 "cloud session (cloud, environment cloud_default)" && out_has "Summary: 0 ${OKG}, 0 !, 1 ${FAILG}" && err_has "cx-doctor: cloud session (cloud): the executors and their logins are in WSL" && [ ! -s "$DLOG" ] && [ ! -d "$DHOME/hosts" ]'
doc_use s-cloud-json
check "[P49] ... with --json: stdout empty, the plain report on stderr, exit 43" eval 'rc_is 43 && out_empty && one_signal HOST_UNSUPPORTED && err_has "cloud session (cloud)" && [ ! -s "$DLOG" ]'
doc_use s-byoc
check "[P49] a BYOC or self-hosted runner (kind self_hosted) without exec_host=local: exit 43 before --pools probes anything" eval 'rc_is 43 && one_signal HOST_UNSUPPORTED && out_has "cloud session (byoc)" && [ ! -s "$DLOG" ]'
doc_use s-byoc-local
check "[P49] BYOC with option exec_host=local: no exit 43; the full doctor runs, info D30 byoc" eval 'rc_is 0 && tj checks "$O" D30 info "session byoc" && tj checks "$O" D9 ok && line_is CX_DOCTOR session byoc'
check "[P51] attended 0 (not bridge): info D30 unattended, D25 allow rules; --json has session and attended 0; 64 CPUs -> 16" \
  eval 'tj checks "$O" D30 info "unattended session" && [ "$(out_json session)" = byoc ] && [ "$(out_json attended)" = 0 ] && line_is CX_DOCTOR attended 0 && tj checks "$O" D32 info "workflow concurrency 16 agents"'
doc_use s-local
check "[P51] D30 local: entrypoint and desktop version printed; an attached claude.ai Project (CLAUDE_PROJECT_UUID) -> info; the header, CX_HOST and CX_DOCTOR carry session local" \
  eval 'rc_is 0 && d_info D30 "session local (entrypoint cli, desktop app 1.5.0)" && d_info D30 "a claude.ai Project is attached" && out_has ", session local" && line_is CX_DOCTOR session local && line_is CX_HOST session local && line_is CX_DOCTOR attended null'
check "[P51] D31: https://api.anthropic.com/ is not a blocker (prerequisites met); [P59] D32 workflows available, ultracode not set, concurrency 6 for 8 CPUs, the Workflow allow rule listed" \
  eval 'd_info D31 "Work locally prerequisites met here" && d_info D32 "workflows available" && d_info D32 "ultracode not set in the settings files" && d_info D32 "workflow concurrency 6 agents per workflow (min(16, max(2, 8 CPUs - 2))" && d_info D32 "Workflow allow rules: Workflow(conductor:opus-pools)"'
check "[X]   the Session section comes first and holds only info lines" \
  eval '[ "$(sed -n 3p "$O")" = Session ] && ! awk "/^Session\$/{s=1;next} /^[A-Z]/{s=0} s" "$O" | grep -q "^  [!$OKG$FAILG] "'
doc_use s-bridge
check "[P51] D30 bridge (a remote-control thread in WSL): a Remote Control child, the pool slots shared by every thread and session; never unattended; no desktop WSL-session warning; 3 CPUs -> concurrency 2" \
  eval 'd_info D30 "session bridge" && d_info D30 "the pool slots are shared by every thread and session on this computer" && ! d_info D30 "unattended" && ! d_warn D30 "desktop app session" && line_is CX_DOCTOR session bridge && line_is CX_DOCTOR attended null && d_info D32 "workflow concurrency 2 agents"'
doc_use s-blockers
check "[P51] D31: each blocker (env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, settings env DISABLE_GROWTHBOOK, disableRemoteControl, claude 2.1.279, a gateway ANTHROPIC_BASE_URL, ANTHROPIC_API_KEY) is an info line; the doctor still exits 0" \
  eval 'rc_is 0 && d_info D31 "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC is set (environment)" && d_info D31 "DISABLE_GROWTHBOOK is set (user settings" && d_info D31 "disableRemoteControl is true" && d_info D31 "claude 2.1.279 is older than 2.1.280" && d_info D31 "ANTHROPIC_BASE_URL=https://gw.example (environment)" && d_info D31 "ANTHROPIC_API_KEY is set" && ! d_info D31 "prerequisites met" && ! grep -Eq "^  [!$FAILG] .*\[D3[012]\]$" "$O"'
check "[P59] ultracode true in user settings -> on for new sessions (user settings)" d_info D32 "ultracode on for new sessions (user settings"
doc_use s-wsl
check "[P51] a desktop app session in WSL whose PATH lacks the plugin bin/: ! D30 not loaded in this session, with the Windows-folder / WSL terminal / remote-control fix" \
  eval 'd_warn D30 "has not loaded the conductor plugin" && out_has "fix: open the repo in a desktop session on a Windows folder" && out_has "claude remote-control from a WSL terminal"'
doc_use s-wsl-loaded
check "[P51] a desktop app session in WSL with the plugin bin/ on PATH: ✓ D30 loaded in this session, no warning (live run 2026-11-01)" \
  eval 'd_ok D30 "the conductor plugin is loaded in this session" && ! d_warn D30 "not loaded"'
doc_use s-wsl-term
check "[P51] desktop signals without CLAUDECODE (not a Claude Code Bash call): no D30 plugin line either way" \
  eval '! d_warn D30 "conductor plugin" && ! d_ok D30 "conductor plugin"'
doc_use d25-broad-wsl
check "[P27] Bash(cx-wsl:*) in this host's settings: ! D25 remove it (a WSL session needs only the cx-wsl tool rules listed); not among the suggested rules" \
  eval 'd_warn D25 "remove it: a session in WSL needs only the cx-wsl tool rules listed" && ! d_info D25 "Bash(cx-wsl:*)"'
doc_use d25-broad-win
check "[P27] forwarded, Bash(cx-wsl:*) in the Windows-side settings: ! D25 replace it with the cx-wsl tool rules" \
  eval 'd_warn D25 "replace it with the tool rules Bash(cx-wsl ghcp-ci-debug:*)" && d_info D25 "Bash(cx-wsl gh pr:*)"'
}
bg_section doctor sec_doctor

# ------------------------------------------------------------------ 3. emitters (section 4)
section "CX_* emitters, signals and the exit table"
U2028=$'\xe2\x80\xa8'
LONG="$(printf 'x%.0s' $(seq 1 300))"
run bash -c '. "$1/scripts/lib/common.sh"; cx_emit TEST s "é—✓ x" n:int 5 f:num 2.5 b:bool true j:json "[1, 2]" z:null "" reason "$2"' _ "$ROOT" $'a\r\nb\tc'"$U2028"'d'
check "[P8]  cx_emit: one CX_TEST line with default separators and ensure_ascii" \
  eval '[ "$(wc -l < "$E")" = 1 ] && tj linejson "$E" CX_TEST && grep -q "^CX_TEST {\"s\": \"\\\\u00e9\\\\u2014\\\\u2713 x\", \"n\": 5, " "$E"'
check "[P8]  cx_emit: typed keys :int :num :bool :json :null" \
  eval 'line_is CX_TEST n 5 && line_is CX_TEST f 2.5 && line_is CX_TEST b true && line_is CX_TEST j "[1, 2]" && line_is CX_TEST z null'
check "[P8]  reason sanitizing: CR, LF, TAB and U+2028 collapse to one space" line_is CX_TEST reason "a b c d"
run bash -c '. "$1/scripts/lib/common.sh"; CX_PROG=cx-init; cx_signal FAILED 2 "$2"' _ "$ROOT" "$LONG"
check "[P8]  a long reason is cut to 200 characters ending in ..." \
  eval '[ "$(tj line "$E" CX_SIGNAL reason | wc -c)" = 201 ] && tj line "$E" CX_SIGNAL reason | grep -q "xxx\.\.\.$" && rc_is 2'
check "[X]   cx_signal with python3: cmd, exit and status keys" eval 'line_is CX_SIGNAL cmd cx-init && line_is CX_SIGNAL exit 2 && line_is CX_SIGNAL status FAILED'
run env PATH="$NOPY_BIN" bash -c '. "$1/scripts/lib/common.sh"; CX_PROG=cx-init; printf "earlier\n" >&2; cx_signal TIMEOUT 12 "variable \"text\" \\ with \$HOME"' _ "$ROOT"
check "[P9]  cx_signal without python3: the hand-built line parses, is the last stderr line, exit 12" \
  eval 'rc_is 12 && one_signal TIMEOUT && tj linejson "$E" CX_SIGNAL && line_is CX_SIGNAL exit 12 && line_is CX_SIGNAL cmd cx-init'
check "[P9]  ... and holds only constant text (the variable reason goes to a plain note before it)" \
  eval 'line_is CX_SIGNAL reason "the wall clock expired" && line_is CX_SIGNAL retry null && grep -q "^cx-init: variable \"text\"" "$E" && ! grep "^CX_SIGNAL" "$E" | grep -q variable'
run env PATH="$NOPY_BIN" bash -c '. "$1/scripts/lib/common.sh"; CX_PROG=whatever; cx_signal EXISTS 5 ""' _ "$ROOT"
check "[X]   cx_signal without python3: unknown program -> cmd cx; constant retry kept" \
  eval 'rc_is 5 && line_is CX_SIGNAL cmd cx && line_is CX_SIGNAL retry "cx-init --force (rewrites only the conductor block or routes.json)"'
TABLE="$("$REAL_PY" -I - "$ROOT/docs/DESIGN.md" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
sec = text.split("### 4.1 Exit codes", 1)[1].split("### 4.2", 1)[0]
for m in re.finditer(r"^\| (\d+) \| (?:`([A-Z_]+)`|—[^|]*) \|", sec, re.M):
    print("%s=%s" % (m.group(1), m.group(2) or ""))
PY
)"
run bash -c '. "$1/scripts/lib/common.sh"; while IFS== read -r n s; do printf "%s=%s\n" "$n" "$(cx_status_for_exit "$n")"; done <<< "$2"' _ "$ROOT" "$TABLE"
check "[P10] cx_status_for_exit covers every row of the section 4.1 table (0, 1 and 126 have none)" \
  eval '[ "$(cat "$O")" = "$TABLE" ] && [ "$(printf "%s\n" "$TABLE" | wc -l)" -ge 30 ]'
EXIT_AUDIT="$("$REAL_PY" -I - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
for rel in ("scripts/cx-doctor.sh", "scripts/cx-init.sh", "scripts/cx-wsl.sh", "scripts/cx-run.sh", "scripts/cx-job.sh", "scripts/host/detect.sh",
            "scripts/host/pathmap.sh", "scripts/host/forward-wsl.sh", "scripts/host/install-runtime.sh",
            "scripts/host/wsl-entry.sh"):
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        bad.append("%s: missing" % rel)
        continue
    lines = open(p, encoding="utf-8").read().split("\n")
    head = []
    for ln in lines[1:]:
        if not ln.startswith("#"):
            break
        head.append(ln)
    h = " ".join(head)
    if "Exit codes" not in h:
        bad.append("%s: no Exit codes paragraph" % rel)
        continue
    listed = set(re.findall(r"(?<![\w.-])(\d{1,3})(?![\w.-])", h.split("Exit codes", 1)[1]))
    body = "\n".join(l for l in lines if not l.lstrip().startswith("#"))
    used = set(re.findall(r"cx_signal [A-Z_]+ (\d+)", body))
    used |= set(re.findall(r"(?m)(?:^\s*|[;{]\s*|\bthen\s+|\belse\s+|\|\|\s*|&&\s*)exit (\d+)\b", body))
    missing = sorted(used - listed - {"0"}, key=int)
    if missing:
        bad.append("%s: returns %s but its header does not list it" % (rel, ",".join(missing)))
print("\n".join(bad))
PY
)"
check "[P10] each script header lists every code the script returns${EXIT_AUDIT:+ ($(printf '%s' "$EXIT_AUDIT" | tr '\n' ';'))}" test -z "$EXIT_AUDIT"

# ------------------------------------------------------------------ 4. pathmap (section 7.2)
section "pathmap: the section 7.2 example table, both forms, refusals"
# Rows straight from DESIGN.md's example table: MODE<TAB>ARGS<TAB>INPUT<TAB>EXPECTED (or "!refuse").
PM_ROWS="$("$REAL_PY" -I - "$ROOT/docs/DESIGN.md" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
sec = text.split("### 7.2 `pathmap.sh`", 1)[1].split("### 7.3", 1)[0]
tab = sec.split("| Mode | Input | Output |", 1)[1].split("\n\n", 1)[0]
for ln in tab.split("\n"):
    if not ln.startswith("| ") or ln.startswith("|---"):
        continue
    cells = [c.strip() for c in ln.strip().strip("|").split(" | ")]
    if len(cells) != 3:
        continue
    mode, inp, outp = cells
    m = re.match(r"(to-wsl|to-win|to-gitbash)(.*)", mode)
    verb, rest = m.group(1), m.group(2)
    args = []
    if "caller win" in rest: args = ["--caller", "win"]
    if "caller gitbash" in rest: args = ["--caller", "gitbash"]
    if "caller wsl" in rest: args = ["--caller", "wsl"]
    mm = re.search(r"--mnt-root (\S+?)`", rest)
    if mm: args = ["--mnt-root", mm.group(1)]
    if "--mixed" in rest: args = ["--mixed"]
    callers = [args]
    if "any" in rest: callers = [["--caller", c] for c in ("win", "gitbash", "wsl")]
    i = re.fullmatch(r"`(.*)`", inp)
    inp = i.group(1) if i else ""
    o = re.fullmatch(r"`(.*)`", outp)
    exp = o.group(1) if o else "!refuse"
    for a in callers:
        print("\x1f".join([verb, " ".join(a), inp, exp]))
PY
)"
PM_N="$(printf '%s\n' "$PM_ROWS" | grep -c .)"
pm_table() {  # FORM (cli|sourced): prints the failing rows
  local verb args inp exp got rc
  while IFS=$'\x1f' read -r verb args inp exp; do
    # shellcheck disable=SC2086  # ARGS is a space-separated option list
    if [ "$1" = cli ]; then
      got="$(env -u WSL_DISTRO_NAME -u CX_WSL_DISTRO -u CX_MNT_ROOT bash "$PATHMAP" "$verb" --distro Ubuntu $args -- "$inp" 2>"$TMP/pm.err")"; rc=$?
    else
      got="$(env -u WSL_DISTRO_NAME -u CX_WSL_DISTRO -u CX_MNT_ROOT bash -c '. "$1"; v="$2"; shift 2; f="cx_path_${v//-/_}"; "$f" "$@" 2>/dev/null; rc=$?; [ $rc = 42 ] && printf "%s" "$CX_PATHMAP_ERR" >&2; exit $rc' _ "$PATHMAP" "$verb" --distro Ubuntu $args -- "$inp" 2>"$TMP/pm.err")"; rc=$?
    fi
    if [ "$exp" = "!refuse" ]; then
      if [ "$rc" != 42 ] || [ -n "$got" ] || ! [ -s "$TMP/pm.err" ]; then printf '%s %s [%s]: rc %s, got %s\n' "$verb" "$args" "$inp" "$rc" "$got"; fi
      if [ "$1" = cli ] && ! grep -q '^pathmap: ' "$TMP/pm.err"; then printf '%s %s [%s]: no pathmap: reason\n' "$verb" "$args" "$inp"; fi
    elif [ "$rc" != 0 ] || [ "$got" != "$exp" ]; then
      printf '%s %s [%s]: rc %s, got [%s], want [%s]\n' "$verb" "$args" "$inp" "$rc" "$got" "$exp"
    fi
  done <<< "$PM_ROWS"
}
PM_BAD="$(pm_table cli)"
check "[P11] every row of the pathmap example table, CLI form ($PM_N rows; refusals exit 42 with a pathmap: reason)${PM_BAD:+: $(printf '%s' "$PM_BAD" | head -n 5 | tr '\n' ';')}" \
  eval '[ -z "$PM_BAD" ] && [ "$PM_N" -ge 48 ]'
PM_BAD="$(pm_table sourced)"
check "[P11] every row of the pathmap example table, sourced form (rc 42 and CX_PATHMAP_ERR)${PM_BAD:+: $(printf '%s' "$PM_BAD" | head -n 5 | tr '\n' ';')}" test -z "$PM_BAD"
pm() { run env -u WSL_DISTRO_NAME -u CX_WSL_DISTRO -u CX_MNT_ROOT bash "$PATHMAP" "$@"; }
pm to-wsl --caller win -- '\\wsl.localhost\Ubuntu\home\me'
check "[P11] no --distro, WSL_DISTRO_NAME or CX_WSL_DISTRO: T6 refuses with 'distro unknown'" eval 'rc_is 42 && err_has "pathmap: distro unknown"'
check "[X]   a CLI refusal prints one CX_SIGNAL PATH_UNMAPPABLE, last (cmd pathmap)" eval 'one_signal PATH_UNMAPPABLE && line_is CX_SIGNAL cmd pathmap'
run env STUB_UNAME_S=MINGW64_NT-10.0-26100 bash "$PATHMAP" to-wsl --caller win -- '\\server\share\x'
check "[X]   ... also on Git Bash (the constant line, after the pathmap: reason)" eval 'rc_is 42 && one_signal PATH_UNMAPPABLE && err_has "pathmap: network share" && [ "$(grep -c "^pathmap: " "$E")" = 1 ]'
pm to-win /home/me
check "[P11] ... and to-win /home/me refuses with 'distro unknown'" eval 'rc_is 42 && err_has "distro unknown"'
pm to-win /mnt/c/Users/me
check "[P11] ... while drive mappings still work" eval 'rc_is 0 && [ "$(cat "$O")" = "C:\\Users\\me" ]'
run env WSL_DISTRO_NAME=Ubuntu bash "$PATHMAP" to-win /home/me
check "[X]   the distro defaults to WSL_DISTRO_NAME" eval '[ "$(cat "$O")" = "\\\\wsl.localhost\\Ubuntu\\home\\me" ]'
run env -u WSL_DISTRO_NAME CX_WSL_DISTRO=Debian bash "$PATHMAP" to-win /home/me
check "[X]   ... else CX_WSL_DISTRO" eval '[ "$(cat "$O")" = "\\\\wsl.localhost\\Debian\\home\\me" ]'
mkdir -p "$TMP/wslconf-root/etc"
printf '[boot]\nsystemd=true\n[automount]\n  root = "/drives/"  # comment\noptions = "metadata"\n' > "$TMP/wslconf-root/etc/wsl.conf"
run env -u CX_MNT_ROOT CX_DETECT_ROOT="$TMP/wslconf-root" bash "$PATHMAP" to-wsl --caller win -- 'D:\x'
check "[P11] [automount] root from /etc/wsl.conf under CX_DETECT_ROOT is honoured" eval '[ "$(cat "$O")" = "/drives/d/x" ]'
run env CX_MNT_ROOT=/m CX_DETECT_ROOT="$TMP/wslconf-root" bash "$PATHMAP" to-wsl --caller win -- 'D:\x'
check "[X]   CX_MNT_ROOT beats wsl.conf (and gets its trailing /)" eval '[ "$(cat "$O")" = "/m/d/x" ]'
run env CX_DETECT_ROOT="$TMP/wslconf-root" bash "$PATHMAP" to-win /drives/e/y
check "[X]   to-win uses the same mount root" eval '[ "$(cat "$O")" = "E:\\y" ]'
pm to-wsl --caller win --distro Ubuntu -- 'C:\Users\Jöhn Smith\été — ✓\x y.txt'
check "[X]   spaces and non-ASCII survive to-wsl" eval '[ "$(cat "$O")" = "/mnt/c/Users/Jöhn Smith/été — ✓/x y.txt" ]'
pm to-win --distro Ubuntu '/home/me/été — ✓/x y'
check "[X]   spaces and non-ASCII survive to-win" eval '[ "$(cat "$O")" = "\\\\wsl.localhost\\Ubuntu\\home\\me\\été — ✓\\x y" ]'
pm to-wsl --caller win -- $'C:\\x\ny'
check "[X]   T1: a path with LF is refused" eval 'rc_is 42 && err_has "pathmap:"'
pm to-wsl --caller gitbash --distro Ubuntu -- '-weird'
check "[X]   a relative path starting with - maps after -- (stays relative)" eval 'rc_is 0 && [ "$(cat "$O")" = "-weird" ]'
pm to-wsl --caller win -- 'wsl:relative'
check "[X]   T2: wsl:<relative> is refused" rc_is 42
pm bogus x
check "[X]   unknown mode -> usage error 1" eval 'rc_is 1 && err_has "pathmap: try --help"'

# ------------------------------------------------------------------ 5. detect (section 7.1)
section "host detection matrix"
DR="$TMP/detect"
mkroot() {  # NAME [FILE...]: a fresh fake root holding the given empty files
  local n="${1:?}" f
  shift
  rm -rf -- "${DR:?}/${n:?}"
  mkdir -p "$DR/$n"
  for f in "$@"; do mkdir -p "$DR/$n/$(dirname "$f")"; : > "$DR/$n/$f"; done
}
det() {  # ROOT ENV... : runs detect.sh --shell with the stubbed uname
  local r="$1"
  shift
  run env -u WSL_DISTRO_NAME -u container -u COMPOSE_PROJECT_NAME -u MSYSTEM STUB_UNAME_N=box CX_DETECT_ROOT="$DR/$r" "$@" bash "$DETECT" --shell
}
d_is() { grep -Fxq -- "$1" "$O"; }
mkroot empty
det empty STUB_UNAME_S=MINGW64_NT-10.0-26100
check "[P12] MINGW64_NT-... -> gitbash (os_id windows, version from uname)" eval 'd_is CX_HOST=gitbash && d_is CX_OS_ID=windows && d_is CX_OS_VERSION=10.0-26100 && d_is CX_HOSTKEY=gitbash-box'
det empty STUB_UNAME_S=MSYS_NT-10.0-26100
check "[P12] MSYS_NT-... -> gitbash" d_is CX_HOST=gitbash
det empty STUB_UNAME_S=CYGWIN_NT-10.0-26100
check "[P12] CYGWIN_NT-... -> cygwin" d_is CX_HOST=cygwin
det empty STUB_UNAME_S=Darwin
check "[P12] Darwin -> macos" eval 'd_is CX_HOST=macos && d_is CX_HOSTKEY=macos-box'
det empty STUB_UNAME_S=FreeBSD
check "[X]   anything but Linux -> unknown" d_is CX_HOST=unknown
mkroot ubuntu
mkdir -p "$DR/ubuntu/etc"
printf 'NAME="Ubuntu"\nID=ubuntu\nVERSION_ID="24.04"\nID_LIKE=debian\n' > "$DR/ubuntu/etc/os-release"
det ubuntu STUB_UNAME_S=Linux STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2 WSL_DISTRO_NAME=Ubuntu-24.04
check "[P12] Linux + WSL_DISTRO_NAME + 6.6.87.2-microsoft-standard-WSL2 -> wsl/2 (distro, os-release quoting, hostkey)" \
  eval 'd_is CX_HOST=wsl && d_is CX_WSL_VERSION=2 && d_is CX_DISTRO=Ubuntu-24.04 && d_is CX_OS_ID=ubuntu && d_is CX_OS_VERSION=24.04 && d_is CX_HOSTKEY=wsl-Ubuntu-24.04'
mkroot interop proc/sys/fs/binfmt_misc/WSLInterop
mkdir -p "$DR/interop/etc"; printf "ID='debian'\nVERSION_ID='12'\n" > "$DR/interop/etc/os-release"
det interop STUB_UNAME_S=Linux STUB_UNAME_R=5.15.167.4-microsoft-standard-WSL2 STUB_WSLPATH_DISTRO=
check "[P12] Linux + WSLInterop only, wslpath -w / failing -> wsl (distro from os-release, single quotes stripped)" \
  eval 'd_is CX_HOST=wsl && d_is CX_DISTRO=debian && d_is CX_OS_VERSION=12 && d_is CX_HOSTKEY=wsl-debian'
det interop STUB_UNAME_S=Linux STUB_UNAME_R=5.15.167.4-microsoft-standard-WSL2 STUB_WSLPATH_DISTRO=Debian-12
check "[P12] WSL without WSL_DISTRO_NAME (ssh, su -, cron): the registered name from wslpath -w /, the hostkey forwarded calls use" \
  eval 'd_is CX_HOST=wsl && d_is CX_DISTRO=Debian-12 && d_is CX_HOSTKEY=wsl-Debian-12'
det interop STUB_UNAME_S=Linux STUB_UNAME_R=5.15.167.4-microsoft-standard-WSL2 STUB_WSLPATH_DISTRO=Debian STUB_WSLPATH_LEGACY=1
check "[X]   ... also from the legacy \\\\wsl\$\\ form" eval 'd_is CX_DISTRO=Debian && d_is CX_HOSTKEY=wsl-Debian'
mkroot late proc/sys/fs/binfmt_misc/WSLInterop-late
det late STUB_UNAME_S=Linux STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2
check "[X]   WSLInterop-late counts too" d_is CX_HOST=wsl
det empty STUB_UNAME_S=Linux STUB_UNAME_R=4.4.0-19041-Microsoft WSL_DISTRO_NAME=Legacy
check "[P12] 4.4.0-19041-Microsoft -> wsl/1" eval 'd_is CX_HOST=wsl && d_is CX_WSL_VERSION=1'
det empty STUB_UNAME_S=Linux STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2
check "[X]   Linux + microsoft kernel without interop -> wsl (interop disabled)" d_is CX_HOST=wsl
mkroot dockerenv .dockerenv
det dockerenv STUB_UNAME_S=Linux STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2 WSL_DISTRO_NAME=Ubuntu
check "[P12] Linux + .dockerenv + WSL2 kernel -> docker (checked before WSL)" d_is CX_HOST=docker
mkroot cgroup
mkdir -p "$DR/cgroup/proc/1"; printf '0::/system.slice/docker-0123abcd.scope\n' > "$DR/cgroup/proc/1/cgroup"
det cgroup STUB_UNAME_S=Linux STUB_UNAME_R=6.1.0 COMPOSE_PROJECT_NAME='my proj'
check "[P12] cgroup docker -> docker; hostkey from COMPOSE_PROJECT_NAME, sanitized" eval 'd_is CX_HOST=docker && d_is CX_HOSTKEY=docker-my_proj'
det empty STUB_UNAME_S=Linux STUB_UNAME_R=6.1.0 container=podman
check "[X]   container=podman -> docker" d_is CX_HOST=docker
mkroot containerenv run/.containerenv
det containerenv STUB_UNAME_S=Linux STUB_UNAME_R=6.1.0
check "[X]   /run/.containerenv -> docker" d_is CX_HOST=docker
det ubuntu STUB_UNAME_S=Linux STUB_UNAME_R=6.1.0-13-amd64 STUB_UNAME_N='büx 1/2'
check "[P12] plain Linux -> linux; hostkey characters outside [A-Za-z0-9._-] become _" eval 'd_is CX_HOST=linux && d_is CX_HOSTKEY=linux-b__x_1_2 && d_is CX_DISTRO=ubuntu'
run env STUB_UNAME_S=Linux STUB_UNAME_R=6.1.0 CX_DETECT_ROOT="$DR/empty" bash "$DETECT" --field host
check "[X]   --field host" eval '[ "$(cat "$O")" = linux ]'
run env STUB_UNAME_S=Linux STUB_UNAME_R=6.1.0 CX_DETECT_ROOT="$DR/empty" bash "$DETECT" --emit
check "[X]   --emit prints one CX_HOST line (wsl_version null on plain Linux)" eval 'line_is CX_HOST host linux && line_is CX_HOST wsl_version null && tj linejson "$E" CX_HOST'
run env STUB_UNAME_S=MINGW64_NT-10.0-26100 CX_DETECT_ROOT="$DR/empty" bash "$DETECT" --json
check "[X]   --json on Git Bash -> exit 2 with a note (never python there)" eval 'rc_is 2 && one_signal FAILED'
# cx_session / cx_attended truth tables (section 7.1): REMOTE KIND ATTENDED -> SESSION ATTENDED.
mkdir -p "$TMP/p48-interop/proc/sys/fs/binfmt_misc"; : > "$TMP/p48-interop/proc/sys/fs/binfmt_misc/WSLInterop"
P48_BAD=""
while IFS='|' read -r r k a ws wa; do
  out="$(env -u CLAUDE_CODE_REMOTE -u CLAUDE_CODE_ENVIRONMENT_KIND -u CLAUDE_CODE_SESSION_ATTENDED \
    ${r:+CLAUDE_CODE_REMOTE="$r"} ${k:+CLAUDE_CODE_ENVIRONMENT_KIND="$k"} ${a:+CLAUDE_CODE_SESSION_ATTENDED="$a"} \
    bash -c '. "$1"; cx_session; cx_attended; printf "%s|%s" "$CX_SESSION" "$CX_ATTENDED"' _ "$DETECT")"
  [ "$out" = "$ws|$wa" ] || P48_BAD="$P48_BAD [$r/$k/$a: $out]"
done <<'ROWS'
|||local|
true|||cloud|
TRUE|||cloud|
 1 |||cloud|
yes|||cloud|
On|||cloud|
 true |||cloud|
true|byoc||byoc|
true|self_hosted||byoc|
true|bridge||bridge|
|bridge||bridge|
false|||local|
0|||local|
false|byoc||local|
||1|local|1
||0|local|0
|bridge|0|bridge|
true|bridge|1|bridge|1
||yes|local|
ROWS
P48_BAD2=""
for kv in "STUB_UNAME_S=MINGW64_NT-10.0-26100" "STUB_UNAME_S=MSYS_NT-10.0" "STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2" "WSL_DISTRO_NAME=Ubuntu" "CX_DETECT_ROOT=$TMP/p48-interop"; do
  for k in "" byoc self_hosted; do
    out="$(env CLAUDE_CODE_REMOTE=true ${k:+CLAUDE_CODE_ENVIRONMENT_KIND="$k"} "$kv" bash -c '. "$1"; cx_session; printf "%s" "$CX_SESSION"' _ "$DETECT")"
    [ "$out" = local ] || P48_BAD2="$P48_BAD2 [$kv/$k: $out]"
  done
done
check "[P48] cx_session never answers cloud or byoc on the user's computer: Git Bash (MINGW, MSYS) or WSL (uname -r microsoft, WSL_DISTRO_NAME, a WSLInterop file under CX_DETECT_ROOT) -> local${P48_BAD2:+:$P48_BAD2}" test -z "$P48_BAD2"
check "[P48] cx_session truth table (cloud: REMOTE truthy without a kind; byoc: any other kind; bridge: kind bridge, local behaviour) and [P58] cx_attended (1, 0, never 0 for a bridge child)${P48_BAD:+:$P48_BAD}" test -z "$P48_BAD"
run env STUB_UNAME_S=Linux CX_DETECT_ROOT="$DR/empty" CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=byoc CLAUDE_CODE_SESSION_ATTENDED=0 bash "$DETECT" --field session
check "[P58] detect.sh --field session" eval '[ "$(cat "$O")" = byoc ]'
run env STUB_UNAME_S=Linux CX_DETECT_ROOT="$DR/empty" CLAUDE_CODE_SESSION_ATTENDED=0 bash "$DETECT" --field ATTENDED
check "[P58] detect.sh --field ATTENDED (any case)" eval '[ "$(cat "$O")" = 0 ]'
DET_MINI="$TMP/det-mini"
mkdir -p "$DET_MINI"
for t in bash dirname cat; do ln -sf "$(PATH="$REAL_PATH" command -v "$t")" "$DET_MINI/$t"; done
printf '#!/bin/bash\necho PYTHON_CALLED >> %q\nexit 9009\n' "$TMP/det-pytrap.log" > "$DET_MINI/python3"
chmod 0755 "$DET_MINI/python3"
run env -i STUB_UNAME_S=MINGW64_NT-10.0-26100 CX_DETECT_ROOT="$DR/empty" CLAUDE_CODE_ENVIRONMENT_KIND=bridge PATH="$STUBS:$DET_MINI" "$DET_MINI/bash" "$DETECT" --shell
check "[P58] --shell lists CX_SESSION and CX_ATTENDED (simulated Git Bash: bash, dirname, cat and a python3 trap that stays silent)" \
  eval 'rc_is 0 && d_is CX_SESSION=bridge && d_is "CX_ATTENDED='"''"'" && d_is CX_HOST=gitbash && [ ! -s "$TMP/det-pytrap.log" ]'
run env STUB_UNAME_S=Linux CX_DETECT_ROOT="$DR/empty" CLAUDE_CODE_REMOTE=1 CLAUDE_CODE_SESSION_ATTENDED=1 bash "$DETECT" --json
check "[P58] --json has session and attended" eval 'outj_is session cloud && outj_is attended 1'
run env STUB_UNAME_S=Linux CX_DETECT_ROOT="$DR/empty" bash "$DETECT" --emit
check "[X]   --emit: CX_HOST carries session local and attended null" eval 'line_is CX_HOST session local && line_is CX_HOST attended null'

# ------------------------------------------------------------------ 6. policy hook (section 10)
section "SessionStart policy hook"
# The policy blocks of DESIGN.md section 10 (lines between the ```text fences, joined with \n).
blocks_py() {
  "$REAL_PY" -I - "$ROOT/docs/DESIGN.md" "$ROOT/hooks" "$@" <<'PY'
import json, os, sys
text = open(sys.argv[1], encoding="utf-8").read()
hooks = sys.argv[2]
def block(name):
    body = text.split("<!-- %s:begin -->" % name, 1)[1].split("<!-- %s:end -->" % name, 1)[0]
    body = body.split("```text\n", 1)[1].rsplit("\n```", 1)[0]
    return body
LONGEST = "agy (raw), then Copilot, then own subagents"
ATTN = (" UNATTENDED RUN: nobody approves prompts or reads a later turn, so commands outside the allow rules are"
        " denied; wait for jobs with consecutive foreground waits of at most 9 minutes (not background Bash) and"
        " report any job still running by its id.")
cmd = sys.argv[3]
if cmd == "p20":
    bad = []
    want = {"policy-context.json": ("policy", None), "policy-context-gitbash.json": ("policy-gitbash", None),
            "policy-context-crlf.json": ("policy-crlf-context", "policy-crlf-system"),
            "policy-context-cloud.json": ("policy-cloud-context", "policy-cloud-system")}
    for f, (ctx, sysm) in want.items():
        raw = open(os.path.join(hooks, f), "rb").read()
        try:
            raw.decode("ascii")
        except UnicodeDecodeError:
            bad.append(f + ": not ASCII")
        d = json.loads(raw)
        h = d.get("hookSpecificOutput", {})
        if h.get("hookEventName") != "SessionStart":
            bad.append(f + ": hookEventName")
        if h.get("additionalContext") != block(ctx):
            bad.append(f + ": additionalContext differs from the %s block" % ctx)
        if sysm and d.get("systemMessage") != block(sysm):
            bad.append(f + ": systemMessage differs from the %s block" % sysm)
        if not sysm and "systemMessage" in d:
            bad.append(f + ": unexpected systemMessage")
        if raw != (json.dumps(d, indent=2, ensure_ascii=True) + "\n").encode():
            bad.append(f + ": not json.dumps(obj, indent=2, ensure_ascii=True) + newline")
    for name in ("policy", "policy-gitbash"):
        t = block(name)
        n = len(t.replace("{ORDER}", LONGEST).replace("{ATTN}", ATTN))
        if n > 2800:
            bad.append("%s: %d characters rendered" % (name, n))
        if "--new-project" not in t or "load the conductor skill" not in t or t.count("{ORDER}") != 1:
            bad.append(name + ": lacks --new-project, the skill-first rule or one {ORDER}")
        if t.count("{ATTN}") != 1 or not t.endswith("{ATTN}"):
            bad.append(name + ": {ATTN} is not once, at the end")
        if len(ATTN) != 246 or "&" in ATTN or "\\" in ATTN:
            bad.append("the ATTN sentence changed")
        # A background call is stopped at its timeout too (default 30 min): the 2-hour maximum.
        if "background Bash call with timeout 7200000" not in t:
            bad.append(name + ": no background timeout 7200000")
        # Lanes that always pass --yolo are named only to forbid them.
        for w in ("agy-media", "/antigravity:research", "agy-handoff"):
            for i in [k for k in range(len(t)) if t.startswith(w, k)]:
                if "Never" not in t[max(0, i - 40):i]:
                    bad.append("%s: %s named outside a Never clause" % (name, w))
    w = block("policy")
    for name in ("policy", "policy-gitbash"):
        if "cx-run --background" not in block(name) or "cx-job wait" not in block(name) or "cx-run --mode review" not in block(name):
            bad.append(name + ": does not route through cx-run --background, cx-job wait and cx-run --mode review")
    if "(cd DIR && timeout -k" in w:
        bad.append("policy: still has the Phase 1 inline agy registration")
    if "antigravity-delegate" not in w or "grok-delegate" not in w:
        bad.append("policy: does not forbid both proactive subagents (antigravity-delegate, grok-delegate)")
    if "--github acts as you" not in w or "ghcp-delegate --github." in w:
        bad.append("policy: --github is presented as a triage lane")
    g = block("policy-gitbash")
    if "cx-wsl" not in g:
        bad.append("policy-gitbash lacks cx-wsl")
    if "(cd DIR" in g or "timeout -k" in g:
        bad.append("policy-gitbash shows a raw agy command")
    import re as _re
    for m in _re.finditer(r"(\S+ )?(gh pr edit|ghcp-ci-debug)\b", g):
        if (m.group(1) or "").strip() != "cx-wsl":
            bad.append("policy-gitbash: %s without cx-wsl" % m.group(2))
    print("; ".join(bad))
elif cmd == "expect":        # expect FILE PHRASE [attn]: the file with {ORDER} (and {ATTN}) replaced
    a = ATTN if len(sys.argv) > 6 and sys.argv[6] == "attn" else ""
    sys.stdout.write(open(os.path.join(hooks, sys.argv[4]), encoding="utf-8").read().replace("{ORDER}", sys.argv[5]).replace("{ATTN}", a))
elif cmd == "ctx":           # ctx OUTFILE: additionalContext of the printed JSON
    d = json.loads(open(sys.argv[4], encoding="utf-8").read())
    print(d["hookSpecificOutput"]["additionalContext"] == block(sys.argv[5]).replace("{ORDER}", LONGEST).replace("{ATTN}", "") and (d.get("systemMessage") or "") == (block(sys.argv[6]) if len(sys.argv) > 6 else ""))
PY
}
P20_BAD="$(blocks_py p20)"
check "[P20] the four policy JSON files parse, are ASCII json.dumps(indent=2), SessionStart, equal their DESIGN blocks; both texts <= 2800 with the longest order and the unattended sentence, {ATTN} once at the end, --new-project, skill-first, background timeout 7200000, cx-run --background / cx-job wait / cx-run --mode review (Phase 2), --yolo lanes only forbidden, both subagents forbidden, --github not a triage lane, Git Bash: every other command via cx-wsl${P20_BAD:+: $P20_BAD}" test -z "$P20_BAD"
DEF_ORDER='agy (raw), then Copilot, then own subagents'
COP_ORDER='Copilot, then agy (raw), then own subagents'
pol() { run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY -u CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER "$@" bash "$POLICY"; }
pol_is() {  # FILE PHRASE [attn]: stdout is exactly FILE with {ORDER} = PHRASE (and {ATTN}), stderr empty, rc 0
  rc_is 0 && err_empty && [ "$(cat "$O"; printf x)" = "$(blocks_py expect "$1" "$2" ${3:+"$3"}; printf x)" ] && out_lacks '{ORDER}' && out_lacks '{ATTN}'
}
pol
check "[P21] order unset -> the default phrase; output = policy-context.json exactly" pol_is policy-context.json "$DEF_ORDER"
check "[X]   the printed policy is valid JSON with the rendered order" eval 'tj isjson "$O" && tj get "$O" hookSpecificOutput.additionalContext | grep -Fq "in order: $DEF_ORDER (cx-run --exec auto)."'
pol CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=copilot,agy
check "[P21] copilot,agy -> Copilot first" pol_is policy-context.json "$COP_ORDER"
pol CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=' COPILOT, AGY '
check "[P21] ' COPILOT, AGY ' -> Copilot first (trimmed, lowercased)" pol_is policy-context.json "$COP_ORDER"
pol CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=copilot
check "[P21] copilot -> 'Copilot, then own subagents'" pol_is policy-context.json 'Copilot, then own subagents'
P21_BAD=""
for o in 'agy,agy' bogus '*' 'agy,claude,agy' 'agy;rm' 'agy & copilot'; do
  pol CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER="$o"
  pol_is policy-context.json "$DEF_ORDER" || P21_BAD="$P21_BAD [$o]"
done
check "[P21] agy,agy, bogus, * (and other junk) -> the default phrase${P21_BAD:+:$P21_BAD}" test -z "$P21_BAD"
P21_BAD=""
for o in 'copilot,,agy' 'copilot,agy,' ',copilot' ',' ',,'; do
  pol CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER="$o"
  pol_is policy-context.json "$DEF_ORDER" || P21_BAD="$P21_BAD [$o: policy]"
  [ "$(env CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER="$o" bash -c '. "$1/scripts/lib/common.sh"; . "$1/scripts/lib/options.sh"; cx_opt opus_lane_order' _ "$ROOT" 2>/dev/null)" = agy,copilot,claude ] || P21_BAD="$P21_BAD [$o: cx_opt]"
done
check "[P21] empty segments (copilot,,agy / copilot,agy, / ,copilot): the hook and cx_opt agree on the default order${P21_BAD:+:$P21_BAD}" test -z "$P21_BAD"
pol CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=claude,agy
check "[X]   claude,agy -> 'own subagents, then agy (raw)'" pol_is policy-context.json 'own subagents, then agy (raw)'
pol STUB_UNAME_S=MINGW64_NT-10.0-26100
check "[P21] STUB_UNAME_S=MINGW64_NT-... -> the Git Bash variant" pol_is policy-context-gitbash.json "$DEF_ORDER"
pol STUB_UNAME_S=MSYS_NT-10.0-26100 CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=copilot,agy
check "[P21] MSYS_NT-... -> the Git Bash variant (with the order)" pol_is policy-context-gitbash.json "$COP_ORDER"
P21_BAD=""
for v in off OFF ' no ' disabled 0 false 'False' ' Disabled '; do
  pol CLAUDE_PLUGIN_OPTION_POLICY="$v"
  { rc_is 0 && out_empty && err_empty; } || P21_BAD="$P21_BAD [$v]"
done
check "[P21] option policy off/OFF/ no /disabled/0/false -> nothing${P21_BAD:+:$P21_BAD}" test -z "$P21_BAD"
pol CLAUDE_PLUGIN_OPTION_POLICY=on
check "[X]   policy=on -> printed" pol_is policy-context.json "$DEF_ORDER"
pol CX_WORKER=1
check "[P21] CX_WORKER=1 -> nothing" eval 'rc_is 0 && out_empty && err_empty'
pol CX_WORKER=0
check "[P21] CX_WORKER=0 -> printed" pol_is policy-context.json "$DEF_ORDER"
runin 'not json' env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY -u CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER bash "$POLICY"
check "[P21] stdin 'not json' -> exit 0 with the policy" pol_is policy-context.json "$DEF_ORDER"
env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$POLICY" > "$O" 2> "$E" <&-; RC=$?
check "[P21] stdin closed -> exit 0 with the policy" pol_is policy-context.json "$DEF_ORDER"
mkdir -p "$TMP/pol-missing"
cp -R "$ROOT/hooks" "$ROOT/bin" "$ROOT/scripts" "$TMP/pol-missing/"
rm -f -- "$TMP/pol-missing/hooks/policy-context.json"
run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$TMP/pol-missing/hooks/policy.sh"
check "[P21] missing JSON file -> exit 0, nothing" eval 'rc_is 0 && out_empty && err_empty'
BC_BIN="$TMP/bash-cat-bin"
mkdir -p "$BC_BIN"
ln -sf "$(PATH="$REAL_PATH" command -v bash)" "$BC_BIN/bash"
ln -sf "$(PATH="$REAL_PATH" command -v cat)" "$BC_BIN/cat"
run env -i PATH="$BC_BIN" HOME="$HOME" "$BC_BIN/bash" "$POLICY"
check "[P21] a PATH holding only bash and cat (no uname): the WSL variant, stderr empty" pol_is policy-context.json "$DEF_ORDER"
(cd "$ROOT/hooks" && env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash policy.sh > "$O" 2> "$E" < /dev/null); RC=$?
check "[X]   run by a relative path from hooks/ (BASH_SOURCE without a slash)" pol_is policy-context.json "$DEF_ORDER"
crlf_copy "$TMP/crlf-hooks" hooks/policy.sh hooks/hooks.json hooks/policy-context.json hooks/policy-context-gitbash.json hooks/policy-context-crlf.json
run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$TMP/crlf-hooks/hooks/policy.sh"
check "[P22] a CRLF copy of hooks/: exit 0, empty stderr, stdout parses with the same additionalContext" \
  eval 'rc_is 0 && err_empty && [ "$(blocks_py ctx "$O" policy)" = True ]'
run env -u CX_WORKER CLAUDE_PLUGIN_OPTION_POLICY=off bash "$TMP/crlf-hooks/hooks/policy.sh"
check "[P22] ... with the option off: nothing" eval 'rc_is 0 && out_empty && err_empty'
run env -u CX_WORKER CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=copilot,agy bash "$TMP/crlf-hooks/hooks/policy.sh"
check "[X]   ... and the order still renders" eval 'tj get "$O" hookSpecificOutput.additionalContext | grep -Fq "in order: $COP_ORDER (cx-run --exec auto)."'
crlf_copy "$TMP/crlf-all" --all
run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$TMP/crlf-all/hooks/policy.sh"
check "[P22b] a fully CRLF copy: exit 0, empty stderr, the CRLF notice (systemMessage + policy-crlf-context)" \
  eval 'rc_is 0 && err_empty && [ "$(blocks_py ctx "$O" policy-crlf-context policy-crlf-system)" = True ]'
run env -u CX_WORKER CLAUDE_PLUGIN_OPTION_POLICY=OFF bash "$TMP/crlf-all/hooks/policy.sh"
check "[P22b] ... with the option off: nothing" eval 'rc_is 0 && out_empty && err_empty'
CRLF_FIND="$("$REAL_PY" -I - "$ROOT/docs/DESIGN.md" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
for name in ("policy-crlf-context", "policy-crlf-system"):
    body = text.split("<!-- %s:begin -->" % name, 1)[1].split("<!-- %s:end -->" % name, 1)[0]
    if "core.autocrlf" in body:
        raise SystemExit(1)
    m = re.search(r" run (find .*? -exec sed -i 's/\\r\$//' \{\} \+),", body)
    if not m:
        raise SystemExit(1)
print(m.group(1))
PY
)"
cp -a "$TMP/crlf-all" "$TMP/crlf-all-fixed"
(cd "$TMP/crlf-all-fixed" && bash -c "$CRLF_FIND") > /dev/null 2>&1
run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$TMP/crlf-all-fixed/hooks/policy.sh"
check "[P22b] the CRLF notice's fix (no autocrlf advice), run in the install folder of a fully CRLF copy, restores it: normal policy, cx-doctor --version runs" \
  eval '[ -n "$CRLF_FIND" ] && pol_is policy-context.json "$DEF_ORDER" && [ "$(bash "$TMP/crlf-all-fixed/bin/cx-doctor" --version 2>/dev/null)" = "cx-doctor $CXV" ]'
crlf_copy "$TMP/crlf-doctor" bin/cx-doctor
run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$TMP/crlf-doctor/hooks/policy.sh"
check "[P22b] only bin/cx-doctor converted: the CRLF notice" eval 'rc_is 0 && err_empty && [ "$(blocks_py ctx "$O" policy-crlf-context policy-crlf-system)" = True ]'
for c in scripts/lib/common.sh scripts/host/forward-wsl.sh; do
  crlf_copy "$TMP/crlf-$(basename "$c")" "$c"
  run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY STUB_UNAME_S=MINGW64_NT-10.0-26100 bash "$TMP/crlf-$(basename "$c")/hooks/policy.sh"
  check "[X]   only $c converted (on Git Bash too): the CRLF notice" eval '[ "$(blocks_py ctx "$O" policy-crlf-context policy-crlf-system)" = True ]'
done
HJ="$ROOT/hooks/hooks.json"
check "[P53] hooks.json parses; exactly SessionStart and SubagentStart; matchers startup|clear|compact and workflow-subagent|general-purpose; commands exact; both onFailure continue; no PreToolUse in Phase 1; the scripts exist" \
  test "$("$REAL_PY" -I - "$HJ" "$ROOT" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
h = d["hooks"]
def one(ev, matcher, script):
    e = h[ev]
    return (len(e) == 1 and e[0]["matcher"] == matcher
            and e[0]["hooks"] == [{"type": "command", "command": 'bash "${CLAUDE_PLUGIN_ROOT}/hooks/%s"' % script, "onFailure": "continue"}]
            and os.path.isfile(os.path.join(sys.argv[2], "hooks", script)))
ok = (list(h) == ["SessionStart", "SubagentStart"] and list(d) == ["hooks"]
      and one("SessionStart", "startup|clear|compact", "policy.sh")
      and one("SubagentStart", "workflow-subagent|general-purpose", "subagent.sh"))
print(ok)
PY
)" = True

# --- the cloud notice (P46, P47), the subagent guard (P54-P56) and {ATTN} (P57)
cloud_is() { rc_is 0 && err_empty && cmp -s "$O" "$ROOT/hooks/policy-context-cloud.json"; }
P46_BAD=""
for v in true TRUE ' 1 ' yes on On; do
  pol CLAUDE_CODE_REMOTE="$v"
  cloud_is || P46_BAD="$P46_BAD [$v]"
done
pol CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=byoc
cloud_is || P46_BAD="$P46_BAD [byoc]"
pol CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=self_hosted
cloud_is || P46_BAD="$P46_BAD [self_hosted]"
pol CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=byoc CLAUDE_PLUGIN_OPTION_EXEC_HOST=wsl
cloud_is || P46_BAD="$P46_BAD [byoc+wsl]"
pol CLAUDE_CODE_REMOTE=true STUB_UNAME_S=Linux STUB_UNAME_R=6.1.0-13-amd64
cloud_is || P46_BAD="$P46_BAD [plain linux]"
check "[P46] CLAUDE_CODE_REMOTE true/TRUE/ 1 /yes/on/On, kind byoc or self_hosted (without exec_host=local), plain Linux: exactly policy-context-cloud.json${P46_BAD:+:$P46_BAD}" test -z "$P46_BAD"
P46_BAD=""
p46n() { pol "$@"; pol_is policy-context.json "$DEF_ORDER" || P46_BAD="$P46_BAD [$*]"; }
p46n CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=bridge
p46n CLAUDE_CODE_ENVIRONMENT_KIND=bridge
p46n CLAUDE_CODE_REMOTE=false
p46n CLAUDE_CODE_REMOTE=0
p46n CLAUDE_CODE_REMOTE=
p46n CLAUDE_CODE_HOSTED_DESKTOP=1
p46n CLAUDE_CODE_ENTRYPOINT=remote_projects
p46n CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=byoc CLAUDE_PLUGIN_OPTION_EXEC_HOST=local
p46n CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=byoc 'CLAUDE_PLUGIN_OPTION_EXEC_HOST= LOCAL '
p46n CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=self_hosted CLAUDE_PLUGIN_OPTION_EXEC_HOST=local
p46n CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=BYOC CLAUDE_PLUGIN_OPTION_EXEC_HOST=local
check "[P46] kind bridge (with or without REMOTE), REMOTE false/0/empty, HOSTED_DESKTOP or ENTRYPOINT alone, any non-bridge kind (byoc, self_hosted, BYOC) with exec_host=local: the normal policy${P46_BAD:+:$P46_BAD}" test -z "$P46_BAD"
P46_BAD=""
mkdir -p "$TMP/p46-interop/proc/sys/fs/binfmt_misc"; : > "$TMP/p46-interop/proc/sys/fs/binfmt_misc/WSLInterop-late"
p46n CLAUDE_CODE_REMOTE=true STUB_UNAME_S=Linux STUB_UNAME_R=6.6.87.2-microsoft-standard-WSL2
p46n CLAUDE_CODE_REMOTE=true STUB_UNAME_S=Linux STUB_UNAME_R=4.4.0-19041-Microsoft
p46n CLAUDE_CODE_REMOTE=true WSL_DISTRO_NAME=Ubuntu
p46n CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=byoc CX_DETECT_ROOT="$TMP/p46-interop"
pol CLAUDE_CODE_REMOTE=true STUB_UNAME_S=MINGW64_NT-10.0-26100
pol_is policy-context-gitbash.json "$DEF_ORDER" || P46_BAD="$P46_BAD [gitbash]"
check "[P46] never the cloud notice on the user's computer: CLAUDE_CODE_REMOTE=true (no kind, or byoc) on WSL (uname -r microsoft, WSL_DISTRO_NAME, a WSLInterop file) -> the WSL policy, on simulated Git Bash -> the Git Bash policy${P46_BAD:+:$P46_BAD}" test -z "$P46_BAD"
pol CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=bridge STUB_UNAME_S=MINGW64_NT-10.0-26100
check "[P46] a bridge child on Git Bash (a Work locally thread from the Windows app): the Git Bash policy" pol_is policy-context-gitbash.json "$DEF_ORDER"
P46_BAD=""
pol CLAUDE_CODE_REMOTE=true CX_WORKER=1
{ rc_is 0 && out_empty && err_empty; } || P46_BAD="$P46_BAD [CX_WORKER]"
pol CLAUDE_CODE_REMOTE=true CLAUDE_PLUGIN_OPTION_POLICY=off
{ rc_is 0 && out_empty && err_empty; } || P46_BAD="$P46_BAD [policy off]"
mkdir -p "$TMP/pol-nocloud"
cp -R "$ROOT/hooks" "$ROOT/bin" "$ROOT/scripts" "$TMP/pol-nocloud/"
rm -f -- "$TMP/pol-nocloud/hooks/policy-context-cloud.json"
run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY CLAUDE_CODE_REMOTE=true bash "$TMP/pol-nocloud/hooks/policy.sh"
{ rc_is 0 && out_empty && err_empty; } || P46_BAD="$P46_BAD [unreadable]"
for cp_ in crlf-hooks crlf-all crlf-doctor; do
  run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY CLAUDE_CODE_REMOTE=true bash "$TMP/$cp_/hooks/policy.sh"
  if [ "$cp_" = crlf-hooks ] || [ "$cp_" = crlf-all ]; then
    { rc_is 0 && err_empty && [ "$(tj get "$O" hookSpecificOutput.additionalContext 2>/dev/null)" = "$(tj get "$ROOT/hooks/policy-context-cloud.json" hookSpecificOutput.additionalContext)" ]; } || P46_BAD="$P46_BAD [$cp_]"
  else
    cloud_is || P46_BAD="$P46_BAD [$cp_]"
  fi
done
check "[P46] cloud with CX_WORKER=1 or the option off: nothing; the cloud file unreadable: nothing, exit 0; CRLF copies and a CR in a canary file still select the cloud notice${P46_BAD:+:$P46_BAD}" test -z "$P46_BAD"
P47_BAD="$("$REAL_PY" -I - "$ROOT/docs/DESIGN.md" "$ROOT/hooks" <<'PY'
import json, os, sys
text = open(sys.argv[1], encoding="utf-8").read()
def block(name):
    body = text.split("<!-- %s:begin -->" % name, 1)[1].split("<!-- %s:end -->" % name, 1)[0]
    return body.split("```text\n", 1)[1].rsplit("\n```", 1)[0]
bad = []
raw = open(os.path.join(sys.argv[2], "policy-context-cloud.json"), "rb").read()
d = json.loads(raw)
c, m = d["hookSpecificOutput"]["additionalContext"], d.get("systemMessage", "")
if d["hookSpecificOutput"].get("hookEventName") != "SessionStart": bad.append("hookEventName")
if c != block("policy-cloud-context") or m != block("policy-cloud-system"): bad.append("differs from the DESIGN blocks")
if not raw.isascii() or len(c) > 1000 or len(m) > 200 or "\n" in m: bad.append("not ASCII or too long")
for w in ("CONDUCTOR INACTIVE", "Work locally", "Claude agents only"):
    if w not in c: bad.append("lacks " + w)
for w in ("cx-wsl", "agy --new-project", "{ORDER}", "{ATTN}"):
    if w in c: bad.append("contains " + w)
print("; ".join(bad))
PY
)"
check "[P47] policy-context-cloud.json: SessionStart, equals policy-cloud-context / policy-cloud-system, ASCII, <= 1000 and 200 characters, CONDUCTOR INACTIVE, Work locally, Claude agents only, no cx-wsl or agy command${P47_BAD:+: $P47_BAD}" test -z "$P47_BAD"
SUBH="$ROOT/hooks/subagent.sh"
sub() { run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY "$@" bash "$SUBH"; }
sub_is() { rc_is 0 && err_empty && cmp -s "$O" "$ROOT/hooks/subagent-context.json"; }
sub_none() { rc_is 0 && out_empty && err_empty; }
P54_BAD=""
sub; sub_is || P54_BAD="$P54_BAD [no stdin]"
runin 'not json' env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$SUBH"; sub_is || P54_BAD="$P54_BAD [not json]"
env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$SUBH" > "$O" 2> "$E" <&-; RC=$?; sub_is || P54_BAD="$P54_BAD [closed]"
head -c 1048576 /dev/zero | tr '\0' x > "$TMP/one-mib"
T0=$SECONDS
env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$SUBH" > "$O" 2> "$E" < "$TMP/one-mib"; RC=$?
sub_is || P54_BAD="$P54_BAD [1 MiB]"
[ $((SECONDS - T0)) -lt 3 ] || P54_BAD="$P54_BAD [1 MiB slow]"
for t in workflow-subagent general-purpose; do
  runin '{"hook_event_name":"SubagentStart","agent_id":"a1","agent_type":"'"$t"'"}' env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$SUBH"
  sub_is || P54_BAD="$P54_BAD [$t]"
done
sub CLAUDE_CODE_REMOTE=true; sub_is || P54_BAD="$P54_BAD [cloud]"
check "[P54] subagent.sh prints subagent-context.json byte-equal for the two agent types and whatever the stdin (none, not json, closed, 1 MiB in < 3 s), also in the cloud${P54_BAD:+:$P54_BAD}" test -z "$P54_BAD"
P54_BAD=""
for v in off OFF ' no ' disabled 0 false; do sub CLAUDE_PLUGIN_OPTION_POLICY="$v"; sub_none || P54_BAD="$P54_BAD [$v]"; done
sub CX_WORKER=1; sub_none || P54_BAD="$P54_BAD [CX_WORKER]"
sub CX_WORKER=0; sub_is || P54_BAD="$P54_BAD [CX_WORKER=0]"
for t in ghcp:ghcp-delegate conductor:cx-runner Explore; do
  runin '{"agent_id":"a1","agent_type":"'"$t"'"}' env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$SUBH"
  sub_none || P54_BAD="$P54_BAD [$t]"
done
check "[P54] silent with the option off (six spellings), CX_WORKER=1, or another agent_type (ghcp:ghcp-delegate, conductor:cx-runner, Explore); CX_WORKER=0 prints${P54_BAD:+:$P54_BAD}" test -z "$P54_BAD"
run env -i PATH="$BC_BIN" HOME="$HOME" "$BC_BIN/bash" "$SUBH"
check "[P54] a PATH holding only bash and cat: the guard, stderr empty" sub_is
crlf_copy "$TMP/crlf-sub" hooks/subagent.sh hooks/subagent-context.json
run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$TMP/crlf-sub/hooks/subagent.sh"
check "[P54] a CRLF copy: exit 0, empty stderr, the same additionalContext" \
  eval 'rc_is 0 && err_empty && [ "$(tj get "$O" hookSpecificOutput.additionalContext)" = "$(tj get "$ROOT/hooks/subagent-context.json" hookSpecificOutput.additionalContext)" ]'
P55_BAD="$("$REAL_PY" -I - "$ROOT/docs/DESIGN.md" "$ROOT/hooks" <<'PY'
import json, os, sys
text = open(sys.argv[1], encoding="utf-8").read()
body = text.split("<!-- subagent-context:begin -->", 1)[1].split("<!-- subagent-context:end -->", 1)[0]
want = body.split("```text\n", 1)[1].rsplit("\n```", 1)[0]
bad = []
for f, ev in (("subagent-context.json", "SubagentStart"), ("subagent-context-compact.json", "SessionStart")):
    raw = open(os.path.join(sys.argv[2], f), "rb").read()
    d = json.loads(raw)
    h = d.get("hookSpecificOutput", {})
    if list(d) != ["hookSpecificOutput"] or h.get("hookEventName") != ev:
        bad.append(f + ": shape or hookEventName")
    if h.get("additionalContext") != want:
        bad.append(f + ": differs from the subagent-context block")
    if raw != (json.dumps(d, indent=2, ensure_ascii=True) + "\n").encode():
        bad.append(f + ": not json.dumps(indent=2)")
if not want.isascii() or len(want) > 800:
    bad.append("not ASCII or over 800 characters")
for w in ("EXECUTOR_NEEDED", "cx-wsl", "ghcp-*", "agy-*", "grok", "copilot", "cx-*"):
    if w not in want: bad.append("lacks " + w)
for w in ('"', "\\", "&"):
    if w in want: bad.append("contains " + repr(w))
print("; ".join(bad))
PY
)"
check "[P55] subagent-context.json (SubagentStart) and subagent-context-compact.json (SessionStart) parse and equal the DESIGN block; ASCII, <= 800, EXECUTOR_NEEDED, cx-wsl and every executor name, no quote, backslash or &${P55_BAD:+: $P55_BAD}" test -z "$P55_BAD"
comp_is() { rc_is 0 && err_empty && cmp -s "$O" "$ROOT/hooks/subagent-context-compact.json"; }
polin() { local t="$1"; shift; runin "$t" env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY -u CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER "$@" bash "$POLICY"; }
P56_BAD=""
for t in workflow-subagent general-purpose; do
  polin '{"source":"compact","agent_id":"a1","agent_type":"'"$t"'"}'; comp_is || P56_BAD="$P56_BAD [$t]"
done
for t in conductor:cx-runner ghcp:ghcp-delegate; do
  polin '{"source":"compact","agent_id":"a1","agent_type":"'"$t"'"}'
  { rc_is 0 && out_empty && err_empty; } || P56_BAD="$P56_BAD [$t]"
done
polin '{"source":"compact","agent_type":"workflow-subagent"}'; pol_is policy-context.json "$DEF_ORDER" || P56_BAD="$P56_BAD [--agent main thread]"
polin '{"source":"compact","session_id":"s"}'; pol_is policy-context.json "$DEF_ORDER" || P56_BAD="$P56_BAD [no agent_id]"
polin '{"source":"compact","agent_id":"","agent_type":"workflow-subagent"}'; pol_is policy-context.json "$DEF_ORDER" || P56_BAD="$P56_BAD [empty agent_id]"
polin '{"source":"compact","agent_id":"a1","agent_type":"general-purpose"}' CLAUDE_CODE_REMOTE=true; comp_is || P56_BAD="$P56_BAD [cloud + subagent]"
T0=$SECONDS
env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$POLICY" > "$O" 2> "$E" < "$TMP/one-mib"; RC=$?
pol_is policy-context.json "$DEF_ORDER" || P56_BAD="$P56_BAD [1 MiB]"
[ $((SECONDS - T0)) -lt 3 ] || P56_BAD="$P56_BAD [1 MiB slow]"
runin '{"source":"compact","agent_id":"a1","agent_type":"workflow-subagent"}' env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$TMP/crlf-all/hooks/policy.sh"
{ rc_is 0 && err_empty && [ "$(tj get "$O" hookSpecificOutput.additionalContext 2>/dev/null)" = "$(tj get "$ROOT/hooks/subagent-context-compact.json" hookSpecificOutput.additionalContext)" ]; } || P56_BAD="$P56_BAD [CRLF copy]"
check "[P56] compaction: a workflow-subagent or general-purpose agent_id -> the compact guard; cx-runner or ghcp-delegate -> nothing; agent_type without agent_id, no or an empty agent_id, 1 MiB of stdin (< 3 s) -> the main policy; cloud + subagent -> the guard; a CRLF copy agrees${P56_BAD:+:$P56_BAD}" test -z "$P56_BAD"
P57_BAD=""
pol CLAUDE_CODE_SESSION_ATTENDED=0
pol_is policy-context.json "$DEF_ORDER" attn || P57_BAD="$P57_BAD [wsl 0]"
pol CLAUDE_CODE_SESSION_ATTENDED=0 STUB_UNAME_S=MINGW64_NT-10.0-26100
pol_is policy-context-gitbash.json "$DEF_ORDER" attn || P57_BAD="$P57_BAD [gitbash 0]"
for kv in CLAUDE_CODE_SESSION_ATTENDED=1 CLAUDE_CODE_SESSION_ATTENDED= 'CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_ENVIRONMENT_KIND=bridge'; do
  read -r -a KV <<< "$kv"
  pol "${KV[@]}"
  pol_is policy-context.json "$DEF_ORDER" || P57_BAD="$P57_BAD [$kv]"
done
pol CLAUDE_CODE_SESSION_ATTENDED=0
tj get "$O" hookSpecificOutput.additionalContext | grep -q 'agents\. UNATTENDED RUN: .* by its id\.$' || P57_BAD="$P57_BAD [not at the end]"
for f in policy-context.json policy-context-gitbash.json; do
  t="$(tj get "$ROOT/hooks/$f" hookSpecificOutput.additionalContext)"
  case "$t" in *"Workflows (ultracode too)"*"isolation worktree or remote"*"cx-run --background"*"Pool slots are shared by all sessions and threads"*"exits 28"*) ;; *) P57_BAD="$P57_BAD [$f: Workflows line]" ;; esac
  case "$t" in *"not shared yet"*|*"one agy run at a time"*) P57_BAD="$P57_BAD [$f: Phase 1 slot wording]" ;; esac
done
grep -Fq 'file tools on its wsl.localhost path, commands via cx-wsl bash -c), never with isolation' "$ROOT/hooks/policy-context-gitbash.json" || P57_BAD="$P57_BAD [gitbash: wsl.localhost + cx-wsl bash -c]"
check "[P57] {ATTN}: CLAUDE_CODE_SESSION_ATTENDED=0 -> both variants end with the unattended sentence; 1, empty or 0 in a bridge child -> none; never {ATTN} or {ORDER} in the output; both texts carry the Phase 2 Workflows line (isolation, cx-run --background, pool slots shared by all sessions and threads, exit 28), Git Bash: file tools on the wsl.localhost path, commands via cx-wsl bash -c${P57_BAD:+:$P57_BAD}" test -z "$P57_BAD"

# ------------------------------------------------------------------ 7. worker shims (section 11)
section "worker shims"
SHIMS=(claude copilot grok agy codex gemini cursor-agent agent
  ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-cloud ghcp-models ghcp-doctor
  agy-delegate agy-handoff agy-job agy-media agy-doctor cx-run cx-job cx-fanout cx-gate cx-doctor cx-init cx-wsl)
check "[P24] exactly the 27 shims (8 agent CLIs; Phase 2: the sibling wrappers and the conductor bins, section 11)" test "$(cd "$ROOT/worker-shims" && find . -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" = "$(printf '%s\n' "${SHIMS[@]}" | LC_ALL=C sort | tr '\n' ' ')"
P24_BAD=""
for s in "${SHIMS[@]}"; do
  f="$ROOT/worker-shims/$s"
  { [ -f "$f" ] && [ ! -L "$f" ] && [ -x "$f" ] && ! grep -q $'\r' "$f"; } || { P24_BAD="$P24_BAD $s(file)"; continue; }
  [ "$(cat "$f")" = "$(printf '#!/usr/bin/env bash\n# worker-shims/%s: stands in for an agent CLI on a conductor worker'"'"'s PATH (docs/DESIGN.md section 11).\nprintf '"'"'blocked: CX_WORKER\\n'"'"' >&2\nexit 126' "$s")" ] || P24_BAD="$P24_BAD $s(text)"
  printf 'some stdin\n' | env CX_WORKER=1 FOO=bar "$f" -p 'do something' --yolo > "$O" 2> "$E"; RC=$?
  { rc_is 126 && out_empty && [ "$(cat "$E"; printf x)" = $'blocked: CX_WORKER\nx' ]; } || P24_BAD="$P24_BAD $s(run)"
done
check "[P24] each a regular executable LF file with the exact text; any argv/stdin/env: no stdout, stderr exactly 'blocked: CX_WORKER\\n', exit 126${P24_BAD:+:$P24_BAD}" test -z "$P24_BAD"
stublog_mark
run env PATH="$ROOT/worker-shims:$PATH" CX_WORKER=1 claude -p x
check "[P24] PATH=worker-shims:\$PATH CX_WORKER=1 claude -p x exits 126 and the claude stub logged nothing" \
  eval 'rc_is 126 && [ -z "$(stublog_new)" ]'



# ------------------------------------------------------------------ Phase 2 background sections
# The adapter, cx-run and cx-job sections need no simulated Git Bash or WSL home, so they start
# here, next to static, init and doctor, while the serial sections below leave cores idle.
# overlap EVENTS NAME...: the largest number of NAME runs between their start and end lines.
overlap() {
  "$REAL_PY" -I - "$@" <<'PY'
import sys
names = set(sys.argv[2:])
ev = []
for ln in open(sys.argv[1]).read().split("\n"):
    f = ln.split()
    if len(f) >= 4 and f[1] in names:
        ev.append((float(f[3]), 0 if f[0] == "end" else 1))
cur = best = 0
for _, k in sorted(ev):
    cur += 1 if k else -1
    best = max(best, cur)
print(best)
PY
}
# hold FILE MODE READY: a holder of FILE (flock MODE: -x or -s) until killed; prints its pid.
hold() {
  bash -c 'exec 9>>"$1"; flock '"$2"' 9; : > "$3"; exec sleep 30' _ "$1" "$2" "$3" > /dev/null 2>&1 &
  printf '%s' "$!"
}
wait_file() { local i; for ((i = 0; i < 200; i++)); do [ -e "$1" ] && return 0; sleep 0.05; done; return 1; }
# alive PID: rc 0 while PID runs (a killed child that no one reaped yet is a zombie: not alive).
alive() { local st; st="$(ps -o stat= -p "$1" 2>/dev/null)" && [ -n "$st" ] && [ "${st#Z}" = "$st" ]; }

# ------------------------------------------------------------------ Phase 2 adapters (section 15.2)
# A background section: the five adapters (scripts/adapters/*.sh) against the stubs' run
# scenarios, in their own home ($TMP/ad) whose host record names the stubs; their own stub log
# ($TMP/adapters.log, audited here: an executor run without a scenario knob would be BILLABLE).
AD="$TMP/ad"
ADL="$TMP/adapters.log"
ADP="$ROOT/scripts/adapters"
NORM="$ROOT/scripts/lib/normalize.py"
LEDGER="$ROOT/scripts/lib/ledger.py"
# ad VAR=VALUE... -- LANE ARGS...: one adapter call in the adapter home ($O/$E/$RC).
ad() {
  local -a ev=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done
  shift
  local lane="$1"
  shift
  run env HOME="$AD/home" CX_HOME="$AD/home/.conductor" CLAUDE_CONFIG_DIR="$AD/cfg" STUB_LOG="$ADL" \
    ${ev[@]+"${ev[@]}"} "$ADP/$lane.sh" "$@"
}
# adr LANE OUT [VAR=VALUE...] -- ARGS...: run then parse; $PR = parse's "<exit> <status>", $RJ = result.json.
adr() {
  local lane="$1" out="$2"
  shift 2
  local -a ev=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done
  shift
  rm -rf -- "${out:?}"
  mkdir -p -- "$out"
  ad ${ev[@]+"${ev[@]}"} -- "$lane" run --out "$out" "$@"
  ADR_RC="$RC"
  PR="$(env HOME="$AD/home" CX_HOME="$AD/home/.conductor" "$ADP/$lane.sh" parse --out "$out" 2>/dev/null)"
  RJ="$out/result.json"
}
rj() { "$REAL_PY" -I "$NORM" field "$RJ" "$1" 2>/dev/null; }
rj_is() { [ "$(rj "$1")" = "$2" ]; }
# flags_in ARGV_FILE HELP [SKIP_FIRST]: every flag token of the NUL-separated argv appears in HELP
# (the hidden-flag allowlist is grok's --trust only); prints the flags that do not.
flags_in() {
  "$REAL_PY" -I - "$@" <<'PY'
import re, sys
argv = open(sys.argv[1], "rb").read().decode("utf-8", "replace").split("\0")
if argv and argv[-1] == "":
    argv.pop()
text = open(sys.argv[2], encoding="utf-8", errors="replace").read()
allow = {"--trust"}
bad = []
for a in argv[1:]:
    if not re.fullmatch(r"--?[A-Za-z][A-Za-z0-9-]*", a) or a in allow:
        continue
    if not re.search(r"(?<![A-Za-z0-9-])" + re.escape(a) + r"(?![A-Za-z0-9-])", text):
        bad.append(a)
print(" ".join(bad))
PY
}
# dry_same LANE DIR OPTS...: `LANE argv --dry-run --out DIR OPTS...` prints the argv that DIR/LANE.argv
# holds (printf %q, session uuids masked) and leaves DIR as it was; sets DRY_WHY on failure.
uuid_mask() { sed -E 's/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/<uuid>/g'; }
dry_same() {
  local lane="$1" d="$2" before q line
  shift 2
  local -a av=()
  DRY_WHY=""
  [ -s "$d/$lane.argv" ] || { DRY_WHY="no $d/$lane.argv"; return 1; }
  before="$(find "$d" -printf '%p %s %T@\n' | sort)"
  ad -- "$lane" argv --dry-run --out "$d" "$@"
  [ "$RC" = 0 ] || { DRY_WHY="rc $RC"; return 1; }
  [ "$before" = "$(find "$d" -printf '%p %s %T@\n' | sort)" ] || { DRY_WHY="the dry run wrote into $d"; return 1; }
  mapfile -d '' -t av < "$d/$lane.argv"
  printf -v q '%q ' "${av[@]}"
  line="$(sed -n 's/^argv: //p' "$O")"
  [ "$(printf '%s\n' "${q% }" | uuid_mask)" = "$(printf '%s\n' "$line" | uuid_mask)" ] || { DRY_WHY="dry argv differs: $line"; return 1; }
}
# argv_line FILE: the copilot argv of a ghcp-delegate --print-command capture as a NUL file.
shell_argv() {
  "$REAL_PY" -I - "$1" "$2" <<'PY'
import shlex, sys
line = open(sys.argv[1], encoding="utf-8").read().strip()
# $'...' quoting (bash printf %q) -> shlex: decode the ANSI-C escapes first.
import re, codecs
def ansi(m):
    return "'" + codecs.decode(m.group(1).encode(), "unicode_escape").replace("'", "'\"'\"'") + "'"
line = re.sub(r"\$'((?:[^'\\]|\\.)*)'", ansi, line)
open(sys.argv[2], "wb").write(b"\0".join(w.encode("utf-8", "surrogatepass") for w in shlex.split(line)) + b"\0")
PY
}

# The variables every executor run must not see (DESIGN section 15.6; API keys bill APIs, not
# subscriptions) and wrong auto-update values the worker environment must override (the suite
# exports the right ones globally, so their presence alone would prove nothing).
SCRUB_PROBE=(ANTHROPIC_API_KEY=a XAI_API_KEY=x GEMINI_API_KEY=g GOOGLE_API_KEY=o CLAUDE_PLUGIN_OPTION_TIMEOUT=9m
  COPILOT_AUTO_UPDATE=true GROK_DISABLE_AUTOUPDATER=0 AGY_CLI_DISABLE_AUTO_UPDATE=false NO_COLOR=0 CX_WORKER=0)
# worker_env_ok FILE BLOCK PATH_HEAD [VAR=VALUE...]: every "== BLOCK" env dump in FILE lacks the
# scrubbed names, has CX_WORKER=1, NO_COLOR=1 and each VAR=VALUE, and its PATH starts with
# PATH_HEAD; sets WENV_WHY.
worker_env_ok() {
  local f="$1" b="$2" head="$3" n
  shift 3
  WENV_WHY=""
  n="$(grep -c "^== $b\$" "$f" 2>/dev/null)"
  [ "${n:-0}" -gt 0 ] || { WENV_WHY="no $b env dump"; return 1; }
  WENV_WHY="$("$REAL_PY" -I - "$f" "$b" "$head" "$@" <<'PY2'
import re, sys
f, b, head, want = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
blocks, cur = [], None
for ln in open(f, encoding="utf-8", errors="replace").read().split("\n"):
    if ln.startswith("== "):
        cur = {} if ln == "== " + b else None
        if cur is not None:
            blocks.append(cur)
    elif cur is not None and "=" in ln:
        k, v = ln.split("=", 1)
        cur.setdefault(k, v)
bad = []
for i, e in enumerate(blocks):
    for k in e:
        if k in ("ANTHROPIC_API_KEY", "XAI_API_KEY", "GEMINI_API_KEY", "GOOGLE_API_KEY") or k.startswith("CLAUDE_PLUGIN_OPTION_"):
            bad.append("%s#%d has %s" % (b, i + 1, k))
    for kv in ["CX_WORKER=1", "NO_COLOR=1"] + want:
        k, v = kv.split("=", 1)
        if e.get(k) != v:
            bad.append("%s#%d %s=%r" % (b, i + 1, k, e.get(k)))
    if not (e.get("PATH", "") + ":").startswith(head + ":"):
        bad.append("%s#%d PATH %s" % (b, i + 1, e.get("PATH", "")[:120]))
print("; ".join(bad))
PY2
)"
  [ -z "$WENV_WHY" ]
}
# ad_setup: the adapter home $AD (dynamic: each section sets its own AD and ADL): a host record
# naming the stubs, a repository with worktrees t1, t2, other and a Claude worktree; sets HK,
# REPO and O1 in the caller.
ad_setup() {
  mkdir -p "$AD/home/.conductor/hosts" "$AD/cfg"
  HK="$(bash -c '. "$1/scripts/host/detect.sh"; cx_detect; printf %s "$CX_HOSTKEY"' _ "$ROOT")"
  "$REAL_PY" -I - "$AD/home/.conductor/hosts/$HK.json" "$STUBS" "$PY_DIR" <<'PY'
import json, os, sys
st, py = sys.argv[2], sys.argv[3]
b = {k: st + "/" + k for k in ("claude", "copilot", "grok", "agy", "gh")}
b.update({"git": "/usr/bin/git", "python3": py + "/python3", "ghcp_delegate": st + "/ghcp-delegate",
          "ghcp_models": st + "/ghcp-models", "ghcp_cloud": st + "/ghcp-cloud", "agy_delegate": st + "/agy-delegate"})
json.dump({"version": 1, "recorded_at": "2026-11-01T10:00:00Z", "plugin_version": os.environ["CXV"], "host": "linux",
           "hostkey": "test", "path": st + ":" + py + ":/usr/local/bin:/usr/bin:/bin", "path_source": "interactive",
           "bin": b, "copilot_home": None, "copilot_token_env": None}, open(sys.argv[1], "w"))
PY
  REPO="$AD/repo"
  mkdir -p "$REPO"; git -C "$REPO" init -q; printf 'hi\n' > "$REPO/README.md"; commit_all "$REPO"
  for W in t1 t2 other; do git -C "$REPO" worktree add -q -b "cx/$W" "$AD/wt-$W"; done
  mkdir -p "$REPO/.claude/worktrees"; git -C "$REPO" worktree add -q -b claude-a "$REPO/.claude/worktrees/a"
  O1="$AD/home/.conductor/out/t1"
}

sec_adapters() {
section "Phase 2 adapters: probe, argv, run, parse; worker environment; ledger (A1-A11, A14, parts of A27, A28, A30)"
local AD="$TMP/ad" ADL="$TMP/adapters.log" HK REPO W O1 b f lane st
ad_setup

# --- probes (free) and the preflight cache
ad -- grok probe
check "[X]   grok probe: the section 15.2 keys, version 1.0.70 on the pin, logged in, grok-4.7 listed, not cached" \
  eval 'rc_is 0 && [ "$(out_json version)" = 1.0.70 ] && outj_is version_ok true && outj_is logged_in true && outj_is model_ok true && outj_is cached false && out_json lane >/dev/null && out_json bin >/dev/null && out_json models >/dev/null'
ad -- grok probe
check "[X]   ... a second probe within 10 minutes answers from \$CX_HOME/state/preflight.json (cached true, no CLI call)" \
  eval 'rc_is 0 && outj_is cached true && [ "$(grep -c "^grok	" "$ADL")" = 2 ]'
ad -- copilot probe
check "[X]   copilot probe: copilot --version on the pin, then ghcp-models --json (an absolute GHCP_COPILOT_BIN), claude-opus-5.5 listed" \
  eval 'rc_is 0 && outj_is version_ok true && outj_is logged_in true && outj_is model_ok true && grep -q "^ghcp-models	.*copilot_bin=$STUBS/copilot" "$ADL"'
ad STUB_COPILOT_VERSION=1.0.106 -- copilot probe --refresh
check "[X]   copilot probe off the pin: version_ok false and no ghcp-models probe (free only on 1.0.105)" \
  eval 'rc_is 0 && outj_is version_ok false && outj_is logged_in null && [ "$(grep -c "^ghcp-models	" "$ADL")" = 1 ]'

# --- A1: every emitted flag is in the captured help
local A1_BAD=""
ad -- grok argv --out "$AD/a1/grok" --wt "$AD/wt-t1" --allow 'npm test'
b="$(flags_in "$AD/a1/grok/grok.argv" "$FIX/real/grok/help.txt")"; [ -z "$b" ] || A1_BAD="$A1_BAD [grok write: $b]"
ad -- grok argv --out "$AD/a1/grokr" --wt "$AD/wt-t1" --mode read
b="$(flags_in "$AD/a1/grokr/grok.argv" "$FIX/real/grok/help.txt")"; [ -z "$b" ] || A1_BAD="$A1_BAD [grok read: $b]"
grep -qz -- '^--always-approve$' "$AD/a1/grokr/grok.argv" && grep -qz -- '^read-only$' "$AD/a1/grokr/grok.argv" || A1_BAD="$A1_BAD [grok read: no read-only --always-approve]"
ad -- copilot argv --out "$AD/a1/cop" --wt "$AD/wt-t1" --allow 'npm test'
b="$(flags_in "$AD/a1/cop/copilot.argv" "$FIX/real/ghcp/ghcp-delegate-help.txt")"; [ -z "$b" ] || A1_BAD="$A1_BAD [ghcp-delegate: $b]"
ad -- copilot argv --out "$AD/a1/copf" --wt "$AD/wt-t1" --fusion max --mode review --add-dir "$AD"
b="$(flags_in "$AD/a1/copf/copilot.argv" "$FIX/real/ghcp/ghcp-delegate-help.txt")"; [ -z "$b" ] || A1_BAD="$A1_BAD [ghcp-delegate fusion: $b]"
for f in "$FIX"/real/ghcp/print-command-*.txt; do
  shell_argv "$f" "$AD/a1/pc.argv"
  b="$(flags_in "$AD/a1/pc.argv" "$FIX/real/copilot/help.txt")"; [ -z "$b" ] || A1_BAD="$A1_BAD [${f##*/}: $b]"
done
ad -- agy argv --out "$AD/a1/agy" --wt "$AD/wt-t1"
b="$(flags_in "$AD/a1/agy/agy.argv" "$FIX/real/agy/help.txt")"; [ -z "$b" ] || A1_BAD="$A1_BAD [agy raw: $b]"
printf '%s\0' agy --new-project --output-format json -p /model > "$AD/a1/reg.argv"
b="$(flags_in "$AD/a1/reg.argv" "$FIX/real/agy/help.txt")"; [ -z "$b" ] || A1_BAD="$A1_BAD [agy registration: $b]"
ad -- agy argv --out "$AD/a1/agyw" --wt "$AD/wt-t1" --mode review --model 'Gemini 4 Argon (High)' --add-dir "$AD"
b="$(flags_in "$AD/a1/agyw/agy.argv" "$FIX/real/antigravity/agy-delegate-help.txt")"; [ -z "$b" ] || A1_BAD="$A1_BAD [agy-delegate: $b]"
ad -- claude argv --out "$AD/a1/cl" --wt "$AD/wt-t1" --headless
b="$(flags_in "$AD/a1/cl/claude.argv" "$FIX/real/claude/help.txt")"; [ -z "$b" ] || A1_BAD="$A1_BAD [claude: $b]"
ad -- copilot-cloud argv --out "$AD/a1/cc" --gh-repo github.com/o/r --base-branch main --task-file "$ROOT/templates/repo-bundle/AGENTS.md"
b="$(flags_in "$AD/a1/cc/copilot-cloud.argv" "$FIX/real/ghcp/ghcp-cloud-help.txt")"; [ -z "$b" ] || A1_BAD="$A1_BAD [ghcp-cloud: $b]"
check "[A1]  every flag each adapter emits is in the captured help: grok 1.0.70 (write and read), ghcp-delegate and the Copilot argv it prints (real --print-command captures vs copilot 1.0.105 --help), agy raw and its registration (the SYNTHETIC agy help: agy --help is not captured), agy-delegate, claude -p, ghcp-cloud${A1_BAD:+:$A1_BAD}" test -z "$A1_BAD"
# A1 is "via --dry-run": the dry run of the same options prints exactly the argv those files hold
# (session uuids aside: each call draws a new one) and writes nothing into the out directory.
local A1D_BAD="" a1s
for a1s in "grok|grok|--allow|npm test" "grokr|grok|--mode|read" "cop|copilot|--allow|npm test" \
           "copf|copilot|--fusion|max|--mode|review|--add-dir|$AD" "agy|agy" \
           "agyw|agy|--mode|review|--model|Gemini 4 Argon (High)|--add-dir|$AD" "cl|claude|--headless" \
           "cc|copilot-cloud|--gh-repo|github.com/o/r|--base-branch|main|--task-file|$ROOT/templates/repo-bundle/AGENTS.md"; do
  IFS='|' read -r -a A1A <<< "$a1s"
  dry_same "${A1A[1]}" "$AD/a1/${A1A[0]}" --wt "$AD/wt-t1" "${A1A[@]:2}" || A1D_BAD="$A1D_BAD [${A1A[0]}: $DRY_WHY]"
done
check "[A1]  ... and argv --dry-run prints that same argv (printf %q, uuids aside) for every lane and variant, writing nothing into the out directory${A1D_BAD:+:$A1D_BAD}" test -z "$A1D_BAD"
ad -- agy argv --dry-run --wt "$AD/wt-t1"
check "[A17] argv --dry-run prints lane, model, effort, argv, env names, cwd and worktree, writes nothing and runs no executor" \
  eval 'rc_is 0 && out_has "lane: agy-opus (adapter agy, executor agy, pool google-claude-bucket)" && out_has "model: claude-opus-5-5-high" && out_has "argv: $STUBS/agy --model claude-opus-5-5-high --add-dir" && out_has "env unset: ANTHROPIC_API_KEY XAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY" && [ ! -e "$AD/wt-t1/.conductor" ] && ! grep -q "^agy	.*-p Read" "$ADL"'
ad -- copilot argv --dry-run --wt "$AD/wt-t1" --allow 'npm test'
check "[A17] the Copilot dry run shows ghcp-delegate's own --print-command line (free)" \
  eval 'rc_is 0 && out_has "copilot argv (ghcp-delegate --print-command): $STUBS/copilot -p" && out_has "--allow-tool write"'
ad -- copilot argv --dry-run --effort max
check "[X]   effort max never leaves Claude: copilot argv --effort max -> exit 1" eval 'rc_is 1 && no_signal'
ad -- agy argv --dry-run --effort xhigh
check "[X]   agy offers no xhigh (next pool): exit 1" eval 'rc_is 1 && no_signal'

# --- A2 and A14: success per lane, the worker environment
adr grok "$O1" STUB_GROK_RUN=ok "${SCRUB_PROBE[@]}" GROK_SANDBOX=off STUB_ENV_FILE="$AD/env.grok" -- --wt "$AD/wt-t1" --allow 'npm test'
check "[A2]  grok success: run exit 0, parse '0 ok', result.json v1 with lane, pool xai-weekly, model served = requested, session = the -s uuid, usage tokens, digest" \
  eval '[ "$ADR_RC" = 0 ] && [ "$PR" = "0 ok" ] && rj_is version 1 && rj_is lane grok && rj_is pool xai-weekly && rj_is model_served grok-4.7 && [ "$(rj session)" = "$("$REAL_PY" -I "$NORM" field "$O1/grok.meta.json" session_hint)" ] && rj_is usage.input 900 && grep -q "DIGEST:" "$O1/answer.txt" && [ -f "$AD/wt-t1/.conductor/prompt.txt" ] && [ -s "$O1/grok.usage.txt" ]'
check "[A14] worker environment (grok): worker-shims first on PATH, CX_WORKER=1, the GROK_* values; XAI_API_KEY, GROK_SANDBOX, ANTHROPIC_API_KEY and CLAUDE_PLUGIN_OPTION_* absent" \
  eval 'sed -n "/^== grok$/,/^== /p" "$AD/env.grok" > "$AD/env.grok.1"; grep -qx "PATH=$ROOT/worker-shims:$STUBS:.*" "$AD/env.grok.1" && grep -qx CX_WORKER=1 "$AD/env.grok.1" && grep -qx GROK_CLAUDE_HOOKS_ENABLED=false "$AD/env.grok.1" && grep -qx NO_COLOR=1 "$AD/env.grok.1" && ! grep -Eq "^(XAI_API_KEY|GROK_SANDBOX|ANTHROPIC_API_KEY|CLAUDE_PLUGIN_OPTION_[A-Z_]*)=" "$AD/env.grok.1"'
"$REAL_PY" -I "$NORM" emit --out "$O1" 2> "$AD/emit.err"
check "[A2]  emit: one CX_RESULT line (single-line json.dumps, ASCII) with path and status ok; no CX_DENIED for a clean run" \
  eval '[ "$(tj count "$AD/emit.err" CX_RESULT)" = 1 ] && tj linejson "$AD/emit.err" CX_RESULT && [ "$(tj line "$AD/emit.err" CX_RESULT status)" = ok ] && [ "$(tj line "$AD/emit.err" CX_RESULT path)" = "$O1/result.json" ] && ! grep -q "^CX_DENIED" "$AD/emit.err"'
"$REAL_PY" -I "$NORM" report --out "$O1" > "$AD/report.out"
check "[A2]  report: the digest, then a VERIFY THIS line naming the commands" \
  eval 'grep -q "^DIGEST: created cx-grok.txt.$" "$AD/report.out" && grep -q "^VERIFY THIS: .*npm test" "$AD/report.out"'
adr copilot "$O1" STUB_GHCP_RUN=ok "${SCRUB_PROBE[@]}" COPILOT_MODEL=gpt-x COPILOT_ALLOW_ALL=1 GH_TOKEN=t STUB_ENV_FILE="$AD/env.cop" -- --wt "$AD/wt-t1" --allow 'npm test'
check "[A2]  copilot success through ghcp-delegate (never raw copilot): ok, lane copilot-opus, served claude-opus-5.5, ai_credits 1.5; ghcp-delegate got --write --allow-shell 'npm test' --digest" \
  eval '[ "$PR" = "0 ok" ] && rj_is lane copilot-opus && rj_is model_served claude-opus-5.5 && rj_is cost.ai_credits 1.5 && grep -q "^ghcp-delegate	.*--write --allow-shell npm\\\\ test --timeout 1800s --digest" "$ADL"'
check "[A14] worker environment (copilot): COPILOT_MODEL, COPILOT_ALLOW_ALL, GH_TOKEN unset; GHCP_COPILOT_BIN = the recorded copilot; GHCP_USAGE_LOG under \$CX_HOME" \
  eval 'sed -n "/^== ghcp-delegate$/,/^== /p" "$AD/env.cop" > "$AD/env.cop.1"; ! grep -Eq "^(COPILOT_MODEL|COPILOT_ALLOW_ALL|GH_TOKEN)=" "$AD/env.cop.1" && grep -qx "GHCP_COPILOT_BIN=$STUBS/copilot" "$AD/env.cop.1" && grep -qx "GHCP_USAGE_LOG=$AD/home/.conductor/raw-usage.log" "$AD/env.cop.1" && grep -qx CX_WORKER=1 "$AD/env.cop.1"'
adr claude "$O1" -- --wt "$AD/wt-t1" --effort max --id t1
check "[A27] claude lane (default): no process; run prints the dispatch JSON; parse gives status dispatched, exit 0, with dispatch {worktree, host_path, prompt, effort max, task_file}; the running mark stays for cx-run --finish" \
  eval '[ "$ADR_RC" = 0 ] && [ "$PR" = "0 dispatched" ] && [ "$(out_json dispatch)" = claude-subagent ] && outj_is effort max && rj_is dispatch.worktree "$AD/wt-t1" && rj_is status dispatched && [ -s "$O1/running" ] && ! grep -q "^claude	.*-p" "$ADL"'
rm -f "$O1/running"
adr claude "$O1" STUB_CLAUDE_RUN=ok STUB_ENV_FILE="$AD/env.cl" "${SCRUB_PROBE[@]}" CLAUDE_CODE_ENTRYPOINT=sdk-ts CLAUDE_CODE_REMOTE=true CLAUDE_CODE_REMOTE_SESSION_ID=r CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE=cloud CLAUDE_CODE_SESSION_ID=s CLAUDE_CODE_SESSION_KIND=k CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_CHILD_SESSION=1 CLAUDE_CODE_ENVIRONMENT_KIND=x CLAUDECODE=1 AI_AGENT=claude CLAUDE_EFFORT=high CLAUDE_PLUGIN_ROOT=/p CLAUDE_PROJECT_DIR=/d -- --wt "$AD/wt-t1" --headless --allow 'npm test'
check "[A27] claude --headless: ok (served claude-opus-5-5; a haiku helper is no mismatch); the stub env lacks every scrubbed variable (the fixed list and any CLAUDE_CODE_REMOTE* / CLAUDE_CODE_SESSION_* name); cx-worker.json allows Bash(npm test) and denies the agent CLIs and cx-*" \
  eval '[ "$PR" = "0 ok" ] && rj_is model_served claude-opus-5-5 && sed -n "/^== claude$/,/^== /p" "$AD/env.cl" > "$AD/env.cl.1" && grep -qx CX_WORKER=1 "$AD/env.cl.1" && ! grep -Eq "^(CLAUDE_CODE_ENTRYPOINT|CLAUDE_CODE_REMOTE[A-Z_]*|CLAUDE_CODE_SESSION_[A-Z_]*|CLAUDE_CODE_CHILD_SESSION|CLAUDE_CODE_ENVIRONMENT_KIND|CLAUDECODE|AI_AGENT|CLAUDE_EFFORT|ANTHROPIC_API_KEY|CLAUDE_PLUGIN_ROOT|CLAUDE_PROJECT_DIR)=" "$AD/env.cl.1" && grep -q "\"Bash(npm test)\"" "$O1/cx-worker.json" && grep -q "\"Bash(cx-run:\\*)\"" "$O1/cx-worker.json" && grep -q "\"Bash(grok:\\*)\"" "$O1/cx-worker.json"'
local A14_BAD=""
worker_env_ok "$AD/env.grok" grok "$ROOT/worker-shims" GROK_DISABLE_AUTOUPDATER=1 GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_SKILLS_ENABLED=false \
  GROK_CLAUDE_MCPS_ENABLED=false GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false || A14_BAD="$A14_BAD [grok: $WENV_WHY]"
worker_env_ok "$AD/env.cop" ghcp-delegate "$ROOT/worker-shims" COPILOT_AUTO_UPDATE=false || A14_BAD="$A14_BAD [copilot: $WENV_WHY]"
worker_env_ok "$AD/env.cl" claude "$ROOT/worker-shims" || A14_BAD="$A14_BAD [claude: $WENV_WHY]"
check "[A14] section 15.6 for every grok, ghcp-delegate and claude -p call of a run: the worker shims first on PATH, CX_WORKER=1, NO_COLOR=1, the lane's auto-update switch forced off (over a caller's wrong value), and no ANTHROPIC/XAI/GEMINI/GOOGLE API key or CLAUDE_PLUGIN_OPTION_* (agy: its section)${A14_BAD:+:$A14_BAD}" test -z "$A14_BAD"

# --- A3: rc 0 with a denial -> 15
local A3_BAD=""
adr copilot "$O1" STUB_GHCP_RUN=denied-write -- --wt "$AD/wt-t1" --model gpt-6-luna
[ "$PR" = "15 denied" ] || A3_BAD="$A3_BAD [copilot denied-write: $PR]"
adr grok "$O1" STUB_GROK_RUN=denied -- --wt "$AD/wt-t1"
{ [ "$PR" = "15 denied" ] && [ "$(rj denied.0.detail)" = "Bash(npm install)" ]; } || A3_BAD="$A3_BAD [grok permission required: $PR]"
"$REAL_PY" -I "$NORM" emit --out "$O1" 2> "$AD/emit3.err"
check "[A3]  exit 0 is not success: Copilot GHCP_DENIED write (real denied-write capture) and grok 'permission required:' classify 15; CX_DENIED is emitted (agy: the agy section)${A3_BAD:+:$A3_BAD}" \
  eval '[ -z "$A3_BAD" ] && [ "$(tj line "$AD/emit3.err" CX_DENIED count)" = 1 ] && [ "$(tj line "$AD/emit3.err" CX_DENIED kinds)" = "[\"shell\"]" ]'
adr copilot "$O1" STUB_GHCP_RUN=autodenied-shell -- --wt "$AD/wt-t1" --model gpt-6-luna
check "[A3]  ... a denied shell call with an answer (real autodenied-shell) is not a failure: ok, the denial recorded" \
  eval '[ "$PR" = "0 ok" ] && rj_is denied.0.kind shell'
check "[P30] adapters (probes, argv, lanes, denials): no stub logged BILLABLE (every executor run carried a scenario knob)" eval '! grep -q "^BILLABLE" "$ADL"'
}
bg_section adapters sec_adapters
sec_adapters2() {
section "Phase 2 adapters: classification, the pin, ghcp's real captures, the cloud lane, slots, cancellation, ledger (A6-A11, A13, A30)"
local AD="$TMP/ad3" ADL="$TMP/adapters3.log" HK REPO W O1 b f lane st
ad_setup
# --- A6, A7, A8, A10: classification
adr copilot "$O1" STUB_GHCP_RUN=5149 CLAUDE_PLUGIN_OPTION_COPILOT_XHIGH_OK=true -- --wt "$AD/wt-t1" --effort xhigh
check "[A6]  Copilot #5149 (xhigh, 32,000 output tokens, empty answer) -> 2 failed with reason copilot#5149" \
  eval '[ "$PR" = "2 failed" ] && rj reason | grep -q "^copilot#5149"'
ad -- copilot argv --dry-run --effort xhigh
check "[X]   Copilot xhigh without option copilot_xhigh_ok=true -> exit 1" eval 'rc_is 1'
local A7_BAD=""
adr copilot "$O1" STUB_GHCP_RUN=quota -- --wt "$AD/wt-t1"; [ "$PR" = "10 quota" ] || A7_BAD="$A7_BAD [copilot $PR]"
adr grok "$O1" STUB_GROK_RUN=quota -- --wt "$AD/wt-t1"; [ "$PR" = "10 quota" ] || A7_BAD="$A7_BAD [grok $PR]"
check "[A7]  quota / rate-limit text -> 10: ghcp's exit (real capture over ghcp's synthetic quota text), grok's 429${A7_BAD:+:$A7_BAD}" test -z "$A7_BAD"
local A8_BAD=""
adr copilot "$O1" STUB_GHCP_RUN=fusion-fallback -- --wt "$AD/wt-t1" --fusion max
{ [ "$PR" = "21 model_mismatch" ] && rj reason | grep -q GHCP_FALLBACK; } || A8_BAD="$A8_BAD [copilot GHCP_FALLBACK: $PR]"
adr grok "$O1" STUB_GROK_RUN=mismatch -- --wt "$AD/wt-t1"
[ "$PR" = "21 model_mismatch" ] || A8_BAD="$A8_BAD [grok modelUsage: $PR]"
adr copilot "$O1" STUB_GHCP_RUN=mismatch -- --wt "$AD/wt-t1"
[ "$PR" = "21 model_mismatch" ] || A8_BAD="$A8_BAD [copilot models_used: $PR]"
check "[A8]  served model checks -> 21: GHCP_FALLBACK on a Fusion lane (real capture), grok modelUsage naming another model, Copilot models_used${A8_BAD:+:$A8_BAD}" test -z "$A8_BAD"
local A10_BAD=""
adr grok "$O1" STUB_GROK_RUN=error -- --wt "$AD/wt-t1"; { [ "$PR" = "2 failed" ] && rj reason | grep -q "no sessionId"; } || A10_BAD="$A10_BAD [error object: $PR]"
adr grok "$O1" STUB_GROK_RUN=auth -- --wt "$AD/wt-t1"; [ "$PR" = "11 auth" ] || A10_BAD="$A10_BAD [auth: $PR]"
check "[A10] grok: an error object without sessionId (rc 1) -> 2; 'You are not authenticated' -> 11${A10_BAD:+:$A10_BAD}" test -z "$A10_BAD"
local AX_BAD=""
adr claude "$O1" STUB_CLAUDE_RUN=mismatch -- --wt "$AD/wt-t1" --headless; [ "$PR" = "21 model_mismatch" ] || AX_BAD="$AX_BAD [claude: $PR]"
check "[X]   claude --headless: modelUsage naming another model -> 21${AX_BAD:+:$AX_BAD}" test -z "$AX_BAD"

# --- A9: version pin before any invocation
grep -c . "$ADL" > "$AD/n0"
adr grok "$O1" STUB_GROK_RUN=ok STUB_GROK_VERSION=1.0.71 -- --wt "$AD/wt-t1" --refresh
check "[A9]  grok 1.0.71 (pin 1.0.70) -> 26 VERSION_MISMATCH with one CX_SIGNAL, and grok was only asked --version and models (no run)" \
  eval '[ "$ADR_RC" = 26 ] && one_signal VERSION_MISMATCH && ! tail -n +"$(( $(cat "$AD/n0") + 1 ))" "$ADL" | grep -q "^grok	.*--prompt-file"'
adr copilot "$O1" STUB_GHCP_RUN=ok STUB_COPILOT_VERSION=1.0.106 -- --wt "$AD/wt-t1" --refresh
check "[A9]  copilot 1.0.106 (pin 1.0.105) -> 26 before ghcp-delegate runs" \
  eval '[ "$ADR_RC" = 26 ] && one_signal VERSION_MISMATCH && ! tail -n +"$(( $(cat "$AD/n0") + 1 ))" "$ADL" | grep -q "^ghcp-delegate	"'
ad CX_SIGNAL_OWNER=cx-run STUB_GROK_VERSION=1.0.71 -- grok run --out "$AD/own" --wt "$AD/wt-t1" --refresh
check "[X]   with CX_SIGNAL_OWNER set (cx-run owns the run's single signal) the adapter exits 26 with its note and no CX_SIGNAL" \
  eval 'rc_is 26 && no_signal && err_has "does not match the pin 1.0.70"'

# --- A11: the parsers on ghcp's real captures
local A11_BAD=""
"$REAL_PY" -I - "$FIX/ghcp-models.json" "$AD/catalog.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
c["models"].append({"id": "mai-code-1.1-flash", "name": "MAI Code 1.1 Flash", "vendor": "Microsoft", "policy": "enabled",
                    "price_category": "standard", "input_price": 50, "output_price": 200, "restricted_to": None})
json.dump(c, open(sys.argv[2], "w"))
PY
adr copilot "$O1" STUB_GHCP_RUN=ok-pong STUB_GHCP_MODELS_FILE="$AD/catalog.json" -- --wt "$AD/wt-t1" --model mai-code-1.1-flash
{ [ "$PR" = "0 ok" ] && rj_is model_served mai-code-1.1-flash && rj_is session 68fee466-5b1f-4366-9aab-ffd6686f05a4 && rj_is cost.ai_credits 0.2386 && rj_is usage.input 13046 && [ "$(cat "$O1/answer.txt")" = PONG ]; } || A11_BAD="$A11_BAD [ok-pong: $PR]"
cp "$RJ" "$AD/a11-ok-pong.json"
adr copilot "$O1" STUB_GHCP_RUN=ok-pong -- --wt "$AD/wt-t1"
[ "$PR" = "21 model_mismatch" ] || A11_BAD="$A11_BAD [ok-pong as Opus: $PR]"
adr copilot "$O1" STUB_GHCP_RUN=denied-write -- --wt "$AD/wt-t1" --model gpt-6-luna
{ [ "$PR" = "15 denied" ] && rj_is session 376c4518-0e42-4f32-b15b-942c181cb84d && [ "$(rj denied | tr -d ' ')" = '[{"kind":"write","detail":"GHCP_DENIED"},{"kind":"shell","detail":"GHCP_DENIED"}]' ]; } || A11_BAD="$A11_BAD [denied-write: $PR]"
cp "$RJ" "$AD/a11-denied-write.json"
adr copilot "$O1" STUB_GHCP_RUN=autodenied-shell -- --wt "$AD/wt-t1" --model gpt-6-luna
{ [ "$PR" = "0 ok" ] && rj_is session c8043864-1e72-4b0a-b022-4c5fd2271d28 && [ "$(rj denied | tr -d ' ')" = '[{"kind":"shell","detail":"GHCP_DENIED"}]' ] && [ -s "$O1/answer.txt" ]; } || A11_BAD="$A11_BAD [autodenied-shell: $PR]"
cp "$RJ" "$AD/a11-autodenied-shell.json"
adr copilot "$O1" STUB_GHCP_RUN=fusion-max-pong -- --wt "$AD/wt-t1" --fusion max
{ [ "$PR" = "0 ok" ] && rj_is lane copilot-fusion && rj_is model_served gpt-6-luna && rj_is fusion.profile hydrafusion-max && rj_is cost.ai_credits 0.0869 && rj_is effort_applied null; } || A11_BAD="$A11_BAD [fusion-max-pong: $PR]"
cp "$RJ" "$AD/a11-fusion-max-pong.json"
adr copilot "$O1" STUB_GHCP_RUN=auth -- --wt "$AD/wt-t1"
[ "$PR" = "11 auth" ] || A11_BAD="$A11_BAD [auth: $PR]"
check "[A11] parsers on ghcp's real captures: ok-pong (session, credits, tokens, answer PONG; as an Opus request it is a mismatch), denied-write (write and shell), autodenied-shell (an answer and a denied shell call: ok), fusion-max-pong (profile hydrafusion-max, served gpt-6-luna), auth${A11_BAD:+:$A11_BAD}" test -z "$A11_BAD"
# Provenance: every real Copilot recording (tests/fixtures/real/copilot/*.jsonl) was parsed above
# through ghcp's real output for it, and the result agrees with Copilot's own data: the JSONL
# sessionId, totalNanoAiu / 1e9 (ghcp rounds to 4 places) and every modelMetrics model.
A11_PROV="$("$REAL_PY" -I - "$FIX/real/copilot" "$AD" <<'PY'
import glob, json, os, re, sys
src, ad = sys.argv[1], sys.argv[2]
bad, n = [], 0
for j in sorted(glob.glob(os.path.join(src, "*.jsonl"))):
    name = os.path.basename(j)[:-len(".jsonl")]
    n += 1
    rp = os.path.join(ad, "a11-%s.json" % name)
    if not os.path.exists(rp):
        bad.append(name + ": never parsed")
        continue
    r = json.load(open(rp))
    sid = re.search(r'"sessionId":\s*"([^"]+)"', open(j).read()).group(1)
    u = json.load(open(os.path.join(src, name + ".usage.json")))
    if r.get("session") != sid:
        bad.append("%s: session %s, recording %s" % (name, r.get("session"), sid))
    cr = (r.get("cost") or {}).get("ai_credits")
    if cr is None or abs(cr - u["totalNanoAiu"] / 1e9) > 1e-4:
        bad.append("%s: ai_credits %s, recording %s" % (name, cr, u["totalNanoAiu"] / 1e9))
    seen = set(r.get("models_seen") or []) | {r.get("model_served")}
    miss = set(u.get("modelMetrics") or {}) - seen
    if miss:
        bad.append("%s: models %s not seen" % (name, sorted(miss)))
print("%d %s" % (n, "; ".join(bad)))
PY
)"
check "[A11] ... and each of the real Copilot recordings (got ${A11_PROV%% *}: ok-pong, denied-write, autodenied-shell, fusion-max-pong) agrees with what the parser made of ghcp's real output for it: session id, AI credits (totalNanoAiu) and served models${A11_PROV#* }" \
  eval '[ "${A11_PROV%% *}" = 4 ] && [ -z "${A11_PROV#* }" ]'
# Every Phase 0 capture is used: each real/ghcp derivation is replayed by some check, and every
# captured help file is an A1 reference.
local A11_USE=""
for f in "$FIX"/real/ghcp/*.out; do f="${f##*/}"; grep -q "STUB_GHCP_RUN=${f%.out} " "$HERE/run-tests.sh" || A11_USE="$A11_USE [real/ghcp/${f%.out} never replayed]"; done
for f in "$FIX"/real/*/*help*.txt; do f="${f#"$FIX/"}"; grep -qF "\$FIX/$f\"" "$HERE/run-tests.sh" || A11_USE="$A11_USE [$f is no A1 reference]"; done
check "[A11] ... every Phase 0 capture is used: each real/ghcp replay (ok-pong, denied-write, autodenied-shell, fusion-max-pong, fusion-fallback, auth, quota) runs in a check and each captured --help (copilot, grok, claude, agy-delegate, ghcp-delegate, ghcp-cloud) is an A1 reference${A11_USE:+:$A11_USE}" test -z "$A11_USE"

# --- A30 (part): the Copilot cloud agent lane
printf '%s\n' '<!-- cx-task {"id": "t1", "base": "abc", "lane": "copilot-cloud", "effort": "high", "allowed_paths": ["src/**"], "lockfiles": false, "commands": ["npm test"]} -->' \
  '# Task t1: add greet' '## Goal' 'Add greet() to src/greet.js.' '## Acceptance tests' '- Must pass: `npm test`' \
  '## Allowed changes' 'Only paths matching: `src/**`. Lockfiles: no.' '## Forbidden' \
  'Editing .conductor/task.md; installing, upgrading or patching dependencies; committing, pushing or branching; starting subagents or other coding agents.' \
  '## Output contract' 'End with exactly one line: DIGEST: <one sentence>.' > "$AD/task.md"
rm -rf -- "$AD/cc"; mkdir -p "$AD/cc"
ad -- copilot-cloud argv --out "$AD/cc" --gh-repo github.com/o/r --base-branch main --task-file "$AD/task.md"
ad STUB_GH_AGENT_TASK=ok STUB_GH_TASK_FILE="$AD/gh-task.txt" -- copilot-cloud run --out "$AD/cc"
PR="$("$ADP/copilot-cloud.sh" parse --out "$AD/cc" 2>/dev/null)"; RJ="$AD/cc/result.json"
check "[A30] copilot-cloud: ghcp-cloud create -R github.com/o/r --base main - hands gh agent-task the rendered section 6.4 contract (goal, acceptance tests, allowed changes; no ban on committing, pushing or branching; a PR delivery); result.json records the task and PR 42; no pool slot" \
  eval '[ "$PR" = "0 ok" ] && cmp -s "$AD/gh-task.txt" "$AD/cc/cloud-task.md" && grep -qx "## Acceptance tests" "$AD/gh-task.txt" && grep -q "src/\\*\\*" "$AD/gh-task.txt" && ! grep -q "committing, pushing or branching" "$AD/gh-task.txt" && grep -q "Open one pull request against main" "$AD/gh-task.txt" && rj_is cloud.pr 42 && rj_is cloud.task 0aa1b2c3-0000-4000-8000-000000000042 && rj_is cloud.repo github.com/o/r && grep -q "^gh	.*argv: agent-task create -F - --repo github.com/o/r --base main$" "$ADL" && rj_is pool copilot-credits'

# --- slots and cancellation
mkdir -p "$AD/home/.conductor/locks"
local h1 h2 h3
h1="$(hold "$AD/home/.conductor/locks/copilot.1" -x "$AD/h1")"; h2="$(hold "$AD/home/.conductor/locks/copilot.2" -x "$AD/h2")"; h3="$(hold "$AD/home/.conductor/locks/copilot.3" -x "$AD/h3")"
wait_file "$AD/h1"; wait_file "$AD/h2"; wait_file "$AD/h3"
grep -c . "$ADL" > "$AD/n0"
adr copilot "$O1" STUB_GHCP_RUN=ok -- --wt "$AD/wt-t1" --no-wait
check "[A13] adapter run takes the pool slot: with every copilot slot held, --no-wait -> 28 NO_CAPACITY at once (one CX_SIGNAL), ghcp-delegate never ran, no running mark left" \
  eval '[ "$ADR_RC" = 28 ] && one_signal NO_CAPACITY && ! tail -n +"$(( $(cat "$AD/n0") + 1 ))" "$ADL" | grep -q "^ghcp-delegate	" && [ ! -e "$O1/running" ]'
mkdir -p "$AD/job"
( env HOME="$AD/home" CX_HOME="$AD/home/.conductor" CLAUDE_CONFIG_DIR="$AD/cfg" STUB_LOG="$ADL" STUB_GHCP_RUN=ok CX_SLOT_WAIT_SECS=60 CX_JOB_DIR="$AD/job" \
    "$ADP/copilot.sh" run --out "$O1" --wt "$AD/wt-t1" > "$AD/q.out" 2> "$AD/q.err"; printf '%s\n' "$?" > "$AD/q.rc" ) &
local qp=$! qt0=$SECONDS
wait_file "$AD/job/queued"
kill -TERM "$(pgrep -o -f "$ADP/copilot.sh run --out $O1")" 2>/dev/null
wait "$qp" 2>/dev/null
O="$AD/q.out" E="$AD/q.err" RC="$(cat "$AD/q.rc" 2>/dev/null)"
check "[X]   TERM while run waits for a slot (CX_JOB_DIR/queued says copilot): 130 CANCELLED at once, the queued marker and the running mark removed, rc 130 written, ghcp-delegate never ran" \
  eval 'rc_is 130 && one_signal CANCELLED && [ $((SECONDS - qt0)) -lt 30 ] && [ ! -e "$AD/job/queued" ] && [ ! -e "$O1/running" ] && [ "$(cat "$O1/rc")" = 130 ] && ! tail -n +"$(( $(cat "$AD/n0") + 1 ))" "$ADL" | grep -q "^ghcp-delegate	"'
kill "$h1" "$h2" "$h3" 2>/dev/null; wait "$h1" "$h2" "$h3" 2>/dev/null
# ad_bg NAME VAR=VALUE... -- LANE ARGS...: one adapter run in the background; its rc lands in $AD/NAME.rc.
ad_bg() {
  local n="$1"; shift
  local -a ev=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done
  shift
  ( env HOME="$AD/home" CX_HOME="$AD/home/.conductor" CLAUDE_CONFIG_DIR="$AD/cfg" STUB_LOG="$ADL" ${ev[@]+"${ev[@]}"} \
      "$ADP/$1.sh" "${@:2}" > "$AD/$n.out" 2> "$AD/$n.err"; printf '%s\n' "$?" > "$AD/$n.rc" ) &
  BG_P=$!
}
# A TERM that lands the moment the keeper has written the executor's session id, before the
# adapter has read it: the session must still be killed and recorded for cx-job kill.
local sp sid sr_bad="" it_t0 it_dt dpid spid2
rm -rf "$AD/sr" "$AD/job2"; mkdir -p "$AD/job2"
ad_bg sr STUB_GROK_RUN=sleep STUB_GROK_SLEEP=60 CX_JOB_DIR="$AD/job2" -- grok run --out "$AD/sr" --wt "$AD/wt-t1"
sp=$BG_P
until [ -s "$AD/sr/grok.sid" ] || ! kill -0 "$sp" 2>/dev/null; do :; done
kill -TERM "$(pgrep -o -f "$ADP/grok.sh run --out $AD/sr")" 2>/dev/null
wait "$sp" 2>/dev/null
sid="$(cat "$AD/sr/grok.sid" 2>/dev/null)"
for ((i = 0; i < 50; i++)); do ps -eo sid= | tr -d ' ' | grep -qx "${sid:-none}" || break; sleep 0.1; done
[ "$(cat "$AD/sr.rc" 2>/dev/null)" = 130 ] || sr_bad="$sr_bad [rc $(cat "$AD/sr.rc" 2>/dev/null)]"
grep -qx "${sid:-none}" "$AD/job2/sids" 2>/dev/null || sr_bad="$sr_bad [sid $sid not in sids]"
if ps -eo sid= | tr -d ' ' | grep -qx "${sid:-none}"; then sr_bad="$sr_bad [session $sid still runs]"; pkill -KILL -s "$sid" 2>/dev/null; fi
check "[X]   TERM the moment the executor's session id is written (before the adapter read it): 130, the executor's session is killed, and its id is in \$CX_JOB_DIR/sids (written by the keeper before anything else)${sr_bad:+:$sr_bad}" test -z "$sr_bad"
# A TERM-ignoring executor with a TERM-ignoring child in another process group of its session:
# one TERM to the adapter ends both after CX_KILL_GRACE_SECS (2 here; default 10), not at
# timeout's own --kill-after=30s.
rm -rf "$AD/it"; rm -f "$AD/it.pid"
ad_bg it STUB_GROK_RUN=ignoreterm STUB_GROK_DAEMON_PID="$AD/it.pid" CX_KILL_GRACE_SECS=2 -- grok run --out "$AD/it" --wt "$AD/wt-t1"
sp=$BG_P
wait_file "$AD/it.pid"; sleep 0.3
it_t0=$SECONDS
kill -TERM "$(pgrep -o -f "$ADP/grok.sh run --out $AD/it")" 2>/dev/null
wait "$sp" 2>/dev/null
it_dt=$((SECONDS - it_t0))
dpid="$(cat "$AD/it.pid" 2>/dev/null)"
check "[X]   a TERM-ignoring executor (and its TERM-ignoring child in another process group): one TERM, the adapter exits 130 after the grace (${it_dt} s, under 15; timeout alone would take 30) and the child is gone too" \
  eval '[ "$(cat "$AD/it.rc")" = 130 ] && [ "$it_dt" -lt 15 ] && [ -n "$dpid" ] && ! alive "$dpid"'
check "[X]   ... the default grace is 10 s (cxa_wait_exec)" grep -q 'grace="${CX_KILL_GRACE_SECS:-10}"' "$ROOT/scripts/lib/adapter.sh"
# An executor that leaves processes behind: the one in its session is killed with the run, the
# setsid one survives but never got the slot's descriptor, so the slot is free at once.
rm -f "$AD/dm.pid" "$AD/dm.pid.setsid"
adr grok "$O1" STUB_GROK_RUN=daemon STUB_GROK_DAEMON_PID="$AD/dm.pid" CLAUDE_PLUGIN_OPTION_CAP_GROK=1 -- --wt "$AD/wt-t1"
dpid="$(cat "$AD/dm.pid" 2>/dev/null)"; spid2="$(cat "$AD/dm.pid.setsid" 2>/dev/null)"
check "[X]   leftovers never hold the pool slot: an executor's same-session child is killed with the run; its setsid child holds no slot or lock descriptor, and grok.1 is free right after the run (cap_grok=1)" \
  eval '[ "$PR" = "0 ok" ] && [ -n "$dpid" ] && ! alive "$dpid" && [ -n "$spid2" ] && ! ls -l "/proc/$spid2/fd" 2>/dev/null | grep -q "/locks/" && flock -n "$AD/home/.conductor/locks/grok.1" true'
[ -z "$spid2" ] || kill -KILL "$spid2" 2>/dev/null
# The Copilot token reaches ghcp-delegate through its environment, never a command line.
mkdir -p "$AD/home/.conductor/secrets"; (umask 077; printf 'github_pat_SECRETVALUE123\n' > "$AD/home/.conductor/secrets/copilot-token")
rm -rf "$AD/tok"; : > "$AD/env.tok"
ad_bg tok STUB_GHCP_RUN=sleep STUB_GHCP_SLEEP=3 STUB_ENV_FILE="$AD/env.tok" -- copilot run --out "$AD/tok" --wt "$AD/wt-t1"
sp=$BG_P
for ((i = 0; i < 100; i++)); do grep -q '^== ghcp-delegate$' "$AD/env.tok" 2>/dev/null && break; sleep 0.05; done
local TOK_CMD
TOK_CMD="$(grep -l 'SECRETVALU[E]123' /proc/[0-9]*/cmdline 2>/dev/null | head -n 3 | tr '\n' ' ')"   # [E]: never grep's own argv
wait "$sp" 2>/dev/null
rm -f "$AD/home/.conductor/secrets/copilot-token"
check "[X]   the Copilot token file signs ghcp-delegate in through its environment (COPILOT_GITHUB_TOKEN in its env) and is on no process's command line during the run (timeout, env, the executor)${TOK_CMD:+: in $TOK_CMD}" \
  eval '[ "$(cat "$AD/tok.rc")" = 0 ] && [ -z "$TOK_CMD" ] && grep -qx "COPILOT_GITHUB_TOKEN=github_pat_SECRETVALUE123" "$AD/env.tok"'
# The preflight cache is per caller side: a green direct probe never answers a forwarded call.
ad -- grok probe --refresh
ad -- grok probe
local pc1=""; outj_is cached true && pc1=direct-cached
ad CX_FORWARDED=1 -- grok probe
check "[X]   the preflight cache key has the caller side: a direct probe is cached (got: ${pc1:-not cached}), the same probe forwarded from Git Bash (CX_FORWARDED=1) is not answered from it" \
  eval '[ "$pc1" = direct-cached ] && rc_is 0 && outj_is cached false'

# --- ledger
"$REAL_PY" -I - "$AD/r1.json" <<'PY'
import datetime, json, sys
ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"version": 1, "ts": ts, "id": "t1", "pool": "copilot-credits", "status": "ok",
           "cost": {"ai_credits": 1.25}, "raw": {"stdout": "x"}, "notes": ["n"]}, open(sys.argv[1], "w"))
PY
local i lp=()
for i in 1 2 3 4; do CLAUDE_CODE_SESSION_ID=sess-1 CLAUDE_EFFORT=xhigh "$REAL_PY" -I "$LEDGER" append --ledger "$AD/l/ledger.jsonl" "$AD/r1.json" > /dev/null & lp+=("$!"); done
wait "${lp[@]}"
check "[X]   ledger.py append: 4 concurrent appends give 4 whole lines (flock + fsync), without raw and notes, with claude_session and claude_effort; mode 0600" \
  eval '[ "$(grep -c . "$AD/l/ledger.jsonl")" = 4 ] && ! grep -q "\"raw\"\\|\"notes\"" "$AD/l/ledger.jsonl" && [ "$(grep -c "\"claude_session\": \"sess-1\", \"claude_effort\": \"xhigh\"" "$AD/l/ledger.jsonl")" = 4 ] && [ "$(stat -c %a "$AD/l/ledger.jsonl")" = 600 ]'
check "[X]   ledger.py month --pool copilot-credits sums cost.ai_credits (5.0); tail -n 1 prints the last line" \
  eval '[ "$("$REAL_PY" -I "$LEDGER" month --pool copilot-credits --ledger "$AD/l/ledger.jsonl")" = 5.0 ] && [ "$("$REAL_PY" -I "$LEDGER" tail -n 1 --ledger "$AD/l/ledger.jsonl" | wc -l)" = 1 ] && [ "$("$REAL_PY" -I "$LEDGER" month --pool xai-weekly --ledger "$AD/l/ledger.jsonl")" = 0.0 ]'
cp "$AD/l/ledger.jsonl" "$AD/l/before"
"$REAL_PY" -I "$LEDGER" append --ledger "$AD/l/ledger.jsonl" "$AD/r1.json" > /dev/null
check "[X]   the ledger is append-only: an append keeps every earlier byte" eval 'cmp -s "$AD/l/before" <(head -c "$(stat -c %s "$AD/l/before")" "$AD/l/ledger.jsonl")'

# --- the adapter log is free of billable calls; no bytecode written into the plugin
check "[P30] adapters: no stub logged BILLABLE (every executor run carried a scenario knob)" eval '! grep -q "^BILLABLE" "$ADL"'
check "[X]   no __pycache__ anywhere in the plugin (normalize.py loads cxlib.py with bytecode writing off)" \
  test -z "$(cd "$ROOT" && find . -path ./.git -prune -o -name __pycache__ -print)"
local HV_AD=""
for lane in copilot grok agy claude copilot-cloud; do
  run "$ADP/$lane.sh" --version
  { rc_is 0 && [ "$(cat "$O")" = "adapter-$lane $CXV" ]; } || HV_AD="$HV_AD [$lane --version]"
  run "$ADP/$lane.sh" --help
  { rc_is 0 && [ "$(cat "$O")" = "$(awk 'NR <= 2 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$ADP/$lane.sh")" ]; } || HV_AD="$HV_AD [$lane --help]"
done
check "[X]   each adapter answers --help (its header) and --version${HV_AD:+:$HV_AD}" test -z "$HV_AD"
}
bg_section adapters2 sec_adapters2
sec_adapters_agy() {
section "Phase 2 adapters: the agy lane (raw and wrapper; A2-A5, A7, A8, A14, A28)"
local AD="$TMP/ad2" ADL="$TMP/adapters-agy.log" HK REPO W O1 t0
ad_setup
adr agy "$O1" STUB_AGY_RUN=ok "${SCRUB_PROBE[@]}" STUB_ENV_FILE="$AD/env.agy" -- --wt "$AD/wt-t1" --repo "$REPO"
check "[A2]  agy raw success: ok, served = init.model claude-opus-5-5-high, registration in the worktree, /usage before and after (quota_delta), the launch lock released at init" \
  eval '[ "$PR" = "0 ok" ] && rj_is model_served claude-opus-5-5-high && rj_is pool google-claude-bucket && grep -q "^agy	cwd=$AD/wt-t1	argv: --new-project --output-format json -p /model$" "$ADL" && [ -s "$O1/agy.usage.before.json" ] && rj_is cost.quota_delta.claude_gpt 0 && grep -qx "init claude-opus-5-5-high" "$O1/agy.events"'
adr agy "$O1" STUB_AGY_DELEGATE_RUN=ok "${SCRUB_PROBE[@]}" STUB_ENV_FILE="$AD/env.agyw" -- --wt "$AD/wt-t1" --agy-mode wrapper
check "[A14] agy wrapper lane: the shim set without agy (\$CX_HOME/shimsets/agy) is first on PATH, so agy-delegate finds the real agy; model_served null and the unverified note; never 21" \
  eval '[ "$PR" = "0 ok" ] && rj_is model_served null && grep -q "AGY_USAGE.model echoes the request" "$RJ" && [ -d "$AD/home/.conductor/shimsets/agy" ] && [ ! -e "$AD/home/.conductor/shimsets/agy/agy" ] && [ -x "$AD/home/.conductor/shimsets/agy/agy-delegate" ] && grep -q "^agy-delegate	.*agy=$STUBS/agy	" "$ADL" && grep -q "^PATH=$AD/home/.conductor/shimsets/agy:" "$AD/env.agyw"'
local A14_BAD=""
worker_env_ok "$AD/env.agy" agy "$ROOT/worker-shims" AGY_CLI_DISABLE_AUTO_UPDATE=true || A14_BAD="$A14_BAD [agy raw: $WENV_WHY]"
worker_env_ok "$AD/env.agyw" agy-delegate "$AD/home/.conductor/shimsets/agy" AGY_CLI_DISABLE_AUTO_UPDATE=true "AGY_USAGE_LOG=$AD/home/.conductor/raw-usage.log" || A14_BAD="$A14_BAD [agy wrapper: $WENV_WHY]"
check "[A14] section 15.6 for agy: every agy call of a raw run (/usage, the registration, the run) and the agy-delegate call of a wrapper run get the worker environment (CX_WORKER=1, NO_COLOR=1, AGY_CLI_DISABLE_AUTO_UPDATE=true over a wrong value, no API key or CLAUDE_PLUGIN_OPTION_*), shims first on PATH (the wrapper: the set without agy)${A14_BAD:+:$A14_BAD}" test -z "$A14_BAD"
adr agy "$O1" STUB_AGY_DELEGATE_RUN=ok -- --wt "$AD/wt-t1" --mode review --model 'Gemini 4 Argon (High)'
check "[X]   a Gemini review is always agy-delegate (lane agy-gemini, pool google-gemini)" eval '[ "$PR" = "0 ok" ] && rj_is lane agy-gemini && rj_is pool google-gemini'
local A3_BAD=""
adr agy "$O1" STUB_AGY_RUN=denied -- --wt "$AD/wt-t1"
{ [ "$PR" = "15 denied" ] && rj_is denied.0.kind write; } || A3_BAD="$A3_BAD [agy denied_actions: $PR]"
check "[A3]  agy: denied_actions in the result event (rc 0) -> 15 denied, kind write${A3_BAD:+:$A3_BAD}" test -z "$A3_BAD"
# --- A4: agy result-then-hang
t0=$SECONDS
adr agy "$O1" STUB_AGY_RUN=hang -- --wt "$AD/wt-t1"
local A4_T=$((SECONDS - t0))
check "[A4]  agy result-then-hang (the stub ignores TERM after its result): the session is SIGKILLed 5 s after the result event, status ok (${A4_T} s)" \
  eval '[ "$PR" = "0 ok" ] && grep -qx killed_after_result "$O1/agy.events" && [ "$A4_T" -ge 4 ] && [ "$A4_T" -le 45 ] && grep -q "killed 5 s later" "$RJ"'

# --- A5 and A28: wrong tree, the pause, the .claude/worktrees exclusion, running marks
adr agy "$O1" STUB_AGY_RUN=wrongtree STUB_AGY_OTHER="$REPO/.claude/worktrees/a" -- --wt "$AD/wt-t1" --repo "$REPO"
check "[A28] the agy snapshot ignores Claude Code's worktrees under the main checkout's .claude/worktrees (a write there is no WRONG_TREE)" \
  eval '[ "$PR" = "0 ok" ] && ! grep -q "^== $REPO/.claude/worktrees" "$O1/agy.trees.before" && grep -qx "== $REPO" "$O1/agy.trees.before" && ! grep -qx "== $AD/wt-t1" "$O1/agy.trees.before"'
mkdir -p "$AD/home/.conductor/out/busy"; printf '%s\n' "$AD/wt-other" > "$AD/home/.conductor/out/busy/running"
adr agy "$O1" STUB_AGY_RUN=wrongtree STUB_AGY_OTHER="$AD/wt-other" -- --wt "$AD/wt-t1"
check "[X]   a worktree another lane marked running (\$CX_HOME/out/*/running) is left out: its changes are no WRONG_TREE" eval '[ "$PR" = "0 ok" ]'
rm -f "$AD/home/.conductor/out/busy/running" "$AD/wt-other/cx-wrong.txt"
adr agy "$O1" STUB_AGY_RUN=wrongtree STUB_AGY_OTHER="$AD/wt-other" -- --wt "$AD/wt-t1"
check "[A5]  agy writes into another worktree -> 22 wrong_tree naming it, and \$CX_HOME/state/agy-paused is set" \
  eval '[ "$PR" = "22 wrong_tree" ] && grep -q "$AD/wt-other" "$O1/agy.trees.changed" && [ -s "$AD/home/.conductor/state/agy-paused" ]'
adr agy "$O1" STUB_AGY_RUN=ok -- --wt "$AD/wt-t1"
check "[A5]  ... the next agy dispatch is refused with 28 NO_CAPACITY (one CX_SIGNAL, last) before any agy call, until the pause file is removed (cx-job unpause agy)" \
  eval '[ "$ADR_RC" = 28 ] && one_signal NO_CAPACITY && err_has "agy dispatch is paused" && [ ! -e "$O1/agy.out" ]'
ad -- agy probe
check "[A5]  ... and the probe reports paused true (never answered from a cache entry of before the pause)" eval 'rc_is 0 && outj_is paused true'
rm -f "$AD/home/.conductor/state/agy-paused"
adr agy "$O1" STUB_AGY_RUN=ok -- --wt "$AD/wt-t1"
check "[A5]  ... once the pause is lifted agy runs again" eval '[ "$PR" = "0 ok" ]'
# A commit in another worktree leaves its status clean: HEAD, the refs, the config and the hooks
# are in the snapshot too.
adr agy "$O1" STUB_AGY_RUN=wrongcommit STUB_AGY_OTHER="$REPO" -- --wt "$AD/wt-t1" --repo "$REPO"
check "[A5]  agy commits in the main checkout (its status stays clean) -> 22 wrong_tree naming it, and agy is paused" \
  eval '[ "$PR" = "22 wrong_tree" ] && grep -qx "$REPO" "$O1/agy.trees.changed" && [ -s "$AD/home/.conductor/state/agy-paused" ]'
rm -f "$AD/home/.conductor/state/agy-paused"
local WT_BAD="" agt="$AD/agt"
mkdir -p "$agt"
agy_snap() {  # NAME: the adapter's agy_trees on wt-t1 (the repo's other trees and its shared state)
  env A_WT="$AD/wt-t1" A_REPO="$REPO" bash -c 'eval "$(sed -n "/^agy_trees() {/,/^}/p" "$1")"; agy_trees "$2"' _ "$ADP/agy.sh" "$agt/$1"
}
agy_diff() { "$REAL_PY" -I "$NORM" trees-diff "$agt/$1" "$agt/$2" > "$agt/$1.changed"; }
agy_snap b1; git -C "$REPO" branch -q side; agy_snap a1
agy_diff b1 a1 && WT_BAD="$WT_BAD [a new branch not seen]"
agy_snap b2; printf '#!/bin/sh\n' > "$REPO/.git/hooks/pre-commit"; agy_snap a2
agy_diff b2 a2 && WT_BAD="$WT_BAD [a planted hook not seen]"
rm -f "$REPO/.git/hooks/pre-commit"
agy_snap b3; git -C "$REPO" config core.hooksPath /tmp/evil; agy_snap a3
agy_diff b3 a3 && WT_BAD="$WT_BAD [core.hooksPath not seen]"
git -C "$REPO" config --unset core.hooksPath
printf '.env\n' > "$REPO/.gitignore"; git -C "$REPO" add .gitignore; git -C "$REPO" -c user.email=t@x -c user.name=t commit -qm ignore
agy_snap b4; printf 'SECRET=1\n' > "$REPO/.env"; agy_snap a4
agy_diff b4 a4 && WT_BAD="$WT_BAD [an ignored .env not seen]"
rm -f "$REPO/.env"
agy_snap b5; git -C "$REPO" config branch.cx/t9.remote origin; git -C "$AD/wt-t1" -c user.email=t@x -c user.name=t commit -q --allow-empty -m own; agy_snap a5
agy_diff b5 a5 || WT_BAD="$WT_BAD [the task's own commit or git push -u's branch.* config flagged: $(cat "$agt/b5.changed")]"
check "[A5]  the agy snapshot sees a moved or new branch, a planted hook, core.hooksPath and an ignored .env outside the worktree, but not the task's own commit or the branch.* keys git push -u writes${WT_BAD:+:$WT_BAD}" test -z "$WT_BAD"
# Running marks: only a live run's (its cx-run holds .run.lock) or a finished ok/dispatched task's
# count; a failed task's mark or a dead cx-run's is stale.
local MK="$AD/home/.conductor/out" MK_BAD=""
mkdir -p "$MK/mk-fail" "$MK/mk-ok" "$MK/mk-dead" "$MK/mk-live"
for i in fail ok dead live; do printf '%s\n' "$AD/mk-$i-tree" > "$MK/mk-$i/running"; done
printf '{"status": "denied"}\n' > "$MK/mk-fail/result.json"; printf '{"status": "ok"}\n' > "$MK/mk-ok/result.json"
: > "$MK/mk-dead/.run.lock"; : > "$MK/mk-live/.run.lock"
local mkh; mkh="$(hold "$MK/mk-live/.run.lock" -x "$AD/mk.held")"; wait_file "$AD/mk.held"
env HOME="$AD/home" CXA_HOME="$AD/home/.conductor" CX_LIB="$ROOT/scripts/lib" bash -c 'cxa_py() { python3 -I "$CX_LIB/normalize.py" "$@"; }; eval "$(sed -n "/^agy_marks() {/,/^}/p" "$1")"; agy_marks "$2"' _ "$ADP/agy.sh" "$agt/marks"
kill "$mkh" 2>/dev/null; wait "$mkh" 2>/dev/null
grep -qx "$AD/mk-ok-tree" "$agt/marks" || MK_BAD="$MK_BAD [ok mark dropped]"
grep -qx "$AD/mk-live-tree" "$agt/marks" || MK_BAD="$MK_BAD [live mark dropped]"
grep -qx "$AD/mk-fail-tree" "$agt/marks" && MK_BAD="$MK_BAD [a failed task's mark kept]"
grep -qx "$AD/mk-dead-tree" "$agt/marks" && MK_BAD="$MK_BAD [a dead cx-run's mark kept]"
rm -rf "$MK"/mk-*
check "[X]   agy_marks keeps the marks of live runs and of ok tasks waiting for Step 3, and ignores a failed task's mark and a killed cx-run's (no result, its .run.lock free)${MK_BAD:+:$MK_BAD}" test -z "$MK_BAD"
# The pause is checked again after the slot wait: a run that queued before another run paused agy
# never launches it.
mkdir -p "$AD/home/.conductor/locks"
local ph; ph="$(hold "$AD/home/.conductor/locks/agy.1" -x "$AD/ph.held")"; wait_file "$AD/ph.held"
rm -rf -- "${O1:?}" "$AD/pj"; mkdir -p "$O1" "$AD/pj"; grep -c . "$ADL" > "$AD/n0"
( env HOME="$AD/home" CX_HOME="$AD/home/.conductor" CLAUDE_CONFIG_DIR="$AD/cfg" STUB_LOG="$ADL" STUB_AGY_RUN=ok CLAUDE_PLUGIN_OPTION_CAP_AGY=1 CX_SLOT_WAIT_SECS=30 CX_JOB_DIR="$AD/pj" \
    "$ADP/agy.sh" run --out "$O1" --wt "$AD/wt-t1" > "$AD/pq.out" 2> "$AD/pq.err"; printf '%s\n' "$?" > "$AD/pq.rc" ) &
local pqp=$!
wait_file "$AD/pj/queued"
mkdir -p "$AD/home/.conductor/state"; printf '{"id": "other"}\n' > "$AD/home/.conductor/state/agy-paused"
kill "$ph" 2>/dev/null; wait "$ph" 2>/dev/null
wait "$pqp" 2>/dev/null
O="$AD/pq.out" E="$AD/pq.err" RC="$(cat "$AD/pq.rc" 2>/dev/null)"
check "[X]   an agy run queued for its slot when another run paused agy: once it has the slot it exits 28 NO_CAPACITY (one CX_SIGNAL, 'paused') and never registers or launches agy" \
  eval 'rc_is 28 && one_signal NO_CAPACITY && err_has "agy dispatch is paused" && ! tail -n +"$(( $(cat "$AD/n0") + 1 ))" "$ADL" | grep -q "^agy	.*\(--new-project\|stream-json\)"'
rm -f "$AD/home/.conductor/state/agy-paused"
local A7_BAD=""
adr agy "$O1" STUB_AGY_RUN=quota -- --wt "$AD/wt-t1"; [ "$PR" = "10 quota" ] || A7_BAD="$A7_BAD [agy $PR]"
adr agy "$O1" STUB_AGY_DELEGATE_RUN=quota -- --wt "$AD/wt-t1" --agy-mode wrapper; [ "$PR" = "10 quota" ] || A7_BAD="$A7_BAD [agy-delegate $PR]"
check "[A7]  agy quota text (RESOURCE_EXHAUSTED) and agy-delegate's quota exit -> 10${A7_BAD:+:$A7_BAD}" test -z "$A7_BAD"
local A8_BAD=""
adr agy "$O1" STUB_AGY_RUN=mismatch -- --wt "$AD/wt-t1"
{ [ "$PR" = "21 model_mismatch" ] && grep -q '"mismatch_killed": true' "$O1/agy.run.json"; } || A8_BAD="$A8_BAD [agy init.model: $PR]"
check "[A8]  agy: init.model naming another model -> killed at init, 21${A8_BAD:+:$A8_BAD}" test -z "$A8_BAD"
local AX_BAD=""
adr agy "$O1" STUB_AGY_RUN=partial -- --wt "$AD/wt-t1"; [ "$PR" = "27 partial" ] || AX_BAD="$AX_BAD [partial: $PR]"
adr agy "$O1" STUB_AGY_RUN=subagent -- --wt "$AD/wt-t1"; { [ "$PR" = "2 failed" ] && rj reason | grep -q "^subagent"; } || AX_BAD="$AX_BAD [subagent: $PR]"
adr agy "$O1" STUB_AGY_RUN=auth -- --wt "$AD/wt-t1"; [ "$PR" = "11 auth" ] || AX_BAD="$AX_BAD [auth: $PR]"
adr agy "$O1" STUB_AGY_RUN=noinit CX_AGY_INIT_SECS=2 -- --wt "$AD/wt-t1"; { [ "$PR" = "2 failed" ] && rj reason | grep -q "no init event within 2 s"; } || AX_BAD="$AX_BAD [noinit: $PR]"
check "[X]   agy: an expired print timeout -> 27, a subagent event -> 2 (subagent), a sign-in error -> 11, no init event within CX_AGY_INIT_SECS -> killed, 2${AX_BAD:+:$AX_BAD}" test -z "$AX_BAD"
rm -rf -- "${O1:?}"; mkdir -p "$O1"
( env HOME="$AD/home" CX_HOME="$AD/home/.conductor" CLAUDE_CONFIG_DIR="$AD/cfg" STUB_LOG="$ADL" STUB_AGY_RUN=sleep STUB_AGY_SLEEP=60 \
    "$ADP/agy.sh" run --out "$O1" --wt "$AD/wt-t1" > "$AD/cancel.out" 2> "$AD/cancel.err"; printf '%s\n' "$?" > "$AD/cancel.rc" ) &
local cp=$!
wait_file "$O1/agy.sid"; sleep 1
local asid; asid="$(cat "$O1/agy.sid" 2>/dev/null)"
kill -TERM "$(pgrep -o -f "$ADP/agy.sh run --out $O1")" 2>/dev/null
wait "$cp" 2>/dev/null
sleep 0.5
O="$AD/cancel.out" E="$AD/cancel.err" RC="$(cat "$AD/cancel.rc" 2>/dev/null)"
check "[X]   TERM to an adapter run -> 130 CANCELLED (rc file 130, one CX_SIGNAL); agy's session is killed at once (agy ignores TERM), nothing of it left" \
  eval 'rc_is 130 && one_signal CANCELLED && [ "$(cat "$O1/rc")" = 130 ] && [ -n "$asid" ] && ! kill -0 "$asid" 2>/dev/null && [ -z "$(ps -eo sid= | tr -d " " | grep -x "$asid")" ]'
check "[P30] adapters (agy): no stub logged BILLABLE (every executor run carried a scenario knob)" eval '! grep -q "^BILLABLE" "$ADL"'
}
bg_section adapters-agy sec_adapters_agy

# ------------------------------------------------------------------ Phase 2 cx-run and cx-job (sections 15.1, 15.5, 15.7)
# A background section: cx-run and cx-job against the stubs' run scenarios, in their own home
# ($TMP/cr) whose host record names the stubs (current plugin version, recorded now, so cx-run
# never refreshes it), with a repository whose .cx/routes.json has setup true and test true.
CXRUN="$ROOT/bin/cx-run"
CXJOB="$ROOT/bin/cx-job"
# cr VAR=VALUE... -- CMD ARGS...: CMD in ${CR_CWD:-$REPO} with the cx-run home ($O/$E/$RC).
cr() {
  local -a ev=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done
  shift
  O="$TMP/out$SEC_TAG" E="$TMP/err$SEC_TAG"
  (cd "${CR_CWD:-$REPO}" && env HOME="$AD/home" CX_HOME="$AD/home/.conductor" CLAUDE_CONFIG_DIR="$AD/cfg" STUB_LOG="$ADL" \
     ${ev[@]+"${ev[@]}"} "$@") > "$O" 2> "$E" < /dev/null
  RC=$?
}
UNC_PFX=$'\\\\wsl.localhost\\'
is_unc() { [ "${1:0:${#UNC_PFX}}" = "$UNC_PFX" ]; }
crj() { "$REAL_PY" -I "$NORM" field "$AD/home/.conductor/out/$1/result.json" "$2" 2>/dev/null; }
cr_setup() {
  mkdir -p "$AD/home/.conductor/hosts" "$AD/cfg"
  HK="$(bash -c '. "$1/scripts/host/detect.sh"; cx_detect; printf %s "$CX_HOSTKEY"' _ "$ROOT")"
  "$REAL_PY" -I - "$AD/home/.conductor/hosts/$HK.json" "$STUBS" "$PY_DIR" "$CXV" <<'PY'
import datetime, json, sys
st, py = sys.argv[2], sys.argv[3]
b = {k: st + "/" + k for k in ("claude", "copilot", "grok", "agy", "gh")}
b.update({"git": "/usr/bin/git", "python3": py + "/python3", "ghcp_delegate": st + "/ghcp-delegate",
          "ghcp_models": st + "/ghcp-models", "ghcp_cloud": st + "/ghcp-cloud", "agy_delegate": st + "/agy-delegate"})
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"version": 1, "recorded_at": now, "plugin_version": sys.argv[4], "host": "linux", "hostkey": "test",
           "path": st + ":" + py + ":/usr/local/bin:/usr/bin:/bin", "path_source": "interactive", "bin": b,
           "copilot_home": None, "copilot_token_env": None}, open(sys.argv[1], "w"))
PY
  REPO="$AD/repo"
  mkdir -p "$REPO/.cx"; git -C "$REPO" init -q; printf 'hi\n' > "$REPO/README.md"
  printf '{"version": 1, "setup": "true", "commands": {"test": "true", "lint": null, "typecheck": null}, "pools": {"grok": true, "agy": true, "copilot": true}}\n' > "$REPO/.cx/routes.json"
  commit_all "$REPO"
}

sec_run() {
section "Phase 2 cx-run: every lane, result.json, CX_RESULT, the ledger, the claude dispatch and --finish (A2, A27, A28)"
local AD="$TMP/cr" ADL="$TMP/cr.log" HK REPO OUT1 L J J2 J3 JD t0 lc spid qp i b
cr_setup
L="$AD/home/.conductor/ledger.jsonl"
a2_keep() { cp "$O" "$AD/a2.$1.out"; cp "$E" "$AD/a2.$1.err"; }

# --- A2: success per lane through cx-run
cr STUB_GROK_RUN=ok CLAUDE_CODE_SESSION_ID=sess-a2 CLAUDE_EFFORT=xhigh -- "$CXRUN" --exec grok --id g1 'Add a greeting file'
a2_keep g1
OUT1="$AD/home/.conductor/out/g1"
check "[A2]  cx-run --exec grok: exit 0; stdout = the digest, a 'VERIFY THIS:' line and the diffstat; one CX_RESULT (ok, lane grok, served = requested, +1 -0, branch cx/g1, json.dumps line) and no CX_SIGNAL" \
  eval 'rc_is 0 && out_has "DIGEST: created cx-grok.txt." && grep -q "^VERIFY THIS: .*commit it (the skill.s Step 3)" "$O" && out_has "diffstat: +1 -0, 1 file" && [ "$(grep -c "^CX_RESULT " "$E")" = 1 ] && line_is CX_RESULT status ok && line_is CX_RESULT lane grok && line_is CX_RESULT model_served grok-4.7 && line_is CX_RESULT branch cx/g1 && line_is CX_RESULT diffstat "+1 -0, 1 file" && tj linejson "$E" CX_RESULT && no_signal'
check "[A2]  ... the worktree <worktree_root>/repo-g1 on cx/g1 holds the change, uncommitted (Step 3 commits); the contract, its hash and vars.sh are in the out dir; the worktree stays marked running until Step 3" \
  eval '[ -f "$AD/home/.cx-wt/repo-g1/cx-grok.txt" ] && [ "$(git -C "$AD/home/.cx-wt/repo-g1" symbolic-ref --short HEAD)" = cx/g1 ] && [ "$(git -C "$AD/home/.cx-wt/repo-g1" rev-list --count HEAD)" = 1 ] && head -n 1 "$OUT1/task.md" | grep -q "^<!-- cx-task {\"id\": \"g1\"" && [ "$(sha256sum "$AD/home/.cx-wt/repo-g1/.conductor/task.md" | cut -d" " -f1)" = "$(cat "$OUT1/task.sha")" ] && grep -qx "ID=g1" "$OUT1/vars.sh" && grep -qx "$AD/home/.cx-wt/repo-g1" "$OUT1/running" && grep -q "/.conductor/" "$REPO/.git/info/exclude"'
tail -n 1 "$L" > "$AD/ledger.last" 2>/dev/null
check "[A2]  ... one ledger line: result.json without raw and notes; [A28] it carries claude_session and claude_effort" \
  eval '[ "$(wc -l < "$L")" = 1 ] && [ "$(tj get "$AD/ledger.last" id)" = g1 ] && [ "$(tj get "$AD/ledger.last" claude_session)" = sess-a2 ] && [ "$(tj get "$AD/ledger.last" claude_effort)" = xhigh ] && ! grep -q "\"raw\"" "$AD/ledger.last" && ! grep -q "\"notes\"" "$AD/ledger.last"'
cr STUB_GHCP_RUN=ok -- "$CXRUN" --exec copilot --effort high --id c1 'Add a file'
a2_keep c1
check "[A2]  cx-run --exec copilot: ok, lane copilot-opus through ghcp-delegate (--write, --dir the worktree, --allow-shell per routes command), served claude-opus-5.5, CX_NOTE same_family_as_conductor" \
  eval 'rc_is 0 && line_is CX_RESULT lane copilot-opus && line_is CX_RESULT model_served claude-opus-5.5 && line_is CX_NOTE same_family_as_conductor true && grep "^ghcp-delegate	" "$ADL" | grep -q -- "--dir $AD/home/.cx-wt/repo-c1 --write --allow-shell true"'
cr STUB_AGY_RUN=ok -- "$CXRUN" --exec agy --id a1 'Add a file'
a2_keep a1
check "[A2]  cx-run --exec agy: raw mode (served = the init event's claude-opus-5-5-high), and no running mark left (an agy task's tree stays in later agy snapshots)" \
  eval 'rc_is 0 && line_is CX_RESULT lane agy-opus && line_is CX_RESULT model_served claude-opus-5-5-high && [ ! -e "$AD/home/.conductor/out/a1/running" ]'
cr STUB_AGY_DELEGATE_RUN=ok -- "$CXRUN" --exec agy --agy-mode wrapper --id w1 'Add a file'
a2_keep w1
check "[A2]  cx-run --exec agy --agy-mode wrapper: agy-delegate in the worktree, ok, lane agy-opus with model_served null (the wrapper cannot verify it) and its note" \
  eval 'rc_is 0 && line_is CX_RESULT lane agy-opus && line_is CX_RESULT model_served null && grep "^agy-delegate	" "$ADL" | grep -q "cwd=$AD/home/.cx-wt/repo-w1"'
cr STUB_CLAUDE_RUN=ok -- "$CXRUN" --exec claude --headless --id h1 'Add a file'
a2_keep h1
check "[A2]  cx-run --exec claude --headless: claude -p in the worktree, ok, lane claude, pool claude-plan, served claude-opus-5-5" \
  eval 'rc_is 0 && line_is CX_RESULT lane claude && line_is CX_RESULT pool claude-plan && line_is CX_RESULT model_served claude-opus-5-5 && grep "^claude	" "$ADL" | grep -q "cwd=$AD/home/.cx-wt/repo-h1	argv: -p "'

# --- A27: the claude dispatch, then --finish
cr -- "$CXRUN" --exec claude --id d1 'Add a file'
check "[A27] --exec claude: exit 0; stdout = the dispatch JSON (claude-subagent, the worktree, prompt, effort, task file); CX_RESULT status dispatched; no ledger line yet; the worktree marked running" \
  eval 'rc_is 0 && outj_is dispatch claude-subagent && outj_is worktree "$AD/home/.cx-wt/repo-d1" && outj_is effort high && line_is CX_RESULT status dispatched && ! grep -q "\"id\": \"d1\"" "$L" && [ -f "$AD/home/.conductor/out/d1/running" ]'
printf 'from the subagent\n' > "$AD/home/.cx-wt/repo-d1/sub.txt"
cr -- "$CXRUN" --finish d1
a2_keep d1
check "[A27] --finish d1: the final CX_RESULT (ok, +1 -0), its ledger line, and VERIFY THIS names the subagent's own account" \
  eval 'rc_is 0 && line_is CX_RESULT status ok && line_is CX_RESULT diffstat "+1 -0, 1 file" && grep -q "\"id\": \"d1\"" "$L" && out_has "VERIFY THIS: the subagent" && no_signal'
cp "$O" "$AD/d1.keep.out"; cp "$E" "$AD/d1.keep.err"
cr -- "$CXRUN" --finish d1
local FIN_D1="$RC"
cr -- "$CXRUN" --finish g1
check "[X]   a finished task is never finished again: a second --finish d1 (exit $FIN_D1) and --finish of a grok task that ended inside cx-run exit 1 and book nothing (one ledger line each)" \
  eval '[ "$FIN_D1" = 1 ] && rc_is 1 && no_signal && err_has "already finished" && [ "$(grep -c "\"id\": \"d1\"" "$L")" = 1 ] && [ "$(grep -c "\"id\": \"g1\"" "$L")" = 1 ]'
cp "$AD/d1.keep.out" "$O"; cp "$AD/d1.keep.err" "$E"

local A2_BAD="" a2
for a2 in g1 c1 a1 w1 h1 d1; do
  b="$(tj schema "$AD/home/.conductor/out/$a2/result.json" "$AD/a2.$a2.err" "$L" 2>&1)"
  [ -z "$b" ] || A2_BAD="$A2_BAD [$a2: $b]"
  [ "$(grep -c '^CX_RESULT ' "$AD/a2.$a2.err")" = 1 ] || A2_BAD="$A2_BAD [$a2: not one CX_RESULT]"
  { tail -n 2 "$AD/a2.$a2.out" | head -n 1 | grep -q '^VERIFY THIS: ' && tail -n 1 "$AD/a2.$a2.out" | grep -q '^diffstat: +'; } || A2_BAD="$A2_BAD [$a2: stdout does not end with VERIFY THIS and the diffstat]"
done
check "[A2]  every lane through cx-run (grok, copilot, agy raw, agy wrapper, claude --headless, the claude dispatch once finished; the cloud lane: its section): result.json carries every section 15.4 field with its type, the one CX_RESULT is result.json without raw, notes and models_seen plus path and host_path, the ledger line is result.json without raw and notes, stdout ends with the VERIFY THIS line and the diffstat${A2_BAD:+:$A2_BAD}" test -z "$A2_BAD"

check "[P30] cx-run: no stub logged BILLABLE (every executor run carried a scenario knob)" eval '! grep -q "^BILLABLE" "$ADL"'
}
bg_section run sec_run
sec_run2() {
section "Phase 2 cx-run: contract, post-checks, ids, dry runs, the .claude/worktrees refusal, read and review modes (A15, A17, A28)"
local AD="$TMP/cr2" ADL="$TMP/cr2.log" HK REPO L i
cr_setup
L="$AD/home/.conductor/ledger.jsonl"
# --- A15: task hash, no diff, setup failure
cr STUB_GROK_RUN=tamper -- "$CXRUN" --exec grok --id m1 'x'
check "[A15] the executor edits .conductor/task.md -> 23 SPEC_TAMPERED (CX_RESULT spec_tampered, one CX_SIGNAL, last)" \
  eval 'rc_is 23 && line_is CX_RESULT status spec_tampered && one_signal SPEC_TAMPERED'
cr STUB_GROK_RUN=nodiff -- "$CXRUN" --exec grok --id n1 'x'
check "[A15] no diff in the worktree -> 3 EMPTY_OUTPUT" eval 'rc_is 3 && line_is CX_RESULT status empty && one_signal EMPTY_OUTPUT'
sed -i 's/"setup": "true"/"setup": "false"/' "$REPO/.cx/routes.json"
cr STUB_GROK_RUN=ok -- "$CXRUN" --exec grok --id s1 'x'
sed -i 's/"setup": "false"/"setup": "true"/' "$REPO/.cx/routes.json"
check "[A15] the repo's setup fails -> 25 ENV_FAILED (status env_failed, setup.log kept) and the executor never ran (no grok call in the worktree)" \
  eval 'rc_is 25 && line_is CX_RESULT status env_failed && one_signal ENV_FAILED && [ -f "$AD/home/.conductor/out/s1/setup.log" ] && ! grep -q "^grok	cwd=$AD/home/.cx-wt/repo-s1" "$ADL"'
cr STUB_GROK_RUN=ok -- "$CXRUN" --exec grok --id n1 'again'
check "[X]   a taken id (cx/n1 and out/n1 exist) -> exit 1, nothing run" eval 'rc_is 1 && no_signal && err_has "is taken on this computer"'
cr STUB_GROK_RUN=ok -- "$CXRUN" --background --exec grok --id n1 'again'
check "[X]   ... the same with --background: refused up front by the --dry-run preflight (exit 1, no JOB_ID, no job directory)" \
  eval 'rc_is 1 && no_signal && ! out_has JOB_ID && err_has "is taken on this computer" && [ -z "$(ls "$AD/home/.conductor/jobs" 2>/dev/null)" ]'
cr -- "$CXRUN" --dry-run --exec grok --id m1 'x'
check "[X]   ... and a plain --dry-run of a taken id is refused too (exit 1)" eval 'rc_is 1 && err_has "is taken on this computer"'
# A task text that starts with "-": after "--" it is the text, in the foreground and through a job.
cr STUB_GROK_RUN=ok -- "$CXRUN" --exec grok --id dd1 -- '- add a greeting file'
check "[X]   cx-run -- '<text starting with ->': the text is the task (exit 0, task.txt holds it), never an option" \
  eval 'rc_is 0 && line_is CX_RESULT id dd1 && [ "$(cat "$AD/home/.conductor/out/dd1/task.txt")" = "- add a greeting file" ]'
(cd "$REPO" && printf -- '--help' | env HOME="$AD/home" CX_HOME="$AD/home/.conductor" CLAUDE_CONFIG_DIR="$AD/cfg" STUB_LOG="$ADL" STUB_GROK_RUN=ok \
   "$CXRUN" --background --exec grok --id dd2 -) > "$TMP/out.dd2" 2> "$TMP/err.dd2"
local DDJ; DDJ="$(sed -n 's/^JOB_ID //p' "$TMP/out.dd2")"
cr -- "$CXJOB" wait "${DDJ:-none}"
check "[X]   printf -- --help | cx-run --background ... -: the job runs the task '--help' (CX_RESULT id dd2, task.txt '--help'), not cx-run's help; the job argv stores it after --" \
  eval 'rc_is 0 && line_is CX_RESULT id dd2 && [ "$(cat "$AD/home/.conductor/out/dd2/task.txt")" = "--help" ] && ! out_has "Usage: cx-run" && [ "$(tr "\0" "\n" < "$AD/home/.conductor/jobs/$DDJ/argv" | tail -n 2 | tr "\n" " ")" = "-- --help " ]'
cr STUB_GROK_RUN=ok -- "$CXJOB" start --exec grok --id dd3 -- '--finish=n1'
DDJ="$(sed -n 's/^JOB_ID //p' "$O")"
cr -- "$CXJOB" wait "${DDJ:-none}"
check "[X]   cx-job start -- '--finish=n1': the text is the task of a new run dd3 (preflight run, exit 0), never a --finish of n1" \
  eval 'rc_is 0 && line_is CX_RESULT id dd3 && [ "$(cat "$AD/home/.conductor/out/dd3/task.txt")" = "--finish=n1" ]'
# A failed write run drops its running mark (agy's snapshots watch that tree again).
cr STUB_GROK_RUN=denied -- "$CXRUN" --exec grok --id dn1 'x'
check "[X]   a denied write run (15) keeps no running mark, though its worktree has a diff; an ok run with a diff keeps it (Step 3 removes it)" \
  eval 'rc_is 15 && [ -f "$AD/home/.cx-wt/repo-dn1/cx-grok.txt" ] && [ ! -e "$AD/home/.conductor/out/dn1/running" ] && [ ! -e "$AD/home/.conductor/out/m1/running" ]'
# One cx-run per task: a re-dispatch while a run of the task is still going is refused.
cr STUB_GROK_RUN=sleep STUB_GROK_SLEEP=20 -- "$CXRUN" --background --exec grok --id rl1 'x'
DDJ="$(sed -n 's/^JOB_ID //p' "$O")"
for ((i = 0; i < 100; i++)); do [ -s "$AD/home/.conductor/out/rl1/grok.sid" ] && break; sleep 0.1; done
cr STUB_GROK_RUN=ok -- "$CXRUN" --reuse-worktree --exec grok --id rl1 'x'
check "[X]   a re-dispatch (--reuse-worktree) while the task's first run still goes -> exit 1 'task rl1 is running', and its out files are untouched" \
  eval 'rc_is 1 && no_signal && err_has "task rl1 is running" && [ -s "$AD/home/.conductor/out/rl1/grok.argv" ] && [ -s "$AD/home/.conductor/out/rl1/grok.sid" ]'
cr STUB_GROK_RUN=ok -- "$CXRUN" --background --reuse-worktree --exec grok --id rl1 'x'
check "[X]   ... and through --background it is refused before a job starts (exit 1, no JOB_ID)" eval 'rc_is 1 && ! out_has JOB_ID && err_has "is running"'
cr -- "$CXJOB" kill "${DDJ:-none}"
cr -- "$CXRUN" --exec copilot --effort max --id x1 'x'
check "[X]   effort max on Copilot -> exit 1 before anything is created" eval 'rc_is 1 && no_signal && [ ! -e "$AD/home/.conductor/out/x1" ] && [ ! -e "$AD/home/.cx-wt/repo-x1" ]'
printf 'no json line\n# Task\n' > "$AD/bad-task.md"
cr -- "$CXRUN" --exec grok --task-file "$AD/bad-task.md"
check "[X]   a task file without the line-1 cx-task JSON -> exit 1" eval 'rc_is 1 && no_signal && err_has "is not <!-- cx-task {json} -->"'

# --- A17: --dry-run and --explain create nothing and start no executor
CR_MARK="$(wc -l < "$ADL")"
cr -- "$CXRUN" --explain --id z1 'x'
check "[A17] --explain: exit 0; the plan, why agy was chosen (preflight, a free slot), the adapter's argv and env names; no out dir, worktree or branch; the stub log shows free probes only" \
  eval 'rc_is 0 && out_has "cx-run dry run: nothing created" && out_has "explain: agy: chosen: preflight green" && out_has "argv: $STUBS/agy --model claude-opus-5-5-high" && out_has "env unset: " && [ ! -e "$AD/home/.conductor/out/z1" ] && [ ! -e "$AD/home/.cx-wt/repo-z1" ] && ! git -C "$REPO" rev-parse -q --verify cx/z1 >/dev/null && ! tail -n +"$((CR_MARK + 1))" "$ADL" | grep -Eq "BILLABLE|-p Read|--prompt-file|^ghcp-delegate	.*run="'
cr -- "$CXRUN" --dry-run --exec copilot --id z2 'x'
check "[A17] --dry-run --exec copilot shows ghcp-delegate's own --print-command line (free) and creates nothing" \
  eval 'rc_is 0 && out_has "copilot argv (ghcp-delegate --print-command): $STUBS/copilot -p" && [ ! -e "$AD/home/.conductor/out/z2" ]'
mkdir -p "$AD/home/.conductor/state"; printf '{}\n' > "$AD/home/.conductor/state/agy-paused"
cr -- "$CXRUN" --explain --id z3 'x'
check "[X]   auto with agy paused: agy skipped (cx-job unpause agy), copilot chosen" \
  eval 'rc_is 0 && out_has "explain: agy: skipped: agy dispatch is paused" && out_has "explain: copilot: chosen" && out_has "exec: copilot"'
cr -- "$CXJOB" unpause agy
check "[A5]  cx-job unpause agy removes the pause" eval 'rc_is 0 && out_has "agy dispatch resumed" && [ ! -e "$AD/home/.conductor/state/agy-paused" ]'
cr -- "$CXRUN" --explain --effort max 'x'
check "[X]   auto with effort max -> the claude lane (max never leaves Claude)" eval 'rc_is 0 && out_has "exec: claude" && out_has "effort max stays with Claude"'

# --- A28: a cwd inside .claude/worktrees without --repo
git -C "$REPO" worktree add -q -b claude-x "$REPO/.claude/worktrees/x"
CR_CWD="$REPO/.claude/worktrees/x" cr -- "$CXRUN" --exec grok 'x'
check "[A28] cx-run from a checkout under .claude/worktrees/ without --repo -> exit 1 (the base would be wrong)" \
  eval 'rc_is 1 && no_signal && err_has "one of Claude Code"'
CR_CWD="$REPO/.claude/worktrees/x" cr -- "$CXRUN" --dry-run --repo "$REPO" --exec grok --id z4 'x'
check "[A28] ... with --repo the run proceeds (dry run)" eval 'rc_is 0 && out_has "repo: $REPO"'

# --- read and review modes
cr STUB_GROK_RUN=ok -- "$CXRUN" --mode read 'where is the greeting?'
check "[X]   --mode read (default lane grok): the answer on a detached gate checkout of HEAD, removed afterwards; read-only flags" \
  eval 'rc_is 0 && out_has "\"file\": \"README.md\"" && line_is CX_RESULT mode read && [ -z "$(ls "$AD/home/.conductor/gate" 2>/dev/null)" ] && grep "^grok	" "$ADL" | grep -- "--json-schema" | tail -n 1 | grep -q -- "--sandbox read-only --always-approve"'
git -C "$REPO" checkout -q -b feat; printf 'f\n' > "$REPO/f.txt"; git -C "$REPO" add f.txt; git -C "$REPO" commit -qm feat; git -C "$REPO" checkout -q -
cr STUB_AGY_DELEGATE_RUN=ok -- "$CXRUN" --mode review --family gemini --branch feat --id rv1
check "[X]   --mode review --family gemini --branch feat: agy-delegate with review_model_gemini on a gate checkout of feat, the diff in .conductor/change.diff, the checkout removed" \
  eval 'rc_is 0 && line_is CX_RESULT lane agy-gemini && line_is CX_RESULT model_requested "Gemini 4 Argon (High)" && grep -q "f.txt" "$AD/home/.conductor/out/rv1/change.diff" && [ ! -e "$AD/home/.conductor/gate/rv1.1" ] && grep "^agy-delegate	" "$ADL" | tail -n 1 | grep -q "cwd=$AD/home/.conductor/gate/rv1.1"'
cr -- "$CXRUN" --mode review --family gpt --branch HEAD --id rv2
check "[X]   a review of an empty diff -> 3 EMPTY_OUTPUT, no executor" eval 'rc_is 3 && one_signal EMPTY_OUTPUT'
cr CLAUDE_PLUGIN_OPTION_CAP_GROK=0 -- "$CXRUN" --mode read --id rq1 'where is it?'
check "[X]   a read run that stops before its executor (cap_grok=0 -> 28) removes its gate checkout: no \$CX_HOME/gate/rq1.1, no registered worktree left" \
  eval 'rc_is 28 && one_signal NO_CAPACITY && [ ! -e "$AD/home/.conductor/gate/rq1.1" ] && ! git -C "$REPO" worktree list | grep -q "gate/rq1"'

check "[P30] cx-run: no stub logged BILLABLE (every executor run carried a scenario knob)" eval '! grep -q "^BILLABLE" "$ADL"'
}
bg_section run2 sec_run2
sec_runy() {
section "Phase 2 cx-run: the agy pause end to end, a sibling task's setup, the pin, the worker environment, dry runs of every lane (A5, A9, A14, A17)"
local AD="$TMP/cry" ADL="$TMP/cry.log" HK REPO L i b
cr_setup
L="$AD/home/.conductor/ledger.jsonl"
# --- A5 end to end: wrong tree, the pause, cx-job unpause agy
git -C "$REPO" worktree add -q -b side "$AD/side"
cr STUB_AGY_RUN=wrongtree STUB_AGY_OTHER="$AD/side" -- "$CXRUN" --exec agy --id wt1 'Add a file'
check "[A5]  cx-run --exec agy whose agy also writes into another worktree of the repo -> 22 WRONG_TREE (CX_RESULT wrong_tree naming it, one CX_SIGNAL, last) and \$CX_HOME/state/agy-paused set" \
  eval 'rc_is 22 && line_is CX_RESULT status wrong_tree && one_signal WRONG_TREE && grep -q "$AD/side" "$AD/home/.conductor/out/wt1/agy.trees.changed" && [ -s "$AD/home/.conductor/state/agy-paused" ]'
CR_MARK="$(wc -l < "$ADL")"
cr STUB_AGY_RUN=ok -- "$CXRUN" --exec agy --id wt2 'Add a file'
check "[A5]  ... the next cx-run --exec agy is refused with 28 NO_CAPACITY (agy dispatch is paused) before anything is created, and agy got no registration or run" \
  eval 'rc_is 28 && one_signal NO_CAPACITY && err_has "agy dispatch is paused" && [ ! -e "$AD/home/.conductor/out/wt2" ] && [ ! -e "$AD/home/.cx-wt/repo-wt2" ] && ! tail -n +"$((CR_MARK + 1))" "$ADL" | grep -Eq "^agy	.*(--new-project|stream-json)"'
cr -- "$CXRUN" --explain --id wt2 'Add a file'
check "[A5]  ... and --exec auto skips agy while it is paused" eval 'rc_is 0 && out_has "explain: agy: skipped: agy dispatch is paused" && ! out_has "exec: agy"'
cr -- "$CXJOB" unpause agy
cr STUB_AGY_RUN=ok -- "$CXRUN" --exec agy --id wt3 'Add a file'
check "[A5]  ... until cx-job unpause agy: then the same dispatch runs (exit 0, ok)" eval 'rc_is 0 && line_is CX_RESULT status ok && [ ! -e "$AD/home/.conductor/state/agy-paused" ]'
rm -f -- "$AD/side/cx-wrong.txt"
# No false alarm from a sibling task: its setup writes into its own worktree (untracked, not
# ignored) between an agy run's two snapshots; that worktree is marked running from its creation
# on, so the snapshots leave it out. Ordered by files: B's setup waits for go, A's stub logs its
# start after the before-snapshot, B writes, A's after-snapshot comes while B is still in setup.
local SBX="$AD/sbx" pa pb
mkdir -p "$SBX"
cat > "$SBX/setup.sh" <<SH
case "\$PWD" in
  */repo-sb1) : > "$SBX/b-started"; while [ ! -e "$SBX/go" ]; do sleep 0.1; done; echo x > made-by-setup.txt; : > "$SBX/b-wrote"; while [ ! -e "$SBX/done" ]; do sleep 0.1; done ;;
esac
SH
sed -i "s#\"setup\": \"true\"#\"setup\": \"sh $SBX/setup.sh\"#" "$REPO/.cx/routes.json"
( SEC_TAG="$SEC_TAG.sb"; cr STUB_GROK_RUN=ok -- "$CXRUN" --exec grok --id sb1 'Add a file'; printf '%s\n' "$RC" > "$SBX/b.rc" ) &
pb=$!
wait_file "$SBX/b-started"
( SEC_TAG="$SEC_TAG.sa"; cr STUB_AGY_RUN=sleep STUB_AGY_SLEEP=3 STUB_EVENTS="$SBX/ev" -- "$CXRUN" --exec agy --id sa1 'Add a file'; printf '%s\n' "$RC" > "$SBX/a.rc"; cp "$E" "$SBX/a.err" ) &
pa=$!
for ((i = 0; i < 300; i++)); do grep -q '^start agy-run' "$SBX/ev" 2>/dev/null && break; sleep 0.05; done
: > "$SBX/go"
wait_file "$SBX/b-wrote"
wait "$pa"
: > "$SBX/done"
wait "$pb"
sed -i "s#\"setup\": \"sh $SBX/setup.sh\"#\"setup\": \"true\"#" "$REPO/.cx/routes.json"
check "[A5]  no false WRONG_TREE: a sibling task's setup writes into its own worktree between an agy run's two snapshots (cx-run marks a worktree running from its creation, so every agy snapshot leaves it out): the agy run ends 0 ok, agy is not paused, the sibling ends 0" \
  eval '[ "$(cat "$SBX/a.rc")" = 0 ] && [ "$(cat "$SBX/b.rc")" = 0 ] && [ ! -e "$AD/home/.conductor/state/agy-paused" ] && [ "$(tj line "$SBX/a.err" CX_RESULT status)" = ok ] && [ -f "$AD/home/.cx-wt/repo-sb1/made-by-setup.txt" ]'

# --- A9 through cx-run: the pin is checked before anything is created
rm -f -- "$AD/home/.conductor/state/preflight.json"
CR_MARK="$(wc -l < "$ADL")"
cr STUB_GROK_RUN=ok STUB_GROK_VERSION=1.0.71 -- "$CXRUN" --exec grok --id v1 'x'
check "[A9]  cx-run --exec grok with grok 1.0.71 (pin 1.0.70; no cached probe) -> 26 VERSION_MISMATCH (one CX_SIGNAL, last) before anything is created: no out dir, worktree or cx/v1 branch, and grok was asked only --version and models" \
  eval 'rc_is 26 && one_signal VERSION_MISMATCH && [ ! -e "$AD/home/.conductor/out/v1" ] && [ ! -e "$AD/home/.cx-wt/repo-v1" ] && ! git -C "$REPO" rev-parse -q --verify cx/v1 >/dev/null && [ -z "$(tail -n +"$((CR_MARK + 1))" "$ADL" | grep "^grok	" | grep -Ev "	argv: (--version|models)$")" ]'

# --- A14 through cx-run: saved options and the caller's keys never reach the executor
printf '{"pluginConfigs": {"conductor@conductor-for-claude-code": {"options": {"cap_grok": "3", "default_timeout": "20m"}}}}\n' > "$AD/cfg/settings.json"
cr STUB_GROK_RUN=ok STUB_ENV_FILE="$AD/env.cr" "${SCRUB_PROBE[@]}" -- "$CXRUN" --exec grok --id e1 'Add a file'
rm -f -- "$AD/cfg/settings.json"
check "[A14] through cx-run (options in settings.json, every API key and a CLAUDE_PLUGIN_OPTION_* in the caller's environment): exit 0, and every grok call ran in the worker environment from the runtime copy's worker-shims, with none of them" \
  eval 'rc_is 0 && worker_env_ok "$AD/env.cr" grok "$AD/home/.conductor/runtime/$CXV/worker-shims" GROK_DISABLE_AUTOUPDATER=1'

# --- A17 for every lane and mode: dry runs create nothing and call only free forms
rm -f -- "$AD/home/.conductor/state/preflight.json"
CR_MARK="$(wc -l < "$ADL")"
local A17_BAD="" a17 A17_L0 A17_S0
A17_L0="$(wc -l < "$L")"
A17_S0="$(ls -A "$AD/home/.conductor/out" "$AD/home/.cx-wt" "$AD/home/.conductor/jobs" 2>&1; git -C "$REPO" for-each-ref --format='%(refname)'; git -C "$REPO" worktree list --porcelain)"
for a17 in "--exec grok" "--exec agy --agy-mode wrapper" "--exec claude --headless" "--exec copilot --fusion max" \
           "--exec copilot-cloud --gh-repo github.com/o/r" "--mode read --exec agy" "--mode review --family gpt --branch side" \
           "--explain --exec copilot"; do
  read -r -a A17A <<< "$a17"
  cr -- "$CXRUN" --dry-run "${A17A[@]}" --id z9 'x'
  { rc_is 0 && out_has "cx-run dry run: nothing created" && out_has "argv: "; } || A17_BAD="$A17_BAD [$a17: rc $RC]"
  case "$a17" in "--exec claude --headless") out_has "--settings $AD/home/.conductor/out/z9/cx-worker.json" || A17_BAD="$A17_BAD [claude --headless: the --settings path]" ;; esac
done
[ "$A17_S0" = "$(ls -A "$AD/home/.conductor/out" "$AD/home/.cx-wt" "$AD/home/.conductor/jobs" 2>&1; git -C "$REPO" for-each-ref --format='%(refname)'; git -C "$REPO" worktree list --porcelain)" ] || A17_BAD="$A17_BAD [an out dir, worktree, job, branch or gate checkout appeared]"
[ "$(wc -l < "$L")" = "$A17_L0" ] || A17_BAD="$A17_BAD [a ledger line was written]"
b="$(tail -n +"$((CR_MARK + 1))" "$ADL" | grep -Ev '^(grok|copilot|agy|claude|gh)	cwd=[^	]*	([^	]*	)*argv: --version$|^grok	cwd=[^	]*	argv: models$|^agy	cwd=[^	]*	argv: models( --output-format json)?$|^agy	cwd=[^	]*	argv: -p /usage --output-format json$|^claude	cwd=[^	]*	argv: auth status --json$|^gh	cwd=[^	]*	argv: auth status$|^ghcp-models	.*	argv: --json$|^ghcp-delegate	[^	]*	[^	]*	run=	argv: --print-command ' | cut -c1-160)"
[ -z "$b" ] || A17_BAD="$A17_BAD [not a free form: $b]"
check "[A17] --dry-run of the other lanes and modes (grok, agy wrapper, claude --headless, Fusion, copilot-cloud, read on agy, a gpt review) and --explain of an explicit lane, with the probe cache cleared: exit 0, the plan and the adapter argv (claude's --settings under the would-be out dir); no out dir, worktree, gate checkout, job, branch or ledger line, and every stub call a free form (--version, models, auth status, ghcp-models --json, ghcp-delegate --print-command)${A17_BAD:+:$A17_BAD}" test -z "$A17_BAD"

check "[P30] cx-run (A5, A9, A14, A17): no stub logged BILLABLE (every executor run carried a scenario knob)" eval '! grep -q "^BILLABLE" "$ADL"'
}
bg_section runy sec_runy
sec_job() {
section "Phase 2 cx-job: lifecycle, kill (TERM then KILL), pid reuse, queued, the caps under cx-run (A12, A13)"
local AD="$TMP/crj" ADL="$TMP/crj.log" HK REPO J J2 J3 JD t0 lc spid qp i
cr_setup
# --- A12: cx-job lifecycle
cr STUB_GROK_RUN=ok -- "$CXRUN" --background --exec grok --id j1 'x'
J="$(sed -n 's/^JOB_ID //p' "$O")"
check "[A12] cx-run --background prints JOB_ID <id> (YYYYmmdd-HHMMSS-<hex>) at once" eval 'rc_is 0 && [[ $J =~ ^[0-9]{8}-[0-9]{6}-[0-9a-f]{4}$ ]]'
cr -- "$CXJOB" wait "${J:0:12}"
check "[A12] cx-job wait <unique prefix>: exit 0 when the job ends; stdout the digest and VERIFY THIS, stderr the job's CX_RESULT; status done rc=0" \
  eval 'rc_is 0 && out_has "DIGEST: created cx-grok.txt." && out_has "VERIFY THIS:" && line_is CX_RESULT id j1 && no_signal && [ "$(cd "$REPO" && env HOME="$AD/home" CX_HOME="$AD/home/.conductor" "$CXJOB" status "$J")" = "done rc=0" ]'
cr STUB_GROK_RUN=sleep STUB_GROK_SLEEP=30 -- "$CXJOB" start --exec grok --id j2 'x'
J2="$(sed -n 's/^JOB_ID //p' "$O")"
JD="$AD/home/.conductor/jobs/$J2"
for ((i = 0; i < 100; i++)); do [ -s "$JD/sids" ] && break; sleep 0.1; done
cr -- "$CXJOB" result "$J2"
check "[A12] result while the job runs -> 75 RUNNING (one CX_SIGNAL)" eval 'rc_is 75 && one_signal RUNNING'
cr -- "$CXJOB" wait "$J2" --timeout 1s
check "[A12] wait --timeout 1s -> 75 RUNNING, and the status line" eval 'rc_is 75 && one_signal RUNNING && out_has running'
# A TERM-ignoring process in its own session that carries the job's CX_JOB_DIR, recorded in sids
# (as an executor session is): kill escalates to KILL after 10 s.
setsid env CX_JOB_DIR="$JD" bash -c 'trap "" TERM; exec sleep 60' > /dev/null 2>&1 &
spid=$!
# A second recorded session reads the job's rc file the moment its TERM lands: kill must have
# written 130 before it signals anything.
printf '%s\n' 'd="$1"; trap '"'"'cat "$d/rc" > "$d/rc-at-term" 2>/dev/null || echo none > "$d/rc-at-term"; exit 0'"'"' TERM; : > "$d/termrec-ready"; while :; do sleep 0.1; done' > "$AD/termrec.sh"
setsid env CX_JOB_DIR="$JD" bash "$AD/termrec.sh" "$JD" > /dev/null 2>&1 &
local rpid=$!
wait_file "$JD/termrec-ready"
sleep 0.3
printf '%s\n' "$spid" "$rpid" >> "$JD/sids"
t0=$SECONDS
cr -- "$CXJOB" kill "$J2"
local KT=$((SECONDS - t0))
check "[A12] kill: rc 130 written first, TERM to the runner and every recorded session, KILL after 10 s for a TERM-ignoring one (${KT} s); nothing of the job left; status cancelled" \
  eval 'rc_is 0 && out_has "cancelled $J2" && [ "$(cat "$JD/rc")" = 130 ] && [ "$KT" -ge 9 ] && [ "$KT" -le 35 ] && ! kill -0 "$spid" 2>/dev/null && [ -z "$(ps -eo sid= | tr -d " " | grep -Fx -f "$JD/sids")" ] && [ "$(cd "$REPO" && env HOME="$AD/home" CX_HOME="$AD/home/.conductor" "$CXJOB" status "$J2")" = cancelled ]'
check "[A12] ... rc 130 was on disk before the first TERM landed: a recorded session that reads rc on TERM saw 130 (got $(cat "$JD/rc-at-term" 2>/dev/null)), and it is gone" \
  eval '[ "$(cat "$JD/rc-at-term" 2>/dev/null)" = 130 ] && ! kill -0 "$rpid" 2>/dev/null'
cr -- "$CXJOB" result "$J2"
check "[A12] ... result of the killed job -> 130 with one CX_SIGNAL CANCELLED, last, and the run's own result says cancelled (never an executor that did not start)" \
  eval 'rc_is 130 && one_signal CANCELLED && line_is CX_RESULT status cancelled && ! err_has "stopped before its executor ran"'
# pid-reuse protection: a registry entry whose pid now belongs to an unrelated process
sleep 60 & qp=$!
mkdir -p "$AD/home/.conductor/jobs/20990101-000000-dead"; printf 'x\0' > "$AD/home/.conductor/jobs/20990101-000000-dead/argv"
printf '%s\n' "$qp" > "$AD/home/.conductor/jobs/20990101-000000-dead/pid"; printf '1\n' > "$AD/home/.conductor/jobs/20990101-000000-dead/pid_start"
touch -d '1 hour ago' "$AD/home/.conductor/jobs/20990101-000000-dead/argv"
cr -- "$CXJOB" status 20990101
check "[A12] pid reuse: the recorded pid is alive but its start time differs -> status unknown (not running)" eval 'rc_is 0 && [ "$(cat "$O")" = unknown ]'
cr -- "$CXJOB" kill 20990101-000000-dead
check "[A12] ... and kill never signals that process" eval 'rc_is 0 && kill -0 "$qp" 2>/dev/null'
kill "$qp" 2>/dev/null; wait "$qp" 2>/dev/null
cr -- "$CXJOB" status 2
check "[X]   an ambiguous id prefix -> exit 1" eval 'rc_is 1 && err_has "ambiguous"'
# result: rc 1 (the job's cx-run refused the request) relays its notes and exits 1 without a
# CX_SIGNAL; the last CX_SIGNAL always names the exit (a wall-clock kill, a late cx-job kill).
local JX="$AD/home/.conductor/jobs"
mkdir -p "$JX/20990102-000000-0001" "$JX/20990102-000000-0002" "$JX/20990102-000000-0003"
for i in 1 2 3; do printf 'x\0' > "$JX/20990102-000000-000$i/argv"; : > "$JX/20990102-000000-000$i/out"; done
printf '1\n' > "$JX/20990102-000000-0001/rc"; printf 'cx-run: the id z is taken on this computer\ncx-run: try --help\n' > "$JX/20990102-000000-0001/err"
printf '124\n' > "$JX/20990102-000000-0002/rc"; printf '%s\n' 'CX_SIGNAL {"status": "CANCELLED", "exit": 130, "reason": "x", "retry": null, "cmd": "cx-run"}' > "$JX/20990102-000000-0002/err"
printf '130\n' > "$JX/20990102-000000-0003/rc"; printf '%s\n' 'CX_SIGNAL {"status": "FAILED", "exit": 2, "reason": "x", "retry": null, "cmd": "cx-run"}' > "$JX/20990102-000000-0003/err"
cr -- "$CXJOB" result 20990102-000000-0001
check "[X]   cx-job result of a job whose cx-run exited 1: exit 1, the job's notes, no CX_SIGNAL" eval 'rc_is 1 && no_signal && err_has "is taken on this computer"'
cr -- "$CXJOB" result 20990102-000000-0002
check "[X]   ... rc 124 (the runner's wall clock) after a CX_SIGNAL CANCELLED: exit 12 with one CX_SIGNAL TIMEOUT, last" eval 'rc_is 12 && one_signal TIMEOUT'
cr -- "$CXJOB" result 20990102-000000-0003
check "[X]   ... rc 130 (cx-job kill) after a CX_SIGNAL FAILED 2: exit 130 with one CX_SIGNAL CANCELLED, last" eval 'rc_is 130 && one_signal CANCELLED'
rm -rf "$JX"/20990102-000000-000[123]
cr -- "$CXJOB" list --all
check "[X]   cx-job list --all names every job with its status" eval 'rc_is 0 && out_has "$J  done rc=0" && out_has "$J2  cancelled"'

# --- A13: the caps under cx-run; --no-wait; queued
cr STUB_GROK_RUN=sleep STUB_GROK_SLEEP=20 CLAUDE_PLUGIN_OPTION_CAP_GROK=1 -- "$CXRUN" --background --exec grok --id q1 'x'
J3="$(sed -n 's/^JOB_ID //p' "$O")"
for ((i = 0; i < 100; i++)); do [ -s "$AD/home/.conductor/jobs/$J3/sids" ] && break; sleep 0.1; done
cr STUB_GROK_RUN=ok CLAUDE_PLUGIN_OPTION_CAP_GROK=1 -- "$CXRUN" --exec grok --no-wait --id q2 'x'
check "[A13] cap_grok=1 with one grok job running: cx-run --no-wait -> 28 at once (CX_RESULT no_capacity, one CX_SIGNAL NO_CAPACITY) and grok never ran for it" \
  eval 'rc_is 28 && line_is CX_RESULT status no_capacity && one_signal NO_CAPACITY && ! grep -q "^grok	cwd=$AD/home/.cx-wt/repo-q2" "$ADL"'
cr STUB_GROK_RUN=ok CLAUDE_PLUGIN_OPTION_CAP_GROK=1 CX_SLOT_WAIT_SECS=30 -- "$CXJOB" start --exec grok --id q3 'x'
J="$(sed -n 's/^JOB_ID //p' "$O")"
lc=""
for ((i = 0; i < 100; i++)); do lc="$(cd "$REPO" && env HOME="$AD/home" CX_HOME="$AD/home/.conductor" "$CXJOB" status "$J")"; [ "$lc" = queued ] && break; sleep 0.1; done
check "[A13] ... a second job waits for the slot: cx-job status says queued" test "$lc" = queued
cr -- "$CXJOB" wait "$J"
check "[A13] ... and runs once the first ends (exit 0)" eval 'rc_is 0 && line_is CX_RESULT id q3 && line_is CX_RESULT status ok'
cr -- "$CXJOB" wait "$J3"
check "[X]   the first job ended ok too" eval 'rc_is 0 && line_is CX_RESULT id q1'
# Three foreground cx-run --exec copilot at once, cap_copilot=2, sleeping ghcp-delegate stubs: the
# stub's start/end events never show more than 2 at once, and the slots used are copilot.1-2.
: > "$AD/ev13"
local -a P13=()
for i in 1 2 3; do
  ( SEC_TAG="$SEC_TAG.p$i"; cr STUB_GHCP_RUN=sleep STUB_GHCP_SLEEP=2 STUB_EVENTS="$AD/ev13" CLAUDE_PLUGIN_OPTION_CAP_COPILOT=2 CX_SLOT_WAIT_SECS=60 \
      -- "$CXRUN" --exec copilot --id "p$i" 'Add a file'; printf '%s\n' "$RC" > "$AD/p$i.rc" ) &
  P13+=("$!")
done
wait "${P13[@]}"
local A13_BAD="" A13_MAX
for i in 1 2 3; do
  [ "$(cat "$AD/p$i.rc" 2>/dev/null)" = 0 ] || A13_BAD="$A13_BAD [p$i rc $(cat "$AD/p$i.rc" 2>/dev/null)]"
  case "$(tj get "$AD/home/.conductor/out/p$i/copilot.run.json" slot 2>/dev/null)" in */locks/copilot.1|*/locks/copilot.2) ;; *) A13_BAD="$A13_BAD [p$i slot]" ;; esac
done
A13_MAX="$(overlap "$AD/ev13" ghcp-delegate)"
[ "$(grep -c '^start ghcp-delegate ' "$AD/ev13")" = 3 ] || A13_BAD="$A13_BAD [$(grep -c '^start ghcp-delegate ' "$AD/ev13") runs]"
[ "$A13_MAX" -le 2 ] 2>/dev/null || A13_BAD="$A13_BAD [overlap $A13_MAX]"
grep -q '"slot": "[^"]*/locks/copilot.2"' "$AD"/home/.conductor/out/p[1-3]/copilot.run.json || A13_BAD="$A13_BAD [never two at once: no run took slot 2]"
check "[A13] 3 parallel cx-run --exec copilot with cap_copilot=2 (sleeping stubs): all exit 0, at most 2 executors ever ran at once (got $A13_MAX), the second slot was used and no third${A13_BAD:+:$A13_BAD}" test -z "$A13_BAD"

check "[P30] cx-run: no stub logged BILLABLE (every executor run carried a scenario knob)" eval '! grep -q "^BILLABLE" "$ADL"'
}
bg_section job sec_job


# ------------------------------------------------------------------ 11. runtime copy (section 7.5)
section "install-runtime.sh: subset, exec bits, CR handling, idempotence, concurrency"
RSRC="$TMP/rt-src"
mkdir -p "$RSRC"
(cd "$ROOT" && cp -R .claude-plugin bin scripts hooks worker-shims templates skills commands docs tests "$RSRC/")
chmod a-x "$RSRC"/bin/* "$RSRC"/scripts/*.sh "$RSRC"/scripts/host/*.sh "$RSRC"/worker-shims/*
printf 'line one\r\nline two\r\n' > "$RSRC/templates/crlf-note.txt"
irt() { run env CX_HOME="$1" bash "$RSRC/scripts/host/install-runtime.sh" --from "$RSRC"; }
irt "$TMP/rt1"
RT1="$TMP/rt1/runtime/$CXV"
check "[P18] first install: exit 0, CX_RUNTIME changed true with the CRLF file counted, current -> $CXV" \
  eval 'rc_is 0 && line_is CX_RUNTIME changed true && line_is CX_RUNTIME version $CXV && line_is CX_RUNTIME path "$RT1" && line_is CX_RUNTIME stripped_cr 1 && [ "$(readlink "$TMP/rt1/runtime/current")" = $CXV ] && no_signal'
check "[P18] copies only the six directories (plus RUNTIME_STAMP): no tests, docs, skills or commands" \
  test "$(cd "$RT1" && find . -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" = ".claude-plugin RUNTIME_STAMP bin hooks scripts templates worker-shims "
check "[P18] exec bits: bin/*, scripts/**/*.sh, scripts/lib/*.py, hooks/*.sh, worker-shims/* are 0755" \
  eval '( for f in "$RT1"/bin/* "$RT1"/scripts/*.sh "$RT1"/scripts/host/*.sh "$RT1"/scripts/lib/*.py "$RT1"/hooks/policy.sh "$RT1"/worker-shims/*; do [ "$(stat -c %a "$f")" = 755 ] || exit 1; done )'
check "[P18] CRs before LF are stripped; RUNTIME_STAMP has version, installed_at, source and sha256" \
  eval '! grep -rq $'"'"'\r'"'"' "$RT1" && grep -qx "version=$CXV" "$RT1/RUNTIME_STAMP" && grep -q "^installed_at=20[0-9-]*T[0-9:]*Z$" "$RT1/RUNTIME_STAMP" && grep -qx "source=$RSRC" "$RT1/RUNTIME_STAMP" && grep -Eq "^sha256=[0-9a-f]{64}$" "$RT1/RUNTIME_STAMP"'
SHA1="$(sed -n 's/^sha256=//p' "$RT1/RUNTIME_STAMP")"
irt "$TMP/rt1"
check "[P18] identical reinstall: changed false, same tree" eval 'rc_is 0 && line_is CX_RUNTIME changed false && [ "$(sed -n "s/^sha256=//p" "$RT1/RUNTIME_STAMP")" = "$SHA1" ]'
touch "$RSRC/templates/repo-bundle/AGENTS.md"
irt "$TMP/rt1"
check "[X]   an mtime-only change: changed false, and the stamp is refreshed (no source file is newer than it), so cx_runtime_ensure does not reinstall on every call" \
  eval 'rc_is 0 && line_is CX_RUNTIME changed false && [ -z "$(find "$RSRC/scripts" "$RSRC/templates" -newer "$RT1/RUNTIME_STAMP" -print -quit)" ]'
printf '\nnew line\n' >> "$RSRC/templates/repo-bundle/AGENTS.md"
irt "$TMP/rt1"
check "[P18] a changed source replaces the copy and moves current; no old copy or tmp dir left" \
  eval 'rc_is 0 && line_is CX_RUNTIME changed true && tail -n 1 "$RT1/templates/repo-bundle/AGENTS.md" | grep -qx "new line" && [ "$(readlink "$TMP/rt1/runtime/current")" = $CXV ] && [ "$(cd "$TMP/rt1/runtime" && find . -mindepth 1 -maxdepth 1 -printf "%f\n" | LC_ALL=C sort | tr "\n" " ")" = ".install.lock $CXV current " ]'
SHA2="$(sed -n 's/^sha256=//p' "$RT1/RUNTIME_STAMP")"
printf 'a\rb\n' > "$RSRC/templates/midline-cr.txt"
irt "$TMP/rt1"
check "[P18] a mid-line CR -> exit 44 CRLF_CORRUPT, the old runtime stays" \
  eval 'rc_is 44 && one_signal CRLF_CORRUPT && [ "$(sed -n "s/^sha256=//p" "$RT1/RUNTIME_STAMP")" = "$SHA2" ] && [ ! -e "$RT1/templates/midline-cr.txt" ] && [ -z "$(cd "$TMP/rt1/runtime" && find . -maxdepth 1 -name ".tmp.*")" ]'
rm -f -- "$RSRC/templates/midline-cr.txt"
# A content change while a cx-run uses the copy (its held .run.lock names it): the swap waits.
mkdir -p "$TMP/rt1/out/busy"; printf 'pid=1 job= since=x\nrt=%s\n' "$RT1" > "$TMP/rt1/out/busy/.run.lock"
RTH="$(hold "$TMP/rt1/out/busy/.run.lock" -x "$TMP/rt1.held")"; wait_file "$TMP/rt1.held"
printf 'later line\n' >> "$RSRC/templates/repo-bundle/AGENTS.md"
irt "$TMP/rt1"
check "[X]   changed content while a cx-run still uses runtime/<version> (its .run.lock held, rt= naming it): not swapped (changed false, deferred 1, the old files stay)" \
  eval 'rc_is 0 && line_is CX_RUNTIME changed false && line_is CX_RUNTIME deferred 1 && out_has "the update waits" && ! grep -qx "later line" "$RT1/templates/repo-bundle/AGENTS.md"'
check "[X]   ... cx_runtime_ensure keeps using that copy meanwhile (no install attempt, one note)" \
  eval 'env CX_HOME="$TMP/rt1" bash -c ". \"\$1/scripts/lib/common.sh\"; cx_runtime_ensure; printf %s \"\$CX_RT\"" _ "$RSRC" > "$TMP/rt1.ens" 2> "$TMP/rt1.ens.err"; [ "$(cat "$TMP/rt1.ens")" = "$RT1" ] && grep -q "still use the runtime copy" "$TMP/rt1.ens.err" && ! grep -qx "later line" "$RT1/templates/repo-bundle/AGENTS.md"'
kill "$RTH" 2>/dev/null; wait "$RTH" 2>/dev/null
irt "$TMP/rt1"
check "[X]   ... once that run ends the next install swaps it in (changed true)" \
  eval 'rc_is 0 && line_is CX_RUNTIME changed true && grep -qx "later line" "$RT1/templates/repo-bundle/AGENTS.md"'
rm -rf "$TMP/rt1/out"
( env CX_HOME="$TMP/rt2" bash "$RSRC/scripts/host/install-runtime.sh" --from "$RSRC" > "$TMP/rt2a.out" 2> "$TMP/rt2a.err" ) &
p1=$!
( env CX_HOME="$TMP/rt2" bash "$RSRC/scripts/host/install-runtime.sh" --from "$RSRC" > "$TMP/rt2b.out" 2> "$TMP/rt2b.err" ) &
p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
CH="$(tj line "$TMP/rt2a.err" CX_RUNTIME changed) $(tj line "$TMP/rt2b.err" CX_RUNTIME changed)"
check "[P18] two concurrent installs of one source: one changed true, one changed false, one clean tree" \
  eval '[ "$r1$r2" = 00 ] && { [ "$CH" = "true false" ] || [ "$CH" = "false true" ]; } && [ ! -e "$TMP/rt2/runtime/$CXV/$CXV" ] && [ -z "$(find "$TMP/rt2/runtime/$CXV" -mindepth 1 -maxdepth 1 -name ".tmp.*" -o -mindepth 1 -maxdepth 1 -name "$CXV")" ] && [ "$(cd "$TMP/rt2/runtime" && find . -mindepth 1 -maxdepth 1 -printf "%f\n" | LC_ALL=C sort | tr "\n" " ")" = ".install.lock $CXV current " ]'
run env CX_HOME="$TMP/rt3" bash "$RSRC/scripts/host/install-runtime.sh" --from "$TMP/not-a-plugin"
check "[X]   --from a directory without scripts/lib/common.sh -> exit 1" eval 'rc_is 1 && no_signal'
run env CX_HOME="$TMP/rt3" bash "$RSRC/scripts/host/install-runtime.sh" --bogus
check "[X]   unknown argument -> exit 1" rc_is 1
mkdir -p "$TMP/irmnt/s" "$TMP/irboot"; ln -s "$RSRC" "$TMP/irmnt/s/src"; : > "$TMP/irboot/main"
(cd "$TMP/irboot" && env CX_HOME="$TMP/rt4" CX_MNT_ROOT="$TMP/irmnt/" CX_STAGE_WIN='S:\src' bash -s < "$RSRC/scripts/host/install-runtime.sh" > "$TMP/irboot.out" 2> "$TMP/irboot.err"); RC=$?
O="$TMP/irboot.out" E="$TMP/irboot.err"
check "[P18] bootstrap (bash -s with CX_STAGE_WIN) from a cwd holding a file named main: installs from the stage, not from the cwd's parent" \
  eval 'rc_is 0 && out_has "from Git Bash" && line_is CX_RUNTIME changed true && [ -f "$TMP/rt4/runtime/$CXV/RUNTIME_STAMP" ]'

# ------------------------------------------------------------------ 12. Git Bash -> WSL forwarding (sections 7.3, 7.4, 7.7, 8.6)
section "Git Bash forwarding: argv, env allowlist, cwd, exit codes, runtime install, WSL-side environment, --windows"
WIN="$TMP/win"
GB_USER="$WIN/c/Users/me"
GB_TMP="$GB_USER/AppData/Local/Temp"
mkdir -p "$GB_TMP" "$WIN/c/proj" "$WIN/c/Users/John Smith/AppData/Local/Temp" "$TMP/share/x" "$WIN/c/Windows/System32"
ln -s "John Smith" "$WIN/c/Users/JOHNSM~1"
ln -s / "$TMP/unc"
# The mini bin: exactly the Git Bash tools of section 3.1, plus bash itself, Git for Windows' git
# (the gitbash/ stub) and a python3 trap that logs PYTHON_CALLED and exits 9009 (P42).
GB_MINI="$TMP/gb-mini"
mkdir -p "$GB_MINI"
for t in awk cat cp cut dirname env grep head iconv kill mkdir mktemp od rm sed sleep tee timeout tr uname wc bash; do
  ln -s "$(PATH="$REAL_PATH" command -v "$t")" "$GB_MINI/$t"
done
ln -s "$STUBS/gitbash/git" "$GB_MINI/git"
PYTRAP="$TMP/pytrap.log"
printf '#!/bin/bash\necho PYTHON_CALLED "$@" >> %q\nexit 9009\n' "$PYTRAP" > "$GB_MINI/python3"
chmod 0755 "$GB_MINI/python3"
cp "$GB_MINI/python3" "$GB_MINI/python"
: > "$PYTRAP"
# The WSL side: a template Linux home with settings, the fake plugins, an interactive host
# record written by a doctor run "from a WSL terminal", and the runtime copy; each scenario
# clones it (wsl_clone NAME), so parallel forwarded runs never share state.
WT="$TMP/wsl-template"
mkdir -p "$WT/.claude/plugins" "$WT/.grok"
cp "$FIX/settings/green.json" "$WT/.claude/settings.json"
write_installed "$WT/.claude" "$ROOT"
printf '[cli]\nauto_update = false\n' > "$WT/.grok/config.toml"
printf '[profiles.cx-workspace]\nextends = "workspace"\n' > "$WT/.grok/sandbox.toml"
printf 'export COPILOT_AUTO_UPDATE=false\nexport GROK_DISABLE_AUTOUPDATER=1\nexport AGY_CLI_DISABLE_AUTO_UPDATE=true\n' > "$WT/.profile"
WSL_PATH0="$STUBS:$PY_DIR:/usr/bin:/bin"
# wsl_direct HOME CMD...: a command "in a WSL terminal" (not forwarded) of that Linux home.
wsl_direct() {
  local h="$1"
  shift
  env -u CLAUDE_CONFIG_DIR -u CX_HOME -u XDG_CACHE_HOME -u XDG_DATA_HOME -u XDG_CONFIG_HOME -u GHCP_COPILOT_BIN -u TMPDIR \
    HOME="$h" WSL_DISTRO_NAME=Ubuntu WSL_INTEROP=/run/WSL/1_interop CX_MNT_ROOT="$WIN/" PATH="$WSL_PATH0" STUB_LOG="$TMP/wsl-direct.log" "$@"
}
mkdir -p "$WT/.gemini/antigravity-cli"
printf '{"permissions": {"allow": ["write_file(%s/.cx-wt)"]}}\n' "$WT" > "$WT/.gemini/antigravity-cli/settings.json"
(cd "$TMP/work" && wsl_direct "$WT" "$DOCTOR" > "$TMP/wsl-direct.out" 2> "$TMP/wsl-direct.err" < /dev/null); RC=$?
O="$TMP/wsl-direct.out" E="$TMP/wsl-direct.err"
check "[X]   setup: a doctor from a WSL terminal (host wsl, distro Ubuntu) writes the interactive host record" \
  eval 'line_is CX_HOST host wsl && line_is CX_HOST hostkey wsl-Ubuntu && [ "$(tj get "$WT/.conductor/hosts/wsl-Ubuntu.json" path_source)" = interactive ] && [ "$(tj get "$WT/.conductor/hosts/wsl-Ubuntu.json" logins.copilot.direct)" = true ] && d_ok D6 && no_fail_glyph'
REC_PATH0="$(cat "$WT/.conductor/hosts/wsl-Ubuntu.path")"
cp -a "$WT" "$TMP/wsl-template-noruntime"
wsl_direct "$WT" bash "$ROOT/scripts/host/install-runtime.sh" --from "$ROOT" > /dev/null 2>&1
# A test-only target inside the runtime copy (cx-gate is on the forwarder's list and does not
# exist before Phase 3): it records its environment, cwd, argv and stdin.
cat > "$WT/.conductor/runtime/$CXV/scripts/cx-gate.sh" <<'SH'
#!/usr/bin/env bash
env > "$HOME/target.env"
pwd > "$HOME/target.pwd"
printf '%s\0' "$@" > "$HOME/target.argv"
[ "${1-}" = --stdin ] && cat > "$HOME/target.stdin"
[ "${1-}" = --exit ] && exit "$2"
[ "${1-}" = --sleep ] && exec sleep "$2"
exit 0
SH
chmod 0755 "$WT/.conductor/runtime/$CXV/scripts/cx-gate.sh"
WH="$TMP/wh"
mkdir -p "$WH"
# wsl_clone NAME [--no-runtime] [KNOB=VALUE...]: a private Linux home; knobs go to its .stub.env.
wsl_clone() {
  local n="$1" src="$WT" k
  shift
  if [ "${1-}" = --no-runtime ]; then src="$TMP/wsl-template-noruntime"; shift; fi
  cp -a "$src" "$WH/$n"
  printf '{"permissions": {"allow": ["write_file(%s/.cx-wt)"]}}\n' "$WH/$n" > "$WH/$n/.gemini/antigravity-cli/settings.json"
  { printf 'STUB_LOG=%s\nSTUB_GROK_AUTH=1\n' "$WH/$n.log"; for k in "$@"; do printf '%s\n' "$k"; done; } > "$WH/$n/.stub.env"
  printf '%s' "$WH/$n"
}
GB_PATH="$STUBS:$GB_MINI"
# gb NAME [VAR=VALUE...] -- CMD...: a command in the simulated Git Bash, cwd ${GB_CWD:-$WIN/c/proj},
# stdin ${GB_IN:-/dev/null}; the WSL side is $WH/${GB_HOME:-NAME} (wsl_clone it first). Output in
# $WH/NAME.{out,err,rc} and $O/$E/$RC; gb_bg runs it in the pool.
gb_env() {
  local n="$1"
  GBE=(HOME="$GB_USER" USERPROFILE='C:\Users\me' PATH="$GB_PATH" TMPDIR="$GB_TMP" LANG=C.UTF-8
       STUB_UNAME_S=MINGW64_NT-10.0-26100 STUB_UNAME_N=WINBOX STUB_WIN_ROOT="$WIN" STUB_UNC_ROOT="$TMP/unc"
       STUB_SHARE_ROOT="$TMP/share" STUB_WSL_HOME="$WH/${GB_HOME:-$n}" STUB_WSL_MNT="$WIN/" STUB_WSL_PATH="$STUBS:$PY_DIR:/usr/bin:/bin:/mnt/c/Windows/System32"
       STUB_WSL_DETECT_ROOT="$TMP/root" CX_DETECT_ROOT="$TMP/root" STUB_LOG="$WH/$n.gb.log" STUB_REAL_GIT="$REAL_GIT")
}
gb() {
  local n="$1"
  shift
  gb_env "$n"
  while [ $# -gt 0 ] && [ "$1" != -- ]; do GBE+=("$1"); shift; done
  shift
  O="$WH/$n.out" E="$WH/$n.err"
  (cd "${GB_CWD:-$WIN/c/proj}" && env -i PWD="${GB_CWD:-$WIN/c/proj}" "${GBE[@]}" "$@" > "$O" 2> "$E" < "${GB_IN:-/dev/null}"); RC=$?
  printf '%s\n' "$RC" > "$WH/$n.rc"
}
gb_bg() { pool_go; ( gb "$@" ) & DOC_PIDS+=("$!"); }
# gb_private_mini NAME: a copy of the mini bin whose python3 trap logs to $TMP/pytrap-NAME.log,
# put on GB_PATH for the calling (background) section: its forwarded runs are checked for python3
# calls on the Git Bash side by the section itself, whatever the timing of the shared P42 check.
gb_private_mini() {
  local d="$TMP/gb-mini-$1" f
  mkdir -p "$d"
  for f in "$GB_MINI"/*; do [ "${f##*/}" = python3 ] || [ "${f##*/}" = python ] || cp -P "$f" "$d/"; done
  printf '#!/bin/bash\necho PYTHON_CALLED "$@" >> %q\nexit 9009\n' "$TMP/pytrap-$1.log" > "$d/python3"
  chmod 0755 "$d/python3"; cp "$d/python3" "$d/python"
  : > "$TMP/pytrap-$1.log"
  GB_PATH="$STUBS:$d"
}
gb_use() { O="$WH/$1.out"; E="$WH/$1.err"; RC="$(cat "$WH/$1.rc" 2>/dev/null)"; GLOG="$WH/$1.gb.log"; WLOG="$WH/$1.log"; WHOME="$WH/$1"; }
fwd_dir() { sed -n 's/^forward-wsl: CX_DEBUG=1: keeping the transport directory //p' "$E" | tail -n 1; }
# ------------------------------------------------------------------ 12b. pool slots (section 15.3)
# A background section: concurrent cx-wsl executor calls, direct and forwarded through the stub
# wsl.exe, against sleeping wrappers (A25's half without cx-run), and A26. Each scenario has its
# own WSL home (wsl_clone), so its $CX_HOME/locks is private; its host record names the sleepers.
LOCKS_LIB="$ROOT/scripts/lib/locks.sh"
# The sleeper: answers free forms at once; otherwise logs "start NAME PID TIME CX_SLOT_FDS" and
# "end NAME PID TIME" around a sleep of $DIR/sleep.NAME (else $DIR/sleep, else 1) seconds into
# $DIR/events; ghcp-job leaves a detached sleep behind (a job keeps every inherited descriptor).
SLEEPER="$TMP/sleeper.sh"
cat > "$SLEEPER" <<'SH'
#!/bin/bash
d="${0%/*}"; n="${0##*/}"
case "${1-}" in --version) echo "$n 1.4.12"; exit 0 ;; models|usage|status|result|list|inspect) echo free; exit 0 ;; esac
case " $* " in *" --print-command "*|*" -p /usage "*|*" -p /model "*|*" -p /config "*) echo free; exit 0 ;; esac
s="$(cat "$d/sleep.$n" 2>/dev/null || cat "$d/sleep" 2>/dev/null || echo 1)"
printf 'start %s %s %s %s\n' "$n" "$$" "$(date +%s.%N)" "${CX_SLOT_FDS:-none}" >> "$d/events"
if [ "$n" = ghcp-job ]; then
  nohup sleep "$s" > /dev/null 2>&1 &
  echo "JOB_ID 20261101-000000-abcd"
  exit 0
fi
sleep "$s"
printf 'end %s %s %s\n' "$n" "$$" "$(date +%s.%N)" >> "$d/events"
echo "answer from $n"
SH
chmod 0755 "$SLEEPER"
# slot_home NAME [SLEEP]: a WSL home whose host record runs the sleepers in $WH/NAME.bin.
slot_home() {
  local n="$1" b="$WH/$1.bin" t
  wsl_clone "$n" > /dev/null
  mkdir -p "$b"
  for t in ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug agy-delegate agy-job agy grok; do cp "$SLEEPER" "$b/$t"; done
  printf '%s\n' "${2:-1}" > "$b/sleep"
  : > "$b/events"
  "$REAL_PY" -I - "$WH/$n/.conductor/hosts/wsl-Ubuntu.json" "$b" <<'PY'
import json, sys
p, b = sys.argv[1], sys.argv[2]
r = json.load(open(p))
for k in ("ghcp_delegate", "ghcp_job", "ghcp_handoff", "ghcp_ci_debug", "agy_delegate", "agy_job", "agy", "grok"):
    r["bin"][k] = b + "/" + k.replace("_", "-")
open(p, "w").write(json.dumps(r))
PY
}
# sd NAME OUT [VAR=VALUE...] -- CMD...: a direct (WSL terminal) call in home NAME; $WH/OUT.{out,err,rc}.
sd() {
  local n="$1" o="$2"
  shift 2
  local -a ev=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done
  shift
  (cd "$TMP/work" && wsl_direct "$WH/$n" env STUB_LOG="$TMP/slots.log" ${ev[@]+"${ev[@]}"} "$@" > "$WH/$o.out" 2> "$WH/$o.err" < /dev/null; printf '%s\n' "$?" > "$WH/$o.rc")
}
s_use() { O="$WH/$1.out"; E="$WH/$1.err"; RC="$(cat "$WH/$1.rc" 2>/dev/null)"; }
n_starts() { grep -c "^start $2 " "$WH/$1.bin/events"; }
wait_start() {  # HOME NAME COUNT: until COUNT start lines of NAME are logged (at most 10 s)
  local i
  for ((i = 0; i < 200; i++)); do [ "$(n_starts "$1" "$2")" -ge "$3" ] && return 0; sleep 0.05; done
  return 1
}

sec_slots() {
section "pool slots: cx-wsl executor calls share the caps, direct and forwarded (A25 without cx-run, A26)"
local i k c p1 p2 p3 t0 lk lkw
local -a SP=()
# A25: six concurrent cx-wsl ghcp-delegate calls (three direct, three forwarded), cap_copilot=2;
# and four agy calls (cap_agy=2). Both run in the background while the later scenarios run.
slot_home sa 2
slot_home sc 1
for i in 1 2 3; do
  sd sa "sa-d$i" CLAUDE_PLUGIN_OPTION_CAP_COPILOT=2 CX_SLOT_WAIT_SECS=40 -- "$CXWSL" ghcp-delegate --model m "task $i" &
  SP+=("$!")
  ( GB_HOME=sa gb "sa-f$i" CLAUDE_PLUGIN_OPTION_CAP_COPILOT=2 CX_SLOT_WAIT_SECS=40 -- "$CXWSL" ghcp-delegate --model m "task f$i" ) &
  SP+=("$!")
done
sd sc sc-d1 CLAUDE_PLUGIN_OPTION_CAP_AGY=2 CX_SLOT_WAIT_SECS=40 -- "$CXWSL" agy --model claude-opus-5-5-high -p "task 1" &
SP+=("$!")
sd sc sc-d2 CLAUDE_PLUGIN_OPTION_CAP_AGY=2 CX_SLOT_WAIT_SECS=40 -- "$CXWSL" agy-delegate --model x --dir /tmp "task 2" &
SP+=("$!")
sd sc sc-d3 CLAUDE_PLUGIN_OPTION_CAP_AGY=2 CX_SLOT_WAIT_SECS=40 -- "$CXWSL" agy --new-project --output-format json -p /model &
SP+=("$!")
( GB_HOME=sc gb sc-f1 CLAUDE_PLUGIN_OPTION_CAP_AGY=2 CX_SLOT_WAIT_SECS=40 -- "$CXWSL" agy -p "task f1" ) &
SP+=("$!")

# A26 and overflow: every copilot slot held (default cap 3) -> 28 after CX_SLOT_WAIT_SECS, direct and forwarded.
slot_home sb 1
mkdir -p "$WH/sb/.conductor/locks"
p1="$(hold "$WH/sb/.conductor/locks/copilot.1" -x "$WH/sb.h1")"; p2="$(hold "$WH/sb/.conductor/locks/copilot.2" -x "$WH/sb.h2")"; p3="$(hold "$WH/sb/.conductor/locks/copilot.3" -x "$WH/sb.h3")"
wait_file "$WH/sb.h1"; wait_file "$WH/sb.h2"; wait_file "$WH/sb.h3"
t0=$SECONDS
sd sb sb-over CX_SLOT_WAIT_SECS=2 -- "$CXWSL" ghcp-delegate --model m task
local SB_T=$((SECONDS - t0))
s_use sb-over
check "[A26] cx-wsl ghcp-delegate while all 3 copilot slots are held: exit 28 after CX_SLOT_WAIT_SECS=2 (${SB_T} s) with a waiting note, a reason note and one CX_SIGNAL NO_CAPACITY last; the wrapper never ran" \
  eval 'rc_is 28 && one_signal NO_CAPACITY && err_has "cx-wsl: all 3 copilot slots are busy (cap_copilot=3); waiting up to 2 s" && err_has "cx-wsl: no copilot capacity: all 3 copilot slots stayed busy for 2 s; use the next pool in the order" && out_empty && [ "$(n_starts sb ghcp-delegate)" = 0 ] && [ "$SB_T" -ge 1 ] && [ "$SB_T" -le 15 ]'
GB_HOME=sb gb sb-fover CX_SLOT_WAIT_SECS=1 -- "$CXWSL" ghcp-handoff --dir /tmp task
check "[A25] the same from simulated Git Bash (CX_SLOT_WAIT_SECS crosses the forwarder): ghcp-handoff exits 28 with exactly one CX_SIGNAL NO_CAPACITY, last" \
  eval 'rc_is 28 && one_signal NO_CAPACITY && [ "$(n_starts sb ghcp-handoff)" = 0 ]'
local SB_BAD=""
for c in "gh --version" "git --version" "ghcp-delegate --print-command --model m task" "ghcp-job status 20261101" "ghcp-job result 20261101" "ghcp-models --json" "ghcp-delegate --help"; do
  read -r -a CMD <<< "$c"
  t0=$SECONDS
  sd sb sb-free CX_SLOT_WAIT_SECS=20 -- "$CXWSL" "${CMD[@]}"
  s_use sb-free
  { rc_is 0 && ! grep -q '^CX_' "$E" && ! err_has "slots are busy" && [ $((SECONDS - t0)) -lt 15 ]; } || SB_BAD="$SB_BAD [$c: rc $RC]"
done
check "[A26] ... while they are held, cx-wsl gh --version, git --version, ghcp-delegate --print-command / --help, ghcp-job status / result and ghcp-models take no slot: exit 0 at once${SB_BAD:+:$SB_BAD}" test -z "$SB_BAD"
# A30: cx-wsl ghcp-cloud is allowed and takes no slot (the Copilot cloud agent runs on GitHub).
"$REAL_PY" -I - "$WH/sb/.conductor/hosts/wsl-Ubuntu.json" "$STUBS/ghcp-cloud" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
r["bin"]["ghcp_cloud"] = sys.argv[2]
open(sys.argv[1], "w").write(json.dumps(r))
PY
t0=$SECONDS
sd sb sb-cloud STUB_GH_AGENT_TASK=ok CX_SLOT_WAIT_SECS=20 -- "$CXWSL" ghcp-cloud create -R github.com/o/r -
local SB_CT=$((SECONDS - t0))
s_use sb-cloud
check "[A30] cx-wsl ghcp-cloud is allowed and takes no pool slot: while every copilot slot is held, cx-wsl ghcp-cloud create -R github.com/o/r - reaches gh agent-task create at once (${SB_CT} s; exit 0, the pull request URL, no CX_* line)" \
  eval 'rc_is 0 && out_has "/pull/42" && ! grep -q "^CX_" "$E" && [ "$SB_CT" -lt 15 ] && grep -q "^gh	.*argv: agent-task create -F - --repo github.com/o/r$" "$TMP/slots.log"'
kill "$p1" "$p2" "$p3" 2>/dev/null; wait "$p1" "$p2" "$p3" 2>/dev/null
sd sb sb-after CX_SLOT_WAIT_SECS=1 -- "$CXWSL" ghcp-delegate --model m task
s_use sb-after
check "[A26] once the holders exit, the same call runs (exit 0, its answer, stderr empty)" eval 'rc_is 0 && out_has "answer from ghcp-delegate" && err_empty'
# A job started through cx-wsl keeps its slot; an inherited slot is reused; cap 0 refuses at once.
slot_home se 3
sd se se-job CLAUDE_PLUGIN_OPTION_CAP_COPILOT=1 -- "$CXWSL" ghcp-job start --model m task
sd se se-busy CLAUDE_PLUGIN_OPTION_CAP_COPILOT=1 CX_SLOT_WAIT_SECS=1 -- "$CXWSL" ghcp-delegate --model m task
s_use se-busy
check "[X]   cx-wsl ghcp-job start returns at once, and its detached job keeps the copilot slot: with cap_copilot=1 a following ghcp-delegate exits 28" \
  eval '[ "$(cat "$WH/se-job.rc")" = 0 ] && grep -q "^JOB_ID " "$WH/se-job.out" && rc_is 28 && one_signal NO_CAPACITY'
sd se se-nest CLAUDE_PLUGIN_OPTION_CAP_GROK=1 CX_SLOT_WAIT_SECS=1 -- bash -c '. "$1" || exit 9; cx_slot_take grok || exit $?; "$2" grok -p "nested task"' _ "$LOCKS_LIB" "$CXWSL"
s_use se-nest
check "[X]   a shell that holds the only grok slot (cx_slot_take grok, cap_grok=1) runs cx-wsl grok -p inside: the child reuses the inherited slot (CX_SLOT_FDS) instead of waiting" \
  eval 'rc_is 0 && out_has "answer from grok" && grep -q "^start grok .*grok\.1=" "$WH/se.bin/events"'
t0=$SECONDS
sd se se-cap0 CLAUDE_PLUGIN_OPTION_CAP_GROK=0 CX_SLOT_WAIT_SECS=30 -- "$CXWSL" grok -p task
s_use se-cap0
check "[X]   cap_grok=0: cx-wsl grok -p exits 28 at once (the pool is disabled), one CX_SIGNAL NO_CAPACITY" \
  eval 'rc_is 28 && one_signal NO_CAPACITY && err_has "the grok pool is disabled (cap_grok=0)" && [ $((SECONDS - t0)) -lt 20 ] && [ "$(grep -c "^start grok " "$WH/se.bin/events")" = 1 ]'
sd se se-bad CX_SLOT_WAIT_SECS=soon CLAUDE_PLUGIN_OPTION_CAP_GROK=x -- "$CXWSL" grok models
s_use se-bad
check "[X]   a free form ignores the slot knobs (grok models with CX_SLOT_WAIT_SECS=soon, cap_grok=x): exit 0, no note" eval 'rc_is 0 && err_empty'
t0=$SECONDS
sd se se-v CLAUDE_PLUGIN_OPTION_CAP_GROK=0 -- "$CXWSL" grok -v
s_use se-v
check "[X]   cx-wsl grok -v (grok 1.0.70's version flag) is a free form: no slot even with cap_grok=0 (exit 0 at once, no CX_SIGNAL)" \
  eval 'rc_is 0 && no_signal && ! err_has "pool is disabled" && [ $((SECONDS - t0)) -lt 15 ]'
mkdir -p "$WH/se/.conductor/state"; printf '{"id": "other"}\n' > "$WH/se/.conductor/state/agy-paused"
sd se se-paused -- "$CXWSL" agy-delegate --model m task
s_use se-paused
check "[X]   cx-wsl agy-delegate while agy dispatch is paused (a wrong_tree result): exit 28 NO_CAPACITY (one CX_SIGNAL, the pause named) once it has its slot; the wrapper never ran" \
  eval 'rc_is 28 && one_signal NO_CAPACITY && err_has "agy dispatch is paused" && [ "$(n_starts se agy-delegate)" = 0 ]'
rm -f "$WH/se/.conductor/state/agy-paused"
# A Phase 1 step (an older skill copy) holding ~/.conductor/locks/agy exclusively blocks agy slots.
slot_home sd 1
mkdir -p "$WH/sd/.conductor/locks"
lk="$(hold "$WH/sd/.conductor/locks/agy" -x "$WH/sd.h")"
wait_file "$WH/sd.h"
sd sd sd-legacy CX_SLOT_WAIT_SECS=1 -- "$CXWSL" agy-delegate --model x task
s_use sd-legacy
local SD_OK=""
{ rc_is 28 && one_signal NO_CAPACITY && err_has "for a Phase 1 agy step (the" && [ "$(grep -c '^start ' "$WH/sd.bin/events")" = 0 ]; } && SD_OK=1
sd sd sd-free CX_SLOT_WAIT_SECS=20 -- "$CXWSL" agy -p /usage --output-format json
s_use sd-free
{ rc_is 0 && err_empty; } || SD_OK=""
kill "$lk" 2>/dev/null; wait "$lk" 2>/dev/null
check "[A25] while a Phase 1 agy step holds ~/.conductor/locks/agy (exclusive), cx-wsl agy-delegate exits 28 (the slot takes that lock shared), and the zero-quota agy -p /usage takes nothing" test -n "$SD_OK"
# The queued marker for cx-job (CX_JOB_DIR) and the library's own return codes.
mkdir -p "$WH/sq/locks" "$WH/sq/job"
lk="$(hold "$WH/sq/locks/copilot.1" -x "$WH/sq.h")"
wait_file "$WH/sq.h"
( CX_HOME="$WH/sq" CX_JOB_DIR="$WH/sq/job" bash -c '. "$1"; cx_lock_acquire copilot 1 6; printf "%s %s\n" "$?" "${CX_SLOT_N:-}" > "$2"' _ "$LOCKS_LIB" "$WH/sq.res" 2> "$WH/sq.err" ) &
lkw=$!
wait_file "$WH/sq/job/queued"
local SQ_Q; SQ_Q="$(cat "$WH/sq/job/queued" 2>/dev/null)"
kill "$lk" 2>/dev/null; wait "$lk" 2>/dev/null
wait "$lkw" 2>/dev/null
check "[X]   cx_lock_acquire while the only slot is busy: \$CX_JOB_DIR/queued names the pool while it waits (got '$SQ_Q'), is gone once the holder exits and the slot is taken (rc 0, slot 1)" \
  eval '[ "$SQ_Q" = copilot ] && [ ! -e "$WH/sq/job/queued" ] && [ "$(cat "$WH/sq.res")" = "0 1" ]'
CX_HOME="$WH/sq" bash -c '. "$1"; cx_lock_acquire claude 2 0; a=$?; cx_lock_acquire copilot -1 0; b=$?; cx_lock_try copilot 1; c=$?; printf "%s %s %s %s" "$a" "$b" "$c" "$CX_SLOT_FDS"; cx_lock_release; printf " [%s]" "${CX_SLOT_FDS-}"' _ "$LOCKS_LIB" > "$WH/sq.rc2" 2>&1
check "[X]   locks.sh: an unknown pool or a bad cap -> 2; cx_lock_try takes a free slot and records it in CX_SLOT_FDS; cx_lock_release clears it (got $(cat "$WH/sq.rc2"))" \
  eval 'grep -Eq "^2 2 0 copilot\.1=[0-9]+ \[\]$" "$WH/sq.rc2"'
for p1 in "${SP[@]}"; do wait "$p1" 2>/dev/null; done
local SA_BAD=""
for i in 1 2 3; do
  for k in d f; do
    s_use "sa-$k$i"
    { rc_is 0 && out_has "answer from ghcp-delegate" && ! grep -q '^CX_' "$E"; } || SA_BAD="$SA_BAD [sa-$k$i rc $RC]"
  done
done
[ "$(n_starts sa ghcp-delegate)" = 6 ] || SA_BAD="$SA_BAD [$(n_starts sa ghcp-delegate) starts]"
SA_MAX="$(overlap "$WH/sa.bin/events" ghcp-delegate)"
[ "$SA_MAX" = 2 ] || SA_BAD="$SA_BAD [overlap $SA_MAX]"
grep -q "^start ghcp-delegate .* copilot\.[12]=" "$WH/sa.bin/events" || SA_BAD="$SA_BAD [no copilot.N in CX_SLOT_FDS]"
grep -q "^start ghcp-delegate .* copilot\.3=" "$WH/sa.bin/events" && SA_BAD="$SA_BAD [a third slot]"
check "[A25] 6 concurrent cx-wsl ghcp-delegate calls (3 direct, 3 forwarded from Git Bash) with cap_copilot=2: all exit 0 with their answers and no CX_* line, at most 2 ever run at once (got $SA_MAX), only slots copilot.1-2 are used${SA_BAD:+:$SA_BAD}" test -z "$SA_BAD"
# A25: agy calls never overlap (the launch lock is held for the whole call), cap_agy=2.
local SC_BAD=""
for i in sc-d1 sc-d2 sc-d3 sc-f1; do s_use "$i"; rc_is 0 || SC_BAD="$SC_BAD [$i rc $RC]"; done
[ "$(grep -c '^start ' "$WH/sc.bin/events")" = 3 ] || SC_BAD="$SC_BAD [$(grep -c '^start ' "$WH/sc.bin/events") starts]"
SC_MAX="$(overlap "$WH/sc.bin/events" agy agy-delegate)"
[ "$SC_MAX" = 1 ] || SC_BAD="$SC_BAD [overlap $SC_MAX]"
grep '^start ' "$WH/sc.bin/events" | grep -v 'agy-launch=' > /dev/null && SC_BAD="$SC_BAD [a run without the launch lock]"
check "[A25] agy runs through cx-wsl (agy -p, agy-delegate, a forwarded agy -p) with cap_agy=2 never overlap: each holds an agy slot and the agy launch lock for the whole call (got $SC_MAX at once); the registration with -p /model is a launch too${SC_BAD:+:$SC_BAD}" test -z "$SC_BAD"
}
bg_section slots sec_slots

sec_runx() {
section "Phase 2 cx-run: the Copilot cloud agent lane, cx-init --user-grants, forwarded runs and jobs (A30, A18, A16)"
local AD="$TMP/crx" ADL="$TMP/crx.log" HK REPO L J lc
gb_private_mini runx
cr_setup
L="$AD/home/.conductor/ledger.jsonl"
# --- A30: the Copilot cloud agent lane, then the PR head gated
printf '<!-- cx-task {"id": "k1", "commands": ["true"]} -->\n# Task k1: add k\n## Goal\nAdd k.txt.\n## Allowed changes\nk.txt only.\n## Forbidden\nEditing tests; committing, pushing or branching; starting subagents.\n' > "$AD/k1.md"
cr STUB_GH_AGENT_TASK=ok STUB_GH_TASK_FILE="$AD/gh-task.txt" -- "$CXRUN" --exec copilot-cloud --gh-repo github.com/o/r --task-file "$AD/k1.md"
check "[A30] --exec copilot-cloud: the stub gh agent-task received the rendered contract (goal, allowed changes; no ban on committing, pushing or branching); CX_RESULT and the ledger record the task and PR 42; VERIFY THIS names cx-run --finish k1" \
  eval 'rc_is 0 && grep -q "^## Goal" "$AD/gh-task.txt" && grep -q "k.txt only" "$AD/gh-task.txt" && ! grep -q "committing, pushing or branching" "$AD/gh-task.txt" && line_is CX_RESULT cloud.pr 42 && grep "\"id\": \"k1\"" "$L" | grep -q "\"pr\": 42" && out_has "cx-run --finish k1"'
# A fork checkout: origin is the user's fork (its own pull/42 is an unrelated commit), upstream is
# the task's repository github.com/o/r (insteadOf maps both URLs to local bare repositories).
git init -q --bare "$AD/origin.git"; git init -q --bare "$AD/fork.git"
git -C "$REPO" config url."$AD/origin.git".insteadOf https://github.com/o/r.git
git -C "$REPO" config url."$AD/fork.git".insteadOf https://github.com/me/r.git
git -C "$REPO" remote add origin https://github.com/me/r.git; git -C "$REPO" remote add upstream https://github.com/o/r.git
git -C "$REPO" checkout -q -b pr42; printf 'k\n' > "$REPO/k.txt"; git -C "$REPO" add k.txt; git -C "$REPO" commit -qm k
git -C "$REPO" push -q "$AD/origin.git" HEAD:refs/pull/42/head; git -C "$REPO" checkout -q -; git -C "$REPO" branch -q -D pr42
git -C "$REPO" checkout -q -b fork42; printf 'f\n' > "$REPO/fork.txt"; git -C "$REPO" add fork.txt; git -C "$REPO" commit -qm fork
git -C "$REPO" push -q "$AD/fork.git" HEAD:refs/pull/42/head; git -C "$REPO" checkout -q -; git -C "$REPO" branch -q -D fork42
PRH="$(git --git-dir="$AD/origin.git" rev-parse refs/pull/42/head)"
cr STUB_GH_PR_HEAD=0000000000000000000000000000000000000042 -- "$CXRUN" --finish k1
check "[A30] --finish: a fetched commit that is not the pull request's head on GitHub (gh pr view headRefOid) is never gated: exit 2, no gate checkout, no gate in result.json" \
  eval 'rc_is 2 && one_signal FAILED && err_has "not gating it" && [ ! -e "$AD/home/.conductor/gate/k1.1" ] && [ "$(tj get "$AD/home/.conductor/out/k1/result.json" gate)" = null ]'
cr STUB_GH_PR_HEAD="$PRH" -- "$CXRUN" --finish k1
check "[A30] --finish k1 in a fork checkout: pull/42/head fetched from the task's repository (upstream = github.com/o/r, not the fork's origin) and confirmed as the PR head, into a gate checkout, setup and the routes commands green there; CX_RESULT ok with gate green and the PR head as commit; the checkout removed" \
  eval 'rc_is 0 && line_is CX_RESULT gate green && [ "$(tj line "$E" CX_RESULT commit)" = "$PRH" ] && line_is CX_RESULT diffstat "+1 -0, 1 file" && [ ! -e "$AD/home/.conductor/gate/k1.1" ] && grep -q "k.txt" "$AD/home/.conductor/out/k1/changed.txt" && ! grep -q "fork.txt" "$AD/home/.conductor/out/k1/changed.txt"'
A30_SCHEMA="$(tj schema "$AD/home/.conductor/out/k1/result.json" "$E" "$L" 2>&1)"
check "[A30] ... the cloud lane's final result is a whole section 15.4 result (lane copilot-cloud, pool copilot-credits, the cloud task and PR kept), its CX_RESULT and ledger line agree with it, and the ledger holds both of k1's lines (dispatch and gate)${A30_SCHEMA:+: $A30_SCHEMA}" \
  eval '[ -z "$A30_SCHEMA" ] && line_is CX_RESULT lane copilot-cloud && line_is CX_RESULT pool copilot-credits && line_is CX_RESULT cloud.pr 42 && line_is CX_RESULT cloud.task 0aa1b2c3-0000-4000-8000-000000000042 && [ "$(grep -c "\"id\": \"k1\"" "$L")" = 2 ]'
sed 's/"id": "k1", "commands": \["true"\]/"id": "k2", "commands": ["false"]/' "$AD/k1.md" > "$AD/k2.md"
cr -- "$CXRUN" --finish k1
check "[X]   --finish of a gated cloud task without --pr is refused (exit 1, no CX_SIGNAL) and books nothing: the ledger still holds 2 lines for k1" \
  eval 'rc_is 1 && no_signal && err_has "already gated" && [ "$(grep -c "\"id\": \"k1\"" "$L")" = 2 ]'
cr STUB_GH_PR_HEAD="$PRH" -- "$CXRUN" --finish k1 --pr 42
check "[X]   ... a re-gate with --pr 42 runs the gate again (exit 0) but books the run only once (still 2 ledger lines for k1)" \
  eval 'rc_is 0 && line_is CX_RESULT gate green && err_has "not booked again" && [ "$(grep -c "\"id\": \"k1\"" "$L")" = 2 ]'
cr STUB_GH_AGENT_TASK=ok -- "$CXRUN" --exec copilot-cloud --gh-repo github.com/o/r --task-file "$AD/k2.md"
cr STUB_GH_PR_HEAD="$PRH" -- "$CXRUN" --finish k2 --pr 42
check "[A30] ... a red gate (a routes command fails on the PR head) -> 20 GATE_FAILED, the checkout kept for inspection" \
  eval 'rc_is 20 && line_is CX_RESULT status gate_failed && one_signal GATE_FAILED && [ -d "$AD/home/.conductor/gate/k2.1" ]'

# --- A18: cx-init --user-grants
local UH="$AD/ug"
mkdir -p "$UH/.grok" "$UH/.gemini/antigravity-cli"
printf '{"theme": "x", "permissions": {"allow": ["command(ls)"], "deny": ["write_file(/)"]}}\n' > "$UH/.gemini/antigravity-cli/settings.json"
printf '[cli]\ntheme = "dark"\n' > "$UH/.grok/config.toml"
printf '[profiles.other]\nextends = "read-only"\n' > "$UH/.grok/sandbox.toml"
cp -a "$UH" "$AD/ug.orig"
cr HOME="$UH" -- "$INIT" --user-grants --dry-run
check "[A18] --user-grants --dry-run: three updates listed, nothing written" \
  eval 'rc_is 0 && [ "$(grep -c "^update " "$O")" = 3 ] && diff -r "$UH" "$AD/ug.orig" >/dev/null'
cr HOME="$UH" -- "$INIT" --user-grants
check "[A18] --user-grants: agy settings keep their keys and gain write_file(<worktree_root>) and command(true); the cx-workspace profile is added to sandbox.toml (the other kept); [cli] auto_update = false under the existing [cli]; a .cx-bak of each changed file; CX_INIT" \
  eval 'rc_is 0 && [ "$(tj get "$UH/.gemini/antigravity-cli/settings.json" theme)" = x ] && [ "$(tj get "$UH/.gemini/antigravity-cli/settings.json" permissions.allow)" = "[\"command(ls)\", \"write_file($UH/.cx-wt)\", \"command(true)\"]" ] && [ "$(tj get "$UH/.gemini/antigravity-cli/settings.json" permissions.deny.0)" = "write_file(/)" ] && "$REAL_PY" -I "$CXLIB" toml-table "$UH/.grok/sandbox.toml" cx-workspace && grep -q "^\[profiles.other\]" "$UH/.grok/sandbox.toml" && [ "$("$REAL_PY" -I "$CXLIB" toml-get "$UH/.grok/config.toml" cli auto_update)" = false ] && grep -q "theme = \"dark\"" "$UH/.grok/config.toml" && cmp -s "$UH/.grok/config.toml.cx-bak" "$AD/ug.orig/.grok/config.toml" && cmp -s "$UH/.gemini/antigravity-cli/settings.json.cx-bak" "$AD/ug.orig/.gemini/antigravity-cli/settings.json" && line_is CX_INIT detected.user_grants true'
A18_TOML="$("$REAL_PY" -I - "$UH/.grok/sandbox.toml" "$UH/.grok/config.toml" "$ROOT/templates/grok-sandbox.toml" <<'PY'
import re, sys
sb, cfg, tpl = (open(p, encoding="utf-8").read() for p in sys.argv[1:4])
try:
    import tomllib
except ImportError:  # Python < 3.11: text checks only
    ok = '[profiles.cx-workspace]' in sb and 'extends = "workspace"' in sb and '[profiles.other]' in sb
    print("" if ok else "the profile text is not there")
    raise SystemExit(0)
bad = []
try:
    s, c = tomllib.loads(sb), tomllib.loads(cfg)
except Exception as e:
    print("not valid TOML: %s" % e)
    raise SystemExit(0)
p = s.get("profiles", {}).get("cx-workspace", {})
want = tomllib.loads(tpl.replace("{{name}}", "cx-workspace"))["profiles"]["cx-workspace"]
if p != want:
    bad.append("profile %r != template %r" % (p, want))
if p.get("extends") != "workspace" or sorted(p.get("deny", [])) != sorted(["**/.env", "**/.env.*", "**/*.pem", "**/*.key", "**/id_rsa*"]):
    bad.append("profile %r" % p)
if s.get("profiles", {}).get("other") != {"extends": "read-only"}:
    bad.append("the other profile changed")
if c.get("cli") != {"theme": "dark", "auto_update": False}:
    bad.append("config [cli] %r" % c.get("cli"))
print("; ".join(bad))
PY
)"
check "[A18] ... both merged TOML files parse (tomllib, as grok reads them): the cx-workspace profile equals templates/grok-sandbox.toml (extends workspace; denies **/.env, **/.env.*, **/*.pem, **/*.key, **/id_rsa*), the other profile is untouched, [cli] holds theme and auto_update = false; sandbox.toml.cx-bak is the file as it was${A18_TOML:+: $A18_TOML}" \
  eval '[ -z "$A18_TOML" ] && cmp -s "$UH/.grok/sandbox.toml.cx-bak" "$AD/ug.orig/.grok/sandbox.toml"'
cp -a "$UH" "$AD/ug.once"
cr HOME="$UH" -- "$INIT" --user-grants
check "[A18] ... a second run is idempotent: three 'same' lines, no file changed" \
  eval 'rc_is 0 && [ "$(grep -c "^same " "$O")" = 3 ] && diff -r "$UH" "$AD/ug.once" >/dev/null'
printf '{"permissions": {"allow": "not a list"}}\n' > "$UH/.gemini/antigravity-cli/settings.json"
rm -f "$UH/.grok/config.toml"
cr HOME="$UH" -- "$INIT" --user-grants
check "[A18] ... a file it cannot merge -> 5 EXISTS (CONFLICT line), and nothing at all is written" \
  eval 'rc_is 5 && one_signal EXISTS && out_has "CONFLICT $UH/.gemini/antigravity-cli/settings.json" && [ ! -e "$UH/.grok/config.toml" ]'

# --- A16: forwarded from the simulated Git Bash (the WSL side is a clone of the template home)
local RW="$WIN/c/proj/runrepo" HP WHP DHP
mkdir -p "$RW/.cx"; git -C "$RW" init -q; printf 'hi\n' > "$RW/README.md"
printf '{"version": 1, "setup": "true", "commands": {"test": "true"}}\n' > "$RW/.cx/routes.json"; commit_all "$RW"
wsl_clone rf STUB_GROK_RUN=ok > /dev/null
sed -i "s#^STUB_LOG=.*#STUB_LOG=$TMP/crf-rf.log#" "$WH/rf/.stub.env"
GB_CWD="$RW" GB_HOME=rf gb rf-run -- "$CXRUN" --exec grok --id w1 'Add a file'
HP="$(tj line "$E" CX_RESULT host_path 2>/dev/null)"; WHP="$(tj line "$E" CX_RESULT worktree.host_path 2>/dev/null)"; DHP="$(tj line "$E" CX_RESULT digest.host_path 2>/dev/null)"
check "[A16] forwarded cx-run (Git Bash -> WSL, cwd C:\\proj\\runrepo): exit 0, caller gitbash; the CX_RESULT host_path, worktree.host_path and digest.host_path are Windows paths (\\\\wsl.localhost\\...)" \
  eval 'rc_is 0 && line_is CX_RESULT status ok && line_is CX_RESULT caller gitbash && is_unc "$HP" && is_unc "$WHP" && is_unc "$DHP" && [ "${HP##*\\}" = result.json ] && [ "${DHP##*\\}" = answer.txt ] && [ -f "$WH/rf/.cx-wt/runrepo-w1/cx-grok.txt" ]'
wsl_clone rb STUB_GROK_RUN=sleep STUB_GROK_SLEEP=8 > /dev/null
sed -i "s#^STUB_LOG=.*#STUB_LOG=$TMP/crf-rb.log#" "$WH/rb/.stub.env"
GB_CWD="$RW" GB_HOME=rb gb rb-start -- "$CXJOB" start --exec grok --id w2 'x'
J="$(sed -n 's/^JOB_ID //p' "$O")"
lc="no-id"
if [ -n "$J" ]; then
  lc="no-pid"
  if wait_file "$WH/rb/.conductor/jobs/$J/pid"; then
    sleep 0.2
    lc="ended"
    if [ ! -e "$WH/rb/.conductor/jobs/$J/rc" ]; then
      lc="dead:$(cat "$WH/rb/.conductor/jobs/$J/pid" 2>&1)"
      kill -0 "$(cat "$WH/rb/.conductor/jobs/$J/pid")" 2>/dev/null && lc=alive
    fi
  fi
fi
check "[A16] forwarded cx-job start: JOB_ID at once and the note to wait with one background call; the forwarder has exited while the job's runner lives on ($lc)" \
  eval 'rc_is 0 && [ -n "$J" ] && err_has "cx-job wait $J" && [ "$lc" = alive ]'
GB_CWD="$RW" GB_HOME=rb gb rb-wait -- "$CXJOB" wait "$J"
check "[A16] ... a forwarded cx-job wait collects the detached job: exit 0, CX_RESULT ok" \
  eval 'rc_is 0 && line_is CX_RESULT status ok && line_is CX_RESULT id w2'
# A Git Bash /tmp path has no WSL form: a forwarded --background run is refused before any job
# starts (the --dry-run preflight's 42 is relayed), never a JOB_ID whose job then ends 42.
printf '<!-- cx-task {"id": "w3", "commands": ["true"]} -->\n# Task w3\n' > "$RW/w3.md"
GB_CWD="$RW" GB_HOME=rb gb rb-unmap -- "$CXRUN" --background --exec grok --task-file /tmp/cx-t1.md --id w3
check "[A16] forwarded cx-run --background --task-file /tmp/cx-t1.md (a Git Bash path with no WSL form): exit 42 PATH_UNMAPPABLE with one CX_SIGNAL, no JOB_ID, no job started" \
  eval 'rc_is 42 && one_signal PATH_UNMAPPABLE && ! out_has JOB_ID && err_has "nothing started" && [ "$(ls "$WH/rb/.conductor/jobs" | wc -l)" = 1 ]'
local RX_BAD="" n
for n in rf-run rb-start rb-wait rb-unmap; do grep -q 'command not found' "$WH/$n.err" && RX_BAD="$RX_BAD $n(command not found)"; done
check "[P42] the forwarded cx-run and cx-job calls of this section (rf-run, rb-start, rb-wait, rb-unmap) ran their Git Bash side on the mini bin: no python3 call (its own trap file), no missing tool${RX_BAD:+:$RX_BAD}" \
  eval '[ ! -s "$TMP/pytrap-runx.log" ] && [ -z "$RX_BAD" ]'
check "[P30] forwarded cx-run: no stub logged BILLABLE" eval '! grep -qs "^BILLABLE" "$TMP/crf-rf.log" "$TMP/crf-rb.log"'

check "[P30] cx-run: no stub logged BILLABLE (every executor run carried a scenario knob)" eval '! grep -q "^BILLABLE" "$ADL"'
}
bg_section runx sec_runx

# ------------------------------------------------------------------ A25 through cx-run (section 15.8)
# A background section: twelve concurrent cx-run --background calls in one WSL home, six from a
# WSL terminal and six forwarded from the simulated Git Bash (one set of $CX_HOME/locks), against
# sleeping agy and ghcp-delegate stubs that log start/end events (STUB_EVENTS): cap_agy=2,
# cap_copilot=3. The stubs hold their runs at a gate (STUB_GATE) until every slot is busy and
# the other jobs are queued, so the caps are reached and the queue is seen whatever the load.
# Then the overflow: every agy slot held, CX_SLOT_WAIT_SECS=2.
sec_a25() {
section "Phase 2 A25 through cx-run: 12 concurrent cx-run --background (6 direct, 6 forwarded), shared caps, serialized agy launches, queued then running, overflow 28"
local H RW i lane dir n deadline nrc j st A25_BAD="" A25_Q="" A25_ST="" ma mc ml t0 h1 h2 OVJ
local -a PIDS=() A25_ENV=(CLAUDE_PLUGIN_OPTION_CAP_AGY=2 CLAUDE_PLUGIN_OPTION_CAP_COPILOT=3 CX_SLOT_WAIT_SECS=120)
gb_private_mini a25
RW="$WIN/c/proj/a25repo"
mkdir -p "$RW/.cx"; git -C "$RW" init -q; printf 'hi\n' > "$RW/README.md"
printf '{"version": 1, "setup": "true", "commands": {"test": "true"}}\n' > "$RW/.cx/routes.json"; commit_all "$RW"
H="$(wsl_clone a25 STUB_AGY_RUN=sleep STUB_AGY_SLEEP=2 STUB_GHCP_RUN=sleep STUB_GHCP_SLEEP=2 "STUB_EVENTS=$WH/a25.events" "STUB_GATE=$WH/a25.gate")"
sed -i "s#^STUB_LOG=.*#STUB_LOG=$TMP/a25.log#" "$H/.stub.env"
: > "$WH/a25.events"
# The template record's ghcp-delegate is the fake (billable) ghcp install: the wrapper stub instead.
"$REAL_PY" -I - "$H/.conductor/hosts/wsl-Ubuntu.json" "$STUBS" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
r["bin"]["ghcp_delegate"] = sys.argv[2] + "/ghcp-delegate"
open(sys.argv[1], "w").write(json.dumps(r))
PY
# a25d NAME [VAR=VALUE...] -- CMD...: a call from a WSL terminal of that home, cwd the repo.
a25d() {
  local n="$1"
  shift
  local -a ev=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do ev+=("$1"); shift; done
  shift
  (cd "$RW" && wsl_direct "$H" env STUB_LOG="$TMP/a25.log" ${ev[@]+"${ev[@]}"} "$@" > "$WH/$n.out" 2> "$WH/$n.err" < /dev/null; printf '%s\n' "$?" > "$WH/$n.rc")
}
for i in 1 2 3; do
  for lane in agy copilot; do
    a25d "a25-d-$lane$i" "${A25_ENV[@]}" -- "$CXRUN" --background --exec "$lane" --id "d-$lane$i" 'Add a file' &
    PIDS+=("$!")
    ( GB_CWD="$RW" GB_HOME=a25 gb "a25-f-$lane$i" "${A25_ENV[@]}" -- "$CXRUN" --background --exec "$lane" --id "f-$lane$i" 'Add a file' ) &
    PIDS+=("$!")
  done
done
# The gate stays shut until 2 agy and 3 Copilot runs hold their slots and 4 agy and 3 Copilot
# jobs wait in the queue (their $CX_JOB_DIR/queued names the pool); cx-job status of a queued
# job then says queued. Then the gate opens and the registry is watched until twelve rc files.
local qa=0 qc=0 sa=0 sc=0 qj=""
deadline=$((SECONDS + 120))
: > "$WH/a25.queued"
while [ "$SECONDS" -lt "$deadline" ]; do
  qa=0 qc=0 qj=""
  for dir in "$H"/.conductor/jobs/*/; do
    [ -e "$dir/queued" ] || continue
    case "$(cat "$dir/queued" 2>/dev/null)" in agy) qa=$((qa + 1)) ;; copilot) qc=$((qc + 1)) ;; *) continue ;; esac
    qj="$(basename -- "$dir")"
    printf '%s %s\n' "$qj" "$(cat "$dir/queued" 2>/dev/null)" >> "$WH/a25.queued"
  done
  sa="$(grep -c '^start agy-run ' "$WH/a25.events")" sc="$(grep -c '^start ghcp-delegate ' "$WH/a25.events")"
  [ "$qa" -ge 4 ] && [ "$qc" -ge 3 ] && [ "$sa" -ge 2 ] && [ "$sc" -ge 3 ] && break
  sleep 0.2
done
local A25_GATE="queued agy $qa, copilot $qc; running agy $sa, copilot $sc"
[ -z "$qj" ] || A25_ST="$( (cd "$RW" && wsl_direct "$H" "$CXJOB" status "$qj") 2>/dev/null)"
: > "$WH/a25.gate"
deadline=$((SECONDS + 120))
while [ "$SECONDS" -lt "$deadline" ]; do
  nrc="$(find "$H"/.conductor/jobs -mindepth 2 -maxdepth 2 -name rc 2>/dev/null | wc -l)"
  [ "$nrc" -ge 12 ] && break
  sleep 0.2
done
wait "${PIDS[@]}"
for i in 1 2 3; do
  for lane in agy copilot; do
    for n in "a25-d-$lane$i" "a25-f-$lane$i"; do
      { [ "$(cat "$WH/$n.rc" 2>/dev/null)" = 0 ] && grep -q '^JOB_ID ' "$WH/$n.out"; } || A25_BAD="$A25_BAD [$n start rc $(cat "$WH/$n.rc" 2>/dev/null)]"
    done
    grep -q "cx-job wait " "$WH/a25-f-$lane$i.err" || A25_BAD="$A25_BAD [a25-f-$lane$i: no wait note]"
  done
done
check "[A25] 12 concurrent cx-run --background (agy and copilot, 6 from a WSL terminal, 6 forwarded from Git Bash) each print JOB_ID at once (the forwarded ones with the one-background-wait note)${A25_BAD:+:$A25_BAD}" test -z "$A25_BAD"
A25_BAD=""
n=0
for dir in "$H"/.conductor/jobs/*/; do
  n=$((n + 1))
  j="$(basename -- "$dir")"
  [ "$(cat "$dir/rc" 2>/dev/null)" = 0 ] || A25_BAD="$A25_BAD [$j rc $(cat "$dir/rc" 2>/dev/null)]"
  [ "$(tj line "$dir/err" CX_RESULT status 2>/dev/null)" = ok ] || A25_BAD="$A25_BAD [$j: $(grep '^CX_SIGNAL' "$dir/err" | tail -n 1 | cut -c1-120)]"
done
[ "$n" = 12 ] || A25_BAD="$A25_BAD [$n jobs]"
ma="$(overlap "$WH/a25.events" agy-run)" mc="$(overlap "$WH/a25.events" ghcp-delegate)" ml="$(overlap "$WH/a25.events" agy-launch)"
[ "$(grep -c '^start agy-run ' "$WH/a25.events")" = 6 ] && [ "$(grep -c '^start ghcp-delegate ' "$WH/a25.events")" = 6 ] && [ "$(grep -c '^start agy-launch ' "$WH/a25.events")" = 6 ] \
  || A25_BAD="$A25_BAD [runs: $(grep -c '^start ' "$WH/a25.events") starts]"
[ "$ma" = 2 ] || A25_BAD="$A25_BAD [agy overlap $ma]"
[ "$mc" = 3 ] || A25_BAD="$A25_BAD [copilot overlap $mc]"
[ "$ml" = 1 ] || A25_BAD="$A25_BAD [agy launch overlap $ml]"
check "[A25] ... all 12 jobs end 0 with CX_RESULT ok; the shared caps hold across direct and forwarded runs and are reached (exactly $ma agy and $mc Copilot executors at most at once, caps 2 and 3) and no two agy launches (registration to init) ever overlap (got $ml)${A25_BAD:+:$A25_BAD}" test -z "$A25_BAD"
A25_BAD=""
{ [ "$qa" -ge 4 ] && [ "$qc" -ge 3 ] && [ "$sa" = 2 ] && [ "$sc" = 3 ]; } || A25_BAD="$A25_BAD [at the gate: $A25_GATE]"
while IFS= read -r j; do
  [ "$(cat "$H/.conductor/jobs/$j/rc" 2>/dev/null)" = 0 ] && [ ! -e "$H/.conductor/jobs/$j/queued" ] || A25_BAD="$A25_BAD [$j queued but not run]"
done < <(cut -d' ' -f1 "$WH/a25.queued" | sort -u)
[ "$A25_ST" = queued ] || A25_BAD="$A25_BAD [cx-job status said '$A25_ST']"
check "[A25] ... queued then running: with every slot busy, the other 4 agy and 3 Copilot jobs waited in the queue (\$CX_JOB_DIR/queued names the pool; cx-job status says queued), then ran and ended 0 with the marker gone ($A25_GATE)${A25_BAD:+:$A25_BAD}" test -z "$A25_BAD"
# Overflow: both agy slots held; CX_SLOT_WAIT_SECS=2, direct (foreground) and forwarded (a job).
mkdir -p "$H/.conductor/locks"
h1="$(hold "$H/.conductor/locks/agy.1" -x "$WH/a25.h1")"; h2="$(hold "$H/.conductor/locks/agy.2" -x "$WH/a25.h2")"
wait_file "$WH/a25.h1"; wait_file "$WH/a25.h2"
( GB_CWD="$RW" GB_HOME=a25 gb a25-ovf CLAUDE_PLUGIN_OPTION_CAP_AGY=2 CX_SLOT_WAIT_SECS=2 -- "$CXRUN" --background --exec agy --id ov-f 'Add a file' ) &
PIDS=("$!")
t0=$SECONDS
a25d a25-ovd CLAUDE_PLUGIN_OPTION_CAP_AGY=2 CX_SLOT_WAIT_SECS=2 -- "$CXRUN" --exec agy --id ov-d 'Add a file'
local OV_T=$((SECONDS - t0))
wait "${PIDS[@]}"
OVJ="$(sed -n 's/^JOB_ID //p' "$WH/a25-ovf.out")"
a25d a25-ovw -- "$CXJOB" wait "$OVJ"
kill "$h1" "$h2" 2>/dev/null; wait "$h1" "$h2" 2>/dev/null
s_use a25-ovd
check "[A25] overflow: with both agy slots held, a direct cx-run --exec agy waits CX_SLOT_WAIT_SECS=2 and ends 28 (${OV_T} s): CX_RESULT no_capacity, exactly one CX_SIGNAL NO_CAPACITY, last; no agy launch" \
  eval 'rc_is 28 && line_is CX_RESULT status no_capacity && one_signal NO_CAPACITY && [ "$OV_T" -ge 2 ] && [ "$(grep -c "^start agy-launch " "$WH/a25.events")" = 6 ]'
s_use a25-ovw
check "[A25] ... and a forwarded cx-run --background into the same full pool: the job ends 28 too (cx-job wait: exit 28, CX_RESULT no_capacity, one CX_SIGNAL NO_CAPACITY, last)" \
  eval '[ -n "$OVJ" ] && rc_is 28 && line_is CX_RESULT status no_capacity && one_signal NO_CAPACITY'
check "[P30] A25 through cx-run: no stub logged BILLABLE" eval '[ -s "$TMP/a25.log" ] && ! grep -q "^BILLABLE" "$TMP/a25.log"'
local A25_PY=""
for n in "$WH"/a25-f-*.err "$WH"/a25-ovf.err; do [ -f "$n" ] && grep -q 'command not found' "$n" && A25_PY="$A25_PY ${n##*/}"; done
check "[P42] the 6 forwarded cx-run --background calls and the forwarded overflow ran their Git Bash side on the mini bin: no python3 call (this section's own trap file), no missing tool${A25_PY:+:$A25_PY}" \
  eval '[ ! -s "$TMP/pytrap-a25.log" ] && [ -z "$A25_PY" ] && [ "$(ls "$WH"/a25-f-*.err | wc -l)" = 6 ]'
}
bg_section a25 sec_a25

# The rest of the Git Bash forwarding cases run as a background section too: the serial sections
# below share nothing with them (their WSL homes are clones, their logs are joined before the
# final audit).
sec_gbfwd() {
section "Git Bash forwarding (continued): argv, cwd forms, stdin, the pty, moved runtimes, cloud refusals"
REPO_W="$WIN/c/proj/repo"
mkdir -p "$REPO_W"; git -C "$REPO_W" init -q; printf '{"name": "r", "scripts": {"test": "node t.js"}}\n' > "$REPO_W/package.json"
printf '* text=auto eol=lf\n' > "$REPO_W/.gitattributes"; commit_all "$REPO_W"
WEIRD=$'-x sp ace "dq" \'sq\' $HOME back\\slash\nnew line é—✓ *?[] ;|&'
# --- P17: an empty WSL home (no runtime copy): three calls in a row, in the background
wsl_clone rt-none --no-runtime > /dev/null
pool_go
( GB_HOME=rt-none gb p17a CX_NO_AUTO_INSTALL=1 -- "$INIT" --dry-run
  GB_HOME=rt-none GB_CWD="$REPO_W" gb p17b -- "$INIT" --dry-run --json
  cp "$WH/rt-none/.conductor/runtime/$CXV/RUNTIME_STAMP" "$WH/p17.stamp" 2>/dev/null
  GB_HOME=rt-none GB_CWD="$REPO_W" gb p17c -- "$INIT" --dry-run --json ) &
DOC_PIDS+=("$!")
# --- P13 argv fidelity, P14 env allowlist, P15 cwd, P16 exit codes (parallel batch)
wsl_clone argv > /dev/null
wsl_clone argv-wsl > /dev/null
wsl_clone envlist > /dev/null
wsl_clone cwd-unc > /dev/null
wsl_clone cwd-share > /dev/null
wsl_clone share-wsl > /dev/null
wsl_clone share-doctor > /dev/null
wsl_clone short > /dev/null
wsl_clone exit37 > /dev/null
wsl_clone nodistro STUB_WSL_FAIL=nodistro > /dev/null
wsl_clone crash > /dev/null
wsl_clone auto > /dev/null
wsl_clone badistro > /dev/null
wsl_clone stdin > /dev/null
wsl_clone leak > /dev/null
GB_CWD="$REPO_W" gb_bg argv CX_DEBUG=1 -- "$INIT" --dry-run --json --test "$WEIRD" --lint ''
GB_CWD="$REPO_W" gb_bg argv-wsl -- "$CXWSL" bash -c 'printf "%s\0" "$@"' _ "$WEIRD" ''
gb_bg envlist CX_DEBUG=1 CLAUDE_PLUGIN_OPTION_POLICY=off GH_TOKEN=x COPILOT_MODEL=y FOO=z GHCP_COPILOT_BIN=/x CX_FORWARDED=1 CX_HOME=/elsewhere -- bash "$ROOT/scripts/host/forward-wsl.sh" cx-gate a
GB_CWD="$TMP/unc$REPO_W" gb_bg cwd-unc -- "$INIT" --dry-run --json
GB_CWD="$TMP/share/x" gb_bg cwd-share -- "$INIT" --dry-run
GB_CWD="$TMP/share/x" gb_bg share-wsl -- "$CXWSL" git --version
GB_CWD="$TMP/share/x" gb_bg share-doctor -- bash "$ROOT/scripts/host/forward-wsl.sh" cx-doctor --version
gb_bg short TMPDIR="$WIN/c/Users/JOHNSM~1/AppData/Local/Temp" STUB_CYGPATH_SHORT='JOHNSM~1=John Smith' -- bash "$ROOT/scripts/host/forward-wsl.sh" cx-gate x
gb_bg exit37 -- "$CXWSL" bash -c 'exit 37'
gb_bg nodistro STUB_WSL_FAIL=nodistro STUB_WSL_IGNORE_UTF8=1 -- "$INIT" --dry-run
gb_bg crash STUB_WSL_FAIL=crash -- bash "$ROOT/scripts/host/forward-wsl.sh" cx-gate x
gb_bg auto -- bash "$ROOT/scripts/host/forward-wsl.sh" cx-gate x
gb_bg badistro CLAUDE_PLUGIN_OPTION_WSL_DISTRO='bad name' -- "$INIT" --dry-run
printf 'x' > "$TMP/stdin-x"
GB_IN="$TMP/stdin-x" gb_bg stdin -- "$CXWSL" bash -c 'cat'
gb_bg leak CX_FORWARDED=1 -- "$CXWSL" git --version
# exit propagation of forwarded commands and the remaining failure modes (second batch)
wsl_clone init5 > /dev/null
wsl_clone gate3 > /dev/null
wsl_clone nowsl > /dev/null
wsl_clone mismatch > /dev/null
wsl_clone launch > /dev/null
wsl_clone record > /dev/null
wsl_clone fallback > /dev/null
wsl_clone moved > /dev/null
R5="$WIN/c/proj/repo5"
mkdir -p "$R5"; git -C "$R5" init -q; printf '* text=auto eol=lf\n' > "$R5/.gitattributes"
(cd "$R5" && "$INIT" > /dev/null 2>&1); sed -i 's/^- Never weaken.*/- edited/' "$R5/AGENTS.md"
GB_CWD="$R5" gb_bg init5 -- "$INIT"
gb_bg gate3 -- bash "$ROOT/scripts/host/forward-wsl.sh" cx-gate --exit 3
NOWSL="$TMP/gb-nowsl"; mkdir -p "$NOWSL"
for f in "$STUBS"/*; do [ "$(basename "$f")" = wsl.exe ] || ln -s "$f" "$NOWSL/"; done
gb_bg nowsl PATH="$NOWSL:$GB_MINI" -- "$INIT" --dry-run
sed -i "s/^CX_VERSION=${CXV//./\\.}\$/CX_VERSION=0.0.9/" "$WH/mismatch/.conductor/runtime/$CXV/scripts/lib/common.sh"
gb_bg mismatch -- "$INIT" --dry-run
gb_bg launch STUB_WSL_FAIL=launch -- "$INIT" --dry-run
gb_bg record STUB_WSL_EXTRA_ENV="DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR" DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus XDG_RUNTIME_DIR=/run/user/1000 -- bash "$ROOT/scripts/host/forward-wsl.sh" cx-gate x
rm -f -- "$WH/fallback/.conductor/hosts/wsl-Ubuntu.path"
gb_bg fallback -- bash "$ROOT/scripts/host/forward-wsl.sh" cx-gate x
mkdir -p "$TMP/plugins-moved"; cp -R "$TMP/plugins/ghcp" "$TMP/plugins-moved/ghcp"
sed -i "s|$TMP/plugins/ghcp\"|$TMP/plugins-moved/ghcp\"|" "$WH/moved/.claude/plugins/installed_plugins.json"
"$REAL_PY" -I - "$WH/moved/.conductor/hosts/wsl-Ubuntu.json" "$TMP" <<'PY'
import json, sys
p, tmp = sys.argv[1], sys.argv[2]
r = json.load(open(p))
for k in list(r["bin"]):
    if k.startswith("ghcp_"):
        r["bin"][k] = r["bin"][k].replace(tmp + "/plugins/ghcp/", tmp + "/plugins-gone/ghcp/")
open(p, "w").write(json.dumps(r))
PY
gb_bg moved -- "$CXWSL" ghcp-models --json
# --- forwarded doctor runs and the Windows checks (third batch)
wsl_clone gbdoc > /dev/null
wsl_clone gbdoc4 STUB_GROK_VERSION=1.0.73 > /dev/null
wsl_clone win-green > /dev/null
wsl_clone win-bad > /dev/null
wsl_clone win-keyring STUB_GHCP_MODELS=auth > /dev/null
wsl_clone win-timeout > /dev/null
wsl_clone win-crlf > /dev/null
mkdir -p "$WIN/c/Users/native/.claude/plugins"
write_installed "$WIN/c/Users/native/.claude" "C:/Users/native/.claude/plugins/cache/conductor"
cp "$FIX/settings/green.json" "$WIN/c/Users/native/.claude/settings.json"
GB_CWD="$REPO_W" gb_bg gbdoc -- "$DOCTOR"
gb_bg gbdoc4 -- "$DOCTOR" --host wsl --no-record
gb_bg win-green STUB_WSL_LIST_V_FILE="$FIX/wsl-l-v.utf16le" STUB_WSL_DISTROS='*Ubuntu:x:2,Debian:x:1,Legacy-1:x:2' USERPROFILE='C:\Users\native' HOME="$WIN/c/Users/native" -- "$DOCTOR" --windows
mkdir -p "$TMP/unc$REPO_W"
GB_CWD="$TMP/unc$REPO_W" gb_bg win-bad CLAUDE_PLUGIN_OPTION_WSL_DISTRO=Fedora STUB_GIT_DUBIOUS=1 STUB_GIT_DUBIOUS_PATH="//wsl.localhost/Ubuntu$REPO_W" -- "$DOCTOR" --windows
gb_bg win-keyring -- "$DOCTOR" --windows
FAKE_TO="$TMP/fake-timeout"; mkdir -p "$FAKE_TO"
printf '#!/bin/bash\necho "ERROR: Invalid syntax. Default option is not allowed more than '"'"'1'"'"' time(s)."\nexit 1\n' > "$FAKE_TO/timeout"; chmod 0755 "$FAKE_TO/timeout"
gb_bg win-timeout PATH="$FAKE_TO:$GB_PATH" -- "$DOCTOR" --windows
GBC="$TMP/gb crlf/plug in"
crlf_copy "$GBC" templates/repo-bundle/routes.json skills/conductor/SKILL.md bin/cx-wsl scripts/cx-init.sh
gb_bg win-crlf -- "$GBC/bin/cx-doctor" --windows
wsl_clone gbdoc-fail > /dev/null
wsl_clone gbdoc-json > /dev/null
wsl_clone gbdoc-lite > /dev/null
wsl_clone gb-install --no-runtime > /dev/null
gb_bg gbdoc-fail STUB_WSL_FAIL=nodistro -- "$DOCTOR"
GB_HOME=gbdoc-fail gb_bg gbdoc-fail-json STUB_WSL_FAIL=nodistro -- "$DOCTOR" --json
GB_HOME=gbdoc-fail gb_bg gbdoc-winjson -- "$DOCTOR" --windows --json
gb_bg gbdoc-json -- "$DOCTOR" --json --no-record
mkdir -p "$WIN/c/Users/lite/.claude"
printf '{"pluginConfigs": {"conductor@conductor-for-claude-code": {"options": {"wsl_distro": "\\u0055buntu", "cap_grok": "4"}}}}\n' > "$WIN/c/Users/lite/.claude/settings.json"
gb_bg gbdoc-lite USERPROFILE='C:\Users\lite' HOME="$WIN/c/Users/lite" -- "$DOCTOR" --no-record
gb_bg gb-install -- "$DOCTOR" --install-runtime
# session kinds on the Git Bash side (P49, P50) and W10/W11 (P51, P59)
for n in gb-bridge gb-bridge-exit gb-bridge-doc gb-w11m gb-cloud; do wsl_clone "$n" > /dev/null; done
GB_CWD="$REPO_W" gb_bg gb-bridge CLAUDE_CODE_ENVIRONMENT_KIND=bridge CLAUDE_CODE_SESSION_ATTENDED=0 CLAUDE_CODE_ENTRYPOINT=sdk-cli CX_DEBUG=1 -- "$INIT" --dry-run --json --test "$WEIRD" --lint ''
gb_bg gb-bridge-exit CLAUDE_CODE_ENVIRONMENT_KIND=bridge -- "$CXWSL" bash -c 'exit 37'
mkdir -p "$WIN/c/Users/w11/.claude" "$WIN/c/Program Files/ClaudeCode"
printf '\xef\xbb\xbf{\r\n  "ultracode": true,\r\n  "workflowKeywordTriggerEnabled": false,\r\n  "workflowSizeGuideline": "small",\r\n  "disableRemoteControl": true,\r\n  "env": {"DISABLE_GROWTHBOOK": "1", "ANTHROPIC_BASE_URL": "https://gw.example/"},\r\n  "x": {"disableWorkflows": true, "s": "} {"}\r\n}\r\n' > "$WIN/c/Users/w11/.claude/settings.json"
printf '{"disableWorkflows": true}\n' > "$WIN/c/Program Files/ClaudeCode/managed-settings.json"
GB_CWD="$REPO_W" gb_bg gb-bridge-doc CLAUDE_CODE_ENVIRONMENT_KIND=bridge CLAUDE_CODE_DESKTOP_APP_VERSION=1.5.0 NUMBER_OF_PROCESSORS=8 \
  CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 USERPROFILE='C:\Users\w11' HOME="$WIN/c/Users/w11" CLAUDE_CODE_SUBAGENT_EFFORT=low -- "$DOCTOR" --no-record
gb_bg gb-w11m USERPROFILE='C:\Users\w11' HOME="$WIN/c/Users/w11" ProgramFiles='C:\Program Files' CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS=5 -- "$DOCTOR" --windows
gb_bg gb-cloud CLAUDE_CODE_REMOTE=true -- "$INIT" --dry-run
GB_HOME=gb-cloud gb_bg gb-cloud-doc CLAUDE_CODE_REMOTE=true -- "$DOCTOR"
GB_HOME=gb-cloud gb_bg gb-cloud-wsl CLAUDE_CODE_REMOTE=On -- "$CXWSL" ghcp-models --json
doc_wait
gb_use gb-bridge
check "[P50] a bridge child on Git Bash: argv fidelity unchanged (detected.test = WEIRD); the env file still holds only CX_DEBUG (no CLAUDE_CODE_* crosses into WSL)" \
  eval 'rc_is 0 && [ "$(out_json detected.test)" = "$WEIRD" ] && [ "$(tj envnames "$(fwd_dir)/env")" = CX_DEBUG ]'
gb_use gb-bridge-exit
check "[P50] ... exit propagation unchanged: cx-wsl bash -c 'exit 37' -> 37, no CX_* line" eval 'rc_is 37 && ! grep -q "^CX_" "$E"'
gb_use gb-bridge-doc
check "[P50] Git Bash doctor in a bridge child: W10 reports bridge (the pool slots shared by every thread and session) and the desktop version; the WSL side prints no D30 and no D32; the header and CX_DOCTOR say session bridge" \
  eval 'rc_is 0 && d_info W10 "session bridge (entrypoint unset, desktop app 1.5.0)" && d_info W10 "the pool slots are shared by every thread and session on this computer" && d_none D30 && d_none D32 && out_has "caller gitbash, session bridge" && line_is CX_DOCTOR session bridge'
check "[P51] W10: a Remote Control blocker in the Windows environment is an info line; the desktop WSL-session note; W11 concurrency 6 from NUMBER_OF_PROCESSORS=8; D31 still runs on the WSL side" \
  eval 'd_info W10 "is off while: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC is set (environment)" && d_info W10 "run inside WSL, where plugins are not loaded" && d_info W11 "workflow concurrency 6 agents per workflow" && d_info D31 "Work locally prerequisites met here"'
check "[P59] W11 over a BOM+CRLF Windows settings file (lite reader): ultracode on, workflows available (a nested disableWorkflows is ignored), keyword off, guideline small, the effort override" \
  eval 'd_info W11 "ultracode on for new sessions ($WIN/c/Users/w11/.claude/settings.json)" && d_info W11 "workflows available on the Windows side" && d_info W11 "the ultracode keyword trigger is off" && d_info W11 "workflow size guideline small" && d_info W11 "CLAUDE_CODE_SUBAGENT_EFFORT=low overrides the effort"'
check "[P51] W10 over the same file: settings env DISABLE_GROWTHBOOK, a gateway ANTHROPIC_BASE_URL and disableRemoteControl are info lines; no ! or cross from W10/W11" \
  eval 'd_info W10 "DISABLE_GROWTHBOOK is set (env block of" && d_info W10 "ANTHROPIC_BASE_URL=https://gw.example (env block of" && d_info W10 "disableRemoteControl is true" && ! grep -Eq "^  [!$FAILG] .*\[W1[01]\]$" "$O"'
gb_use gb-w11m
check "[P59] W11: disableWorkflows in Program Files' managed settings wins -> workflows off (managed file), ultracode set but without effect; CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS=5 wins" \
  eval 'd_info W11 "workflows off (disableWorkflows in $WIN/c/Program Files/ClaudeCode/managed-settings.json)" && d_info W11 "but workflows are off, so it has no effect" && d_info W11 "workflow concurrency 5 agents per workflow (CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS)"'
P49_BAD=""
for n in gb-cloud gb-cloud-doc gb-cloud-wsl; do
  gb_use "$n"
  { [ "$RC" != 43 ] && ! grep -q '"status": "HOST_UNSUPPORTED"' "$E" && ! err_has "cloud session (" && grep -q "^wsl.exe" "$GLOG" 2>/dev/null; } || P49_BAD="$P49_BAD [$n]"
done
gb_use gb-cloud-doc
{ out_has "caller gitbash, session local" && d_none D30; } || P49_BAD="$P49_BAD [doctor report]"
gb_use gb-cloud-wsl
rc_is 0 || P49_BAD="$P49_BAD [cx-wsl rc $RC]"
check "[P49] a Git Bash host is never a cloud session: with CLAUDE_CODE_REMOTE=true (no kind) cx-init, cx-doctor and cx-wsl forward into WSL as usual (no exit 43); the doctor says session local${P49_BAD:+:$P49_BAD}" test -z "$P49_BAD"
gb_use p17a
check "[P17] no runtime copy and CX_NO_AUTO_INSTALL=1 -> 41 RUNTIME_MISSING, one CX_SIGNAL (from the forwarder)" \
  eval 'rc_is 41 && one_signal RUNTIME_MISSING && err_has "forward-wsl: no conductor runtime $CXV"'
gb_use p17b
check "[P17] an empty WSL home: the first call installs (installed true, stamp, current link) and succeeds" \
  eval 'rc_is 0 && line_is CX_FORWARD installed true && [ -f "$WH/p17.stamp" ] && [ "$(readlink "$WH/rt-none/.conductor/runtime/current")" = $CXV ] && outj_is detected.test "npm test" && line_is CX_RUNTIME changed true && no_signal'
check "[X]   the bootstrap install crossed only CX_STAGE_WIN (WSLENV) and ran bash -s, not a path on the command line" \
  eval 'grep -q "^wsl.exe	.*crossed=CX_STAGE_WIN	.*argv: --cd \\\\~ --exec /bin/bash --noprofile --norc -s$" "$GLOG"'
gb_use p17c
check "[P17] the second call does not reinstall (installed false, same stamp)" \
  eval 'rc_is 0 && line_is CX_FORWARD installed false && cmp -s "$WH/rt-none/.conductor/runtime/$CXV/RUNTIME_STAMP" "$WH/p17.stamp" && ! err_has CX_RUNTIME'
gb_use argv
ARGV_F="$(fwd_dir)/argv"
check "[P13] argv fidelity: detected.test equals WEIRD byte for byte (spaces, quotes, \$HOME, backslash, newline, non-ASCII, leading -)" \
  eval 'rc_is 0 && [ "$(out_json detected.test)" = "$WEIRD" ]'
check "[P13] --lint '' arrives as an empty argument (-> null)" outj_is detected.lint null
check "[P13] CX_DEBUG=1 keeps the argv file: it equals printf '%s\\0' of the arguments" \
  eval '[ -f "$ARGV_F" ] && cmp -s "$ARGV_F" <(printf "%s\0" --dry-run --json --test "$WEIRD" --lint "")'
check "[P13] CX_DEBUG=1 prints the wsl.exe argv; it carries only fixed text (no user argument)" \
  eval 'err_has "forward-wsl: wsl.exe argv: wsl.exe --cd" && grep "^wsl.exe	" "$GLOG" | grep -v -- "--list\|-l " | grep -q "argv: --cd \\\\~ --exec /bin/bash --noprofile --norc .conductor/runtime/$CXV/scripts/host/wsl-entry.sh$" && ! grep "^wsl.exe	" "$GLOG" | grep -q "sp ace"'
check "[P13] every Windows path in meta came from cygpath -w -l" \
  eval '! grep "^cygpath	" "$GLOG" | grep "argv: -w" | grep -qv "argv: -w -l " && grep -q "^cygpath	.*argv: -w -l " "$GLOG" && grep -qx "cwd_win=C:\\\\proj\\\\repo" "$(fwd_dir)/meta"'
check "[X]   meta: v=1, cmd, version, caller=gitbash, distro=auto, installed=0" \
  eval 'M="$(fwd_dir)/meta"; grep -qx v=1 "$M" && grep -qx cmd=cx-init "$M" && grep -qx version=$CXV "$M" && grep -qx caller=gitbash "$M" && grep -qx distro=auto "$M" && grep -qx installed=0 "$M" && grep -qx "win_settings=" "$M"'
gb_use argv-wsl
check "[P13] cx-wsl bash -c 'printf \"%s\\0\" \"\$@\"' _ \"\$WEIRD\" '' prints exactly those two arguments" \
  eval 'rc_is 0 && cmp -s "$O" <(printf "%s\0" "$WEIRD" "")'
check "[X]   forwarded cx-wsl adds no CX_* line to the tool's stderr (no CX_FORWARD either)" eval 'err_empty'
gb_use envlist
ENVF="$(fwd_dir)/env"
check "[P14] env allowlist: the kept env file holds only CX_DEBUG and CLAUDE_PLUGIN_OPTION_POLICY" \
  eval '[ "$(tj envnames "$ENVF")" = "CLAUDE_PLUGIN_OPTION_POLICY CX_DEBUG" ]'
check "[P14] the wsl.exe stub logged only CX_FWD_WIN crossing via WSLENV" \
  eval 'grep "^wsl.exe	" "$GLOG" | grep -q "wslenv=CX_FWD_WIN	crossed=CX_FWD_WIN	" && ! grep "^wsl.exe	" "$GLOG" | grep -v "wslenv=CX_FWD_WIN	crossed=CX_FWD_WIN	" | grep -q crossed='
check "[X]   the target saw CX_DEBUG and the option, not GH_TOKEN, COPILOT_MODEL, FOO, GHCP_COPILOT_BIN or CX_HOME; CX_FORWARDED=1 set by wsl-entry" \
  eval 'TE="$WH/envlist/target.env"; grep -qx CX_DEBUG=1 "$TE" && grep -qx CLAUDE_PLUGIN_OPTION_POLICY=off "$TE" && ! grep -Eq "^(GH_TOKEN|COPILOT_MODEL|FOO|GHCP_COPILOT_BIN|CX_HOME|CX_FWD_WIN|WSLENV)=" "$TE" && grep -qx CX_FORWARDED=1 "$TE" && grep -qx CX_CALLER=gitbash "$TE"'
gb_use argv
CWD_DRIVE="$(tj line "$E" CX_FORWARD cwd 2>/dev/null)"
gb_use cwd-unc
check "[P15] a drive cwd and a \\\\wsl.localhost\\Ubuntu\\... cwd reach the same repo on the WSL side (CX_FORWARD.cwd)" \
  eval 'rc_is 0 && [ "$CWD_DRIVE" = "$REPO_W" ] && line_is CX_FORWARD cwd "$REPO_W" && line_is CX_FORWARD cwd_win "\\\\wsl.localhost\\Ubuntu${REPO_W//\//\\}"'
gb_use cwd-share
check "[P15] a \\\\server\\share cwd: cx-init exits 42 with one CX_SIGNAL (from wsl-entry.sh)" \
  eval 'rc_is 42 && one_signal PATH_UNMAPPABLE && line_is CX_SIGNAL cmd cx-init && err_has "wsl-entry: the current directory"'
gb_use share-wsl
check "[P15] ... cx-wsl exits 42 too (never runs a tool in \$HOME by accident)" eval 'rc_is 42 && one_signal PATH_UNMAPPABLE && ! grep -q "git version" "$O"'
gb_use share-doctor
check "[P15] ... cx-doctor runs from \$HOME with cwd null" eval 'rc_is 0 && line_is CX_FORWARD cwd null && [ "$(cat "$O")" = "cx-doctor $CXV" ]'
gb_use short
check "[P15] a TMPDIR with a short-name component (JOHNSM~1) still maps because the forwarder passed -l" \
  eval 'rc_is 0 && grep -q "^cygpath	.*argv: -w -l .*JOHNSM~1/AppData/Local/Temp/cx-fwd" "$GLOG" && [ -f "$WH/short/target.pwd" ] && [ "$(env STUB_WIN_ROOT="$WIN" STUB_CYGPATH_SHORT="JOHNSM~1=John Smith" "$STUBS/cygpath" -w -l "$WIN/c/Users/JOHNSM~1/x")" = "C:\\Users\\John Smith\\x" ] && [ "$(env STUB_WIN_ROOT="$WIN" STUB_CYGPATH_SHORT="JOHNSM~1=John Smith" "$STUBS/cygpath" -w "$WIN/c/Users/JOHNSM~1/x")" = "C:\\Users\\JOHNSM~1\\x" ]'
gb_use exit37
check "[P16] cx-wsl bash -c 'exit 37' -> 37 with no CX_* line" eval 'rc_is 37 && ! grep -q "^CX_" "$E"'
gb_use nodistro
check "[P16] STUB_WSL_FAIL=nodistro with UTF-16LE messages -> 40, the note shows the decoded English message, one CX_SIGNAL" \
  eval 'rc_is 40 && one_signal FORWARD_FAILED && err_has "forward-wsl: wsl.exe failed (rc 255): There is no distribution with the supplied name."'
gb_use crash
check "[P16] STUB_WSL_FAIL=crash (after started) -> 40 FORWARD_FAILED, one CX_SIGNAL" \
  eval 'rc_is 40 && one_signal FORWARD_FAILED && err_has "WSL stopped while the command ran"'
gb_use auto
check "[P16] wsl_distro=auto: the wsl.exe argv has no -d; CX_FORWARD.distro is the stub's default" \
  eval 'rc_is 0 && line_is CX_FORWARD distro Ubuntu && grep "^wsl.exe	" "$GLOG" | grep -vq -- "argv: -d" && ! grep "^wsl.exe	" "$GLOG" | grep -q -- "argv: -d"'
gb_use badistro
check "[P16] an invalid wsl_distro -> 40 without invoking wsl.exe" eval 'rc_is 40 && one_signal FORWARD_FAILED && ! grep -q "^wsl.exe" "$GLOG" && err_has "invalid option wsl_distro"'
gb_use stdin
check "[P16] stdin reaches the child: printf x | cx-wsl bash -c cat prints x" eval 'rc_is 0 && [ "$(cat "$O")" = x ]'
gb_use leak
check "[P42] CX_FORWARDED=1 leaked into the Git Bash environment still forwards (wsl.exe invoked)" \
  eval 'rc_is 0 && grep -q "^wsl.exe	" "$GLOG" && grep -q "^git version" "$O"'
gb_use init5
check "[P16] forwarded cx-init exit 5 crosses unchanged (one CX_SIGNAL EXISTS, from the WSL side)" eval 'rc_is 5 && one_signal EXISTS && out_has "CONFLICT AGENTS.md"'
gb_use gate3
check "[X]   a forwarded command's own exit code (3) crosses unchanged" rc_is 3
gb_use nowsl
check "[P16] no wsl.exe -> 40 with the constant reason, one CX_SIGNAL" \
  eval 'rc_is 40 && one_signal FORWARD_FAILED && line_is CX_SIGNAL reason "wsl.exe failed, the WSL distribution is missing, or the WSL VM stopped" && err_has "wsl.exe not found"'
gb_use mismatch
check "[P16] wsl-entry.sh version mismatch -> 41, one CX_SIGNAL (from wsl-entry.sh)" \
  eval 'rc_is 41 && one_signal RUNTIME_MISSING && err_has "wsl-entry: forwarded by conductor $CXV"'
gb_use launch
check "[X]   wsl.exe fails before the command starts (VM terminated at launch) -> 40, one CX_SIGNAL" \
  eval 'rc_is 40 && one_signal FORWARD_FAILED && err_has "instance has terminated"'
gb_use record
check "[P19] WSL side: the host record's .path is used (no /mnt/ entry though the stub appended one)" \
  eval 'TE="$WH/record/target.env"; P="$(sed -n "s/^PATH=//p" "$TE")"; [ "$P" = "$REC_PATH0" ] && ! printf "%s" ":$P:" | grep -q ":/mnt/"'
check "[P19] DBUS_SESSION_BUS_ADDRESS and XDG_RUNTIME_DIR from wsl.exe survive; the three auto-update pins are set" \
  eval 'TE="$WH/record/target.env"; grep -qx "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus" "$TE" && grep -qx "XDG_RUNTIME_DIR=/run/user/1000" "$TE" && grep -qx COPILOT_AUTO_UPDATE=false "$TE" && grep -qx GROK_DISABLE_AUTOUPDATER=1 "$TE" && grep -qx AGY_CLI_DISABLE_AUTO_UPDATE=true "$TE"'
check "[X]   the target runs in the mapped cwd with CX_WIN_SETTINGS empty (no Windows-side settings file)" \
  eval '[ "$(cat "$WH/record/target.pwd")" = "$WIN/c/proj" ] && grep -qx "CX_WIN_SETTINGS=" "$WH/record/target.env"'
gb_use fallback
check "[P19] no record .path: the fallback PATH has ~/.local/bin, /snap/bin, ~/.bun/bin, ~/.cargo/bin and no /mnt/ entry" \
  eval '( P="$(sed -n "s/^PATH=//p" "$WH/fallback/target.env")"; H="$WH/fallback"; case ":$P:" in *":$H/.local/bin:"*":$H/.bun/bin:$H/.cargo/bin:"*":/snap/bin:"*) ;; *) exit 1 ;; esac; ! printf "%s" ":$P:" | grep -q ":/mnt/" )'
gb_use moved
check "[P19] a moved installPath is re-resolved once from installed_plugins.json (cx-wsl ghcp-models still runs)" \
  eval 'rc_is 0 && grep -q "\"claude-opus-5.5\"" "$O" && grep -q "^ghcp-models	" "$WLOG"'
gb_use gbdoc
check "[P34] default Git Bash cx-doctor: a Windows (Git Bash) section in the forwarded report; returns the WSL side's exit (0)" \
  eval 'rc_is 0 && out_has "Windows (Git Bash)" && d_ok W1 "wsl.exe found" && d_ok W2 "default WSL distribution Ubuntu (WSL2)" && d_info W3 "Windows drive" && line_is CX_DOCTOR caller gitbash && line_is CX_DOCTOR fail 0'
check "[P16] forwarded cx-doctor exit 0, one CX_FORWARD; CX_HOST says wsl" eval 'n_signal 0 && [ "$(tj count "$E" CX_FORWARD)" = 1 ] && line_is CX_HOST host wsl'
check "[P19] a forwarded doctor never replaces the interactive record path" \
  eval '[ "$(tj get "$WH/gbdoc/.conductor/hosts/wsl-Ubuntu.json" path_source)" = interactive ] && [ "$(cat "$WH/gbdoc/.conductor/hosts/wsl-Ubuntu.path")" = "$REC_PATH0" ] && [ "$(tj get "$WH/gbdoc/.conductor/hosts/wsl-Ubuntu.json" logins.copilot.forwarded)" = true ]'
check "[P19] host-record wrappers come from the scope user entry (a project entry is listed first)" \
  test "$(tj get "$WH/gbdoc/.conductor/hosts/wsl-Ubuntu.json" bin.ghcp_delegate)" = "$TMP/plugins/ghcp/bin/ghcp-delegate"
check "[X]   forwarded doctor: D3 checks the installed copy, D4 the runtime copy, D14 reads ~/.profile" \
  eval 'd_ok D3 "($ROOT)" && d_ok D4 && d_ok D14 "exported in your WSL login files"'
gb_use gbdoc4
check "[P16] forwarded cx-doctor exit 4 crosses unchanged, one CX_SIGNAL (from the WSL side)" \
  eval 'rc_is 4 && one_signal CHECKS_FAILED && d_fail D10 "grok 1.0.73" && ! out_has "Windows (Git Bash)"'
gb_use gbdoc-fail
check "[X]   default Git Bash cx-doctor when forwarding fails: the W lines in plain text plus a cross W8, exit 40, one CX_SIGNAL" \
  eval 'rc_is 40 && d_ok W1 "wsl.exe found" && d_fail W8 "forwarding into WSL failed (exit 40)" && one_signal FORWARD_FAILED && grep -q "^Summary: " "$O"'
gb_use gbdoc-fail-json
check "[X]   Git Bash cx-doctor --json when forwarding fails: exit 40, stdout empty (no half document), the W report on stderr, one CX_SIGNAL last" \
  eval 'rc_is 40 && out_empty && err_has "wsl.exe found" && err_has "forwarding into WSL failed (exit 40)" && one_signal FORWARD_FAILED'
gb_use gbdoc-winjson
check "[X]   cx-doctor --windows --json: a usage error (the W1-W9 report is plain text), nothing on stdout" \
  eval 'rc_is 1 && out_empty && no_signal && err_has "--json does not combine with --windows"'
gb_use gbdoc-json
check "[X]   Git Bash cx-doctor --json: one JSON document from the WSL side with the W checks merged, caller gitbash" \
  eval 'rc_is 0 && tj isjson "$O" && tj checks "$O" W1 ok "wsl.exe found" && tj checks "$O" D1 ok && outj_is caller gitbash && outj_is host.host wsl'
gb_use gbdoc-lite
check "[X]   W7 cross-check: the lite reader and the real parse of the Windows-side settings disagree -> ! W7; CX_WIN_SETTINGS loaded" \
  eval 'd_warn W7 "lite reader sees wsl_distro='"''"', the real parse '"'"'Ubuntu'"'"'" && d_info D7 "option cap_grok = 4"'
gb_use gb-install
check "[X]   cx-doctor --install-runtime on Git Bash: the bootstrap install into WSL, exit 0, no CX_SIGNAL" \
  eval 'rc_is 0 && line_is CX_RUNTIME changed true && [ -f "$WH/gb-install/.conductor/runtime/$CXV/RUNTIME_STAMP" ] && no_signal'
gb_use win-green
check "[P34] --windows: W1 ok, W2 takes the * row from the UTF-16LE fixture (multi-word STATE), W3 drive cwd info (no \\\\wsl.localhost advice), W4, W8 cx-doctor $CXV" \
  eval 'd_ok W1 "timeout is GNU coreutils" && d_ok W2 "default WSL distribution Ubuntu (WSL2)" && d_info W3 "Windows drive" && d_info W3 "not a desktop session opened on" && d_warn W4 && d_ok W8 "forwarding works: cx-doctor $CXV"'
check "[P34] W7: ghcp, antigravity installed natively in %USERPROFILE%\\.claude -> ! each; the conductor ok" \
  eval 'd_ok W7 "conductor is installed in the Windows-side Claude Code" && d_warn W7 "ghcp is installed natively on Windows" && d_warn W7 "antigravity is installed natively on Windows"'
check "[P34] W9 relays the forwarded D15-D19 lines; plain-text report and Summary; the Git Bash side never called python3" \
  eval 'd_ok W9 && grep -q "^  ✓ copilot is logged in.*\[D16\]$" "$O" && grep -q "^Summary: " "$O" && [ ! -s "$PYTRAP" ]'
gb_use win-bad
check "[P34] an explicit missing wsl_distro: cross W2 listing the installed names" \
  eval 'd_fail W2 "wsl_distro=Fedora is not installed; installed: Ubuntu" && rc_is 4'
check "[P34] UNC cwd: W3 ok; dubious ownership -> cross W5 with git's own suggested command" \
  eval 'd_ok W3 "WSL filesystem" && d_fail W5 "dubious ownership" && grep -Fxq "      fix: git config --global --add safe.directory '"'"'%(prefix)///wsl.localhost/Ubuntu$REPO_W'"'"'" "$O"'
gb_use win-keyring
check "[P34] W9: a direct logged-in record and a forwarded logged-out probe -> ! keyring unreachable through wsl.exe, with the token-file fix" \
  eval 'grep -q "^  ! copilot: logged in from a WSL terminal but not through wsl.exe: the keyring is unreachable (D-Bus) \[D16\]$" "$O" && grep -Fq "fix: in a WSL terminal: create a fine-grained PAT" "$O" && ! grep -q "fix: copilot login" "$O"'
gb_use win-timeout
check "[P34] W1 fails when timeout resolves to a non-GNU timeout" d_fail W1 "timeout resolves to"
gb_use win-crlf
check "[P34] CR in bin/cx-wsl, scripts/cx-init.sh (no canary covers them), templates/ and skills/ of the Windows-side copy: cross W6 naming all four" \
  eval 'd_fail W6 "CRLF line endings in: $GBC/bin/cx-wsl $GBC/scripts/cx-init.sh $GBC/templates/repo-bundle/routes.json $GBC/skills/conductor/SKILL.md" && ! out_has "reset --hard" && ! out_has "core.autocrlf input"'
W6_SED="$(sed -n "s/^      fix: \(sed -i.*\)\$/\1/p" "$O" | head -n 1)"
check "[P34] ... its sed fix quotes each path (the plugin root has spaces) and, run as printed, removes every CR" \
  eval '[ -n "$W6_SED" ] && bash -c "$W6_SED" && ! grep -lq $'"'"'\r'"'"' "$GBC/bin/cx-wsl" "$GBC/scripts/cx-init.sh" "$GBC/templates/repo-bundle/routes.json" "$GBC/skills/conductor/SKILL.md"'
P42_BAD=""
for n in p17a p17b p17c argv argv-wsl envlist cwd-unc cwd-share share-wsl share-doctor short exit37 nodistro crash auto badistro stdin leak init5 gate3 nowsl mismatch launch record fallback moved gbdoc gbdoc4 win-green win-bad win-keyring win-timeout win-crlf gbdoc-fail gbdoc-fail-json gbdoc-json gbdoc-lite gb-install gb-bridge gb-bridge-exit gb-bridge-doc gb-w11m gb-cloud gb-cloud-doc gb-cloud-wsl; do
  grep -q 'command not found' "$WH/$n.err" && P42_BAD="$P42_BAD $n(command not found)"
done
check "[P42] Git Bash code paths (forwarding, cx-wsl, --windows, the doctor) ran on the section 3.1 mini bin: no python3 call, no missing tool${P42_BAD:+:$P42_BAD}" \
  eval '[ ! -s "$PYTRAP" ] && [ -z "$P42_BAD" ]'
gb rt-none -- bash -c '. "$1/scripts/lib/common.sh"; . "$1/scripts/lib/options.sh"; CX_PROG=cx-init; cx_opt_lite wsl_distro "$2"; cx_signal TIMEOUT 12 "x"' _ "$ROOT" "$FIX/settings/enabled-first.json"
check "[P42] cx_signal and cx_opt_lite on Git Bash: no python3 even though a python3 is on PATH" \
  eval 'rc_is 12 && one_signal TIMEOUT && [ "$(cat "$O")" = Right-1.x_y ] && [ ! -s "$PYTRAP" ]'
gb rt-none -- bash "$POLICY"
check "[P42] policy.sh on Git Bash: the Git Bash variant, no python3" eval 'pol_is policy-context-gitbash.json "$DEF_ORDER" && [ ! -s "$PYTRAP" ]'
gb rt-none CLAUDE_PLUGIN_OPTION_EXEC_HOST=local -- "$INIT" --dry-run
check "[X]   exec_host=local on Git Bash -> 43 HOST_UNSUPPORTED" eval 'rc_is 43 && one_signal HOST_UNSUPPORTED'
gb rt-none STUB_UNAME_S=CYGWIN_NT-10.0 -- "$INIT" --dry-run
check "[X]   Cygwin -> 43 HOST_UNSUPPORTED" eval 'rc_is 43 && one_signal HOST_UNSUPPORTED'
# --- INT during a forwarded call whose WSL-side child sleeps
wsl_clone cancel > /dev/null
gb_env cancel
set -m
( cd "$WIN/c/proj" && exec env -i "${GBE[@]}" bash "$ROOT/scripts/host/forward-wsl.sh" cx-gate --sleep 31.7 > "$WH/cancel.out" 2> "$WH/cancel.err" < /dev/null ) &
CPID=$!
set +m
BG_PIDS+=("$CPID")
for _ in $(seq 1 50); do pgrep -f '^sleep 31.7$' > /dev/null && break; sleep 0.1; done
SEEN=0; pgrep -f '^sleep 31.7$' > /dev/null && SEEN=1
kill -INT "$CPID" 2>/dev/null
wait "$CPID"; CRC=$?
GONE=0
for _ in $(seq 1 60); do pgrep -f '^sleep 31.7$' > /dev/null || { GONE=1; break; }; sleep 0.1; done
O="$WH/cancel.out" E="$WH/cancel.err" RC="$CRC"
check "[P16] INT during a forwarded call whose WSL-side child sleeps -> 130 CANCELLED; the Linux-side child is gone within 6 s" \
  eval '[ "$SEEN" = 1 ] && rc_is 130 && one_signal CANCELLED && [ "$GONE" = 1 ]'
pkill -f '^sleep 31.7$' 2>/dev/null
# --- a forwarded call from a console (wsl.exe gives the Linux side a pty): tty reads must work.
# ptyrun TIMEOUT INPUT CMD...: CMD as the session leader of a new pty (python3 -I pty.fork), INPUT
# typed into it; prints "rc=<status|timeout>" and everything the terminal showed. On timeout every
# process of the session is KILLed.
PTYPY="$TMP/ptyrun.py"
cat > "$PTYPY" <<'PY'
import os, pty, select, signal, sys, time
timeout, data, cmd = float(sys.argv[1]), sys.argv[2].encode(), sys.argv[3:]
pid, fd = pty.fork()
if pid == 0:
    os.execvp(cmd[0], cmd)
os.write(fd, data)
out, rc, deadline = b"", None, time.time() + timeout
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.2)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            chunk = b""
        if not chunk:
            break
        out += chunk
if time.time() < deadline:
    rc = os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])
else:
    for p in os.listdir("/proc"):
        try:
            f = open("/proc/%s/stat" % p).read().rsplit(") ", 1)[1].split()
        except (OSError, IndexError):
            continue
        if f[3] == str(pid):
            try:
                os.kill(int(p), signal.SIGKILL)
            except OSError:
                pass
    os.waitpid(pid, 0)
    rc = "timeout"
sys.stdout.write("rc=%s\n%s" % (rc, out.decode("utf-8", "replace")))
PY
wsl_clone tty > /dev/null
gb_env tty
(cd "$WIN/c/proj" && env -i PWD="$WIN/c/proj" "${GBE[@]}" "$REAL_PY" -I "$PTYPY" 15 $'hello\n' bash "$CXWSL" bash -c 'read -r x; echo "got:$x"' > "$WH/tty.out" 2>&1)
O="$WH/tty.out" E="$WH/tty.out" RC=0
check "[P16] under a pty (a console), a forwarded cx-wsl bash -c 'read -r x; echo got:\$x' reads the terminal: got:hello, rc 0, no SIGTTIN stop" \
  eval 'head -n 1 "$O" | grep -qx "rc=0" && grep -q "^got:hello" "$O"'
}
bg_section gbfwd sec_gbfwd

# ------------------------------------------------------------------ 13. cx-wsl on the executor host (section 7.7)
section "cx-wsl passthrough"
CW_HOME="$TMP/cxwsl-home"
cp -a "$WT" "$CW_HOME"
cw() { run wsl_direct "$CW_HOME" "$CXWSL" "$@"; }
CW_BAD=""
for t in copilot claude agy-handoff agy-media rm cx-doctor; do
  stublog_mark
  run wsl_direct "$CW_HOME" env STUB_LOG="$STUB_LOG" "$CXWSL" "$t" --version
  { rc_is 1 && no_signal && err_has "cx-wsl: not allowed: $t" && [ -z "$(stublog_new)" ]; } || CW_BAD="$CW_BAD $t"
done
check "[P45] tools outside the allowlist (copilot, claude, agy-handoff, agy-media (both always --yolo), rm, cx-doctor) -> exit 1 without running anything${CW_BAD:+:$CW_BAD}" test -z "$CW_BAD"
"$REAL_PY" -I "$CXLIB" wsl-resolve --record "$CW_HOME/.conductor/hosts/wsl-Ubuntu.json" --tool ghcp-cloud --config-dir "$CW_HOME/.claude" --conductor-bin "$ROOT/bin" --mnt-root "$WIN/" > "$TMP/cw-cloud.res" 2>&1
check "[P45] ghcp-cloud is allow-listed: it resolves from the host record to the ghcp install dir (the Copilot cloud agent through gh; not run here: the fake wrapper is billable)" \
  eval '[ "$(head -n 1 "$TMP/cw-cloud.res")" = "$TMP/plugins/ghcp/bin/ghcp-cloud" ]'
# The token route (W9, --login-help copilot): $CX_HOME/secrets/copilot-token signs in ghcp-* calls
# only, and only as a regular 0600 file of the user's.
TOKF="$CW_HOME/.conductor/secrets/copilot-token"
mkdir -p "${TOKF%/*}"; printf 'github_pat_CXTEST\n' > "$TOKF"; chmod 600 "$TOKF"
tokrun() {  # ENVFILE TOOL ARGS...: cx-wsl with the token knob; the stub fails with 11 without the token
  local f="$1"; shift
  : > "$f"
  run env -u CLAUDE_CONFIG_DIR -u CX_HOME -u COPILOT_GITHUB_TOKEN HOME="$CW_HOME" WSL_DISTRO_NAME=Ubuntu PATH="$WSL_PATH0" \
    STUB_COPILOT_TOKEN_ONLY=COPILOT_GITHUB_TOKEN STUB_ENV_FILE="$f" STUB_LOG="$TMP/cw.log" "$@"
}
TOK_BAD=""
tokrun "$TMP/cw-tok.env" "$CXWSL" ghcp-models --json
{ rc_is 0 && grep -qx COPILOT_GITHUB_TOKEN=github_pat_CXTEST "$TMP/cw-tok.env" && err_empty; } || TOK_BAD="$TOK_BAD [0600 file: rc $RC]"
tokrun "$TMP/cw-tok2.env" env COPILOT_GITHUB_TOKEN=github_pat_CALLER "$CXWSL" ghcp-models --json
{ rc_is 0 && grep -qx COPILOT_GITHUB_TOKEN=github_pat_CALLER "$TMP/cw-tok2.env"; } || TOK_BAD="$TOK_BAD [caller's own token kept]"
run env -u CLAUDE_CONFIG_DIR -u CX_HOME -u COPILOT_GITHUB_TOKEN HOME="$CW_HOME" WSL_DISTRO_NAME=Ubuntu PATH="$WSL_PATH0" STUB_LOG="$TMP/cw.log" \
  "$CXWSL" bash -c 'printf "%s\n" "${COPILOT_GITHUB_TOKEN-unset}"'
{ rc_is 0 && [ "$(cat "$O")" = unset ]; } || TOK_BAD="$TOK_BAD [bash got it]"
chmod 644 "$TOKF"
tokrun "$TMP/cw-tok3.env" "$CXWSL" ghcp-models --json
{ rc_is 11 && ! grep -q '^COPILOT_GITHUB_TOKEN=' "$TMP/cw-tok3.env" && err_has "cx-wsl: ignoring $TOKF: it must be a regular file you own with mode 0600"; } || TOK_BAD="$TOK_BAD [0644 file: rc $RC]"
rm -f "$TOKF"; ln -s "$TMP/tok-elsewhere" "$TOKF"; printf 'github_pat_LINK\n' > "$TMP/tok-elsewhere"; chmod 600 "$TMP/tok-elsewhere"
tokrun "$TMP/cw-tok4.env" "$CXWSL" ghcp-models --json
{ rc_is 11 && ! grep -q '^COPILOT_GITHUB_TOKEN=' "$TMP/cw-tok4.env"; } || TOK_BAD="$TOK_BAD [symlink: rc $RC]"
rm -f "$TOKF"
check "[P45] token route: a 0600 \$CX_HOME/secrets/copilot-token becomes COPILOT_GITHUB_TOKEN for cx-wsl ghcp-* only (a caller's own token wins; cx-wsl bash never gets it; a 0644 file or a symlink is ignored with a note)${TOK_BAD:+:$TOK_BAD}" test -z "$TOK_BAD"
mkdir -p "$TMP/decoy"; printf '#!/bin/sh\necho DECOY\n' > "$TMP/decoy/ghcp-models"; chmod 0755 "$TMP/decoy/ghcp-models"
run env -u CLAUDE_CONFIG_DIR -u CX_HOME HOME="$CW_HOME" WSL_DISTRO_NAME=Ubuntu PATH="$TMP/decoy:$WSL_PATH0" STUB_ENV_FILE="$TMP/cw-ghcp.env" STUB_LOG="$TMP/cw.log" \
  COPILOT_MODEL=gpt-x COPILOT_ALLOW_ALL=1 "$CXWSL" ghcp-models --json
check "[P45] an allow-listed tool resolves from the host record (ghcp-models via the fake install dir), never a PATH entry of the same name" \
  eval 'rc_is 0 && ! out_has DECOY && grep -q "\"claude-opus-5.5\"" "$O" && ! grep -q "^CX_" "$E"'
check "[P45] ghcp-* prefix: COPILOT_MODEL and COPILOT_ALLOW_ALL unset, CX_WORKER=1 COPILOT_AUTO_UPDATE=false" \
  eval 'sed -n "/^== ghcp-models$/,/^== /p" "$TMP/cw-ghcp.env" > "$TMP/cw-ghcp.1"; ! grep -Eq "^COPILOT_(MODEL|ALLOW_ALL)=" "$TMP/cw-ghcp.1" && grep -qx CX_WORKER=1 "$TMP/cw-ghcp.1" && grep -qx COPILOT_AUTO_UPDATE=false "$TMP/cw-ghcp.1"'
run env -u CLAUDE_CONFIG_DIR -u CX_HOME HOME="$CW_HOME" WSL_DISTRO_NAME=Ubuntu PATH="$WSL_PATH0" STUB_ENV_FILE="$TMP/cw-grok.env" STUB_LOG="$TMP/cw.log" \
  XAI_API_KEY=xai-secret GROK_SANDBOX=off "$CXWSL" grok --version
check "[P45] cx-wsl grok --version: the tool's output unchanged; XAI_API_KEY and GROK_SANDBOX unset; CX_WORKER=1 and the GROK_* values set" \
  eval 'rc_is 0 && [ "$(cat "$O")" = "grok 1.0.70 (f50904eaee6c)" ] && err_empty && ! grep -Eq "^(XAI_API_KEY|GROK_SANDBOX)=" "$TMP/cw-grok.env" && grep -qx CX_WORKER=1 "$TMP/cw-grok.env" && grep -qx GROK_DISABLE_AUTOUPDATER=1 "$TMP/cw-grok.env" && ( for v in HOOKS SKILLS MCPS RULES AGENTS; do grep -qx "GROK_CLAUDE_${v}_ENABLED=false" "$TMP/cw-grok.env" || exit 1; done )'
run env -u CLAUDE_CONFIG_DIR -u CX_HOME HOME="$CW_HOME" WSL_DISTRO_NAME=Ubuntu PATH="$WSL_PATH0" STUB_ENV_FILE="$TMP/cw-agy.env" STUB_LOG="$TMP/cw.log" \
  GEMINI_API_KEY=g GOOGLE_API_KEY=g "$CXWSL" agy --version
check "[P45] agy prefix: GEMINI_API_KEY and GOOGLE_API_KEY unset, CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true" \
  eval 'rc_is 0 && [ "$(cat "$O")" = 1.4.12 ] && ! grep -Eq "^(GEMINI_API_KEY|GOOGLE_API_KEY)=" "$TMP/cw-agy.env" && grep -qx CX_WORKER=1 "$TMP/cw-agy.env" && grep -qx AGY_CLI_DISABLE_AUTO_UPDATE=true "$TMP/cw-agy.env"'
cw bash -c 'printf "%s\n" "$PATH"; command -v ghcp-delegate agy-job cx-doctor; echo oops >&2; exit 9'
check "[P45] cx-wsl bash sees the sibling wrapper dirs, the conductor bin/ and the record path; status and stderr unchanged, no CX_* line" \
  eval 'rc_is 9 && [ "$(cat "$E")" = oops ] && head -n 1 "$O" | grep -q "^$TMP/plugins/ghcp/bin:$TMP/plugins/antigravity/bin:$ROOT/bin:" && grep -qx "$TMP/plugins/ghcp/bin/ghcp-delegate" "$O" && grep -qx "$ROOT/bin/cx-doctor" "$O"'
cw git --version
check "[X]   cx-wsl git: the recorded git, output unchanged" eval 'rc_is 0 && grep -q "^git version" "$O" && err_empty'
runin $'X=one\r\nprintf "x=[%s]\\n" "$X"\r\n' wsl_direct "$CW_HOME" "$CXWSL" bash -s
check "[X]   cx-wsl bash -s with a CRLF step on stdin: run with LF (no CR in any word), a cx-wsl: note, no CX_* line" \
  eval 'rc_is 0 && [ "$(cat "$O")" = "x=[one]" ] && err_has "cx-wsl: the step on stdin had CRLF line endings" && ! grep -q "^CX_" "$E"'
runin $'X=two\nprintf "x=[%s]\\n" "$X"\n' wsl_direct "$CW_HOME" "$CXWSL" bash -s
check "[X]   ... an LF step: unchanged, stderr empty" eval 'rc_is 0 && [ "$(cat "$O")" = "x=[two]" ] && err_empty'
run env -u CLAUDE_CONFIG_DIR -u CX_HOME HOME="$TMP/cxwsl-norecord" WSL_DISTRO_NAME=Ubuntu PATH="$WSL_PATH0" "$CXWSL" grok --version
check "[P45] no host record -> 13 CLI_MISSING with one CX_SIGNAL (retry: cx-doctor)" \
  eval 'rc_is 13 && one_signal CLI_MISSING && line_is CX_SIGNAL retry "cx-doctor (from a Claude Code session; in a WSL terminal, where cx-doctor is not on PATH: ~/.conductor/runtime/current/bin/cx-doctor, created once by cx-doctor --install-runtime)" && err_has "run /conductor:doctor in a Claude Code session in WSL, or ~/.conductor/runtime/current/bin/cx-doctor in a WSL terminal" && err_has "create that copy once with /conductor:doctor --install-runtime" && out_empty'
"$REAL_PY" -I - "$CW_HOME/.conductor/hosts/wsl-Ubuntu.json" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); r["bin"]["grok"] = None
open(sys.argv[1], "w").write(json.dumps(r))
PY
cw grok --version
check "[X]   a null bin entry -> 13 CLI_MISSING" eval 'rc_is 13 && one_signal CLI_MISSING'
cw
check "[X]   no TOOL -> exit 1" eval 'rc_is 1 && no_signal'

# ------------------------------------------------------------------ 14. skill, commands, docs (sections 12, 13, U5)
section "session kinds: the cloud refusal (step 0a), Projects instructions, hygiene"
P49_BAD=""
stublog_mark
for c in "$CXWSL ghcp-models --json" "$INIT --dry-run" "$CXWSL agy-delegate --model x y" "$INIT --dir /nonexistent"; do
  read -r -a CMD <<< "$c"
  run env CLAUDE_CODE_REMOTE=true "${CMD[@]}"
  { rc_is 43 && one_signal HOST_UNSUPPORTED && err_has "cloud session (cloud): the executors and their logins are in WSL on your computer; run this in a local desktop session, a Work locally project thread or a Claude Code session in WSL" && out_empty; } || P49_BAD="$P49_BAD [${c##*/}]"
done
run env CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=byoc "$INIT" --dry-run
{ rc_is 43 && err_has "cloud session (byoc)"; } || P49_BAD="$P49_BAD [byoc]"
[ -z "$(stublog_new)" ] || P49_BAD="$P49_BAD [stubs ran: $(stublog_new | cut -f1 | sort -u | tr '\n' ' ')]"
check "[P49] CLAUDE_CODE_REMOTE=true: cx-wsl and cx-init exit 43 with the cloud session note and one CX_SIGNAL HOST_UNSUPPORTED last, nothing on stdout, no stub ran${P49_BAD:+:$P49_BAD}" test -z "$P49_BAD"
P49_BAD=""
for b in cx-doctor cx-init cx-wsl; do
  run env CLAUDE_CODE_REMOTE=true "$ROOT/bin/$b" --version
  { rc_is 0 && [ "$(cat "$O")" = "$b $CXV" ]; } || P49_BAD="$P49_BAD [$b --version]"
  run env CLAUDE_CODE_REMOTE=true "$ROOT/bin/$b" --help
  { rc_is 0 && out_has "Usage: $b"; } || P49_BAD="$P49_BAD [$b --help]"
done
run env CLAUDE_CODE_REMOTE=true "$DOCTOR" --login-help grok
{ rc_is 0 && out_has "grok login --device-auth"; } || P49_BAD="$P49_BAD [--login-help]"
run env CLAUDE_CODE_REMOTE=true CLAUDE_CODE_ENVIRONMENT_KIND=bridge "$INIT" --dry-run --dir "$TMP/work"
rc_is 43 && P49_BAD="$P49_BAD [bridge refused]"
check "[P49] in the cloud --help, --version and cx-doctor --login-help still exit 0; a bridge child is never refused${P49_BAD:+:$P49_BAD}" test -z "$P49_BAD"
PI="$ROOT/templates/projects-instructions.md"
P52_BAD="$("$REAL_PY" -I - "$PI" "$ROOT/skills/conductor/SKILL.md" "$ROOT/README.md" "$ROOT/docs/DESIGN.md" <<'PY'
import sys
raw = open(sys.argv[1], "rb").read()
bad = []
if not raw.isascii() or b"\r" in raw or not raw.endswith(b"\n"): bad.append("not ASCII LF")
t = raw.decode()
if len(t) > 2000: bad.append("%d characters" % len(t))
if "one job at a time" in t or "until the conductor shares" in t: bad.append("still has the Phase 1 agy line")
for w in ("Work locally", "these win", "every thread", "shares its pool slots between threads", "cap_agy", "agy launches one at a time",
          "next Opus pool", "ghcp-cloud", "Claude alone", "my own messages", "coordinator brief"):
    if w not in t: bad.append("lacks " + repr(w))
sk = open(sys.argv[2], encoding="utf-8").read()
if "### In a Claude Code Project" not in sk: bad.append("SKILL lacks the Projects subsection")
de = open(sys.argv[4], encoding="utf-8").read()
blk = de.split("<!-- projects-instructions:begin -->", 1)[1].split("<!-- projects-instructions:end -->", 1)[0]
if blk.split("```text\n", 1)[1].rsplit("\n```", 1)[0] + "\n" != t: bad.append("differs from the DESIGN section 9.6 block")
rd = open(sys.argv[3], encoding="utf-8").read()
if "templates/projects-instructions.md" not in rd or "Project settings > Memory" not in rd: bad.append("README lacks the paste instructions")
print("; ".join(bad))
PY
)"
check "[P52] templates/projects-instructions.md: equals the section 9.6 block, ASCII, LF, <= 2000 characters, every thread Work locally, these win, the conductor shares its pool slots between threads (cap_agy, agy launches one at a time), executors' own clouds (ghcp-cloud), a cloud thread uses Claude alone; the SKILL subsection; README says where to paste it${P52_BAD:+: $P52_BAD}" test -z "$P52_BAD"
P62_BAD=""
for v in "${ISO_VARS[@]}"; do
  [ -z "$(bash -c 'printf "%s" "${!1+set}"' _ "$v")" ] || P62_BAD="$P62_BAD $v"
done
check "[P62] the suite's environment has none of the session, attended, Work locally and workflow variables (${#ISO_VARS[@]} names)${P62_BAD:+:$P62_BAD}" test -z "$P62_BAD"
P62_BAD="$(cd "$ROOT" && grep -rnE 'CLAUDE_PROJECT_DIR|CLAUDE_CODE_VERSION|CLAUDE_CODE_ENTRYPOINT' bin scripts \
  | grep -v 'ep="${CLAUDE_CODE_ENTRYPOINT:-}" dv="${CLAUDE_CODE_DESKTOP_APP_VERSION:-}"' | grep -v 'case "${CLAUDE_CODE_ENTRYPOINT:-}:${CLAUDE_CODE_DESKTOP_APP_VERSION:-}" in' \
  | grep -v '^scripts/adapters/claude.sh:[0-9]*:CLAUDE_WORKER_SCRUB=(' | head -n 3)"
check "[P62] no file under bin/ or scripts/ reads CLAUDE_PROJECT_DIR, CLAUDE_CODE_VERSION or CLAUDE_CODE_ENTRYPOINT (only the doctor's D30 wording, allow-listed)${P62_BAD:+: $P62_BAD}" test -z "$P62_BAD"

section "skill, commands, README, Cursor"
P61_BAD="$("$REAL_PY" -I - "$ROOT/skills/conductor/SKILL.md" <<'PY'
import re, sys
t = open(sys.argv[1], encoding="utf-8").read()
bad = []
body = t.split("\n---\n", 1)[1]
paras = [p.strip() for p in body.split("\n\n") if p.strip()]
if not paras[0].startswith("# conductor") or not paras[1].startswith("**If you are a subagent or a workflow agent, do not run anything in this skill: return `EXECUTOR_NEEDED: <lane> - <reason>`"):
    bad.append("the preface line is not the first paragraph after the title")
i = t.find("### Workflows and ultracode"); j = t.find("### In a Claude Code Project"); k = t.find("\n## 5.")
if not (0 < i < j < k):
    bad.append("Workflows and ultracode / In a Claude Code Project missing or out of order before section 5")
sec = t[i:j]
m = re.search(r"```js\n(.*?)\n```", sec, re.S)
if not m:
    bad.append("no js block in Workflows and ultracode")
else:
    js = m.group(1)
    if not js.startswith("export const meta = {"):
        bad.append("js does not start with export const meta = {")
    meta = js.split("\n}\n", 1)[0]
    if "${" in meta or "..." in meta or "name:" not in meta or "description:" not in meta:
        bad.append("meta is not a pure literal with name and description")
    for w in ("Date.now", "Math.random", "new Date(", "isolation", "agentType", "import ", "require("):
        if w in js:
            bad.append("js uses " + w)
    if "effort:" not in js:
        bad.append("js sets no effort")
    for w in ("t.wt_win", "cd \"${t.wt}\" &&", "cx-wsl bash -c 'cd \"${t.wt}\" && <command>'", "${t.wt_win} and paths under it for Read, Edit, Write, Glob and Grep"):
        if w not in js:
            bad.append("js lacks " + repr(w))
    if "cd ${t.wt} &&" in js:
        bad.append("js has an unquoted cd ${t.wt}")
if "bashCommandClamp" in t:
    bad.append("mentions bashCommandClamp")
for w in ("Ultracode\nchanges how thorough you are, not who executes", "EXECUTOR_NEEDED", "isolation: 'worktree'", "budget"):
    if w.replace("\n", " ") not in t.replace("\n", " "):
        bad.append("lacks " + repr(w))
pj = t[j:k]
for w in ("Precedence", "user's own messages", "Projects", "coordinator", "they share the pool slots", "agy launches one at a time", "reply tool"):
    if w.replace("\n  ", " ") not in pj.replace("\n  ", " ").replace("\n", " "):
        bad.append("Projects subsection lacks " + repr(w))
print("; ".join(bad))
PY
)"
check "[P61] SKILL: the subagent preface is the first paragraph after the title; Workflows and ultracode then In a Claude Code Project before section 5; the claude-pool script is static (pure-literal meta, no Date/random, no isolation, no agentType, effort set) and quotes the WSL path, with a wt_win (Windows) prompt: file tools on wt_win, commands through cx-wsl bash -c; no bashCommandClamp${P61_BAD:+: $P61_BAD}" test -z "$P61_BAD"
FM_BAD="$("$REAL_PY" -I - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
for rel in ("skills/conductor/SKILL.md", "commands/doctor.md", "commands/init.md", "commands/route.md"):
    text = open(os.path.join(root, rel), encoding="utf-8").read()
    if not text.startswith("---\n"):
        bad.append(rel + ": no frontmatter"); continue
    fm = text[4:].split("\n---\n", 1)[0].split("\n")
    keys = {}
    for ln in fm:
        m = re.match(r"([A-Za-z-]+):\s*(.*)$", ln)
        if m:
            keys[m.group(1)] = m.group(2)
            v = m.group(2)
            if v[:1] in ("[", "{"):
                bad.append("%s: %s starts with %s unquoted" % (rel, m.group(1), v[:1]))
    if rel.startswith("skills"):
        if keys.get("name") != "conductor" or not keys.get("description"):
            bad.append(rel + ": name/description")
    else:
        if not keys.get("description") or not keys.get("argument-hint", "").startswith('"'):
            bad.append(rel + ": description or a double-quoted argument-hint")
        if "$ARGUMENTS" not in text:
            bad.append(rel + ": body lacks $ARGUMENTS")
    if rel == "commands/route.md" and keys.get("allowed-tools") != "Read, Glob, Grep":
        bad.append(rel + ": allowed-tools")
print("; ".join(bad))
PY
)"
check "[P43] SKILL and command frontmatter: present; values starting with [ or { are double-quoted; route.md allowed-tools Read, Glob, Grep${FM_BAD:+: $FM_BAD}" test -z "$FM_BAD"
SK="$ROOT/skills/conductor/SKILL.md"
check "[P43] SKILL exit table has '| 130 | CANCELLED |'; README has '| 130 | \`CANCELLED\` |'" \
  eval 'grep -q "^| 130 | CANCELLED |" "$SK" && grep -q "^| 130 | \`CANCELLED\` |" "$ROOT/README.md"'
SK_BAD=""
for s in 'cx-run --background --exec agy --task-file' 'cx-run --background --exec copilot --effort high' '--fusion max' 'cx-run --exec claude --task-file' 'cx-run --finish t1' 'cx-run --mode review --family gemini --branch cx/t1' 'cx-run --exec copilot-cloud' 'cx-init --user-grants' 'cx-job wait' '--no-subagents'; do
  grep -Fq -- "$s" "$SK" || SK_BAD="$SK_BAD [$s]"
done
check "[P43] SKILL contains the section 12.2 commands verbatim (the Phase 2 cx-run / cx-job forms)${SK_BAD:+ (missing:$SK_BAD)}" test -z "$SK_BAD"
# Every non-comment line of every bash block in DESIGN section 12.2 appears in the SKILL verbatim
# (the SKILL copies 12.2; a drifted Step 3 once committed and gated after SPEC_TAMPERED).
SYNC_BAD="$("$REAL_PY" -I - "$ROOT/docs/DESIGN.md" "$SK" <<'PY'
import sys
design = open(sys.argv[1], encoding="utf-8").read()
sec = design.split("### 12.2 Lane commands", 1)[1].split("### 12.3", 1)[0]
skill = set(ln.rstrip() for ln in open(sys.argv[2], encoding="utf-8").read().split("\n"))
bad, n = [], 0
for blk in sec.split("```bash\n")[1:]:
    for ln in blk.split("\n```", 1)[0].split("\n"):
        if not ln.strip() or ln.strip().startswith("#"):
            continue
        n += 1
        if ln.rstrip() not in skill:
            bad.append(ln.strip()[:90])
if n < 30:
    bad.append("only %d lines found in section 12.2" % n)
print(" | ".join(bad[:4]))
PY
)" || SYNC_BAD="the checker failed"
check "[P43] every non-comment line of every bash block in DESIGN section 12.2 appears in the SKILL verbatim${SYNC_BAD:+ (missing: $SYNC_BAD)}" test -z "$SYNC_BAD"
# D25 (U2): every executor and GitHub simple command in the SKILL's bash blocks starts with one of
# the allow rules the doctor prints, so the skill copied verbatim runs without prompts.
"$REAL_PY" -I "$CXLIB" const D25_HOST_RULES > "$TMP/d25.json"
D25_BAD="$("$REAL_PY" -I - "$SK" "$TMP/d25.json" <<'PY'
import json, re, shlex, sys
text = open(sys.argv[1], encoding="utf-8").read()
rules = [r[len("Bash("):-len(":*)")] for r in json.load(open(sys.argv[2])) if r.endswith(":*)")]
norm = lambda toks: " ".join(toks)
prefixes = []
for r in rules:
    try:
        prefixes.append((norm(shlex.split(r)), False))
    except ValueError:              # a prefix that ends inside a quote: . "$HOME/.conductor/out/
        prefixes.append((norm(shlex.split(r + '"')), True))
blocks = [b.split("\n```", 1)[0] for b in text.split("```bash\n")[1:]]
bad, seen, used = [], 0, set()
for blk in blocks:
    lines, out, heredoc = blk.replace("\\\n", " ").split("\n"), [], None
    for ln in lines:
        if heredoc:
            if ln.strip() == heredoc:
                heredoc = None
            continue
        m = re.search(r"<<'(\w+)'", ln)
        if m:
            heredoc = m.group(1)
        out.append(ln)
    for ln in out:
        if not ln.strip() or ln.strip().startswith("#"):
            continue
        if re.search(r"\(\s*cd\s[^)]*&&\s*(gh\b|git\b[^)]*\bpush\b)", ln):
            bad.append("gh/git inside a (cd ... && ...) subshell: " + ln.strip()[:60])
        lx = shlex.shlex(ln, posix=True, punctuation_chars=True)
        lx.whitespace_split = True
        try:
            toks = list(lx)
        except ValueError:
            bad.append("unparsable: " + ln[:60]); continue
        cmds, cur = [], []
        for t in toks:
            if t in ("&&", "||", ";", "|", "(", ")", "$(", "<", ">", "2>", "<<") or set(t) <= set("&|;()<>"):
                if cur: cmds.append(cur)
                cur = []
            else:
                cur.append(t)
        if cur: cmds.append(cur)
        for c in cmds:
            c = [t for t in c if not re.fullmatch(r"\$?", t)]
            i = 0
            if c and c[0] == "env":
                i = 1
                while i < len(c) and (c[i] == "-u" or c[i - 1] == "-u" or re.fullmatch(r"[A-Z_][A-Z0-9_]*=.*", c[i]) or c[i] == "${G_ENV[@]}"):
                    i += 1
            if i < len(c) and c[i] == "timeout":
                i += 1
                while i < len(c) and (c[i].startswith("-") or re.fullmatch(r"\d+[smh]?", c[i])):
                    i += 1
            if i >= len(c):
                continue
            w = c[i]
            hit = (re.fullmatch(r"ghcp-(delegate|job|handoff|ci-debug|cloud)|agy-(delegate|job|media)|agy-handoff|agy|grok|cx-run|cx-job|cx-wsl|cx-doctor|cx-init", w)
                   or (w == "git" and "push" in c) or (w == "gh" and len(c) > i + 1 and c[i + 1] in ("pr", "api", "issue", "repo"))
                   or w == ".")
            if not hit:
                continue
            seen += 1
            s = norm(c)
            m = [p for p, part in prefixes if s == p or s.startswith(p + " ") or (part and s.startswith(p))]
            if not m:
                bad.append(s[:100])
            used.update(m)
if seen < 20:
    bad.append("only %d executor/GitHub commands found" % seen)
# The other way: every rule (but cx-doctor and cx-init, which the skill names in prose) matches a
# command of the skill's bash blocks; a rule for a form the skill no longer runs is too broad.
for p, part in prefixes:
    if p not in used and p not in ("cx-doctor", "cx-init"):
        bad.append("rule without a command: " + p)
print(" | ".join(bad[:4]))
PY
)" || D25_BAD="the checker failed"
check "[P43] every executor and GitHub simple command in the SKILL's bash blocks (cx-run, cx-job, cx-wsl grok / ghcp-ci-debug, ghcp-cloud, the vars.sh line, git push, gh pr) matches a D25 allow rule, and every D25 host rule matches one of them (no rule for a form the skill does not run); no gh/git in a (cd ... && ...) subshell${D25_BAD:+ (unmatched: $D25_BAD)}" test -z "$D25_BAD"
# The Windows rules: each cx-wsl form is one the SKILL tells the Windows side to run directly.
"$REAL_PY" -I "$CXLIB" const D25_WIN_RULES > "$TMP/d25w.json"
D25W_BAD="$("$REAL_PY" -I - "$SK" "$TMP/d25w.json" <<'PY'
import json, sys
text = open(sys.argv[1], encoding="utf-8").read().replace("\n  ", " ")
bad = []
for r in json.load(open(sys.argv[2])):
    p = r[len("Bash("):-len(":*)")]
    if p.startswith("cx-wsl ") and ("`" + p) not in text:
        bad.append(p)
    if p == "cx-wsl" or p.startswith("cx-wsl bash") or p.startswith("cx-wsl agy") or p.startswith("cx-wsl ghcp-delegate"):
        bad.append("too broad: " + p)
print(" | ".join(bad))
PY
)"
check "[P43] every D25 Windows-side cx-wsl rule is a form the SKILL's Windows section names (no cx-wsl bash, agy or ghcp-delegate rule)${D25W_BAD:+: $D25W_BAD}" test -z "$D25W_BAD"
# Lanes that always pass --yolo (agy-handoff, agy-media, /antigravity:research) are never run
# by a SKILL code block nor listed as a read-only lane; cx-wsl refuses agy-media (P45).
check "[P43] no SKILL code block runs agy-media, agy-handoff, /antigravity:research or --yolo; their lane row is not marked read-only (Writes: no)" \
  eval '! awk "/^\`\`\`bash/{f=1;next} /^\`\`\`/{f=0} f" "$SK" | grep -Eq "agy-media|agy-handoff|antigravity:research|--yolo|--dangerously-skip-permissions" && ! grep -E "^\| \`agy-media\` " "$SK" | grep -q "| no |"'
check "[P43] the SKILL names the background-call timeout (timeout: 7200000) in its rules for every call" \
  eval 'sed -n "/^### Rules for every call/,/^### Step 1/p" "$SK" | grep -q "timeout: 7200000"'
# Phase 2: the tree snapshots live only in the agy adapter (agy.sh agy_trees; [A5], [A28] and the
# running-mark check of the agy adapter section run them); the SKILL and section 12.2 define none.
SKR="$TMP/skillrun"; mkdir -p "$SKR/home/.conductor/out/t1" "$SKR/home/.cx-wt"
P60_N="$(grep -c "status --porcelain=v1 --untracked-files=all -- . ':!.claude/worktrees'" "$SK") $(sed -n "/^### 12.2 /,/^### 12.3 /p" "$ROOT/docs/DESIGN.md" | grep -c "status --porcelain=v1 --untracked-files=all -- . ':!.claude/worktrees'") $(grep -c "status --porcelain=v1 --untracked-files=all -- . ':!.claude/worktrees'" "$ROOT/scripts/adapters/agy.sh")"
check "[P60] the tree snapshot that excludes .claude/worktrees is defined once, in the agy adapter, and no longer in the SKILL or section 12.2 (SKILL, 12.2, agy.sh: $P60_N)" \
  eval '[ "$P60_N" = "0 0 1" ] && ! grep -q "^trees() {" "$SK"'
# Phase 2: no SKILL or section 12.2 block registers or runs agy, agy-delegate or ghcp-delegate by
# hand (cx-run does, under its pool slot), none starts an agy-job, no Phase 1 lock line is left.
LOCK_LINE='CXB=$(command -v cx-wsl); source "${CXB%/bin/cx-wsl}/scripts/lib/locks.sh" && cx_slot_take agy || exit $?   # an agy pool slot and the agy launch lock (shared by every session and thread), held until this call ends'
LOCK_BAD="$("$REAL_PY" -I - "$SK" "$ROOT/docs/DESIGN.md" <<'PY'
import sys
bad = []
for path in sys.argv[1:3]:
    text = open(path, encoding="utf-8").read()
    if path.endswith("DESIGN.md"):
        text = text.split("### 12.2 Lane commands", 1)[1].split("### 12.3", 1)[0]
    for blk in [b.split("\n```", 1)[0] for b in text.split("```bash\n")[1:]]:
        for l in blk.split("\n"):
            if l.startswith("cx-run ") or l.startswith("cx-job "):
                continue
            if any(w in l for w in ("agy-job start", "agy --new-project", "agy-delegate --model", "agy --model", "ghcp-delegate --model", "ghcp-job start", "cx_slot_take")):
                bad.append(path.rsplit("/", 1)[1] + ": " + l.strip()[:60])
print("; ".join(bad))
PY
)"
check "[P43] no SKILL or section 12.2 block runs agy, agy-delegate, ghcp-delegate or a job of theirs by hand (cx-run does, under its pool slot); no Phase 1 lock line is left${LOCK_BAD:+: $LOCK_BAD}" \
  eval '[ -z "$LOCK_BAD" ] && ! grep -q "AGY_BUSY\|flock -w 4800" "$SK" && ! sed -n "/^### 12.2 /,/^### 12.3 /p" "$ROOT/docs/DESIGN.md" | grep -q "AGY_BUSY\|flock -w 4800"'
# The slot line (cx_slot_take, section 15.3; no longer in the SKILL, still the library's contract
# for hand steps), as a step runs it (cx-wsl's bin/ on PATH), in a scratch home whose
# settings.json sets cap_agy=1; a 1 s wait.
LKH="$SKR/lockhome"
mkdir -p "$LKH/.conductor/locks" "$LKH/cfg"
printf '{"pluginConfigs": {"conductor@conductor-for-claude-code": {"options": {"cap_agy": "1", "cap_grok": 7}}}}\n' > "$LKH/cfg/settings.json"
LK_STEP="$LOCK_LINE"$'\necho GOT'
lk_step() { env HOME="$LKH" CX_HOME="$LKH/.conductor" CLAUDE_CONFIG_DIR="$LKH/cfg" PATH="$ROOT/bin:$PATH" CX_SLOT_WAIT_SECS=1 bash -c "$LK_STEP" > "$LKH/out" 2> "$LKH/err"; RC=$?; O="$LKH/out" E="$LKH/err"; }
lk_hold() { bash -c 'exec 9>>"$1"; flock -x 9; : > "$2"; exec sleep 30' _ "$1" "$LKH/held" > /dev/null 2>&1 & LK_PID=$!; until [ -e "$LKH/held" ]; do sleep 0.05; done; rm -f "$LKH/held"; }
LK_OUT=""
lk_hold "$LKH/.conductor/locks/agy.1"
lk_step; { rc_is 28 && out_empty && one_signal NO_CAPACITY && line_is CX_SIGNAL cmd slot; } && LK_OUT="$LK_OUT slot-busy"
kill "$LK_PID"; wait "$LK_PID" 2>/dev/null
lk_hold "$LKH/.conductor/locks/agy-launch"
lk_step; { rc_is 28 && out_empty && one_signal NO_CAPACITY && err_has "another agy launch is in progress"; } && LK_OUT="$LK_OUT launch-busy"
kill "$LK_PID"; wait "$LK_PID" 2>/dev/null
lk_hold "$LKH/.conductor/locks/agy"
lk_step; { rc_is 28 && out_empty && one_signal NO_CAPACITY; } && LK_OUT="$LK_OUT phase1-busy"
kill "$LK_PID"; wait "$LK_PID" 2>/dev/null
lk_step; { rc_is 0 && [ "$(cat "$O")" = GOT ] && err_empty; } && LK_OUT="$LK_OUT free"
env HOME="$LKH" CX_HOME="$LKH/.conductor" CLAUDE_CONFIG_DIR="$LKH/cfg" PATH="$ROOT/bin:$PATH" bash -c "$LOCK_LINE"$'\nenv' 2>/dev/null | grep -q '^CLAUDE_PLUGIN_OPTION_' && LK_OUT="$LK_OUT leaked-options"
check "[P43] the slot line (cap_agy=1 from settings.json, CX_SLOT_WAIT_SECS=1): exits 28 with one CX_SIGNAL NO_CAPACITY (cmd slot) while the agy slot, the agy launch lock or a Phase 1 step's ~/.conductor/locks/agy is held, and proceeds (stderr empty) once they are free; no option variable leaks into the step (got:$LK_OUT)" \
  test "$LK_OUT" = " slot-busy launch-busy phase1-busy free"
STEP3="$(awk '/^### Step 3: after every run/{s=1} s&&/^```bash/{f=1;next} f&&/^```/{exit} f' "$SK" | sed 's/^(cd "\$G" && npm ci.*/(cd "$G" \&\& test -f f)/')"
step3_run() {  # NAME SETUP: a fresh task t1 from BASE, SETUP run in $WT as the executor, then the SKILL's Step 3
  local d="$SKR/$1"
  rm -rf "$d"; mkdir -p "$d/home/.conductor/out/t1"
  git init -q "$d/top"; printf 'a\n' > "$d/top/f"; git -C "$d/top" add f; git -C "$d/top" commit -qm i
  local base wt="$d/home/.cx-wt/top-t1"
  base="$(git -C "$d/top" rev-parse HEAD)"
  git -C "$d/top" worktree add -q -b cx/t1 "$wt" "$base"
  mkdir -p "$wt/.conductor"; printf 'task\n' > "$wt/.conductor/task.md"; printf '/.conductor/\n' >> "$d/top/.git/info/exclude"
  sha256sum "$wt/.conductor/task.md" | cut -d' ' -f1 > "$d/home/.conductor/out/t1/task.sha"
  printf '%s=%q\n' ID t1 TOP "$d/top" BASE "$base" WT "$wt" OUT "$d/home/.conductor/out/t1" > "$d/home/.conductor/out/t1/vars.sh"
  (cd "$wt" && bash -c "$2") > /dev/null 2>&1
  (cd "$d/top" && env HOME="$d/home" bash -c "$STEP3") > "$d/out" 2>&1; printf '%s' "$?" > "$d/rc"
}
step3_run s3-switch 'git checkout -q -b fix && printf "b\n" >> f && git commit -qam change'
check "[P43] SKILL Step 3 after an executor switched to its own branch: BRANCH_TAMPERED, exit 24, cx/t1 untouched at BASE, nothing gated" \
  eval '[ "$(cat "$SKR/s3-switch/rc")" = 24 ] && grep -qx BRANCH_TAMPERED "$SKR/s3-switch/out" && [ "$(git -C "$SKR/s3-switch/top" rev-parse cx/t1)" = "$(git -C "$SKR/s3-switch/top" rev-parse HEAD)" ] && [ ! -e "$SKR/s3-switch/home/.conductor/gate" ]'
step3_run s3-ok 'printf "b\n" >> f && git commit -qam one && printf "c\n" >> f'
check "[P43] SKILL Step 3 after a well-behaved executor (a commit plus an uncommitted edit): one squashed commit on cx/t1, gated at that exact commit" \
  eval '[ "$(cat "$SKR/s3-ok/rc")" = 0 ] && [ "$(git -C "$SKR/s3-ok/top" rev-list --count cx/t1)" = 2 ] && [ "$(git -C "$SKR/s3-ok/home/.conductor/gate/t1.1" rev-parse HEAD)" = "$(git -C "$SKR/s3-ok/top" rev-parse cx/t1)" ] && [ "$(cat "$SKR/s3-ok/home/.conductor/gate/t1.1/f")" = "$(printf "a\nb\nc")" ]'
# Step 5's ghcp-ci-debug --apply hand-back (it switches $WT to ghcp/ci-fix-<run id> and leaves the
# edits uncommitted): the SKILL's two hand-back lines, then Step 3 again -> the fix is one more
# commit on cx/t1 (no squash into the pushed commit), gated at that commit.
step3_run s3-ci 'printf "b\n" >> f'
CI_HB="$(grep -E '^(F=\$\(git -C "\$WT" symbolic-ref|printf .BASE=%q)' "$SK")"
CI_D="$SKR/s3-ci"
git -C "$CI_D/top" worktree remove --force "$CI_D/home/.conductor/gate/t1.1"
CI_C1="$(git -C "$CI_D/top" rev-parse cx/t1)"
(cd "$CI_D/home/.cx-wt/top-t1" && git switch -q -c ghcp/ci-fix-99 && printf 'fix\n' >> f) > /dev/null 2>&1
(cd "$CI_D/top" && env HOME="$CI_D/home" bash -c '. "$HOME/.conductor/out/t1/vars.sh"'$'\n'"$CI_HB"$'\n'"$STEP3") > "$CI_D/out2" 2>&1; printf '%s' "$?" > "$CI_D/rc2"
check "[P43] SKILL Step 5 after ghcp-ci-debug --apply: the hand-back puts the edits on cx/t1 and drops ghcp/ci-fix-*; Step 3 then commits them on top of the pushed commit (not squashed) and gates that commit (got rc $(cat "$CI_D/rc2"))" \
  eval '[ "$(cat "$CI_D/rc2")" = 0 ] && [ -n "$CI_HB" ] && [ "$(git -C "$CI_D/top" rev-parse cx/t1~1)" = "$CI_C1" ] && ! git -C "$CI_D/top" rev-parse -q --verify ghcp/ci-fix-99 >/dev/null && [ "$(git -C "$CI_D/home/.conductor/gate/t1.1" rev-parse HEAD)" = "$(git -C "$CI_D/top" rev-parse cx/t1)" ] && [ "$(cat "$CI_D/home/.conductor/gate/t1.1/f")" = "$(printf "a\nb\nfix")" ]'
step3_run s3-ci-raw 'printf "b\n" >> f'
git -C "$SKR/s3-ci-raw/top" worktree remove --force "$SKR/s3-ci-raw/home/.conductor/gate/t1.1"
(cd "$SKR/s3-ci-raw/home/.cx-wt/top-t1" && git switch -q -c ghcp/ci-fix-99 && printf 'fix\n' >> f) > /dev/null 2>&1
(cd "$SKR/s3-ci-raw/top" && env HOME="$SKR/s3-ci-raw/home" bash -c "$STEP3") > /dev/null 2>&1; CI_RAW=$?
check "[P43] ... without the hand-back, Step 3 stops with BRANCH_TAMPERED (exit 24), as the finding said" test "$CI_RAW" = 24
PFX_BAD="$("$REAL_PY" -I - "$SK" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
# join continuation lines, then look at every line that runs grok, agy-*, ghcp-* as a command
lines = text.replace("\\\n", " ").split("\n")
G = "env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1"
A = "env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1"
C = "env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL CX_WORKER=1"
bad = []
fence = False
for n, ln in enumerate(lines, 1):
    if ln.strip().startswith("```"):
        fence = not fence
        continue
    if not fence:
        continue
    s = ln.strip()
    if s.startswith("#"):
        continue
    for tool, pre in ((r"\bgrok\s+(?:--prompt-file|-p\b)", G), (r"\bagy-(?:delegate|job)\s+(?!status|result|list|cancel)", A),
                      (r"\bghcp-(?:delegate|job|handoff|ci-debug|cloud)\s+(?!status|result|list|cancel|view)", C)):
        for m in re.finditer(tool, s):
            if pre not in s[:m.start()] and not s[:m.start()].endswith("cx-wsl "):
                bad.append("%d: %s" % (n, s[:120]))
if re.search(r"(?m)^\s*export\s+CX_WORKER", text):
    bad.append("export CX_WORKER")
print("; ".join(bad[:5]))
PY
)"
check "[P43] every grok, agy-delegate/agy-job and ghcp-delegate/ghcp-job/ghcp-handoff/ghcp-ci-debug command line in the SKILL carries its prefix or runs through cx-wsl (which adds it and takes the slot); no export CX_WORKER${PFX_BAD:+: $PFX_BAD}" test -z "$PFX_BAD"
check "[P43] recipe headings in order: Step 1 contract, Step 2 dispatch, Step 3 after-run, Step 4 reviews, Step 5 GitHub, From Windows" \
  test "$(grep -E '^### (Step [0-9][a-e]?|From Windows)' "$SK" | sed -E 's/^### (Step [0-9][a-e]?|From Windows).*/\1/' | tr '\n' ' ')" = "Step 1 Step 2 Step 3 Step 4 Step 5 From Windows "
check "[P43] no ghcp-ci-debug ... --apply without --dir \"\$WT\"" \
  eval '! grep -E "ghcp-ci-debug[^|;]*--apply" "$SK" | grep -vq -- "--dir \"\\\$WT\""'
CUR_BAD="$("$REAL_PY" -I - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
defs = {"CURSOR_WORKER_MSG": 0, "CURSOR_POOL_MSG": 0}
for d, dirs, files in os.walk(root):
    rel = os.path.relpath(d, root)
    dirs[:] = [x for x in dirs if x not in (".git", "docs", "tests", "__pycache__")]
    for f in files:
        r = os.path.normpath(os.path.join(rel, f))
        if r in ("README.md", "CHANGELOG.md"):
            continue
        try:
            text = open(os.path.join(d, f), encoding="utf-8").read()
        except (UnicodeDecodeError, OSError):
            continue
        for n, ln in enumerate(text.split("\n"), 1):
            for name in defs:
                if re.match(r"\s*%s\s*=" % name, ln) and r == "scripts/lib/cxlib.py":
                    defs[name] += 1
            s = re.sub(r"worker-shims/cursor-agent|\bcursor-agent\b|CURSOR_WORKER_MSG|CURSOR_POOL_MSG", "", ln)
            if r == "scripts/lib/cxlib.py" and re.match(r"\s*CURSOR_(WORKER|POOL)_MSG\s*=", ln):
                continue
            if re.search(r"(?i)cursor", s):
                bad.append("%s:%d" % (r, n))
for name, k in defs.items():
    if k != 1:
        bad.append("%s defined %d times in cxlib.py" % (name, k))
print(" ".join(bad[:8]))
PY
)"
check "[P44] no Cursor option, adapter or doctor check: 'cursor' only as worker-shims/cursor-agent and the two constants, each defined once in cxlib.py${CUR_BAD:+: $CUR_BAD}" test -z "$CUR_BAD"
check "[X]   README install line for the plugin directory advice (one step)" grep -Fq 'claude plugin install conductor --marketplace 40chalk/conductor-for-claude-code' "$ROOT/README.md"

# static, init and doctor are joined here, not before the serial sections above (they share no
# state), so those run while the doctor section finishes.
join_section static
join_section init
join_section doctor
join_section slots
join_section adapters
join_section adapters2
join_section adapters-agy
join_section run
join_section run2
join_section runy
join_section runx
join_section job
join_section a25
join_section gbfwd

# ------------------------------------------------------------------ 15. free by construction (section 3.7)
section "free by construction: the stub logs"
ALL_LOGS=("$STUB_LOG" "$TMP/wsl-direct.log" "$TMP/cw.log" "$TMP/slots.log")
for f in "$DOCS"/*/stub.log "$WH"/*.log; do [ -f "$f" ] && ALL_LOGS+=("$f"); done
FREE_BAD="$("$REAL_PY" -I - "${ALL_LOGS[@]}" 2> "$TMP/usage-calls" <<'PY'
import os, re, sys
bad = []
usage_calls = 0
for path in sys.argv[1:]:
    doctor = "/doc/" in path or path.endswith("wsl-direct.log") or os.path.basename(path).startswith(("gbdoc", "win-"))
    for ln in open(path, encoding="utf-8", errors="replace").read().split("\n"):
        if not ln:
            continue
        f = ln.split("\t")
        name = f[0]
        argv = ln.split("\targv:", 1)[1].strip() if "\targv:" in ln else ""
        cwd = f[1][4:] if len(f) > 1 and f[1].startswith("cwd=") else ""
        if name == "BILLABLE":
            bad.append("BILLABLE: " + ln[:160])
        elif name == "copilot":
            if not (argv == "--version" or argv.startswith("-p . --model __cx_doctor_probe__ ")):
                bad.append("copilot: " + argv)
            if argv.startswith("-p") and not cwd.endswith("/probe"):
                bad.append("copilot probe cwd: " + cwd)
        elif name == "grok":
            if argv not in ("--version", "models"):
                bad.append("grok: " + argv)
        elif name == "agy":
            if argv == "-p /usage --output-format json":
                usage_calls += 1
            elif argv not in ("--version", "models", "models --output-format json"):
                bad.append("agy: " + argv)
        elif name == "claude":
            if argv not in ("--version", "auth status --json"):
                bad.append("claude: " + argv)
        elif name == "ghcp-models":
            if not re.search(r"\tcopilot_bin=/", ln):
                bad.append("ghcp-models without an absolute GHCP_COPILOT_BIN: " + ln[:160])
            if doctor and ("refresh=yes" not in ln or not cwd.endswith("/probe")):
                bad.append("ghcp-models (D16) without --refresh or outside the probe dir: " + ln[:160])
print("; ".join(bad[:6]))
print(usage_calls, file=sys.stderr)
PY
)"
check "[P30] no stub logged BILLABLE; copilot saw only --version or the doctor probe (from the probe dir); grok only --version and models; claude only --version and auth status; ghcp-models always an absolute GHCP_COPILOT_BIN and --refresh for D16${FREE_BAD:+: $FREE_BAD}" test -z "$FREE_BAD"
check "[P30] agy saw -p /usage exactly twice (the two --pools --agy-usage runs: pools-usage and scrub)" test "$(cat "$TMP/usage-calls")" = 2
# Wall time is informational: only CX_TEST_STRICT_TIME=1 turns a run over 60 s into a FAIL.
if [ "$STRICT_TIME" = 1 ]; then
  check "[X]   the suite stayed under 60 s ($((SECONDS - T_START)) s so far; CX_TEST_STRICT_TIME=1)" test "$((SECONDS - T_START))" -lt 60
else
  printf 'INFO  the suite took %s s (CX_TEST_STRICT_TIME=1 fails a run over 60 s)\n' "$((SECONDS - T_START))"
fi

# ------------------------------------------------------------------ summary
printf '\nPASS %d  FAIL %d  SKIP %d  (%ss)\n' "$PASS" "$FAIL" "$SKIP" "$((SECONDS - T_START))"
[ "$FAIL" -eq 0 ]
