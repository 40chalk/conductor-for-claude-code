#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
# wsl-entry.sh - the WSL side of the conductor forwarder (docs/DESIGN.md section 7.4).
#
# Started by forward-wsl.sh through
#   wsl.exe [-d D] --cd ~ --exec /bin/bash --noprofile --norc .conductor/runtime/<v>/scripts/host/wsl-entry.sh
# with CX_FWD_WIN (the Windows path of the transport directory) passed through WSLENV. It has no
# argv contract. It maps the transport directory, writes "started", checks the meta version,
# builds the target's environment from scratch (env -i plus a fixed list: the login and
# keyring variables, PATH from the host record, the auto-update switches, the allow-listed
# variables from the transport, CX_FORWARDED=1 CX_CALLER=gitbash CX_CALLER_CWD_WIN
# CX_WIN_SETTINGS), maps the caller's cwd, emits CX_FORWARD (not for cx-wsl) and runs
# scripts/<cmd>.sh from this runtime copy, writing its process group to "pgid" so the Git Bash
# side can stop it: its own group (a background job) without a terminal, wsl-entry's group (in
# the foreground) when wsl-entry leads the terminal's foreground group, so tty reads and Ctrl-C
# work. A watchdog stops the target when wsl.exe goes away.
#
# Exit codes: the target's status (it prints its own CX_* lines); 40 (no CX_SIGNAL: the
# transport directory is unusable, the Git Bash side owns that signal); 2 FAILED (meta names a
# command outside the forwarder's list); 13 CLI_MISSING (the command is not in this runtime);
# 41 RUNTIME_MISSING (meta version mismatch); 42 PATH_UNMAPPABLE (cwd unmappable for cx-init,
# cx-run, cx-fanout, cx-gate, cx-wsl). On INT/TERM/HUP it forwards TERM to the target's process
# group (a terminal delivers its signals to the whole foreground group) and exits with the
# target's status.

set -uo pipefail
unset CDPATH
CX_PROG=wsl-entry
RT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/common.sh
. "$RT/scripts/lib/common.sh"
# shellcheck source=../lib/options.sh
. "$RT/scripts/lib/options.sh"
# shellcheck source=pathmap.sh
. "$RT/scripts/host/pathmap.sh"
# shellcheck source=detect.sh
. "$RT/scripts/host/detect.sh"

# Step 1: the transport directory (no CX_SIGNAL: "started" cannot be written).
if ! cx_path_to_wsl --caller win -- "${CX_FWD_WIN:-}" >/dev/null; then
  cx_note "cannot map the transport directory '${CX_FWD_WIN:-}': ${CX_PATHMAP_ERR:-unset}"
  exit 40
fi
FWD="$CX_PATHMAP_OUT"
for f in meta argv env; do
  if [ ! -f "$FWD/$f" ]; then
    cx_note "the transport directory $FWD lacks $f"
    exit 40
  fi
done

# Step 2.
if ! printf '%s\n' "$$" > "$FWD/started"; then
  cx_note "cannot write $FWD/started"
  exit 40
fi

# Step 3: meta.
declare -A META=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in *=*) META[${line%%=*}]="${line#*=}" ;; esac
done < "$FWD/meta"
CMD="${META[cmd]-}"
CX_SIGNAL_CMD="$CMD"
case " $CX_FORWARD_CMDS " in *" $CMD "*) ;; *) CX_SIGNAL_CMD=wsl-entry ;; esac
if [ "${META[v]-}" != 1 ] || [ "${META[version]-}" != "$CX_VERSION" ]; then
  cx_note "forwarded by conductor ${META[version]:-?} (meta v${META[v]:-?}), but this runtime is $CX_VERSION"
  cx_signal RUNTIME_MISSING 41 "runtime version mismatch: caller ${META[version]:-?}, runtime $CX_VERSION"
fi
if [ "$CX_SIGNAL_CMD" = wsl-entry ]; then
  cx_note "not a forwardable command: '$CMD'"
  cx_signal FAILED 2 "not a forwardable command"
fi
if [ ! -f "$RT/scripts/$CMD.sh" ]; then
  cx_note "$CMD is not part of runtime $CX_VERSION ($RT/scripts/$CMD.sh missing)"
  cx_signal CLI_MISSING 13 "$CMD is not in this runtime"
fi

# Step 4: the target's environment, from scratch.
KEEP=()
for n in HOME USER LOGNAME SHELL WSL_DISTRO_NAME WSL_INTEROP TERM LANG XDG_RUNTIME_DIR \
         DBUS_SESSION_BUS_ADDRESS DISPLAY WAYLAND_DISPLAY CX_MNT_ROOT CX_DETECT_ROOT; do
  [ -n "${!n+x}" ] && KEEP+=("$n=${!n}")
