#!/usr/bin/env python3
"""cxlib.py - stdlib-only helpers for the conductor plugin (docs/DESIGN.md section 4.4).

Always invoked as `python3 -I cxlib.py <subcommand> ...` on the executor host (WSL or Linux),
never on Git Bash. Output goes to stdout unless a subcommand says otherwise. Malformed input is
counted and skipped, never a crash; settings and installed_plugins.json files are read with
encoding "utf-8-sig"; JSONL is split on "\\n" only; every JSON with variable content is built
with json.dumps.

Subcommands (DESIGN section 4.4 plus helpers used by cx-doctor and cx-init):
  emit NAME [KEY VALUE]...     one "CX_NAME {json}" line (KEY suffixes :int :num :bool :json :null)
  json [KEY VALUE]...          the same object without the prefix
  emit-obj NAME FILE           "CX_NAME <the JSON object in FILE>" (FILE "-" = stdin)
  sanitize                     stdin text -> one sanitized line
  semver TEXT | vercmp A B     first semver in TEXT | -1, 0 or 1
  json-get FILE DOTTED.KEY     a scalar (JSON for objects and lists); exit 1 when absent
  toml-get FILE SECTION KEY    raw value; exit 1 when absent
  toml-table FILE NAME         exit 0 when a table whose last key segment is NAME exists
  const NAME                   prints a message constant (CURSOR_WORKER_MSG, CURSOR_POOL_MSG)
  options-check                effective options (CLAUDE_PLUGIN_OPTION_*) validated (section 5.3)
  conductor-options FILE       the conductor's saved options in FILE as JSON
  plugins --config-dir DIR     sibling-plugin report (section 8.3)
  parse-models --cli C FILE    model ids per CLI (section 8.3 D16-D18)
  host-record                  writes the host record (section 7.6)
  tsv-to-json FILE             dotted TSV facts -> one JSON object
  agy-grant FILE PATH          checks the agy write_file grant (D18)
  wsl-resolve ...              cx-wsl: a tool's absolute path, PATH and copilot from the host record (7.7)
  doctor-siblings ...          D13, D20-D26 as doctor TSV records
  doctor-pools ...             section 8.4 as doctor TSV records plus the CX_POOLS payload
  claude-settings ...          the Claude Code settings layers D31/D32 read, as JSON (section 8.3)
  doctor-session ...           D31 and D32 as doctor TSV records (section 8.3)
  doctor-render ...            renders the doctor report (sections 8.2, 8.7); exit 0 or 4
  init-detect DIR              detection JSON (section 9.3)
  init-plan ...                detection plus cx-init's overrides -> plan JSON
  init-apply ...               bundle writer (section 9.2); exit 0 or 5
  pools-mtd --file F [--set N] reads or writes the month-to-date record (section 8.4)
"""

import argparse
import datetime
import json
import os
import re
import subprocess
import sys
import tempfile

VERSION = "0.1.0"

CURSOR_WORKER_MSG = "a grok worker process registers this machine with Cursor as a private worker; stop it"
CURSOR_POOL_MSG = "interactive Cursor IDE use on Grok/Composer drains the same weekly pool"

CONSTANTS = {"CURSOR_WORKER_MSG": CURSOR_WORKER_MSG, "CURSOR_POOL_MSG": CURSOR_POOL_MSG}

CTRL_RE = re.compile("[\x00-\x1f\x7f-\x9f  ]+")
SEMVER_RE = re.compile(r"\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?")
FREE_TEXT_KEYS = ("reason", "detail")
CONDUCTOR_ID = "conductor@conductor-for-claude-code"


# --------------------------------------------------------------------------- basics

def out(text):
    sys.stdout.write(text)


def err(text):
    sys.stderr.write(text)


def sanitize(text, limit=200):
    s = CTRL_RE.sub(" ", str(text)).strip()
    if len(s) > limit:
        s = s[: limit - 3] + "..."
    return s


def cx_bool(value):
    v = re.sub(r"\s+", "", str(value)).lower()
    if v in ("on", "true", "1", "yes", "enabled"):
        return True
    if v in ("off", "false", "0", "no", "disabled", ""):
        return False
    return None


def dumps_line(obj):
    return json.dumps(obj, ensure_ascii=True)


def read_text(path):
    with open(path, encoding="utf-8", errors="replace") as fh:
        return fh.read()


def load_json_file(path, sig=True):
    try:
        with open(path, encoding="utf-8-sig" if sig else "utf-8", errors="strict") as fh:
            return json.load(fh)
    except Exception:
        return None


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


def utc_now():
    return datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0)


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(text):
    if not isinstance(text, str):
        return None
    try:
        t = text.strip().replace("Z", "+00:00")
        dt = datetime.datetime.fromisoformat(t)
        if dt.tzinfo is None:
            dt = dt.replace(tzinfo=datetime.timezone.utc)
        return dt
    except ValueError:
        return None


def typed_pairs(items):
    """KEY VALUE pairs -> dict; KEY suffixes :int :num :bool :json :null; none = string."""
    obj = {}
    if len(items) % 2:
        items = list(items) + [""]
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
        elif kind == "num":
            try:
                f = float(val.strip())
                obj[key] = int(f) if f.is_integer() else f
            except ValueError:
                obj[key] = None
        elif kind == "bool":
            obj[key] = cx_bool(val)
        elif kind == "json":
            try:
                obj[key] = json.loads(val)
            except ValueError:
                obj[key] = None
        elif kind == "null":
            obj[key] = None
        else:
            obj[key] = sanitize(val) if key in FREE_TEXT_KEYS else val
    return obj


def cmd_emit(a):
    name = a.name if a.name.startswith("CX_") else "CX_" + a.name
    obj = typed_pairs(a.items)
    out("%s %s\n" % (name, dumps_line(obj)))
    return 0


def cmd_json(a):
    out(dumps_line(typed_pairs(a.items)) + "\n")
    return 0


def cmd_emit_obj(a):
    try:
        text = sys.stdin.read() if a.file == "-" else read_text(a.file)
        obj = json.loads(text)
    except Exception:
        return 1
    name = a.name if a.name.startswith("CX_") else "CX_" + a.name
    out("%s %s\n" % (name, dumps_line(obj)))
    return 0


def cmd_sanitize(a):
    out(sanitize(sys.stdin.read()) + "\n")
    return 0


def first_semver(text):
    m = SEMVER_RE.search(text or "")
    return m.group(0).rstrip(".") if m else None


def cmd_semver(a):
    v = first_semver(a.text)
    if v is None:
        return 1
    out(v + "\n")
    return 0


def _pre_key(pre):
    parts = []
    for p in pre.split("."):
        if p.isdigit():
            parts.append((0, int(p), ""))
        else:
            parts.append((1, 0, p))
    return parts


def vercmp(a, b):
    def split(v):
        v = (v or "").strip()
        m = re.match(r"^v?(\d+(?:\.\d+)*)(?:-([0-9A-Za-z.]+))?", v)
        if not m:
            return [0], None
        return [int(x) for x in m.group(1).split(".")], m.group(2)
    na, pa = split(a)
    nb, pb = split(b)
    n = max(len(na), len(nb))
    na += [0] * (n - len(na))
    nb += [0] * (n - len(nb))
    if na != nb:
        return -1 if na < nb else 1
    if pa == pb:
        return 0
    if pa is None:
        return 1
    if pb is None:
        return -1
    ka, kb = _pre_key(pa), _pre_key(pb)
    if ka == kb:
        return 0
    return -1 if ka < kb else 1


def cmd_vercmp(a):
    out("%d\n" % vercmp(a.a, a.b))
    return 0


def scalar_text(v):
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (dict, list)):
        return json.dumps(v, ensure_ascii=False)
    return str(v)


def dig(obj, dotted):
    for seg in [s for s in dotted.split(".") if s != ""]:
        if isinstance(obj, dict) and seg in obj:
            obj = obj[seg]
        elif isinstance(obj, list) and seg.isdigit() and int(seg) < len(obj):
            obj = obj[int(seg)]
        else:
            raise KeyError(seg)
    return obj


def cmd_json_get(a):
    obj = load_json_file(a.file)
    if obj is None:
        return 1
    try:
        v = dig(obj, a.key)
    except KeyError:
        return 1
    out(scalar_text(v) + "\n")
    return 0


# --------------------------------------------------------------------------- TOML

def _toml_load(path):
    try:
        import tomllib  # Python >= 3.11
    except ImportError:
        return None
    try:
        with open(path, "rb") as fh:
            return tomllib.load(fh)
    except Exception:
        return None


def _toml_scan(path):
    """Line scanner fallback: {section: {key: raw value}} and the list of table headers."""
    tables = {}
    headers = []
    sect = ""
    try:
        text = read_text(path)
    except OSError:
        return None, []
    for line in text.split("\n"):
        s = line.strip().rstrip("\r")
        if not s or s.startswith("#"):
            continue
        m = re.match(r"^\[\[?\s*([^\]]+?)\s*\]\]?\s*(#.*)?$", s)
        if m:
            sect = ".".join(p.strip().strip('"').strip("'") for p in m.group(1).split("."))
            headers.append(sect)
            tables.setdefault(sect, {})
            continue
        m = re.match(r'^("[^"]*"|\'[^\']*\'|[A-Za-z0-9_.-]+)\s*=\s*(.*)$', s)
        if m:
            key = m.group(1).strip('"').strip("'")
            val = m.group(2).strip()
            if val[:1] in ('"', "'"):
                q = val[0]
                end = val.find(q, 1)
                val = val[1:end] if end > 0 else val[1:]
            else:
                val = val.split("#", 1)[0].strip()
            tables.setdefault(sect, {})[key] = val
    return tables, headers


def toml_get(path, section, key):
    data = _toml_load(path)
    if data is not None:
        node = data
        try:
            for seg in [s for s in section.split(".") if s]:
                node = node[seg]
            v = node[key]
        except (KeyError, TypeError):
            return None
        if isinstance(v, bool):
            return "true" if v else "false"
        if isinstance(v, (str, int, float)):
            return str(v)
        return json.dumps(v, default=str)
    tables, _ = _toml_scan(path)
    if not tables:
        return None
    return tables.get(section, {}).get(key)


def cmd_toml_get(a):
    if not os.path.isfile(a.file):
        return 1
    v = toml_get(a.file, a.section, a.key)
    if v is None:
        return 1
    out(v + "\n")
    return 0


def cmd_toml_table(a):
    if not os.path.isfile(a.file):
        return 1
    data = _toml_load(a.file)
    found = False
    if data is not None:
        def walk(node):
            if isinstance(node, dict):
                for k, v in node.items():
                    if k == a.name and isinstance(v, (dict, list)):
                        return True
                    if isinstance(v, dict) and walk(v):
                        return True
                    if isinstance(v, list):
                        for item in v:
                            if isinstance(item, dict) and (item.get("name") == a.name or walk(item)):
                                return True
                    if k == "name" and v == a.name:
                        return True
            return False
        found = walk(data)
    else:
        tables, headers = _toml_scan(a.file)
        found = any(h.split(".")[-1] == a.name for h in headers)
        if not found and tables:
            found = any(t.get("name") == a.name for t in tables.values())
    return 0 if found else 1


def cmd_const(a):
    if a.name in ("D25_HOST_RULES", "D25_WIN_RULES"):
        out(json.dumps(globals()[a.name]) + "\n")
        return 0
    if a.name not in CONSTANTS:
        return 1
    out(CONSTANTS[a.name] + "\n")
    return 0


# --------------------------------------------------------------------------- options

BOOL_WORDS = ("on", "true", "1", "yes", "enabled", "off", "false", "0", "no", "disabled")


def _int_in(v, lo, hi):
    if not re.fullmatch(r"\d{1,6}", v):
        return None
    n = int(v)
    return n if lo <= n <= hi else None


