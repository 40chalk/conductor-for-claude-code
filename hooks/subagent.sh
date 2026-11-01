#!/usr/bin/env bash
# hooks/subagent.sh - SubagentStart (workflow-subagent|general-purpose): print the conductor #
# subagent guard as hookSpecificOutput.additionalContext (docs/DESIGN.md section 10.7): workflow #
# and Agent-tool subagents never run executors; the main session dispatches them. Bash builtins #
# plus cat; reads at most 256 KiB of stdin with a 2-second timeout; always exits 0 (fails open). #
# Silent when CX_WORKER is set, option policy is off, or the payload names another agent_type. #
# Every line ends in " #" so a CRLF copy works. #
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
re='"agent_type"[[:space:]]*:[[:space:]]*"([^"]*)"' #
if [[ $i =~ $re ]]; then #
  case "${BASH_REMATCH[1]}" in workflow-subagent|general-purpose) ;; *) exit 0 ;; esac #
fi #
[ -r "$d/subagent-context.json" ] && cat -- "$d/subagent-context.json" #
exit 0 #