done
uid="$(id -u 2>/dev/null)" || uid=""
if [ -z "${XDG_RUNTIME_DIR+x}" ] && [ -n "$uid" ] && [ -d "/run/user/$uid" ]; then
  KEEP+=("XDG_RUNTIME_DIR=/run/user/$uid")
fi
if [ -z "${DBUS_SESSION_BUS_ADDRESS+x}" ] && [ -n "$uid" ] && [ -S "/run/user/$uid/bus" ]; then
  KEEP+=("DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$uid/bus")
fi
[ -n "${LANG+x}" ] || KEEP+=("LANG=C.UTF-8")
# An ssh-agent socket wsl.exe happened to pass on (a systemd user agent, an exported WSLENV
# entry) is kept when it is a live socket; shell rc files never run here (section 7.4).
[ -n "${SSH_AUTH_SOCK:-}" ] && [ -S "$SSH_AUTH_SOCK" ] && KEEP+=("SSH_AUTH_SOCK=$SSH_AUTH_SOCK")

# PATH: the host record's .path line, else the fallback list; never a /mnt/ entry.
CXH="${HOME:-}/.conductor"
cx_detect
P=""
if [ -f "$CXH/hosts/$CX_HOSTKEY.path" ]; then
  IFS= read -r P < "$CXH/hosts/$CX_HOSTKEY.path" || true
fi
if [ -z "$P" ]; then
  nvm=""
  if [ -d "${HOME:-}/.nvm/versions/node" ]; then
    nvm="$(for d in "$HOME"/.nvm/versions/node/*/bin; do [ -d "$d" ] && printf '%s\n' "$d"; done | sort -V | tail -n 1)"
  fi
  P="$HOME/.local/bin:$HOME/.npm-global/bin${nvm:+:$nvm}:$HOME/.bun/bin:$HOME/.cargo/bin:/home/linuxbrew/.linuxbrew/bin:/snap/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
