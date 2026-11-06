#!/usr/bin/env python3
"""normalize.py - result normalizer of the conductor's Phase 2 adapters (docs/DESIGN.md section 15).

Always invoked as `python3 -I normalize.py <subcommand> ...` on the executor host. stdlib only;
cxlib.py (same directory) is loaded by file path, never through sys.path. Malformed executor
output is counted and skipped, never a crash; JSONL is split on "\\n" only; every JSON with
variable content is built with json.dumps.

Fields marked [docs-only] or [unverified] come from vendor docs or inference, not from a
captured run (DESIGN section 20 items 6, 7, 27): every parser accepts several shapes and falls
back to "unknown" rather than guessing.

Files of one run in OUT ($CX_HOME/out/<id>), for adapter L (copilot grok agy claude copilot-cloud):
  L.argv L.env           NUL-separated argv and NAME=VALUE / NAME= (unset) lines (adapter argv)
  L.meta.json            what was requested (adapter argv)
  L.out L.err rc         the executor's stdout, stderr and exit status (adapter run)
  L.run.json             run facts: times, sids, cancelled, timed_out, agy init/result/tree facts
  checks.json            optional post-run facts from cx-run: spec_ok, git_link_ok and
                         git_link_why (false: the worktree's .git was rewritten -> tampered, 24),
                         diff, diffstat, commit,
                         branch, base, gate (green|red), cancelled, timed_out, finished (cx-run
                         --finish: a dispatched claude task is classified, not "dispatched"),
                         stop ({status, reason}: the run stopped before the executor, e.g.
                         env_failed or no_capacity), notes (extra result notes)
  answer.txt result.json written by `parse`

Subcommands:
  parse --lane L --out OUT          result.json (+ answer.txt); prints "<exit> <status>"
  emit --out OUT                    CX_DENIED, CX_NOTE, CX_RESULT lines (stderr), as applicable
  report --out OUT                  the stdout block of cx-run: digest, VERIFY THIS line, diffstat
  probe --lane L ...                the probe JSON of DESIGN section 15.2 from captured probe output,
                                    with the flag contract (--help-file, --argv-file, --need)
  cache-get / cache-put             the 10-minute preflight cache ($CX_HOME/state/preflight.json;
                                    the adapters store green probes only)
  agy-watch --ndjson F --events E --pgid N [--after-result 5]
                                    follows agy's stream-json: writes "init <model>", "result",
                                    "killed_after_result" lines into E; SIGKILLs the process group
                                    5 s after the result event (agy #1313)
  trees-diff BEFORE AFTER [--exclude-file F]...
                                    the worktrees whose snapshot changed (exit 1 when any did)
  render-cloud --task F [--base B]  the Copilot cloud agent's task text from a section 6.4 task.md
  field FILE DOTTED.KEY             one value of a JSON file (exit 1 when absent)
  field-lines FILE DOTTED.KEY       a list of strings, one per line (control characters dropped)
  uuid                              a random UUID (grok -s, claude --session-id)
  json-list ITEM...                 a JSON list of strings
  obj KEY VALUE... [--list NAME N ITEM...]
                                    one JSON object (adapter meta.json, run.json)
  verdict PROBE_JSON                the preflight verdict: "<exit> <STATUS> <version or -> <reason>"
  json-extract RAW OUT              the JSON object in RAW into OUT (agy /usage)
  worker-settings --template T --out F [--allow CMD]...
                                    the --headless claude worker's settings file
  meta-env FILE                     a meta.json's run-time fields as shell assignments
  routes --file F                   .cx/routes.json as shell assignments for cx-run (RT_*)
  task-meta --file F                a task.md's line-1 JSON as shell assignments (TK_*); exit 1
                                    when line 1 is not <!-- cx-task {json} -->
  task-render --template T --out F --id ID --base SHA --lane L --effort E --text-file F
              [--cmd CMD]... [--snapshot OUT/routes.json]
                                    a free-text task wrapped into templates/task.md (checks named
                                    as cx-route <name> from the snapshot)
  route-snapshot --routes F --out OUT --dir D --id ID [--cmd CMD]... [--bin BIN] [--bash B]
                                    OUT/routes.json and BIN/cx-route (cx-run: $CX_HOME/routes/<id>;
                                    default OUT/bin): the task's checks, named from .cx/routes.json
                                    at dispatch (cx-route)
  agy-settings --out F --wt DIR...  the agy raw lane's per-run --settings file (write_file of the
                                    worktree, command() of cx-route, git status and ls)
  grok-check --profile P --workspace W --grok-home H --probe-out F [--probe-rc N] [--events E
             --from N --to M] [--json-out J]
                                    the grok lane's per-run profile check (DESIGN section 15.2):
                                    "ok" or "refuse <reason>" on stdout, then "note <text>" lines
                                    (resolver files the logged profile cannot read), the facts as
                                    JSON in J
  grok-netlog --file F --from N --to M --out O
                                    the connection and DNS failures among the bytes grok appended
                                    to its log F (~/.grok/logs/unified.jsonl) during a run: one
                                    matched phrase per line in O (text only; no JSON shape assumed)
"""

import argparse
import datetime
import importlib.util
import json
import os
import re
import signal
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))


class _LazyCxlib:
    """cxlib.py (same directory), loaded by file path on first use (only the probe needs it:
    parse_models, first_semver, vercmp). Bytecode writing is off, so no __pycache__ lands in the
    plugin (the runtime installer refuses binary files with CR bytes; the copy may be read-only)."""

    _mod = None

    def __getattr__(self, name):
        if _LazyCxlib._mod is None:
            sys.dont_write_bytecode = True
            spec = importlib.util.spec_from_file_location("cxlib", os.path.join(HERE, "cxlib.py"))
            mod = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mod)
            _LazyCxlib._mod = mod
        return getattr(_LazyCxlib._mod, name)


CXL = _LazyCxlib()
CTRL_RE = re.compile("[\x00-\x1f\x7f-\x9f\u2028\u2029]+")


class CX:
    """The small cxlib.py helpers, local so most calls never load cxlib.py."""

    @staticmethod
    def out(text):
        sys.stdout.write(text)

    @staticmethod
    def err(text):
        sys.stderr.write(text)

    @staticmethod
    def sanitize(text, limit=200):
        s = CTRL_RE.sub(" ", str(text)).strip()
        return s[: limit - 3] + "..." if len(s) > limit else s

    @staticmethod
    def dumps_line(obj):
        return json.dumps(obj, ensure_ascii=True)

    @staticmethod
    def shell_quote(s):
        return "'" + s.replace("'", "'\\''") + "'"

    @staticmethod
    def utc_now():
        return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)

    @staticmethod
    def iso(dt):
        return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

    @staticmethod
    def atomic_write(path, data, mode=None):
        d = os.path.dirname(os.path.abspath(path))
        os.makedirs(d, exist_ok=True)
        fd, tmp = tempfile.mkstemp(prefix=".cx-tmp.", dir=d)
        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(data if isinstance(data, bytes) else data.encode("utf-8"))
            if mode is not None:
                os.chmod(tmp, mode)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except OSError:
                pass
            raise


RESULT_VERSION = 1

# DESIGN section 4.1: status -> exit (ledger status words).
STATUS_EXIT = {
    "ok": 0, "dispatched": 0, "failed": 2, "empty": 3, "quota": 10, "auth": 11, "timeout": 12,
    "missing": 13, "model_unavailable": 14, "denied": 15, "sandbox": 16, "model_mismatch": 21,
    "gate_failed": 20, "wrong_tree": 22, "spec_tampered": 23, "tampered": 24, "env_failed": 25, "version_mismatch": 26,
    "partial": 27, "no_capacity": 28, "cancelled": 130,
}
# A wrapper's own exit (ghcp-delegate, agy-delegate, ghcp-cloud) -> the fact it stands for.
WRAPPER_EXIT = {2: "failed", 3: "empty", 10: "quota", 11: "auth", 12: "timeout", 13: "missing",
                14: "model_unavailable", 15: "denied", 16: "sandbox", 130: "cancelled"}
POOLS = {"agy-opus": "google-claude-bucket", "agy-gemini": "google-gemini",
         "copilot-opus": "copilot-credits", "copilot-fusion": "copilot-credits",
         "copilot-gpt": "copilot-credits", "copilot": "copilot-credits",
         "copilot-cloud": "copilot-credits", "grok": "xai-weekly", "claude": "claude-plan"}

# Text classes, scanned only in the executor's diagnostics (stderr, error fields), never in the
# answer, and only when the executor failed or left no answer (ghcp's rule).
QUOTA_RE = re.compile(r"rate.?limit|quota|\b429\b|resource.?exhausted|credits balance is too low|insufficient credits|usage limit", re.I)
AUTH_RE = re.compile(r"You are not authenticated|not (?:logged|signed) in|unauthenticated|unauthorized|please (?:sign in|authenticate|run /login)|No authentication information found|Invalid API key|\breauth", re.I)
SANDBOX_RE = re.compile(r"Read-only file system|os error 30|EROFS", re.I)
# grok's own sandbox not applied: "warning: sandbox could not be applied: <cause>", then "error:
# could not apply the '<p>' sandbox profile; ... Refusing to start with its protections missing."
# (grok 1.0.70, measured 2026-11-06, a profile with a file in read_only, rc 1) and "Refusing to
# start with denied paths unprotected" (no bubblewrap, rc 1); grok's README says that where the
# sandbox cannot be applied (no Landlock) it "logs a warning and continues without enforcement".
GROK_NOSANDBOX_RE = re.compile(r"(?im)^.*(?:sandbox could not be applied|could not apply the '[^'\n]*' sandbox profile"
                               r"|refusing to start with (?:its protections missing|denied paths unprotected)"
                               r"|without (?:sandbox )?enforcement).*$")


def grok_nosandbox(text):
    """The first line of TEXT saying grok's sandbox was not applied, else None."""
    m = GROK_NOSANDBOX_RE.search(text or "")
    return CX.sanitize(m.group(0).strip(), 200) if m else None


# grok could not reach its API (measured 2026-11-06, grok 1.0.70 on WSL, a strict-based profile
# that could not read /etc/resolv.conf's target): rc 1 after 1657 s (grok's own retries, 4
# rounds), usage all 0, stderr 'Error: Internal error: "reqwest error stream: error sending
# request for url (https://cli-chat-proxy.grok.com/v1/responses)"', and ~/.grok/logs/unified.jsonl
# held "client error (Connect): dns error: failed to lookup address information: Try again" (the
# JSON shape of that log line was not captured: only its text is searched). The phrase, up to a
# JSON string's quote or escape.
GROK_CONNECT_RE = re.compile(r"(?i)(?:error sending request for url|client error \(connect\)|dns error|"
                             r"failed to lookup address information)[^\"\\\n]{0,160}")
GROK_DNS_RE = re.compile(r"(?i)dns error|failed to lookup address information")
GROK_NETLOG_MAX = 4 << 20


def grok_netlog(path, start, end):
    """The distinct GROK_CONNECT_RE phrases (at most 5, each sanitized) among the bytes grok
    appended to its log PATH between sizes START and END (at most the last 4 MiB of them)."""
    data = CXL.read_appended(path, start, end, GROK_NETLOG_MAX, tail=True)
    found = []
    for line in data.decode("utf-8", "replace").split("\n"):
        for m in GROK_CONNECT_RE.finditer(line):
            p = CX.sanitize(m.group(0).strip(), 200)
            if p not in found:
                found.append(p)
            if len(found) >= 5:
                return found
    return found
MODEL_RE = re.compile(r"model .{0,80}(?:not available|not found|unknown|unsupported|is not supported)|unknown model|invalid model", re.I)
PARTIAL_RE = re.compile(r"print timeout after .*returning partial output", re.I)


# --------------------------------------------------------------------------- small helpers

def read(path, default=""):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return default


