#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# cx-wsl - runs one allow-listed WSL-side tool with the conductor's per-tool environment
# (docs/DESIGN.md section 7.7). On Git Bash it forwards into WSL like every cx-* command, so the
# Windows app can delegate before cx-run exists; in WSL or on Linux it runs the tool here.
#
# Usage: cx-wsl TOOL [ARG...]
#        cx-wsl -h|--help | --version
#
# TOOL is one of
#   ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models    the ghcp plugin's wrappers
#   ghcp-cloud                                                        (the Copilot cloud agent, via gh)
#   agy-delegate agy-job                                              the antigravity plugin's
#   agy grok gh git                                                   the CLIs
#   bash                                                              /bin/bash (cx-wsl bash -s < FILE)
# and resolves to an absolute path from the host record $CX_HOME/hosts/<hostkey>.json that
# cx-doctor writes (never from PATH, never a Windows-side path under the automount root; a
# sibling wrapper that moved is re-resolved once from installed_plugins.json). Not allowed:
# copilot (always through ghcp), claude, agy-handoff and agy-media (both always pass --yolo,
# machine-wide) and the cx-* commands (they forward themselves).
#
# Environment: PATH = the sibling wrapper directories, the conductor's bin/, then the record's
# path. Per-tool prefixes (DESIGN section 12.2): ghcp-* unset COPILOT_MODEL COPILOT_ALLOW_ALL
# COPILOT_AUTO_TIER COPILOT_PROVIDER_BASE_URL and set CX_WORKER=1 COPILOT_AUTO_UPDATE=false
# (and GHCP_COPILOT_BIN, when unset, to the recorded copilot binary; and COPILOT_GITHUB_TOKEN,
# when unset, from $CX_HOME/secrets/copilot-token if that is a regular 0600 file you own: the
# keyring route for Copilot logins that wsl.exe cannot reach; never for bash or any other tool);
# agy and agy-* unset GEMINI_API_KEY GOOGLE_API_KEY and set CX_WORKER=1
# AGY_CLI_DISABLE_AUTO_UPDATE=true; grok unsets XAI_API_KEY GROK_SANDBOX and sets CX_WORKER=1
# GROK_DISABLE_AUTOUPDATER=1 GROK_CLAUDE_{HOOKS,SKILLS,MCPS,RULES,AGENTS}_ENABLED=false; gh, git
# and bash run with the environment unchanged (a shell step carries its own prefixes).
# Arguments pass byte for byte: paths in them must be WSL paths (/home/...). For bash -s with a
# step on stdin (not a terminal), a CR before each LF is stripped, with a cx-wsl: note; the step
# is buffered in $CX_HOME/tmp (0700), never in /tmp, which every strict-based grok run may write.
#
# grok runs (every form that takes a slot, below): only under conductor's cx-strict profile and
# with an absolute --cwd DIR (DESIGN section 12.2): every --sandbox must name cx-strict, else exit
# 1 before the slot (grok's built-ins other than strict write ~/.grok: off and devbox everywhere,
# workspace and read-only its own binary, ripgrep and plugins, measured on 1.0.70; no --sandbox
# means no sandbox at all; the built-in strict cannot read the resolver file on WSL, where
# /etc/resolv.conf links to /mnt/wsl/resolv.conf, so grok resolves no host name there). cx-strict
# extends strict with read-only access to the directories that hold this host's resolver and TLS
# files outside strict's read set, and nothing else (none on most hosts; cx-doctor D17 lists
# them). Once the slot is held, cx-wsl writes it into ${GROK_HOME:-~/.grok}/sandbox.toml when it
# is missing or differs (cxlib.py grok-profile --strict, under $CX_HOME/locks/grok-sandbox.lock,
# as the grok lane writes a repository's profile: any other definition of the name is replaced),
# then runs the grok lane's per-run check (free; a .grok/sandbox.toml in DIR refuses the call, 2):
# grok --sandbox cx-strict models in DIR and the
# bytes it appended to grok's sandbox log (normalize.py grok-check): a sandbox not applied, an
# unenforced start or a write grant into grok's home refuses the call (2), and a resolver file the
# logged profile cannot read gives a note. cx-wsl runs grok from DIR, so the process's working
# directory, which strict lets grok write, is --cwd too.
#
# Pool slots (DESIGN section 15.3): an executor call first takes a slot of its pool, shared by
# every session, Work locally thread and forwarded call on this computer, and holds it until
# the tool and every child that inherited it have exited (a ghcp-job or agy-job started this
# way keeps it for the whole job): copilot (cap_copilot) for ghcp-delegate, ghcp-handoff,
# ghcp-ci-debug and ghcp-job start; agy (cap_agy, plus the agy launch lock for the whole call)
# for agy-delegate, agy-job start and agy runs; grok (cap_grok) for grok runs. Free forms take
# none: --help, --version, ghcp-delegate/agy-delegate --print-command, the other ghcp-job and
# agy-job subcommands, ghcp-models, ghcp-cloud (the agent runs on GitHub), agy models and the
# zero-quota agy -p /usage|/model|/config probes, grok -v|models|usage|inspect|login|logout. gh,
# git and bash take none (a shell step takes its own). A busy pool prints one note and waits up
# to CX_SLOT_WAIT_SECS seconds (default 600; 0 = no wait). An agy call while agy dispatch is
# paused ($CX_HOME/state/agy-paused, after a wrong_tree result) exits 28 once it has its slot.
#
# Exit codes: the tool's own status (0-255), its stdout and stderr unchanged, no CX_* line
# added. cx-wsl's own failures: 1 usage error (no TOOL, a tool outside the list, a grok run
# without --sandbox cx-strict or without an absolute --cwd directory); 2 FAILED (the
# bash -s step could not be buffered, the lock directory is unusable, or a grok run's cx-strict
# profile could not be written or its check refused it); 13 CLI_MISSING (no
# host record, or the tool is not recorded or not executable: run cx-doctor first, see the
# note); 28 NO_CAPACITY (no slot of the tool's pool within CX_SLOT_WAIT_SECS, or its cap is 0:
# use the next pool; agy paused); and from Git Bash forwarding 40 FORWARD_FAILED, 41 RUNTIME_MISSING, 42
# PATH_UNMAPPABLE (the cwd has no WSL path) and 43 HOST_UNSUPPORTED (also in a cloud session,
# before anything runs).