def check_option(name, value, default, home, repo):
    """(valid, effective, note) for one option (DESIGN sections 5.1 and 5.3)."""
    v = (value or "").strip()
    if v == "":
        v = default
    if name in ("policy", "copilot_xhigh_ok"):
        if re.sub(r"\s+", "", v).lower() in BOOL_WORDS:
            return True, v, None
        return False, default, "expected on/off, true/false, 1/0, yes/no, enabled/disabled"
    if name == "exec_host":
        t = v.lower()
        if t in ("auto", "wsl", "local"):
            return True, t, None
        if t == "docker":
            return False, default, "docker arrives in v1.1"
        return False, default, "expected auto, wsl or local"
    if name == "wsl_distro":
        if v.lower() == "auto" or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}", v):
            return True, ("auto" if v.lower() == "auto" else v), None
        return False, default, "expected auto or a distribution name ([A-Za-z0-9._-], at most 64)"
    if name == "docker_compose_file":
        if v == "" or v.startswith("/"):
            return True, v, None
        return False, default, "expected an absolute WSL path"
    if name in ("docker_service", "grok_sandbox_profile"):
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", v):
            return True, v, None
        return False, default, "expected a name ([A-Za-z0-9._-])"
    if name == "opus_lane_order":
        t = re.sub(r"\s+", "", v).lower()
        parts = t.split(",") if t else []
        if not parts or any(p not in ("agy", "copilot", "claude") for p in parts) or len(set(parts)) != len(parts):
            return False, default, "expected a comma list of distinct agy, copilot, claude"
        if "claude" not in parts:
            parts.append("claude")
        eff = ",".join(parts)
        return True, eff, (None if eff == t else "claude appended: %s" % eff)
    if name == "agy_opus_slug_tpl":
        if "{effort}" in v and not re.search(r"\s", v):
            return True, v, None
        return False, default, "must contain {effort}"
    if name == "agy_opus_mode":
        if v.lower() in ("raw", "wrapper"):
            return True, v.lower(), None
        return False, default, "expected raw or wrapper"
    if name in ("copilot_opus_id", "grok_bulk_model", "review_model_gpt"):
        if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]*", v):
            return True, v, None
        return False, default, "expected a model id"
    if name == "grok_bulk_effort":
        if v.lower() in ("low", "medium", "high", "xhigh"):
            return True, v.lower(), None
        return False, default, "expected low, medium, high or xhigh"
    if name == "review_model_gemini":
        if v and not CTRL_RE.search(v):
            return True, v, None
        return False, default, "expected an agy model label"
    ranges = {"cap_agy": (0, 16), "cap_copilot": (0, 16), "cap_grok": (0, 32),
              "copilot_reserve_pct": (0, 90), "agy_claude_floor_pct": (0, 90),
              "copilot_mtd_max_age_days": (1, 31)}
    if name in ranges:
        lo, hi = ranges[name]
        n = _int_in(v, lo, hi)
        if n is None:
            return False, default, "expected an integer %d-%d" % (lo, hi)
        return True, str(n), None
    if name == "worktree_root":
        if not (v.startswith("/") or v == "~" or v.startswith("~/")):
            return False, default, "must be absolute (or start with ~/)"
        p = expand_tilde(v, home).rstrip("/") or "/"
        h = (home or "").rstrip("/") or "/"
        if p == "/":
            return False, default, "must not be /"
        if p == h:
            return False, default, "must not be your home directory itself"
        if repo:
            rp = os.path.realpath(p)
            rr = os.path.realpath(repo)
            if rp == rr or rp.startswith(rr.rstrip("/") + "/"):
                return False, default, "must not be inside the current repository"
        return True, v, None
    if name == "ledger_path":
        if (v.startswith("/") and len(v) > 1) or (v.startswith("~/") and len(v) > 2):
            return True, v, None
        return False, default, "must be absolute (or start with ~/)"
    if name == "default_timeout":
        m = re.fullmatch(r"(\d{1,7})([smh]?)", v)
        if m:
            secs = int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[m.group(2)]
            if secs >= 30:
                return True, v, None
        return False, default, "expected N, Ns, Nm or Nh, at least 30 s"
    return True, v, None


def expand_tilde(p, home):
    home = home if home is not None else os.environ.get("HOME", "")
    if p == "~":
        return home
    if p.startswith("~/"):
        return home.rstrip("/") + "/" + p[2:]
    return p


def conductor_options(path):
    root = load_json_file(path)
    pc = root.get("pluginConfigs") if isinstance(root, dict) else None
    if not isinstance(pc, dict):
        return None
    entry = pc.get(CONDUCTOR_ID)
    if not isinstance(entry, dict):
        entry = pc.get("conductor")
    if not isinstance(entry, dict):
        entry = None
        for key, val in pc.items():
            if isinstance(key, str) and key.startswith("conductor@") and isinstance(val, dict):
                entry = val
                break
    opts = entry.get("options") if isinstance(entry, dict) else None
    return opts if isinstance(opts, dict) else None


def cmd_conductor_options(a):
    merged = {}
    for f in reversed(a.files):
        opts = conductor_options(f)
        if opts:
            merged.update(opts)
    out(json.dumps(merged, ensure_ascii=False) + "\n")
    return 0


def cmd_options_check(a):
    defaults = {}
    order = []
    for item in a.default or []:
        if "=" in item:
            k, v = item.split("=", 1)
            defaults[k] = v
            order.append(k)
    home = a.home if a.home is not None else os.environ.get("HOME", "")
    res = []
    for name in order:
        var = "CLAUDE_PLUGIN_OPTION_" + name.upper()
        raw = os.environ.get(var)
        value = raw if raw not in (None, "") else defaults[name]
        valid, eff, note = check_option(name, value, defaults[name], home, a.repo)
        res.append({"name": name, "value": value, "default": defaults[name], "valid": valid,
                    "effective": eff, "source": "env" if raw not in (None, "") else "default",
                    "note": note})
    known = set(order)
    seen = set()
    for f in a.settings or []:
        opts = conductor_options(f) or {}
        for key, val in opts.items():
            if key in known or key in seen:
                continue
            seen.add(key)
            res.append({"name": key, "value": scalar_text(val), "default": None, "valid": False,
                        "effective": None, "source": f, "note": "unknown option (probable typo)"})
    if not a.tsv:
        out(json.dumps(res, ensure_ascii=False) + "\n")
        return 0
    sec = "Options"
    lines = []
    bad = 0
    for r in res:
        if r["default"] is None:
            bad += 1
            lines.append(rec_line("warn", "D7", sec, "unknown option %s=%s in %s (probable typo)" % (r["name"], r["value"], r["source"])))
        elif not r["valid"]:
            bad += 1
            fix = "printf '%%s' %s | claude plugin configure %s --values-stdin" % (
                shell_quote(json.dumps({r["name"]: r["default"]})), CONDUCTOR_ID)
            lines.append(rec_line("warn", "D7", sec, "option %s='%s' is invalid (%s); using '%s'"
                                  % (r["name"], r["value"], r["note"], r["default"]), fix))
    for r in res:
        if r["default"] is not None and r["valid"] and r["value"] != r["default"]:
            extra = " (%s)" % r["note"] if r["note"] else ""
            lines.append(rec_line("info", "D7", sec, "option %s = %s (default %s)%s" % (r["name"], r["value"], r["default"] or "empty", extra)))
    if not bad:
        lines.insert(0, rec_line("ok", "D7", sec, "options valid (%d set, %d defaults)" % (
            sum(1 for r in res if r["default"] is not None and r["source"] == "env"),
            sum(1 for r in res if r["default"] is not None and r["source"] == "default"))))
    out("".join(lines))
    return 0


def shell_quote(s):
    return "'" + s.replace("'", "'\\''") + "'"


# --------------------------------------------------------------------------- plugins

SIBLINGS = ("ghcp@ghcp-for-claude-code", "antigravity@antigravity-for-claude-code",
            "grok-build@xai-grok-build", CONDUCTOR_ID)


def _pick_id(keys, pid):
    if pid in keys:
        return pid
    name = pid.split("@", 1)[0]
    for k in keys:
        if isinstance(k, str) and (k == name or k.startswith(name + "@")):
            return k
    return None


def plugins_report(config_dir):
    inst_path = os.path.join(config_dir, "plugins", "installed_plugins.json")
    set_path = os.path.join(config_dir, "settings.json")
    inst = load_json_file(inst_path)
    sett = load_json_file(set_path)
    plugs = inst.get("plugins") if isinstance(inst, dict) else None
    plugs = plugs if isinstance(plugs, dict) else {}
    sett = sett if isinstance(sett, dict) else {}
    enabled = sett.get("enabledPlugins") if isinstance(sett.get("enabledPlugins"), dict) else {}
    pconf = sett.get("pluginConfigs") if isinstance(sett.get("pluginConfigs"), dict) else {}
    rep = {"config_dir": config_dir, "installed_file": os.path.isfile(inst_path),
           "settings_file": os.path.isfile(set_path), "plugins": {}}
    for pid in SIBLINGS:
        key = _pick_id(plugs.keys(), pid)
        entries = plugs.get(key) if key else None
        if isinstance(entries, dict):
            entries = [entries]
        entries = [e for e in (entries or []) if isinstance(e, dict)]
        chosen = None
        for e in entries:
            if e.get("scope") == "user":
                chosen = e
                break
        if chosen is None and entries:
            chosen = entries[0]
        ekey = _pick_id(enabled.keys(), pid)
        en = enabled.get(ekey) if ekey else None
        ckey = _pick_id(pconf.keys(), pid)
        conf = pconf.get(ckey) if ckey else None
        opts = conf.get("options") if isinstance(conf, dict) else None
        ip = chosen.get("installPath") if chosen else None
        rep["plugins"][pid] = {
            "id": key or pid,
            "installed": chosen is not None,
            "enabled": en if isinstance(en, bool) else None,
            "version": chosen.get("version") if chosen and isinstance(chosen.get("version"), str) else None,
            "scope": chosen.get("scope") if chosen and isinstance(chosen.get("scope"), str) else None,
            "install_path": ip if isinstance(ip, str) else None,
            "entries": len(entries),
            "options": opts if isinstance(opts, dict) else {},
        }
    perms = sett.get("permissions") if isinstance(sett.get("permissions"), dict) else {}
    rep["permissions"] = {
        "allow": [x for x in perms.get("allow", []) if isinstance(x, str)] if isinstance(perms.get("allow"), list) else [],
        "deny": [x for x in perms.get("deny", []) if isinstance(x, str)] if isinstance(perms.get("deny"), list) else [],
    }
    rep["sandbox"] = sett.get("sandbox") if isinstance(sett.get("sandbox"), dict) else None
    return rep


def cmd_plugins(a):
    out(json.dumps(plugins_report(a.config_dir), ensure_ascii=False) + "\n")
    return 0


# --------------------------------------------------------------------------- models

AGY_STATUS_KEYS = {"error", "errors", "status", "message", "code", "detail", "reason"}


def _agy_slug_like(s):
    """A model slug such as claude-opus-5-5-high or gemini-3.8-flash-high: one token, with a digit."""
    return isinstance(s, str) and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]*", s)) and any(c.isdigit() for c in s)


def parse_models(cli, text):
    ids = []
    authenticated = None
    shape = "none"
    enabled = []
    labels = {}
    if cli == "copilot":
        try:
            obj = json.loads(text)
        except ValueError:
            obj = None
        models = obj.get("models") if isinstance(obj, dict) else None
        if isinstance(models, list):
            shape = "ghcp-models"
            authenticated = True
            for m in models:
                if isinstance(m, dict) and isinstance(m.get("id"), str):
                    ids.append(m["id"])
                    pol = m.get("policy")
                    if isinstance(pol, dict):
                        pol = pol.get("state")
                    if pol == "enabled":
                        enabled.append(m["id"])
        return {"ids": ids, "authenticated": authenticated, "shape": shape, "enabled": enabled}
    if cli == "grok":
        if "You are not authenticated" in text:
            authenticated = False
        lines = [ln.rstrip("\r") for ln in text.split("\n")]
        for ln in lines:
            m = re.match(r"^\s*[*-]\s+(\S+)", ln)
            if m:
                ids.append(m.group(1))
        if ids:
            shape = "bullets"
        else:
            for ln in lines:
                s = ln.strip()
                if re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._:/-]*", s) and any(c.isdigit() for c in s):
                    ids.append(s)
            if ids:
                shape = "bare"
        if authenticated is None and ids:
            authenticated = True
        return {"ids": ids, "authenticated": authenticated, "shape": shape}
    # agy: JSON (several shapes accepted) or "<slug>\t<Label>" lines
    obj = None
    try:
        obj = json.loads(text)
    except ValueError:
        obj = None
    if obj is not None:
        items = obj
        if isinstance(obj, dict):
            for k in ("models", "availableModels", "available_models", "data", "items"):
                if isinstance(obj.get(k), list):
                    items = obj[k]
                    break
            else:
                # A {"<slug>": "<label>"} map, accepted only when every string-valued key looks
                # like a model slug and the object carries no status field: an error or status
                # envelope ({"status": "ERROR", "message": "You are not signed in"}, rc 0) is not
                # a model list.
                keys = [k for k, v in obj.items() if isinstance(v, str)]
                if keys and not (AGY_STATUS_KEYS & {str(k).lower() for k in obj}) and all(_agy_slug_like(k) for k in keys):
                    items = [{"id": k, "label": obj[k]} for k in keys]
                else:
                    items = None
        if isinstance(items, list):
            shape = "json"
            for it in items:
                if isinstance(it, str):
                    ids.append(it)
                elif isinstance(it, dict):
                    for k in ("slug", "id", "model", "name"):
                        if isinstance(it.get(k), str) and it.get(k):
                            ids.append(it[k])
                            lab = it.get("label") or it.get("displayName") or it.get("display_name")
                            if isinstance(lab, str):
                                labels[it[k]] = lab
                            break
    else:
        for ln in text.split("\n"):
            s = ln.rstrip("\r")
            if not s.strip() or s.strip().startswith("Fetching"):
                continue
            parts = s.split("\t")
            slug = parts[0].strip()
            if _agy_slug_like(slug):
                ids.append(slug)
                if len(parts) > 1:
                    labels[slug] = parts[1].strip()
        if ids:
            shape = "text"
    if any(_agy_slug_like(i) for i in ids):
        authenticated = True
    return {"ids": ids, "authenticated": authenticated, "shape": shape, "labels": labels}


