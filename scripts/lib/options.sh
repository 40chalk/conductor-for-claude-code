#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR disable=SC2034,SC2088  # sourced library: callers read its variables; "~" is a literal default
# scripts/lib/options.sh - the conductor's userConfig options (docs/DESIGN.md section 5).
#
# Sourced, never run. Claude Code injects CLAUDE_PLUGIN_OPTION_* into hooks only, never into
# Bash-tool subshells, so scripts call cx_load_options, which re-reads the saved options from
#   ${CX_WIN_SETTINGS} (forwarded calls only), then ${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json
#     -> .pluginConfigs["conductor@conductor-for-claude-code"].options
#        (else key "conductor", else the first key starting with "conductor@")
# and exports CLAUDE_PLUGIN_OPTION_<UPPER> for each scalar whose variable is not set yet: an
# environment value always wins, even when empty. Precedence: CLI flag > environment >
# Windows-side settings (forwarded calls) > this host's settings > CX_OPT_DEFAULTS.
# cx_opt NAME prints the effective, validated value (an invalid value prints a note and the
# default). cx_opt_lite NAME FILE is the pure-bash reader Git Bash uses for exec_host and
# wsl_distro only.
#
# python3 runs as `python3 -I` from a quoted heredoc: this file is sourced from the caller's
# working directory and must not import modules from it.

# The script copy of every default (the other copy is .claude-plugin/plugin.json; a test pins
# them equal). An empty value means "use the default" for every option.
declare -gA CX_OPT_DEFAULTS=(
  [policy]="on"
  [exec_host]="auto"
  [wsl_distro]="auto"
  [docker_compose_file]=""
  [docker_service]="agents"
  [opus_lane_order]="agy,copilot,claude"
  [agy_opus_slug_tpl]="claude-opus-5-5-{effort}"
  [agy_opus_mode]="raw"
  [copilot_opus_id]="claude-opus-5.5"
  [copilot_xhigh_ok]="false"
  [grok_bulk_model]="grok-4.7"
  [grok_bulk_effort]="high"
  [grok_sandbox_profile]="cx-workspace"
  [review_model_gemini]="Gemini 4 Argon (High)"
  [review_model_gpt]="gpt-6.1-sol"
  [cap_agy]="2"
  [cap_copilot]="3"
  [cap_grok]="5"
  [copilot_reserve_pct]="0"
  [copilot_mtd_max_age_days]="3"
  [agy_claude_floor_pct]="0"
  [worktree_root]="~/.cx-wt"
  [ledger_path]="~/.conductor/ledger.jsonl"
  [default_timeout]="30m"
)
# The same names in DESIGN section 5.1 order.
CX_OPT_NAMES=(
  policy exec_host wsl_distro docker_compose_file docker_service opus_lane_order
  agy_opus_slug_tpl agy_opus_mode copilot_opus_id copilot_xhigh_ok grok_bulk_model
  grok_bulk_effort grok_sandbox_profile review_model_gemini review_model_gpt cap_agy
  cap_copilot cap_grok copilot_reserve_pct copilot_mtd_max_age_days agy_claude_floor_pct
  worktree_root ledger_path default_timeout
)
declare -gA CX_OPT_WARNED=()

# cx_load_options [FILE...]: see the header. Silent no-op when a file is missing, python3 may
# not be used (cx_py_ok) or the JSON is invalid.
cx_load_options() {
  local out
  local -a files=()
  CX_OPTIONS_LOADED=1
  if [ $# -gt 0 ]; then
    files=("$@")
  else
    [ -n "${CX_WIN_SETTINGS:-}" ] && files+=("$CX_WIN_SETTINGS")
    files+=("${CLAUDE_CONFIG_DIR:-${HOME:-}/.claude}/settings.json")
  fi
  declare -F cx_py_ok >/dev/null 2>&1 && ! cx_py_ok && return 0
  command -v python3 >/dev/null 2>&1 || return 0
  out="$(python3 -I - "${files[@]}" 2>/dev/null <<'PY'
import json, os, re, shlex, sys

seen = set()
for path in sys.argv[1:]:
    try:
        with open(path, encoding="utf-8-sig") as fh:
            root = json.load(fh)
    except Exception:
        continue
    pc = root.get("pluginConfigs") if isinstance(root, dict) else None
    if not isinstance(pc, dict):
        continue
    entry = pc.get("conductor@conductor-for-claude-code")
    if not isinstance(entry, dict):
        entry = pc.get("conductor")
    if not isinstance(entry, dict):
        entry = None
        for key, val in pc.items():
            if isinstance(key, str) and key.startswith("conductor@") and isinstance(val, dict):
                entry = val
                break
    opts = entry.get("options") if isinstance(entry, dict) else None
    if not isinstance(opts, dict):
        continue
    for key, val in opts.items():
        if not isinstance(key, str) or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            continue
        if isinstance(val, bool):
            text = "true" if val else "false"
        elif isinstance(val, int):
            text = str(val)
        elif isinstance(val, float):
            text = str(int(val)) if val.is_integer() else repr(val)
        elif isinstance(val, str):
            text = val
        else:
            continue  # null, lists, objects: not scalars
        name = "CLAUDE_PLUGIN_OPTION_" + key.upper()
        if name in os.environ or name in seen:
            continue  # the environment (or an earlier file) wins
        seen.add(name)
        print("export %s=%s" % (name, shlex.quote(text)))
PY
)" || out=""
  if [ -n "$out" ]; then
    eval "$out"
  fi
  return 0
}