set -uo pipefail
unset CDPATH
CX_PROG=cx-wsl
HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "$HERE/lib/common.sh"
# shellcheck source=lib/options.sh
. "$HERE/lib/options.sh"

[ $# -gt 0 ] && cx_help_version "$1"
[ $# -gt 0 ] || cx_usage_error "missing TOOL (one of: ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models ghcp-cloud agy-delegate agy-job agy grok gh git bash)"
TOOL="$1"
case "$TOOL" in
  ghcp-delegate|ghcp-job|ghcp-handoff|ghcp-ci-debug|ghcp-models|ghcp-cloud|agy-delegate|agy-job|agy|grok|gh|git|bash) ;;
  *) cx_usage_error "not allowed: $TOOL (allowed: ghcp-delegate ghcp-job ghcp-handoff ghcp-ci-debug ghcp-models ghcp-cloud agy-delegate agy-job agy grok gh git bash)" ;;
esac
cx_forward_if_needed cx-wsl "$@"
shift

# Executor host: resolve the tool from the host record (section 7.6).
REC="${CX_HOME:-$HOME/.conductor}/hosts/$CX_HOSTKEY.json"
if [ ! -f "$REC" ]; then
  cx_note "no host record $REC: run cx-doctor once (it records where $TOOL lives): from a Windows session it forwards into WSL and records what it finds; for your full interactive PATH run /conductor:doctor in a Claude Code session in WSL, or ~/.conductor/runtime/current/bin/cx-doctor in a WSL terminal (cx-doctor itself is not on a plain terminal's PATH; create that copy once with /conductor:doctor --install-runtime)"
  cx_signal CLI_MISSING 13 "no host record for $CX_HOSTKEY"
fi
if ! cx_py_ok; then
  cx_note "python3 is required on the executor host to read the host record"
  cx_signal CLI_MISSING 13 "python3 missing on the executor host"
fi
RES=()
_cx_source_pathmap
mapfile -t RES < <(cx_py wsl-resolve --record "$REC" --tool "$TOOL" --config-dir "${CLAUDE_CONFIG_DIR:-$HOME/.claude}" \
  --conductor-bin "$CX_ROOT/bin" --mnt-root "$(_cx_pm_mnt_root "")" 2>/dev/null)