fi
NP=""
IFS=: read -r -a parts <<< "$P"
for d in "${parts[@]+"${parts[@]}"}"; do
  case "$d" in ""|/mnt/*) continue ;; esac
  case ":$NP:" in *":$d:"*) continue ;; esac
  NP="${NP:+$NP:}$d"
done
KEEP+=("PATH=$NP")
KEEP+=("COPILOT_AUTO_UPDATE=false" "GROK_DISABLE_AUTOUPDATER=1" "AGY_CLI_DISABLE_AUTO_UPDATE=true")

# The allow-listed variables from the transport, checked again.
declare -A ALLOW=([CX_WORKER]=1 [CX_DEBUG]=1 [NO_COLOR]=1 [CX_SLOT_WAIT_SECS]=1)
for n in "${CX_OPT_NAMES[@]}"; do ALLOW["CLAUDE_PLUGIN_OPTION_${n^^}"]=1; done
while IFS= read -r -d '' rec; do
  name="${rec%%=*}"
  if [ "$name" != "$rec" ] && [ -n "${ALLOW[$name]-}" ]; then
    KEEP+=("$rec")
  else
    cx_note "dropping a variable that is not on the forwarding allowlist: ${name:0:64}"
  fi
done < "$FWD/env"

CWD_WIN="${META[cwd_win]-}"
WIN_SETTINGS=""
if [ -n "${META[win_settings]-}" ] && cx_path_to_wsl --caller win -- "${META[win_settings]}" >/dev/null; then
  WIN_SETTINGS="$CX_PATHMAP_OUT"
fi
KEEP+=("CX_FORWARDED=1" "CX_CALLER=gitbash" "CX_CALLER_CWD_WIN=$CWD_WIN" "CX_WIN_SETTINGS=$WIN_SETTINGS")

# Step 5: the cwd.
CWD=""
if [ -n "$CWD_WIN" ] && cx_path_to_wsl --caller win -- "$CWD_WIN" >/dev/null && [ -d "$CX_PATHMAP_OUT" ]; then
  CWD="$CX_PATHMAP_OUT"
  cd -- "$CWD" || CWD=""
fi
if [ -z "$CWD" ]; then
  case "$CMD" in
    cx-doctor|cx-job)
      cd -- "${HOME:-/}" || cd /
      KEEP+=("CX_CALLER_CWD_UNMAPPED=1") ;;
    *)
      cx_note "the current directory '$CWD_WIN' has no WSL equivalent (${CX_PATHMAP_ERR:-not a directory in WSL}); open the project from a drive path (C:\\...), or work on a repo that lives in WSL from a WSL terminal (claude, or claude remote-control there): a desktop session opened on \\\\wsl.localhost runs inside WSL without plugins"
      cx_signal PATH_UNMAPPABLE 42 "cwd has no WSL equivalent" ;;
  esac
fi

# Step 6: argv (empty records preserved).
ARGV=()
mapfile -d '' -t ARGV < "$FWD/argv"

# Step 7. cx-wsl is the exception: its stderr is the passed-through tool's, unchanged, with no
# CX_* line added (DESIGN sections 4.1 and 7.7).
INST=false
[ "${META[installed]-0}" = 1 ] && INST=true
if [ -n "$CWD" ]; then cwdarg=(cwd "$CWD"); else cwdarg=(cwd:null ""); fi
if [ "$CMD" != cx-wsl ]; then
  cx_emit FORWARD caller gitbash host wsl distro "${WSL_DISTRO_NAME:-}" cmd "$CMD" "${cwdarg[@]}" \
    cwd_win "$CWD_WIN" runtime "$CX_VERSION" installed:bool "$INST"
fi

# Step 8: run the target and stay its parent. Without a terminal (the Claude Bash tool) it runs
# as a background job in its own process group (set -m), so a cancel can stop the whole group.
# When wsl-entry's process group is the foreground group of a controlling terminal (wsl.exe
# attached to a console gives the Linux side a pty), a separate group would be a background
# group of that terminal: a tty read or ioctl stops it with SIGTTIN/SIGTTOU and the wait never
# ends. Then the target runs in the foreground of wsl-entry's own group, which is written to
# "pgid", so the terminal's Ctrl-C and the Git Bash side's group TERM reach it directly.
PPID0="$PPID"
ME=$$
tpid=""
PG="" TPG=""
st="$(cat "/proc/$$/stat" 2>/dev/null)" && { st="${st##*) }"; read -r _ _ PG _ _ TPG _ <<< "$st"; }
TTYFG=0
case "$PG" in ""|*[!0-9]*) ;; *) [ "$TPG" = "$PG" ] && TTYFG=1 ;; esac
# shellcheck disable=SC2329  # invoked by the trap below
forward_term() {
  [ -n "$tpid" ] && kill -TERM -- "-$tpid" 2>/dev/null
  return 0
}
ppid_now() {
  local s
  s="$(cat "/proc/$ME/stat" 2>/dev/null)" || return 1
  s="${s##*) }"
  read -r _ p _ <<< "$s"
  printf '%s' "$p"
}
# watchdog GROUP: TERM, then KILL 5 s later, to GROUP once wsl-entry's parent changed (the
# wsl.exe relay is gone); it ends with wsl-entry (or, for a background job, with the job).
watchdog() {
  local g="$1" p
  trap - INT TERM HUP
  while kill -0 "$ME" 2>/dev/null && { [ -z "$tpid" ] || kill -0 "$tpid" 2>/dev/null; }; do
    sleep 2
    p="$(ppid_now)" || continue
    if [ -n "$p" ] && [ "$p" != "$PPID0" ]; then
      trap '' TERM   # it may be in GROUP itself: survive the TERM to send the KILL
      kill -TERM -- "-$g" 2>/dev/null
      sleep 5
      kill -KILL -- "-$g" 2>/dev/null
      exit 0
    fi
  done
}
trap forward_term INT TERM HUP
if [ "$TTYFG" = 1 ]; then
  printf '%s\n' "$PG" > "$FWD/pgid.tmp" && mv -f "$FWD/pgid.tmp" "$FWD/pgid"
  watchdog "$PG" </dev/null >/dev/null 2>&1 &
  wdpid=$!
  env -i "${KEEP[@]}" /bin/bash "$RT/scripts/$CMD.sh" "${ARGV[@]+"${ARGV[@]}"}"
  rc=$?
  kill "$wdpid" 2>/dev/null
  wait "$wdpid" 2>/dev/null
  exit "$rc"
fi
exec 3<&0
set -m
env -i "${KEEP[@]}" /bin/bash "$RT/scripts/$CMD.sh" "${ARGV[@]+"${ARGV[@]}"}" <&3 &
tpid=$!
set +m
printf '%s\n' "$tpid" > "$FWD/pgid.tmp" && mv -f "$FWD/pgid.tmp" "$FWD/pgid"
watchdog "$tpid" </dev/null >/dev/null 2>&1 &
wdpid=$!

while :; do
  wait "$tpid"
  rc=$?
  if [ "$rc" -gt 128 ] && kill -0 "$tpid" 2>/dev/null; then
    continue
  fi
  break
done
kill "$wdpid" 2>/dev/null
wait "$wdpid" 2>/dev/null
exit "$rc"
