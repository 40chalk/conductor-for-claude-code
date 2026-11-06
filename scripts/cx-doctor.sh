#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# cx-doctor - checks the conductor's hosts, CLIs, logins and sibling plugins with free probes
# only (docs/DESIGN.md section 8). It never calls a model.
#
# Usage: cx-doctor [--pools] [--json] [--no-record]
#        cx-doctor --host wsl|docker [same flags]
#        cx-doctor --windows                         Git Bash only: Windows-side checks W1-W11
#        cx-doctor --login-help [copilot|grok|agy|gh|claude] [--host wsl|docker]
#        cx-doctor --install-runtime
#        cx-doctor --record-only
#        cx-doctor --pools --set-copilot-mtd <credits>
#        cx-doctor --pools --agy-usage
#        cx-doctor -h|--help | --version
#
#   (none)              executor host (WSL/Linux): checks D1-D32 and writes the host record
#                       $CX_HOME/hosts/<hostkey>.{json,path}; Git Bash: W1-W7, W10, W11 here, then
#                       the same doctor inside WSL with the Windows lines merged in. In a cloud
#                       session (or a BYOC runner without exec_host=local) only a cross D30 and
#                       exit 43: the executors are on your computer
#   --pools             also the Opus and review pools (agy, Copilot, grok) and a CX_POOLS line
#   --agy-usage         with --pools: also run agy -p /usage (documented as zero-quota)
#   --set-copilot-mtd N record the month-to-date Copilot credits from GitHub's billing page
#   --json              the report as one JSON document on stdout (on Git Bash, when forwarding
#                       fails: nothing on stdout, the W report on stderr before the CX_SIGNAL;
#                       not with --windows, whose report is plain text)
#   --no-record         do not write the host record
#   --host wsl          Git Bash: forward without the Windows checks; WSL: run here
#   --host docker       arrives in v1.1 (exit 43)
#   --windows           Git Bash: W1-W11 (W8 forwards cx-doctor --version, W9 the login probes)
#   --login-help [cli]  the exact fresh-login commands per CLI; no probes, any host
#   --install-runtime   install the runtime copy into ~/.conductor/runtime/<version>
#   --record-only       resolution and --version probes only; writes the host record silently
#   --windows-report F, --logins-only   internal (set by the Git Bash side)
#
# Every probe runs with stdin from /dev/null, cwd $CX_HOME/probe (kept empty) and a timeout
# (CX_PROBE_TIMEOUT=<secs> caps them all). No CLI version is pinned: each version is reported
# with the one the lanes were last verified against (an info line, never a failure), and each
# lane checks the live --help for the flags it uses before every run. Copilot's login probe is
# ghcp-models' own (free); without ghcp-models the raw invalid-model probe runs only on the
# Copilot version where it is verified free. Run the doctor outside Claude Code's Bash sandbox: Copilot, agy and grok
# cannot write their state directories inside it. stdout: the report; stderr: CX_HOST, CX_POOLS
# (--pools), CX_DOCTOR, and CX_SIGNAL CHECKS_FAILED on exit 4.
#
# Exit codes: 0 no check failed; 1 usage error; 2 FAILED (--record-only could not write the
# record, unexpected error); 4 CHECKS_FAILED (at least one check marked with a cross); 40
# FORWARD_FAILED and 41 RUNTIME_MISSING (Git Bash forwarding); 42 PATH_UNMAPPABLE
# (--windows-report path); 43 HOST_UNSUPPORTED (a cloud session, Cygwin, unknown host, --host
# docker, --host wsl off WSL, exec_host=local on Git Bash, exec_host=wsl on plain Linux); 44 CRLF_CORRUPT
# (--install-runtime); 130 CANCELLED (INT, TERM or HUP). Exit 0 with no check failed may still
# list warnings (!).

set -uo pipefail
unset CDPATH
CX_PROG=cx-doctor
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/options.sh
. "$HERE/lib/options.sh"
# shellcheck source=host/detect.sh
. "$CX_HOSTDIR/detect.sh"
# shellcheck source=host/pathmap.sh
. "$CX_HOSTDIR/pathmap.sh"

[ $# -gt 0 ] && cx_help_version "$1"

ORIG_ARGS=("$@")
POOLS=0 JSON=0 NO_RECORD=0 HOST_OPT="" WINDOWS=0 WIN_REPORT="" LOGINS_ONLY=0 LOGIN_HELP=0
LOGIN_CLI="" INSTALL_RT=0 RECORD_ONLY=0 SET_MTD="" AGY_USAGE=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help|--version) cx_help_version "$1" ;;
    --pools) POOLS=1; shift ;;
    --json) JSON=1; shift ;;
    --no-record) NO_RECORD=1; shift ;;
    --host)
      [ $# -ge 2 ] || cx_usage_error "--host needs wsl or docker"
      HOST_OPT="$2"; shift 2 ;;
    --host=*) HOST_OPT="${1#*=}"; shift ;;
    --windows) WINDOWS=1; shift ;;
    --windows-report)
      [ $# -ge 2 ] || cx_usage_error "--windows-report needs a file"
      WIN_REPORT="$2"; shift 2 ;;
    --windows-report=*) WIN_REPORT="${1#*=}"; shift ;;
    --logins-only) LOGINS_ONLY=1; shift ;;
    --login-help)
      LOGIN_HELP=1; shift
      case "${1-}" in copilot|grok|agy|gh|claude) LOGIN_CLI="$1"; shift ;; esac ;;
    --login-help=*)
      LOGIN_HELP=1; LOGIN_CLI="${1#*=}"; shift
      case "$LOGIN_CLI" in copilot|grok|agy|gh|claude) ;; *) cx_usage_error "--login-help takes copilot, grok, agy, gh or claude" ;; esac ;;
    --install-runtime) INSTALL_RT=1; shift ;;
    --record-only) RECORD_ONLY=1; shift ;;
    --set-copilot-mtd)
      [ $# -ge 2 ] || cx_usage_error "--set-copilot-mtd needs a number of credits"
      SET_MTD="$2"; POOLS=1; shift 2 ;;
    --set-copilot-mtd=*) SET_MTD="${1#*=}"; POOLS=1; shift ;;
    --agy-usage) AGY_USAGE=1; shift ;;
    *) cx_usage_error "unknown argument: $1" ;;
  esac
done
case "$HOST_OPT" in ""|wsl|docker) ;; *) cx_usage_error "--host takes wsl or docker, not '$HOST_OPT'" ;; esac
if [ -n "$SET_MTD" ] && [[ ! $SET_MTD =~ ^[0-9]+([.][0-9]+)?$ ]]; then
  cx_usage_error "--set-copilot-mtd needs a non-negative number, not '$SET_MTD'"
fi
[ "$AGY_USAGE" = 0 ] || [ "$POOLS" = 1 ] || cx_usage_error "--agy-usage needs --pools"
[ "$WINDOWS" = 0 ] || [ "$JSON" = 0 ] || cx_usage_error "--json does not combine with --windows: the W1-W11 report is plain text (Git Bash runs no python); plain cx-doctor --json merges the W checks into the WSL-side document"

T=""
# shellcheck disable=SC2329  # invoked by the EXIT trap
cleanup() { [ -n "$T" ] && rm -rf "$T"; return 0; }
trap cleanup EXIT
trap 'trap "" INT TERM HUP; cx_signal CANCELLED 130 ""' INT TERM HUP
T="$(mktemp -d "${TMPDIR:-/tmp}/cx-doctor.XXXXXXXX" 2>/dev/null)" || T=""
if [ -z "$T" ] || [ ! -d "$T" ]; then
  printf '%s: cannot create a temporary directory under %s\n' "$CX_PROG" "${TMPDIR:-/tmp}" >&2
  exit 2
fi
CHECKS="$T/checks.tsv"
: > "$CHECKS"

# chk STATUS ID SECTION TEXT [FIX...]: one doctor record (TAB, CR and LF become spaces).
chk() {
  local st="$1" id="$2" sec="$3" line f
  shift 3
  line="$st"$'\t'"$id"$'\t'"$sec"
  for f in "$@"; do
    [ -n "$f" ] || continue
    f="${f//$'\t'/ }"
    f="${f//$'\r'/ }"
    f="${f//$'\n'/ }"
    line="$line"$'\t'"$f"
  done
  printf '%s\n' "$line" >> "${CHK_OUT:-$CHECKS}"
}

# ---------------------------------------------------------------- pure-bash rendering (Git Bash,
# or an executor host without python3)
SECTIONS=("Session" "Host" "Runtime" "Options" "CLIs" "Versions" "Logins (free probes)" "Sibling plugins"
          "Windows (Git Bash)" "Pools")
N_OK=0 N_WARN=0 N_FAIL=0
render_plain() {
  local sec st id s text rest fx
  local -a f
  for sec in "${SECTIONS[@]}"; do
    local printed=0
    while IFS= read -r line || [ -n "$line" ]; do
      IFS=$'\t' read -r -a f <<< "$line"
      st="${f[0]-}"; id="${f[1]-}"; s="${f[2]-}"; text="${f[3]-}"
      [ "$s" = "$sec" ] || continue
      case "$st" in ok|warn|fail|info) ;; *) continue ;; esac
      if [ "$printed" = 0 ]; then printf '\n%s\n' "$sec"; printed=1; fi
      case "$st" in
        ok) printf '  \xe2\x9c\x93 %s [%s]\n' "$text" "$id"; N_OK=$((N_OK + 1)) ;;
        warn) printf '  ! %s [%s]\n' "$text" "$id"; N_WARN=$((N_WARN + 1)) ;;
        fail) printf '  \xe2\x9c\x97 %s [%s]\n' "$text" "$id"; N_FAIL=$((N_FAIL + 1)) ;;
        info) printf '      %s [%s]\n' "$text" "$id" ;;
      esac
      if [ "$st" != info ]; then
        for fx in "${f[@]:4}"; do [ -n "$fx" ] && printf '      fix: %s\n' "$fx"; done
      fi
      if [ "$id" = W9 ] && [ -s "$T/w9.out" ]; then
        while IFS= read -r rest || [ -n "$rest" ]; do
          printf '%s\n' "$rest"
          case "$rest" in
            "  "$'\xe2\x9c\x93'*) N_OK=$((N_OK + 1)) ;;
            "  !"*) N_WARN=$((N_WARN + 1)) ;;
            "  "$'\xe2\x9c\x97'*) N_FAIL=$((N_FAIL + 1)) ;;
          esac
        done < "$T/w9.out"
      fi
    done < "$1"
  done
}

plain_report() {  # TITLE FILE
  printf '%s\n' "$1"
  render_plain "$2"
  printf '\nSummary: %d \xe2\x9c\x93, %d !, %d \xe2\x9c\x97\n' "$N_OK" "$N_WARN" "$N_FAIL"
}

# ---------------------------------------------------------------- --login-help (pure bash)
login_help() {
  local cli="$1" gb="$2"
  if [ "$gb" = 1 ]; then
    printf '%s\n\n' "Logins are per host; open a WSL terminal (wsl.exe, or wsl.exe -d <distro> when wsl_distro is set) and run these there. The Windows side's logins do not count."
  else
    printf '%s\n\n' "Logins are per host: run these on the executor host (this WSL distribution), in a terminal."
  fi
  case "$cli" in ""|copilot)
    cat <<'TXT'
copilot (GitHub Copilot CLI)
  fresh login:   copilot login
                 device flow: open https://github.com/login/device and enter the code it prints
  verify (free): /conductor:doctor in a Claude Code session in WSL, or in a WSL terminal
                 ~/.conductor/runtime/current/bin/cx-doctor (create that copy once with
                 /conductor:doctor --install-runtime); its D16 line probes the login
                 (ghcp's ghcp-models is not on a plain terminal's PATH)
  keyring unreachable through wsl.exe (no D-Bus): create a fine-grained PAT with the
                 "Copilot Requests" permission and store it with
                 install -d -m 700 ~/.conductor/secrets && install -m 600 /dev/null ~/.conductor/secrets/copilot-token
                 then paste the token into that file; cx-wsl ghcp-* calls export it as
                 COPILOT_GITHUB_TOKEN for that call only (shell steps through cx-wsl bash -s
                 do not: run Copilot lanes as direct cx-wsl ghcp-* calls; Phase 2 adapters
                 export it for every Copilot lane)
  avoid:         classic ghp_ tokens, and a stray GH_TOKEN/GITHUB_TOKEN (they can change the
                 account Copilot uses)

TXT
  esac
  case "$cli" in ""|grok)
    cat <<'TXT'
grok (Grok Build)
  fresh login:   grok login --device-auth
                 prints a URL and a code; works headless
  verify (free): grok models
                 must not print "You are not authenticated."
  avoid:         grok login --oauth in containers (loopback callback), and XAI_API_KEY (bills
                 the API account, not the subscription)

TXT
  esac
  case "$cli" in ""|agy)
    cat <<'TXT'
agy (Antigravity)
  fresh login:   agy
                 the first run asks you to sign in with Google (over SSH it prints a URL and a
                 code); then quit
  verify (free): agy models
                 lists claude-opus-5-5-high
  notes:         without D-Bus agy stores credentials in a file (expected in wsl.exe shells)
  avoid:         GEMINI_API_KEY (bills the key, not the plan); never run /antigravity:migrate
                 or agy plugin import claude

TXT
  esac
  case "$cli" in ""|gh)
    cat <<'TXT'
gh (GitHub CLI)
  fresh login:   gh auth login --web
                 prints a one-time code for https://github.com/login/device
  verify (free): gh auth status

TXT
  esac
  case "$cli" in ""|claude)
    cat <<'TXT'
claude (Claude Code; only claude -p workers need it on this host)
  fresh login:   claude auth login
                 the Claude subscription is the default
  verify (free): claude auth status --json
                 shows "loggedIn": true
  avoid:         --console (it would bill API usage instead of the plan)

TXT
  esac
}