def cmd_parse_models(a):
    try:
        text = read_text(a.file)
    except OSError:
        text = ""
    out(json.dumps(parse_models(a.cli, text), ensure_ascii=False) + "\n")
    return 0


# --------------------------------------------------------------------------- host record

LOGIN_CLIS = ("claude", "copilot", "grok", "agy", "gh")


def cmd_tsv_to_json(a):
    obj = {}
    try:
        text = read_text(a.file)
    except OSError:
        text = ""
    for line in text.split("\n"):
        if not line or "\t" not in line:
            continue
        key, val = line.split("\t", 1)
        kind = ""
        if ":" in key:
            key, kind = key.rsplit(":", 1)
        v = typed_pairs([key + (":" + kind if kind else ""), val])[key]
        node = obj
        segs = key.split(".")
        for s in segs[:-1]:
            if not isinstance(node.get(s), dict):
                node[s] = {}
            node = node[s]
        node[segs[-1]] = v
    out(json.dumps(obj, ensure_ascii=False) + "\n")
    return 0


def cmd_host_record(a):
    try:
        desc = json.loads(sys.stdin.read())
    except ValueError:
        err("cxlib: host-record: invalid JSON on stdin\n")
        return 2
    if not isinstance(desc, dict):
        return 2
    path = os.path.join(a.out_dir, a.hostkey + ".json")
    old = load_json_file(path)
    old = old if isinstance(old, dict) else {}
    forwarded = bool(desc.get("forwarded"))
    logins_only = bool(desc.get("logins_only"))
    now = iso(utc_now())
    rec = dict(old)
    rec["version"] = 1
    rec["recorded_at"] = now
    rec["plugin_version"] = VERSION
    rec["hostkey"] = a.hostkey
    if not logins_only:
        for k in ("host", "distro", "home"):
            if k in desc:
                rec[k] = desc[k]
        new_path = desc.get("path")
        if isinstance(new_path, str) and new_path:
            if not forwarded or old.get("path_source") != "interactive" or not old.get("path"):
                rec["path"] = new_path
                rec["path_source"] = "forwarded" if forwarded else "interactive"
        bins = dict(old.get("bin") or {}) if isinstance(old.get("bin"), dict) else {}
        for k, v in (desc.get("bin") or {}).items():
            v = v if isinstance(v, str) and v.startswith("/") else None
            if forwarded and bins.get(k):
                continue
            if forwarded and v is None and k in bins:
                continue
            bins[k] = v
        rec["bin"] = bins
        vers = dict(old.get("versions") or {}) if isinstance(old.get("versions"), dict) else {}
        for k, v in (desc.get("versions") or {}).items():
            if v is not None or k not in vers:
                vers[k] = v
        rec["versions"] = vers
        if not forwarded or "copilot_home" not in old:
            rec["copilot_home"] = desc.get("copilot_home")
        if "copilot_token_env" in desc and (not forwarded or desc.get("copilot_token_env")):
            rec["copilot_token_env"] = desc.get("copilot_token_env")
        rec.setdefault("copilot_token_env", None)
        if isinstance(desc.get("plugins"), dict):
            pl = {}
            for pid, info in desc["plugins"].items():
                if isinstance(info, dict) and info.get("installed", True):
                    pl[pid] = {k: info.get(k) for k in ("version", "enabled", "scope", "install_path")}
            rec["plugins"] = pl
    logins = dict(old.get("logins") or {}) if isinstance(old.get("logins"), dict) else {}
    side = "forwarded" if forwarded else "direct"
    for cli in LOGIN_CLIS:
        cur = dict(logins.get(cli) or {}) if isinstance(logins.get(cli), dict) else {}
        for s in ("direct", "forwarded"):
            cur.setdefault(s, None)
            cur.setdefault(s + "_at", None)
        if cli in (desc.get("logins") or {}):
            v = desc["logins"][cli]
            if v is not None or cur.get(side) is None:
                cur[side] = v if isinstance(v, bool) else None
                cur[side + "_at"] = now
        logins[cli] = cur
    rec["logins"] = logins
    for k in ("bin", "versions"):
        rec.setdefault(k, {})
    rec.setdefault("path", "")
    rec.setdefault("path_source", None)
    rec.setdefault("copilot_home", None)
    rec.setdefault("plugins", {})
    order = ["version", "recorded_at", "plugin_version", "host", "hostkey", "distro", "home", "path",
             "path_source", "bin", "versions", "copilot_home", "copilot_token_env", "logins", "plugins"]
    final = {k: rec[k] for k in order if k in rec}
    for k, v in rec.items():
        final.setdefault(k, v)
    try:
        atomic_write(path, json.dumps(final, indent=1, ensure_ascii=False) + "\n")
        atomic_write(os.path.join(a.out_dir, a.hostkey + ".path"), (final.get("path") or "") + "\n")
    except OSError as e:
        err("cxlib: host-record: %s\n" % e)
        return 2
    out(path + "\n")
    return 0


# --------------------------------------------------------------------------- doctor helpers

def tsv_field(text):
    return re.sub(r"[\t\r\n]", " ", str(text))


def rec_line(status, cid, section, text, *fixes):
    fields = [status, cid, section, tsv_field(text)] + [tsv_field(f) for f in fixes if f]
    return "\t".join(fields) + "\n"


def cmd_agy_grant(a):
    want = "write_file(%s)" % a.path.rstrip("/")
    obj = load_json_file(a.file)
    allow = []
    if isinstance(obj, dict) and isinstance(obj.get("permissions"), dict):
        al = obj["permissions"].get("allow")
        allow = [x for x in al if isinstance(x, str)] if isinstance(al, list) else []
    norm = [re.sub(r"/+\)$", ")", x.strip()) for x in allow]
    if want in norm:
        out("ok\n")
        return 0
    out(json.dumps({"permissions": {"allow": [want]}}) + "\n")
    return 1


GHCP_ID, AGY_ID, GROKB_ID = SIBLINGS[0], SIBLINGS[1], SIBLINGS[2]
# Marketplace sources for D13's install fix (claude plugin install NAME --marketplace SOURCE adds
# the marketplace and installs in one step; measured with claude plugin install --help on 2.1.316).
SIBLING_SOURCES = {GHCP_ID: "40chalk/ghcp-for-claude-code", AGY_ID: "yuting0624/antigravity-for-claude-code"}
GHCP_WRAPPERS = ("ghcp-delegate", "ghcp-job", "ghcp-handoff", "ghcp-ci-debug", "ghcp-models", "ghcp-cloud")
AGY_WRAPPERS = ("agy-delegate", "agy-handoff", "agy-job", "agy-media")
GHCP_PREFIX = ("env -u COPILOT_MODEL -u COPILOT_ALLOW_ALL -u COPILOT_AUTO_TIER -u COPILOT_PROVIDER_BASE_URL "
               "CX_WORKER=1 COPILOT_AUTO_UPDATE=false")
AGY_PREFIX = "env -u GEMINI_API_KEY -u GOOGLE_API_KEY CX_WORKER=1 AGY_CLI_DISABLE_AUTO_UPDATE=true"
SANDBOX_EXCLUDES = ("ghcp-*", "agy-*", "agy", "grok", "gh", "git", "copilot", "cx-*")
AGY_REG_PREFIX = "env -u GEMINI_API_KEY -u GOOGLE_API_KEY AGY_CLI_DISABLE_AUTO_UPDATE=true"
GROK_PREFIX = 'env -u XAI_API_KEY -u GROK_SANDBOX CX_WORKER=1 "${G_ENV[@]}"'
# D25 (U2): allow rules for the Phase 1 command forms exactly as the skill writes them (section
# 12.2), one per leading form of a simple command: the vars.sh line that starts every step, each
# prefixed executor call, the raw agy and grok calls, and the GitHub steps. The suite checks every
# executor and GitHub command in the skill's code blocks against this list. agy-media is not
# here: it always passes --yolo and is not a Phase 1 lane (section 0.3).
D25_HOST_RULES = (
    ["Bash(cx-doctor:*)", "Bash(cx-init:*)", "Bash(cx-wsl:*)"]
    + ["Bash(%s:*)" % n for n in ("ghcp-delegate", "ghcp-job", "ghcp-handoff", "ghcp-ci-debug", "ghcp-models",
                                  "ghcp-cloud", "agy-delegate", "agy-job")]
    + ["Bash(%s %s:*)" % (GHCP_PREFIX, n) for n in ("ghcp-delegate", "ghcp-job", "ghcp-handoff", "ghcp-ci-debug",
                                                    "ghcp-cloud")]
    + ["Bash(%s %s:*)" % (AGY_PREFIX, n) for n in ("agy-delegate", "agy-job")]
    + ["Bash(%s timeout -k 5 60 agy --new-project:*)" % AGY_REG_PREFIX,
       "Bash(%s timeout -k 15s 35m agy:*)" % AGY_PREFIX,
       "Bash(%s grok:*)" % GROK_PREFIX,
       'Bash(. "$HOME/.conductor/out/:*)',
       'Bash(git -C "$WT" push:*)', "Bash(git push:*)", "Bash(gh pr:*)", "Bash(gh repo view:*)"])
# Bash(cx-wsl:*) also covers cx-wsl bash -c/-s, i.e. every command in WSL: D25 says so.
D25_CXWSL_SCOPE = ("scope: Bash(cx-wsl:*) also allows cx-wsl bash -c and -s, i.e. any command in WSL, without a prompt "
                   "(U2 grants spend, pushes, PRs and @copilot reviews, not every shell command); to keep cx-wsl bash "
                   "prompted, allow only the tool forms instead, e.g. Bash(cx-wsl ghcp-job:*), Bash(cx-wsl ghcp-delegate:*), "
                   "Bash(cx-wsl gh pr:*), and approve the shell steps one by one")
D25_WIN_RULES = ["Bash(cx-doctor:*)", "Bash(cx-init:*)", "Bash(cx-wsl:*)"]


def _opt_off(opts, key, default="on"):
    v = opts.get(key, default)
    if isinstance(v, bool):
        return not v
    return cx_bool(v) is False


def _duration_secs(v):
    m = re.fullmatch(r"\s*(\d+)\s*([smh]?)\s*", str(v))
    if not m:
        return None
    return int(m.group(1)) * {"": 1, "s": 1, "m": 60, "h": 3600}[m.group(2)]