ABS="${RES[0]-}"
NEWPATH="${RES[1]-}"
COPILOT_BIN="${RES[2]-}"
if [ -z "$ABS" ] || [ -z "$NEWPATH" ] || [ ! -x "$ABS" ]; then
  cx_note "$TOOL is not recorded in $REC, or not executable there: install it in WSL, then run cx-doctor from this session, /conductor:doctor in a Claude Code session in WSL, or ~/.conductor/runtime/current/bin/cx-doctor in a WSL terminal (create that copy once with /conductor:doctor --install-runtime)"
  cx_signal CLI_MISSING 13 "$TOOL not found in the host record"
fi

# The pool a call of TOOL with these arguments takes a slot of (header; DESIGN section 15.3), or
# nothing for a free form.
slot_pool() {
  local t="$1" a prev=""
  shift
  case "${1-}" in -h|--help|--version) return 0 ;; esac
  case "$t" in
    ghcp-delegate|agy-delegate)
      for a in "$@"; do [ "$a" = --print-command ] && return 0; done
      [ "$t" = ghcp-delegate ] && echo copilot || echo agy ;;
    ghcp-handoff|ghcp-ci-debug) echo copilot ;;
    ghcp-job) [ "${1-}" = start ] && echo copilot ;;
    agy-job) [ "${1-}" = start ] && echo agy ;;
    agy)
      case "${1-}" in -v|-V|help|models) return 0 ;; esac
      for a in "$@"; do
        [ "$a" = --new-project ] && { echo agy; return 0; }
      done
      for a in "$@"; do
        if [ "$prev" = -p ]; then
          case "$a" in /usage|/model|/config) ;; *) echo agy; return 0 ;; esac
        fi
        prev="$a"
      done
      for a in "$@"; do [ "$a" = -p ] && return 0; done
      echo agy ;;
    grok)
      case "${1-}" in -v|help|version|models|usage|inspect|login|logout) return 0 ;; esac
      echo grok ;;
  esac
  return 0
}
POOL="$(slot_pool "$TOOL" "$@")"