if [ "$LOGIN_HELP" = 1 ]; then
  if [ "$HOST_OPT" = docker ]; then
    cx_note "the Docker host arrives in v1.1"
    cx_signal HOST_UNSUPPORTED 43 ""
  fi
  gb=0
  cx_is_windows_shell && gb=1
  login_help "$LOGIN_CLI" "$gb"
  exit 0
fi
if [ "$HOST_OPT" = docker ]; then
  cx_note "the Docker host arrives in v1.1 (--host docker)"
  cx_signal HOST_UNSUPPORTED 43 ""
fi

cx_detect
S_SESSION="Session"

# Step 0a (DESIGN section 7.3): in a cloud session (or a BYOC runner without exec_host=local)
# nothing is probed: the header, a cross D30 and the summary, then exit 43.
CLOUD_KIND=""
case "$CX_SESSION" in
  cloud) CLOUD_KIND=cloud ;;
  byoc) [ "$(_cx_exec_host_raw)" = local ] || CLOUD_KIND=byoc ;;
esac
if [ -n "$CLOUD_KIND" ]; then
  et="${CLAUDE_CODE_REMOTE_ENVIRONMENT_TYPE:-}"
  chk fail D30 "$S_SESSION" "cloud session (${CLOUD_KIND}${et:+, environment $et}): the conductor is inactive here; the executors and their logins are in WSL on your computer" \
    "run /conductor:doctor in a local desktop session, a Work locally project thread or a Claude Code session in WSL"
  title="conductor doctor $CX_VERSION: host $CX_HOST, caller $CX_HOST, session $CX_SESSION"
  if [ "$JSON" = 1 ]; then plain_report "$title" "$CHECKS" >&2; else plain_report "$title" "$CHECKS"; fi
  cx_note "cloud session ($CLOUD_KIND): the executors and their logins are in WSL on your computer; run this in a local desktop session, a Work locally project thread or a Claude Code session in WSL"
  cx_signal HOST_UNSUPPORTED 43 ""
fi

# session_lines ID SECTION: the D30 / W10 session lines (DESIGN section 8.3). A cloud session
# never gets here (step 0a above).
session_lines() {
  local id="$1" sec="$2" ep="${CLAUDE_CODE_ENTRYPOINT:-}" dv="${CLAUDE_CODE_DESKTOP_APP_VERSION:-}" bits
  bits="entrypoint ${ep:-unset}${dv:+, desktop app $dv}"
  case "$CX_SESSION" in
    bridge) chk info "$id" "$sec" "session bridge ($bits): a Remote Control child, such as a Work locally project thread; this machine's settings, hooks and plugins apply. the pool slots are shared by every thread and session on this computer (cap_agy, cap_copilot, cap_grok; agy launches one at a time)" ;;
    byoc) chk info "$id" "$sec" "session byoc ($bits): option exec_host=local treats this runner as this machine" ;;
    *) chk info "$id" "$sec" "session local ($bits)" ;;
  esac
  if [ "$CX_ATTENDED" = 0 ]; then
    chk info "$id" "$sec" "unattended session (CLAUDE_CODE_SESSION_ATTENDED=0): permission prompts are denied, so executor commands need the D25 allow rules"
  fi
  if [ -n "${CLAUDE_PROJECT_UUID:-}" ]; then
    chk info "$id" "$sec" "a claude.ai Project is attached (CLAUDE_PROJECT_UUID); Claude Code adds its instructions itself"
  fi
  return 0
}
# plugin_bin_on_path: true when a PATH entry holds this plugin's own cx-doctor (same file, by
# device and inode, so a symlinked or differently spelled install path still matches). Claude
# Code adds a plugin's bin/ to the Bash tool's PATH only for a loaded plugin.
plugin_bin_on_path() {
  local e
  local -a parts=()
  IFS=: read -r -a parts <<< "${PATH:-}"
  for e in ${parts[@]+"${parts[@]}"}; do
    [ -n "$e" ] && [ "$e/cx-doctor" -ef "$CX_ROOT/bin/cx-doctor" ] && return 0
  done
  return 1
}
# The docs say the desktop app's WSL sessions (a \\wsl.localhost folder from the picker, or the
# WSL environment) load no plugins (DESIGN section 1.5); D30 checks this session instead.
DESKTOP_WSL_FIX="open the repo in a desktop session on a Windows folder (C:\\...; it forwards into WSL), run claude in a WSL terminal, or serve the WSL folder with claude remote-control from a WSL terminal (unverified until live check L11)"

# The last CRLF fix of D3 and W6 (after the sed line, which works for every source): CRs come
# from archive downloads, copies made with Windows tools or a folder marketplace edited on
# Windows, where core.autocrlf changes nothing (this repo's eol=lf rules override it).
CRLF_FALLBACK="if the plugin comes from a folder (directory) marketplace edited with Windows tools, convert that source folder the same way, or the next update copies the CRs back; for an archive install: claude plugin marketplace update conductor-for-claude-code && claude plugin update conductor@conductor-for-claude-code (or uninstall and reinstall the plugin)"