def cmd_doctor_siblings(a):
    rep = plugins_report(a.config_dir)
    P = rep["plugins"]
    lines = []
    sec = "Sibling plugins"
    wrappers = {}

    # D13 sibling wrappers, from installed_plugins.json only.
    for pid, names in ((GHCP_ID, GHCP_WRAPPERS), (AGY_ID, AGY_WRAPPERS)):
        info = P[pid]
        short = pid.split("@", 1)[0]
        if not info["installed"]:
            lines.append(rec_line("fail", "D13", sec, "%s plugin is not installed on this host" % short,
                                  "%sclaude plugin install %s --marketplace %s"
                                  % ("in a WSL terminal: " if a.forwarded else "", short, SIBLING_SOURCES[pid])))
            for n in names:
                wrappers[n.replace("-", "_")] = ""
            continue
        ip = info["install_path"] or ""
        missing = []
        for n in names:
            p = os.path.join(ip, "bin", n)
            ok = os.path.isfile(p) and os.access(p, os.X_OK)
            wrappers[n.replace("-", "_")] = os.path.abspath(p) if ok else ""
            if not ok:
                missing.append(n)
        label = "%s %s (%s scope)" % (short, info["version"] or "?", info["scope"] or "?")
        if missing:
            lines.append(rec_line("fail", "D13", sec, "%s: missing or not executable in %s/bin: %s"
                                  % (label, ip, ", ".join(missing)),
                                  "claude plugin update %s" % pid))
        else:
            lines.append(rec_line("ok", "D13", sec, "%s wrappers: %s" % (label, " ".join(names))))
    if a.wrappers_out:
        atomic_write(a.wrappers_out, "".join("%s\t%s\n" % kv for kv in sorted(wrappers.items())))

    # D20 conductor install.
    me = P[CONDUCTOR_ID]
    if me["installed"]:
        if me["enabled"] is False:
            lines.append(rec_line("warn", "D20", sec, "conductor %s is installed but disabled" % (me["version"] or "?"),
                                  "claude plugin enable %s" % CONDUCTOR_ID))
        else:
            lines.append(rec_line("info", "D20", sec, "conductor %s installed (%s scope, %s)"
                                  % (me["version"] or "?", me["scope"] or "?", me["install_path"] or "?")))
    else:
        lines.append(rec_line("info", "D20", sec, "conductor is not installed on this host (running from %s)" % a.root))

    policy_on = a.policy == "on"
    # D21 ghcp overlap.
    g = P[GHCP_ID]
    if g["installed"]:
        o = g["options"]
        if not policy_on:
            lines.append(rec_line("info", "D21", sec, "conductor policy is off; the ghcp policy and nudge are left as configured"))
        elif _opt_off(o, "coding_policy") and _opt_off(o, "delegation_nudge"):
            lines.append(rec_line("ok", "D21", sec, "ghcp coding_policy and delegation_nudge are off (the conductor policy replaces them)"))
        else:
            lines.append(rec_line("warn", "D21", sec, "ghcp coding_policy=%s, delegation_nudge=%s: its policy and nudge compete with the conductor policy"
                                  % (o.get("coding_policy", "on (default)"), o.get("delegation_nudge", "on (default)")),
                                  "printf '%s' '{\"coding_policy\":\"off\",\"delegation_nudge\":\"off\"}' | claude plugin configure ghcp@ghcp-for-claude-code --values-stdin"))
        if str(o.get("usage_log", "")).strip() == "":
            lines.append(rec_line("info", "D21", sec, "ghcp usage_log is empty (Phase 2 passes GHCP_USAGE_LOG per run)"))
    # D22 antigravity overlap.
    ag = P[AGY_ID]
    if ag["installed"]:
        o = ag["options"]
        t = o.get("timeout", "5m")
        secs = _duration_secs(t)
        t_ok = secs is not None and secs >= 1800
        pol_ok = _opt_off(o, "coding_policy") and _opt_off(o, "delegation_nudge")
        if policy_on:
            if pol_ok and t_ok:
                lines.append(rec_line("ok", "D22", sec, "antigravity coding_policy and delegation_nudge are off, timeout %s" % t))
            else:
                lines.append(rec_line("warn", "D22", sec, "antigravity coding_policy=%s, delegation_nudge=%s, timeout=%s (want off, off, at least 30m: a shorter print timeout returns PARTIAL output)"
                                      % (o.get("coding_policy", "on (default)"), o.get("delegation_nudge", "on (default)"), t),
                                      "printf '%s' '{\"coding_policy\":\"off\",\"delegation_nudge\":\"off\",\"timeout\":\"30m\"}' | claude plugin configure antigravity@antigravity-for-claude-code --values-stdin"))
        elif t_ok:
            lines.append(rec_line("ok", "D22", sec, "antigravity timeout %s (conductor policy off: its policy is left as configured)" % t))
        else:
            lines.append(rec_line("warn", "D22", sec, "antigravity timeout=%s: a print timeout under 30m returns PARTIAL output" % t,
                                  "printf '%s' '{\"timeout\":\"30m\"}' | claude plugin configure antigravity@antigravity-for-claude-code --values-stdin"))
    # D23 grok-build bridge.
    gb = P[GROKB_ID]
    if gb["installed"] and gb["enabled"] is not False:
        lines.append(rec_line("warn", "D23", sec, "grok-build: its SessionEnd hook also fires on /clear and kills and erases its session-tagged bridge jobs in the current workspace; the conductor never uses the bridge"))
        lines.append(rec_line("warn", "D23", sec, "grok-build:grok-delegate is a proactive subagent that writes by default without a gate"))
        lines.append(rec_line("info", "D23", sec, "/grok-build:import calls a grok import that grok 1.0.70 lacks"))
    # D24 deny rules (executor host settings).
    deny = rep["permissions"]["deny"]
    for pid, agent in ((AGY_ID, "antigravity:antigravity-delegate"), (GROKB_ID, "grok-build:grok-delegate")):
        if not P[pid]["installed"]:
            continue
        if "Task(%s)" % agent in deny or "Agent(%s)" % agent in deny:
            lines.append(rec_line("ok", "D24", sec, "subagent %s is denied" % agent))
        else:
            lines.append(rec_line("warn", "D24", sec, "subagent %s is not denied (Task(...) rule syntax unverified on 2.1.316)" % agent,
                                  "add to permissions.deny in %s: %s" % (os.path.join(a.config_dir, "settings.json"),
                                                                        json.dumps({"permissions": {"deny": ["Task(%s)" % agent]}}))))
    if P[AGY_ID]["installed"] or P[GROKB_ID]["installed"]:
        lines.append(rec_line("info", "D24", sec, "the same deny rules also refuse those agents as a workflow agent() agentType"))
    # D25 autonomy allow rules and D26 sandbox, from the settings of the host where Claude Code runs.
    if a.forwarded and a.win_settings:
        sfile = a.win_settings
        s = load_json_file(sfile)
        s = s if isinstance(s, dict) else {}
        perms = s.get("permissions") if isinstance(s.get("permissions"), dict) else {}
        allow = [x for x in perms.get("allow", []) if isinstance(x, str)] if isinstance(perms.get("allow"), list) else []
        sandbox = s.get("sandbox") if isinstance(s.get("sandbox"), dict) else None
        want = list(D25_WIN_RULES)
        where = "the Windows-side settings"
    elif a.forwarded:
        sfile, allow, sandbox, want, where = None, [], None, [], None
    else:
        sfile = os.path.join(a.config_dir, "settings.json")
        allow = rep["permissions"]["allow"]
        sandbox = rep["sandbox"]
        want = list(D25_HOST_RULES)
        where = "this host's settings"
    if sfile is None:
        lines.append(rec_line("info", "D25", sec, "Windows-side settings not found: allow rules not checked"))
    else:
        missing = [r for r in want if r not in allow]
        if missing:
            lines.append(rec_line("info", "D25", sec, "%d autonomy allow rule(s) missing in %s (%s); without them Claude Code prompts before each delegation (U2):"
                                  % (len(missing), where, sfile)))
            lines.append(rec_line("info", "D25", sec, json.dumps({"permissions": {"allow": missing}})))
            lines.append(rec_line("info", "D25", sec, "the rules match the skill's commands as written (prefixes and $VAR text included); how 2.1.316 matches env -u prefixes and multi-line steps is unverified; the doctor never writes settings"))
        else:
            lines.append(rec_line("ok", "D25", sec, "autonomy allow rules present in %s" % where))
        if "Bash(cx-wsl:*)" in want:
            lines.append(rec_line("info", "D25", sec, D25_CXWSL_SCOPE))
        if isinstance(sandbox, dict) and sandbox.get("enabled") is True:
            exc = sandbox.get("excludedCommands")
            exc = [x for x in exc if isinstance(x, str)] if isinstance(exc, list) else []
            lack = [x for x in SANDBOX_EXCLUDES if x not in exc]
            if lack:
                lines.append(rec_line("info", "D26", sec, "the Bash sandbox is on and does not exclude %s; executors fail inside it, and worktree setup writes worktree_root (default ~/.cx-wt) and ~/.conductor, which it also blocks:"
                                      % ", ".join(lack)))
                lines.append(rec_line("info", "D26", sec, json.dumps({"sandbox": {"excludedCommands": list(SANDBOX_EXCLUDES)}})))
    out("".join(lines))
    return 0


CX_WSL_KEYS = {"ghcp-delegate": "ghcp_delegate", "ghcp-job": "ghcp_job", "ghcp-handoff": "ghcp_handoff",
               "ghcp-ci-debug": "ghcp_ci_debug", "ghcp-models": "ghcp_models", "agy-delegate": "agy_delegate",
               "ghcp-cloud": "ghcp_cloud", "agy-job": "agy_job", "agy": "agy", "grok": "grok", "gh": "gh",
               "git": "git", "bash": None}


def cmd_wsl_resolve(a):
    """cx-wsl (section 7.7): prints the tool's absolute path, the PATH for it and the recorded
    copilot binary (empty when none), one per line.

    Exit 3 without a host record, 4 when the tool is not recorded or not executable, 1 for a tool
    outside the allowlist. A sibling wrapper that moved is re-resolved once from
    installed_plugins.json (the record is not rewritten: cx-doctor does that)."""
    if a.tool not in CX_WSL_KEYS:
        return 1
    rec = load_json_file(a.record)
    if not isinstance(rec, dict):
        return 3

    mnt = a.mnt_root if a.mnt_root.endswith("/") else a.mnt_root + "/"

    drive = re.compile("(%s|/mnt/)[A-Za-z]/" % re.escape(mnt))

    def runnable(p):
        # Never a Windows-side binary (an npm shim in a drive directory of the automount root,
        # section 7.6), even from an old record. Only <root><letter>/: with [automount] root = /
        # every path starts with the root, and /mnt/data or /mnt/wsl are Linux mounts.
        if not (isinstance(p, str) and p.startswith("/")) or drive.match(p):
            return False
        return os.path.isfile(p) and os.access(p, os.X_OK)

    bins = dict(rec.get("bin")) if isinstance(rec.get("bin"), dict) else {}
    key = CX_WSL_KEYS[a.tool]
    if key is None:
        tool = "/bin/bash"
    else:
        tool = bins.get(key)
        if not runnable(tool) and (key.startswith("ghcp_") or key.startswith("agy_")):
            pid, names = (GHCP_ID, GHCP_WRAPPERS) if key.startswith("ghcp_") else (AGY_ID, AGY_WRAPPERS)
            info = plugins_report(a.config_dir)["plugins"][pid]
            if info["installed"] and info["install_path"]:
                for n in names:
                    cand = os.path.abspath(os.path.join(info["install_path"], "bin", n))
                    if runnable(cand):
                        bins[n.replace("-", "_")] = cand
                tool = bins.get(key)
    if not runnable(tool):
        return 4
    dirs = []
    for prefix in ("ghcp_", "agy_"):
        for k in sorted(bins):
            if k.startswith(prefix) and runnable(bins[k]):
                d = os.path.dirname(bins[k])
                if d not in dirs:
                    dirs.append(d)
    if a.conductor_bin and a.conductor_bin not in dirs:
        dirs.append(a.conductor_bin)
    path = rec.get("path") if isinstance(rec.get("path"), str) else ""
    for d in path.split(":"):
        if d and d.startswith("/") and d not in dirs:
            dirs.append(d)
    cop = bins.get("copilot") if runnable(bins.get("copilot")) else ""
    out(tool + "\n" + ":".join(dirs) + "\n" + cop + "\n")
    return 0


def _walk_nums(node, path=""):
    if isinstance(node, dict):
        for k, v in node.items():
            yield from _walk_nums(v, "%s.%s" % (path, k) if path else str(k))
    elif isinstance(node, list):
        for i, v in enumerate(node):
            yield from _walk_nums(v, "%s.%d" % (path, i))
    elif isinstance(node, (int, float)) and not isinstance(node, bool):
        yield path, node