def load_json(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            v = json.load(fh)
        return v if isinstance(v, dict) else None
    except (OSError, ValueError):
        return None


def read_rc(out_dir):
    t = read(os.path.join(out_dir, "rc")).strip()
    return int(t) if re.fullmatch(r"-?\d{1,4}", t) else None


def num(v):
    return v if isinstance(v, (int, float)) and not isinstance(v, bool) else None


def first_num(d, *keys):
    if not isinstance(d, dict):
        return None
    for k in keys:
        if num(d.get(k)) is not None:
            return d[k]
    return None


def nonblank(s):
    return isinstance(s, str) and s.strip() != ""


def jsonl(text):
    """Every JSON object line of TEXT (split on "\\n" only); malformed lines are skipped."""
    evs = []
    for ln in text.split("\n"):
        ln = ln.strip()
        if not ln.startswith("{"):
            continue
        try:
            ev = json.loads(ln, strict=False)
        except ValueError:
            continue
        if isinstance(ev, dict):
            evs.append(ev)
    return evs


def last_json_object(text):
    """The whole of TEXT as one JSON object, else its last JSON object line."""
    s = text.strip()
    if s.startswith("{"):
        try:
            v = json.loads(s, strict=False)
            if isinstance(v, dict):
                return v
        except ValueError:
            pass
    evs = jsonl(text)
    return evs[-1] if evs else None


def prefixed(text, name):
    """Lines "NAME {json}" (or "NAME <text>") of TEXT, payloads in order."""
    outl = []
    for ln in text.split("\n"):
        if ln.startswith(name + " "):
            outl.append(ln[len(name) + 1:].strip())
    return outl


def prefixed_json(text, name):
    res = []
    for p in prefixed(text, name):
        try:
            v = json.loads(p)
        except ValueError:
            continue
        if isinstance(v, dict):
            res.append(v)
    return res


def empty_usage():
    return {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "reasoning": 0}


def usage_from(d, extra=None):
    """Token counts from a usage object of any of the shapes seen (snake and camel case)."""
    u = empty_usage()
    if not isinstance(d, dict):
        return u
    pairs = (("input", ("input_tokens", "inputTokens", "input", "prompt_tokens")),
             ("output", ("output_tokens", "outputTokens", "output", "completion_tokens")),
             ("cache_read", ("cache_read_tokens", "cacheReadTokens", "cache_read_input_tokens", "cacheReadInputTokens", "cache_read")),
             ("cache_write", ("cache_write_tokens", "cacheWriteTokens", "cache_creation_input_tokens", "cacheCreationInputTokens", "cache_write")),
             ("reasoning", ("reasoning_tokens", "reasoningTokens", "thinking_tokens", "thinkingTokens", "reasoning")))
    for key, names in pairs:
        v = first_num(d, *names)
        if v is not None:
            u[key] = int(v)
    if extra:
        for k, v in extra.items():
            if num(v) is not None and not u.get(k):
                u[k] = int(v)
    return u


def deny_kind(text):
    t = (text or "").lower()
    if re.search(r"\b(write|edit|multiedit|create|apply_patch|write_file|replace|patch|str_replace|notebookedit|delete)", t):
        return "write"
    if re.search(r"\b(bash|shell|command|run_command|exec)", t):
        return "shell"
    if re.search(r"\b(url|fetch|web|read_url)", t):
        return "url"
    if re.search(r"\b(mcp)", t):
        return "mcp"
    return "other"


def is_claude_model(m):
    return isinstance(m, str) and m.lower().startswith("claude")


# --------------------------------------------------------------------------- lane parsers
# Each returns a dict of facts: answer, session, served, models, usage, cost, denied,
# denied_fatal, finished_reason, effort_applied, flags (cls -> reason) and notes.

def facts_base():
    return {"answer": "", "session": None, "served": None, "models": [], "usage": empty_usage(),
            "cost": {"ai_credits": None, "usd_est": None, "quota_delta": None, "estimated": False},
            "denied": [], "denied_fatal": False, "finished_reason": None, "effort_applied": None,
            "flags": {}, "notes": [], "extra": {}}


def flag(f, cls, reason):
    f["flags"].setdefault(cls, reason)


def text_classes(f, diag, failed):
    """quota / auth / sandbox / model_unavailable from diagnostics, only for a failed run."""
    if not failed:
        return
    if SANDBOX_RE.search(diag):
        flag(f, "sandbox", "the executor cannot write its home (read-only file system): run outside the Claude Code Bash sandbox")
    if AUTH_RE.search(diag):
        flag(f, "auth", "the executor is not logged in")
    if MODEL_RE.search(diag):
        flag(f, "model_unavailable", "the executor refused the model")
    if QUOTA_RE.search(diag):
        flag(f, "quota", "quota or rate limit (classified by pattern)")


def parse_copilot(out_dir, meta, run, rc):
    """ghcp-delegate's contract [verified, ghcp 0.1.0]: stdout = the answer; stderr GHCP_SESSION
    <id>, GHCP_USAGE/GHCP_DENIED/GHCP_FALLBACK/GHCP_NOTE/GHCP_SIGNAL {json}; exits 0, 2, 3, 10-16, 130."""
    f = facts_base()
    f["answer"] = read(os.path.join(out_dir, "copilot.out"))
    err = read(os.path.join(out_dir, "copilot.err"))
    sess = prefixed(err, "GHCP_SESSION")
    usages = prefixed_json(err, "GHCP_USAGE")
    u = usages[-1] if usages else {}
    f["session"] = (sess[-1].split()[0] if sess and sess[-1] else None) or u.get("session_id")
    used = [m.get("model") for m in (u.get("models_used") or []) if isinstance(m, dict) and isinstance(m.get("model"), str)]
    f["models"] = used
    fusion = u.get("fusion") if isinstance(u.get("fusion"), dict) else None
    req = meta.get("model_requested")
    if meta.get("fusion"):
        f["served"] = (fusion or {}).get("final_model") or u.get("model") or (used[0] if used else None)
        f["extra"]["fusion"] = fusion
    else:
        f["served"] = u.get("model") if isinstance(u.get("model"), str) else (used[0] if used else None)
    f["usage"] = usage_from(u)
    f["cost"]["ai_credits"] = num(u.get("ai_credits"))
    for d in prefixed_json(err, "GHCP_DENIED"):
        for k in d.get("kinds") or []:
            f["denied"].append({"kind": str(k), "detail": "GHCP_DENIED"})
    fallbacks = prefixed_json(err, "GHCP_FALLBACK")
    if fallbacks:
        f["extra"]["fallback"] = fallbacks[-1]
    f["effort_applied"] = None if meta.get("fusion") else meta.get("effort_requested")
    # Served model (G6): every models_used[].model equals the request; on a Fusion lane any
    # GHCP_FALLBACK means the answer came from a billed plain-auto re-run.
    if meta.get("fusion"):
        if fallbacks:
            flag(f, "model_mismatch", "GHCP_FALLBACK on a Fusion lane: the answer came from a billed plain-auto re-run (%s)" % CX.sanitize(fallbacks[-1].get("reason", ""), 120))
        elif rc == 0 and fusion is None:
            f["notes"].append("Fusion run without a session.fusion_resolved event: the profile actually used is unverified")
    elif used:
        bad = sorted({m for m in used if m != req})
        if bad:
            flag(f, "model_mismatch", "served %s, requested %s" % (", ".join(bad), req))
    elif rc == 0:
        f["notes"].append("served model unverified: no GHCP_USAGE models_used")
    # copilot#5149: Opus at xhigh burns the 32k output budget on hidden reasoning, empty answer.
    out_tok = num(u.get("output_tokens")) or 0
    if meta.get("effort_requested") == "xhigh" and out_tok >= 30000 and not nonblank(f["answer"]):
        flag(f, "failed", "copilot#5149: %d output tokens and an empty answer at effort xhigh (billed)" % out_tok)
    sigs = prefixed_json(err, "GHCP_SIGNAL")
    reason = CX.sanitize(sigs[-1].get("reason", ""), 160) if sigs else ""
    if rc in WRAPPER_EXIT:
        cls = WRAPPER_EXIT[rc]
        if cls == "denied":
            f["denied_fatal"] = True
            if not f["denied"]:
                f["denied"].append({"kind": "other", "detail": reason or "ghcp-delegate exit 15"})
        flag(f, cls, reason or "ghcp-delegate exited %d" % rc)
    elif rc not in (0, None):
        flag(f, "failed", "ghcp-delegate exited %d" % rc)
    return f


# Served-model aliases (G6, DESIGN section 15.2): the served name may be the requested one plus
# one of these suffixes, nothing else (measured 2026-11-06 on grok 1.0.70: -m grok-4.6 serves
# grok-4.6-build and -m grok-4.7 serves grok-4.7-build; grok-4.7-build-fast is another model).
SERVED_ALIASES = {"grok": ("", "-build")}


def served_matches(lane, req, served):
    return isinstance(req, str) and isinstance(served, str) and any(
        served == req + suf for suf in SERVED_ALIASES.get(lane, ("",)))


def _grok_denials(err):
    res = []
    for ln in err.split("\n"):
        m = re.search(r"permission required:\s*(.*)", ln)
        if m:
            detail = CX.sanitize(m.group(1), 160)
            res.append({"kind": deny_kind(detail), "detail": detail})
    return res


def parse_grok(out_dir, meta, run, rc):
    """grok --output-format json, verified on 1.0.70 (tests/fixtures/real/grok/sbx-grok-1..3):
    one JSON object with text, stopReason, sessionId, requestId, cwd, thought, usage
    {input_tokens, cache_read_input_tokens, cache_creation_input_tokens, output_tokens,
    reasoning_tokens, total_tokens}, num_turns, total_cost_usd(_ticks), modelUsage {<served>:
    {...}} and, with --json-schema, structuredOutput. text joins every turn's assistant message
    with no separator (turn boundaries cannot be recovered from it), so with --json-schema the
    structured answer wins; without one, text stays the answer, with a note saying it is not the
    structured one. "permission required:" on stderr for a denied tool (rc 0); an error object
    without sessionId on rc 1 [docs-only]."""
    f = facts_base()
    raw = read(os.path.join(out_dir, "grok.out"))
    err = read(os.path.join(out_dir, "grok.err"))
    obj = last_json_object(raw) or {}
    run = run if isinstance(run, dict) else {}
    text = obj.get("text") if isinstance(obj.get("text"), str) else obj.get("result") if isinstance(obj.get("result"), str) else obj.get("response")
    if isinstance(text, str):
        f["answer"] = text
    elif raw.strip() and not obj:
        f["answer"] = raw  # plain text (no JSON at all)
    if meta.get("json_schema"):
        # With --json-schema, 1.0.70 puts the validated answer in structuredOutput, while text
        # joins every turn's message with no separator (sbx-grok-3: "[ ]" from the first turn,
        # then the array), so text alone is not valid JSON. The structured answer wins.
        for k in ("structuredOutput", "structured_output") + (() if isinstance(text, str) else ("output", "data")):
            if obj.get(k) is not None:
                f["answer"] = json.dumps(obj[k], ensure_ascii=False)
                break
        else:
            if nonblank(f["answer"]):
                f["notes"].append("grok gave no structuredOutput for --json-schema: the answer is its text, which joins "
                                  "every turn's message with no separator (it may not be valid JSON)")
    f["session"] = obj.get("sessionId") or obj.get("session_id") or None
    mu = obj.get("modelUsage") if isinstance(obj.get("modelUsage"), dict) else None
    f["models"] = sorted(mu) if mu else []
    f["finished_reason"] = obj.get("stopReason") or obj.get("stop_reason")
    agg = {}
    for v in (mu or {}).values():
        uu = usage_from(v)
        for k, n in uu.items():
            agg[k] = agg.get(k, 0) + n
    f["usage"] = usage_from(obj.get("usage"), agg)
    ut = read(os.path.join(out_dir, "grok.usage.txt"))
    if ut and not any(f["usage"].values()):
        for key, pat in (("input", r"input tokens:\s*(\d+)"), ("output", r"output tokens:\s*(\d+)"),
                         ("cache_read", r"cache(?:d| read)[^:\n]*:\s*(\d+)"), ("reasoning", r"reasoning tokens:\s*(\d+)")):
            m = re.search(pat, ut, re.I)
            if m:
                f["usage"][key] = int(m.group(1))
    cost = first_num(obj, "total_cost_usd", "costUsd", "cost_usd")
    if cost is not None:
        f["cost"]["usd_est"] = cost
        f["cost"]["estimated"] = True
    f["effort_applied"] = meta.get("effort_requested")
    f["denied"] = _grok_denials(err)
    if f["denied"]:
        f["denied_fatal"] = True  # grok: any "permission required:" fails the run (G5)
    error = obj.get("error")
    diag = err + "\n" + (json.dumps(error) if error is not None else "")
    failed = rc not in (0, None) or not nonblank(f["answer"])
    # grok could not reach its API: a connection or DNS failure, no model call (DESIGN section
    # 15.2). Exit 2 FAILED (or 12 when the wall clock ended grok's retries first); the reason
    # names it, and DNS when grok's own log (the lines this run appended, grok.netlog.txt) says so.
    if rc not in (0, None, 130) and not run.get("cancelled") and not mu and not any(f["usage"].values()) and not grok_nosandbox(err):
        said = GROK_CONNECT_RE.search(diag)
        logged = [x for x in read(os.path.join(out_dir, "grok.netlog.txt")).split("\n") if x.strip()]
        dns = next((x for x in logged if GROK_DNS_RE.search(x)), None)
        if said or dns:
            # The reason keeps to result.json's 200 characters: what failed, D17, the evidence.
            sc = run.get("sandbox_check") if isinstance(run.get("sandbox_check"), dict) else {}
            unread = [t for t in (sc.get("resolver_unreadable") or []) if isinstance(t, dict)]
            what = ("grok could not resolve its API's host name (DNS; cx-doctor D17): %s" % dns if dns else
                    "grok could not reach its API (a connection or DNS failure; cx-doctor D17): %s" % CX.sanitize(said.group(0), 160))
            if rc in (124, 137):
                flag(f, "timeout", "the grok run hit the wall clock: " + what)
            else:
                flag(f, "failed", what + " (no model call)")
            if dns and said:
                f["notes"].append("grok said: %s" % CX.sanitize(said.group(0), 200))
            if unread:
                f["notes"].append("the per-run check found that the run's sandbox profile cannot read %s (cx-doctor D17)" % ", ".join(
                    "%s -> %s" % (t.get("path"), t.get("real")) for t in unread[:3]))
            f["notes"].append("cx-doctor D17 lists the resolver and TLS files grok must read under its sandbox profile; grok's "
                              "own retries can hold a run for about 28 minutes before it fails (the run's timeout bounds it)")
    if rc in (124, 137) and not run.get("cancelled"):
        flag(f, "timeout", "the grok run hit the wall clock")
    text_classes(f, diag, failed)
    req = meta.get("model_requested")
    if mu:
        bad = sorted(m for m in mu if not served_matches("grok", req, m))
        if bad:
            flag(f, "model_mismatch", "modelUsage names %s, requested %s" % (", ".join(sorted(mu)), req))
            f["served"] = bad[0]
        else:
            f["served"] = sorted(mu)[-1]
            if f["served"] != req:
                f["notes"].append("grok served %s for %s: its build alias (accepted, DESIGN section 15.2)" % (f["served"], req))
    elif rc == 0 and nonblank(f["answer"]):
        f["notes"].append("served model unverified: no modelUsage in grok's JSON")
    nosb = grok_nosandbox(err)
    if nosb:
        if rc == 0 or nonblank(f["answer"]):
            flag(f, "failed", "grok ran without its sandbox (%s): every tool was approved and nothing confined it; "
                              "inspect the worktree and the files it could reach before anything else (cx-doctor D17)" % nosb)
        else:
            flag(f, "failed", "grok could not apply its sandbox profile and did not start (%s; cx-doctor D17)" % nosb)
    if rc not in (0, None) and rc not in (124, 137, 130):
        if error is not None and not f["session"]:
            flag(f, "failed", "grok exited %d with an error object and no sessionId: %s" % (rc, CX.sanitize(json.dumps(error), 120)))
        else:
            flag(f, "failed", "grok exited %d" % rc)
    return f


def _ev_type(ev):
    """An event's type: "type" (the shapes of other CLIs) or "event" (agy's real stream-json,
    verified on 1.4.12: {"event": "init" | "step_update" | "result", "<event>": {...}})."""
    for k in ("type", "event"):
        t = ev.get(k)
        if isinstance(t, str) and t:
            return t
    return ""


def agy_event_kind(ev):
    """init | result | subagent | step | other for one agy stream-json event. The real shape
    (agy 1.4.12, tests/fixtures/real/agy/sbx-agy-1/agy.out) is {"event": "init", "init":
    {"model", "cwd", "tools", "permission_mode"}, "conversation_id"}, {"event": "step_update",
    "step_update": {"step_index", "state", "step_type", "tool_name", "tool_info": {"name",
    "parameters"}}} and {"event": "result", "result": {"status", "response", "usage",
    "denied_actions"}}; the older guesses ({"type": "init", "model"}, {"type": "system",
    "subtype": "init"}) are still accepted."""
    t = _ev_type(ev).lower()
    if t == "init" or (t == "system" and ev.get("subtype") == "init") or isinstance(ev.get("init"), dict):
        return "init"
    if t == "result" or isinstance(ev.get("result"), dict) and t in ("", "final"):
        return "result"
    if "subagent" in t or "subagent_info" in ev:
        return "subagent"
    if t == "step_update" or isinstance(ev.get("step_update"), dict):
        st = ev.get("step_update") if isinstance(ev.get("step_update"), dict) else {}
        if "subagent" in str(st.get("tool_name") or "").lower():
            return "subagent"
        return "step"
    return "other"


def agy_init_model(ev):
    for body in (ev.get("init"), ev, ev.get("data"), ev.get("message")):
        if isinstance(body, dict):
            for k in ("model", "model_name", "modelName"):
                if isinstance(body.get(k), str) and body[k]:
                    return body[k]
    return None


def _snake(name):
    return re.sub(r"(?<!^)(?=[A-Z])", "_", str(name)).lower()


def agy_tool_steps(evs):
    """The tool steps of agy's step_update events, in step order (the last update of each
    step wins): [{"index", "state", "tool", "params"}]."""
    steps = {}
    for e in evs:
        st = e.get("step_update")
        if not isinstance(st, dict) or st.get("step_type") != "tool":
            continue
        info = st.get("tool_info") if isinstance(st.get("tool_info"), dict) else {}
        idx = st.get("step_index") if isinstance(st.get("step_index"), int) else len(steps) + 1000
        params = info.get("parameters") if isinstance(info.get("parameters"), dict) else {}
        steps[idx] = {"index": idx, "state": str(st.get("state") or ""),
                      "tool": str(st.get("tool_name") or info.get("name") or ""), "params": params}
    return [steps[k] for k in sorted(steps)]


AGY_DETAIL_KEYS = ("CommandLine", "Command", "command", "TargetFile", "AbsolutePath", "Path", "path", "Url", "url")


def agy_denials(res, evs):
    """result.denied_actions ([{action, display_name}]) named after the tool step each one
    stopped: the last tool step of that tool (run_command for "command"/"RunCommand"), whose
    parameters give the command line or the path (agy ends the run at its first denial)."""
    steps = agy_tool_steps(evs)
    used = set()
    out = []
    for a in res.get("denied_actions") or []:
        if isinstance(a, dict):
            action, disp = a.get("action"), a.get("display_name")
        else:
            action, disp = a, None
        if not action and not disp:
            continue
        names = {n for n in (_snake(disp) if disp else None, str(action) if action else None,
                             "run_" + str(action) if action else None) if n}
        step = None
        for s in reversed(steps):
            if s["index"] not in used and s["tool"] in names:
                step = s
                break
        entry = {"kind": deny_kind(str(action or disp)), "detail": CX.sanitize(str(action or disp), 120),
                 "action": str(action or disp)}
        if step is not None:
            used.add(step["index"])
            entry["tool"] = step["tool"]
            for k in AGY_DETAIL_KEYS:
                v = step["params"].get(k)
                if isinstance(v, str) and v.strip():
                    entry["detail"] = CX.sanitize(v, 300)
                    if k in ("CommandLine", "Command", "command"):
                        entry["command"] = entry["detail"]
                    break
        out.append(entry)
    return out


def _agy_result_body(ev):
    return ev.get("result") if isinstance(ev.get("result"), dict) else ev


def parse_agy(out_dir, meta, run, rc):
    if meta.get("variant") == "wrapper":
        return parse_agy_wrapper(out_dir, meta, run, rc)
    f = facts_base()
    raw = read(os.path.join(out_dir, "agy.out"))
    err = read(os.path.join(out_dir, "agy.err"))
    evs = jsonl(raw)
    slug = meta.get("model_requested")
    init = next((e for e in evs if agy_event_kind(e) == "init"), None)
    results = [e for e in evs if agy_event_kind(e) == "result"]
    res = _agy_result_body(results[-1]) if results else None
    served = agy_init_model(init) if init else None
    f["served"] = served
    f["models"] = sorted({m for m in [served] + [agy_init_model(e) for e in evs if agy_event_kind(e) != "init" and agy_init_model(e)] if m})
    for e in (init, res):
        if isinstance(e, dict):
            f["session"] = f["session"] or e.get("session_id") or e.get("conversation_id") or e.get("sessionId")
    texts = []
    for e in evs:
        if _ev_type(e) in ("message", "assistant") and e.get("role", "assistant") == "assistant":
            c = e.get("content")
            if isinstance(c, str):
                texts.append(c)
            elif isinstance(c, list):
                texts.extend(x.get("text", "") for x in c if isinstance(x, dict) and isinstance(x.get("text"), str))
    if isinstance(res, dict):
        for k in ("response", "result", "text"):
            if isinstance(res.get(k), str):
                f["answer"] = res[k]
                break
        f["usage"] = usage_from(res.get("usage") or res.get("stats"))
        fr = res.get("finished_reason") or res.get("finish_reason") or res.get("stop_reason") or res.get("status") or res.get("subtype")
        f["finished_reason"] = fr if isinstance(fr, str) else None
        f["denied"].extend(agy_denials(res, evs))
        if isinstance(f["finished_reason"], str) and "permission" in f["finished_reason"].lower():
            f["denied"].append({"kind": "other", "detail": "finished_reason " + f["finished_reason"]})
    if not nonblank(f["answer"]) and texts:
        f["answer"] = "".join(texts)
    if f["denied"]:
        f["denied_fatal"] = True  # agy: a denied action means the task was not done as asked (G5)
    f["effort_applied"] = meta.get("effort_requested")
    # Served model (G6): only the init event names it; release of the launch lock and the
    # mismatch kill happened in the adapter (run.json).
    if init is None:
        if run.get("init_timeout"):
            flag(f, "failed", "no init event within %s s: agy was killed (a headless hang, #318?)" % run.get("init_secs", 120))
        elif rc == 0 or results:
            flag(f, "model_mismatch", "served model unknown: no init event in agy's stream-json")
    elif not served:
        flag(f, "model_mismatch", "served model unknown: the init event names no model")
    elif served != slug:
        flag(f, "model_mismatch", "init.model is %s, requested %s" % (served, slug))
    others = [m for m in f["models"] if m != slug]
    if any(agy_event_kind(e) == "subagent" for e in evs) or (others and served == slug):
        flag(f, "failed", "subagent: agy started a subagent or another model (%s); subagents cannot be pinned to Opus" % (", ".join(others) or "subagent_info"))
    diag = err + "\n" + (json.dumps(res.get("error")) if isinstance(res, dict) and res.get("error") else "")
    killed = bool(run.get("killed_after_result"))
    eff_rc = 0 if killed and results else rc
    if killed:
        f["notes"].append("agy did not exit after its result event: its process group was killed 5 s later (#1313)")
    if PARTIAL_RE.search(err) and eff_rc == 0:
        flag(f, "partial", "agy's --print-timeout expired mid-turn: the answer is PARTIAL")
    if eff_rc in (124, 137) and not run.get("cancelled") and not run.get("init_timeout") and "model_mismatch" not in f["flags"]:
        flag(f, "timeout", "the agy run hit the wall clock")
    failed = eff_rc not in (0, None) or not nonblank(f["answer"])
    text_classes(f, diag, failed)
    if isinstance(res, dict) and str(res.get("status", "")).upper() == "ERROR":
        flag(f, "failed", "agy's result is an ERROR: %s" % CX.sanitize(str(res.get("error", "")), 120))
    if eff_rc not in (0, None, 124, 137, 130):
        flag(f, "failed", "agy exited %d" % eff_rc)
    agy_quota(f, out_dir)
    agy_tree(f, run)
    return f


def agy_quota(f, out_dir):
    """cost.quota_delta from /usage before and after [docs-only shape]: percentage points per bucket."""
    b = load_json(os.path.join(out_dir, "agy.usage.before.json"))
    a = load_json(os.path.join(out_dir, "agy.usage.after.json"))
    if not (b and a):
        return
    delta = {}
    bb, ab = b.get("buckets"), a.get("buckets")
    if isinstance(bb, dict) and isinstance(ab, dict):
        for k, v in bb.items():
            x, y = first_num(v, "remaining_percent"), first_num(ab.get(k) or {}, "remaining_percent")
            if x is not None and y is not None:
                delta[k] = round(x - y, 3)
    if delta:
        f["cost"]["quota_delta"] = delta


def agy_tree(f, run):
    changed = run.get("tree_changed") or []
    if changed:
        flag(f, "wrong_tree", "agy changed files outside the task worktree: %s (agy dispatch is paused until cx-job unpause agy)" % ", ".join(changed[:3]))


def parse_agy_wrapper(out_dir, meta, run, rc):
    """agy-delegate [verified, antigravity 0.30.2]: stdout = the answer, AGY_USAGE / AGY_SIGNAL
    on stderr, exits 0, 2, 3, 10-15. AGY_USAGE.model echoes the request (section 1.4): the served
    model stays unverified and such a run never yields 21."""
    f = facts_base()
    f["answer"] = read(os.path.join(out_dir, "agy.out"))
    err = read(os.path.join(out_dir, "agy.err"))
    us = prefixed_json(err, "AGY_USAGE")
    u = us[-1] if us else {}
    f["usage"] = usage_from(u.get("usage") if isinstance(u.get("usage"), dict) else u)
    f["session"] = u.get("conversation_id") or None
    f["served"] = None
    f["notes"].append("agy wrapper: AGY_USAGE.model echoes the request; served model unverified")
    f["effort_applied"] = meta.get("effort_requested")
    sigs = prefixed_json(err, "AGY_SIGNAL")
    reason = CX.sanitize(sigs[-1].get("reason", ""), 160) if sigs else ""
    if rc in WRAPPER_EXIT:
        cls = WRAPPER_EXIT[rc]
        if cls == "denied":
            f["denied_fatal"] = True
            f["denied"].append({"kind": "other", "detail": reason or "agy-delegate exit 15"})
        flag(f, cls, reason or "agy-delegate exited %d" % rc)
    elif rc not in (0, None):
        flag(f, "failed", "agy-delegate exited %d" % rc)
    agy_quota(f, out_dir)
    agy_tree(f, run)
    return f


def parse_claude(out_dir, meta, run, rc):
    """claude -p --output-format json [assumption, DESIGN section 20 item 27]: result,
    session_id, usage, modelUsage, is_error, permission_denials, total_cost_usd."""
    f = facts_base()
    if meta.get("variant") == "dispatch":
        f["extra"]["dispatch"] = meta.get("dispatch")
        flag(f, "dispatched", "dispatched to a Claude subagent in the conductor worktree")
        return f
    raw = read(os.path.join(out_dir, "claude.out"))
    err = read(os.path.join(out_dir, "claude.err"))
    obj = last_json_object(raw) or {}
    if isinstance(obj.get("result"), str):
        f["answer"] = obj["result"]
    f["session"] = obj.get("session_id") or obj.get("sessionId")
    mu = obj.get("modelUsage") if isinstance(obj.get("modelUsage"), dict) else None
    f["models"] = sorted(mu) if mu else []
    f["usage"] = usage_from(obj.get("usage"))
    cost = first_num(obj, "total_cost_usd", "cost_usd")
    if cost is not None:
        f["cost"]["usd_est"] = cost
        f["cost"]["estimated"] = True
    f["finished_reason"] = obj.get("subtype") if isinstance(obj.get("subtype"), str) else None
    f["effort_applied"] = meta.get("effort_requested")
    for d in obj.get("permission_denials") or []:
        name = d.get("tool_name") if isinstance(d, dict) else d
        if name:
            f["denied"].append({"kind": deny_kind(str(name)), "detail": CX.sanitize(str(name), 120)})
    if any(d["kind"] == "write" for d in f["denied"]):
        f["denied_fatal"] = True
    req = meta.get("model_requested") or ""
    if mu:
        mine = [m for m in mu if m == req or m.startswith(req + "-") or m.startswith(req + "[")]
        others = [m for m in mu if m not in mine and "haiku" not in m.lower()]
        if not mine or others:
            flag(f, "model_mismatch", "modelUsage names %s, requested %s" % (", ".join(sorted(mu)), req))
        f["served"] = mine[0] if mine else sorted(mu)[0]
    elif rc == 0 and nonblank(f["answer"]):
        f["notes"].append("served model unverified: no modelUsage in claude's JSON")
    failed = rc not in (0, None) or bool(obj.get("is_error")) or not nonblank(f["answer"])
    if rc in (124, 137) and not run.get("cancelled"):
        flag(f, "timeout", "the claude worker hit the wall clock")
    text_classes(f, err + "\n" + (f["answer"] if obj.get("is_error") else ""), failed)
    if obj.get("is_error") or (rc not in (0, None, 124, 137, 130)):
        flag(f, "failed", "claude -p reported an error (%s, exit %s)" % (obj.get("subtype") or "error", rc))
    return f


URL_RE = re.compile(r"https?://[^\s\"'<>)]+")


def parse_copilot_cloud(out_dir, meta, run, rc):
    """ghcp-cloud create (gh agent-task create -F -, a gh preview) [docs-only output]: the task
    and pull request URLs are taken from any URL in its output."""
    f = facts_base()
    out = read(os.path.join(out_dir, "copilot-cloud.out"))
    err = read(os.path.join(out_dir, "copilot-cloud.err"))
    urls = URL_RE.findall(out + "\n" + err)
    pr = None
    pr_url = None
    task = None
    for u in urls:
        m = re.search(r"/pull/(\d+)", u)
        if m and pr is None:
            pr, pr_url = int(m.group(1)), u
        m = re.search(r"/(?:agent[-_]?tasks?|tasks|sessions?)/([A-Za-z0-9-]+)", u)
        if m and task is None:
            task = m.group(1)
    f["answer"] = out
    f["session"] = task
    f["served"] = None
    f["notes"].append("Copilot cloud agent: the model is chosen on GitHub; served model unverified")
    f["extra"]["cloud"] = {"state": "created" if rc == 0 else "failed", "task": task, "pr": pr,
                           "pr_url": pr_url, "urls": urls[:5], "repo": meta.get("repo_gh") or None,
                           "base": meta.get("base_branch")}
    if rc in WRAPPER_EXIT:
        flag(f, WRAPPER_EXIT[rc], "ghcp-cloud exited %d" % rc)
    elif rc not in (0, None):
        flag(f, "failed", "ghcp-cloud exited %d" % rc)
    elif not urls:
        f["notes"].append("no task or pull request URL in gh's output: check with ghcp-cloud list")
    return f


PARSERS = {"copilot": parse_copilot, "grok": parse_grok, "agy": parse_agy, "claude": parse_claude,
           "copilot-cloud": parse_copilot_cloud}

# DESIGN section 15.1, first match wins (13 missing slots in before failed).
ORDER = ("wrong_tree", "spec_tampered", "tampered", "cancelled", "timeout", "sandbox", "missing", "auth",
         "model_unavailable", "quota", "model_mismatch", "denied", "partial", "failed")


def classify(f, checks, meta, run, rc):
    flags = dict(f["flags"])
    stop = checks.get("stop") if isinstance(checks.get("stop"), dict) else None
    if stop and stop.get("status") in STATUS_EXIT:
        return stop["status"], str(stop.get("reason") or stop["status"])
    if checks.get("finished"):
        flags.pop("dispatched", None)
    if checks.get("spec_ok") is False:
        flags.setdefault("spec_tampered", ".conductor/task.md changed during the run")
    if checks.get("git_link_ok") is False:
        flags.setdefault("tampered", str(checks.get("git_link_why") or "the worktree's .git was rewritten during the run"))
    if run.get("cancelled") or checks.get("cancelled") or rc == 130:
        flags.setdefault("cancelled", "interrupted (INT, TERM or HUP, or cx-job kill)")
    if run.get("timed_out") or checks.get("timed_out"):
        flags.setdefault("timeout", "the wall clock expired")
    if "dispatched" in flags:
        return "dispatched", flags["dispatched"]
    diff = checks.get("diff")
    answer = nonblank(f["answer"])
    if f["denied"] and "denied" not in flags:
        if f["denied_fatal"] or (not answer and not diff):
            kinds = sorted({d["kind"] for d in f["denied"]})
            flags["denied"] = "the executor was denied: %s" % ", ".join(kinds)
    for cls in ORDER:
        if cls in flags:
            return cls, flags[cls]
    if checks.get("gate") == "red":
        return "gate_failed", str(checks.get("gate_reason") or "a gate check failed")
    if meta.get("executor") != "copilot-cloud" or checks.get("finished"):
        if meta.get("mode", "write") == "write" and diff is not None:
            if not diff:
                return "empty", "no diff in the worktree"
        elif not answer:
            return "empty", "the executor exited 0 with no answer"
    return "ok", ""


def nz(v):
    return None if v == "" else v


def cmd_parse(a):
    out_dir = a.out
    lane = a.lane
    meta = load_json(os.path.join(out_dir, lane + ".meta.json")) or {}
    run = load_json(os.path.join(out_dir, lane + ".run.json")) or {}
    checks = load_json(os.path.join(out_dir, "checks.json")) or {}
    rc = read_rc(out_dir)
    if rc is None:
        rc = run.get("rc") if isinstance(run.get("rc"), int) else None
    if lane not in PARSERS:
        CX.err("normalize: unknown lane %s\n" % lane)
        return 1
    dispatch = meta.get("variant") == "dispatch" and not checks.get("finished")
    if isinstance(checks.get("stop"), dict):
        f = facts_base()
    elif rc is None and meta.get("variant") != "dispatch":
        f = facts_base()
        flag(f, "failed", "the executor left no exit status (%s/rc)" % out_dir)
    else:
        f = PARSERS[lane](out_dir, meta, run, rc)
    if meta.get("variant") == "dispatch" and checks.get("finished"):
        f["notes"].append("a Claude subagent did the task in the conductor's worktree; its digest is in the conversation, not here")
    status, reason = classify(f, checks, meta, run, rc)
    answer_path = os.path.join(out_dir, "answer.txt")
    if not dispatch:
        CX.atomic_write(answer_path, f["answer"])
    host = run.get("host") or meta.get("host")
    started = run.get("started_at") or meta.get("created_at")
    res = {
        "version": RESULT_VERSION, "ts": started or CX.iso(CX.utc_now()), "id": meta.get("id"),
        "batch": checks.get("batch") or meta.get("batch"), "lane": meta.get("lane") or lane,
        "host": host, "caller": meta.get("caller") or "local", "executor": meta.get("executor") or lane,
        "cli_version": nz(run.get("cli_version")) or nz(meta.get("cli_version")), "pool": meta.get("pool") or POOLS.get(meta.get("lane") or lane),
        "mode": nz(meta.get("mode")), "model_requested": nz(meta.get("model_requested")),
        "model_served": f["served"], "effort_requested": nz(meta.get("effort_requested")),
        "effort_applied": nz(f["effort_applied"]), "exit": STATUS_EXIT[status], "status": status,
        "reason": CX.sanitize(reason, 200) if reason else None,
        "finished_reason": f["finished_reason"], "session": f["session"], "usage": f["usage"],
        "cost": f["cost"], "denied": f["denied"],
        "worktree": {"path": nz(meta.get("wt")), "host_path": nz(meta.get("wt_host"))},
        "branch": checks.get("branch") or nz(meta.get("branch")), "base": checks.get("base") or nz(meta.get("base")),
        "commit": checks.get("commit"), "diffstat": checks.get("diffstat"), "gate": checks.get("gate"),
        "digest": {"path": answer_path if not dispatch else None,
                   "host_path": (meta.get("out_host") + "\\answer.txt") if meta.get("out_host") and not dispatch else None},
        "out": {"path": out_dir, "host_path": nz(meta.get("out_host"))},
        "duration_s": run.get("duration_s"), "models_seen": f["models"],
        "claude_session": os.environ.get("CLAUDE_CODE_SESSION_ID") or meta.get("claude_session"),
        "claude_effort": os.environ.get("CLAUDE_EFFORT") or meta.get("claude_effort"),
        "raw": {"stdout": os.path.join(out_dir, lane + ".out"), "stderr": os.path.join(out_dir, lane + ".err")},
        "notes": f["notes"] + list(run.get("notes") or []) + [str(n) for n in (checks.get("notes") or []) if n],
    }
    for k in ("dispatch", "cloud", "fusion", "fallback"):
        if f["extra"].get(k) is not None:
            res[k] = f["extra"][k]
    CX.atomic_write(os.path.join(out_dir, "result.json"), json.dumps(res, ensure_ascii=False, indent=1) + "\n")
    CX.out("%d %s\n" % (res["exit"], status))
    return 0


# --------------------------------------------------------------------------- output lines

SUMMARY_DROP = ("raw", "notes", "models_seen")


def deny_hint(executor, kinds):
    """The CX_DENIED hint (DESIGN section 15.2): what the executor may run and write, per lane.
    It never suggests a skip-permissions or always-approve flag."""
    hints = []
    if "shell" in kinds:
        if executor == "agy":
            hints.append("agy may run only cx-route <name>, git status and ls (its per-run --settings), "
                         "and its first other command ends the run: name the check in the task (cx-route <name>), add a missing "
                         "check to .cx/routes.json commands, then re-dispatch")
        else:
            hints.append("only cx-route <name> (the task's .cx/routes.json checks) and git status may run: "
                         "add a missing check to .cx/routes.json commands, or narrow the task")
    if "write" in kinds:
        if executor == "agy":
            hints.append("agy may write only inside the task's worktree (write_file per run): narrow the task")
        elif executor == "grok":
            hints.append("grok may write only inside the task's worktree (plus /tmp, /var/tmp and ~/.grok/sessions: "
                         "its sandbox profile): narrow the task")
        else:
            hints.append("writes outside the task's worktree are refused: narrow the task")
    return "; ".join(hints) or "the denied actions were not performed"


def cmd_emit(a):
    p = os.path.join(a.out, "result.json")
    res = load_json(p)
    if res is None:
        return 1
    if res.get("denied"):
        dl = [d for d in res["denied"] if isinstance(d, dict)]
        kinds = sorted({str(d.get("kind")) for d in dl})
        line = {"count": len(res["denied"]), "kinds": kinds, "hint": deny_hint(res.get("executor"), kinds)}
        cmds = [str(d["command"]) for d in dl if isinstance(d.get("command"), str)]
        if cmds:
            line["commands"] = [CX.sanitize(c, 200) for c in cmds[:3]]
        CX.err("CX_DENIED " + CX.dumps_line(line) + "\n")
    model = res.get("model_served") or res.get("model_requested")
    if is_claude_model(model) or res.get("lane") == "claude":
        models = sorted({m for m in [res.get("model_served"), res.get("model_requested")] if isinstance(m, str)})
        CX.err("CX_NOTE " + CX.dumps_line({"same_family_as_conductor": True, "models": models}) + "\n")
    summ = {k: v for k, v in res.items() if k not in SUMMARY_DROP}
    summ["path"] = p
    oh = (res.get("out") or {}).get("host_path") if isinstance(res.get("out"), dict) else None
    summ["host_path"] = (oh.rstrip("\\") + "\\result.json") if oh else None
    CX.err("CX_RESULT " + CX.dumps_line(summ) + "\n")
    return 0


def cmd_report(a):
    """cx-run's stdout (DESIGN section 15.1, G8): the digest, a VERIFY THIS line, the diffstat."""
    res = load_json(os.path.join(a.out, "result.json"))
    if res is None:
        return 1
    meta = load_json(os.path.join(a.out, str(res.get("executor")) + ".meta.json")) or {}
    if res.get("status") == "dispatched":
        CX.out(json.dumps(res.get("dispatch") or {}, ensure_ascii=False) + "\n")
        return 0
    ans = read(os.path.join(a.out, "answer.txt")).rstrip("\n")
    if ans:
        CX.out(ans + "\n")
    cmds = ", ".join(meta.get("allow") or []) or "the routes.json commands"
    served = res.get("model_served") or "unverified"
    if res.get("executor") == "copilot-cloud" and res.get("gate") == "green":
        what = "the gate passed on the pull request head %s; read the diff (%s) and %s/changed.txt against allowed_paths and the protected set, then review it (cx-run --mode review --branch %s) before anything merges" % (
            res.get("commit") or "?", res.get("diffstat") or "no diffstat", (res.get("out") or {}).get("path") or "the out directory", res.get("commit") or "<head>")
    elif res.get("executor") == "copilot-cloud":
        cloud = res.get("cloud") or {}
        what = "the agent's pull request %s, once it is ready: cx-run --finish %s%s gates its head on a clean checkout (setup and %s) before anything merges" % (
            cloud.get("pr_url") or "(see ghcp-cloud list)", res.get("id"), "" if cloud.get("pr") else " --pr N", cmds)
    elif res.get("mode") == "write":
        whose = "the subagent's own account (in this conversation)" if res.get("lane") == "claude" and not ans else "the executor's own account above"
        what = "%s; read the diff (%s), commit it (the skill's Step 3) and rerun %s on that commit in a clean gate checkout (served model: %s)" % (whose, res.get("diffstat") or "no diffstat yet", cmds, served)
    else:
        what = "every file:line the answer cites, in the checkout, before acting on it (served model: %s)" % served
    if res.get("status") != "ok":
        what = "nothing: the run ended %s (%s)" % (res.get("status"), res.get("reason") or "")
    CX.out("VERIFY THIS: %s\n" % what)
    if res.get("diffstat"):
        CX.out("diffstat: %s\n" % res["diffstat"])
    return 0


# --------------------------------------------------------------------------- probe and cache

FLAG_TOKEN_RE = re.compile(r"(--?[A-Za-z][A-Za-z0-9-]*)(?:=.*)?", re.S)


def argv_flags(argv):
    """The flag tokens of an argv (after the executable; "--x=v" counts as "--x"; nothing after
    a literal "--"), in order, without repeats."""
    seen = []
    for tok in argv[1:]:
        if tok == "--":
            break
        m = FLAG_TOKEN_RE.fullmatch(tok)
        if m and m.group(1) not in seen:
            seen.append(m.group(1))
    return seen


def _read_argv(path):
    try:
        with open(path, "rb") as fh:
            parts = fh.read().decode("utf-8", "replace").split("\0")
    except OSError:
        return None
    if parts and parts[-1] == "":
        parts.pop()
    return parts


def shell_words(line):
    """The words of one shell-quoted line (bash printf %q, including $'...' ANSI-C quoting, as
    ghcp-delegate --print-command prints its Copilot argv); None when it does not parse."""
    import codecs
    import shlex

    def ansi(m):
        try:
            v = codecs.decode(m.group(1).encode("latin-1", "backslashreplace"), "unicode_escape")
        except (UnicodeDecodeError, ValueError):
            v = m.group(1)
        return "'" + v.replace("'", "'\"'\"'") + "'"
    try:
        return shlex.split(re.sub(r"\$'((?:[^'\\]|\\.)*)'", ansi, line.strip()))
    except ValueError:
        return None


def help_has(text, token):
    """TOKEN appears in a help text: a flag as a whole token, anything else (a permission kind
    such as "shell(") as a substring."""
    if FLAG_TOKEN_RE.fullmatch(token):
        return re.search(r"(?<![A-Za-z0-9-])" + re.escape(token) + r"(?![A-Za-z0-9-])", text) is not None
    return token in text


def flag_contract(helps, argvs, needs, shells=()):
    """The flag contract of DESIGN section 5.4: every flag the adapter is about to emit (the
    argv files) and every extra token (needs) must appear in the live help it is checked against.
    helps: {name: (path, label)}; argvs, needs: [(name, value)]. Returns the probe's "contract"
    object, or None when nothing is checked."""
    if not helps and not argvs and not needs:
        return None
    texts, unreadable, missing, checked = {}, [], [], 0
    for name, (path, label) in helps.items():
        t = read(path)
        if t.strip():
            texts[name] = t
        else:
            unreadable.append(label)
    want = []
    for name, path in argvs:
        av = _read_argv(path)
        if av is None:
            unreadable.append("argv %s" % os.path.basename(path))
            continue
        want.extend((name, f) for f in argv_flags(av))
    for name, path in shells:
        words = shell_words(read(path).split("\n", 1)[0]) if read(path).strip() else None
        if not words:
            unreadable.append("command line %s" % os.path.basename(path))
            continue
        want.extend((name, f) for f in argv_flags(words))
    want.extend(needs)
    done = set()
    for name, tok in want:
        if (name, tok) in done:
            continue
        done.add((name, tok))
        label = helps.get(name, (None, name))[1]
        if name not in texts:
            if label not in unreadable:
                unreadable.append(label)
            continue
        checked += 1
        if not help_has(texts[name], tok):
            missing.append("%s (%s)" % (tok, label))
    return {"ok": not missing and not unreadable, "checked": checked, "missing": missing,
            "unreadable": unreadable}


def _named(items, what):
    res = []
    for it in items or []:
        name, sep, val = it.partition("=")
        if not sep or not name or not val:
            raise ValueError("--%s needs NAME=VALUE (got %r)" % (what, it))
        res.append((name, val))
    return res


def cmd_probe(a):
    """Builds the probe JSON (DESIGN section 15.2) from the files the adapter captured. The
    version is recorded, never judged (no pins, DESIGN section 5.4): the live help decides."""
    ver_text = read(a.version_out) if a.version_out else ""
    version = CXL.first_semver(ver_text) if ver_text else None
    vok = True if version else (False if a.bin else None)
    logged = None
    models = []
    mok = None
    detail = []
    if a.models_cli and a.models_out and os.path.exists(a.models_out):
        pm = CXL.parse_models(a.models_cli, read(a.models_out))
        models = pm.get("ids") or []
        if a.models_cli == "copilot":
            if a.models_rc == 0 and pm.get("shape") == "ghcp-models":
                logged = True
            elif a.models_rc == 11:
                logged = False
            if a.model == "fusion":
                try:
                    dyn = json.loads(read(a.models_out)).get("dynamic_auto_tiers")
                except (ValueError, AttributeError):
                    dyn = None
                mok = None if dyn is None else bool(dyn)
            elif models and a.model:
                mok = a.model in models
        else:
            logged = pm.get("authenticated")
            labels = list((pm.get("labels") or {}).values())
            if a.model and models:
                mok = a.model in models or a.model in labels
        if a.models_rc not in (0, None) and logged is None:
            detail.append("model listing exited %s" % a.models_rc)
    if a.auth_out and os.path.exists(a.auth_out):
        t = read(a.auth_out)
        if a.auth_kind == "claude":
            try:
                logged = bool(json.loads(t).get("loggedIn"))
            except (ValueError, AttributeError):
                logged = None
        elif a.auth_kind == "rc":
            logged = a.auth_rc == 0
    if a.model_ok is not None:
        mok = a.model_ok == "true"
    sandbox = None
    if a.sandbox_out and os.path.exists(a.sandbox_out):
        why = grok_nosandbox(read(a.sandbox_out))
        # grok's sandbox log: the ProfileApplied events the probe appended (DESIGN section 1.3). An
        # enforced false refuses like a line saying the sandbox was not applied, and so does a
        # read_write path into grok's home (a grok whose built-in strict writes ~/.grok: its
        # README says it does, 1.0.70 measured it does not; every strict-based profile, the
        # repository's included, would grant the same); no event changes nothing (the log is
        # absent on other hosts or versions).
        evs = CXL.grok_sandbox_events(a.sandbox_events, a.sandbox_events_from, a.sandbox_events_to,
                                      a.sandbox_workspace) if a.sandbox_events and a.sandbox_workspace else []
        ev = next((e for e in evs if e["enforced"] is False), evs[0] if evs else None)
        hw = None
        for e in evs if a.sandbox_grok_home else []:
            hw = CXL.grok_home_write(e["read_write_paths"] or [], a.sandbox_grok_home)
            if hw:
                break
        if not why and ev and ev["enforced"] is False:
            why = ("its sandbox log says --sandbox %s ran unenforced: ProfileApplied, enforced false, platform %s, in %s" % (
                ev["profile"], ev["platform"], a.sandbox_events))
        if why:
            hw = None  # home_write names the refusal's reason only
        elif hw:
            why = ("its sandbox log says --sandbox strict grants write to grok's home %s here (read_write path %s in the "
                   "probe's ProfileApplied event, in %s)" % (a.sandbox_grok_home, hw, a.sandbox_events))
        sandbox = {"ok": False if why else (True if a.sandbox_rc == 0 else None), "detail": why or (
            None if a.sandbox_rc == 0 else "grok --sandbox strict models exited %s" % a.sandbox_rc),
            "enforced": ev["enforced"] if ev else None, "platform": ev["platform"] if ev else None,
            "home_write": hw}
    if a.version_ok is not None:
        vok = a.version_ok == "true"
    try:
        helps = {}
        for name, val in _named(a.help_file, "help-file"):
            path, sep, label = val.rpartition("::")
            if not sep:
                path, label = val, ""
            helps[name] = (path, label or name)
        contract = flag_contract(helps, _named(a.argv_file, "argv-file"), _named(a.need, "need"),
                                 _named(a.argv_shell, "argv-shell"))
    except ValueError as e:
        CX.err("normalize: %s\n" % e)
        return 1
    res = {"lane": a.lane, "bin": a.bin or None, "version": version, "version_ok": vok,
           "verified": a.verified or None, "logged_in": logged, "models": models, "model": a.model or None,
           "model_ok": mok, "contract": contract, "sandbox": sandbox, "cached": False, "paused": bool(a.paused),
           "wrapper": a.wrapper or None, "detail": detail}
    CX.out(json.dumps(res, ensure_ascii=False) + "\n")
    return 0


# The built-in grok profiles that let grok write its own home (grok's docs: off and devbox write
# everywhere, workspace writes ~/.grok; measured on 1.0.70: read-only writes ~/.grok, its bin/,
# vendor/ and installed-plugins/ included, tests/fixtures/real/grok/write-probe-read-only-1.0.70.txt).
GROK_HOME_WRITERS = ("off", "devbox", "workspace", "read-only")


def grok_check(profile, workspace, grok_home, probe_out, probe_rc, events, start, end):
    """The grok lane's per-run profile check (DESIGN section 15.2), from the free `grok --sandbox
    PROFILE models` the adapter ran in the run's checkout WORKSPACE and the bytes [START, END) it
    appended to grok's sandbox log EVENTS. Returns (reason or None, facts): a refusal when PROFILE
    is a built-in that writes grok's home (whatever the log says), when the probe's output says the
    sandbox was not applied, when a ProfileApplied event for WORKSPACE has enforced false, or when
    one of its read_write_paths grants write to grok's home (cxlib.grok_home_write: GROK_HOME, a
    directory above it or one inside it, except GROK_HOME/sessions). No log, no event or a probe
    that failed otherwise (rc alone) changes nothing: like the preflight, the log can only add a
    refusal."""
    evs = CXL.grok_sandbox_events(events, start, end, workspace) if events and workspace else []
    facts = {"profile": profile, "workspace": workspace, "grok_home": grok_home, "log": events or None,
             "probe_rc": probe_rc, "events": len(evs), "event": None, "home_write": None}
    reason = None
    if profile in GROK_HOME_WRITERS:
        reason = ("--sandbox %s is grok's built-in %s profile, which lets grok write its home %s (grok's own binary, ripgrep "
                  "and plugins, which later run outside any sandbox): conductor's grok runs use the repository's strict-based "
                  "profile (option grok_sandbox_profile auto)" % (profile, profile, grok_home))
    why = grok_nosandbox(read(probe_out)) if probe_out else None
    if not reason and why:
        reason = "grok --sandbox %s models in %s says the sandbox was not applied (%s)" % (profile, workspace, why)
    for ev in evs:
        if ev["enforced"] is False:
            facts["event"] = ev
            if not reason:
                reason = ("grok's sandbox log %s says --sandbox %s ran unenforced in %s (ProfileApplied, enforced false, "
                          "platform %s)" % (events, ev["profile"], workspace, ev["platform"]))
            break
    for ev in evs:
        hw = CXL.grok_home_write(ev["read_write_paths"] or [], grok_home)
        if hw:
            facts["home_write"] = hw
            facts["event"] = facts["event"] or ev
            if not reason:
                reason = ("grok's sandbox profile %s grants write to grok's home %s (read_write path %s in its ProfileApplied "
                          "event for %s, in %s): a run steered by what it reads could replace grok's own binary, ripgrep or "
                          "plugins there, which later run outside any sandbox" % (ev["profile"], grok_home, hw, workspace, events))
            break
    if facts["event"] is None and evs:
        facts["event"] = evs[0]
    # grok's resolver and TLS files (DESIGN section 15.7): an enforced event that lists its read
    # paths (read_only_paths, as strict and the profiles extending it log them on 1.0.70) shows
    # whether grok can read them under this profile. A note, never a refusal: a file grok cannot
    # read there makes its API calls fail (on WSL, measured: no name resolved, and grok retried
    # for 28 minutes), and the run's failure reason then names it.
    facts["notes"] = []
    ev = next((e for e in evs if e["enforced"] and isinstance(e.get("read_only_paths"), list)), None) if not reason else None
    if ev is not None:
        root = os.environ.get("CX_DETECT_ROOT", "")
        bad = CXL.grok_resolver_unreadable(root, os.environ, ev["read_only_paths"] + (ev["read_write_paths"] or []))
        facts["resolver_unreadable"] = [{"path": t["path"], "real": t["real"], "kind": t["kind"]} for t in bad]
        for t in bad:
            facts["notes"].append("grok's sandbox log shows profile %s cannot read %s (grok's %s file) in %s: grok %s under it "
                                  "(cx-doctor D17)" % (ev["profile"], CXL._target_text(t), "resolver" if t["kind"] != "tls" else "TLS",
                                                       workspace, CXL.GROK_RESOLVER_EFFECT.get(t["kind"], "cannot read it")))
    facts["ok"] = reason is None
    facts["reason"] = reason
    return reason, facts


def cmd_grok_netlog(a):
    found = grok_netlog(a.file, a.start, a.end)
    if found:
        CX.atomic_write(a.out, "".join(p + "\n" for p in found))
    return 0


def cmd_grok_check(a):
    reason, facts = grok_check(a.profile, a.workspace, a.grok_home, a.probe_out, a.probe_rc, a.events, a.start, a.end)
    if a.json_out:
        try:
            CX.atomic_write(a.json_out, json.dumps(facts, ensure_ascii=False) + "\n")
        except OSError as e:
            CX.err("normalize: grok-check: %s\n" % e)
            return 2
    # Paths can be long: the verdict keeps the whole reason (one line; the signal shortens it).
    # Notes follow it, one "note <text>" line each.
    CX.out(("refuse " + CX.sanitize(reason, 8000) if reason else "ok") + "\n"
           + "".join("note %s\n" % CX.sanitize(n, 600) for n in facts.get("notes") or []))
    return 0


def _cache_path():
    home = os.environ.get("CX_HOME") or os.path.join(os.path.expanduser("~"), ".conductor")
    return os.path.join(home, "state", "preflight.json")


def cmd_cache_get(a):
    data = load_json(_cache_path()) or {}
    e = data.get(a.key)
    if not isinstance(e, dict) or not isinstance(e.get("result"), dict):
        return 1
    if time.time() - (num(e.get("t")) or 0) > a.ttl:
        return 1
    r = dict(e["result"])
    r["cached"] = True
    CX.out(json.dumps(r, ensure_ascii=False) + "\n")
    return 0


def cmd_cache_put(a):
    try:
        r = json.loads(read(a.file) if a.file != "-" else sys.stdin.read())
    except ValueError:
        return 1
    if not isinstance(r, dict):
        return 1
    if verdict(r) != "0 OK":
        return 0  # only a green probe is cached: a refusal is probed again next time
    p = _cache_path()
    data = load_json(p) or {}
    now = time.time()
    data = {k: v for k, v in data.items() if isinstance(v, dict) and now - (num(v.get("t")) or 0) < 86400}
    data[a.key] = {"t": now, "result": r}
    try:
        CX.atomic_write(p, json.dumps(data, ensure_ascii=False) + "\n", 0o600)
    except OSError:
        return 1
    return 0


# --------------------------------------------------------------------------- agy watcher

def cmd_agy_watch(a):
    """Follows agy's stream-json until the process group is gone (DESIGN section 15.2 agy row)."""
    pos = 0
    buf = ""
    seen_init = seen_result = False
    result_at = None
    ev_out = open(a.events, "a", encoding="utf-8")

    def emit(line):
        ev_out.write(line + "\n")
        ev_out.flush()

    def alive():
        try:
            os.killpg(a.pgid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    while True:
        try:
            with open(a.ndjson, "rb") as fh:
                fh.seek(pos)
                chunk = fh.read()
        except OSError:
            chunk = b""
        if chunk:
            pos += len(chunk)
            buf += chunk.decode("utf-8", "replace")
            lines = buf.split("\n")
            buf = lines.pop()
            for ln in lines:
                ln = ln.strip()
                if not ln.startswith("{"):
                    continue
                try:
                    ev = json.loads(ln, strict=False)
                except ValueError:
                    continue
                if not isinstance(ev, dict):
                    continue
                k = agy_event_kind(ev)
                if k == "init" and not seen_init:
                    seen_init = True
                    emit("init " + (agy_init_model(ev) or ""))
                elif k == "result" and not seen_result:
                    seen_result = True
                    result_at = time.time()
                    emit("result")
        if not alive():
            return 0
        if result_at is not None and time.time() - result_at >= a.after_result:
            try:
                os.killpg(a.pgid, signal.SIGKILL)
                emit("killed_after_result")
            except ProcessLookupError:
                pass
            return 0
        time.sleep(0.2)


# --------------------------------------------------------------------------- tree snapshots

def _blocks(text):
    res = {}
    cur = None
    for ln in text.split("\n"):
        if ln.startswith("== "):
            cur = ln[3:]
            res[cur] = []
        elif cur is not None:
            res[cur].append(ln)
    return {k: "\n".join(v) for k, v in res.items()}


def cmd_trees_diff(a):
    """Changed worktrees between two snapshots: only trees present in both, minus every path
    named in an exclude file (running marks read before and after the run), so a worktree added
    or removed during the run, or one whose mark disappeared mid-run, is no false alarm."""
    b = _blocks(read(a.before))
    af = _blocks(read(a.after))
    excl = set()
    for p in a.exclude_file or []:
        for ln in read(p).split("\n"):
            if ln.strip():
                excl.add(ln.rstrip("/"))
    changed = [t for t in sorted(set(b) & set(af)) if t.rstrip("/") not in excl and b[t] != af[t]]
    for t in changed:
        CX.out(t + "\n")
    return 1 if changed else 0


# --------------------------------------------------------------------------- cloud task text

def _sections(text):
    secs = {}
    cur = None
    for ln in text.split("\n"):
        m = re.match(r"^##\s+(.+?)\s*$", ln)
        if m:
            cur = m.group(1).strip().lower()
            secs[cur] = []
        elif cur is not None:
            secs[cur].append(ln)
    return {k: "\n".join(v).strip() for k, v in secs.items()}


def cmd_render_cloud(a):
    """The Copilot cloud agent's task (U7, DESIGN section 15 build order item 3) from a section
    6.4 task.md: goal, context, acceptance tests, allowed changes and commands; the agent opens a
    pull request, so the contract's ban on committing, pushing and branching is dropped."""
    text = read(a.task)
    if not text.strip():
        CX.err("normalize: empty task file %s\n" % a.task)
        return 1
    lines = text.split("\n")
    meta = {}
    if lines and lines[0].startswith("<!-- cx-task "):
        try:
            meta = json.loads(lines[0][len("<!-- cx-task "):].rsplit("-->", 1)[0])
        except ValueError:
            meta = {}
    title = next((ln[2:].strip() for ln in lines if ln.startswith("# ")), "Task")
    s = _sections(text)
    parts = ["# " + title, ""]
    for head, key in (("Goal", "goal"), ("Context", "context"), ("Acceptance tests", "acceptance tests"),
                      ("Allowed changes", "allowed changes"), ("Allowed commands", "allowed commands")):
        if s.get(key):
            parts += ["## " + head, s[key], ""]
    forb = s.get("forbidden", "")
    forb = re.sub(r"\s*committing, pushing or branching;?", "", forb)
    if forb.strip():
        parts += ["## Forbidden", forb.strip(), ""]
    base = a.base or meta.get("base_branch")
    parts += ["## Delivery",
              "Open one pull request%s with the change. In its description: what changed (file:line), what you ran and its result, open issues." % (" against " + base if base else ""),
              "Do not merge it. Do not change files outside the allowed changes."]
    if meta.get("id"):
        parts += ["", "<!-- cx-task-id %s -->" % re.sub(r"[^A-Za-z0-9._-]", "", str(meta["id"]))]
    CX.out("\n".join(parts).rstrip() + "\n")
    return 0


def typed_pairs(items):
    """KEY VALUE pairs -> dict (cxlib.py's rule: KEY suffixes :int :bool :json; none = string)."""
    obj = {}
    items = list(items) + ([""] if len(items) % 2 else [])
    for i in range(0, len(items), 2):
        key, val = items[i], items[i + 1]
        kind = ""
        if ":" in key:
            key, kind = key.rsplit(":", 1)
        if kind == "int":
            try:
                obj[key] = int(val.strip())
            except ValueError:
                obj[key] = None
        elif kind == "bool":
            obj[key] = val.strip().lower() in ("1", "true", "yes", "on")
        elif kind == "json":
            try:
                obj[key] = json.loads(val)
            except ValueError:
                obj[key] = None
        else:
            obj[key] = val
    return obj


def cmd_obj(a):
    """One JSON object from KEY VALUE pairs plus --list NAME ITEM groups (adapter meta.json and
    run.json): "--list allow 3 a b c" adds "allow": ["a", "b", "c"]."""
    items = list(a.items)
    obj = {}
    rest = []
    i = 0
    while i < len(items):
        if items[i] == "--list" and i + 2 < len(items) + 1:
            name = items[i + 1]
            n = int(items[i + 2]) if re.fullmatch(r"\d+", items[i + 2] or "") else 0
            obj[name] = items[i + 3:i + 3 + n]
            i += 3 + n
        else:
            rest.append(items[i])
            i += 1
    res = typed_pairs(rest)
    res.update(obj)
    CX.out(CX.dumps_line(res) + "\n")
    return 0


def cmd_uuid(a):
    import uuid
    CX.out(str(uuid.uuid4()) + "\n")
    return 0


def cmd_meta_env(a):
    """The run-time fields of a meta.json as shell assignments (adapter run reads its own argv)."""
    m = load_json(a.file)
    if m is None:
        return 1
    pairs = (("A_TIMEOUT", "timeout_s"), ("A_PROMPT", "prompt"), ("A_WT", "wt"), ("A_MODE", "mode"),
             ("CXA_MODEL", "model_requested"), ("CXA_EFFORT", "effort_requested"), ("A_FUSION", "fusion"),
             ("CXA_VARIANT", "variant"), ("CXA_SESSION_HINT", "session_hint"), ("A_ID", "id"),
             ("A_REPO", "repo"), ("A_GH_REPO", "repo_gh"), ("A_BASE_BRANCH", "base_branch"))
    for var, key in pairs:
        v = m.get(key)
        if v is None:
            v = ""
        CX.out("%s=%s\n" % (var, CX.shell_quote(str(v))))
    return 0


def cmd_json_list(a):
    CX.out(json.dumps(list(a.items), ensure_ascii=False) + "\n")
    return 0


def verdict(p):
    """The probe's verdict for adapter run (DESIGN section 15.1 free preflight): "<exit> <STATUS>
    <reason>", first match: binary missing 13, flag contract 26 (the live help lacks a flag the
    lane is about to emit; never the version: nothing is pinned), agy paused 28, grok's sandbox
    not applicable here 2, login 11, model 14."""
    lane = p.get("lane")
    c = p.get("contract") if isinstance(p.get("contract"), dict) else None
    if p.get("bin") is None and p.get("version_ok") is not True:
        line = "13 CLI_MISSING the %s CLI is not available" % lane
    elif c is not None and c.get("ok") is False:
        what = c.get("missing") or []
        if what:
            why = "the help no longer lists %s" % ", ".join(str(x) for x in what[:4])
        else:
            why = "the help could not be read (%s)" % ", ".join(str(x) for x in (c.get("unreadable") or [])[:3])
        line = "26 VERSION_MISMATCH flag contract: %s %s: %s; refused before running (the CLI changed: update the conductor or report it)" % (
            lane, p.get("version") or "(version unknown)", why)
    elif p.get("paused"):
        line = "28 NO_CAPACITY agy dispatch is paused after a wrong_tree result: inspect the changed tree, then run cx-job unpause agy"
    elif isinstance(p.get("sandbox"), dict) and p["sandbox"].get("ok") is False and p["sandbox"].get("home_write"):
        line = ("2 FAILED %s's built-in strict profile lets it write its own home on this host (%s): its binary, ripgrep and "
                "plugins there run outside any sandbox later, and every grok run (the repository's strict-based profile "
                "included) approves every tool inside its sandbox, so the lane is refused (cx-doctor D17)" % (
                    lane, p["sandbox"].get("detail")))
    elif isinstance(p.get("sandbox"), dict) and p["sandbox"].get("ok") is False:
        line = ("2 FAILED %s cannot apply its sandbox on this host (%s): it runs with --always-approve inside it, so the lane is "
                "refused (on Linux and WSL it needs Landlock, kernel 5.13 or newer, and bubblewrap; cx-doctor D17)" % (
                    lane, p["sandbox"].get("detail") or "grok --sandbox strict models"))
    elif p.get("logged_in") is False:
        line = "11 AUTH_REQUIRED %s is not logged in (cx-doctor --login-help %s)" % (lane, lane)
    elif p.get("model_ok") is False:
        line = "14 MODEL_UNAVAILABLE %s is not in the %s catalog" % (p.get("model"), lane)
    else:
        line = "0 OK"
    return line


def cmd_verdict(a):
    """Prints "<exit> <STATUS> <version or -> <reason>" for a probe JSON."""
    try:
        p = json.loads(a.json)
    except ValueError:
        CX.out("2 FAILED - the probe output is not JSON\n")
        return 0
    code, _, rest = verdict(p).partition(" ")
    status, _, reason = rest.partition(" ")
    CX.out("%s %s %s %s\n" % (code, status, p.get("version") or "-", reason))
    return 0


def cmd_json_extract(a):
    """The first JSON object in RAW (whole text, else the last object line) into OUT."""
    v = last_json_object(read(a.raw))
    if v is None:
        return 1
    CX.atomic_write(a.out, json.dumps(v, ensure_ascii=False) + "\n")
    return 0


def cmd_worker_settings(a):
    """$OUT/cx-worker.json for the --headless claude worker (DESIGN section 15.2): the template's
    deny rules, one Bash(<cmd>) allow rule per routes command."""
    tpl = load_json(a.template) or {}
    perms = tpl.get("permissions") if isinstance(tpl.get("permissions"), dict) else {}
    allow = [r for r in perms.get("allow") or [] if isinstance(r, str)]
    for c in a.allow or []:
        if c.strip():
            allow.append("Bash(%s)" % c.strip())
    perms["allow"] = allow
    tpl["permissions"] = perms
    CX.atomic_write(a.out, json.dumps(tpl, ensure_ascii=False, indent=2) + "\n")
    return 0


# The agy raw lane's per-run grants (DESIGN section 15.2, agy row; measured 2026-11-06 on agy
# 1.5.1: --settings is session-only, command(<rule>) matches each simple command of a compound
# line as a token prefix, write_file(<dir>) grants writes beneath <dir>, reads inside the
# workspace need no grant, and one denial ends a headless run). agy has no filesystem sandbox, and
# a token-prefix rule cannot forbid an option: command(git diff) would also allow git diff
# --output=<any path> (a write anywhere) and git diff --no-index <any file> (a read anywhere),
# git log and git show likewise, so agy reads its own changes with its file tools and git status.
AGY_ALLOW_COMMANDS = ("cx-route", "git status", "ls")


def agy_settings(wts):
    allow = []
    for w in wts:
        w = (w or "").rstrip("/")
        if w and not CTRL_RE.search(w) and "write_file(%s)" % w not in allow:
            allow.append("write_file(%s)" % w)
    allow.extend("command(%s)" % c for c in AGY_ALLOW_COMMANDS)
    return {"permissions": {"allow": allow}}


def cmd_agy_settings(a):
    """$OUT/agy-settings.json for agy --settings: write_file(<worktree>) (and its physical path
    when that differs) plus command() for cx-route, git status and ls. Never a skip-permissions
    switch, never a global grant."""
    try:
        CX.atomic_write(a.out, json.dumps(agy_settings(a.wt or []), ensure_ascii=False, indent=1) + "\n", 0o600)
    except OSError as e:
        CX.err("normalize: cannot write %s: %s\n" % (a.out, e))
        return 1
    return 0


def cmd_field_lines(a):
    d = load_json(a.file)
    v = d
    for k in [p for p in a.key.split(".") if p]:
        v = v.get(k) if isinstance(v, dict) else None
    if not isinstance(v, list):
        return 1
    for x in v:
        if isinstance(x, str) and x and not CTRL_RE.search(x):
            CX.out(x + "\n")
    return 0


def cmd_field(a):
    d = load_json(a.file)
    if d is None:
        return 1
    v = d
    for k in [p for p in a.key.split(".") if p]:
        if isinstance(v, dict) and k in v:
            v = v[k]
        elif isinstance(v, list) and re.fullmatch(r"\d+", k) and int(k) < len(v):
            v = v[int(k)]
        else:
            return 1
    CX.out((v if isinstance(v, str) else json.dumps(v, ensure_ascii=False)) + "\n")
    return 0


# --------------------------------------------------------------------------- cx-run helpers

ROUTE_CMDS = ("test", "lint", "typecheck")
ROUTE_POOLS = ("agy", "copilot", "grok")


def _clean_cmd(v):
    """A routes or task command: a non-empty string without control characters, else None."""
    if not isinstance(v, str) or not v.strip() or CTRL_RE.search(v):
        return None
    return v.strip()


def _sh_array(name, items):
    return "%s=(%s)\n" % (name, " ".join(CX.shell_quote(i) for i in items))


def cmd_routes(a):
    """.cx/routes.json (DESIGN section 9.4) for cx-run, as shell assignments: RT_FOUND 1|0,
    RT_VALID 1|0, RT_SETUP (empty = none), RT_CMDS (test, lint, typecheck in that order, the
    non-null ones), RT_POOL_<pool> 1|0 (missing = 1, U4), RT_DIFF_BUDGET. Never fails: a missing
    or invalid file gives the defaults (RT_FOUND/RT_VALID say which)."""
    found = os.path.isfile(a.file)
    d = None
    if found:
        try:
            with open(a.file, encoding="utf-8-sig") as fh:
                d = json.load(fh)
        except (OSError, ValueError):
            d = None
    valid = isinstance(d, dict)
    d = d if valid else {}
    setup = _clean_cmd(d.get("setup")) or ""
    cmds = d.get("commands") if isinstance(d.get("commands"), dict) else {}
    lst = [c for c in (_clean_cmd(cmds.get(k)) for k in ROUTE_CMDS) if c]
    pools = d.get("pools") if isinstance(d.get("pools"), dict) else {}
    budget = d.get("diff_budget") if isinstance(d.get("diff_budget"), int) and not isinstance(d.get("diff_budget"), bool) else 400
    o = "RT_FOUND=%d\nRT_VALID=%d\nRT_SETUP=%s\n" % (1 if found else 0, 1 if (valid or not found) else 0, CX.shell_quote(setup))
    o += _sh_array("RT_CMDS", lst)
    for p in ROUTE_POOLS:
        o += "RT_POOL_%s=%d\n" % (p, 0 if pools.get(p) is False else 1)
    o += "RT_DIFF_BUDGET=%d\n" % budget
    CX.out(o)
    return 0


ROUTE_NAME_RE = re.compile(r"[a-z][a-z0-9_-]{0,31}")
# The one shell command besides cx-route every executor may run (git diff, log and show take
# --output=<path>, a write anywhere, and diff --no-index reads any file; DESIGN section 15.1).
CX_ROUTE_ALSO = ("git status",)


def route_names(routes_file, cmds):
    """[(name, command)] for the task's commands: the .cx/routes.json name of each (a key of
    "commands" whose value is that command), else cmd-1, cmd-2 ... in order."""
    named = []
    try:
        with open(routes_file, encoding="utf-8-sig") as fh:
            d = json.load(fh)
    except (OSError, ValueError):
        d = None
    rc = d.get("commands") if isinstance(d, dict) and isinstance(d.get("commands"), dict) else {}
    for k in list(ROUTE_CMDS) + sorted(k for k in rc if k not in ROUTE_CMDS):
        c = _clean_cmd(rc.get(k))
        if c and isinstance(k, str) and ROUTE_NAME_RE.fullmatch(k):
            named.append((k, c))
    out, taken, n = [], set(), 0
    for c in cmds:
        c = _clean_cmd(c)
        if not c or any(c == x for _, x in out):
            continue
        name = next((k for k, x in named if x == c and k not in taken), None)
        while name is None:
            n += 1
            if "cmd-%d" % n not in taken and all(k != "cmd-%d" % n for k, _ in named):
                name = "cmd-%d" % n
        taken.add(name)
        out.append((name, c))
    return out


def _route_bash(path):
    """The absolute bash cx-route runs under (its shebang, with -p): /bin/bash (a system path, which
    grok's strict profile reads), else the caller's bash (--bash, cx-run's $BASH)."""
    for b in ("/bin/bash", path or "", "/usr/bin/bash"):
        if b.startswith("/") and re.fullmatch(r"[A-Za-z0-9._/+-]+", b) and os.access(b, os.X_OK):
            return b
    return "/bin/bash"


def cx_route_script(task_id, out_dir, run_dir, routes, bash=""):
    """The text of the run's cx-route ($CX_HOME/routes/<id>/cx-route): self-contained (no runtime
    file, no python), so it also runs inside grok's strict sandbox, which reads only the
    worktree, system paths and the read_only grants of its profile. Whoever calls it controls its
    environment, so nothing from there runs but the snapshotted command: bash -p (no BASH_ENV,
    SHELLOPTS, BASHOPTS or imported functions), and the check gets the caller's exported
    variables through env -i without BASH_ENV, ENV, SHELLOPTS, BASHOPTS, CDPATH and GLOBIGNORE,
    and without the BASH_FUNC_* strings exported functions travel in."""
    q = CX.shell_quote
    lst = ["  printf '%%s\\n' %s" % q("cx-route: the checks of task %s (run one as: cx-route <name>):" % task_id)]
    for name, c in routes:
        lst.append("  printf '%%s\\n' %s" % q("  %s: %s" % (name, c)))
    if not routes:
        lst.append("  printf '%%s\\n' %s" % q("  (none: .cx/routes.json defines no check for this task)"))
    arms = ["  %s) cmd=%s ;;" % (name, q(c)) for name, c in routes]
    return "\n".join([
        "#!%s -p" % _route_bash(bash),
        "# shellcheck disable=SC2016  # the snapshotted commands are data, single-quoted on purpose",
        "# cx-route - the checks of conductor task %s, as cx-run snapshotted them from .cx/routes.json" % CX.sanitize(task_id, 80),
        "# at dispatch (%s/routes.json; docs/DESIGN.md section 15.1). Editing the worktree's" % CX.sanitize(out_dir, 4000),
        "# .cx/routes.json changes nothing here. Generated by cx-run; do not edit.",
        "#",
        "# Usage: cx-route <name>   runs that check in %s; its exit status passes through" % CX.sanitize(run_dir, 4000),
        "#        cx-route          lists the names and their commands (also -l, --list, -h, --help)",
        "#",
        "# Exit codes: the check's own status; 0 for the list; 127 for a name that is not in the",
        "# snapshot, or for anything after the name (nothing runs then).",
        "list() {",
    ] + lst + [
        "}",
        'case "${1-}" in',
        '  ""|-l|--list|-h|--help)',
        '    if [ $# -le 1 ]; then list; exit 0; fi ;;',
        "esac",
        'if [ $# -ne 1 ]; then',
        "  printf 'cx-route: give one check name and nothing else (%s arguments given)\\n' \"$#\" >&2",
        "  list >&2",
        "  exit 127",
        "fi",
        'case "$1" in',
    ] + arms + [
        "  *)",
        "    printf \"cx-route: no check named '%s' in this task's snapshot\\n\" \"$1\" >&2",
        "    list >&2",
        "    exit 127 ;;",
        "esac",
        "# A clean shell for the check: nothing of the caller's shell setup runs (bash -p here and",
        "# below; env -i drops BASH_FUNC_* and the startup variables for every process it starts).",
        "keep=()",
        "for n in $(compgen -e); do",
        '  case "$n" in BASH_ENV|ENV|SHELLOPTS|BASHOPTS|CDPATH|GLOBIGNORE) ;; *) keep+=("$n=${!n}") ;; esac',
        "done",
        "cd -- %s || exit 127" % q(run_dir),
        'exec /usr/bin/env -i "${keep[@]+"${keep[@]}"}" "$BASH" -p -o pipefail -c "$cmd"',
        "",
    ])


def cmd_route_snapshot(a):
    """$OUT/routes.json and BIN/cx-route for one run (DESIGN section 15.1, cx-route; BIN is
    $CX_HOME/routes/<id>, the one directory of the run that grok's profile may read, default
    $OUT/bin): the task's commands named from .cx/routes.json at dispatch. The worker runs
    checks only through cx-route <name>; a later edit of the worktree's routes.json never
    reaches it."""
    routes = route_names(a.routes, a.cmd or [])
    if a.dry_run:
        CX.out("".join("%s: %s\n" % (n, c) for n, c in routes))
        return 0
    snap = {"version": 1, "id": a.id, "dir": a.dir, "source": a.routes, "created_at": CX.iso(CX.utc_now()),
            "routes": [{"name": n, "command": c} for n, c in routes], "also": list(CX_ROUTE_ALSO)}
    bindir = a.bin or os.path.join(a.out, "bin")
    try:
        os.makedirs(a.out, exist_ok=True)
        os.makedirs(bindir, exist_ok=True)
        CX.atomic_write(os.path.join(a.out, "routes.json"), json.dumps(snap, ensure_ascii=False, indent=1) + "\n")
        CX.atomic_write(os.path.join(bindir, "cx-route"), cx_route_script(a.id, a.out, a.dir, routes, a.bash), 0o755)
    except OSError as e:
        CX.err("normalize: cannot write the cx-route snapshot in %s: %s\n" % (a.out, e))
        return 1
    return 0


def snapshot_routes(path):
    """[(name, command)] of a route snapshot ($OUT/routes.json), [] when absent."""
    d = load_json(path) if path else None
    res = []
    for r in (d or {}).get("routes") or []:
        if isinstance(r, dict) and isinstance(r.get("name"), str) and _clean_cmd(r.get("command")):
            res.append((r["name"], _clean_cmd(r["command"])))
    return res


TASK_RE = re.compile(r"^<!-- cx-task (\{.*\}) -->\s*$")


def task_line1(path):
    """The line-1 JSON object of a section 6.4 task.md, or (None, why)."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            first = fh.read().split("\n", 1)[0]
    except OSError as e:
        return None, "cannot read %s: %s" % (path, e.strerror or e)
    m = TASK_RE.match(first)
    if not m:
        return None, "line 1 of %s is not <!-- cx-task {json} --> (section 6.4)" % path
    try:
        obj = json.loads(m.group(1))
    except ValueError as e:
        return None, "line 1 of %s holds invalid JSON: %s" % (path, e)
    if not isinstance(obj, dict):
        return None, "line 1 of %s is not a JSON object" % path
    return obj, ""


def cmd_task_meta(a):
    """A task.md's line-1 JSON as shell assignments: TK_ID TK_BASE TK_LANE TK_EFFORT (empty when
    absent or not a plain string), TK_SUBAGENTS 1|0, TK_LOCKFILES 1|0, TK_HAS_CMDS 1|0, TK_CMDS
    and TK_ALLOWED (arrays). Exit 1 (reason on stderr) when line 1 is missing or invalid."""
    obj, why = task_line1(a.file)
    if obj is None:
        CX.err("normalize: %s\n" % why)
        return 1

    def s(k, pat):
        v = obj.get(k)
        return v if isinstance(v, str) and re.fullmatch(pat, v) else ""

    o = "TK_ID=%s\n" % CX.shell_quote(s("id", r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}"))
    o += "TK_BASE=%s\n" % CX.shell_quote(s("base", r"[0-9a-fA-F]{7,64}"))
    o += "TK_LANE=%s\n" % CX.shell_quote(s("lane", r"[a-z][a-z-]{0,30}"))
    o += "TK_EFFORT=%s\n" % CX.shell_quote(s("effort", r"low|medium|high|xhigh|max"))
    o += "TK_SUBAGENTS=%d\nTK_LOCKFILES=%d\n" % (obj.get("subagents") is True, obj.get("lockfiles") is True)
    cmds = obj.get("commands")
    o += "TK_HAS_CMDS=%d\n" % isinstance(cmds, list)
    o += _sh_array("TK_CMDS", [c for c in (_clean_cmd(x) for x in (cmds if isinstance(cmds, list) else [])) if c])
    ap = obj.get("allowed_paths")
    o += _sh_array("TK_ALLOWED", [x for x in (ap if isinstance(ap, list) else []) if isinstance(x, str) and x and not CTRL_RE.search(x)])
    CX.out(o)
    return 0


def cmd_task_render(a):
    """A free-text task wrapped into templates/task.md (DESIGN section 15.1): line 1 carries the
    id, base, lane, effort, no allowed_paths and the routes commands; the text is the goal."""
    text = read(a.text_file).strip("\n")
    if not text.strip():
        CX.err("normalize: the task text is empty\n")
        return 1
    tpl = read(a.template)
    if "{{goal}}" not in tpl:
        CX.err("normalize: %s is not the task template\n" % a.template)
        return 1
    cmds = [c for c in (_clean_cmd(x) for x in (a.cmd or [])) if c]
    head = {"id": a.id, "base": a.base, "lane": a.lane, "effort": a.effort, "allowed_paths": [],
            "lockfiles": False, "commands": cmds}
    title = CX.sanitize(text.strip().split("\n", 1)[0], 100)
    names = dict((c, n) for n, c in snapshot_routes(a.snapshot)) if a.snapshot else {}
    q = lambda c: "`cx-route %s` (`%s`)" % (names[c], c) if c in names else "`%s`" % c
    vals = {
        "json": json.dumps(head, ensure_ascii=False),
        "id": a.id, "title": title, "goal": text.strip(),
        "must_pass": "\n".join("- Must pass: %s" % q(c) for c in cmds) or "- No acceptance command is defined in .cx/routes.json: say how you checked the change.",
        "commands": ", ".join(q(c) for c in cmds) or "none (.cx/routes.json defines no check)",
    }
    out = tpl
    for k, v in vals.items():
        out = out.replace("{{%s}}" % k, v)
    CX.atomic_write(a.out, out if out.endswith("\n") else out + "\n")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="normalize.py")
    sub = ap.add_subparsers(dest="cmd")
    s = sub.add_parser("parse")
    s.add_argument("--lane", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_parse)
    s = sub.add_parser("emit")
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_emit)
    s = sub.add_parser("report")
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_report)
    s = sub.add_parser("probe")
    s.add_argument("--lane", required=True)
    s.add_argument("--bin", default="")
    s.add_argument("--wrapper", default="")
    s.add_argument("--version-out", default="")
    s.add_argument("--verified", default="")
    s.add_argument("--help-file", action="append", help="NAME=PATH[::LABEL] a captured --help")
    s.add_argument("--argv-file", action="append", help="NAME=PATH a NUL-separated argv checked against help NAME")
    s.add_argument("--argv-shell", action="append", help="NAME=PATH a printf %%q command line (ghcp-delegate --print-command) checked against help NAME")
    s.add_argument("--need", action="append", help="NAME=TOKEN one more token help NAME must list")
    s.add_argument("--models-cli", default="")
    s.add_argument("--models-out", default="")
    s.add_argument("--models-rc", type=int, default=None)
    s.add_argument("--model", default="")
    s.add_argument("--model-ok", choices=("true", "false"), default=None)
    s.add_argument("--version-ok", choices=("true", "false"), default=None)
    s.add_argument("--auth-out", default="")
    s.add_argument("--auth-kind", default="")
    s.add_argument("--auth-rc", type=int, default=None)
    s.add_argument("--paused", action="store_true")
    s.add_argument("--sandbox-out", default="", help="grok --sandbox strict models output (grok's sandbox applies here)")
    s.add_argument("--sandbox-rc", type=int, default=None)
    s.add_argument("--sandbox-events", default="", help="grok's sandbox log (sandbox-events.jsonl)")
    s.add_argument("--sandbox-events-from", type=int, default=0, help="its size before the sandbox probe")
    s.add_argument("--sandbox-events-to", type=int, default=0, help="its size after the sandbox probe")
    s.add_argument("--sandbox-workspace", default="", help="the sandbox probe's working directory")
    s.add_argument("--sandbox-grok-home", default="", help="${GROK_HOME:-~/.grok}: a read_write path into it refuses the lane")
    s.set_defaults(fn=cmd_probe)
    s = sub.add_parser("cache-get")
    s.add_argument("--key", required=True)
    s.add_argument("--ttl", type=int, default=600)
    s.set_defaults(fn=cmd_cache_get)
    s = sub.add_parser("cache-put")
    s.add_argument("--key", required=True)
    s.add_argument("--file", default="-")
    s.set_defaults(fn=cmd_cache_put)
    s = sub.add_parser("agy-watch")
    s.add_argument("--ndjson", required=True)
    s.add_argument("--events", required=True)
    s.add_argument("--pgid", type=int, required=True)
    s.add_argument("--after-result", type=float, default=5.0)
    s.set_defaults(fn=cmd_agy_watch)
    s = sub.add_parser("trees-diff")
    s.add_argument("before")
    s.add_argument("after")
    s.add_argument("--exclude-file", action="append")
    s.set_defaults(fn=cmd_trees_diff)
    s = sub.add_parser("render-cloud")
    s.add_argument("--task", required=True)
    s.add_argument("--base", default="")
    s.set_defaults(fn=cmd_render_cloud)
    s = sub.add_parser("obj")
    s.add_argument("items", nargs=argparse.REMAINDER)
    s.set_defaults(fn=cmd_obj)
    s = sub.add_parser("uuid")
    s.set_defaults(fn=cmd_uuid)
    s = sub.add_parser("meta-env")
    s.add_argument("file")
    s.set_defaults(fn=cmd_meta_env)
    s = sub.add_parser("json-list")
    s.add_argument("items", nargs="*")
    s.set_defaults(fn=cmd_json_list)
    s = sub.add_parser("verdict")
    s.add_argument("json")
    s.set_defaults(fn=cmd_verdict)
    s = sub.add_parser("json-extract")
    s.add_argument("raw")
    s.add_argument("out")
    s.set_defaults(fn=cmd_json_extract)
    s = sub.add_parser("worker-settings")
    s.add_argument("--template", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--allow", action="append")
    s.set_defaults(fn=cmd_worker_settings)
    s = sub.add_parser("agy-settings")
    s.add_argument("--out", required=True)
    s.add_argument("--wt", action="append")
    s.set_defaults(fn=cmd_agy_settings)
    s = sub.add_parser("field")
    s.add_argument("file")
    s.add_argument("key")
    s.set_defaults(fn=cmd_field)
    s = sub.add_parser("field-lines")
    s.add_argument("file")
    s.add_argument("key")
    s.set_defaults(fn=cmd_field_lines)
    s = sub.add_parser("routes")
    s.add_argument("--file", required=True)
    s.set_defaults(fn=cmd_routes)
    s = sub.add_parser("task-meta")
    s.add_argument("--file", required=True)
    s.set_defaults(fn=cmd_task_meta)
    s = sub.add_parser("task-render")
    s.add_argument("--template", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--id", required=True)
    s.add_argument("--base", required=True)
    s.add_argument("--lane", required=True)
    s.add_argument("--effort", required=True)
    s.add_argument("--text-file", required=True)
    s.add_argument("--cmd", action="append")
    s.add_argument("--snapshot", default="", help="the run's $OUT/routes.json (cx-route names)")
    s.set_defaults(fn=cmd_task_render)
    s = sub.add_parser("route-snapshot")
    s.add_argument("--routes", required=True, help="the main checkout's .cx/routes.json (names)")
    s.add_argument("--out", required=True)
    s.add_argument("--dir", required=True, help="where the checks run (the worktree or gate checkout)")
    s.add_argument("--id", required=True)
    s.add_argument("--cmd", action="append")
    s.add_argument("--bin", default="", help="the directory of the run's cx-route ($CX_HOME/routes/<id>; default OUT/bin)")
    s.add_argument("--bash", default="", help="cx-run's bash, when /bin/bash is missing")
    s.add_argument("--dry-run", action="store_true", help="print name: command lines, write nothing")
    s.set_defaults(fn=cmd_route_snapshot)
    s = sub.add_parser("grok-check")
    s.add_argument("--profile", required=True, help="the run's --sandbox profile")
    s.add_argument("--workspace", required=True, help="the run's checkout (the check's cwd)")
    s.add_argument("--grok-home", required=True, help="${GROK_HOME:-~/.grok}")
    s.add_argument("--probe-out", default="", help="the output of grok --sandbox <profile> models")
    s.add_argument("--probe-rc", type=int, default=None)
    s.add_argument("--events", default="", help="grok's sandbox log (sandbox-events.jsonl)")
    s.add_argument("--from", dest="start", type=int, default=0, help="its size before the check")
    s.add_argument("--to", dest="end", type=int, default=0, help="its size after the check")
    s.add_argument("--json-out", default="", help="the check's facts as JSON (run.json sandbox_check)")
    s.set_defaults(fn=cmd_grok_check)
    s = sub.add_parser("grok-netlog")
    s.add_argument("--file", required=True, help="grok's log (~/.grok/logs/unified.jsonl)")
    s.add_argument("--from", dest="start", type=int, default=0, help="its size before the run")
    s.add_argument("--to", dest="end", type=int, default=0, help="its size after the run")
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_grok_netlog)
    a = ap.parse_args(argv)
    if not getattr(a, "fn", None):
        ap.print_help()
        return 1
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