# ================================================================ Git Bash side (pure bash)
W_SEC="Windows (Git Bash)"
W_DISTRO=""
w_checks() {  # W1-W7, W10, W11 into $CHECKS
  local p first line names="" rows="" r name ver def="" defver="" cwdw="" cwds="" top gitout fixl files f crl ac
  # W1
  p="$(command -v wsl.exe 2>/dev/null)" || p=""
  if [ -n "$p" ]; then chk ok W1 "$W_SEC" "wsl.exe found ($p)"
  else chk fail W1 "$W_SEC" "wsl.exe not found on PATH" "install WSL from an elevated PowerShell: wsl.exe --install"
  fi
  first="$(timeout --version 2>/dev/null | head -n 1)" || first=""
  if [[ $first == *"GNU coreutils"* ]]; then chk ok W1 "$W_SEC" "timeout is GNU coreutils"
  else chk fail W1 "$W_SEC" "timeout resolves to C:\\Windows\\System32\\timeout.exe or is missing: put /usr/bin before the Windows directories on PATH"
  fi
  # W2
  local want
  if [ -n "${CLAUDE_PLUGIN_OPTION_WSL_DISTRO+x}" ]; then want="${CLAUDE_PLUGIN_OPTION_WSL_DISTRO}"
  else want="$(cx_opt_lite wsl_distro "$(cx_win_settings_file)")"; fi
  want="$(cx_trim "$want")"
  [ -n "$want" ] || want=auto
  [ "${want,,}" = auto ] && want=auto
  if [ -n "$p" ]; then
    local rq rv
    names="$(cx_timeout 15 env WSL_UTF8=1 MSYS_NO_PATHCONV=1 wsl.exe -l -q 2>"$T/w2q.err" </dev/null | cx_decode_wsl)"
    rq=$?
    rows="$(cx_timeout 15 env WSL_UTF8=1 MSYS_NO_PATHCONV=1 wsl.exe -l -v 2>"$T/w2v.err" </dev/null | cx_decode_wsl)"
    rv=$?
    if [ "$rq" -ne 0 ] || [ "$rv" -ne 0 ]; then
      chk fail W2 "$W_SEC" "wsl.exe -l failed: $(cx_decode_wsl < "$T/w2v.err" | awk 'NF { print; exit }')"
    else
      local hdr=1 star
      declare -A VER=()
      while IFS= read -r r || [ -n "$r" ]; do
        [ -n "${r//[[:space:]]/}" ] || continue
        if [ "$hdr" = 1 ]; then hdr=0; continue; fi
        r="$(cx_trim "$r")"
        star=0
        if [ "${r:0:1}" = "*" ]; then star=1; r="$(cx_trim "${r:1}")"; fi
        name="${r%%[[:space:]]*}"
        ver="${r##*[[:space:]]}"
        VER[$name]="$ver"
        if [ "$star" = 1 ]; then def="$name"; defver="$ver"; fi
      done <<< "$rows"
      local inst=""
      while IFS= read -r r || [ -n "$r" ]; do
        r="$(cx_trim "$r")"
        [ -n "$r" ] && inst="${inst:+$inst, }$r"
      done <<< "$names"
      if [ "$want" = auto ]; then
        if [ -z "$def" ]; then
          chk fail W2 "$W_SEC" "no default WSL distribution (installed: ${inst:-none})" "wsl.exe --install -d Ubuntu, or wsl.exe --set-default <name>"
        elif [ "$defver" = 2 ]; then
          chk ok W2 "$W_SEC" "default WSL distribution $def (WSL2)"
          W_DISTRO="$def"
        else
          chk warn W2 "$W_SEC" "default WSL distribution $def runs WSL$defver; the conductor needs WSL2" "wsl.exe --set-version $def 2"
          W_DISTRO="$def"
        fi
      else
        local found=0
        while IFS= read -r r || [ -n "$r" ]; do
          r="$(cx_trim "$r")"
          [ "${r,,}" = "${want,,}" ] && { found=1; want="$r"; }
        done <<< "$names"
        if [ "$found" = 0 ]; then
          chk fail W2 "$W_SEC" "wsl_distro=$want is not installed; installed: ${inst:-none}; set wsl_distro or leave it auto"
        elif [ "${VER[$want]-}" = 2 ]; then
          chk ok W2 "$W_SEC" "WSL distribution $want (WSL2)"
          W_DISTRO="$want"
        else
          chk warn W2 "$W_SEC" "WSL distribution $want runs WSL${VER[$want]-?}; the conductor needs WSL2" "wsl.exe --set-version $want 2"
          W_DISTRO="$want"
        fi
      fi
    fi
  else
    chk fail W2 "$W_SEC" "WSL distributions not listed (no wsl.exe)"
  fi
  [ -n "$W_DISTRO" ] && export CX_WSL_DISTRO="$W_DISTRO"
  # W3
  cwdw=""
  if command -v cygpath >/dev/null 2>&1; then
    chk ok W3 "$W_SEC" "cygpath found"
    cwdw="$(cygpath -w -l "$PWD" 2>/dev/null)" || cwdw=""
    cwds="${cwdw//\\//}"
    cwds="${cwds,,}"
    case "$cwds" in
      "") chk fail W3 "$W_SEC" "cygpath cannot map the current directory $PWD" ;;
      //wsl.localhost/*|//wsl\$/*) chk ok W3 "$W_SEC" "the current directory is on the WSL filesystem ($cwdw)" ;;
      [a-z]:/*) chk info W3 "$W_SEC" "the current directory is on a Windows drive ($cwdw): WSL reaches it through /mnt, which is slow for large repos; for a repo that lives in WSL use a WSL terminal (claude, or claude remote-control there), not a desktop session opened on \\\\wsl.localhost (it runs inside WSL without plugins)" ;;
      //*) chk fail W3 "$W_SEC" "the current directory is on a network share ($cwdw): it has no WSL path" ;;
      *) chk warn W3 "$W_SEC" "unexpected Windows form of the current directory: $cwdw" ;;
    esac
  else
    chk fail W3 "$W_SEC" "cygpath not found: run the conductor from Git for Windows' Git Bash"
  fi
  # W4
  if [ -n "$W_DISTRO" ]; then
    if [ -d "//wsl.localhost/$W_DISTRO/" ]; then
      chk ok W4 "$W_SEC" "\\\\wsl.localhost\\$W_DISTRO\\ is reachable"
    elif [ -d "//wsl\$/$W_DISTRO/" ]; then
      chk warn W4 "$W_SEC" "only the legacy \\\\wsl\$\\$W_DISTRO\\ prefix answers (host paths use \\\\wsl.localhost)"
    else
      chk warn W4 "$W_SEC" "\\\\wsl.localhost\\$W_DISTRO\\ is not reachable (the distribution may not be running yet)"
    fi
  fi
  # W5
  case "$cwds" in
    //wsl.localhost/*|//wsl\$/*)
      if command -v git >/dev/null 2>&1; then
        gitout="$(git rev-parse --show-toplevel 2>&1 </dev/null)"
        local grc=$?
        if [ "$grc" -eq 0 ]; then
          chk ok W5 "$W_SEC" "Git for Windows accepts this repository"
        elif [[ $gitout == *"dubious ownership"* ]]; then
          fixl="$(printf '%s\n' "$gitout" | grep -m1 'git config --global --add safe.directory')"
          fixl="$(cx_trim "$fixl")"
          if [ -z "$fixl" ]; then
            local rel="${cwdw#\\\\}"
            rel="${rel#*\\}"
            rel="${rel#*\\}"
            fixl="git config --global --add safe.directory '%(prefix)///wsl.localhost/$W_DISTRO/${rel//\\//}'"
          fi
          chk fail W5 "$W_SEC" "Git for Windows refuses this repository (dubious ownership); conductor git work runs in WSL git anyway" "$fixl"
        fi
      fi ;;
  esac
  # W6: every shipped file (grep only reads; a CR in the doctor's own execution path stops it
  # before this line, and the session-start canary reports that case).
  files=()
  for f in "${CX_SHIPPED_FILES[@]}"; do
    [ -f "$CX_ROOT/$f" ] && files+=("$CX_ROOT/$f")
  done
  crl=()
  if [ "${#files[@]}" -gt 0 ]; then
    mapfile -t crl < <(grep -l $'\r' "${files[@]}" 2>/dev/null)
  fi
  if [ "${#crl[@]}" -eq 0 ]; then
    chk ok W6 "$W_SEC" "no CRLF line endings in the Windows-side plugin files"
  else
    chk fail W6 "$W_SEC" "CRLF line endings in: ${crl[*]}" "sed -i 's/\\r\$//' $(cx_shell_words "${crl[@]}")" "$CRLF_FALLBACK"
  fi
  ac=""
  command -v git >/dev/null 2>&1 && ac="$(git config --global --get core.autocrlf 2>/dev/null </dev/null)"
  if [ "${ac,,}" = true ]; then
    chk warn W6 "$W_SEC" "core.autocrlf=true: repos touched from Windows and WSL need * text=auto eol=lf in .gitattributes (this plugin's own eol=lf rules already protect its git checkouts)"
  fi
  # W7
  local cdir ip text id short
  cdir="$(cx_win_config_dir)"
  ip="$cdir/plugins/installed_plugins.json"
  text=""
  if [ -f "$ip" ]; then
    text="$(< "$ip")"
    text="${text#$'\xef\xbb\xbf'}"
    text="${text//$'\r'/}"
  fi
  if [[ $text =~ \"conductor@[^\"]*\"[[:space:]]*: ]]; then
    chk ok W7 "$W_SEC" "conductor is installed in the Windows-side Claude Code"
  else
    chk info W7 "$W_SEC" "conductor not found in $ip"
  fi
  for id in ghcp@ghcp-for-claude-code antigravity@antigravity-for-claude-code grok-build@xai-grok-build; do
    short="${id%%@*}"
    if [[ $text =~ \"$short@[^\"]*\"[[:space:]]*: ]]; then
      chk warn W7 "$W_SEC" "$short is installed natively on Windows: its policy would send Claude to run its wrappers in Git Bash, bypassing WSL; install it in WSL only" "claude plugin uninstall $id"
    fi
  done
  w10_w11
  { printf 'meta\tsession\t%s\t%s\n' "$CX_SESSION" "$CX_ATTENDED"
    printf 'meta\tlite\texec_host\t%s\n' "$(cx_opt_lite exec_host "$(cx_win_settings_file)")"
    printf 'meta\tlite\twsl_distro\t%s\n' "$(cx_opt_lite wsl_distro "$(cx_win_settings_file)")"
  } >> "$CHECKS"
}

# W10 and W11 (DESIGN section 8.6, pure bash): the caller's session and Work locally readiness,
# and workflows and ultracode on the Windows side, from the Windows environment and the lite
# readers over the Windows-side settings (managed settings win; the registry is not read).
w10_w11() {
  local wset mset="" pf top obj v k src blockers=0 off="" u n c
  wset="$(cx_win_settings_file)"
  pf="${ProgramFiles:-${PROGRAMFILES:-}}"
  [ -n "$pf" ] && mset="$(cygpath -u "$pf" 2>/dev/null)/ClaudeCode/managed-settings.json"
  # W10: session, then the Remote Control blockers (change together with cxlib.py RC_BLOCK_ENV).
  session_lines W10 "$W_SEC"
  chk info W10 "$W_SEC" "desktop app sessions opened on a \\\\wsl.localhost folder (or in the WSL environment) run inside WSL, where plugins are not loaded: keep conductor work in a desktop session on a Windows folder, like this one, in a WSL terminal, or behind claude remote-control in WSL (unverified until live check L11)"
  cx_lite_top "$wset" env
  top="$CX_LITE_TOP" obj="$CX_LITE_OBJ"
  for k in CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC DISABLE_GROWTHBOOK; do
    src=""
    if [ -n "${!k:-}" ]; then src="environment"
    elif [ -n "$(cx_lite_value "$obj" "$k")" ]; then src="env block of $wset"
    fi
    if [ -n "$src" ]; then
      chk info W10 "$W_SEC" "Remote Control, and so Work locally threads on this computer, is off while: $k is set ($src)"
      blockers=$((blockers + 1))
    fi
  done
  v="${ANTHROPIC_BASE_URL:-}"
  src=environment
  if [ -z "$v" ]; then v="$(cx_lite_value "$obj" ANTHROPIC_BASE_URL)"; src="env block of $wset"; fi
  v="${v%/}"
  if [ -n "$v" ] && [ "$v" != https://api.anthropic.com ]; then
    chk info W10 "$W_SEC" "Remote Control, and so Work locally threads on this computer, is off while: ANTHROPIC_BASE_URL=$v ($src): a gateway, not a claude.ai login"
    blockers=$((blockers + 1))
  fi
  if [ "$(cx_lite_value "$top" disableRemoteControl)" = true ]; then
    chk info W10 "$W_SEC" "Remote Control, and so Work locally threads on this computer, is off while: disableRemoteControl is true ($wset)"
    blockers=$((blockers + 1))
  fi
  if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
    chk info W10 "$W_SEC" "Remote Control, and so Work locally threads on this computer, is off while: ANTHROPIC_API_KEY is set: Work locally threads need a claude.ai login, not an API key"
    blockers=$((blockers + 1))
  fi
  if [ "$blockers" = 0 ]; then
    chk info W10 "$W_SEC" "Work locally prerequisites met on the Windows side; a thread also needs the desktop app with 'Use this computer from your phone and claude.ai' on (folder added) or claude remote-control running in the folder, and Require trusted devices off"
  fi
  # W11: the D32 keys over the managed file, then the user file (first found wins).
  declare -A WV=() WS=()
  local f
  for f in "$mset" "$wset"; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if [ "$f" = "$wset" ]; then CX_LITE_TOP="$top"; else cx_lite_top "$f"; fi   # W10 parsed wset already
    for k in ultracode disableWorkflows enableWorkflows workflowKeywordTriggerEnabled workflowSizeGuideline; do
      [ -n "${WV[$k]-}" ] && continue
      v="$(cx_lite_value "$CX_LITE_TOP" "$k")"
      [ -n "$v" ] && { WV[$k]="$v"; WS[$k]="$f"; }
    done
  done
  case "${CLAUDE_CODE_DISABLE_WORKFLOWS:-}" in 1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) off="CLAUDE_CODE_DISABLE_WORKFLOWS is set" ;; esac
  if [ -z "$off" ]; then
    case "${CLAUDE_CODE_WORKFLOWS:-x}" in 0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) off="CLAUDE_CODE_WORKFLOWS=$CLAUDE_CODE_WORKFLOWS" ;; esac
  fi
  [ -z "$off" ] && [ "${WV[disableWorkflows]-}" = true ] && off="disableWorkflows in ${WS[disableWorkflows]}"
  [ -z "$off" ] && [ "${WV[enableWorkflows]-}" = false ] && off="enableWorkflows false in ${WS[enableWorkflows]}"
  if [ -n "$off" ]; then
    chk info W11 "$W_SEC" "workflows off ($off): ultracode is unavailable; conductor fan-out uses the main-turn recipe"
  else
    chk info W11 "$W_SEC" "workflows available on the Windows side (not disabled by the environment or the settings files read; on Pro they default off: turn on Dynamic workflows in /config)"
  fi
  u="${WV[ultracode]-}"
  if [ "$u" = true ] && [ -n "$off" ]; then
    chk info W11 "$W_SEC" "ultracode is set (${WS[ultracode]}) but workflows are off, so it has no effect"
  elif [ "$u" = true ]; then
    chk info W11 "$W_SEC" "ultracode on for new sessions (${WS[ultracode]}): workflow agents get the conductor's subagent rules and never run executors (Phase 1)"
  else
    chk info W11 "$W_SEC" "ultracode not set in the Windows-side settings files read (user, Program Files managed; not the registry); a session can still turn it on (/effort ultracode, --effort ultracode, --settings, the keyword)"
  fi
  [ "${WV[workflowKeywordTriggerEnabled]-}" = false ] && chk info W11 "$W_SEC" "the ultracode keyword trigger is off (${WS[workflowKeywordTriggerEnabled]})"
  [ -n "${WV[workflowSizeGuideline]-}" ] && chk info W11 "$W_SEC" "workflow size guideline ${WV[workflowSizeGuideline]} (${WS[workflowSizeGuideline]}; advisory only)"
  for k in CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_MODEL_FORCE CLAUDE_CODE_SUBAGENT_MODEL CLAUDE_CODE_SUBAGENT_EFFORT; do
    [ -n "${!k:-}" ] || continue
    case "$k" in *EFFORT) v=effort ;; *) v=model ;; esac
    chk info W11 "$W_SEC" "$k=${!k} overrides the $v of workflow and subagent stages"
  done
  c="${CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS:-}"
  if [[ $c =~ ^[0-9]+$ ]] && [ "$((10#$c))" -ge 1 ] && [ "$((10#$c))" -le 256 ]; then
    chk info W11 "$W_SEC" "workflow concurrency $((10#$c)) agents per workflow (CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS)"
  else
    n="${NUMBER_OF_PROCESSORS:-}"
    if [[ $n =~ ^[0-9]+$ ]] && [ "$((10#$n))" -ge 1 ]; then
      c=$((10#$n - 2))
      [ "$c" -lt 2 ] && c=2
      [ "$c" -gt 16 ] && c=16
      chk info W11 "$W_SEC" "workflow concurrency $c agents per workflow (min(16, max(2, $((10#$n)) CPUs - 2)); CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS overrides it)"
    fi
  fi
  return 0
}

gitbash_title() {
  printf 'conductor doctor %s: host gitbash (windows %s), caller gitbash, session %s' "$CX_VERSION" "${CX_OS_VERSION:-?}" "$CX_SESSION"
}

fwd_note() {  # FILE: the forwarder's own notes, decoded
  cx_decode_wsl < "$1" 2>/dev/null | grep -E '^(forward-wsl|wsl-entry): ' | head -n 3 | tr '\n' ' '
}

if [ "$CX_HOST" = gitbash ]; then
  if [ "$INSTALL_RT" = 1 ]; then
    exec "${BASH:-bash}" "$CX_HOSTDIR/forward-wsl.sh" --bootstrap-install
  fi
  if [ "$WINDOWS" = 1 ]; then
    w_checks
    out="$("${BASH:-bash}" "$CX_HOSTDIR/forward-wsl.sh" cx-doctor --version 2>"$T/w8.err" </dev/null)"
    rc=$?
    if [ "$rc" -eq 0 ] && [ "$out" = "cx-doctor $CX_VERSION" ]; then
      chk ok W8 "$W_SEC" "forwarding works: $out"
    elif [ "$rc" -eq 41 ]; then
      chk fail W8 "$W_SEC" "the runtime could not be installed into WSL: $(fwd_note "$T/w8.err")" "cx-doctor --install-runtime"
    elif [ "$rc" -eq 40 ]; then
      chk fail W8 "$W_SEC" "forwarding into WSL failed: $(fwd_note "$T/w8.err")"
    else
      chk fail W8 "$W_SEC" "forwarded cx-doctor --version printed '${out:0:80}' (rc $rc)"
    fi
    "${BASH:-bash}" "$CX_HOSTDIR/forward-wsl.sh" cx-doctor --logins-only > "$T/w9.out" 2> "$T/w9.err" </dev/null
    rc=$?
    case "$rc" in
      0|4) chk ok W9 "$W_SEC" "forwarded login probes ran through wsl.exe (rendered in WSL):" ;;
      *) : > "$T/w9.out"
         chk fail W9 "$W_SEC" "forwarded login probes did not run (rc $rc): $(fwd_note "$T/w9.err")" ;;
    esac
    plain_report "$(gitbash_title)" "$CHECKS"
    cx_emit DOCTOR ok:int "$N_OK" warn:int "$N_WARN" fail:int "$N_FAIL" host gitbash caller gitbash record:null "" pools:bool false
    [ "$N_FAIL" -eq 0 ] || cx_signal CHECKS_FAILED 4 ""
    exit 0
  fi
  if [ "$HOST_OPT" = wsl ] || [ "$RECORD_ONLY" = 1 ] || [ "$LOGINS_ONLY" = 1 ] || [ -n "$WIN_REPORT" ]; then
    exec "${BASH:-bash}" "$CX_HOSTDIR/forward-wsl.sh" cx-doctor "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"
  fi
  # Default: W1-W7, W10, W11 here, then the doctor inside WSL with the W lines merged in.
  # exec_host is honoured as in forwarding step 0 (local is refused on Git Bash).
  if [ -n "${CLAUDE_PLUGIN_OPTION_EXEC_HOST+x}" ]; then eh="${CLAUDE_PLUGIN_OPTION_EXEC_HOST:-auto}"
  else eh="$(cx_opt_lite exec_host "$(cx_win_settings_file)")"; eh="${eh:-auto}"; fi
  eh="${eh//[[:space:]]/}"
  if [ "${eh,,}" = local ]; then
    cx_note "option exec_host=local cannot run on Git Bash: the executors live in WSL"
    cx_signal HOST_UNSUPPORTED 43 ""
  fi
  w_checks
  WREP="$T/windows-report.tsv"
  cp "$CHECKS" "$WREP"
  WREP_WIN="$(cygpath -w -l "$WREP" 2>/dev/null)" || WREP_WIN=""
  # With --json, stdout must hold one JSON document or nothing: the forwarder's stderr is kept
  # back so that, when forwarding fails, the W report can go to stderr before it and its
  # CX_SIGNAL stays the last line.
  FWD_ERR="$T/forward.err"
  : > "$FWD_ERR"
  fwd_sig=0
  if [ -n "$WREP_WIN" ]; then
    if [ "$JSON" = 1 ]; then
      "${BASH:-bash}" "$CX_HOSTDIR/forward-wsl.sh" cx-doctor "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}" --windows-report "$WREP_WIN" 2> "$FWD_ERR"
    else
      "${BASH:-bash}" "$CX_HOSTDIR/forward-wsl.sh" cx-doctor "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}" --windows-report "$WREP_WIN"
    fi
    rc=$?
    fwd_sig=1
  else
    cx_note "cygpath cannot map $WREP"
    rc=40
  fi
  case "$rc" in
    40|41)
      chk fail W8 "$W_SEC" "forwarding into WSL failed (exit $rc): the WSL-side checks did not run" \
        "$([ "$rc" = 41 ] && printf 'cx-doctor --install-runtime' || printf 'cx-doctor --windows')"
      if [ "$JSON" = 1 ]; then
        plain_report "$(gitbash_title)" "$CHECKS" >&2
        cat "$FWD_ERR" >&2
      else
        plain_report "$(gitbash_title)" "$CHECKS"
      fi
      [ "$fwd_sig" = 1 ] || cx_signal FORWARD_FAILED 40 "cygpath cannot map the Windows report file"
      exit "$rc" ;;
  esac
  cat "$FWD_ERR" >&2
  exit "$rc"
fi

case "$CX_HOST" in
  wsl|linux|docker|macos) ;;
  *)
    cx_note "host '$CX_HOST' is not supported (uname -s: $(cx_uname_s)); D1 fails"
    cx_signal HOST_UNSUPPORTED 43 "" ;;
esac
if [ "$WINDOWS" = 1 ]; then
  printf '! --windows checks only run from Git Bash\n'
  exit 0
fi
if [ "$HOST_OPT" = wsl ] && [ "$CX_HOST" != wsl ]; then
  cx_note "--host wsl: this host is $CX_HOST, not WSL"
  cx_signal HOST_UNSUPPORTED 43 ""
fi
# shellcheck disable=SC2119  # no FILE: the default settings files
cx_load_options
cx_forward_if_needed cx-doctor "${ORIG_ARGS[@]+"${ORIG_ARGS[@]}"}"

# ================================================================ executor host
PY=0
cx_py_ok && PY=1
CXH="${CX_HOME:-$HOME/.conductor}"
CFG="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
FORWARDED=0
[ "${CX_FORWARDED:-}" = 1 ] && FORWARDED=1
CALLER="${CX_CALLER:-$CX_HOST}"
REC_DIR="$CXH/hosts"
REC="$REC_DIR/$CX_HOSTKEY.json"
HAVE_TIMEOUT=0
cx_have_timeout && HAVE_TIMEOUT=1

# The installed plugin copy (D3, --install-runtime): CLAUDE_PLUGIN_ROOT, else the conductor's
# installPath (scope user first), else this copy unless it is the runtime copy.
SIB_JSON="$T/plugins.json"
if [ "$PY" = 1 ]; then cx_py plugins --config-dir "$CFG" > "$SIB_JSON" 2>/dev/null || : > "$SIB_JSON"; else : > "$SIB_JSON"; fi
jget() {  # FILE KEY -> value (empty when absent)
  [ "$PY" = 1 ] && [ -s "$1" ] || return 1
  cx_py json-get "$1" "$2" 2>/dev/null
}
INSTALLED_ROOT=""
if [ -n "${CLAUDE_PLUGIN_ROOT:-}" ] && [ -d "$CLAUDE_PLUGIN_ROOT" ]; then
  INSTALLED_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  ip="$(jget "$SIB_JSON" "plugins.conductor@conductor-for-claude-code.install_path")" || ip=""
  [ "$ip" = null ] && ip=""
  if [ -n "$ip" ] && [ -d "$ip" ]; then
    INSTALLED_ROOT="$ip"
  else
    case "$CX_ROOT/" in
      "$CXH/runtime/"*) INSTALLED_ROOT="" ;;
      *) INSTALLED_ROOT="$CX_ROOT" ;;
    esac
  fi
fi

if [ "$INSTALL_RT" = 1 ]; then
  SRC="${INSTALLED_ROOT:-$CX_ROOT}"
  exec /bin/bash "$SRC/scripts/host/install-runtime.sh" --from "$SRC"
fi

if [ -n "$WIN_REPORT" ]; then
  cx_path_in_var WIN_REPORT "$WIN_REPORT"
  [ -f "$WIN_REPORT" ] || cx_note "the Windows report $WIN_REPORT is missing; the Windows section stays empty"
fi
# The session the header and CX_DOCTOR report: a forwarded call sees "local" (the env allowlist
# drops the CLAUDE_CODE_* variables), so the Git Bash side's report carries the caller's.
SESSION="$CX_SESSION" ATTENDED="$CX_ATTENDED"
if [ -n "$WIN_REPORT" ] && [ -f "$WIN_REPORT" ]; then
  while IFS=$'\t' read -r st id v1 v2; do
    [ "$st" = meta ] && [ "$id" = session ] || continue
    case "$v1" in local|bridge|cloud|byoc) SESSION="$v1" ;; esac
    case "${v2%$'\r'}" in 0|1) ATTENDED="${v2%$'\r'}" ;; *) ATTENDED="" ;; esac
  done < "$WIN_REPORT"
fi

# The probe directory: created and kept empty.
PROBE="$CXH/probe"
if [ -d "$PROBE" ] && [ -n "$(ls -A "$PROBE" 2>/dev/null)" ]; then
  rm -rf "${PROBE:?}" 2>/dev/null
fi
mkdir -p "$PROBE" 2>/dev/null || PROBE="$T/probe"
mkdir -p "$PROBE"

# probe NAME SECS CMD...: stdout -> $T/NAME.out, stderr -> $T/NAME.err; returns the rc.
probe() {
  local name="$1" secs="$2"
  shift 2
  ( cd -- "$PROBE" 2>/dev/null || cd /
    cx_timeout "$secs" "$@" </dev/null >"$T/$name.out" 2>"$T/$name.err" )
}
killed() { [ "$1" -eq 124 ] || [ "$1" -eq 137 ]; }
# The per-tool prefixes of section 12.2 for every agy and grok probe: an API key would make a
# probe authenticate (and list models) through the API account instead of the subscription the
# real commands use, and agy or grok could self-update mid-check.
AGY_ENV=(env -u GEMINI_API_KEY -u GOOGLE_API_KEY AGY_CLI_DISABLE_AUTO_UPDATE=true)
GROK_ENV=(env -u XAI_API_KEY -u GROK_SANDBOX GROK_DISABLE_AUTOUPDATER=1)
first_line() { awk 'NF { sub(/\r$/, ""); print; exit }' "$@" 2>/dev/null | cut -c1-160; }
semver_of() {  # TEXT -> first X.Y.Z[-pre]
  if [[ $1 =~ ([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?) ]]; then
    local v="${BASH_REMATCH[1]}"
    printf '%s' "${v%.}"
  fi
}
vcmp() {  # A B -> -1, 0 or 1 (numeric parts; a prerelease sorts before its release)
  local a="$1" b="$2" ap="" bp="" i x y
  local -a A B
  [[ $a == *-* ]] && { ap="${a#*-}"; a="${a%%-*}"; }
  [[ $b == *-* ]] && { bp="${b#*-}"; b="${b%%-*}"; }
  IFS=. read -r -a A <<< "$a"
  IFS=. read -r -a B <<< "$b"
  for i in 0 1 2 3; do
    x="${A[i]:-0}"; y="${B[i]:-0}"
    [[ $x =~ ^[0-9]+$ ]] || x=0
    [[ $y =~ ^[0-9]+$ ]] || y=0
    if [ "$((10#$x))" -lt "$((10#$y))" ]; then echo -1; return; fi
    if [ "$((10#$x))" -gt "$((10#$y))" ]; then echo 1; return; fi
  done
  if [ "$ap" = "$bp" ]; then echo 0
  elif [ -z "$ap" ]; then echo 1
  elif [ -z "$bp" ]; then echo -1
  elif [[ $ap < $bp ]]; then echo -1
  else echo 1
  fi
}
# On WSL the Windows PATH is appended to the Linux one, and Windows npm installs leave
# extensionless POSIX shims (%APPDATA%\npm\copilot, claude) that are executable on DrvFs: a
# CLI must never resolve to the Windows side (section 7.6), which record_path drops anyway.
WIN_MNT=""
[ "$CX_HOST" = wsl ] && WIN_MNT="$(_cx_pm_mnt_root "")"
on_windows_side() {  # PATH -> 0 when it lies in a drive directory (<root><letter>/) of the
  # automount root or of /mnt/ (WSL only). Only the drive letters: with [automount] root = /
  # every Linux path starts with the root, and /mnt/data or /mnt/wsl are Linux mounts.
  [ -n "$WIN_MNT" ] || return 1
  case "$1" in "$WIN_MNT"[A-Za-z]/*|/mnt/[A-Za-z]/*) return 0 ;; esac
  return 1
}
path_dirs() {  # the absolute PATH entries, one per line
  local d
  local -a parts=()
  IFS=: read -r -a parts <<< "${PATH:-}"
  for d in "${parts[@]+"${parts[@]}"}"; do
    case "$d" in /*) printf '%s\n' "$d" ;; esac
  done
}
abs_cmd() {  # NAME -> absolute path of an executable on PATH, never one on the Windows side
  local d
  while IFS= read -r d; do
    on_windows_side "$d/" && continue
    [ -f "$d/$1" ] && [ -x "$d/$1" ] && { printf '%s' "$d/$1"; return 0; }
  done < <(path_dirs)
  return 1
}
win_only() {  # NAME -> " (only <path> on the Windows side was found: install it in WSL)" or nothing
  local d
  [ -n "$WIN_MNT" ] || return 0
  while IFS= read -r d; do
    on_windows_side "$d/" || continue
    [ -f "$d/$1" ] && [ -x "$d/$1" ] && { printf ' (only %s on the Windows side was found: install it in WSL)' "$d/$1"; return 0; }
  done < <(path_dirs)
  return 0
}

# ---------------------------------------------------------------- resolution (section 7.6)
B_claude="$(abs_cmd claude)" || B_claude=""
B_grok="$(abs_cmd grok)" || B_grok=""
B_agy="$(abs_cmd agy)" || B_agy=""
B_gh="$(abs_cmd gh)" || B_gh=""
B_git="$(abs_cmd git)" || B_git=""
B_python3="$(abs_cmd python3)" || B_python3=""
B_node="$(abs_cmd node)" || B_node=""
B_copilot=""
COPILOT_BIN_NOTE=""
if [ -n "${GHCP_COPILOT_BIN:-}" ] && [ -f "$GHCP_COPILOT_BIN" ] && [ -x "$GHCP_COPILOT_BIN" ]; then
  case "$GHCP_COPILOT_BIN" in
    /*) B_copilot="$GHCP_COPILOT_BIN" ;;
    *) B_copilot="$(cd -- "$(dirname -- "$GHCP_COPILOT_BIN")" && pwd)/${GHCP_COPILOT_BIN##*/}" ;;
  esac
  if on_windows_side "$B_copilot"; then
    COPILOT_BIN_NOTE="GHCP_COPILOT_BIN=$B_copilot is on the Windows side and was ignored"
    B_copilot=""
  fi