def cmd_doctor_pools(a):
    sec = "Pools"
    lines = []
    payload = {"agy": {"opus_slugs": [], "usage": None},
               "copilot": {"opus_id_enabled": False, "review_ids": [], "mtd_credits": None, "mtd_age_days": None,
                           "ledger_month_credits": None, "reserve_pct": int(a.reserve_pct)},
               "grok": {"bulk_model_listed": False, "claude_ids": []}}
    # agy
    agy = load_json_file(a.agy_ids, sig=False) if a.agy_ids else None
    agy_ids = agy.get("ids", []) if isinstance(agy, dict) else []
    slugs = [i for i in agy_ids if re.fullmatch(r"claude-opus-5-5-(low|medium|high)", i)]
    payload["agy"]["opus_slugs"] = slugs
    want = a.slug_tpl.replace("{effort}", "high")
    if agy is None:
        lines.append(rec_line("warn", "pools-agy", sec, "agy model list unavailable (see D18)"))
    elif want in agy_ids:
        lines.append(rec_line("ok", "pools-agy", sec, "agy Opus lane %s offered (Opus slugs: %s)" % (want, ", ".join(slugs) or "none")))
    else:
        lines.append(rec_line("fail", "pools-agy", sec, "agy does not offer %s: Opus not offered (Ultra must be billed directly, U1)" % want))
    if a.agy_usage_requested:
        raw = ""
        try:
            raw = read_text(a.agy_usage) if a.agy_usage else ""
        except OSError:
            raw = ""
        usage = None
        try:
            usage = json.loads(raw)
        except ValueError:
            usage = None
        pct = [(p, v) for p, v in _walk_nums(usage) if re.search(r"percent|pct|remaining|used|quota", p, re.I)] if usage is not None else []
        if pct:
            payload["agy"]["usage"] = usage if isinstance(usage, dict) else {"value": usage}
            for p, v in pct[:12]:
                lines.append(rec_line("info", "pools-agy", sec, "agy /usage %s = %s" % (p, v)))
            floor = int(a.floor_pct)
            claude = [v for p, v in pct if re.search(r"claude|gpt|anthropic", p, re.I) and re.search(r"remaining|percent|pct", p, re.I)]
            if floor > 0 and claude and min(claude) < floor:
                lines.append(rec_line("warn", "pools-agy", sec, "agy Claude/GPT bucket at %s%%, below agy_claude_floor_pct=%d" % (min(claude), floor)))
        else:
            first = [ln for ln in raw.split("\n") if ln.strip()][:5]
            if not first:
                lines.append(rec_line("warn", "pools-agy", sec, "agy -p /usage returned nothing (rc %s)" % a.agy_usage_rc))
            for ln in first:
                lines.append(rec_line("info", "pools-agy", sec, "agy /usage: %s" % sanitize(ln)))
    else:
        lines.append(rec_line("info", "pools-agy", sec, "agy bucket percentages: pass --agy-usage (runs agy -p /usage, documented as zero-quota)"))
    # copilot
    cat = None
    if a.copilot_catalog:
        try:
            cat = parse_models("copilot", read_text(a.copilot_catalog))
        except OSError:
            cat = None
    if cat is None or cat.get("shape") != "ghcp-models":
        lines.append(rec_line("warn", "pools-copilot", sec, "Copilot model catalog unavailable (see D16)"))
    else:
        src = "D16 probe" if a.copilot_source == "probe" else "ghcp cache file, %s old" % _age_text(a.catalog_age)
        if a.opus_id in cat["enabled"]:
            payload["copilot"]["opus_id_enabled"] = True
            lines.append(rec_line("ok", "pools-copilot", sec, "Copilot %s is enabled (%s)" % (a.opus_id, src)))
        else:
            lines.append(rec_line("fail", "pools-copilot", sec, "Copilot %s is not enabled for this account (%s)" % (a.opus_id, src)))
        rev = [i for i in ("gpt-6.1-sol", "gpt-6-astra", "gpt-6-luna", "gemini-4-argon") if i in cat["ids"]]
        payload["copilot"]["review_ids"] = rev
        lines.append(rec_line("info", "pools-copilot", sec, "Copilot review and text models listed: %s" % (", ".join(rev) or "none")))
    if not cx_bool(a.xhigh_ok):
        lines.append(rec_line("info", "pools-copilot", sec, "copilot_xhigh_ok=false: xhigh stays off until the #5149 check passes"))
    reserve = int(a.reserve_pct)
    if reserve == 0:
        lines.append(rec_line("info", "pools-copilot", sec, "copilot_reserve_pct=0: no reserve (U3)"))
    mtd = None
    rec = load_json_file(a.pools_file) if a.pools_file else None
    if isinstance(rec, dict) and isinstance(rec.get("copilot_mtd_credits"), (int, float)):
        at = parse_iso(rec.get("copilot_mtd_at"))
        age = (utc_now() - at).total_seconds() / 86400.0 if at else None
        mtd = rec["copilot_mtd_credits"]
        payload["copilot"]["mtd_credits"] = mtd
        payload["copilot"]["mtd_age_days"] = round(age, 2) if age is not None else None
        stale = age is None or age > int(a.mtd_max_age)
        text = "Copilot month-to-date credits %s entered %s ago" % (mtd, _age_text(age * 86400 if age is not None else None))
        if stale and reserve > 0:
            lines.append(rec_line("warn", "pools-copilot", sec, text + " (older than copilot_mtd_max_age_days=%s; the reserve gates dispatch on it)" % a.mtd_max_age,
                                  "cx-doctor --pools --set-copilot-mtd <credits from GitHub's billing page>"))
        else:
            lines.append(rec_line("info", "pools-copilot", sec, text))
    elif reserve > 0:
        lines.append(rec_line("warn", "pools-copilot", sec, "no Copilot month-to-date figure recorded, and copilot_reserve_pct=%d needs one" % reserve,
                              "cx-doctor --pools --set-copilot-mtd <credits from GitHub's billing page>"))
    else:
        lines.append(rec_line("info", "pools-copilot", sec, "no Copilot month-to-date figure recorded (nothing reads it while copilot_reserve_pct=0)"))
    led = _ledger_month(a.ledger)
    payload["copilot"]["ledger_month_credits"] = led
    if led is None:
        lines.append(rec_line("info", "pools-copilot", sec, "no ledger yet (Phase 2 records every executor run)"))
    else:
        lines.append(rec_line("info", "pools-copilot", sec, "ledger: %s Copilot credits this month" % led))
    lines.append(rec_line("info", "pools-copilot", sec, "the ledger is a lower bound: PR reviews (average Lite 25, Balanced 150, Max 1,000 credits) and interactive use bill the same 20,000-credit month"))
    # grok
    grok = load_json_file(a.grok_ids, sig=False) if a.grok_ids else None
    gids = grok.get("ids", []) if isinstance(grok, dict) else []
    if grok is None:
        lines.append(rec_line("warn", "pools-grok", sec, "grok model list unavailable (see D17)"))
    elif a.bulk_model in gids:
        payload["grok"]["bulk_model_listed"] = True
        lines.append(rec_line("ok", "pools-grok", sec, "grok %s listed for mechanical lanes" % a.bulk_model))
    else:
        lines.append(rec_line("warn", "pools-grok", sec, "grok %s not listed (an unlisted -m id silently drops --effort)" % a.bulk_model))
    cl = [i for i in gids if "claude" in i.lower() or "opus" in i.lower()]
    payload["grok"]["claude_ids"] = cl
    if cl:
        lines.append(rec_line("info", "pools-grok", sec, "grok lists Claude ids %s: record one as an Opus lane only after an --effort check; never automatic" % ", ".join(cl)))
    lines.append(rec_line("info", "pools-grok", sec, CURSOR_POOL_MSG))
    lines.append(rec_line("info", "pools-claude", sec, "Claude plan: the conductor's own pool for xhigh/max work, architecture and unplaced tasks"))
    if a.out_json:
        atomic_write(a.out_json, json.dumps(payload, ensure_ascii=True) + "\n")
    out("".join(lines))
    return 0


def _age_text(secs):
    if secs is None:
        return "an unknown time"
    secs = float(secs)
    if secs < 3600:
        return "%d min" % max(0, secs // 60)
    if secs < 172800:
        return "%.1f h" % (secs / 3600)
    return "%.1f days" % (secs / 86400)


def _ledger_month(path):
    if not path or not os.path.isfile(path):
        return None
    month = utc_now().strftime("%Y-%m")
    total = 0.0
    try:
        text = read_text(path)
    except OSError:
        return None
    for line in text.split("\n"):
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict):
            continue
        ts = str(ev.get("ts") or ev.get("started_at") or "")
        pool = str(ev.get("pool") or ev.get("lane") or "")
        cr = ev.get("credits", ev.get("ai_credits"))
        if ts.startswith(month) and "copilot" in pool and isinstance(cr, (int, float)):
            total += cr
    return round(total, 3)


# --------------------------------------------------------------------------- session, Work locally
# readiness and workflows (DESIGN section 8.3 D31, D32)

# The settings keys D32 reads, and the environment variables that override them (section 8.3).
WORKFLOW_KEYS = ("ultracode", "disableWorkflows", "enableWorkflows", "workflowKeywordTriggerEnabled",
                 "workflowSizeGuideline", "disableRemoteControl")
MODEL_ENV = ("CLAUDE_CODE_WORKFLOW_SUBAGENT_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE", "CLAUDE_CODE_SUBAGENT_MODEL",
             "CLAUDE_CODE_SUBAGENT_EFFORT")
# Remote Control (and so Work locally threads) is off while one of these is set (section 8.3 D31).
# Change together with W10 in cx-doctor.sh.
RC_BLOCK_ENV = ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "DISABLE_GROWTHBOOK")
ANTHROPIC_DEFAULT_URL = "https://api.anthropic.com"
MIN_REMOTE_CONTROL = "2.1.280"


def _truthy(v):
    return str(v).strip().lower() in ("1", "true", "yes", "on")


def _falsy(v):
    return str(v).strip().lower() in ("0", "false", "no", "off")


def settings_layers(config_dir, repo, root):
    """The settings files Claude Code merges, highest precedence first: managed (drop-ins, the
    managed file, remote settings), local, project, user. --settings flags are invisible."""
    layers = []
    mdir = os.path.join(root or "/", "etc", "claude-code")
    drop = os.path.join(mdir, "managed-settings.d")
    try:
        names = sorted((n for n in os.listdir(drop) if n.endswith(".json")), reverse=True)
    except OSError:
        names = []
    for n in names:
        layers.append(("managed", os.path.join(drop, n)))
    layers.append(("managed", os.path.join(mdir, "managed-settings.json")))
    layers.append(("managed", os.path.join(config_dir, "remote-settings.json")))
    if repo:
        layers.append(("local", os.path.join(repo, ".claude", "settings.local.json")))
        layers.append(("project", os.path.join(repo, ".claude", "settings.json")))
    layers.append(("user", os.path.join(config_dir, "settings.json")))
    return layers


def claude_settings(config_dir, repo, root):
    """{"files": [...], "effective": {key: {value, layer, file}}, "env": {NAME: {value, layer, file}},
    "workflow_allow": [rules]} over the layers of settings_layers()."""
    eff, env, allow, files = {}, {}, [], []
    for layer, path in settings_layers(config_dir, repo, root):
        if not os.path.isfile(path):
            continue
        d = load_json_file(path)
        files.append({"layer": layer, "file": path, "ok": isinstance(d, dict)})
        if not isinstance(d, dict):
            continue
        for k in WORKFLOW_KEYS:
            if k in d and k not in eff:
                eff[k] = {"value": d[k], "layer": layer, "file": path}
        e = d.get("env")
        if isinstance(e, dict):
            for k, v in e.items():
                if isinstance(k, str) and k not in env and isinstance(v, (str, int, float, bool)):
                    env[k] = {"value": v if isinstance(v, str) else json.dumps(v), "layer": layer, "file": path}
        perms = d.get("permissions")
        if isinstance(perms, dict) and isinstance(perms.get("allow"), list):
            for r in perms["allow"]:
                if isinstance(r, str) and (r == "Workflow" or r.startswith("Workflow(")) and r not in allow:
                    allow.append(r)
    return {"files": files, "effective": eff, "env": env, "workflow_allow": allow}


def cmd_claude_settings(a):
    out(json.dumps(claude_settings(a.config_dir, a.repo, a.root), ensure_ascii=False, indent=1) + "\n")
    return 0


def _where(e):
    return "%s settings, %s" % (e["layer"], e["file"])


