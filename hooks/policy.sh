#!/usr/bin/env bash
# hooks/policy.sh - SessionStart (startup|clear|compact): print the conductor policy as #
# hookSpecificOutput.additionalContext (docs/DESIGN.md section 10). Bash builtins plus cat and #
# uname; never reads stdin; always exits 0 (fails open). Silent when CX_WORKER is set (a #
# conductor worker) or option policy is off. Every line ends in " #" so a CRLF copy works. #
set -uo pipefail #
case "${CX_WORKER:-}" in ""|0) ;; *) exit 0 ;; esac #
p="${CLAUDE_PLUGIN_OPTION_POLICY:-on}" #
p="${p//[[:space:]]/}" #
shopt -s nocasematch #
case "$p" in off|false|0|no|disabled) exit 0 ;; esac #
shopt -u nocasematch #
d="${BASH_SOURCE[0]%/*}" #
[ "$d" != "${BASH_SOURCE[0]}" ] || d=. #
f="$d/policy-context.json" #
case "$(uname -s 2>/dev/null)" in MINGW*|MSYS*) f="$d/policy-context-gitbash.json" ;; esac #
for c in "$d/../bin/cx-doctor" "$d/../scripts/lib/common.sh" "$d/../scripts/host/forward-wsl.sh"; do #
  l= #
  { IFS= read -r l < "$c"; } 2>/dev/null #
  case "$l" in *$'\r') f="$d/policy-context-crlf.json"; break ;; esac #
done #
o="${CLAUDE_PLUGIN_OPTION_OPUS_LANE_ORDER:-}" #
o="${o//[[:space:]]/}" #
o="${o,,}" #
case "$o" in ""|*[!a-z,]*) o=agy,copilot,claude ;; esac #
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
k='{ORDER}' #
printf '%s\n' "${t//"$k"/$r}" #
exit 0 #