fi
[ -n "$B_copilot" ] || B_copilot="$(abs_cmd copilot)" || B_copilot=""
if [ -z "$B_copilot" ]; then
  p="${XDG_DATA_HOME:-$HOME/.local/share}/gh/copilot/copilot"
  [ -f "$p" ] && [ -x "$p" ] && B_copilot="$p"
fi

POLICY_ON=on
cx_bool "$(cx_opt policy)"
case $? in 1) POLICY_ON=off ;; esac
SIB_TSV="$T/siblings.tsv"
WRAP="$T/wrappers.tsv"
: > "$WRAP"
if [ "$PY" = 1 ]; then
  cx_py doctor-siblings --config-dir "$CFG" --policy "$POLICY_ON" --forwarded "$FORWARDED" \
    --win-settings "${CX_WIN_SETTINGS:-}" --wrappers-out "$WRAP" --root "$CX_ROOT" > "$SIB_TSV" 2>/dev/null \
    || : > "$SIB_TSV"
else
  : > "$SIB_TSV"
fi
declare -A WR=()
while IFS=$'\t' read -r k v; do [ -n "$k" ] && WR[$k]="$v"; done < "$WRAP"
GHCP_MODELS="${WR[ghcp_models]-}"

# verified_info ID CLI VERSION VERIFIED: the version the lanes were last verified against, as an
# info line (no pin: DESIGN section 5.4); never a warning or a failure.
verified_info() {
  if [ "$3" = "$4" ]; then
    chk info "$1" "$S_CLI" "$2 $3 is the version the conductor's $2 lanes were last verified against"
  else
    chk info "$1" "$S_CLI" "$2 $3: the $2 lanes were last verified against $4; nothing is pinned: before each run the lane checks that the live $2 --help still lists every flag it uses (exit 26 when one is missing)"
  fi
}