def cmd_doctor_session(a):
    """D31 (Work locally readiness) and D32 (workflows and ultracode) as doctor TSV records; all
    info (section 8.3)."""
    sec = "Session"
    env = os.environ
    st = claude_settings(a.config_dir, a.repo, a.root)
    eff = st["effective"]
    lines = []
    # D31: one info line per blocker of Remote Control (Work locally threads), never ! or cross.
    blockers = []
    for v in RC_BLOCK_ENV:
        if env.get(v, "") != "":
            blockers.append("%s is set (environment)" % v)
        elif v in st["env"]:
            blockers.append("%s is set (%s)" % (v, _where(st["env"][v])))
    burl, bsrc = env.get("ANTHROPIC_BASE_URL", ""), "environment"
    if not burl and "ANTHROPIC_BASE_URL" in st["env"]:
        burl, bsrc = st["env"]["ANTHROPIC_BASE_URL"]["value"], _where(st["env"]["ANTHROPIC_BASE_URL"])
    if burl and burl.strip().rstrip("/") != ANTHROPIC_DEFAULT_URL:
        blockers.append("ANTHROPIC_BASE_URL=%s (%s): a gateway, not a claude.ai login" % (burl, bsrc))
    if "disableRemoteControl" in eff and _truthy(eff["disableRemoteControl"]["value"]):
        blockers.append("disableRemoteControl is true (%s)" % _where(eff["disableRemoteControl"]))
    if a.claude_version and vercmp(a.claude_version, MIN_REMOTE_CONTROL) < 0:
        blockers.append("claude %s is older than %s" % (a.claude_version, MIN_REMOTE_CONTROL))
    if env.get("ANTHROPIC_API_KEY", "") != "":
        blockers.append("ANTHROPIC_API_KEY is set: Work locally threads need a claude.ai login, not an API key")
    for b in blockers:
        lines.append(rec_line("info", "D31", sec, "Remote Control, and so Work locally threads on this machine, is off while: " + b))
    if not blockers:
        tail = ""
        if a.host == "wsl":
            tail = "; in WSL, claude remote-control started in the repo folder serves Work locally threads with this WSL install's plugins (unverified until live check L11)"
        lines.append(rec_line("info", "D31", sec, "Work locally prerequisites met here; a thread also needs the desktop app with 'Use this computer from your phone and claude.ai' on (folder added) or claude remote-control running in the folder, and Require trusted devices off" + tail))
    if a.forwarded:
        sys.stdout.write("".join(lines))
        return 0
    # D32 (1) workflows available
    off = None
    if _truthy(env.get("CLAUDE_CODE_DISABLE_WORKFLOWS", "")):
        off = "CLAUDE_CODE_DISABLE_WORKFLOWS is set"
    elif _falsy(env.get("CLAUDE_CODE_WORKFLOWS", "x")):
        off = "CLAUDE_CODE_WORKFLOWS=%s" % env.get("CLAUDE_CODE_WORKFLOWS")
    elif "disableWorkflows" in eff and eff["disableWorkflows"]["value"] is True:
        off = "disableWorkflows in %s" % _where(eff["disableWorkflows"])
    elif "enableWorkflows" in eff and eff["enableWorkflows"]["value"] is False:
        off = "enableWorkflows false in %s" % _where(eff["enableWorkflows"])
    if off:
        lines.append(rec_line("info", "D32", sec, "workflows off (%s): ultracode is unavailable; conductor fan-out uses the main-turn recipe" % off))
    else:
        lines.append(rec_line("info", "D32", sec, "workflows available (not disabled by the environment or the settings files; on Pro they default off: turn on Dynamic workflows in /config)"))
    # (2) ultracode
    u = eff.get("ultracode")
    if u is not None and u["value"] is True:
        if off:
            lines.append(rec_line("info", "D32", sec, "ultracode is set (%s) but workflows are off, so it has no effect" % _where(u)))
        else:
            lines.append(rec_line("info", "D32", sec, "ultracode on for new sessions (%s): workflow agents get the conductor's subagent rules and never run executors (Phase 1)" % _where(u)))
    else:
        lines.append(rec_line("info", "D32", sec, "ultracode not set in the settings files; a session can still turn it on (/effort ultracode, --effort ultracode, --settings, the keyword); the doctor cannot see session toggles"))
    # (3) keyword trigger, (4) size guideline
    k = eff.get("workflowKeywordTriggerEnabled")
    if k is not None and k["value"] is False:
        lines.append(rec_line("info", "D32", sec, "the ultracode keyword trigger is off (%s)" % _where(k)))
    g = eff.get("workflowSizeGuideline")
    if g is not None:
        lines.append(rec_line("info", "D32", sec, "workflow size guideline %s (%s; advisory only)" % (json.dumps(g["value"]), _where(g))))
    # (5) model and effort overrides
    for v in MODEL_ENV:
        if env.get(v, "") != "":
            what = "effort" if v.endswith("EFFORT") else "model"
            lines.append(rec_line("info", "D32", sec, "%s=%s overrides the %s of workflow and subagent stages" % (v, env[v], what)))
    # (6) concurrency per workflow
    mc = env.get("CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS", "").strip()
    if re.fullmatch(r"[0-9]+", mc) and 1 <= int(mc) <= 256:
        lines.append(rec_line("info", "D32", sec, "workflow concurrency %s agents per workflow (CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS)" % int(mc)))
    else:
        try:
            n = int(a.nproc)
        except (TypeError, ValueError):
            n = 0
        if n > 0:
            lines.append(rec_line("info", "D32", sec, "workflow concurrency %d agents per workflow (min(16, max(2, %d CPUs - 2)); CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS overrides it)" % (min(16, max(2, n - 2)), n)))
    if st["workflow_allow"]:
        lines.append(rec_line("info", "D32", sec, "Workflow allow rules: " + ", ".join(st["workflow_allow"])))
    sys.stdout.write("".join(lines))
    return 0


SECTIONS = ["Session", "Host", "Runtime", "Options", "CLIs", "Version pins", "Logins (free probes)",
            "Sibling plugins", "Windows (Git Bash)", "Pools"]
GLYPH = {"ok": "✓", "warn": "!", "fail": "✗"}


def read_checks(path):
    checks = []
    if not path:
        return checks
    try:
        text = read_text(path)
    except OSError:
        return checks
    for line in text.split("\n"):
        if not line.strip():
            continue
        f = line.split("\t")
        if len(f) < 4 or f[0] not in ("ok", "warn", "fail", "info"):
            continue
        checks.append({"id": f[1], "section": f[2], "status": f[0], "text": f[3],
                       "fixes": [x for x in f[4:] if x.strip()]})
    return checks


def _attended(v):
    return int(v) if v in ("0", "1") else None


def cmd_doctor_render(a):
    checks = read_checks(a.checks) + read_checks(a.extra)
    counts = {"ok": 0, "warn": 0, "fail": 0}
    for c in checks:
        if c["status"] in counts:
            counts[c["status"]] += 1
    try:
        host = json.loads(a.host_json) if a.host_json else {}
    except ValueError:
        host = {}
    pools = None
    if a.pools:
        pools = load_json_file(a.pools, sig=False)
    if a.json:
        doc = {"version": 1, "plugin_version": VERSION, "host": host, "caller": a.caller, "session": a.session,
               "attended": _attended(a.attended),
               "checks": [{"id": c["id"], "section": c["section"], "status": c["status"], "text": c["text"],
                           "fix": "\n".join(c["fixes"]) if c["fixes"] else None} for c in checks],
               "pools": pools, "record": a.record or None, "summary": counts}
        out(json.dumps(doc, ensure_ascii=False, indent=1) + "\n")
    else:
        buf = []
        if not a.bare:
            h = host.get("host", "unknown")
            bits = " ".join(x for x in (host.get("distro"), host.get("os_version")) if x)
            if host.get("wsl_version"):
                bits = (bits + ", " if bits else "") + "WSL%s" % host["wsl_version"]
            buf.append("conductor doctor %s: host %s%s, caller %s, session %s\n" % (VERSION, h, " (%s)" % bits if bits else "", a.caller, a.session))
            if a.caller == "gitbash" and h != "gitbash":
                # A forwarded report: its fixes act on WSL, and pasted into Git Bash they would act
                # on the Windows side (~/.profile, claude plugin ..., ~/.gemini).
                buf.append("Fixes run inside WSL, in a WSL terminal (wsl.exe), never in Git Bash; only the Windows section's fixes run on Windows.\n")
        order = SECTIONS + sorted({c["section"] for c in checks if c["section"] not in SECTIONS})
        for sec in order:
            items = [c for c in checks if c["section"] == sec]
            if not items:
                continue
            if not a.bare:
                buf.append("\n%s\n" % sec)
            for c in items:
                if c["status"] == "info":
                    buf.append("      %s [%s]\n" % (c["text"], c["id"]))
                else:
                    buf.append("  %s %s [%s]\n" % (GLYPH[c["status"]], c["text"], c["id"]))
                    for fx in c["fixes"]:
                        buf.append("      fix: %s\n" % fx)
        if not a.bare:
            buf.append("\nSummary: %d ✓, %d !, %d ✗\n" % (counts["ok"], counts["warn"], counts["fail"]))
        out("".join(buf))
    if a.emit_doctor:
        sys.stdout.flush()
        err("CX_DOCTOR %s\n" % dumps_line({"ok": counts["ok"], "warn": counts["warn"], "fail": counts["fail"],
                                            "host": host.get("host", "unknown"), "caller": a.caller,
                                            "session": a.session, "attended": _attended(a.attended),
                                            "record": a.record or None, "pools": bool(a.pools)}))
    return 4 if counts["fail"] else 0


def cmd_pools_mtd(a):
    if a.set is not None:
        try:
            n = float(a.set)
        except ValueError:
            err("cxlib: pools-mtd: not a number: %s\n" % a.set)
            return 1
        if n < 0 or n != n:
            err("cxlib: pools-mtd: must be >= 0\n")
            return 1
        rec = {"version": 1, "copilot_mtd_credits": int(n) if n.is_integer() else n, "copilot_mtd_at": iso(utc_now())}
        try:
            atomic_write(a.file, json.dumps(rec) + "\n")
        except OSError as e:
            err("cxlib: pools-mtd: %s\n" % e)
            return 2
        out(json.dumps(rec) + "\n")
        return 0
    rec = load_json_file(a.file)
    out(json.dumps(rec if isinstance(rec, dict) else {}) + "\n")
    return 0


# --------------------------------------------------------------------------- cx-init

def _exists(repo, *names):
    return any(os.path.exists(os.path.join(repo, n)) for n in names)


def _read(repo, name):
    try:
        return read_text(os.path.join(repo, name))
    except OSError:
        return ""


def _git_tracked(repo, name):
    try:
        r = subprocess.run(["git", "-C", repo, "ls-files", "--error-unmatch", name],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdin=subprocess.DEVNULL)
        return r.returncode == 0
    except OSError:
        return False


def _toml_headers(text):
    return [re.sub(r"\s+", "", m.group(1)) for m in re.finditer(r"(?m)^\s*\[\[?\s*([^\]]+?)\s*\]\]?", text)]