# cx_expand_tilde PATH: a leading ~ or ~/ becomes $HOME.
cx_expand_tilde() {
  local p="${1-}"
  case "$p" in
    "~") p="${HOME:-}" ;;
    "~/"*) p="${HOME:-}/${p#"~/"}" ;;
  esac
  printf '%s' "$p"
}

_cx_int_in() {  # VALUE MIN MAX
  [[ $1 =~ ^[0-9]{1,6}$ ]] || return 1
  [ "$((10#$1))" -ge "$2" ] && [ "$((10#$1))" -le "$3" ]
}

# cx_opt_check NAME VALUE: validates VALUE for option NAME (DESIGN sections 5.1, 5.3). rc 0
# with the normalized value in CX_OPT_VALUE, rc 1 when invalid (CX_OPT_VALUE = the default).
cx_opt_check() {
  local name="$1" v="${2-}" def="${CX_OPT_DEFAULTS[$1]-}" t ok=1 x seen p h
  v="$(cx_trim "$v")"
  [ -n "$v" ] || v="$def"
  CX_OPT_VALUE="$v"
  case "$name" in
    policy|copilot_xhigh_ok)
      cx_bool "$v"
      case $? in 0|1) ok=0 ;; esac ;;
    exec_host)
      t="${v,,}"
      case "$t" in auto|wsl|local) CX_OPT_VALUE="$t"; ok=0 ;; esac ;;
    wsl_distro)
      if [ "${v,,}" = auto ]; then CX_OPT_VALUE=auto; ok=0
      elif [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]]; then ok=0
      fi ;;
    docker_compose_file)
      case "$v" in ""|/*) ok=0 ;; esac ;;
    docker_service|grok_sandbox_profile)
      [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] && ok=0 ;;
    opus_lane_order)
      t="${v//[[:space:]]/}"
      t="${t,,}"
      ok=0
      seen=","
      if [[ ! $t =~ ^[a-z]+(,[a-z]+)*$ ]]; then ok=1; fi
      if [ "$ok" = 0 ]; then
        for x in ${t//,/ }; do
          case "$x" in agy|copilot|claude) ;; *) ok=1; break ;; esac
          case "$seen" in *",$x,"*) ok=1; break ;; esac
          seen="$seen$x,"
        done
      fi
      if [ "$ok" = 0 ]; then
        case "$seen" in *,claude,*) ;; *) t="$t,claude" ;; esac
        CX_OPT_VALUE="$t"
      fi ;;
    agy_opus_slug_tpl)
      [[ $v == *"{effort}"* ]] && [[ ! $v =~ [[:space:]] ]] && ok=0 ;;
    agy_opus_mode)
      t="${v,,}"
      case "$t" in raw|wrapper) CX_OPT_VALUE="$t"; ok=0 ;; esac ;;
    copilot_opus_id|grok_bulk_model|review_model_gpt)
      [[ $v =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]*$ ]] && ok=0 ;;
    grok_bulk_effort)
      t="${v,,}"
      case "$t" in low|medium|high|xhigh) CX_OPT_VALUE="$t"; ok=0 ;; esac ;;
    review_model_gemini)
      [[ $v =~ [[:cntrl:]] ]] || ok=0 ;;
    cap_agy|cap_copilot)
      _cx_int_in "$v" 0 16 && { CX_OPT_VALUE="$((10#$v))"; ok=0; } ;;
    cap_grok)
      _cx_int_in "$v" 0 32 && { CX_OPT_VALUE="$((10#$v))"; ok=0; } ;;
    copilot_reserve_pct|agy_claude_floor_pct)
      _cx_int_in "$v" 0 90 && { CX_OPT_VALUE="$((10#$v))"; ok=0; } ;;
    copilot_mtd_max_age_days)
      _cx_int_in "$v" 1 31 && { CX_OPT_VALUE="$((10#$v))"; ok=0; } ;;
    worktree_root)
      case "$v" in
        /*|"~"|"~/"*)
          p="$(cx_expand_tilde "$v")"
          while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
          h="${HOME:-}"
          while [ "${#h}" -gt 1 ] && [ "${h%/}" != "$h" ]; do h="${h%/}"; done
          if [ "$p" != "/" ] && [ "$p" != "$h" ]; then ok=0; fi ;;
      esac ;;
    ledger_path)
      case "$v" in /?*|"~/"?*) ok=0 ;; esac ;;
    default_timeout)
      if [[ $v =~ ^([0-9]{1,7})([smh]?)$ ]]; then
        t="${BASH_REMATCH[1]}"
        case "${BASH_REMATCH[2]}" in m) t=$((10#$t * 60)) ;; h) t=$((10#$t * 3600)) ;; *) t=$((10#$t)) ;; esac
        [ "$t" -ge 30 ] && ok=0
      fi ;;
    *)
      ok=0 ;;
  esac
  if [ "$ok" != 0 ]; then
    CX_OPT_VALUE="$def"
    return 1
  fi
  return 0
}

# cx_opt NAME: prints the effective value of option NAME: CLAUDE_PLUGIN_OPTION_<UPPER> when
# non-empty, else the default; an invalid value prints
# "<prog>: ignoring invalid option NAME='VALUE'; using 'DEFAULT'" (once per process) and the
# default.
cx_opt() {
  local name="$1" var val
  var="CLAUDE_PLUGIN_OPTION_${name^^}"
  val="${!var-}"
  [ -n "$val" ] || val="${CX_OPT_DEFAULTS[$name]-}"
  if ! cx_opt_check "$name" "$val"; then
    if [ -z "${CX_OPT_WARNED[$name]-}" ]; then
      CX_OPT_WARNED[$name]=1
      printf "%s: ignoring invalid option %s='%s'; using '%s'\n" \
        "${CX_PROG:-cx}" "$name" "$val" "${CX_OPT_DEFAULTS[$name]-}" >&2
    fi
  fi
  printf '%s\n' "$CX_OPT_VALUE"
}

# _cx_lite_span TEXT: TEXT starts with "{"; prints TEXT up to its matching "}" (brace counting
# outside JSON strings; a quote toggles string state unless preceded by an odd number of
# backslashes). rc 1 when the braces do not balance.
_cx_lite_span() {
  local s="$1" n i c depth=0 instr=0 bs=0
  n=${#s}
  for ((i = 0; i < n; i++)); do
    c="${s:i:1}"
    if [ "$c" = "\\" ]; then
      bs=$((bs + 1))
      continue
    fi
    if [ "$c" = '"' ] && [ $((bs % 2)) -eq 0 ]; then
      instr=$((1 - instr))
    fi
    bs=0
    [ "$instr" = 1 ] && continue
    case "$c" in
      '{') depth=$((depth + 1)) ;;
      '}')
        depth=$((depth - 1))
        if [ "$depth" -eq 0 ]; then
          printf '%s' "${s:0:i+1}"
          return 0
        fi ;;
    esac
  done
  return 1
}

# cx_opt_lite NAME FILE (Git Bash; pure bash; for exec_host and wsl_distro only): the value of
# option NAME inside FILE's pluginConfigs entry for the conductor, or nothing (DESIGN section
# 5.2). A heuristic: cx-doctor --windows cross-checks it against a real parse (W7).
cx_opt_lite() {
  local name="$1" file="$2" text rest span opts anchor='"conductor@conductor-for-claude-code"'
  [ -n "$file" ] && [ -f "$file" ] && [ -r "$file" ] || return 0
  text="$(< "$file")" || return 0
  text="${text#$'\xef\xbb\xbf'}"
  text="${text//$'\r'/}"
  rest="$text"
  span=""
  while [[ $rest == *"$anchor"* ]]; do
    rest="${rest#*"$anchor"}"
    if [[ $rest =~ ^[[:space:]]*:[[:space:]]*\{ ]]; then
      rest="${rest#"${BASH_REMATCH[0]%\{}"}"
      span="$(_cx_lite_span "$rest")" || span=""
      break
    fi
  done
  [ -n "$span" ] || return 0
  # Inside that entry: the "options" object, scanned to its own matching brace.
  rest="${span:1}"
  opts=""
  while [[ $rest == *'"options"'* ]]; do
    rest="${rest#*\"options\"}"
    if [[ $rest =~ ^[[:space:]]*:[[:space:]]*\{ ]]; then
      rest="${rest#"${BASH_REMATCH[0]%\{}"}"
      opts="$(_cx_lite_span "$rest")" || opts=""
      break
    fi
  done
  [ -n "$opts" ] || return 0
  if [[ $opts =~ \"$name\"[[:space:]]*:[[:space:]]*\"([A-Za-z0-9._-]*)\" ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  fi
  return 0
}