# ---------------------------------------------------------------- version probes (D8-D12)
V_claude="" V_copilot="" V_grok="" V_agy="" V_gh=""
S_CLI="CLIs"
d8_d12() {
  local rc out
  # D8 claude
  if [ -z "$B_claude" ]; then
    chk warn D8 "$S_CLI" "claude not found$(win_only claude) (only claude -p workers need it on this host)" "claude: https://docs.claude.com/en/docs/claude-code/setup"
  else
    probe claude-version 15 "$B_claude" --version
    out="$(first_line "$T/claude-version.out")"
    if [[ $out =~ ^([0-9]+\.[0-9]+\.[0-9]+)\ \(Claude\ Code\) ]]; then
      V_claude="${BASH_REMATCH[1]}"
      if [ "$(vcmp "$V_claude" "$CX_MIN_CLAUDE")" -ge 0 ]; then
        chk ok D8 "$S_CLI" "claude $V_claude ($B_claude)"
      else
        chk warn D8 "$S_CLI" "claude $V_claude is older than $CX_MIN_CLAUDE" "claude update"
      fi
    else
      chk warn D8 "$S_CLI" "claude --version printed '${out:-nothing}'"
    fi
  fi
  # D9 copilot
  [ -n "$COPILOT_BIN_NOTE" ] && chk warn D9 "$S_CLI" "$COPILOT_BIN_NOTE" "unset GHCP_COPILOT_BIN, or point it at the copilot installed in WSL"
  if [ -z "$B_copilot" ]; then
    chk fail D9 "$S_CLI" "copilot not found (GHCP_COPILOT_BIN, PATH, gh's copilot download)$(win_only copilot)" "npm install -g @github/copilot"
  else
    probe copilot-version 15 env COPILOT_AUTO_UPDATE=false NO_COLOR=1 "$B_copilot" --version
    out="$(cat "$T/copilot-version.out" "$T/copilot-version.err" 2>/dev/null)"
    V_copilot="$(semver_of "$out")"
    if [ -n "$V_copilot" ]; then
      chk ok D9 "$S_CLI" "copilot $V_copilot ($B_copilot)"
      verified_info D9 copilot "$V_copilot" "$CX_VERIFIED_COPILOT"
    else
      chk warn D9 "$S_CLI" "copilot --version printed no version ($B_copilot)"
    fi
  fi
  # D10 grok
  if [ -z "$B_grok" ]; then
    chk fail D10 "$S_CLI" "grok not found$(win_only grok)" "install Grok Build: npm install -g @xai-official/grok"
  else
    probe grok-version 15 "${GROK_ENV[@]}" "$B_grok" --version
    out="$(first_line "$T/grok-version.out")"
    if [[ $out =~ ^grok\ ([0-9]+\.[0-9]+\.[0-9]+[^[:space:]]*)\ \( ]]; then V_grok="${BASH_REMATCH[1]}"; else V_grok="$(semver_of "$out")"; fi
    if [ -n "$V_grok" ]; then
      chk ok D10 "$S_CLI" "${out:-grok $V_grok} ($B_grok)"
      verified_info D10 grok "$V_grok" "$CX_VERIFIED_GROK"
    else
      chk warn D10 "$S_CLI" "grok --version printed '${out:-nothing}'"
    fi
  fi
  # D11 agy
  if [ -z "$B_agy" ]; then
    chk fail D11 "$S_CLI" "agy not found$(win_only agy)" "install Antigravity's agy CLI ($CX_MIN_AGY or newer)"
  elif [ "$HAVE_TIMEOUT" = 0 ]; then
    chk warn D11 "$S_CLI" "agy probe skipped: no timeout command (agy can hang)"
  else
    probe agy-version 10 "${AGY_ENV[@]}" "$B_agy" --version
    rc=$?
    out="$(first_line "$T/agy-version.out")"
    V_agy="$(semver_of "$out")"
    if killed "$rc"; then
      chk warn D11 "$S_CLI" "agy --version hung and was killed"
    elif [ -z "$V_agy" ]; then
      chk warn D11 "$S_CLI" "agy --version printed '${out:-nothing}' (rc $rc)"
    elif [ "$(vcmp "$V_agy" "$CX_MIN_AGY")" -ge 0 ]; then
      chk ok D11 "$S_CLI" "agy $V_agy ($B_agy)"
      verified_info D11 agy "$V_agy" "$CX_VERIFIED_AGY"
    elif [ "$(vcmp "$V_agy" 1.1.10)" -ge 0 ]; then
      chk warn D11 "$S_CLI" "agy $V_agy is older than $CX_MIN_AGY (no --output-format json)" "update agy"
    else
      chk fail D11 "$S_CLI" "agy $V_agy is older than 1.1.10 (it ignores --model in print mode)" "update agy"
    fi
  fi
  # D12 gh
  if [ -z "$B_gh" ]; then
    chk fail D12 "$S_CLI" "gh not found$(win_only gh) (PRs, Copilot review and ghcp-ci-debug need it)" "install GitHub CLI: https://cli.github.com"
  else
    probe gh-version 10 "$B_gh" --version
    out="$(first_line "$T/gh-version.out")"
    if [[ $out =~ ^gh\ version\ ([0-9]+\.[0-9]+\.[0-9]+) ]]; then
      V_gh="${BASH_REMATCH[1]}"
      chk ok D12 "$S_CLI" "gh $V_gh ($B_gh)"
    else
      chk warn D12 "$S_CLI" "gh --version printed '${out:-nothing}'"
    fi
    if [ "${1:-}" = full ]; then
      probe gh-pr-edit-help 10 "$B_gh" pr edit --help
      if grep -q '@copilot' "$T/gh-pr-edit-help.out" "$T/gh-pr-edit-help.err" 2>/dev/null; then
        chk ok D12 "$S_CLI" "gh can request @copilot reviews"
      else
        chk warn D12 "$S_CLI" "gh ${V_gh:-?} cannot request @copilot reviews (measured on >= $CX_MIN_GH_COPILOT_REVIEW); upgrade gh or use the skill's REST fallback" "upgrade gh to $CX_MIN_GH_COPILOT_REVIEW or newer"
      fi
    fi
  fi
}

# D29 (section 15.6, free): every executor run starts its CLI with the worker shims first on
# PATH; a CLI that re-execs itself (or a helper) by name would hit a shim (exit 126, "blocked:
# CX_WORKER") inside every cx-run. Only for a CLI whose own --version probe above succeeded.
d29() {
  local n b v sd="$CX_ROOT/worker-shims" rc ok=""
  [ -d "$sd" ] || return 0
  for n in copilot grok agy; do
    b="B_$n"; b="${!b}"; v="V_$n"; v="${!v}"
    [ -n "$b" ] && [ -n "$v" ] || continue
    case "$n" in
      copilot) probe "$n-shimmed" 15 env PATH="$sd:$PATH" CX_WORKER=1 COPILOT_AUTO_UPDATE=false NO_COLOR=1 "$b" --version ;;
      grok) probe "$n-shimmed" 15 "${GROK_ENV[@]}" PATH="$sd:$PATH" CX_WORKER=1 "$b" --version ;;
      agy) probe "$n-shimmed" 10 "${AGY_ENV[@]}" PATH="$sd:$PATH" CX_WORKER=1 "$b" --version ;;
    esac
    rc=$?
    if [ "$rc" = 126 ] || grep -qs 'blocked: CX_WORKER' "$T/$n-shimmed.out" "$T/$n-shimmed.err"; then
      chk warn D29 "$S_CLI" "$n --version fails with the worker shims first on PATH (exit $rc, blocked: CX_WORKER): it starts a tool by name, so every cx-run of its lane would fail inside the worker" "report it (DESIGN section 20 item 20); meanwhile use the next pool in opus_lane_order"
    elif [ "$rc" = 0 ]; then
      ok="${ok:+$ok, }$n"
    else
      chk warn D29 "$S_CLI" "$n --version exited $rc with the worker shims first on PATH (it succeeded without them)"
    fi
  done
  [ -z "$ok" ] || chk ok D29 "$S_CLI" "$ok start with the worker shims first on PATH (the cx-run worker environment)"
}

# ---------------------------------------------------------------- logins (D15-D19)
# shellcheck disable=SC2034  # the L_* results are read indirectly by write_record
L_claude="" L_copilot="" L_grok="" L_agy="" L_gh=""
TOKEN_ENV=""
GROK_IDS="" AGY_IDS="" COPILOT_CATALOG="" COPILOT_SOURCE=""
S_LOG="Logins (free probes)"
TOKEN_FIX="in a WSL terminal: create a fine-grained PAT with the \"Copilot Requests\" permission, run install -d -m 700 ~/.conductor/secrets && install -m 600 /dev/null ~/.conductor/secrets/copilot-token, then paste the token into that file; cx-wsl ghcp-* calls export it as COPILOT_GITHUB_TOKEN for that call only, so run Copilot lanes from Windows as direct cx-wsl ghcp-* calls (Phase 2 adapters export it for every Copilot lane)"
rec_direct() {  # CLI -> the host record's last direct result (true/false/empty)
  [ -f "$REC" ] || return 0
  local v
  v="$(jget "$REC" "logins.$1.direct")" || v=""
  printf '%s' "$v"
}
# logged_out CLI ID TEXT FIX: the line for a logged-out probe, with the forwarded comparison.
logged_out() {
  local cli="$1" id="$2" text="$3" fix="$4" level="${5:-fail}" d
  if [ "$FORWARDED" = 1 ]; then
    d="$(rec_direct "$cli")"
    if [ "$d" = true ]; then
      local f2
      case "$cli" in
        copilot) f2="$TOKEN_FIX" ;;
        agy) f2="agy keeps its credentials in a file when D-Bus is unreachable: sign in once from a wsl.exe shell (wsl.exe, then agy)" ;;
        gh) f2="gh stores its token in ~/.config/gh/hosts.yml when no keyring is reachable: gh auth login --web --insecure-storage" ;;
        *) f2="keep the CLI's credentials in a file its forwarded environment can read" ;;
      esac
      chk warn "$id" "$S_LOG" "$cli: logged in from a WSL terminal but not through wsl.exe: the keyring is unreachable (D-Bus)" "$f2"
      return
    elif [ -z "$d" ] && [ "$LOGINS_ONLY" = 1 ]; then
      chk "$level" "$id" "$S_LOG" "$text" "$fix"
      chk info "$id" "$S_LOG" "run ~/.conductor/runtime/current/bin/cx-doctor once in a WSL terminal to compare"
      return
    fi
  fi
  chk "$level" "$id" "$S_LOG" "$text" "$fix"
}

COPILOT_ENV=(-u GH_TOKEN -u GITHUB_TOKEN -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL)
SANDBOX_RE='Read-only file system|os error 30|EROFS|ENOTFOUND|ECONNREFUSED|EAI_AGAIN|error sending request|dns error|network is unreachable'
AUTH_RE='No authentication information|not authenticated|authentication (failed|required)|Bad credentials|(^|[^0-9])401([^0-9]|$)|copilot login'
# copilot_probe KEEP_VAR -> sets CP_STATE (in|out|sandbox|timeout|missing|catalog|other) and CP_TEXT.
copilot_probe() {
  local keep="$1" rc
  local -a envs=()
  local e
  for e in "${COPILOT_ENV[@]}"; do
    [ -n "$keep" ] && [ "$e" = "$keep" ] && { envs=("${envs[@]:0:${#envs[@]}-1}"); continue; }
    envs+=("$e")
  done
  CP_TEXT=""
  if [ -n "$GHCP_MODELS" ]; then
    probe ghcp-models 90 env "${envs[@]}" COPILOT_AUTO_UPDATE=false NO_COLOR=1 GHCP_COPILOT_BIN="$B_copilot" \
      "$GHCP_MODELS" --json --refresh
    rc=$?
    CP_TEXT="$(first_line "$T/ghcp-models.err")"
    case "$rc" in
      0)
        if [ "$PY" = 1 ] && [ "$(cx_py parse-models --cli copilot "$T/ghcp-models.out" | grep -c '"shape": "ghcp-models"')" -gt 0 ]; then
          CP_STATE=in
          cp "$T/ghcp-models.out" "$T/copilot-catalog.json"
        else
          CP_STATE=catalog
        fi ;;
      11) CP_STATE=out ;;
      16) CP_STATE=sandbox ;;
      12|124|137) CP_STATE=timeout ;;
      13) CP_STATE=missing ;;
      2) CP_STATE=catalog ;;
      *) CP_STATE=other; CP_TEXT="ghcp-models exited $rc: $CP_TEXT" ;;
    esac
  else
    probe copilot-probe 60 env "${envs[@]}" COPILOT_AUTO_UPDATE=false NO_COLOR=1 \
      "$B_copilot" -p . --model __cx_doctor_probe__ --no-ask-user --no-auto-update --no-color --disable-builtin-mcps
    rc=$?
    CP_TEXT="$(grep -v '^[[:space:]]*$' "$T/copilot-probe.err" "$T/copilot-probe.out" 2>/dev/null | head -n 1 | cut -c1-160)"
    CP_TEXT="${CP_TEXT#*:}"
    if grep -q 'from --model flag is not available' "$T/copilot-probe.err" "$T/copilot-probe.out" 2>/dev/null; then
      CP_STATE=in
    elif killed "$rc"; then
      CP_STATE=timeout
    elif grep -Eiq -- "$SANDBOX_RE" "$T/copilot-probe.err" 2>/dev/null; then
      CP_STATE=sandbox
    elif grep -Eiq -- "$AUTH_RE" "$T/copilot-probe.err" 2>/dev/null; then
      CP_STATE=out
    else
      CP_STATE=other
    fi
  fi
}