def detect_node(repo, notes):
    pj = os.path.join(repo, "package.json")
    if not os.path.isfile(pj):
        return None
    pkg = load_json_file(pj)
    if not isinstance(pkg, dict):
        notes.append("package.json does not parse as a JSON object: Node not detected")
        return None
    pm = None
    pmf = pkg.get("packageManager") if isinstance(pkg.get("packageManager"), str) else ""
    berry_hint = os.path.exists(os.path.join(repo, ".yarnrc.yml")) or "__metadata:" in _read(repo, "yarn.lock")
    if pmf.startswith("pnpm@"):
        pm = "pnpm"
    elif pmf.startswith("yarn@"):
        m = re.match(r"yarn@(\d+)", pmf)
        if m:
            pm = "yarn-classic" if m.group(1) == "1" else "yarn-berry"
        else:
            pm = "yarn-berry" if berry_hint else "yarn-classic"
    elif pmf.startswith("npm@"):
        pm = "npm"
    elif pmf.startswith("bun@"):
        pm = "bun"
    elif _exists(repo, "pnpm-lock.yaml"):
        pm = "pnpm"
    elif _exists(repo, "yarn.lock"):
        pm = "yarn-berry" if berry_hint else "yarn-classic"
    elif _exists(repo, "bun.lock", "bun.lockb"):
        pm = "bun"
    else:
        pm = "npm"
    if pm == "npm":
        setup = ("npm ci --prefer-offline" if _exists(repo, "package-lock.json", "npm-shrinkwrap.json")
                 else "npm install --no-audit --no-fund --no-package-lock")
    elif pm == "bun":
        setup = None
        notes.append("bun detected: set setup yourself, e.g. `bun install --frozen-lockfile`")
    elif pm == "pnpm":
        setup = "pnpm install --frozen-lockfile --prefer-offline"
    elif pm == "yarn-classic":
        setup = "yarn install --frozen-lockfile"
    else:
        setup = "yarn install --immutable"
    scripts = pkg.get("scripts") if isinstance(pkg.get("scripts"), dict) else {}
    run = {"npm": "npm run ", "pnpm": "pnpm run ", "yarn-classic": "yarn ", "yarn-berry": "yarn ", "bun": "bun run "}[pm]
    test = None
    t = scripts.get("test")
    if isinstance(t, str) and t.strip() and "no test specified" not in t:
        test = {"npm": "npm test", "pnpm": "pnpm test", "yarn-classic": "yarn test", "yarn-berry": "yarn test",
                "bun": "bun run test"}[pm]
    lint = None
    if isinstance(scripts.get("lint"), str):
        lint = {"npm": "npm run lint", "pnpm": "pnpm run lint", "yarn-classic": "yarn lint", "yarn-berry": "yarn lint",
                "bun": "bun run lint"}[pm]
    typecheck = None
    for s in ("typecheck", "type-check", "tsc", "check-types"):
        if isinstance(scripts.get(s), str):
            typecheck = run + s
            break
    if typecheck is None and os.path.isfile(os.path.join(repo, "tsconfig.json")):
        deps = {}
        for k in ("dependencies", "devDependencies"):
            if isinstance(pkg.get(k), dict):
                deps.update(pkg[k])
        if "typescript" in deps:
            typecheck = {"npm": "npx tsc --noEmit", "pnpm": "pnpm exec tsc --noEmit", "yarn-classic": "yarn tsc --noEmit",
                         "yarn-berry": "yarn tsc --noEmit", "bun": "bunx tsc --noEmit"}[pm]
    return {"pm": pm, "setup": setup, "test": test, "lint": lint, "typecheck": typecheck}


def detect_python(repo, notes):
    reqs = [n for n in sorted(os.listdir(repo)) if re.fullmatch(r"requirements.*\.txt", n)] if os.path.isdir(repo) else []
    if not (_exists(repo, "pyproject.toml", "setup.cfg", "setup.py") or reqs):
        return None
    if _exists(repo, "uv.lock"):
        runner, setup = "uv run ", "uv sync --frozen"
    elif _exists(repo, "poetry.lock"):
        runner, setup = "poetry run ", "poetry install --no-interaction"
    else:
        runner, setup = "python3 -m ", None
        notes.append("Python detected without uv.lock or poetry.lock: set setup yourself "
                     "(pip into a system Python is refused on PEP 668 distros)")
    pyproject = _read(repo, "pyproject.toml")
    headers = _toml_headers(pyproject)
    data = _toml_load(os.path.join(repo, "pyproject.toml")) if pyproject else None
    dep_text = ""
    if data is not None:
        proj = data.get("project") if isinstance(data.get("project"), dict) else {}
        bits = [proj.get("dependencies"), proj.get("optional-dependencies"), data.get("dependency-groups")]
        poetry = (data.get("tool") or {}).get("poetry") if isinstance(data.get("tool"), dict) else None
        if isinstance(poetry, dict):
            bits += [poetry.get("dependencies"), poetry.get("dev-dependencies"), poetry.get("group")]
        dep_text = json.dumps(bits, default=str)
    else:
        dep_text = pyproject

    def has_table(name):
        if data is not None:
            node = data
            for seg in name.split("."):
                if not isinstance(node, dict) or seg not in node:
                    return False
                node = node[seg]
            return True
        return any(h == name or h.startswith(name + ".") for h in headers)

    setup_cfg = _read(repo, "setup.cfg")
    tox = _read(repo, "tox.ini")
    req_text = "".join(_read(repo, n) for n in reqs)
    tests_dir = os.path.join(repo, "tests")
    test_files = os.path.isdir(tests_dir) and any(re.fullmatch(r"test_.*\.py", n) for n in os.listdir(tests_dir))
    pytest = (has_table("tool.pytest.ini_options") or _exists(repo, "pytest.ini", "conftest.py")
              or re.search(r"(?m)^\s*\[tool:pytest\]", setup_cfg) or re.search(r"(?m)^\s*\[pytest\]", tox)
              or re.search(r"(?i)\bpytest\b", req_text) or re.search(r"(?i)\bpytest\b", dep_text) or test_files)
    ruff = has_table("tool.ruff") or _exists(repo, "ruff.toml", ".ruff.toml")
    mypy = (has_table("tool.mypy") or _exists(repo, "mypy.ini", ".mypy.ini")
            or re.search(r"(?m)^\s*\[mypy\]", setup_cfg))
    return {"setup": setup, "test": runner + "pytest -q" if pytest else None,
            "lint": runner + "ruff check ." if ruff else None,
            "typecheck": runner + "mypy ." if mypy else None}


def detect_go(repo, notes):
    if not _exists(repo, "go.mod"):
        return None
    golangci = _exists(repo, ".golangci.yml", ".golangci.yaml", ".golangci.toml", ".golangci.json")
    return {"setup": "go mod download", "test": "go test ./...",
            "lint": "golangci-lint run" if golangci else "go vet ./...", "typecheck": None}


def detect_rust(repo, notes):
    if not _exists(repo, "Cargo.toml"):
        return None
    if _git_tracked(repo, "Cargo.lock"):
        setup = "cargo fetch --locked"
    else:
        setup = None
        notes.append("Cargo.lock is not tracked: cargo creates it in every worktree; commit it or keep it in .gitignore")
    return {"setup": setup, "test": "cargo test --quiet",
            "lint": "cargo clippy --all-targets --quiet -- -D warnings",
            "typecheck": "cargo check --all-targets --quiet"}


def init_detect(repo):
    notes = []
    res = {"ecosystems": [], "package_manager": None, "setup": None, "test": None, "lint": None,
           "typecheck": None, "notes": notes}
    found = []
    for name, fn in (("node", detect_node), ("python", detect_python), ("go", detect_go), ("rust", detect_rust)):
        try:
            r = fn(repo, notes)
        except OSError:
            r = None
        if r is not None:
            found.append((name, r))
    res["ecosystems"] = [n for n, _ in found]
    for n, r in found:
        if n == "node":
            res["package_manager"] = r["pm"]
    for slot in ("setup", "test", "lint", "typecheck"):
        cmds = [r[slot] for _, r in found if r.get(slot)]
        res[slot] = " && ".join(cmds) if cmds else None
    if len(found) > 1:
        notes.append("several ecosystems detected (%s): each command joins them with &&" % ", ".join(res["ecosystems"]))
    make = _read(repo, "Makefile") or _read(repo, "makefile") or _read(repo, "GNUmakefile")
    if res["test"] is None:
        if os.path.isfile(os.path.join(repo, "tests", "run-tests.sh")):
            res["test"] = "bash tests/run-tests.sh"
        elif re.search(r"(?m)^test:", make):
            res["test"] = "make test"
    if res["lint"] is None and re.search(r"(?m)^lint:", make):
        res["lint"] = "make lint"
    return res


def cmd_init_detect(a):
    out(json.dumps(init_detect(a.dir), ensure_ascii=False) + "\n")
    return 0


def cmd_init_plan(a):
    det = init_detect(a.repo)
    notes = list(det["notes"])
    for slot in ("setup", "test", "lint", "typecheck"):
        v = getattr(a, slot)
        if v is not None:
            det[slot] = v if v != "" else None
    for slot in ("setup", "test", "lint", "typecheck"):
        if det[slot] is None:
            notes.append("nothing detected for %s (set it with --%s or in .cx/routes.json)" % (slot, slot))
    if not os.path.exists(os.path.join(a.repo, ".gitattributes")):
        notes.append("no .gitattributes at the repo root: touched from Windows and WSL? add `* text=auto eol=lf`")
    if (a.autocrlf or "").strip().lower() == "true":
        notes.append("core.autocrlf=true: files written on Windows get CRLF; prefer `* text=auto eol=lf` in .gitattributes")
    if a.subdir:
        notes.append("using the repository root %s" % a.repo)
    det["notes"] = notes
    plan = {"repo": a.repo, "detected": det, "only": a.only or [], "exclude_file": a.exclude_file,
            "notes": notes}
    out(json.dumps(plan, ensure_ascii=False) + "\n")
    return 0


BEGIN_PREFIX = "<!-- cx:begin conductor bundle"
END_LINE = "<!-- cx:end -->"
FILES = (("agents", "AGENTS.md", "AGENTS.md"), ("routes", ".cx/routes.json", "routes.json"),
         ("copilot", ".github/copilot-instructions.md", "copilot-instructions.md"))


def code_span(cmd):
    if cmd is None:
        return "(none detected; set it in .cx/routes.json)"
    runs = [len(m.group(0)) for m in re.finditer(r"`+", cmd)]
    fence = "`" * ((max(runs) if runs else 0) + 1)
    pad = " " if cmd.startswith("`") or cmd.endswith("`") else ""
    return fence + pad + cmd + pad + fence


def render_block(template, det):
    text = template
    for slot in ("setup", "test", "lint", "typecheck"):
        text = text.replace("{{%s}}" % slot, code_span(det.get(slot)))
    return text.rstrip("\n")


def find_block(text):
    parts = text.split("\n")
    i = next((k for k, p in enumerate(parts) if p.rstrip("\r").startswith(BEGIN_PREFIX)), None)
    if i is None:
        return None
    j = next((k for k in range(i + 1, len(parts)) if parts[k].rstrip("\r").strip() == END_LINE), None)
    return (parts, i, j)


def path_hazard(repo, rel):
    """A reason why cx-init must not write REL under REPO, or None. Every component between the
    repo root and the file must be a real directory (not a symlink, not a file), so that a
    committed `.cx` or `.github` symlink can never redirect a write outside the repository, and
    a non-directory `.cx` is a conflict before anything at all is written (section 9.2)."""
    cur = repo
    parts = [x for x in rel.split("/") if x][:-1]
    for i, comp in enumerate(parts):
        cur = os.path.join(cur, comp)
        shown = "/".join(parts[:i + 1])
        if os.path.islink(cur):
            return "%s is a symlink; cx-init does not write through symlinks" % shown
        if os.path.lexists(cur) and not os.path.isdir(cur):
            return "%s exists and is not a directory" % shown
        if not os.path.lexists(cur):
            break
    base = os.path.realpath(repo)
    anc = os.path.dirname(os.path.join(repo, rel))
    while not os.path.lexists(anc) and anc != os.path.dirname(anc):
        anc = os.path.dirname(anc)
    real = os.path.realpath(anc)
    if real != base and not real.startswith(base.rstrip("/") + "/"):
        return "resolves outside the repository (%s)" % real
    return None


def write_nofollow(repo, rel, data):
    """Creates the missing directories of REL one by one and writes DATA, never following a
    symlink (each directory is checked again just before use; O_NOFOLLOW on the file)."""
    cur = repo
    for comp in [x for x in rel.split("/") if x][:-1]:
        cur = os.path.join(cur, comp)
        if os.path.islink(cur):
            raise OSError("%s is a symlink" % cur)
        if not os.path.lexists(cur):
            os.mkdir(cur)
        elif not os.path.isdir(cur):
            raise OSError("%s is not a directory" % cur)
    fd = os.open(os.path.join(repo, rel), os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o666)
    with os.fdopen(fd, "wb") as fh:
        fh.write(data)


def classify_block_file(path, block, force):
    """-> (action, reason, new_bytes or None)."""
    if os.path.islink(path):
        return "conflict", "is a symlink; cx-init does not write through symlinks", None, False
    if os.path.exists(path) and not os.path.isfile(path):
        return "conflict", "not a regular file", None, False
    if not os.path.exists(path):
        return "create", None, (block + "\n").encode("utf-8"), True
    with open(path, "rb") as fh:
        raw = fh.read()
    text = raw.decode("utf-8", "surrogateescape")
    fb = find_block(text)
    if fb is None:
        if text == "":
            new = block + "\n"
        else:
            new = text + ("" if text.endswith("\n") else "\n") + "\n" + block + "\n"
        return "update", "append the conductor block", new.encode("utf-8", "surrogateescape"), True
    parts, i, j = fb
    if j is None:
        return "conflict", "cx:begin without cx:end; fix the markers by hand", None, False
    cur = "\n".join(p.rstrip("\r") for p in parts[i:j + 1])
    if cur == block:
        return "same", None, None, True
    if not force:
        return "conflict", "the conductor block differs; --force to replace the block", None, True
    new = "\n".join(parts[:i] + block.split("\n") + parts[j + 1:])
    return "update", "replace the conductor block", new.encode("utf-8", "surrogateescape"), True


