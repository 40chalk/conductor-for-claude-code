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
# runs the WSL side locally under env -i. Case tags [P1]..[P45] follow DESIGN.md section 14.3;
# [X] checks are extra coverage. The exit status is non-zero on any FAIL.
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
  NUMBER_OF_PROCESSORS ProgramFiles PROGRAMFILES)
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
    [ -n "$cpath" ] && printf ',\n "conductor@conductor-for-claude-code": [{"scope": "user", "installPath": "%s", "version": "0.1.0"}]' "$cpath"
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
  ( __bg_counts="$TMP/sec-$name.counts" PASS=0 FAIL=0 SKIP=0 SEC_TAG=".$name"
    "$fn"
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

# ------------------------------------------------------------------ 1. manifests
section "manifests and versions"
PJ="$ROOT/.claude-plugin/plugin.json" MJ="$ROOT/.claude-plugin/marketplace.json"
check "[P1]  plugin.json and marketplace.json parse; identity, author, repository, license exact; marketplace source ./ and same version" \
  test "$("$REAL_PY" -I - "$PJ" "$MJ" <<'PY'
import json, sys
p = json.load(open(sys.argv[1])); m = json.load(open(sys.argv[2]))
ok = (p["name"] == "conductor" and p["version"] == "0.1.0" and p["license"] == "MIT"
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
check "[P2]  CX_VERSION = plugin.json = marketplace.json = top CHANGELOG heading (0.1.0)" \
  test "$(bash -c '. "$1/scripts/lib/common.sh"; printf %s "$CX_VERSION"' _ "$ROOT")|$(tj get "$PJ" version)|$(tj get "$MJ" plugins.0.version)|$CL_TOP|$("$REAL_PY" -I "$CXLIB" const CURSOR_POOL_MSG >/dev/null && sed -n 's/^VERSION = "\(.*\)"/\1/p' "$CXLIB")" = "0.1.0|0.1.0|0.1.0|0.1.0|0.1.0"
check "[X]   CHANGELOG top heading reads '## 0.1.0 — 2026-11-01'" grep -qx '## 0.1.0 — 2026-11-01' "$ROOT/CHANGELOG.md"
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
for rel in ("scripts/cx-doctor.sh", "scripts/cx-init.sh", "scripts/cx-wsl.sh", "scripts/host/detect.sh",
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
LONGEST = "agy (agy-delegate), then Copilot (ghcp-delegate), then own subagents"
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
    if "(cd DIR && timeout -k 5 60 agy --new-project" not in w:
        bad.append("policy: lacks the inline agy registration")
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
check "[P20] the four policy JSON files parse, are ASCII json.dumps(indent=2), SessionStart, equal their DESIGN blocks; both texts <= 2800 with the longest order and the unattended sentence, {ATTN} once at the end, --new-project, skill-first, background timeout 7200000, --yolo lanes only forbidden, both subagents forbidden, --github not a triage lane, Git Bash: every command via cx-wsl${P20_BAD:+: $P20_BAD}" test -z "$P20_BAD"
DEF_ORDER='agy (agy-delegate), then Copilot (ghcp-delegate), then own subagents'
COP_ORDER='Copilot (ghcp-delegate), then agy (agy-delegate), then own subagents'
pol() { run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY -u CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER "$@" bash "$POLICY"; }
pol_is() {  # FILE PHRASE [attn]: stdout is exactly FILE with {ORDER} = PHRASE (and {ATTN}), stderr empty, rc 0
  rc_is 0 && err_empty && [ "$(cat "$O"; printf x)" = "$(blocks_py expect "$1" "$2" ${3:+"$3"}; printf x)" ] && out_lacks '{ORDER}' && out_lacks '{ATTN}'
}
pol
check "[P21] order unset -> the default phrase; output = policy-context.json exactly" pol_is policy-context.json "$DEF_ORDER"
check "[X]   the printed policy is valid JSON with the rendered order" eval 'tj isjson "$O" && tj get "$O" hookSpecificOutput.additionalContext | grep -Fq "in order: $DEF_ORDER."'
pol CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=copilot,agy
check "[P21] copilot,agy -> Copilot first" pol_is policy-context.json "$COP_ORDER"
pol CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=' COPILOT, AGY '
check "[P21] ' COPILOT, AGY ' -> Copilot first (trimmed, lowercased)" pol_is policy-context.json "$COP_ORDER"
pol CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=copilot
check "[P21] copilot -> 'Copilot (ghcp-delegate), then own subagents'" pol_is policy-context.json 'Copilot (ghcp-delegate), then own subagents'
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
check "[X]   claude,agy -> 'own subagents, then agy (agy-delegate)'" pol_is policy-context.json 'own subagents, then agy (agy-delegate)'
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
crlf_copy "$TMP/crlf-hooks" hooks/policy.sh hooks/hooks.json hooks/policy-context.json hooks/policy-context-gitbash.json hooks/policy-context-crlf.json
run env -u CX_WORKER -u CLAUDE_PLUGIN_OPTION_POLICY bash "$TMP/crlf-hooks/hooks/policy.sh"
check "[P22] a CRLF copy of hooks/: exit 0, empty stderr, stdout parses with the same additionalContext" \
  eval 'rc_is 0 && err_empty && [ "$(blocks_py ctx "$O" policy)" = True ]'
run env -u CX_WORKER CLAUDE_PLUGIN_OPTION_POLICY=off bash "$TMP/crlf-hooks/hooks/policy.sh"
check "[P22] ... with the option off: nothing" eval 'rc_is 0 && out_empty && err_empty'
run env -u CX_WORKER CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER=copilot,agy bash "$TMP/crlf-hooks/hooks/policy.sh"
check "[X]   ... and the order still renders" eval 'tj get "$O" hookSpecificOutput.additionalContext | grep -Fq "in order: $COP_ORDER."'
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
  eval '[ -n "$CRLF_FIND" ] && pol_is policy-context.json "$DEF_ORDER" && [ "$(bash "$TMP/crlf-all-fixed/bin/cx-doctor" --version 2>/dev/null)" = "cx-doctor 0.1.0" ]'
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
  case "$t" in *"Workflows (ultracode too)"*"isolation worktree or remote"*"one agy run at a time on this computer"*) ;; *) P57_BAD="$P57_BAD [$f: Workflows line]" ;; esac
done
grep -Fq 'file tools on its wsl.localhost path, commands via cx-wsl bash -c), never with isolation' "$ROOT/hooks/policy-context-gitbash.json" || P57_BAD="$P57_BAD [gitbash: wsl.localhost + cx-wsl bash -c]"
check "[P57] {ATTN}: CLAUDE_CODE_SESSION_ATTENDED=0 -> both variants end with the unattended sentence; 1, empty or 0 in a bridge child -> none; never {ATTN} or {ORDER} in the output; both texts carry the Workflows line (isolation, one agy run at a time), Git Bash: file tools on the wsl.localhost path, commands via cx-wsl bash -c${P57_BAD:+:$P57_BAD}" test -z "$P57_BAD"

# ------------------------------------------------------------------ 7. worker shims (section 11)
section "worker shims"
SHIMS=(claude copilot grok agy codex gemini cursor-agent agent)
check "[P24] exactly the 8 shims" test "$(cd "$ROOT/worker-shims" && find . -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" = "$(printf '%s\n' "${SHIMS[@]}" | LC_ALL=C sort | tr '\n' ' ')"
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

sec_static() {
# ------------------------------------------------------------------ 8. static checks (section 3)
section "static checks: syntax, shellcheck, line endings, conventions, shipped files"
mapfile -t SH_FILES < <(cd "$ROOT" && find . -path ./.git -prune -o -type f -name '*.sh' -print | sed 's|^\./||' | LC_ALL=C sort)
mapfile -t BASH_FILES < <(cd "$ROOT" && { printf '%s\n' "${SH_FILES[@]}"; ls bin/* worker-shims/* 2>/dev/null; for f in tests/stubs/* tests/stubs/gitbash/*; do [ -f "$f" ] && printf '%s\n' "$f"; done; } | LC_ALL=C sort -u)
SYN_BAD=""
for f in "${BASH_FILES[@]}"; do bash -n "$ROOT/$f" 2>/dev/null || SYN_BAD="$SYN_BAD $f"; done
check "[P38] every shell file passes bash -n (${#BASH_FILES[@]} files)${SYN_BAD:+:$SYN_BAD}" test -z "$SYN_BAD"
if command -v shellcheck >/dev/null 2>&1; then
  SC_OUT="$(cd "$ROOT" && shellcheck -x "${SH_FILES[@]}" 2>&1)"
  check "[P38] shellcheck -x is clean on every *.sh${SC_OUT:+: $(printf '%s' "$SC_OUT" | grep -m3 -E '^In |SC[0-9]+' | tr '\n' ' ')}" test -z "$SC_OUT"
  mapfile -t STUB_FILES < <(cd "$ROOT" && find tests/stubs -type f | LC_ALL=C sort)
  SC_OUT="$(cd "$ROOT" && { shellcheck -x -e SC1007 bin/*; shellcheck -x worker-shims/*; shellcheck -x -s bash "${STUB_FILES[@]}"; } 2>&1)"
  check "[X]   shellcheck is clean on bin/* (SC1007 is the spec's CDPATH= text), worker-shims/* and the stubs${SC_OUT:+: $(printf '%s' "$SC_OUT" | grep -m3 -E '^In |SC[0-9]+' | tr '\n' ' ')}" test -z "$SC_OUT"
else
  skip "[P38] shellcheck" "shellcheck not installed"
fi
check "[P38] cxlib.py compiles (python3 -I, without writing __pycache__)" \
  "$REAL_PY" -I - "$CXLIB" <<'PY'
import sys
compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")
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
for d in ("bin", "scripts", "scripts/lib", "scripts/host", "hooks", "worker-shims", "tests", "tests/stubs", "tests/stubs/gitbash"):
    p = os.path.join(root, d)
    if not os.path.isdir(p):
        continue
    for f in sorted(os.listdir(p)):
        q = os.path.join(p, f)
        if os.path.isfile(q) and (f.endswith(".sh") or d in ("bin", "worker-shims", "tests/stubs", "tests/stubs/gitbash")) and not f.startswith("."):
            scripts.append(os.path.relpath(q, root))
pyfiles = ["scripts/lib/cxlib.py"]
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
    { rc_is 0 && [ "$(cat "$O")" = "$b 0.1.0" ]; } || HV_BAD="$HV_BAD $f${gb:+(gitbash)}(--version)"
    run env STUB_UNAME_S="$gb" bash "$ROOT/$f" --help
    { rc_is 0 && [ "$(cat "$O")" = "$(hdr "$src")" ] && [ -s "$O" ]; } || HV_BAD="$HV_BAD $f${gb:+(gitbash)}(--help)"
  done
  run bash "$ROOT/$f" -h
  [ "$(cat "$O")" = "$(hdr "$src")" ] || HV_BAD="$HV_BAD $f(-h)"
done
check "[P40] --help prints the header and --version prints '<prog> 0.1.0' (also on Git Bash, answered locally)${HV_BAD:+:$HV_BAD}" test -z "$HV_BAD"
SHIM_BAD=""
for b in cx-doctor cx-init cx-wsl; do
  f="$ROOT/bin/$b"
  { [ -f "$f" ] && [ ! -L "$f" ] && [ -x "$f" ]; } || { SHIM_BAD="$SHIM_BAD $b(file)"; continue; }
  [ "$(cat "$f")" = "$(printf '#!/usr/bin/env bash\n# Plugin bin/ entry point (Claude Code puts bin/ on the Bash tool'"'"'s PATH); forwards to scripts/%s.sh.\nexec "$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/scripts/%s.sh" "$@"' "$b" "$b")" ] || SHIM_BAD="$SHIM_BAD $b(text)"
  out="$(cd "$ROOT" && CDPATH=. bash -c 'export CDPATH; bin/'"$b"' --version' 2>&1)"
  [ "$out" = "$b 0.1.0" ] || SHIM_BAD="$SHIM_BAD $b(relative+CDPATH=.: $out)"
done
check "[P40] bin shims: exactly the 3-line text, not symlinks, executable, work from a relative path with CDPATH=. exported${SHIM_BAD:+:$SHIM_BAD}" test -z "$SHIM_BAD"
SHIPPED="$("$REAL_PY" -I - "$ROOT/docs/DESIGN.md" <<'PY'
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
sec = text.split("### 13.4 Shipped file list (Phase 1)", 1)[1].split("## 14.", 1)[0]
lst = sec.split("Executable:", 1)[0]
files = [f for f in re.findall(r"`([^`]+)`", lst) if "*" not in f]
files += ["worker-shims/" + n for n in ("claude", "copilot", "grok", "agy", "codex", "gemini", "cursor-agent", "agent")]
print("\n".join(sorted(set(files))))
PY
)"
D3_LIST="$(bash -c '. "$1/scripts/lib/common.sh"; printf "%s\n" "${CX_SHIPPED_FILES[@]}"' _ "$ROOT" | LC_ALL=C sort)"
MISSING_FILES=""
while IFS= read -r f; do [ -f "$ROOT/$f" ] || MISSING_FILES="$MISSING_FILES $f"; done <<< "$SHIPPED"
check "[P41] every file of the section 13.4 list exists${MISSING_FILES:+ (missing:$MISSING_FILES)}" test -z "$MISSING_FILES"
check "[P41] the doctor's D3 list (CX_SHIPPED_FILES) equals section 13.4 ($(printf '%s\n' "$SHIPPED" | wc -l) files)" test "$D3_LIST" = "$(printf '%s\n' "$SHIPPED" | LC_ALL=C sort)"
EXEC_WANT="$(printf '%s\n' "$SHIPPED" | grep -E '^(bin/|scripts/[^/]+\.sh$|scripts/host/[^/]+\.sh$|hooks/[^/]+\.sh$|worker-shims/)' | LC_ALL=C sort)"
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
bg_section init sec_init

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
DOCTOR="$RTH/runtime/0.1.0/bin/cx-doctor" doc_bg rt-installed CX_HOME="$RTH" CX_FORWARDED=1 CLAUDE_CONFIG_DIR="$RT_CFG" -- --no-record
DOCTOR="$RTH/runtime/0.1.0/bin/cx-doctor" doc_bg rt-none CX_HOME="$RTH" CX_FORWARDED=1 CLAUDE_CONFIG_DIR="$RT_CFG2" -- --no-record
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
  CLAUDE_CODE_ENTRYPOINT=claude-desktop CLAUDE_CODE_DESKTOP_APP_VERSION=1.5.0 -- --no-record
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
  eval 'head -n 1 "$O" | grep -q "^conductor doctor 0.1.0: host linux" && out_has "Logins (free probes)" && d_ok D9 "copilot 1.0.105" && d_ok D10 "grok 1.0.70" && d_ok D16 "copilot is logged in" && d_ok D17 "grok is logged in" && d_ok D18 "agy is logged in" && d_ok D19 && d_ok D13 && d_ok D21 && d_ok D22 && d_ok D24 && grep -q "^Summary: [0-9]* ✓, [0-9]* !, 0 ✗$" "$O"'
check "[P25] stderr: CX_HOST, then CX_DOCTOR (with the record path)" \
  eval 'tj linejson "$E" CX_HOST && line_is CX_HOST host linux && line_is CX_DOCTOR record "$DHOME/hosts/$(tj line "$E" CX_HOST hostkey).json"'
REC_F="$DHOME/hosts/$(tj line "$E" CX_HOST hostkey 2>/dev/null).json"
check "[P25] host record: absolute bins (wrappers from the fake installPaths, the user-scoped ghcp entry)" \
  test "$("$REAL_PY" -I - "$REC_F" "$TMP" "$STUBS" <<'PY'
import json, sys
r = json.load(open(sys.argv[1])); tmp, stubs = sys.argv[2], sys.argv[3]
b = r["bin"]
print(r["version"] == 1 and r["plugin_version"] == "0.1.0" and r["host"] == "linux" and r["path_source"] == "interactive"
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
doc_use green-json
check "[P25] --no-record writes nothing (no hosts/ dir), CX_DOCTOR record null" eval '[ ! -e "$DHOME/hosts" ] && line_is CX_DOCTOR record null'
check "[P33] --json parses and matches section 8.7 (keys, statuses in the enum), same exit as text mode (0)" \
  test "$("$REAL_PY" -I - "$O" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ok = (list(d) == ["version", "plugin_version", "host", "caller", "session", "attended", "checks", "pools", "record", "summary"]
      and d["session"] == "local" and d["attended"] is None
      and d["version"] == 1 and d["plugin_version"] == "0.1.0" and d["pools"] is None and d["record"] is None
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
  eval 'rc_is 0 && line_is CX_RUNTIME changed true && [ -f "$DHOME/runtime/0.1.0/RUNTIME_STAMP" ] && grep -qx "source=$ROOT" "$DHOME/runtime/0.1.0/RUNTIME_STAMP"'
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
  eval 'd_info D25 "autonomy allow rule(s) missing" && d_info D25 "Bash(ghcp-delegate:*)" && ! d_warn D25'
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
check "[P27] forwarded: D25 reads CX_WIN_SETTINGS and lists Bash(cx-wsl:*) (not the executor-host rules)" \
  eval 'd_info D25 "Bash(cx-wsl:*)" && d_info D25 "the Windows-side settings" && ! d_info D25 "Bash(ghcp-delegate:*)"'
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
check "[P51] D30 bridge (a remote-control thread in WSL): a Remote Control child, agy one job at a time across threads and sessions (no shared pool slots in Phase 1); never unattended; no desktop WSL-session warning; 3 CPUs -> concurrency 2" \
  eval 'd_info D30 "session bridge" && d_info D30 "run agy jobs one at a time across every thread and session on this computer" && ! d_info D30 "unattended" && ! d_warn D30 "desktop app session" && line_is CX_DOCTOR session bridge && line_is CX_DOCTOR attended null && d_info D32 "workflow concurrency 2 agents"'
doc_use s-blockers
check "[P51] D31: each blocker (env CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC, settings env DISABLE_GROWTHBOOK, disableRemoteControl, claude 2.1.279, a gateway ANTHROPIC_BASE_URL, ANTHROPIC_API_KEY) is an info line; the doctor still exits 0" \
  eval 'rc_is 0 && d_info D31 "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC is set (environment)" && d_info D31 "DISABLE_GROWTHBOOK is set (user settings" && d_info D31 "disableRemoteControl is true" && d_info D31 "claude 2.1.279 is older than 2.1.280" && d_info D31 "ANTHROPIC_BASE_URL=https://gw.example (environment)" && d_info D31 "ANTHROPIC_API_KEY is set" && ! d_info D31 "prerequisites met" && ! grep -Eq "^  [!$FAILG] .*\[D3[012]\]$" "$O"'
check "[P59] ultracode true in user settings -> on for new sessions (user settings)" d_info D32 "ultracode on for new sessions (user settings"
doc_use s-wsl
check "[P51] a desktop app session in WSL (entrypoint claude-desktop): ! D30 plugins are not loaded there, with the Windows-folder / WSL terminal / remote-control fix" \
  eval 'd_warn D30 "Claude desktop app session opened on a WSL folder" && out_has "fix: open the repo in a desktop session on a Windows folder" && out_has "claude remote-control from a WSL terminal"'
}
bg_section doctor sec_doctor

# ------------------------------------------------------------------ 11. runtime copy (section 7.5)
section "install-runtime.sh: subset, exec bits, CR handling, idempotence, concurrency"
RSRC="$TMP/rt-src"
mkdir -p "$RSRC"
(cd "$ROOT" && cp -R .claude-plugin bin scripts hooks worker-shims templates skills commands docs tests "$RSRC/")
chmod a-x "$RSRC"/bin/* "$RSRC"/scripts/*.sh "$RSRC"/scripts/host/*.sh "$RSRC"/worker-shims/*
printf 'line one\r\nline two\r\n' > "$RSRC/templates/crlf-note.txt"
irt() { run env CX_HOME="$1" bash "$RSRC/scripts/host/install-runtime.sh" --from "$RSRC"; }
irt "$TMP/rt1"
RT1="$TMP/rt1/runtime/0.1.0"
check "[P18] first install: exit 0, CX_RUNTIME changed true with the CRLF file counted, current -> 0.1.0" \
  eval 'rc_is 0 && line_is CX_RUNTIME changed true && line_is CX_RUNTIME version 0.1.0 && line_is CX_RUNTIME path "$RT1" && line_is CX_RUNTIME stripped_cr 1 && [ "$(readlink "$TMP/rt1/runtime/current")" = 0.1.0 ] && no_signal'
check "[P18] copies only the six directories (plus RUNTIME_STAMP): no tests, docs, skills or commands" \
  test "$(cd "$RT1" && find . -mindepth 1 -maxdepth 1 -printf '%f\n' | LC_ALL=C sort | tr '\n' ' ')" = ".claude-plugin RUNTIME_STAMP bin hooks scripts templates worker-shims "
check "[P18] exec bits: bin/*, scripts/**/*.sh, scripts/lib/*.py, hooks/*.sh, worker-shims/* are 0755" \
  eval '( for f in "$RT1"/bin/* "$RT1"/scripts/*.sh "$RT1"/scripts/host/*.sh "$RT1"/scripts/lib/*.py "$RT1"/hooks/policy.sh "$RT1"/worker-shims/*; do [ "$(stat -c %a "$f")" = 755 ] || exit 1; done )'
check "[P18] CRs before LF are stripped; RUNTIME_STAMP has version, installed_at, source and sha256" \
  eval '! grep -rq $'"'"'\r'"'"' "$RT1" && grep -qx "version=0.1.0" "$RT1/RUNTIME_STAMP" && grep -q "^installed_at=20[0-9-]*T[0-9:]*Z$" "$RT1/RUNTIME_STAMP" && grep -qx "source=$RSRC" "$RT1/RUNTIME_STAMP" && grep -Eq "^sha256=[0-9a-f]{64}$" "$RT1/RUNTIME_STAMP"'
SHA1="$(sed -n 's/^sha256=//p' "$RT1/RUNTIME_STAMP")"
irt "$TMP/rt1"
check "[P18] identical reinstall: changed false, same tree" eval 'rc_is 0 && line_is CX_RUNTIME changed false && [ "$(sed -n "s/^sha256=//p" "$RT1/RUNTIME_STAMP")" = "$SHA1" ]'
printf '\nnew line\n' >> "$RSRC/templates/repo-bundle/AGENTS.md"
irt "$TMP/rt1"
check "[P18] a changed source replaces the copy and moves current; no old copy or tmp dir left" \
  eval 'rc_is 0 && line_is CX_RUNTIME changed true && tail -n 1 "$RT1/templates/repo-bundle/AGENTS.md" | grep -qx "new line" && [ "$(readlink "$TMP/rt1/runtime/current")" = 0.1.0 ] && [ "$(cd "$TMP/rt1/runtime" && find . -mindepth 1 -maxdepth 1 -printf "%f\n" | LC_ALL=C sort | tr "\n" " ")" = ".install.lock 0.1.0 current " ]'
SHA2="$(sed -n 's/^sha256=//p' "$RT1/RUNTIME_STAMP")"
printf 'a\rb\n' > "$RSRC/templates/midline-cr.txt"
irt "$TMP/rt1"
check "[P18] a mid-line CR -> exit 44 CRLF_CORRUPT, the old runtime stays" \
  eval 'rc_is 44 && one_signal CRLF_CORRUPT && [ "$(sed -n "s/^sha256=//p" "$RT1/RUNTIME_STAMP")" = "$SHA2" ] && [ ! -e "$RT1/templates/midline-cr.txt" ] && [ -z "$(cd "$TMP/rt1/runtime" && find . -maxdepth 1 -name ".tmp.*")" ]'
rm -f -- "$RSRC/templates/midline-cr.txt"
( env CX_HOME="$TMP/rt2" bash "$RSRC/scripts/host/install-runtime.sh" --from "$RSRC" > "$TMP/rt2a.out" 2> "$TMP/rt2a.err" ) &
p1=$!
( env CX_HOME="$TMP/rt2" bash "$RSRC/scripts/host/install-runtime.sh" --from "$RSRC" > "$TMP/rt2b.out" 2> "$TMP/rt2b.err" ) &
p2=$!
wait "$p1"; r1=$?; wait "$p2"; r2=$?
CH="$(tj line "$TMP/rt2a.err" CX_RUNTIME changed) $(tj line "$TMP/rt2b.err" CX_RUNTIME changed)"
check "[P18] two concurrent installs of one source: one changed true, one changed false, one clean tree" \
  eval '[ "$r1$r2" = 00 ] && { [ "$CH" = "true false" ] || [ "$CH" = "false true" ]; } && [ ! -e "$TMP/rt2/runtime/0.1.0/0.1.0" ] && [ -z "$(find "$TMP/rt2/runtime/0.1.0" -mindepth 1 -maxdepth 1 -name ".tmp.*" -o -mindepth 1 -maxdepth 1 -name "0.1.0")" ] && [ "$(cd "$TMP/rt2/runtime" && find . -mindepth 1 -maxdepth 1 -printf "%f\n" | LC_ALL=C sort | tr "\n" " ")" = ".install.lock 0.1.0 current " ]'
run env CX_HOME="$TMP/rt3" bash "$RSRC/scripts/host/install-runtime.sh" --from "$TMP/not-a-plugin"
check "[X]   --from a directory without scripts/lib/common.sh -> exit 1" eval 'rc_is 1 && no_signal'
run env CX_HOME="$TMP/rt3" bash "$RSRC/scripts/host/install-runtime.sh" --bogus
check "[X]   unknown argument -> exit 1" rc_is 1
mkdir -p "$TMP/irmnt/s" "$TMP/irboot"; ln -s "$RSRC" "$TMP/irmnt/s/src"; : > "$TMP/irboot/main"
(cd "$TMP/irboot" && env CX_HOME="$TMP/rt4" CX_MNT_ROOT="$TMP/irmnt/" CX_STAGE_WIN='S:\src' bash -s < "$RSRC/scripts/host/install-runtime.sh" > "$TMP/irboot.out" 2> "$TMP/irboot.err"); RC=$?
O="$TMP/irboot.out" E="$TMP/irboot.err"
check "[P18] bootstrap (bash -s with CX_STAGE_WIN) from a cwd holding a file named main: installs from the stage, not from the cwd's parent" \
  eval 'rc_is 0 && out_has "from Git Bash" && line_is CX_RUNTIME changed true && [ -f "$TMP/rt4/runtime/0.1.0/RUNTIME_STAMP" ]'

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
cat > "$WT/.conductor/runtime/0.1.0/scripts/cx-gate.sh" <<'SH'
#!/usr/bin/env bash
env > "$HOME/target.env"
pwd > "$HOME/target.pwd"
printf '%s\0' "$@" > "$HOME/target.argv"
[ "${1-}" = --stdin ] && cat > "$HOME/target.stdin"
[ "${1-}" = --exit ] && exit "$2"
[ "${1-}" = --sleep ] && exec sleep "$2"
exit 0
SH
chmod 0755 "$WT/.conductor/runtime/0.1.0/scripts/cx-gate.sh"
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
gb_use() { O="$WH/$1.out"; E="$WH/$1.err"; RC="$(cat "$WH/$1.rc" 2>/dev/null)"; GLOG="$WH/$1.gb.log"; WLOG="$WH/$1.log"; WHOME="$WH/$1"; }
fwd_dir() { sed -n 's/^forward-wsl: CX_DEBUG=1: keeping the transport directory //p' "$E" | tail -n 1; }
REPO_W="$WIN/c/proj/repo"
mkdir -p "$REPO_W"; git -C "$REPO_W" init -q; printf '{"name": "r", "scripts": {"test": "node t.js"}}\n' > "$REPO_W/package.json"
printf '* text=auto eol=lf\n' > "$REPO_W/.gitattributes"; commit_all "$REPO_W"
WEIRD=$'-x sp ace "dq" \'sq\' $HOME back\\slash\nnew line é—✓ *?[] ;|&'
# --- P17: an empty WSL home (no runtime copy): three calls in a row, in the background
wsl_clone rt-none --no-runtime > /dev/null
pool_go
( GB_HOME=rt-none gb p17a CX_NO_AUTO_INSTALL=1 -- "$INIT" --dry-run
  GB_HOME=rt-none GB_CWD="$REPO_W" gb p17b -- "$INIT" --dry-run --json
  cp "$WH/rt-none/.conductor/runtime/0.1.0/RUNTIME_STAMP" "$WH/p17.stamp" 2>/dev/null
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
sed -i 's/^CX_VERSION=0\.1\.0$/CX_VERSION=0.0.9/' "$WH/mismatch/.conductor/runtime/0.1.0/scripts/lib/common.sh"
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
check "[P50] Git Bash doctor in a bridge child: W10 reports bridge (one agy job at a time) and the desktop version; the WSL side prints no D30 and no D32; the header and CX_DOCTOR say session bridge" \
  eval 'rc_is 0 && d_info W10 "session bridge (entrypoint unset, desktop app 1.5.0)" && d_info W10 "run agy jobs one at a time" && d_none D30 && d_none D32 && out_has "caller gitbash, session bridge" && line_is CX_DOCTOR session bridge'
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
  eval 'rc_is 41 && one_signal RUNTIME_MISSING && err_has "forward-wsl: no conductor runtime 0.1.0"'
gb_use p17b
check "[P17] an empty WSL home: the first call installs (installed true, stamp, current link) and succeeds" \
  eval 'rc_is 0 && line_is CX_FORWARD installed true && [ -f "$WH/p17.stamp" ] && [ "$(readlink "$WH/rt-none/.conductor/runtime/current")" = 0.1.0 ] && outj_is detected.test "npm test" && line_is CX_RUNTIME changed true && no_signal'
check "[X]   the bootstrap install crossed only CX_STAGE_WIN (WSLENV) and ran bash -s, not a path on the command line" \
  eval 'grep -q "^wsl.exe	.*crossed=CX_STAGE_WIN	.*argv: --cd \\\\~ --exec /bin/bash --noprofile --norc -s$" "$GLOG"'
gb_use p17c
check "[P17] the second call does not reinstall (installed false, same stamp)" \
  eval 'rc_is 0 && line_is CX_FORWARD installed false && cmp -s "$WH/rt-none/.conductor/runtime/0.1.0/RUNTIME_STAMP" "$WH/p17.stamp" && ! err_has CX_RUNTIME'
gb_use argv
ARGV_F="$(fwd_dir)/argv"
check "[P13] argv fidelity: detected.test equals WEIRD byte for byte (spaces, quotes, \$HOME, backslash, newline, non-ASCII, leading -)" \
  eval 'rc_is 0 && [ "$(out_json detected.test)" = "$WEIRD" ]'
check "[P13] --lint '' arrives as an empty argument (-> null)" outj_is detected.lint null
check "[P13] CX_DEBUG=1 keeps the argv file: it equals printf '%s\\0' of the arguments" \
  eval '[ -f "$ARGV_F" ] && cmp -s "$ARGV_F" <(printf "%s\0" --dry-run --json --test "$WEIRD" --lint "")'
check "[P13] CX_DEBUG=1 prints the wsl.exe argv; it carries only fixed text (no user argument)" \
  eval 'err_has "forward-wsl: wsl.exe argv: wsl.exe --cd" && grep "^wsl.exe	" "$GLOG" | grep -v -- "--list\|-l " | grep -q "argv: --cd \\\\~ --exec /bin/bash --noprofile --norc .conductor/runtime/0.1.0/scripts/host/wsl-entry.sh$" && ! grep "^wsl.exe	" "$GLOG" | grep -q "sp ace"'
check "[P13] every Windows path in meta came from cygpath -w -l" \
  eval '! grep "^cygpath	" "$GLOG" | grep "argv: -w" | grep -qv "argv: -w -l " && grep -q "^cygpath	.*argv: -w -l " "$GLOG" && grep -qx "cwd_win=C:\\\\proj\\\\repo" "$(fwd_dir)/meta"'
check "[X]   meta: v=1, cmd, version, caller=gitbash, distro=auto, installed=0" \
  eval 'M="$(fwd_dir)/meta"; grep -qx v=1 "$M" && grep -qx cmd=cx-init "$M" && grep -qx version=0.1.0 "$M" && grep -qx caller=gitbash "$M" && grep -qx distro=auto "$M" && grep -qx installed=0 "$M" && grep -qx "win_settings=" "$M"'
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
check "[P15] ... cx-doctor runs from \$HOME with cwd null" eval 'rc_is 0 && line_is CX_FORWARD cwd null && [ "$(cat "$O")" = "cx-doctor 0.1.0" ]'
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
  eval 'rc_is 41 && one_signal RUNTIME_MISSING && err_has "wsl-entry: forwarded by conductor 0.1.0"'
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
  eval 'rc_is 0 && line_is CX_RUNTIME changed true && [ -f "$WH/gb-install/.conductor/runtime/0.1.0/RUNTIME_STAMP" ] && no_signal'
gb_use win-green
check "[P34] --windows: W1 ok, W2 takes the * row from the UTF-16LE fixture (multi-word STATE), W3 drive cwd info (no \\\\wsl.localhost advice), W4, W8 cx-doctor 0.1.0" \
  eval 'd_ok W1 "timeout is GNU coreutils" && d_ok W2 "default WSL distribution Ubuntu (WSL2)" && d_info W3 "Windows drive" && d_info W3 "not a desktop session opened on" && d_warn W4 && d_ok W8 "forwarding works: cx-doctor 0.1.0"'
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

join_section static
join_section init
join_section doctor

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
  { rc_is 0 && [ "$(cat "$O")" = "$b 0.1.0" ]; } || P49_BAD="$P49_BAD [$b --version]"
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
for w in ("Work locally", "these win", "every thread", "one job at a time across all threads", "ghcp-cloud", "Claude alone",
          "my own messages", "coordinator brief", "Phase 2"):
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
check "[P52] templates/projects-instructions.md: equals the section 9.6 block, ASCII, LF, <= 2000 characters, every thread Work locally, these win, agy one job at a time across threads until Phase 2, executors' own clouds (ghcp-cloud), a cloud thread uses Claude alone; the SKILL subsection; README says where to paste it${P52_BAD:+: $P52_BAD}" test -z "$P52_BAD"
P62_BAD=""
for v in "${ISO_VARS[@]}"; do
  [ -z "$(bash -c 'printf "%s" "${!1+set}"' _ "$v")" ] || P62_BAD="$P62_BAD $v"
done
check "[P62] the suite's environment has none of the session, attended, Work locally and workflow variables (${#ISO_VARS[@]} names)${P62_BAD:+:$P62_BAD}" test -z "$P62_BAD"
P62_BAD="$(cd "$ROOT" && grep -rnE 'CLAUDE_PROJECT_DIR|CLAUDE_CODE_VERSION|CLAUDE_CODE_ENTRYPOINT' bin scripts \
  | grep -v 'ep="${CLAUDE_CODE_ENTRYPOINT:-}" dv="${CLAUDE_CODE_DESKTOP_APP_VERSION:-}"' | grep -v 'case "${CLAUDE_CODE_ENTRYPOINT:-}:${CLAUDE_CODE_DESKTOP_APP_VERSION:-}" in' | head -n 3)"
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
for w in ("Precedence", "user's own messages", "Projects", "coordinator", "one\n  agy job at a time", "reply tool"):
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
for s in 'agy-delegate --model claude-opus-5-5-high' 'ghcp-delegate --model claude-opus-5.5 --effort high' '--new-project' 'timeout -k 5 60 agy' '--no-subagents' '--test-cmd'; do
  grep -Fq -- "$s" "$SK" || SK_BAD="$SK_BAD [$s]"
done
check "[P43] SKILL contains the section 12.2 commands verbatim${SK_BAD:+ (missing:$SK_BAD)}" test -z "$SK_BAD"
# Every non-comment line of every bash block in DESIGN section 12.2 appears in the SKILL verbatim
# (the SKILL copies 12.2; a drifted Step 3 once committed and gated after SPEC_TAMPERED).
SYNC_BAD="$("$REAL_PY" -I - "$ROOT/docs/DESIGN.md" "$SK" <<'PY'
import sys
design = open(sys.argv[1], encoding="utf-8").read()
sec = design.split("### 12.2 Phase 1 lane commands", 1)[1].split("### 12.3", 1)[0]
skill = set(ln.rstrip() for ln in open(sys.argv[2], encoding="utf-8").read().split("\n"))
bad, n = [], 0
for blk in sec.split("```bash\n")[1:]:
    for ln in blk.split("\n```", 1)[0].split("\n"):
        if not ln.strip() or ln.strip().startswith("#"):
            continue
        n += 1
        if ln.rstrip() not in skill:
            bad.append(ln.strip()[:90])
if n < 40:
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
bad, seen = [], 0
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
            hit = (re.fullmatch(r"ghcp-(delegate|job|handoff|ci-debug|cloud)|agy-(delegate|job|media)|agy-handoff|agy|grok", w)
                   or (w == "git" and "push" in c) or (w == "gh" and len(c) > i + 1 and c[i + 1] in ("pr", "api", "issue", "repo"))
                   or w == ".")
            if not hit:
                continue
            seen += 1
            s = norm(c)
            if not any(s == p or s.startswith(p + " ") or (part and s.startswith(p)) for p, part in prefixes):
                bad.append(s[:100])
if seen < 25:
    bad.append("only %d executor/GitHub commands found" % seen)
print(" | ".join(bad[:4]))
PY
)" || D25_BAD="the checker failed"
check "[P43] every executor and GitHub simple command in the SKILL's bash blocks (vars.sh line, prefixed wrappers, raw agy/grok, git push, gh pr) matches a D25 allow rule; no gh/git in a (cd ... && ...) subshell${D25_BAD:+ (unmatched: $D25_BAD)}" test -z "$D25_BAD"
# Lanes that always pass --yolo (agy-handoff, agy-media, /antigravity:research) are never run
# by a SKILL code block nor listed as a read-only lane; cx-wsl refuses agy-media (P45).
check "[P43] no SKILL code block runs agy-media, agy-handoff, /antigravity:research or --yolo; their lane row is not marked read-only (Writes: no)" \
  eval '! awk "/^\`\`\`bash/{f=1;next} /^\`\`\`/{f=0} f" "$SK" | grep -Eq "agy-media|agy-handoff|antigravity:research|--yolo|--dangerously-skip-permissions" && ! grep -E "^\| \`agy-media\` " "$SK" | grep -q "| no |"'
check "[P43] the SKILL names the background-call timeout (timeout: 7200000) in its rules for every call" \
  eval 'sed -n "/^### Rules for every call/,/^### Step 1/p" "$SK" | grep -q "timeout: 7200000"'
# The SKILL's own snapshot (trees) and Step 3 code, run in a scratch repo.
SKR="$TMP/skillrun"; mkdir -p "$SKR/home/.conductor/out/t1" "$SKR/home/.cx-wt"
git init -q "$SKR/top"; printf 'a\n' > "$SKR/top/f"; git -C "$SKR/top" add f; git -C "$SKR/top" commit -qm i
TREES_LINE="$(grep -m1 '^trees() {' "$SK")"
git -C "$SKR/top" worktree add -q -b cx/t0 "$SKR/home/.cx-wt/top-t0"
git -C "$SKR/top" worktree add -q -b cx/t1 "$SKR/home/.cx-wt/top-t1"
TR_OUT="$(cd "$SKR" && env HOME="$SKR/home" TOP="$SKR/top" WT="$SKR/home/.cx-wt/top-t1" bash -c "$TREES_LINE"'
  trees > before; printf "x\n" >> "$WT/f"; printf "y\n" > "$WT/new"; trees > a1; cmp -s before a1 && echo own-ok
  printf "z\n" >> "$HOME/.cx-wt/top-t0/f"; trees > a2; cmp -s a1 a2 || echo other-wt
  printf "w\n" >> "$TOP/f"; trees > a3; printf "v\n" >> "$TOP/f"; trees > a4; cmp -s a3 a4 || echo second-edit' 2>&1 | tr '\n' ' ')"
check "[P43] the SKILL's trees snapshot ignores \$WT, flags a write in a previous task's worktree and a second edit to an already-modified file in the main checkout" \
  test "$TR_OUT" = "own-ok other-wt second-edit "
git init -q "$SKR/top60"; printf 'a\n' > "$SKR/top60/f"; git -C "$SKR/top60" add f; git -C "$SKR/top60" commit -qm i
git -C "$SKR/top60" worktree add -q -b cx/t1 "$SKR/home/.cx-wt/top60-t1"
P60_OUT="$(cd "$SKR" && env HOME="$SKR/home" TOP="$SKR/top60" WT="$SKR/home/.cx-wt/top60-t1" bash -c "$TREES_LINE"'
  trees > b0; mkdir -p "$TOP/.claude/worktrees/x"; printf "q\n" > "$TOP/.claude/worktrees/x/f"
  git -C "$TOP" worktree add -q -b iso "$TOP/.claude/worktrees/y" 2>/dev/null; printf "r\n" >> "$TOP/.claude/worktrees/y/f"; printf "s\n" > "$TOP/.claude/worktrees/y/n"
  trees > b1; cmp -s b0 b1 && echo iso-ignored
  printf "t\n" >> "$TOP/f"; trees > b2; cmp -s b1 b2 || echo tracked-flagged' 2>&1 | tr '\n' ' ')"
P60_N="$(grep -c "status --porcelain=v1 --untracked-files=all -- . ':!.claude/worktrees'" "$SK") $(grep -c "status --porcelain=v1 --untracked-files=all -- . ':!.claude/worktrees'" "$ROOT/docs/DESIGN.md")"
check "[P60] the trees snapshot (defined once in Step 1's vars.sh, SKILL and section 12.2: $P60_N) excludes .claude/worktrees: a file there and a nested isolation worktree with edits -> no WRONG_TREE; a tracked edit in the main checkout -> WRONG_TREE (got: $P60_OUT)" \
  eval '[ "$P60_N" = "1 1" ] && [ "$P60_OUT" = "iso-ignored tracked-flagged " ]'
# The session itself in a Claude worktree (TOP = <main>/.claude/worktrees/A): a sibling thread's
# worktree B under the MAIN checkout's .claude/worktrees/ is left out; so is a worktree another
# lane marked running (~/.conductor/out/<id>/running), until the mark goes.
git init -q "$SKR/main60"; printf 'a\n' > "$SKR/main60/f"; git -C "$SKR/main60" add f; git -C "$SKR/main60" commit -qm i
git -C "$SKR/main60" worktree add -q -b wa "$SKR/main60/.claude/worktrees/A"
git -C "$SKR/main60" worktree add -q -b wb "$SKR/main60/.claude/worktrees/B"
git -C "$SKR/main60/.claude/worktrees/A" worktree add -q -b cx/a1 "$SKR/home/.cx-wt/A-a1"
git -C "$SKR/main60" worktree add -q -b cx/a2 "$SKR/home/.cx-wt/A-a2"
mkdir -p "$SKR/home/.conductor/out/a2"
P60B_OUT="$(cd "$SKR" && env HOME="$SKR/home" SKR="$SKR" TOP="$SKR/main60/.claude/worktrees/A" WT="$SKR/home/.cx-wt/A-a1" bash -c "$TREES_LINE"'
  trees > c0; printf "s\n" >> "$SKR/main60/.claude/worktrees/B/f"; printf "n\n" > "$SKR/main60/.claude/worktrees/B/new"; trees > c1; cmp -s c0 c1 && echo sibling-ignored
  printf "%s\n" "$HOME/.cx-wt/A-a2" > "$HOME/.conductor/out/a2/running"; trees > c2; printf "x\n" >> "$HOME/.cx-wt/A-a2/f"; trees > c3; cmp -s c2 c3 && echo running-ignored
  rm -f "$HOME/.conductor/out/a2/running"; trees > c4; printf "y\n" >> "$HOME/.cx-wt/A-a2/f"; trees > c5; cmp -s c4 c5 || echo unmarked-flagged
  printf "z\n" >> "$SKR/main60/f"; trees > c6; cmp -s c5 c6 || echo main-flagged
  printf "w\n" >> "$TOP/f"; trees > c7; cmp -s c6 c7 || echo top-flagged' 2>&1 | tr '\n' ' ')"
check "[P60] trees from a session inside a Claude worktree (TOP = <main>/.claude/worktrees/A): an edit in the sibling B -> no WRONG_TREE; a running-marked task worktree -> ignored, flagged once unmarked; the main checkout and TOP itself -> flagged (got: $P60B_OUT)" \
  test "$P60B_OUT" = "sibling-ignored running-ignored unmarked-flagged main-flagged top-flagged "
# Every agy step takes the machine-wide lock before it registers or runs agy, and no SKILL block
# starts an agy-job (no job form: the lock and the snapshots must span the run).
LOCK_LINE='mkdir -p "$HOME/.conductor/locks"; exec 9>> "$HOME/.conductor/locks/agy"; flock -w 4800 9 || { echo AGY_BUSY; exit 28; }   # one agy run at a time on this computer'
LOCK_BAD="$("$REAL_PY" -I - "$SK" "$ROOT/docs/DESIGN.md" "$LOCK_LINE" <<'PY'
import sys
bad = []
for path in sys.argv[1:3]:
    text = open(path, encoding="utf-8").read()
    if path.endswith("DESIGN.md"):
        text = text.split("### 12.2 Phase 1 lane commands", 1)[1].split("### 12.3", 1)[0]
    for blk in [b.split("\n```", 1)[0] for b in text.split("```bash\n")[1:]]:
        lines = blk.split("\n")
        if "agy-job start" in blk:
            bad.append(path.rsplit("/", 1)[1] + ": an agy-job start block")
        first = next((i for i, l in enumerate(lines) if "agy --new-project" in l or "agy-delegate --model" in l or "agy --model" in l), None)
        if first is None:
            continue
        lk = next((i for i, l in enumerate(lines) if l == sys.argv[3]), None)
        if lk is None or lk > first:
            bad.append(path.rsplit("/", 1)[1] + ": no lock before: " + lines[first].strip()[:60])
print("; ".join(bad))
PY
)"
LOCK_N="$(grep -cxF -- "$LOCK_LINE" "$SK")"
check "[P43] every SKILL and section 12.2 block that registers or runs agy takes the agy lock first ($LOCK_N in the SKILL); no block starts an agy-job${LOCK_BAD:+: $LOCK_BAD}" \
  eval '[ -z "$LOCK_BAD" ] && [ "$LOCK_N" -ge 4 ]'
mkdir -p "$SKR/lockhome/.conductor/locks"
LK_STEP="${LOCK_LINE/-w 4800/-w 1}"$'\necho GOT'
LK_OUT="$( { flock "$SKR/lockhome/.conductor/locks/agy" bash -c ': > "$1"; sleep 2' _ "$SKR/lockhome/held" &
  until [ -e "$SKR/lockhome/held" ]; do sleep 0.05; done
  HOME="$SKR/lockhome" bash -c "$LK_STEP"; printf 'rc=%s ' "$?"
  wait
  HOME="$SKR/lockhome" bash -c "$LK_STEP"; printf 'rc=%s' "$?"; } 2>&1 | tr '\n' ' ')"
check "[P43] the agy lock: while another process holds ~/.conductor/locks/agy the step prints AGY_BUSY and exits 28 (wait shortened to 1 s); once free it proceeds (got: $LK_OUT)" \
  test "$LK_OUT" = "AGY_BUSY rc=28 GOT rc=0"
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
            if pre not in s[:m.start()]:
                bad.append("%d: %s" % (n, s[:120]))
if re.search(r"(?m)^\s*export\s+CX_WORKER", text):
    bad.append("export CX_WORKER")
print("; ".join(bad[:5]))
PY
)"
check "[P43] every grok, agy-delegate/agy-job and ghcp-delegate/ghcp-job/ghcp-handoff command line in the SKILL carries its prefix; no export CX_WORKER${PFX_BAD:+: $PFX_BAD}" test -z "$PFX_BAD"
check "[P43] recipe headings in order: Step 1, Step 2a-2d, Step 3 after-run, Step 4 reviews, Step 5 GitHub, From Windows" \
  test "$(grep -E '^### (Step [0-9][a-e]?|From Windows)' "$SK" | sed -E 's/^### (Step [0-9][a-e]?|From Windows).*/\1/' | tr '\n' ' ')" = "Step 1 Step 2a Step 2b Step 2c Step 2d Step 2e Step 3 Step 4 Step 5 From Windows "
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

# ------------------------------------------------------------------ 15. free by construction (section 3.7)
section "free by construction: the stub logs"
ALL_LOGS=("$STUB_LOG" "$TMP/wsl-direct.log" "$TMP/cw.log")
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