# grok_run_args ARG...: a grok run (header) names --sandbox cx-strict, every time it names
# --sandbox, and an absolute --cwd directory (GROK_CWD); exit 1 otherwise, before the slot.
GROK_CWD=""
GROK_SB_WHY="grok's built-ins but strict let it write ~/.grok (its own binary, ripgrep and plugins), and strict cannot read the resolver file on WSL (/etc/resolv.conf links to /mnt/wsl/resolv.conf there): cx-strict is strict plus this host's resolver directories"
grok_run_args() {
  local a prev="" n=0
  for a in "$@"; do
    case "$prev" in
      --sandbox)
        [ "$a" = cx-strict ] || cx_usage_error "cx-wsl grok runs only under --sandbox cx-strict, not --sandbox '$a' ($GROK_SB_WHY)"
        n=$((n + 1)) prev=""; continue ;;
      --cwd) GROK_CWD="$a" prev=""; continue ;;
    esac
    case "$a" in
      --sandbox=*)
        [ "${a#--sandbox=}" = cx-strict ] || cx_usage_error "cx-wsl grok runs only under --sandbox cx-strict, not $a ($GROK_SB_WHY)"
        n=$((n + 1)) ;;
      --cwd=*) GROK_CWD="${a#--cwd=}" ;;
    esac
    prev="$a"
  done
  [ "$prev" != --sandbox ] && [ "$n" -gt 0 ] \
    || cx_usage_error "cx-wsl grok runs only under --sandbox cx-strict (without --sandbox grok runs with no sandbox at all)"
  case "$GROK_CWD" in
    /*) [ -d "$GROK_CWD" ] || cx_usage_error "--cwd $GROK_CWD is not a directory" ;;
    *) cx_usage_error "cx-wsl grok runs need an absolute --cwd DIR (a directory of their own, such as \$OUT/msg): grok's strict profile lets it write its working directory" ;;
  esac
}
[ "$TOOL" != grok ] || [ -z "$POOL" ] || grok_run_args "$@"

if [ -n "$POOL" ]; then
  # shellcheck source=lib/locks.sh
  . "$HERE/lib/locks.sh"
  cx_slot_take "$POOL" || exit $?
  # agy dispatch stops after a wrong_tree result (cx-run's agy lane wrote the pause): checked
  # after the slot wait, so a call that queued before the pause never starts agy.
  if [ "$POOL" = agy ] && [ -e "${CX_HOME:-$HOME/.conductor}/state/agy-paused" ]; then
    cx_note "agy dispatch is paused (${CX_HOME:-$HOME/.conductor}/state/agy-paused: a wrong_tree result); run cx-job unpause agy once the user has checked the other trees"
    cx_signal NO_CAPACITY 28 "agy dispatch is paused"
  fi
fi

# grok_strict_ready: a grok run's cx-strict profile written (when missing or different) and
# checked (header); exit 2 FAILED when it cannot be written or the check refuses it.
GROK_ENVV=(env -u XAI_API_KEY -u GROK_SANDBOX PATH="$NEWPATH" CX_WORKER=1 GROK_DISABLE_AUTOUPDATER=1
  GROK_CLAUDE_HOOKS_ENABLED=false GROK_CLAUDE_SKILLS_ENABLED=false GROK_CLAUDE_MCPS_ENABLED=false
  GROK_CLAUDE_RULES_ENABLED=false GROK_CLAUDE_AGENTS_ENABLED=false)
grok_log_size() {
  local n=""
  if [ -f "$1" ] && [ ! -L "$1" ]; then n="$(stat -c %s -- "$1" 2>/dev/null)"; fi
  [[ $n =~ ^[0-9]+$ ]] || n=0
  printf '%s\n' "$n"
}
grok_strict_ready() {
  local gh="${GROK_HOME:-$HOME/.grok}" cxh="${CX_HOME:-$HOME/.conductor}" out chk sev ev0 ev1 crc v l
  # As in the grok lane: a per-project .grok/sandbox.toml in grok's cwd could redefine the profile.
  if [ -e "$GROK_CWD/.grok/sandbox.toml" ] || [ -L "$GROK_CWD/.grok/sandbox.toml" ]; then
    cx_note "--cwd $GROK_CWD holds .grok/sandbox.toml (a per-project grok sandbox file that could redefine cx-strict): empty that directory first (the commit-message lines of the skill do)"
    cx_signal FAILED 2 "--cwd $GROK_CWD holds .grok/sandbox.toml: grok never started there"
  fi
  mkdir -p -- "$cxh/locks" 2>/dev/null || cx_signal FAILED 2 "cannot create $cxh/locks"
  out="$(cx_py grok-profile --strict --sandbox "$gh/sandbox.toml" --lock "$cxh/locks/grok-sandbox.lock" \
           --workspace "$GROK_CWD" --home "$HOME" --grok-home "$gh" --cx-home "$cxh" 2>&1)" \
    || { cx_note "cannot write the grok sandbox profile cx-strict into $gh/sandbox.toml: ${out:-no output}"
         cx_signal FAILED 2 "cannot write the grok sandbox profile cx-strict into $gh/sandbox.toml"; }
  case "$out" in ""|"same cx-strict") ;; *) cx_note "$out" ;; esac
  chk="$(cx_mktemp cx-wsl-grok-check)" || cx_signal FAILED 2 "cannot create a temporary file in $cxh/tmp"
  sev="$gh/sessions/sandbox-events.jsonl"
  ev0="$(grok_log_size "$sev")"
  (cd -- "$GROK_CWD" && cx_timeout 30 "${GROK_ENVV[@]}" "$ABS" --sandbox cx-strict models) < /dev/null > "$chk" 2>&1
  crc=$?
  ev1="$(grok_log_size "$sev")"
  v="$(python3 -I "$CX_LIB/normalize.py" grok-check --profile cx-strict --workspace "$GROK_CWD" --grok-home "$gh" \
         --probe-out "$chk" --probe-rc "$crc" --events "$sev" --from "$ev0" --to "$ev1")" \
    || { rm -f -- "$chk"; cx_signal FAILED 2 "the check of grok's sandbox profile cx-strict failed (normalize.py grok-check)"; }
  rm -f -- "$chk"
  while IFS= read -r l; do
    case "$l" in "note "*) cx_note "${l#note }" ;; esac
  done <<< "$v"
  v="${v%%$'\n'*}"
  case "$v" in
    ok) ;;
    "refuse "*) cx_note "${v#refuse }: refused before grok started"
                cx_signal FAILED 2 "${v#refuse }: refused before grok started" ;;
    *) cx_signal FAILED 2 "the check of grok's sandbox profile cx-strict gave no verdict" ;;
  esac
}
[ "$TOOL" != grok ] || [ -z "$POOL" ] || grok_strict_ready

case "$TOOL" in
  ghcp-*)
    # The copilot binary the doctor recorded, unless the caller chose one: an
    # unset or invalid GHCP_COPILOT_BIN makes ghcp fall back to whatever copilot is on PATH.
    [ -n "${GHCP_COPILOT_BIN:-}" ] || [ -z "$COPILOT_BIN" ] || export GHCP_COPILOT_BIN="$COPILOT_BIN"
    # The token route (cx-doctor --login-help copilot, W9): when Copilot's keyring login is
    # unreachable through wsl.exe, a fine-grained PAT in $CX_HOME/secrets/copilot-token signs in
    # this ghcp-* call only. Never a symlink, someone else's file or one others can read.
    TOKF="${CX_HOME:-$HOME/.conductor}/secrets/copilot-token"
    if [ -z "${COPILOT_GITHUB_TOKEN:-}" ] && [ -e "$TOKF" ]; then
      if [ -f "$TOKF" ] && [ ! -L "$TOKF" ] && [ -O "$TOKF" ] && [ "$(stat -c %a -- "$TOKF" 2>/dev/null)" = 600 ]; then
        IFS= read -r TOK < "$TOKF" || true
        TOK="${TOK//[[:space:]]/}"
        [ -n "$TOK" ] && export COPILOT_GITHUB_TOKEN="$TOK"
        unset TOK
      else
        cx_note "ignoring $TOKF: it must be a regular file you own with mode 0600 (chmod 600 it)"
      fi
    fi
    exec env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL \
      PATH="$NEWPATH" CX_WORKER=1 COPILOT_AUTO_UPDATE=false "$ABS" "$@" ;;
  agy|agy-*)
    exec env -u GEMINI_API_KEY -u GOOGLE_API_KEY \
      PATH="$NEWPATH" CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true "$ABS" "$@" ;;
  grok)
    # From its --cwd (header): the process's working directory and --cwd are the same.
    [ -z "$GROK_CWD" ] || cd -- "$GROK_CWD" || cx_usage_error "cannot change to --cwd $GROK_CWD"
    exec "${GROK_ENVV[@]}" "$ABS" "$@" ;;
  bash)
    # A shell step (cx-wsl bash -s < FILE) written on the Windows side may come out CRLF: a CR
    # would end up in every word (`. "$HOME/.conductor/out/t1/vars.sh"\r` fails, WT stays
    # empty, `git -C "$WT" add -A` runs in the cwd). Strip a CR before each LF and say so; a
    # terminal on stdin is passed through untouched.
    if [ "${1-}" = -s ] && [ ! -t 0 ]; then
      # Buffered in $CX_HOME/tmp (0700, cx_tmpdir), never in /tmp: a grok run going on meanwhile
      # may write /tmp, and lines it appended to the step would run here, unsandboxed.
      STEP="$(cx_mktemp cx-wsl-step)" || cx_signal FAILED 2 "cannot create a temporary file in ${CX_HOME:-$HOME/.conductor}/tmp"
      cat > "$STEP" || { rm -f "$STEP"; cx_signal FAILED 2 "cannot read the step on stdin"; }
      if grep -q $'\r$' "$STEP"; then
        sed -i 's/\r$//' "$STEP"
        cx_note "the step on stdin had CRLF line endings; ran it with LF (write step files with LF)"
      fi
      exec 3< "$STEP"
      rm -f "$STEP"
      exec env PATH="$NEWPATH" "$ABS" "$@" <&3 3<&-
    fi
    exec env PATH="$NEWPATH" "$ABS" "$@" ;;
  *)
    exec env PATH="$NEWPATH" "$ABS" "$@" ;;
esac