# shellcheck disable=SC2034  # the L_* results are read indirectly by write_record
d15_d19() {
  local rc out
  # D15 claude
  if [ -n "$B_claude" ]; then
    probe claude-auth 15 "$B_claude" auth status --json
    rc=$?
    out="$(cat "$T/claude-auth.out" 2>/dev/null)"
    if [[ $out =~ \"loggedIn\"[[:space:]]*:[[:space:]]*true ]]; then
      L_claude=true
      chk ok D15 "$S_LOG" "claude is logged in"
    elif [[ $out =~ \"loggedIn\"[[:space:]]*:[[:space:]]*false ]]; then
      L_claude=false
      logged_out claude D15 "claude is not logged in (only claude -p workers need it)" "claude auth login" warn
    else
      chk warn D15 "$S_LOG" "claude auth status --json was not parseable (rc $rc): $(first_line "$T/claude-auth.err" "$T/claude-auth.out")"
    fi
  fi
  # D16 copilot
  if [ -z "$B_copilot" ]; then
    :
  elif [ -z "$GHCP_MODELS" ] && [ "$V_copilot" != "$CX_VERIFIED_COPILOT" ]; then
    # Without ghcp-models only the raw invalid-model probe is left, measured free on one version.
    chk warn D16 "$S_LOG" "copilot login not probed: ghcp-models is missing, and the raw invalid-model probe is verified free only on copilot $CX_VERIFIED_COPILOT (this is ${V_copilot:-unknown})" "install the ghcp plugin (its ghcp-models probes the login for free)"
  else
    copilot_probe ""
    if [ "$CP_STATE" = out ]; then
      local var
      for var in GH_TOKEN GITHUB_TOKEN; do
        [ -n "${!var:-}" ] || continue
        copilot_probe "$var"
        if [ "$CP_STATE" = in ]; then TOKEN_ENV="$var"; break; fi
        CP_STATE=out
      done
    fi
    case "$CP_STATE" in
      in)
        L_copilot=true
        if [ -n "$TOKEN_ENV" ]; then
          chk ok D16 "$S_LOG" "copilot is logged in through $TOKEN_ENV"
          chk info D16 "$S_LOG" "Copilot signs in through $TOKEN_ENV"
        else
          chk ok D16 "$S_LOG" "copilot is logged in${GHCP_MODELS:+ (ghcp-models --refresh)}"
        fi
        [ -s "$T/copilot-catalog.json" ] && { COPILOT_CATALOG="$T/copilot-catalog.json"; COPILOT_SOURCE=probe; } ;;
      out)
        L_copilot=false
        logged_out copilot D16 "copilot is not logged in" "copilot login" ;;
      sandbox) chk fail D16 "$S_LOG" "Copilot is blocked by Claude Code's Bash sandbox (exit 16: it must write ~/.copilot)" "re-run this Bash call outside Claude Code's sandbox" ;;
      timeout) chk warn D16 "$S_LOG" "the Copilot login probe timed out" ;;
      missing) chk fail D16 "$S_LOG" "ghcp-models could not run copilot ($B_copilot)" ;;
      catalog) chk warn D16 "$S_LOG" "copilot answered, but its model catalog was unparseable: ${CP_TEXT:-no message}" ;;
      *) chk fail D16 "$S_LOG" "copilot login probe: ${CP_TEXT:-no recognizable answer}" ;;
    esac
  fi
  # D17 grok
  if [ -n "$B_grok" ]; then
    probe grok-models 30 "${GROK_ENV[@]}" GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_SKILLS_ENABLED=false \
      GROK_CLAUDE_MCPS_ENABLED=false GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false "$B_grok" models
    rc=$?
    cat "$T/grok-models.out" "$T/grok-models.err" > "$T/grok-models.all" 2>/dev/null
    local n=0
    if [ "$PY" = 1 ]; then
      cx_py parse-models --cli grok "$T/grok-models.all" > "$T/grok-ids.json" 2>/dev/null && GROK_IDS="$T/grok-ids.json"
      n="$(grep -o '"ids": \[[^]]*\]' "$T/grok-ids.json" 2>/dev/null | grep -o '"[^"]*"' | grep -vc '"ids"')"
    fi
    if killed "$rc"; then
      chk warn D17 "$S_LOG" "grok models hung and was killed"
      GROK_IDS=""
    elif grep -q 'You are not authenticated' "$T/grok-models.all" 2>/dev/null; then
      L_grok=false
      logged_out grok D17 "grok is not logged in" "grok login --device-auth"
    elif [ "$rc" -eq 0 ] && [ "${n:-0}" -ge 1 ]; then
      L_grok=true
      chk ok D17 "$S_LOG" "grok is logged in ($n models listed)"
    else
      chk warn D17 "$S_LOG" "grok models (rc $rc): $(first_line "$T/grok-models.all")"
      [ "${n:-0}" -ge 1 ] || GROK_IDS=""
    fi
    # Every grok run approves every tool inside its sandbox, so the sandbox must apply here
    # (grok 1.0.70 refuses to start when it cannot apply a profile; its README says it may
    # instead warn and go on unconfined). Free: grok models under the built-in strict profile.
    # grok 1.0.70 also logs a ProfileApplied event per sandboxed start in its sandbox log: only
    # the bytes appended during this probe, for this probe's cwd, are read (cxlib.py).
    local why="" sev sev0=0 sev1=0 ev_state=none ev_plat="" ev_prof=""
    sev="${GROK_HOME:-$HOME/.grok}/sessions/sandbox-events.jsonl"
    if [ -f "$sev" ] && [ ! -L "$sev" ]; then sev0="$(stat -c %s -- "$sev" 2>/dev/null)" || sev0=0; fi
    probe grok-sandbox 30 "${GROK_ENV[@]}" GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_SKILLS_ENABLED=false \
      GROK_CLAUDE_MCPS_ENABLED=false GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false "$B_grok" --sandbox strict models
    rc=$?
    if [ -f "$sev" ] && [ ! -L "$sev" ]; then sev1="$(stat -c %s -- "$sev" 2>/dev/null)" || sev1=0; fi
    [[ $sev0 =~ ^[0-9]+$ ]] || sev0=0
    [[ $sev1 =~ ^[0-9]+$ ]] || sev1=0
    if [ "$PY" = 1 ] && [ "$sev1" -gt 0 ]; then
      IFS=$'\t' read -r ev_state ev_plat ev_prof < <(cx_py grok-sandbox-event --file "$sev" --from "$sev0" --to "$sev1" --workspace "$PROBE" 2>/dev/null)
      case "$ev_state" in enforced|unenforced) ;; *) ev_state=none ;; esac
    fi
    cat "$T/grok-sandbox.out" "$T/grok-sandbox.err" > "$T/grok-sandbox.all" 2>/dev/null
    why="$(grep -m 1 -iE "sandbox could not be applied|could not apply the '[^']*' sandbox profile|refusing to start with (its protections missing|denied paths unprotected)|without (sandbox )?enforcement" "$T/grok-sandbox.all" 2>/dev/null | head -c 200)"
    if killed "$rc"; then
      chk warn D17 "$S_LOG" "grok --sandbox strict models hung and was killed"
    elif [ -n "$why" ]; then
      chk fail D17 "$S_LOG" "grok cannot apply its sandbox here ($why): every grok run is refused" \
        "on Linux and WSL grok needs Landlock (kernel 5.13 or newer, enabled) and bubblewrap: sudo apt install -y bubblewrap"
    elif [ "$ev_state" = unenforced ]; then
      chk fail D17 "$S_LOG" "grok started --sandbox ${ev_prof:-strict} here without enforcing it (its sandbox log $sev: ProfileApplied, enforced false, platform ${ev_plat:-unknown}): every grok run is refused" \
        "on Linux and WSL grok needs Landlock (kernel 5.13 or newer, enabled) and bubblewrap: sudo apt install -y bubblewrap"
    elif [ "$rc" -eq 0 ]; then
      chk ok D17 "$S_LOG" "grok applies its sandbox here (grok --sandbox strict models)"
    else
      chk warn D17 "$S_LOG" "grok --sandbox strict models (rc $rc): $(first_line "$T/grok-sandbox.all")"
    fi
    if [ "$ev_state" = enforced ]; then
      chk ok D17 "$S_LOG" "grok's sandbox log reports --sandbox ${ev_prof:-strict} enforced here (platform ${ev_plat:-unknown}; $sev)"
    fi
    if [ "${1:-}" = full ] && [ -n "$GROK_IDS" ]; then
      local bulk
      bulk="$(cx_opt grok_bulk_model)"
      if grep -q "\"$bulk\"" "$GROK_IDS" 2>/dev/null; then
        chk ok D17 "$S_LOG" "grok lists $bulk (option grok_bulk_model)"
      else
        chk warn D17 "$S_LOG" "grok does not list $bulk (option grok_bulk_model): an unlisted -m id silently drops --effort"
      fi
    fi
    if [ "${1:-}" = full ]; then
      local prof sbx="${GROK_HOME:-$HOME/.grok}/sandbox.toml" n_cx=0
      prof="$(cx_opt grok_sandbox_profile)"
      case "$prof" in
        auto|cx-workspace)
          [ -f "$sbx" ] && n_cx="$(grep -c '^# cx:begin cx-' "$sbx" 2>/dev/null)"
          chk info D17 "$S_LOG" "grok runs (write, read and review) use their repository's own sandbox profile (cx-<repo>-<hash>, extends strict; ${n_cx:-0} in $sbx), written by a repository's first grok run or cx-init --user-grants" ;;
        off|devbox|workspace|read-only)
          chk fail D17 "$S_LOG" "option grok_sandbox_profile names grok's built-in $prof, which lets grok write its home ~/.grok (its own binary, ripgrep and plugins): every grok run is refused" "set grok_sandbox_profile back to auto" ;;
        *)
          if [ "$PY" = 1 ] && cx_py toml-table "$sbx" "$prof" 2>/dev/null; then
            chk ok D17 "$S_LOG" "grok sandbox profile $prof (option grok_sandbox_profile) is defined in $sbx"
          else
            chk warn D17 "$S_LOG" "grok sandbox profile $prof (option grok_sandbox_profile) is not defined in $sbx: grok runs fail to start" "define it, or set grok_sandbox_profile back to auto"
          fi ;;
      esac
      if [ -f "$sbx" ] && grep -q '^# conductor: the grok sandbox profile every conductor grok writer runs under' "$sbx" 2>/dev/null; then
        chk warn D17 "$S_LOG" "$sbx still holds the cx-workspace profile conductor 0.2.0 wrote (its deny globs are not valid grok paths)" "cx-init --user-grants (it removes exactly that block)"
      fi
      # grok sandboxes its process with Landlock, and a profile with deny lists needs bubblewrap
      # on Linux (grok refuses to start without it, measured 2026-11-06).
      case "$CX_HOST" in
        wsl|linux)
          if abs_cmd bwrap >/dev/null; then
            chk ok D17 "$S_LOG" "bubblewrap (bwrap) is installed (grok's sandbox may need it)"
          else
            chk warn D17 "$S_LOG" "bubblewrap (bwrap) is not installed: grok refuses to start a sandbox profile with deny lists without it" "sudo apt install -y bubblewrap"
          fi
          if [ "$PY" = 1 ]; then
            local ll
            ll="$(cx_py landlock 2>/dev/null)" || ll="unknown"
            case "$ll" in
              abi\ *) chk ok D17 "$S_LOG" "the kernel offers Landlock (ABI ${ll#abi }), which grok's sandbox uses" ;;
              none\ *) chk warn D17 "$S_LOG" "the kernel offers no Landlock (${ll#none }): grok cannot confine its process here" \
                         "Linux 5.13 or newer with Landlock enabled (a current WSL kernel: wsl --update)" ;;
              *) chk info D17 "$S_LOG" "Landlock: ${ll#unknown }" ;;
            esac
          fi ;;
      esac
    fi
  fi
  # D18 agy
  if [ -n "$B_agy" ]; then
    if [ "$HAVE_TIMEOUT" = 0 ]; then
      chk warn D18 "$S_LOG" "agy login probe skipped: no timeout command (agy can hang)"
    else
      local ok=0 k=0
      probe agy-models-json 30 "${AGY_ENV[@]}" "$B_agy" models --output-format json
      rc=$?
      if killed "$rc"; then
        k=1
      else
        if [ "$rc" -eq 0 ] && [ "$PY" = 1 ]; then
          cx_py parse-models --cli agy "$T/agy-models-json.out" > "$T/agy-ids.json" 2>/dev/null
          grep -q '"shape": "json"' "$T/agy-ids.json" 2>/dev/null && grep -q '"authenticated": true' "$T/agy-ids.json" && ok=1
        fi
        if [ "$ok" = 0 ]; then
          probe agy-models 30 "${AGY_ENV[@]}" "$B_agy" models
          rc=$?
          if killed "$rc"; then
            k=1
          elif [ "$PY" = 1 ]; then
            cx_py parse-models --cli agy "$T/agy-models.out" > "$T/agy-ids.json" 2>/dev/null
            grep -q '"authenticated": true' "$T/agy-ids.json" 2>/dev/null && ok=1
          fi
        fi
      fi
      if [ "$k" = 1 ]; then
        chk warn D18 "$S_LOG" "agy models hung and was killed (not an auth problem: #318 or MCP startup)"
      elif [ "$ok" = 1 ]; then
        L_agy=true
        AGY_IDS="$T/agy-ids.json"
        chk ok D18 "$S_LOG" "agy is logged in (models listed)"
      else
        L_agy=false
        logged_out agy D18 "agy listed no models (rc $rc)" "run agy once in a terminal and sign in with Google"
      fi
    fi
    if [ "${1:-}" = full ] && [ "$PY" = 1 ]; then
      local gf="$HOME/.gemini/antigravity-cli/settings.json" g
      if g="$(cx_py agy-grants "$gf" 2>/dev/null)"; then
        chk info D18 "$S_LOG" "$gf holds global agy grants ($g), likely from conductor 0.2.0's cx-init --user-grants: conductor runs no longer need them (each raw agy run gets its own --settings grants) and they apply to every agy session of yours; remove them if you do not want them"
      else
        chk info D18 "$S_LOG" "agy grants are per run (the raw lane passes --settings with write_file(<worktree>) and command() for cx-route, git status and ls); no global grant is needed"
      fi
    fi
  fi
  # D19 gh
  if [ -n "$B_gh" ]; then
    probe gh-auth 15 "$B_gh" auth status
    rc=$?
    if [ "$rc" -eq 0 ]; then
      L_gh=true
      chk ok D19 "$S_LOG" "gh is logged in"
    elif killed "$rc"; then
      chk warn D19 "$S_LOG" "gh auth status timed out"
    else
      L_gh=false
      logged_out gh D19 "gh is not logged in" "gh auth login --web"
    fi
  fi
}

