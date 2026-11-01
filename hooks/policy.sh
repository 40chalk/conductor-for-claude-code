#!/usr/bin/env bash
# hooks/policy.sh - SessionStart (startup|clear|compact): print the conductor policy as #
# hookSpecificOutput.additionalContext (docs/DESIGN.md section 10). Bash builtins plus cat and #
# uname; reads at most 256 KiB of stdin with a 2-second timeout; always exits 0 (fails open). #
# Silent when CX_WORKER is set (a conductor worker) or option policy is off. A compacting #
# workflow-subagent or general-purpose agent gets the subagent guard instead, another agent #
# nothing; a cloud session, or BYOC (any kind but bridge) without exec_host=local, gets the cloud #
# notice, never on Git Bash or WSL (the user's computer). Every line ends in " #" (CRLF-safe). #
set -uo pipefail #
case "${CX_WORKER:-}" in ""|0) ;; *) exit 0 ;; esac #
p="${CLAUDE_PLUGIN_OPTION_POLICY:-on}" #
p="${p//[[:space:]]/}" #
shopt -s nocasematch #
case "$p" in off|false|0|no|disabled) exit 0 ;; esac #
shopt -u nocasematch #
d="${BASH_SOURCE[0]%/*}" #
[ "$d" != "${BASH_SOURCE[0]}" ] || d=. #
i= #
IFS= read -r -d '' -t 2 -n 262144 i 2>/dev/null #
re='"agent_id"[[:space:]]*:[[:space:]]*"[^"]' #
if [[ $i =~ $re ]]; then #
  re='"agent_type"[[:space:]]*:[[:space:]]*"(workflow-subagent|general-purpose)"' #
  [[ $i =~ $re ]] && [ -r "$d/subagent-context-compact.json" ] && cat -- "$d/subagent-context-compact.json" #
  exit 0 #
fi #
q="${CLAUDE_CODE_REMOTE:-}" #
q="${q//[[:space:]]/}" #
e="${CLAUDE_PLUGIN_OPTION_EXEC_HOST:-auto}" #
e="${e//[[:space:]]/}" #
c= #
case "${q,,}:${CLAUDE_CODE_ENVIRONMENT_KIND:-}:${e,,}" in 1:bridge:*|true:bridge:*|yes:bridge:*|on:bridge:*|1:?*:local|true:?*:local|yes:?*:local|on:?*:local) ;; 1:*|true:*|yes:*|on:*) c=1 ;; esac #
u="$(uname -s 2>/dev/null)" #
if [ -n "$c" ]; then #
  case "$u" in MINGW*|MSYS*) c= ;; esac #
  [ -n "${WSL_DISTRO_NAME:-}" ] && c= #
  for w in "${CX_DETECT_ROOT:-}"/proc/sys/fs/binfmt_misc/WSLInterop*; do [ -e "$w" ] && c=; done #
  case "$(uname -r 2>/dev/null)" in *[Mm]icrosoft*) c= ;; esac #
fi #
if [ -n "$c" ]; then [ -r "$d/policy-context-cloud.json" ] && cat -- "$d/policy-context-cloud.json"; exit 0; fi #
f="$d/policy-context.json" #
case "$u" in MINGW*|MSYS*) f="$d/policy-context-gitbash.json" ;; esac #
for c in "$d/../bin/cx-doctor" "$d/../scripts/lib/common.sh" "$d/../scripts/host/forward-wsl.sh"; do #
  l= #
  { IFS= read -r l < "$c"; } 2>/dev/null #
  case "$l" in *$'\r') f="$d/policy-context-crlf.json"; break ;; esac #
done #
o="${CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER:-}" #
o="${o//[[:space:]]/}" #
o="${o,,}" #
case "$o" in ""|*[!a-z,]*|,*|*,|*,,*) o=agy,copilot,claude ;; esac #
case ",$o," in *,claude,*) ;; *) o="$o,claude" ;; esac #
r= #
s=, #
for x in ${o//,/ }; do #
  case "$s" in *",$x,"*) r=; break ;; esac #
  s="$s$x," #
  case "$x" in agy) y='agy (agy-delegate)' ;; copilot) y='Copilot (ghcp-delegate)' ;; claude) y='own subagents' ;; *) r=; break ;; esac #
  r="${r:+$r, then }$y" #
done #
[ -n "$r" ] || r='agy (agy-delegate), then Copilot (ghcp-delegate), then own subagents' #
[ -r "$f" ] || exit 0 #
t="$(cat -- "$f" 2>/dev/null)" || exit 0 #
a= #
case "${CLAUDE_CODE_SESSION_ATTENDED:-}:${CLAUDE_CODE_ENVIRONMENT_KIND:-}" in 0:bridge) ;; 0:*) a=' UNATTENDED RUN: nobody approves prompts or reads a later turn, so commands outside the allow rules are denied; wait for jobs with consecutive foreground waits of at most 9 minutes (not background Bash) and report any job still running by its id.' ;; esac #
k='{ORDER}' #
t="${t//"$k"/$r}" #
k='{ATTN}' #
printf '%s\n' "${t//"$k"/$a}" #
exit 0 #