def classify_routes(path, rendered_obj, force):
    text = json.dumps(rendered_obj, indent=2) + "\n"
    if os.path.islink(path):
        return "conflict", "is a symlink; cx-init does not write through symlinks", None, False
    if os.path.exists(path) and not os.path.isfile(path):
        return "conflict", "not a regular file", None, False
    if not os.path.exists(path):
        return "create", None, text.encode("utf-8"), True
    cur = load_json_file(path)
    if cur is not None and cur == rendered_obj:
        return "same", None, None, True
    why = "not valid JSON" if cur is None else "differs from the generated file"
    if not force:
        return "conflict", why + "; --force to overwrite", None, True
    return "update", "overwrite", text.encode("utf-8"), True


def cmd_init_apply(a):
    try:
        plan = json.loads(a.plan) if not a.plan.startswith("@") else json.loads(read_text(a.plan[1:]))
    except (ValueError, OSError):
        err("cxlib: init-apply: invalid --plan\n")
        return 2
    repo = a.dir
    det = plan.get("detected") or {}
    only = set(plan.get("only") or [])
    notes = plan.get("notes") or []
    results = []
    writes = []
    conflict = False
    for key, rel, tpl in FILES:
        path = os.path.join(repo, rel)
        if only and key not in only:
            results.append({"path": rel, "action": "skipped", "reason": None})
            continue
        tpath = os.path.join(a.templates, tpl)
        hazard = path_hazard(repo, rel)
        if hazard:
            conflict = True
            results.append({"path": rel, "action": "conflict", "reason": hazard})
            continue
        try:
            if key == "routes":
                obj = load_json_file(tpath)
                if not isinstance(obj, dict):
                    raise ValueError("template routes.json does not parse")
                obj["setup"] = det.get("setup")
                cmds = obj.get("commands") if isinstance(obj.get("commands"), dict) else {}
                cmds = dict(cmds)
                for s in ("test", "lint", "typecheck"):
                    cmds[s] = det.get(s)
                obj["commands"] = cmds
                action, reason, data, _ = classify_routes(path, obj, a.force)
            else:
                block = render_block(read_text(tpath), det)
                action, reason, data, _ = classify_block_file(path, block, a.force)
        except (OSError, ValueError) as e:
            err("cxlib: init-apply: template %s: %s\n" % (tpath, e))
            return 2
        if action == "conflict":
            conflict = True
        results.append({"path": rel, "action": action, "reason": reason})
        if data is not None:
            writes.append((rel, data))
    exclude = plan.get("exclude_file")
    excluded = False
    ex_lines = []
    if exclude and os.path.isfile(exclude):
        ex_lines = [ln.strip() for ln in read_text(exclude).split("\n")]
        excluded = "/.conductor/" in ex_lines
    written = []
    if not conflict and not a.dry_run:
        for rel, data in writes:
            try:
                write_nofollow(repo, rel, data)
            except OSError as e:
                err("cxlib: init-apply: cannot write %s: %s\n" % (os.path.join(repo, rel), e))
                return 2
        if exclude and not excluded:
            try:
                os.makedirs(os.path.dirname(exclude), exist_ok=True)
                cur = ""
                if os.path.isfile(exclude):
                    with open(exclude, "rb") as fh:
                        cur = fh.read().decode("utf-8", "surrogateescape")
                with open(exclude, "ab") as fh:
                    if cur and not cur.endswith("\n"):
                        fh.write(b"\n")
                    fh.write(b"/.conductor/\n")
                excluded = True
            except OSError as e:
                err("cxlib: init-apply: cannot update %s: %s\n" % (exclude, e))
                return 2
    if not conflict:
        written = [r["path"] for r in results if r["action"] in ("create", "update")]
    unchanged = [r["path"] for r in results if r["action"] == "same"]
    conflicts = [r["path"] for r in results if r["action"] == "conflict"]
    detected = {k: det.get(k) for k in ("ecosystems", "package_manager", "setup", "test", "lint", "typecheck", "notes")}
    if a.json:
        out(json.dumps({"repo": repo, "dry_run": bool(a.dry_run), "files": results, "excluded": excluded,
                        "detected": detected, "notes": notes}, ensure_ascii=False, indent=1) + "\n")
    else:
        buf = []
        for r in results:
            act = r["action"]
            if act == "conflict":
                buf.append("CONFLICT %s (%s)\n" % (r["path"], r["reason"]))
            elif act == "update":
                buf.append("update   %s (%s)\n" % (r["path"], r["reason"]))
            else:
                buf.append("%-8s %s\n" % (act, r["path"]))
        for slot in ("setup", "test", "lint", "typecheck"):
            v = det.get(slot)
            buf.append("detected: %s = %s\n" % (slot, v if v is not None else "(none)"))
        out("".join(buf))
        sys.stdout.flush()
        for n in notes:
            err("cx-init: %s\n" % sanitize(n, 400))
    sys.stdout.flush()
    err("CX_INIT %s\n" % dumps_line({"repo": repo, "dry_run": bool(a.dry_run), "written": written,
                                     "unchanged": unchanged, "conflicts": conflicts, "excluded": excluded,
                                     "detected": detected}))
    return 5 if conflict else 0


# --------------------------------------------------------------------------- main

def main(argv):
    p = argparse.ArgumentParser(prog="cxlib.py", description="conductor helpers")
    sub = p.add_subparsers(dest="cmd")

    s = sub.add_parser("emit")
    s.add_argument("name")
    s.add_argument("items", nargs=argparse.REMAINDER)
    s.set_defaults(fn=cmd_emit)
    s = sub.add_parser("json")
    s.add_argument("items", nargs=argparse.REMAINDER)
    s.set_defaults(fn=cmd_json)
    s = sub.add_parser("emit-obj")
    s.add_argument("name")
    s.add_argument("file")
    s.set_defaults(fn=cmd_emit_obj)
    s = sub.add_parser("sanitize")
    s.set_defaults(fn=cmd_sanitize)
    s = sub.add_parser("semver")
    s.add_argument("text")
    s.set_defaults(fn=cmd_semver)
    s = sub.add_parser("vercmp")
    s.add_argument("a")
    s.add_argument("b")
    s.set_defaults(fn=cmd_vercmp)
    s = sub.add_parser("json-get")
    s.add_argument("file")
    s.add_argument("key")
    s.set_defaults(fn=cmd_json_get)
    s = sub.add_parser("toml-get")
    s.add_argument("file")
    s.add_argument("section")
    s.add_argument("key")
    s.set_defaults(fn=cmd_toml_get)
    s = sub.add_parser("toml-table")
    s.add_argument("file")
    s.add_argument("name")
    s.set_defaults(fn=cmd_toml_table)
    s = sub.add_parser("const")
    s.add_argument("name")
    s.set_defaults(fn=cmd_const)
    s = sub.add_parser("options-check")
    s.add_argument("--default", action="append")
    s.add_argument("--settings", action="append")
    s.add_argument("--repo")
    s.add_argument("--home")
    s.add_argument("--tsv", action="store_true")
    s.set_defaults(fn=cmd_options_check)
    s = sub.add_parser("conductor-options")
    s.add_argument("files", nargs="+")
    s.set_defaults(fn=cmd_conductor_options)
    s = sub.add_parser("plugins")
    s.add_argument("--config-dir", required=True)
    s.set_defaults(fn=cmd_plugins)
    s = sub.add_parser("parse-models")
    s.add_argument("--cli", required=True, choices=["copilot", "grok", "agy"])
    s.add_argument("file")
    s.set_defaults(fn=cmd_parse_models)
    s = sub.add_parser("host-record")
    s.add_argument("--out-dir", required=True)
    s.add_argument("--hostkey", required=True)
    s.set_defaults(fn=cmd_host_record)
    s = sub.add_parser("tsv-to-json")
    s.add_argument("file")
    s.set_defaults(fn=cmd_tsv_to_json)
    s = sub.add_parser("agy-grant")
    s.add_argument("file")
    s.add_argument("path")
    s.set_defaults(fn=cmd_agy_grant)
    s = sub.add_parser("doctor-siblings")
    s.add_argument("--config-dir", required=True)
    s.add_argument("--policy", default="on")
    s.add_argument("--forwarded", type=int, default=0)
    s.add_argument("--win-settings", default="")
    s.add_argument("--wrappers-out")
    s.add_argument("--root", default="")
    s.set_defaults(fn=cmd_doctor_siblings)
    s = sub.add_parser("wsl-resolve")
    s.add_argument("--record", required=True)
    s.add_argument("--tool", required=True)
    s.add_argument("--config-dir", required=True)
    s.add_argument("--conductor-bin", default="")
    s.add_argument("--mnt-root", default="/mnt/")
    s.set_defaults(fn=cmd_wsl_resolve)
    s = sub.add_parser("doctor-pools")
    for opt in ("--agy-ids", "--copilot-catalog", "--catalog-age", "--grok-ids", "--agy-usage", "--pools-file",
                "--ledger", "--out-json"):
        s.add_argument(opt)
    s.add_argument("--copilot-source", default="probe")
    s.add_argument("--agy-usage-rc", default="")
    s.add_argument("--agy-usage-requested", type=int, default=0)
    s.add_argument("--slug-tpl", default="claude-opus-5-5-{effort}")
    s.add_argument("--opus-id", default="claude-opus-5.5")
    s.add_argument("--xhigh-ok", default="false")
    s.add_argument("--reserve-pct", default="0")
    s.add_argument("--mtd-max-age", default="3")
    s.add_argument("--floor-pct", default="0")
    s.add_argument("--bulk-model", default="grok-4.7")
    s.set_defaults(fn=cmd_doctor_pools)
    s = sub.add_parser("claude-settings")
    s.add_argument("--config-dir", required=True)
    s.add_argument("--repo", default="")
    s.add_argument("--root", default="")
    s.set_defaults(fn=cmd_claude_settings)
    s = sub.add_parser("doctor-session")
    s.add_argument("--config-dir", required=True)
    s.add_argument("--repo", default="")
    s.add_argument("--root", default="")
    s.add_argument("--claude-version", default="")
    s.add_argument("--nproc", default="")
    s.add_argument("--host", default="")
    s.add_argument("--forwarded", type=int, default=0)
    s.set_defaults(fn=cmd_doctor_session)
    s = sub.add_parser("doctor-render")
    s.add_argument("--checks", required=True)
    s.add_argument("--extra")
    s.add_argument("--json", action="store_true")
    s.add_argument("--pools")
    s.add_argument("--host-json", default="")
    s.add_argument("--caller", default="local")
    s.add_argument("--record", default="")
    s.add_argument("--bare", action="store_true")
    s.add_argument("--emit-doctor", action="store_true")
    s.add_argument("--session", default="local")
    s.add_argument("--attended", default="")
    s.set_defaults(fn=cmd_doctor_render)
    s = sub.add_parser("init-detect")
    s.add_argument("dir")
    s.set_defaults(fn=cmd_init_detect)
    s = sub.add_parser("init-plan")
    s.add_argument("--repo", required=True)
    for slot in ("--setup", "--test", "--lint", "--typecheck"):
        s.add_argument(slot)
    s.add_argument("--only", action="append", choices=["agents", "routes", "copilot"])
    s.add_argument("--exclude-file", default="")
    s.add_argument("--autocrlf", default="")
    s.add_argument("--subdir", action="store_true")
    s.set_defaults(fn=cmd_init_plan)
    s = sub.add_parser("init-apply")
    s.add_argument("--dir", required=True)
    s.add_argument("--templates", required=True)
    s.add_argument("--plan", required=True)
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--force", action="store_true")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_init_apply)
    s = sub.add_parser("pools-mtd")
    s.add_argument("--file", required=True)
    s.add_argument("--set")
    s.set_defaults(fn=cmd_pools_mtd)

    a = p.parse_args(argv)
    if not getattr(a, "fn", None):
        p.print_help(sys.stderr)
        return 1
    return a.fn(a)


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except BrokenPipeError:
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