# ---------------------------------------------------------------- host record (section 7.6)
FACTS="$T/facts.tsv"
fact() { printf '%s\t%s\n' "$1" "${2//[$'\t\n\r']/ }" >> "$FACTS"; }
fact_s() { if [ -n "$2" ]; then fact "$1" "$2"; else fact "$1:null" ""; fi; }
fact_b() { case "$2" in true|false) fact "$1:bool" "$2" ;; *) fact "$1:null" "" ;; esac; }
record_path() {
  local d out="" p
  local -a cand=()
  for p in "$B_claude" "$B_copilot" "$B_grok" "$B_agy" "$B_gh" "$B_git" "$B_python3" "$B_node"; do
    [ -n "$p" ] && cand+=("${p%/*}")
  done
  cand+=("$HOME/.local/bin" "$HOME/.npm-global/bin" "$HOME/.bun/bin" "$HOME/.cargo/bin"
         /home/linuxbrew/.linuxbrew/bin /snap/bin /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin)
  for d in "${cand[@]}"; do
    case "$d" in ""|/mnt/[A-Za-z]/*|*/worker-shims|"$CX_ROOT/bin"|"$CFG/plugins/"*) continue ;; /*) ;; *) continue ;; esac
    on_windows_side "$d/" && continue
    [ -d "$d" ] || continue
    local skip=0 w
    for w in "${WR[@]}"; do [ -n "$w" ] && [ "${w%/*}" = "$d" ] && skip=1; done
    [ "$skip" = 1 ] && continue
    case ":$out:" in *":$d:"*) continue ;; esac
    out="${out:+$out:}$d"
  done
  printf '%s' "$out"
}
write_record() {  # [logins_only]
  [ "$PY" = 1 ] || return 2
  : > "$FACTS"
  fact_b forwarded "$([ "$FORWARDED" = 1 ] && echo true || echo false)"
  fact_b logins_only "$([ "${1:-}" = logins_only ] && echo true || echo false)"
  fact host "$CX_HOST"
  fact_s distro "$CX_DISTRO"
  fact home "$HOME"
  fact path "$(record_path)"
  local k
  for k in claude copilot grok agy gh git python3; do
    local v="B_$k"
    fact_s "bin.$k" "${!v}"
  done
  for k in ghcp_delegate ghcp_job ghcp_handoff ghcp_ci_debug ghcp_models ghcp_cloud agy_delegate agy_handoff agy_job agy_media; do
    fact_s "bin.$k" "${WR[$k]-}"
  done
  for k in claude copilot grok agy gh; do
    local v="V_$k"
    fact_s "versions.$k" "${!v}"
  done
  fact_s copilot_home "${COPILOT_HOME:-}"
  fact_s copilot_token_env "$TOKEN_ENV"
  for k in claude copilot grok agy gh; do
    local v="L_$k"
    [ -n "${!v}" ] && fact_b "logins.$k" "${!v}"
  done
  if [ -s "$SIB_JSON" ]; then
    local pj
    pj="$(cx_py json-get "$SIB_JSON" plugins 2>/dev/null)" && fact "plugins:json" "$pj"
  fi
  mkdir -p "$REC_DIR" 2>/dev/null || return 2
  cx_py tsv-to-json "$FACTS" | cx_py host-record --out-dir "$REC_DIR" --hostkey "$CX_HOSTKEY" > /dev/null
}

# ---------------------------------------------------------------- --record-only, --logins-only
if [ "$RECORD_ONLY" = 1 ]; then
  CHK_OUT="$T/discard.tsv"
  d8_d12
  write_record || cx_signal FAILED 2 "cannot write the host record in $REC_DIR"
  exit 0
fi
if [ "$LOGINS_ONLY" = 1 ]; then
  CHK_OUT="$T/discard.tsv"
  d8_d12
  CHK_OUT=""
  d15_d19
  [ "$NO_RECORD" = 1 ] || write_record logins_only || true
  if [ "$PY" = 1 ]; then
    cx_py doctor-render --checks "$CHECKS" --bare --caller "$CALLER"
    rc=$?
  else
    render_plain "$CHECKS"
    rc=0
    [ "$N_FAIL" -eq 0 ] || rc=4
  fi
  [ "$rc" -eq 0 ] || cx_signal CHECKS_FAILED 4 ""
  exit 0
fi

# ---------------------------------------------------------------- the full doctor
S_HOST="Host"
# D30 session (forwarded calls: W10 reports the caller instead).
if [ "$FORWARDED" != 1 ]; then
  session_lines D30 "$S_SESSION"
  if [ "$CX_HOST" = wsl ] && [ "$CX_SESSION" = local ]; then
    case "${CLAUDE_CODE_ENTRYPOINT:-}:${CLAUDE_CODE_DESKTOP_APP_VERSION:-}" in
      claude-desktop*:*|*:?*)
        # Decide from this session, not from the docs: Claude Code puts a plugin's bin/ on the
        # Bash tool's PATH only when the plugin is loaded. A live run on 2026-11-01 found the
        # conductor loaded in a desktop session in WSL (DESIGN section 1.5, section 20 item 66).
        if plugin_bin_on_path; then
          chk ok D30 "$S_SESSION" "Claude desktop app session in WSL: the conductor plugin is loaded in this session (its bin/ is on PATH)"
        elif [ -n "${CLAUDECODE:-}" ]; then
          chk warn D30 "$S_SESSION" "this Claude desktop app session in WSL has not loaded the conductor plugin (its bin/ is not on this session's PATH), so its policy, skill and cx-* commands are missing here" "$DESKTOP_WSL_FIX"
        fi ;;
    esac
  fi
fi
# D1
HBITS="$(cx_trim "${CX_DISTRO:-} ${CX_OS_VERSION:-}")"
[ -n "$CX_WSL_VERSION" ] && HBITS="${HBITS:+$HBITS, }WSL$CX_WSL_VERSION"
case "$CX_HOST" in
  wsl)
    chk ok D1 "$S_HOST" "host wsl${HBITS:+ ($HBITS)}, hostkey $CX_HOSTKEY"
    [ "$CX_WSL_INTEROP" = 0 ] && chk info D1 "$S_HOST" "WSL interop looks disabled (no WSL_DISTRO_NAME, no WSLInterop): Windows-side forwarding needs it"
    [ "$CX_WSL_VERSION" = 1 ] && chk warn D1 "$S_HOST" "this distribution runs WSL1; the conductor is built for WSL2"
    # Calls forwarded from Windows always have WSL_DISTRO_NAME and always use $HOME/.conductor.
    case "${CX_DISTRO_SOURCE:-}" in
      wslpath) chk info D1 "$S_HOST" "WSL_DISTRO_NAME is unset (an ssh, su - or cron shell?); the distribution name $CX_DISTRO came from wslpath -w /" ;;
      os-release) chk warn D1 "$S_HOST" "WSL_DISTRO_NAME is unset and wslpath -w / named no distribution: hostkey $CX_HOSTKEY comes from os-release, while calls forwarded from Windows use wsl-<registered name> and will not find this record" "run cx-doctor from a terminal that wsl.exe opened (not ssh, su - or cron), or from the Windows session" ;;
    esac
    if [ "$FORWARDED" != 1 ] && [ -n "${CX_HOME:-}" ] && [ "${CX_HOME%/}" != "$HOME/.conductor" ]; then
      chk warn D1 "$S_HOST" "CX_HOME=$CX_HOME: calls forwarded from Windows ignore CX_HOME and read $HOME/.conductor (host record, runtime copy)" "unset CX_HOME in your shell profile, then run cx-doctor again"
    fi ;;
  linux) chk ok D1 "$S_HOST" "host linux${HBITS:+ ($HBITS)}, hostkey $CX_HOSTKEY" ;;
  docker) chk warn D1 "$S_HOST" "host docker: treated as a plain Linux host in v1 (Docker lanes arrive in v1.1)" ;;
  macos) chk warn D1 "$S_HOST" "host macos: runs locally, untested" ;;
esac
# D2
if [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; then
  chk ok D2 "$S_HOST" "bash $BASH_VERSION"
else
  chk fail D2 "$S_HOST" "bash $BASH_VERSION is older than 4.4"
fi
pyv="$(python3 -I -V 2>&1 </dev/null)" || pyv=""
if [[ $pyv =~ ^Python\ 3\.([0-9]+) ]] && [ "${BASH_REMATCH[1]}" -ge 8 ]; then
  chk ok D2 "$S_HOST" "$pyv"
else
  chk fail D2 "$S_HOST" "python3 3.8 or newer not found (${pyv:-missing})" "sudo apt install python3"
fi
for tool in timeout setsid flock sha256sum git; do
  if command -v "$tool" >/dev/null 2>&1; then
    chk ok D2 "$S_HOST" "$tool found"
  else
    chk fail D2 "$S_HOST" "$tool not found" "sudo apt install coreutils util-linux git"
  fi
done
if [ -n "$B_git" ]; then
  gv="$("$B_git" --version 2>/dev/null </dev/null)"
  gv="$(semver_of "$gv")"
  if [ -n "$gv" ] && [ "$(vcmp "$gv" 2.31.0)" -ge 0 ]; then
    chk ok D2 "$S_HOST" "git $gv (2.31 or newer: rev-parse --path-format)"
  else
    chk fail D2 "$S_HOST" "git ${gv:-?} is older than 2.31" "upgrade git"
  fi
fi
if [ "$FORWARDED" = 1 ]; then
  ps_src=""
  [ -f "$REC" ] && ps_src="$(jget "$REC" path_source)"
  if [ "$ps_src" != interactive ]; then
    chk info D2 "$S_HOST" "run ~/.conductor/runtime/current/bin/cx-doctor once in a WSL terminal (or /conductor:doctor in a WSL Claude Code session) so the record captures your interactive PATH"
  fi
fi

# D3 plugin files (the installed copy)
S_RT="Runtime"
if [ -z "$INSTALLED_ROOT" ]; then
  chk info D3 "$S_RT" "plugin files are checked on Windows by W6 (no installed copy on this host)"
else
  miss=() noexec=() crl=()
  for f in "${CX_SHIPPED_FILES[@]}"; do
    [ -f "$INSTALLED_ROOT/$f" ] || miss+=("$f")
  done
  for f in "${CX_SHIPPED_EXEC[@]}"; do
    [ -f "$INSTALLED_ROOT/$f" ] && [ ! -x "$INSTALLED_ROOT/$f" ] && noexec+=("$INSTALLED_ROOT/$f")
  done
  present=()
  for f in "${CX_SHIPPED_FILES[@]}"; do [ -f "$INSTALLED_ROOT/$f" ] && present+=("$INSTALLED_ROOT/$f"); done
  if [ "${#present[@]}" -gt 0 ]; then
    mapfile -t crl < <(grep -l $'\r' "${present[@]}" 2>/dev/null)
  fi
  if [ "${#crl[@]}" -gt 0 ]; then
    fixes=("sed -i 's/\\r\$//' $(cx_shell_words "${crl[@]}")")
    X="$CFG/plugins/marketplaces/conductor-for-claude-code"
    if [ -d "$X" ] && command -v git >/dev/null 2>&1; then
      xt="$(git -C "$X" rev-parse --show-toplevel 2>/dev/null </dev/null)" || xt=""
      if [ -n "$xt" ] && [ "$(cd -- "$xt" 2>/dev/null && pwd -P)" = "$(cd -- "$X" && pwd -P)" ]; then
        fixes+=("git -C $(cx_shell_words "$X") -c core.autocrlf=input checkout-index -a -f, then claude plugin update conductor@conductor-for-claude-code")
      fi
    fi
    fixes+=("$CRLF_FALLBACK")
    chk fail D3 "$S_RT" "CRLF line endings in: ${crl[*]}" "${fixes[@]}"
  fi
  if [ "${#miss[@]}" -gt 0 ]; then
    chk fail D3 "$S_RT" "plugin files missing in $INSTALLED_ROOT: ${miss[*]}" "claude plugin update conductor@conductor-for-claude-code (or reinstall the plugin)"
  fi
  if [ "${#noexec[@]}" -gt 0 ]; then
    chk fail D3 "$S_RT" "not executable: ${noexec[*]}" "chmod 0755 $(cx_shell_words "${noexec[@]}")"
  fi
  if [ "${#crl[@]}" -eq 0 ] && [ "${#miss[@]}" -eq 0 ] && [ "${#noexec[@]}" -eq 0 ]; then
    chk ok D3 "$S_RT" "plugin files complete, executable and LF ($INSTALLED_ROOT)"
  fi
fi
# D4 runtime copy
RTV="$CXH/runtime/$CX_VERSION"
if [ -f "$RTV/RUNTIME_STAMP" ] && grep -qx "version=$CX_VERSION" "$RTV/RUNTIME_STAMP" 2>/dev/null; then
  have=""
  shopt -s nullglob dotglob
  for e in "$RTV"/*; do have="$have ${e##*/}"; done
  shopt -u nullglob dotglob
  want=" .claude-plugin RUNTIME_STAMP bin hooks scripts templates worker-shims"
  # shellcheck disable=SC2086  # word splitting of the space-separated entry lists is intended
  sorted="$(printf '%s\n' $have | LC_ALL=C sort | tr '\n' ' ')"
  # shellcheck disable=SC2086  # same
  wsorted="$(printf '%s\n' $want | LC_ALL=C sort | tr '\n' ' ')"
  if [ "$sorted" = "$wsorted" ]; then
    chk ok D4 "$S_RT" "runtime copy $CX_VERSION at $RTV"
  else
    chk warn D4 "$S_RT" "runtime copy $CX_VERSION has unexpected entries (${sorted% })" "cx-doctor --install-runtime"
  fi
else
  chk warn D4 "$S_RT" "no runtime copy $CX_VERSION in $CXH/runtime (the forwarder installs it on first use)" "cx-doctor --install-runtime"
fi
# D5 repo location
if [ "${CX_CALLER_CWD_UNMAPPED:-}" != 1 ] && command -v git >/dev/null 2>&1; then
  top="$(git rev-parse --show-toplevel 2>/dev/null </dev/null)" || top=""
  mnt="$(_cx_pm_mnt_root "")"
  if [ -n "$top" ] && [[ "$top/" == "$mnt"[a-z]/* ]]; then
    if [ "$FORWARDED" = 1 ]; then
      # From the Windows app a Windows folder is the supported place (a desktop session opened on
      # \\wsl.localhost loads no plugins, H8): an info line with W3's wording, never "move it".
      chk info D5 "$S_HOST" "this repository is on a Windows drive ($top): WSL reaches it through /mnt, which is slow for large repos; for a repo that lives in WSL use a WSL terminal (claude, or claude remote-control there), never a desktop session opened on \\\\wsl.localhost (it runs inside WSL without plugins)"
    else
      chk warn D5 "$S_HOST" "this repository is on a Windows drive ($top): /mnt access from WSL is slow; keep repos on the WSL filesystem"
    fi
  fi
  # Calls forwarded from Windows run with an environment built from scratch (section 7.4): no
  # shell rc files, so no ssh-agent (SSH_AUTH_SOCK) and no GPG_TTY for a passphrase prompt.
  if [ -n "$top" ]; then
    url="$(git -C "$top" config --get remote.origin.url 2>/dev/null </dev/null)" || url=""
    sign="$(git -C "$top" config --get commit.gpgsign 2>/dev/null </dev/null)" || sign=""
    case "$url" in
      git@*:*|ssh://*)
        if [ "$FORWARDED" = 1 ] && [ ! -S "${SSH_AUTH_SOCK:-}" ]; then
          chk warn D5 "$S_HOST" "origin is an SSH remote ($url) and calls forwarded from Windows have no ssh-agent: pushing cx/* branches fails with Permission denied (publickey)" \
            "use HTTPS with gh's credential helper: gh auth setup-git && git -C $(cx_shell_words "$top") remote set-url origin https://<host>/<owner>/<repo>.git" \
            "or name the agent socket or a key in ~/.ssh/config (IdentityAgent / IdentityFile), which works without the shell's environment"
        elif [ "$CX_HOST" = wsl ] && [ "$FORWARDED" != 1 ]; then
          chk info D5 "$S_HOST" "origin is an SSH remote: calls forwarded from the Windows app see no ssh-agent from your shell; use gh auth setup-git with an HTTPS remote, or IdentityAgent / IdentityFile in ~/.ssh/config"
        fi ;;
    esac
    if [ "${sign,,}" = true ]; then
      if [ "$FORWARDED" = 1 ]; then
        chk warn D5 "$S_HOST" "commit.gpgsign=true: a forwarded call has no terminal for a passphrase prompt, so the conductor's own commits (Step 3) fail unless the key's passphrase is cached in gpg-agent" \
          "git -C $(cx_shell_words "$top") config commit.gpgsign false (this repository only), or cache the passphrase before delegating"
      elif [ "$CX_HOST" = wsl ]; then
        chk info D5 "$S_HOST" "commit.gpgsign=true: forwarded calls from the Windows app cannot prompt for a passphrase; cache it in gpg-agent first"
      fi
    fi
  fi
fi
# D6 path mapping (WSL)
if [ "$CX_HOST" = wsl ]; then
  if command -v wslpath >/dev/null 2>&1; then
    wu="$(wslpath -u "C:\\" 2>/dev/null </dev/null)" || wu=""
    wu="$(_cx_pm_norm "$wu")"
    pm="$(cx_path_to_wsl --caller win -- "C:\\" 2>/dev/null)" || pm=""
    if [ -n "$wu" ] && [ "$wu" = "$pm" ]; then
      chk ok D6 "$S_HOST" "drive paths map like wslpath (C:\\ -> $pm)"
    else
      chk fail D6 "$S_HOST" "wslpath maps C:\\ to '${wu:-?}', pathmap to '${pm:-?}': the automount root differs" "set CX_MNT_ROOT, or fix [automount] root in /etc/wsl.conf"
    fi
    ww="$(wslpath -w / 2>/dev/null </dev/null)" || ww=""
    wws="${ww//\\//}"
    case "${wws,,}" in
      //wsl\$/*) chk info D6 "$S_HOST" "wslpath -w / prints the legacy prefix ($ww); host paths use \\\\wsl.localhost" ;;
      //wsl.localhost/*) chk info D6 "$S_HOST" "Windows sees this distribution as $ww" ;;
    esac
  else
    chk warn D6 "$S_HOST" "wslpath not found: path mapping not cross-checked"
  fi
fi
# D7 options
if [ "$PY" = 1 ]; then
  OC=()
  for n in "${CX_OPT_NAMES[@]}"; do OC+=(--default "$n=${CX_OPT_DEFAULTS[$n]}"); done
  [ -n "${CX_WIN_SETTINGS:-}" ] && OC+=(--settings "$CX_WIN_SETTINGS")
  OC+=(--settings "$CFG/settings.json")
  top="$(git rev-parse --show-toplevel 2>/dev/null </dev/null)" || top=""
  [ -n "$top" ] && [ "${CX_CALLER_CWD_UNMAPPED:-}" != 1 ] && OC+=(--repo "$top")
  cx_py options-check --tsv "${OC[@]}" >> "$CHECKS" 2>/dev/null
fi

d8_d12 full
d29

# D31 Work locally readiness, D32 workflows and ultracode (info only; D32 describes the host
# where Claude Code runs, so a forwarded call leaves it to W11).
if [ "$PY" = 1 ]; then
  top="$(git rev-parse --show-toplevel 2>/dev/null </dev/null)" || top=""
  [ "${CX_CALLER_CWD_UNMAPPED:-}" = 1 ] && top=""
  np="$(nproc 2>/dev/null </dev/null)" || np=""
  cx_py doctor-session --config-dir "$CFG" --repo "$top" --root "${CX_DETECT_ROOT:-}" --host "$CX_HOST" \
    --claude-version "$V_claude" --nproc "$np" --forwarded "$FORWARDED" \
    --caps "cap_agy=$(cx_opt cap_agy) cap_copilot=$(cx_opt cap_copilot) cap_grok=$(cx_opt cap_grok)" >> "$CHECKS" 2>/dev/null
fi

# D13, D20-D26 (siblings; computed above)
cat "$SIB_TSV" >> "$CHECKS"

# D14 auto-update (information only: nothing is pinned, DESIGN section 5.4). Every conductor run
# turns self-updates off for its own run (the worker environment); the user's CLIs update as
# the user chooses.
S_PIN="Versions"
GCONF="${GROK_HOME:-$HOME/.grok}/config.toml"
au=""
[ "$PY" = 1 ] && au="$(cx_py toml-get "$GCONF" cli auto_update 2>/dev/null)"
chk info D14 "$S_PIN" "auto-update is your choice (COPILOT_AUTO_UPDATE=${COPILOT_AUTO_UPDATE-unset}, GROK_DISABLE_AUTOUPDATER=${GROK_DISABLE_AUTOUPDATER-unset}, AGY_CLI_DISABLE_AUTO_UPDATE=${AGY_CLI_DISABLE_AUTO_UPDATE-unset}, grok [cli] auto_update ${au:-not set}): each conductor run turns it off for that run only, and each lane checks the live --help for its flags first"

d15_d19 full

# D27 stray grok worker
if command -v ps >/dev/null 2>&1; then
  ps -eo args > "$T/ps.txt" 2>/dev/null
  if grep -Eq '(^|/)grok(\.js)? worker( |$)' "$T/ps.txt" 2>/dev/null; then
    chk warn D27 "$S_HOST" "$(cx_py const CURSOR_WORKER_MSG 2>/dev/null || printf 'a grok worker process is running; stop it')"
  fi
fi
# D28 billing and account switches
for v in COPILOT_MODEL COPILOT_ALLOW_ALL COPILOT_AUTO_TIER COPILOT_PROVIDER_BASE_URL; do
  [ -n "${!v+x}" ] || continue
  chk warn D28 "$S_HOST" "$v is set: it can silently change the model, permissions or endpoint of every Copilot run$([ "$v" = COPILOT_MODEL ] && printf ' (an unknown id bills the default model)')" "unset $v (the Phase 1 command prefixes unset it per command)"
done
for v in XAI_API_KEY GEMINI_API_KEY GOOGLE_API_KEY ANTHROPIC_API_KEY; do
  [ -n "${!v+x}" ] || continue
  chk warn D28 "$S_HOST" "$v is set: it bills an API account instead of the subscription" "unset $v"
done
for v in GH_TOKEN GITHUB_TOKEN; do
  [ -n "${!v+x}" ] || continue
  if [ "$v" = "$TOKEN_ENV" ]; then
    chk info D28 "$S_HOST" "Copilot signs in through $v"
  else
    chk warn D28 "$S_HOST" "$v is set: it can change the account Copilot uses" "unset $v, unless Copilot signs in through it"
  fi
done

# The Windows report (forwarded from Git Bash): W lines, and the W7 lite-reader cross-check.
EXTRA=""
if [ -n "$WIN_REPORT" ] && [ -f "$WIN_REPORT" ]; then
  EXTRA="$T/windows.tsv"
  tr -d '\r' < "$WIN_REPORT" > "$EXTRA"
  if [ "$PY" = 1 ] && [ -n "${CX_WIN_SETTINGS:-}" ] && [ -f "$CX_WIN_SETTINGS" ]; then
    real="$(cx_py conductor-options "$CX_WIN_SETTINGS" 2>/dev/null)"
    printf '%s\n' "$real" > "$T/winopts.json"
    while IFS=$'\t' read -r st id name val; do
      [ "$st" = meta ] && [ "$id" = lite ] || continue
      rv="$(jget "$T/winopts.json" "$name")" || rv=""
      [[ $rv =~ ^[A-Za-z0-9._-]*$ ]] || rv="(not readable by the lite reader: $rv)"
      if [ "$rv" != "$val" ]; then
        chk warn W7 "$W_SEC" "Git Bash's lite reader sees $name='${val}', the real parse '${rv}'" "keep $name a plain value ([A-Za-z0-9._-]) in the conductor's pluginConfigs options"
      fi
    done < "$EXTRA"
  fi
fi

# Pools
POOLS_JSON=""
if [ "$POOLS" = 1 ] && [ "$PY" = 1 ]; then
  if [ -n "$SET_MTD" ]; then
    if cx_py pools-mtd --file "$CXH/pools.json" --set "$SET_MTD" > /dev/null; then
      chk info pools-copilot Pools "recorded $SET_MTD month-to-date Copilot credits in $CXH/pools.json"
    else
      chk fail pools-copilot Pools "cannot write $CXH/pools.json"
    fi
  fi
  CAT_AGE=""
  if [ -z "$COPILOT_CATALOG" ]; then
    cache="${XDG_CACHE_HOME:-$HOME/.cache}/ghcp-claude/models.json"
    if [ -f "$cache" ]; then
      COPILOT_CATALOG="$cache"
      COPILOT_SOURCE=cache
      CAT_AGE=$(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || date +%s) ))
    fi
  fi
  UARGS=()
  if [ "$AGY_USAGE" = 1 ]; then
    if [ -n "$B_agy" ] && [ "$HAVE_TIMEOUT" = 1 ]; then
      probe agy-usage 45 "${AGY_ENV[@]}" "$B_agy" -p /usage --output-format json
      UARGS=(--agy-usage "$T/agy-usage.out" --agy-usage-rc "$?")
    fi
    UARGS+=(--agy-usage-requested 1)
  fi
  POOLS_JSON="$T/pools.json"
  [ -n "$AGY_IDS" ] && UARGS+=(--agy-ids "$AGY_IDS")
  [ -n "$COPILOT_CATALOG" ] && UARGS+=(--copilot-catalog "$COPILOT_CATALOG")
  [ -n "$CAT_AGE" ] && UARGS+=(--catalog-age "$CAT_AGE")
  [ -n "$GROK_IDS" ] && UARGS+=(--grok-ids "$GROK_IDS")
  cx_py doctor-pools --copilot-source "${COPILOT_SOURCE:-probe}" \
    "${UARGS[@]+"${UARGS[@]}"}" --pools-file "$CXH/pools.json" --ledger "$(cx_expand_tilde "$(cx_opt ledger_path)")" \
    --slug-tpl "$(cx_opt agy_opus_slug_tpl)" --opus-id "$(cx_opt copilot_opus_id)" \
    --xhigh-ok "$(cx_opt copilot_xhigh_ok)" --reserve-pct "$(cx_opt copilot_reserve_pct)" \
    --mtd-max-age "$(cx_opt copilot_mtd_max_age_days)" --floor-pct "$(cx_opt agy_claude_floor_pct)" \
    --bulk-model "$(cx_opt grok_bulk_model)" --out-json "$POOLS_JSON" >> "$CHECKS" 2>/dev/null || POOLS_JSON=""
fi

# The host record
RECORD=""
if [ "$NO_RECORD" = 0 ]; then
  if write_record; then
    RECORD="$REC"
  else
    chk warn D2 "$S_HOST" "could not write the host record in $REC_DIR"
  fi
fi

# Render
if [ "$PY" = 0 ]; then
  plain_report "conductor doctor $CX_VERSION: host $CX_HOST, caller $CALLER, session $SESSION (python3 missing: plain report)" "$CHECKS"
  cx_signal CHECKS_FAILED 4 ""
fi
HA=(host "$CX_HOST" hostkey "$CX_HOSTKEY")
if [ -n "$CX_DISTRO" ]; then HA+=(distro "$CX_DISTRO"); else HA+=(distro:null ""); fi
if [ -n "$CX_OS_ID" ]; then HA+=(os_id "$CX_OS_ID"); else HA+=(os_id:null ""); fi
if [ -n "$CX_OS_VERSION" ]; then HA+=(os_version "$CX_OS_VERSION"); else HA+=(os_version:null ""); fi
if [ -n "$CX_WSL_VERSION" ]; then HA+=(wsl_version:int "$CX_WSL_VERSION"); else HA+=(wsl_version:null ""); fi
HA+=(arch "$CX_ARCH" kernel "$CX_KERNEL" session "$SESSION")
if [ -n "$ATTENDED" ]; then HA+=(attended:int "$ATTENDED"); else HA+=(attended:null ""); fi
HOST_JSON="$(cx_py json "${HA[@]}")"
cx_emit HOST "${HA[@]}"
[ -n "$POOLS_JSON" ] && cx_py emit-obj POOLS "$POOLS_JSON" >&2
RARGS=(--checks "$CHECKS" --host-json "$HOST_JSON" --caller "$CALLER" --session "$SESSION" --attended "$ATTENDED" --emit-doctor)
[ -n "$EXTRA" ] && RARGS+=(--extra "$EXTRA")
[ -n "$RECORD" ] && RARGS+=(--record "$RECORD")
[ -n "$POOLS_JSON" ] && RARGS+=(--pools "$POOLS_JSON")
[ "$JSON" = 1 ] && RARGS+=(--json)
cx_py doctor-render "${RARGS[@]}"
rc=$?
case "$rc" in
  0) exit 0 ;;
  4) cx_signal CHECKS_FAILED 4 "" ;;
  *) cx_signal FAILED 2 "rendering the report failed (rc $rc)" ;;
esac
