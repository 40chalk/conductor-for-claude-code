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
  landlock                     "abi N", "none <why>" or "unknown <why>": the kernel's Landlock (D17)
  grok-sandbox-event --file F --from N --to M --workspace W [--grok-home H]
                               "enforced|unenforced|none<TAB>platform<TAB>profile": grok's sandbox
                               log lines appended between sizes N and M for workspace W (D17); with
                               --grok-home a fourth field, the first read_write path of those
                               events that grants write to H (grok_home_write), else "-"
  const NAME                   prints a message constant (CURSOR_WORKER_MSG, CURSOR_POOL_MSG)
  options-check                effective options (CLAUDE_PLUGIN_OPTION_*) validated (section 5.3)
  conductor-options FILE       the conductor's saved options in FILE as JSON
  plugins --config-dir DIR     sibling-plugin report (section 8.3)
  parse-models --cli C FILE    model ids per CLI (section 8.3 D16-D18)
  host-record                  writes the host record (section 7.6)
  tsv-to-json FILE             dotted TSV facts -> one JSON object
  agy-grant FILE PATH          checks the agy write_file grant (D18)
  wsl-resolve ...              cx-wsl: a tool's absolute path, PATH and copilot from the host record (7.7)
  record-env ...               the host record as CXR_* shell assignments for the adapters (15.2)
  doctor-siblings ...          D13, D20-D26 as doctor TSV records
  doctor-pools ...             section 8.4 as doctor TSV records plus the CX_POOLS payload
  claude-settings ...          the Claude Code settings layers D31/D32 read, as JSON (section 8.3)
  doctor-session ...           D31 and D32 as doctor TSV records (section 8.3)
  doctor-render ...            renders the doctor report (sections 8.2, 8.7); exit 0 or 4
  init-detect DIR              detection JSON (section 9.3)
  init-plan ...                detection plus cx-init's overrides -> plan JSON
  init-apply ...               bundle writer (section 9.2); exit 0 or 5
  user-grants ...              cx-init --user-grants (section 15.7): the repository's grok
                               sandbox profile (and a note on agy's 0.2.0 global grants); exit 0 or 5
  grok-profile ...             the repository's grok sandbox profile, or conductor's cx-strict
                               (--strict), with the resolver directories, under a lock (section 15.7)
  grok-resolver ...            D17's resolver and TLS records (section 8.3)
  agy-grants FILE              the global write_file/command grants of agy's settings (D18 info)
  pools-mtd --file F [--set N] reads or writes the month-to-date record (section 8.4)
"""

import argparse
import datetime
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

VERSION = "0.2.2"

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


def landlock_abi():
    """("abi", N) when the kernel offers Landlock (landlock_create_ruleset's version query),
    ("none", why) when it definitely does not (ENOSYS: not built in; EOPNOTSUPP: disabled), else
    ("unknown", why) (not Linux, no ctypes, or a seccomp filter answering EPERM)."""
    import errno
    if not sys.platform.startswith("linux"):
        return "unknown", "not Linux"
    try:
        import ctypes
        libc = ctypes.CDLL(None, use_errno=True)
        # landlock_create_ruleset(NULL, 0, LANDLOCK_CREATE_RULESET_VERSION): syscall 444 on every
        # architecture (it was added after the syscall numbers were unified).
        r = libc.syscall(444, None, ctypes.c_size_t(0), ctypes.c_uint32(1))
        e = ctypes.get_errno()
    except (OSError, AttributeError, ImportError) as x:
        return "unknown", "cannot query (%s)" % x
    if r >= 1:
        return "abi", str(r)
    if e == errno.ENOSYS:
        return "none", "ENOSYS: the kernel has no Landlock"
    if e == errno.EOPNOTSUPP:
        return "none", "EOPNOTSUPP: Landlock is disabled at boot"
    return "unknown", "cannot query (%s)" % (errno.errorcode.get(e, e))


def cmd_landlock(a):
    """landlock: prints "abi N", "none <why>" or "unknown <why>" (DESIGN section 8.3 D17)."""
    k, v = landlock_abi()
    out("%s %s\n" % (k, v))
    return 0


GROK_EVENTS_MAX = 1 << 20


def grok_sandbox_events(path, start, end, workspace):
    """grok's sandbox log (1.0.70, measured 2026-11-06: ~/.grok/sessions/sandbox-events.jsonl
    gets one JSON line per sandboxed start, {"timestamp", "event_type": "ProfileApplied",
    "profile", "workspace", "platform", "enforced", "restrict_network", "read_write_paths"},
    plus "read_only_paths" for strict and the profiles extending it (the built-in read-only
    logs none); tests/fixtures/real/grok/sandbox-events-1.0.70.jsonl). Reads only bytes
    [START, END) of PATH, what grok appended while one probe ran ([0, END) when the file shrank
    meanwhile; at most 1 MiB), never when PATH itself is a symlink (O_NOFOLLOW: its last path
    component only; a symlinked directory above it is followed) and never blocking on a FIFO;
    lines are split on "\n" only. Returns every ProfileApplied event whose workspace is
    WORKSPACE (as given or resolved) and whose "enforced" is a boolean, in log order, each as
    {"profile", "platform", "enforced", "read_write_paths"} (the strings of its list, None when
    the event has none). Neither the read-only nor the strict-based events list grok's
    write-denied protected set (config.toml, sandbox.toml, hooks/, ...): only the grants.
    read_only_paths is kept too (the strings of its list, None when the event has none)."""
    if not path or not workspace:
        return []
    data = read_appended(path, start, end, GROK_EVENTS_MAX)
    if not data:
        return []
    want = {os.path.abspath(workspace), os.path.realpath(workspace)}
    found = []
    for line in data.decode("utf-8", "replace").split("\n"):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            ev = json.loads(line)
        except ValueError:
            continue
        if not isinstance(ev, dict) or ev.get("event_type") != "ProfileApplied":
            continue
        ws = ev.get("workspace")
        if not isinstance(ws, str) or not ws or (os.path.abspath(ws) not in want and os.path.realpath(ws) not in want):
            continue
        enf = ev.get("enforced")
        if not isinstance(enf, bool):
            continue
        rw = ev.get("read_write_paths")
        rw = [x for x in rw if isinstance(x, str)] if isinstance(rw, list) else None
        ro = ev.get("read_only_paths")
        ro = [x for x in ro if isinstance(x, str)] if isinstance(ro, list) else None
        found.append({"profile": sanitize(ev.get("profile") or "?", 80), "platform": sanitize(ev.get("platform") or "unknown", 80),
                      "enforced": enf, "read_write_paths": rw, "read_only_paths": ro})
    return found


def read_appended(path, start, end, cap, tail=False):
    """Bytes [START, END) of PATH, what a CLI appended while one call ran ([0, END) when the file
    shrank meanwhile; at most CAP bytes: the first ones, or with TAIL the last ones), never when
    PATH itself is a symlink (O_NOFOLLOW: its last path component only) or no regular file, and
    never blocking on a FIFO; b"" otherwise."""
    import stat
    if not path or end is None or not isinstance(end, int) or end <= 0:
        return b""
    start = start if isinstance(start, int) and 0 <= start <= end else 0
    if end <= start:
        return b""
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    except OSError:
        return b""
    data = b""
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return b""
        n = min(end - start, cap)
        os.lseek(fd, end - n if tail else start, os.SEEK_SET)
        while len(data) < n:
            chunk = os.read(fd, n - len(data))
            if not chunk:
                break
            data += chunk
    except OSError:
        return b""
    finally:
        os.close(fd)
    return data


def grok_sandbox_event(path, start, end, workspace):
    """The ProfileApplied event of grok_sandbox_events for WORKSPACE (an event with enforced false
    wins, else the first), else None: the event can only add a refusal, never lift one (an
    absent log or event changes nothing)."""
    evs = grok_sandbox_events(path, start, end, workspace)
    for ev in evs:
        if ev["enforced"] is False:
            return ev
    return evs[0] if evs else None


def _path_under(child, parent):
    return child == parent or child.startswith(parent.rstrip("/") + "/")


def grok_home_write(paths, grok_home):
    """The first of PATHS (a ProfileApplied event's read_write_paths) that grants write to grok's
    home GROK_HOME (${GROK_HOME:-~/.grok}): GROK_HOME itself, a directory above it (/, $HOME, or
    /tmp when the home lies there) or one inside it (bin/, vendor/, installed-plugins/), except
    GROK_HOME/sessions and below, the session store every grok run writes. Each path and the home
    are compared as given (abspath) and resolved (realpath), both, and only on whole path
    components ($GROK_HOME/sessions-x is no session store, ${GROK_HOME}-x no part of the home): a
    path is exempt only when both of its forms lie in the session store of the home's own form,
    so a sessions link back to the home is no exemption. Measured on 1.0.70
    (tests/fixtures/real/grok/write-probe-*): the built-in read-only grants ~/.grok, where grok's
    binary in bin/, its ripgrep (vendor/), installed-plugins/ and auth.json stay writable (an
    append-open of its protected set was denied), so a run steered by what it reads could plant
    code that later runs outside any sandbox. None when no path does."""
    if not grok_home:
        return None
    homes = [os.path.abspath(grok_home), os.path.realpath(grok_home)]
    for p in paths or []:
        if not isinstance(p, str) or not p:
            continue
        pa, pr = os.path.abspath(p), os.path.realpath(p)
        if _path_under(pa, homes[0] + "/sessions") and _path_under(pr, homes[1] + "/sessions"):
            continue
        for h in homes:
            if any(_path_under(h, x) or _path_under(x, h) for x in (pa, pr)):
                return p
    return None


# --------------------------------------------------------------------------- grok's resolver reads

# strict's read set as grok 1.0.70 applies it (every strict-based ProfileApplied event of
# tests/fixtures/real/grok/sandbox-events-1.0.70.jsonl): these system directories, the working
# directory and grok's home, with a profile's read_only entries added to the list. Measured
# 2026-11-06 with a Landlock child holding the same read list: on WSL /etc/resolv.conf links to
# /mnt/wsl/resolv.conf, which the list cannot read (EACCES), so getaddrinfo failed; with /mnt/wsl
# added it resolved. A grok run under such a profile retried its API for 28 minutes, then failed.
GROK_STRICT_READ = ("/usr", "/lib", "/lib64", "/bin", "/sbin", "/etc", "/dev", "/proc", "/sys", "/tmp", "/run", "/var")
# The files grok's name lookups (glibc's resolver configuration) and TLS (the usual CA bundles)
# read on Linux, each with what it is for: dns (no name resolves without it), lookup, tls.
# SSL_CERT_FILE and each SSL_CERT_DIR entry (colon-separated) join them when set.
GROK_RESOLVER_FILES = (("/etc/resolv.conf", "dns"), ("/etc/hosts", "lookup"), ("/etc/nsswitch.conf", "lookup"),
                       ("/etc/host.conf", "lookup"), ("/etc/gai.conf", "lookup"),
                       ("/etc/ssl/certs/ca-certificates.crt", "tls"), ("/etc/ssl/cert.pem", "tls"),
                       ("/etc/pki/tls/certs/ca-bundle.crt", "tls"))
# conductor's own strict-based profile for grok calls outside a repository's profile (the
# skill's commit-message call through cx-wsl, a grok lane run outside a git checkout): strict
# plus the resolver directories only.
GROK_STRICT_PROFILE = "cx-strict"
GROK_RESOLVER_EFFECT = {"dns": "cannot resolve any host name", "lookup": "cannot read it for name lookups",
                        "tls": "may not verify TLS certificates"}


def root_realpath(root, path, limit=40):
    """PATH (absolute, as this host names it) resolved as the kernel would with ROOT as / (ROOT ""
    is the real /; the suite's CX_DETECT_ROOT a test tree, which prefixes every file detect.sh
    reads): every symlink followed, an absolute target from ROOT again; a missing component and
    what follows are kept as given, as os.path.realpath does. Returns the resolved path as the
    host names it (without ROOT), or None for a link loop."""
    import stat
    root = (root or "").rstrip("/")
    todo = [p for p in path.split("/") if p not in ("", ".")]
    done = []
    links = 0
    while todo:
        c = todo.pop(0)
        if c == "..":
            if done:
                done.pop()
            continue
        cand = done + [c]
        full = root + "/" + "/".join(cand)
        try:
            st = os.lstat(full)
        except OSError:
            done = cand
            continue
        if stat.S_ISLNK(st.st_mode):
            links += 1
            if links > limit:
                return None
            try:
                t = os.readlink(full)
            except OSError:
                return None
            if t.startswith("/"):
                done = []
            todo = [p for p in t.split("/") if p not in ("", ".")] + todo
            continue
        done = cand
    return "/" + "/".join(done)


def grok_resolver_targets(root, env):
    """The resolver and TLS files of this host that exist (a dangling link counts, with exists
    False): GROK_RESOLVER_FILES, then SSL_CERT_FILE and each SSL_CERT_DIR entry of ENV (absolute
    ones only), each as {"path", "kind" (dns, lookup, tls), "real" (resolved under ROOT, as the
    host names it; None for a link loop), "exists", "dir"}. Every file is read under ROOT
    (CX_DETECT_ROOT, empty in production)."""
    root = (root or "").rstrip("/")
    items = list(GROK_RESOLVER_FILES)
    v = env.get("SSL_CERT_FILE") or ""
    if v.startswith("/"):
        items.append((v, "tls"))
    for d in (env.get("SSL_CERT_DIR") or "").split(":"):
        if d.startswith("/"):
            items.append((d, "tls"))
    res, seen = [], set()
    for path, kind in items:
        p = "/" + os.path.normpath(path).lstrip("/")
        if p in seen or not os.path.lexists(root + p):
            continue
        seen.add(p)
        real = root_realpath(root, p)
        ok = real is not None and os.path.exists(root + real)
        res.append({"path": p, "kind": kind, "real": real, "exists": ok, "dir": ok and os.path.isdir(root + real)})
    return res


def _path_forms(root, p):
    """P as given (normalized) and resolved under ROOT: the two forms every comparison uses."""
    if not p or not p.startswith("/"):
        return []
    forms = ["/" + os.path.normpath(p).lstrip("/")]
    r = root_realpath(root, p)
    if r and r not in forms:
        forms.append(r)
    return forms


def grok_reads(root, path, bases):
    """True when PATH (resolved, as the host names it) lies inside one of BASES (each as given and
    resolved under ROOT)."""
    return any(_path_under(path, f) for b in bases for f in _path_forms(root, b))


def _grant_refusal(root, d, guards, cx_home):
    """Why directory D may not become a read grant, else None: it is /, no directory, is or
    contains a GUARDS path ((label, path) pairs: the home directory, grok's home, the conductor's
    home, a checkout), or lies inside the conductor's home (other runs' tasks and diffs, the
    Copilot token file)."""
    if d == "/":
        return "it is /"
    if not os.path.isdir((root or "").rstrip("/") + d):
        return "it is not a directory"
    for label, p in guards:
        for f in _path_forms(root, p):
            if _path_under(f, d):
                return "it %s %s %s" % ("is" if f == d else "contains", label, p)
    for f in _path_forms(root, cx_home):
        if _path_under(d, f):
            return "it lies inside the conductor's home %s (other runs' tasks and diffs, the Copilot token file)" % cx_home
    return None


def grok_resolver_plan(root, env, home, grok_home, cx_home, protect=()):
    """What every conductor grok profile adds for grok's resolver and TLS files (DESIGN section
    15.7): {"platform", "targets", "dirs", "skipped"}. A target whose resolved path lies outside
    strict's read set (GROK_STRICT_READ and grok's home) gets the directory that holds it (the
    directory itself for an SSL_CERT_DIR entry) into "dirs" (sorted, unique), unless that
    directory is /, is or contains HOME, GROK_HOME, CX_HOME or a PROTECT path ((label, path)
    pairs: the run's checkout, the repository and its git directory), or lies inside CX_HOME:
    those go to "skipped", with the reason. Linux only (grok's Landlock sandbox, where that read
    set was measured); elsewhere nothing is added."""
    plan = {"platform": sys.platform, "targets": [], "dirs": [], "skipped": []}
    if not sys.platform.startswith("linux"):
        return plan
    guards = [("your home directory", home), ("grok's home", grok_home), ("the conductor's home", cx_home)] + list(protect)
    for t in grok_resolver_targets(root, env):
        t["inside"] = bool(t["exists"] and grok_reads(root, t["real"], GROK_STRICT_READ + (grok_home,)))
        t["grant"] = t["skip"] = None
        plan["targets"].append(t)
        if not t["exists"] or t["inside"]:
            continue
        d = t["real"] if t["dir"] else os.path.dirname(t["real"])
        why = _grant_refusal(root, d, guards, cx_home)
        if why:
            t["skip"] = why
            plan["skipped"].append({"dir": d, "why": why, "path": t["path"], "real": t["real"], "kind": t["kind"]})
        else:
            t["grant"] = d
            if d not in plan["dirs"]:
                plan["dirs"].append(d)
    plan["dirs"].sort()
    return plan


def grok_resolver_unreadable(root, env, grants):
    """The resolver and TLS targets (grok_resolver_targets) whose resolved path lies under none of
    GRANTS (a ProfileApplied event's read_only_paths and read_write_paths): what grok cannot read
    under that profile. Linux only."""
    if not sys.platform.startswith("linux"):
        return []
    return [t for t in grok_resolver_targets(root, env) if t["exists"] and not grok_reads(root, t["real"], grants)]


def _target_text(t):
    if t["real"] is None:
        return "%s (a link loop)" % t["path"]
    return t["path"] if t["real"] == t["path"] else "%s -> %s" % (t["path"], t["real"])


def cmd_grok_sandbox_event(a):
    """grok-sandbox-event --file F --from N --to M --workspace W [--grok-home H]: prints
    "enforced", "unenforced" or "none", then the platform and the profile, tab-separated, and with
    --grok-home the first read_write path of those events that grants write to H, else "-"
    (DESIGN section 8.3 D17: a grok whose built-in strict writes its home fails D17)."""
    ev = grok_sandbox_event(a.file, a.start, a.end, a.workspace)
    if ev is None:
        line = "none\t-\t-"
    else:
        line = "%s\t%s\t%s" % ("enforced" if ev["enforced"] else "unenforced", ev["platform"].replace("\t", " "),
                                ev["profile"].replace("\t", " "))
    if a.grok_home:
        hw = None
        for e in grok_sandbox_events(a.file, a.start, a.end, a.workspace):
            hw = grok_home_write(e["read_write_paths"] or [], a.grok_home)
            if hw:
                break
        line += "\t" + (sanitize(hw, 300).replace("\t", " ") if hw else "-")
    out(line + "\n")
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
SANDBOX_EXCLUDES = ("ghcp-*", "agy-*", "agy", "grok", "gh", "git", "copilot", "cx-*")
# D25 (U2): the narrow allow rules for the command forms the skill writes (section 12.2), one per
# leading form of a simple command in its bash blocks and no other (the suite checks both ways):
# cx-run and cx-job (every executor run), the hand steps' two executor calls through cx-wsl (it
# takes their pool slot and adds the per-tool prefix, in WSL as from Windows), ghcp-cloud list /
# view (the cloud agent, free), the vars.sh line that starts every hand step and the GitHub steps.
# No raw agy, agy-delegate, ghcp-delegate or job form: those would bypass cx-run's slots, agy
# registration, tree snapshots and served-model checks.
D25_HOST_RULES = (
    ["Bash(cx-doctor:*)", "Bash(cx-init:*)", "Bash(cx-run:*)", "Bash(cx-job:*)",
     "Bash(cx-wsl grok:*)", "Bash(cx-wsl ghcp-ci-debug:*)", "Bash(ghcp-cloud list:*)", "Bash(ghcp-cloud view:*)",
     'Bash(. "$HOME/.conductor/out/:*)', 'Bash(git -C "$WT" push:*)', "Bash(gh pr:*)"])
# The Windows side reaches WSL through cx-run and cx-job (they forward themselves, so
# Bash(cx-run:*) and Bash(cx-job:*) suffice there) and cx-wsl. D25 lists the cx-wsl forms the
# skill runs directly from Windows, never Bash(cx-wsl:*): that rule also covers cx-wsl bash -c/-s,
# i.e. every command in WSL, and U2 grants spending, pushes, PRs and @copilot reviews, not every
# shell command (the user's choice, 2026-11-01). The skill's cx-wsl bash steps (Step 3's commit
# and gate, Step 5) prompt.
D25_CXWSL_TOOLS = ("ghcp-ci-debug", "ghcp-cloud list", "ghcp-cloud view", "gh pr")
D25_WIN_RULES = (["Bash(cx-doctor:*)", "Bash(cx-init:*)", "Bash(cx-run:*)", "Bash(cx-job:*)"]
                 + ["Bash(cx-wsl %s:*)" % t for t in D25_CXWSL_TOOLS])
D25_CXWSL_BROAD = ("Bash(cx-wsl:*) is in %s: it also allows cx-wsl bash -c and -s, i.e. any command in WSL, without a "
                   "prompt, which is more than U2 (spending, pushes, PRs, @copilot reviews); %s")


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
            lines.append(rec_line("warn", "D24", sec, "subagent %s is not denied (the Task(...) rule syntax is unverified)" % agent,
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
            lines.append(rec_line("info", "D25", sec, "the rules match the skill's commands as written (prefixes and $VAR text included); how Claude Code matches env -u prefixes and multi-line steps is unverified; the doctor never writes settings"))
        else:
            lines.append(rec_line("ok", "D25", sec, "autonomy allow rules present in %s" % where))
        if "Bash(cx-wsl:*)" in allow:
            lines.append(rec_line("warn", "D25", sec, D25_CXWSL_BROAD % (
                where, "replace it with the tool rules " + ", ".join(D25_WIN_RULES[4:]) + " (cx-wsl bash steps then prompt)"
                if a.forwarded else "remove it: a session in WSL needs only the cx-wsl tool rules listed (the skill's grok and ghcp-ci-debug calls)")))
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


RECORD_BINS = ("claude", "copilot", "grok", "agy", "gh", "git", "python3", "ghcp_delegate", "ghcp_job",
               "ghcp_handoff", "ghcp_ci_debug", "ghcp_models", "ghcp_cloud", "agy_delegate", "agy_job")


def cmd_record_env(a):
    """The Phase 2 adapters (section 15.2): the host record as shell assignments (printf %q
    style, through shell_quote) for eval: CXR_PATH, CXR_COPILOT_HOME (set or unset),
    CXR_COPILOT_TOKEN_ENV, CXR_RECORDED_AT, CXR_PLUGIN_VERSION and CXR_BIN_<key> for every key
    of RECORD_BINS (empty when missing, not executable or under the automount root; a sibling
    wrapper that moved is re-resolved once from installed_plugins.json, like wsl-resolve).
    Exit 3 without a readable record."""
    rec = load_json_file(a.record)
    if not isinstance(rec, dict):
        return 3
    mnt = a.mnt_root if a.mnt_root.endswith("/") else a.mnt_root + "/"
    drive = re.compile("(%s|/mnt/)[A-Za-z]/" % re.escape(mnt))

    def runnable(p):
        if not (isinstance(p, str) and p.startswith("/")) or drive.match(p):
            return False
        return os.path.isfile(p) and os.access(p, os.X_OK)

    bins = dict(rec.get("bin")) if isinstance(rec.get("bin"), dict) else {}
    for prefix, pid, names in (("ghcp_", GHCP_ID, GHCP_WRAPPERS), ("agy_", AGY_ID, AGY_WRAPPERS)):
        if any(k.startswith(prefix) and k in RECORD_BINS and not runnable(bins.get(k)) for k in
               [n.replace("-", "_") for n in names]):
            info = plugins_report(a.config_dir)["plugins"][pid]
            if info["installed"] and info["install_path"]:
                for n in names:
                    cand = os.path.abspath(os.path.join(info["install_path"], "bin", n))
                    if runnable(cand) and not runnable(bins.get(n.replace("-", "_"))):
                        bins[n.replace("-", "_")] = cand
    path = rec.get("path") if isinstance(rec.get("path"), str) else ""
    path = ":".join(d for d in path.split(":") if d.startswith("/") and not drive.match(d + "/"))
    lines = ["CXR_PATH=" + shell_quote(path)]
    ch = rec.get("copilot_home")
    lines.append("CXR_COPILOT_HOME_SET=" + ("1" if isinstance(ch, str) else "0"))
    lines.append("CXR_COPILOT_HOME=" + shell_quote(ch if isinstance(ch, str) else ""))
    te = rec.get("copilot_token_env")
    lines.append("CXR_COPILOT_TOKEN_ENV=" + shell_quote(te if te in ("GH_TOKEN", "GITHUB_TOKEN") else ""))
    lines.append("CXR_RECORDED_AT=" + shell_quote(str(rec.get("recorded_at") or "")))
    lines.append("CXR_PLUGIN_VERSION=" + shell_quote(str(rec.get("plugin_version") or "")))
    for k in RECORD_BINS:
        v = bins.get(k)
        lines.append("CXR_BIN_%s=%s" % (k, shell_quote(v if runnable(v) else "")))
    out("\n".join(lines) + "\n")
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
        if cr is None and isinstance(ev.get("cost"), dict):
            cr = ev["cost"].get("ai_credits")  # Phase 2 ledger lines (section 15.4)
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
            lines.append(rec_line("info", "D32", sec, "ultracode on for new sessions (%s): workflow agents get the conductor's subagent rules and run executors only through cx-run --background (the shared pool slots cap them)" % _where(u)))
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
    # (7) Phase 2: the pool slot caps next to the concurrency (section 15.3)
    if re.fullmatch(r"(cap_[a-z]+=[0-9]+ ?)+", a.caps or ""):
        lines.append(rec_line("info", "D32", sec, "slot caps: %s (shared by every session, thread and workflow agent on this computer; a run beyond them queues, then exits 28)" % a.caps.strip()))
    if st["workflow_allow"]:
        lines.append(rec_line("info", "D32", sec, "Workflow allow rules: " + ", ".join(st["workflow_allow"])))
    sys.stdout.write("".join(lines))
    return 0


SECTIONS = ["Session", "Host", "Runtime", "Options", "CLIs", "Versions", "Logins (free probes)",
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
        # /.conductor, not 0.2.1's /.conductor/ (directories only): a .conductor symlink or file
        # an executor left is ignored too (worktree.sh cx_wt_exclude).
        excluded = "/.conductor" in ex_lines
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
                    fh.write(b"/.conductor\n")
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


# --------------------------------------------------------------------------- grok sandbox profiles

# The profile text conductor 0.2.0 appended to ~/.grok/sandbox.toml (templates/grok-sandbox.toml of
# 0.2.0, name cx-workspace): its deny globs are invalid (grok's deny takes literal paths), so the
# writers below remove this exact block (nothing else) wherever they touch the file.
GROK_OLD_BLOCK = """# conductor: the grok sandbox profile every conductor grok writer runs under (option
# grok_sandbox_profile; docs/DESIGN.md section 15.7). Added to ~/.grok/sandbox.toml by
# cx-init --user-grants when the profile is absent. It extends grok's built-in workspace
# profile (writes inside the working directory) and denies secrets. The key names are
# docs-only (DESIGN section 20): check the effective profile with `grok inspect --json` in a
# conductor worktree.
[profiles.cx-workspace]
extends = "workspace"
deny = ["**/.env", "**/.env.*", "**/*.pem", "**/*.key", "**/id_rsa*"]
"""


def grok_profile_name(gcd):
    """cx-<repo>-<8 hex>: the repository's main-checkout name (sanitized, at most 24
    characters) and the start of the sha256 of its git common directory."""
    import hashlib
    gcd = gcd.rstrip("/") or "/"
    base = os.path.basename(gcd)
    base = os.path.basename(os.path.dirname(gcd)) if base == ".git" else re.sub(r"\.git$", "", base)
    slug = re.sub(r"[^a-z0-9]+", "-", base.lower()).strip("-")[:24].strip("-") or "repo"
    return "cx-%s-%s" % (slug, hashlib.sha256(gcd.encode("utf-8", "surrogateescape")).hexdigest()[:8])


def _toml_str_list(items):
    return "[" + ", ".join(json.dumps(i, ensure_ascii=True) for i in items) + "]"


def grok_repo_of(gcd):
    """The main checkout of git common directory GCD (its parent when it is a .git directory)."""
    return os.path.dirname(gcd.rstrip("/")) if os.path.basename(gcd.rstrip("/")) == ".git" else gcd


def grok_profile_block(template, name, gcd, routes_root, extra=()):
    """The repository's profile: read_only the git common directory, the routes directory and
    EXTRA (the resolver directories of grok_resolver_plan)."""
    ro = [gcd, routes_root] + [d for d in extra if d not in (gcd, routes_root)]
    body = template.replace("{{name}}", name).replace("{{repo}}", sanitize(grok_repo_of(gcd), 300)).replace(
        "{{read_only}}", _toml_str_list(ro))
    if not body.endswith("\n"):
        body += "\n"
    return "# cx:begin %s\n%s# cx:end %s\n" % (name, body, name)


# cx-strict's text (no template file: it names no repository).
GROK_STRICT_TEXT = """# conductor: grok's built-in strict profile plus read-only access to the directories outside
# strict's read set that hold this host's resolver and TLS files (on WSL /etc/resolv.conf links to
# /mnt/wsl/resolv.conf, which strict cannot read, so grok could not resolve any host name; cx-doctor
# D17 lists them; none on most hosts). cx-wsl runs the skill's grok calls under it (commit messages,
# PR text) and the grok lane runs under it outside a git checkout; both rewrite the lines between
# cx:begin and cx:end when they differ, and any other [profiles.{{name}}] in this file is replaced
# (the name is conductor's own), so put your own profiles under other names
# (docs/DESIGN.md section 15.7).
[profiles.{{name}}]
extends = "strict"
read_only = {{read_only}}
"""


def grok_strict_block(dirs):
    """conductor's cx-strict profile: strict plus read_only DIRS (the resolver directories)."""
    body = GROK_STRICT_TEXT.replace("{{name}}", GROK_STRICT_PROFILE).replace("{{read_only}}", _toml_str_list(list(dirs)))
    return "# cx:begin %s\n%s# cx:end %s\n" % (GROK_STRICT_PROFILE, body, GROK_STRICT_PROFILE)


def _toml_ok(text):
    """True / False when tomllib can judge TEXT, None without tomllib (Python < 3.11)."""
    try:
        import tomllib
    except ImportError:
        return None
    try:
        tomllib.loads(text)
        return True
    except Exception:
        return False


def _toml_profile(text, name):
    """(parsed, profile): parsed is None without tomllib, False when TEXT does not parse; profile
    is TEXT's [profiles.NAME] table (None when absent)."""
    try:
        import tomllib
    except ImportError:
        return None, None
    try:
        d = tomllib.loads(text)
    except Exception:
        return False, None
    p = d.get("profiles")
    return True, (p.get(name) if isinstance(p, dict) else None)


def _grok_unmarked_re(name):
    """A table [profiles.NAME] or [profiles.NAME.<sub>] (bare, "quoted" or 'literal' key) with
    its lines up to the next table header."""
    n = re.escape(name)
    return re.compile(r"^[ \t]*\[[ \t]*profiles[ \t]*\.[ \t]*(?:%s|\"%s\"|'%s')[ \t]*(?:\.[^\]\n]*)?\][^\n]*(?:\n|\Z)"
                      r"(?:(?![ \t]*\[|# cx:(?:begin|end) )[^\n]*(?:\n|\Z))*" % (n, n, n), re.M)


def grok_profile_plan(path, name, block):
    """(action, new_text, notes) for profile NAME, rendered as BLOCK (grok_profile_block, the
    repository's; grok_strict_block, cx-strict), in sandbox.toml PATH: create, update, same or
    conflict (the result would not parse, or would not hold exactly the rendered profile). Every
    conductor grok run (write, read and review, and the skill's commit-message call under
    cx-strict) runs under a strict-based profile, and under
    strict grok write-denies ~/.grok itself and sandbox.toml (measured on 1.0.70,
    tests/fixtures/real/grok/write-probe-strict-1.0.70.txt), so no conductor grok run can change
    this file. Under the built-in read-only an append-open of its protected set (config.toml,
    sandbox.toml, trusted_folders.toml, managed_config.toml, requirements.toml, hooks-paths,
    hooks/, bundled/, bundles/) was denied too, but ~/.grok itself stayed writable, so whether
    a rename over a protected file is denied rests on grok's docs alone (they pin a protected
    path's parents). What can change it: your own grok sessions without a sandbox (grok's
    default) or with devbox, other tools, and code planted earlier where 0.2.1's read-only runs
    could write (grok's binary in ~/.grok/bin, its ripgrep in ~/.grok/vendor,
    ~/.grok/installed-plugins, auth.json), which runs outside any sandbox. The names cx-<repo>-<hash>
    and cx-strict are conductor's own (no person writes them), so every
    definition of NAME is replaced by the rendered block, between the cx:begin/cx:end lines or
    not (markers something stripped never make a widened profile "the user's")."""
    notes = []
    tgt = _ug_target(path)
    old = read_text(tgt) if os.path.exists(tgt) else ""
    new = old
    if GROK_OLD_BLOCK in new:
        new = new.replace("\n\n" + GROK_OLD_BLOCK, "\n").replace("\n" + GROK_OLD_BLOCK, "\n").replace(GROK_OLD_BLOCK, "")
        notes.append("removed the 0.2.0 cx-workspace profile from %s (its deny globs are not valid grok paths)" % path)
    hole = "\0cx-profile\0"
    marked = re.compile(r"(?ms)^# cx:begin %s\n.*?^# cx:end %s(?:\n|\Z)" % (re.escape(name), re.escape(name)))
    m = marked.search(new)
    if m:
        new = new[:m.start()] + hole + marked.sub("", new[m.end():])
    unmarked = _grok_unmarked_re(name)
    if unmarked.search(new.replace(hole, "")):
        notes.append("%s defined [profiles.%s] outside conductor's cx:begin/cx:end lines: replaced it with conductor's own "
                     "profile of that name (something other than a conductor grok run rewrote the file, which grok "
                     "write-denies under its sandbox profiles)" % (path, name))
        parts = new.split(hole)
        new = hole.join(unmarked.sub("", x) for x in parts)
    if hole in new:
        new = new.replace(hole, block, 1)
    else:
        new = new.rstrip("\n")
        new = new + ("\n\n" if new.strip() else "") + block
    # Checked also when nothing changes: grok must read exactly the rendered profile.
    parsed, prof = _toml_profile(new, name)
    if parsed is False:
        return "conflict", old, notes + ["%s would not parse%s (is it valid TOML now?): nothing written" % (path, "" if new == old else " after the edit")]
    if parsed is True and prof != _toml_profile(block, name)[1]:
        return "conflict", old, notes + ["%s defines [profiles.%s] another way too (an inline table or dotted keys): nothing "
                                         "written; remove every other definition of it by hand" % (path, name)]
    if new == old:
        return "same", new, notes
    return ("update" if old else "create"), new, notes


def _write_user_file(path, data, existed):
    """Through a symlinked dotfile to its target; <file>.cx-bak first when it existed; the
    file's own mode is kept (0600 for a new one: sandbox.toml holds no secret, grok makes it 0600)."""
    tgt = _ug_target(path)
    mode = 0o600
    if existed:
        shutil.copy2(tgt, path + ".cx-bak")
        try:
            mode = os.stat(tgt).st_mode & 0o7777
        except OSError:
            pass
    atomic_write(tgt, data, mode)


def grok_plan_notes(plan, act):
    """The notes a profile write prints about the resolver directories (cx-doctor D17)."""
    notes = []
    if plan["dirs"] and act in ("create", "update"):
        notes.append("read_only adds %s: grok's resolver and TLS files there lie outside strict's read set (cx-doctor D17)"
                     % ", ".join(plan["dirs"]))
    for s in plan["skipped"]:
        notes.append("not granted: %s (%s), for %s, outside strict's read set: grok %s under this profile (cx-doctor D17)"
                     % (s["dir"], s["why"], _target_text(s), GROK_RESOLVER_EFFECT.get(s["kind"], "cannot read it")))
    return notes


def grok_plan_for(a, gcd):
    """grok_resolver_plan from grok-profile's / user-grants' options (each defaults to the
    environment: HOME, GROK_HOME, CX_HOME, CX_DETECT_ROOT, SSL_CERT_FILE, SSL_CERT_DIR)."""
    home = a.home or os.environ.get("HOME", "")
    grok_home = a.grok_home or os.environ.get("GROK_HOME") or os.path.join(home, ".grok")
    cx_home = getattr(a, "cx_home", "") or os.environ.get("CX_HOME") or os.path.join(home, ".conductor")
    root = a.resolver_root if a.resolver_root is not None else os.environ.get("CX_DETECT_ROOT", "")
    protect = []
    if getattr(a, "workspace", ""):
        protect.append(("the run's checkout", a.workspace))
    if gcd:
        protect += [("the repository", grok_repo_of(gcd)), ("the repository's git directory", gcd)]
    return grok_resolver_plan(root, os.environ, home, grok_home, cx_home, protect)


def cmd_grok_profile(a):
    """grok-profile --gcd D --name-only | (--gcd D --template T --routes-root R | --strict)
    --sandbox F [--lock L] [--dry-run] [--workspace W] [--home H] [--grok-home G] [--cx-home C]
    [--resolver-root R]: the repository's sandbox profile, or with --strict conductor's
    cx-strict (DESIGN section 15.7), each with the resolver directories grok_resolver_plan finds
    (W, the run's checkout, is never granted), written idempotently under the lock; prints
    "<action> <name>" (and notes); exit 0, 5 conflict, 2 error."""
    gcd = None
    if a.strict:
        name = GROK_STRICT_PROFILE
    else:
        if not a.gcd:
            err("cxlib: grok-profile needs --gcd or --strict\n")
            return 2
        gcd = os.path.realpath(a.gcd)
        name = grok_profile_name(gcd)
        if a.name_only:
            out(name + "\n")
            return 0
        if not (a.template and a.routes_root):
            err("cxlib: grok-profile needs --template and --routes-root\n")
            return 2
    if not a.sandbox:
        err("cxlib: grok-profile needs --sandbox\n")
        return 2
    lk = None
    try:
        if a.lock:
            import fcntl
            os.makedirs(os.path.dirname(os.path.abspath(a.lock)), exist_ok=True)
            lk = open(a.lock, "a")
            fcntl.flock(lk.fileno(), fcntl.LOCK_EX)
        plan = grok_plan_for(a, gcd)
        if gcd:
            block = grok_profile_block(read_text(a.template), name, gcd, a.routes_root, plan["dirs"])
        else:
            block = grok_strict_block(plan["dirs"])
        act, new, notes = grok_profile_plan(a.sandbox, name, block)
        if act in ("create", "update") and not a.dry_run:
            _write_user_file(a.sandbox, new, os.path.exists(_ug_target(a.sandbox)))
        notes += grok_plan_notes(plan, act)
    except OSError as e:
        err("cxlib: grok-profile: %s\n" % e)
        return 2
    finally:
        if lk is not None:
            lk.close()
    out("%s %s%s\n" % (act, name, "".join("; " + sanitize(n, 300) for n in notes)))
    return 5 if act == "conflict" else 0


def _sandbox_profiles(path):
    """{name: read paths (read_only plus read_write; None when unknown)} of the profiles conductor
    marked (# cx:begin NAME) in sandbox.toml PATH: tomllib when it parses the file, else the
    block's own read_only line (written by _toml_str_list)."""
    try:
        text = read_text(_ug_target(path))
    except OSError:
        return {}
    names = re.findall(r"(?m)^# cx:begin (cx-[A-Za-z0-9._-]+)$", text)
    res = {}
    for n in names:
        parsed, prof = _toml_profile(text, n)
        if parsed is True and isinstance(prof, dict):
            paths = []
            for k in ("read_only", "read_write"):
                v = prof.get(k)
                paths += [x for x in v if isinstance(x, str)] if isinstance(v, list) else []
            res[n] = paths
            continue
        m = re.search(r"(?ms)^# cx:begin %s\n(.*?)^# cx:end %s$" % (re.escape(n), re.escape(n)), text)
        ro = re.search(r"(?m)^read_only = (\[.*\])$", m.group(1)) if m else None
        try:
            v = json.loads(ro.group(1)) if ro else None
        except ValueError:
            v = None
        res[n] = [x for x in v if isinstance(x, str)] if isinstance(v, list) else None
    return res


def cmd_grok_resolver(a):
    """grok-resolver --section S [--home H] [--grok-home G] [--cx-home C] [--resolver-root R]
    [--sandbox F] [--profile P]: D17's resolver records (DESIGN section 8.3): the resolver and TLS
    targets, the directories conductor's grok profiles add for those outside strict's read set,
    the ones it cannot grant (! grok cannot resolve names under any conductor profile), the
    conductor profiles in F whose read paths lack one of those directories (! fixed by the
    profile's next write), and option grok_sandbox_profile P naming strict or a profile of the
    user's own that lacks one. Linux only (nothing elsewhere)."""
    plan = grok_plan_for(a, None)
    if not plan["platform"].startswith("linux"):
        return 0
    root = a.resolver_root if a.resolver_root is not None else os.environ.get("CX_DETECT_ROOT", "")
    sec, lines = a.section, []
    tg = plan["targets"]
    outside = [t for t in tg if t["exists"] and not t["inside"]]
    if tg:
        lines.append(rec_line("info", "D17", sec, "grok's resolver and TLS files: %s (%s outside strict's read set: the "
                              "system directories %s, the working directory and grok's home)" % (
                                  ", ".join(_target_text(t) + ("" if t["exists"] else " (missing)") for t in tg),
                                  "%d" % len(outside) if outside else "none", " ".join(GROK_STRICT_READ))))
    granted = [t for t in outside if t["grant"]]
    if plan["dirs"]:
        lines.append(rec_line("ok", "D17", sec, "conductor's grok profiles (each repository's cx-<repo>-<hash> and cx-strict) "
                              "add read_only %s for %s: grok can read them there" % (
                                  ", ".join(plan["dirs"]), ", ".join(_target_text(t) for t in granted))))
    elif tg and not outside:
        lines.append(rec_line("ok", "D17", sec, "grok's resolver and TLS files lie inside strict's read set: no profile needs more"))
    for s in plan["skipped"]:
        t = {"path": s["path"], "real": s["real"]}
        if s["kind"] == "dns":
            text = "grok cannot resolve any host name under any conductor profile: %s, outside strict's read set, and its directory %s cannot be granted (%s)"
            fix = "make %s resolve to a file outside your home directory, ~/.grok, ~/.conductor and your checkouts (on WSL its default link to /mnt/wsl/resolv.conf works)" % s["path"]
        elif s["kind"] == "tls":
            text = "grok may not verify TLS certificates under any conductor profile: %s, outside strict's read set, and its directory %s cannot be granted (%s)"
            fix = "keep the CA bundle (SSL_CERT_FILE, SSL_CERT_DIR) outside your home directory, ~/.grok, ~/.conductor and your checkouts"
        else:
            text = "grok cannot read %s under any conductor profile (outside strict's read set; its directory %s cannot be granted: %s), so its name lookups may differ from the host's"
            fix = ""
        lines.append(rec_line("warn", "D17", sec, text % (_target_text(t), s["dir"], s["why"]), fix))
    for t in tg:
        if not t["exists"]:
            lines.append(rec_line("warn" if t["kind"] == "dns" else "info", "D17", sec, "%s points at %s, which does not exist%s" % (
                t["path"], t["real"] or "a link loop", ": no host name resolves here" if t["kind"] == "dns" else "")))
    if a.sandbox and plan["dirs"] and os.path.exists(a.sandbox):
        for name, paths in sorted(_sandbox_profiles(a.sandbox).items()):
            lack = [d for d in plan["dirs"] if paths is None or not grok_reads(root, d, paths)]
            if not lack:
                continue
            who = ("the next cx-wsl grok call (the skill's commit-message step) rewrites it" if name == GROK_STRICT_PROFILE else
                   "that repository's next grok run rewrites it (cx-run does before every grok run; cx-init --user-grants in it does now)")
            lines.append(rec_line("warn", "D17", sec, "%s: conductor's profile %s lacks read_only %s (grok's resolver and TLS files "
                                  "there): grok runs under it cannot read them until %s" % (a.sandbox, name, ", ".join(lack), who)))
    prof = (a.profile or "auto").strip()
    if plan["dirs"] and prof not in ("", "auto", "cx-workspace") and prof not in ("off", "devbox", "workspace", "read-only"):
        if prof == "strict":
            lines.append(rec_line("warn", "D17", sec, "option grok_sandbox_profile names grok's built-in strict, which cannot read %s "
                                  "(grok's resolver and TLS files there)" % ", ".join(plan["dirs"]),
                                  "set grok_sandbox_profile back to auto (conductor's profiles add them)"))
        else:
            parsed, p = _toml_profile(read_text(_ug_target(a.sandbox)), prof) if a.sandbox and os.path.exists(a.sandbox) else (None, None)
            paths = []
            for k in ("read_only", "read_write"):
                v = p.get(k) if isinstance(p, dict) else None
                paths += [x for x in v if isinstance(x, str)] if isinstance(v, list) else []
            lack = [d for d in plan["dirs"] if not grok_reads(root, d, paths)]
            if lack:
                lines.append(rec_line("warn", "D17", sec, "option grok_sandbox_profile names your own profile %s, to which conductor "
                                      "adds nothing: its read_only%s lacks %s (grok's resolver and TLS files there)" % (
                                          prof, "" if parsed else " (unread: no tomllib, or it does not parse)", ", ".join(lack)),
                                      "add %s to its read_only, or set grok_sandbox_profile back to auto" % ", ".join(lack)))
    out("".join(lines))
    return 0


def agy_global_grants(path):
    """The write_file(...) and command(...) rules of agy's user settings (conductor 0.2.0's
    cx-init --user-grants wrote them; agy runs now get per-run --settings grants)."""
    obj = load_json_file(path)
    if not isinstance(obj, dict) or not isinstance(obj.get("permissions"), dict):
        return []
    al = obj["permissions"].get("allow")
    return [x for x in (al if isinstance(al, list) else []) if isinstance(x, str) and re.match(r"\s*(write_file|command)\(", x)]


def cmd_agy_grants(a):
    g = agy_global_grants(a.file)
    out(json.dumps(g, ensure_ascii=False) + "\n")
    return 0 if g else 1


# --------------------------------------------------------------------------- cx-init --user-grants

def _ug_target(path):
    """Write through a symlinked dotfile to its target (dotfile managers), never replace the link."""
    return os.path.realpath(path) if os.path.islink(path) else path


def cmd_user_grants(a):
    """cx-init --user-grants (DESIGN section 15.7): user-level, idempotent. It writes the grok
    sandbox profile of the repository at --repo (--gcd: its git common directory) into
    ~/.grok/sandbox.toml (cx-run's grok lane writes the same profile on a repository's first
    run) and removes conductor 0.2.0's invalid cx-workspace profile. agy needs no user-level
    grant any more (each raw run passes its own --settings), so nothing is written for agy: a
    note lists the global grants 0.2.0 left in ~/.gemini/antigravity-cli/settings.json. Grok's
    auto-update setting is the user's (nothing pins a CLI version). A file that changes is first
    copied to <file>.cx-bak; a result that would not parse is a conflict and nothing is written
    (exit 5)."""
    home = a.home
    grok_home = a.grok_home or os.path.join(home, ".grok")
    root = a.root.rstrip("/") or "/"
    cmds = []
    for c in a.cmd or []:
        c = c.strip()
        if c and not CTRL_RE.search(c) and c not in cmds:
            cmds.append(c)
    results, writes, notes = [], [], []

    # agy: nothing to write; report the global grants an older conductor left
    gf = os.path.join(home, ".gemini", "antigravity-cli", "settings.json")
    left = agy_global_grants(gf) if os.path.exists(gf) else []
    if left:
        notes.append("%s still holds global agy grants (%s), written by conductor 0.2.0's cx-init --user-grants: "
                     "conductor runs no longer need them (each agy run gets its own --settings grants), and they apply "
                     "to every agy session of yours; remove them by hand if you do not want them" % (gf, ", ".join(left[:4]) + (" ..." if len(left) > 4 else "")))

    # grok: the repository's sandbox profile
    sf = os.path.join(grok_home, "sandbox.toml")
    prof = (a.profile or "auto").strip()
    tpl = read_text(a.template)
    if prof not in ("", "auto", "cx-workspace"):
        notes.append("option grok_sandbox_profile names your own profile %s: every conductor grok run (write, read and review) "
                     "uses it as it is (it must let grok read the repository's git directory, %s and the resolver directories "
                     "cx-doctor D17 lists, and must not let grok write "
                     "its home ~/.grok, but ~/.grok/sessions: each run checks that and is refused otherwise); nothing written for "
                     "it" % (prof, a.routes_root or "~/.conductor/routes"))
    if a.gcd and prof in ("", "auto", "cx-workspace"):
        gcd = os.path.realpath(a.gcd)
        a.home, a.grok_home = home, grok_home
        plan = grok_plan_for(a, gcd)
        act, new, n2 = grok_profile_plan(sf, grok_profile_name(gcd), grok_profile_block(tpl, grok_profile_name(gcd), gcd, a.routes_root, plan["dirs"]))
        notes.extend(n2 + grok_plan_notes(plan, act))
        if act in ("create", "update"):
            writes.append((sf, new, os.path.exists(_ug_target(sf))))
            ro = [gcd, a.routes_root] + plan["dirs"]
            results.append({"path": sf, "action": act, "reason": "profile %s (extends strict; read_only %s)" % (
                grok_profile_name(gcd), ", ".join(ro[:-1]) + " and " + ro[-1])})
        elif act == "conflict":
            results.append({"path": sf, "action": "conflict", "reason": n2[-1] if n2 else "would not parse"})
        else:
            results.append({"path": sf, "action": "same", "reason": ""})
    else:
        if os.path.exists(sf) and GROK_OLD_BLOCK in read_text(_ug_target(sf)):
            old = read_text(_ug_target(sf))
            new = old.replace("\n\n" + GROK_OLD_BLOCK, "\n").replace("\n" + GROK_OLD_BLOCK, "\n").replace(GROK_OLD_BLOCK, "")
            writes.append((sf, new, True))
            results.append({"path": sf, "action": "update", "reason": "removed the 0.2.0 cx-workspace profile (invalid deny globs)"})
        if not a.gcd:
            notes.append("not inside a git repository: no grok profile written (run it inside the repository, or let its first grok run write it)")

    conflict = any(r["action"] == "conflict" for r in results)
    written, unchanged, conflicts = [], [], []
    for r in results:
        (conflicts if r["action"] == "conflict" else unchanged if r["action"] == "same" else written).append(r["path"])
    if not a.dry_run and not conflict:
        for path, data, existed in writes:
            _write_user_file(path, data, existed)
    if a.json:
        out(json.dumps({"user_grants": True, "dry_run": bool(a.dry_run), "files": results, "notes": notes},
                       ensure_ascii=False, indent=1) + "\n")
    else:
        buf = []
        for r in results:
            act = r["action"]
            if act == "conflict":
                buf.append("CONFLICT %s (%s)\n" % (r["path"], r["reason"]))
            elif act in ("update", "create"):
                buf.append("%-8s %s (%s)\n" % (act, r["path"], r["reason"]))
            else:
                buf.append("same     %s\n" % r["path"])
        out("".join(buf))
        sys.stdout.flush()
        for n in notes:
            err("cx-init: %s\n" % sanitize(n, 600))
    sys.stdout.flush()
    err("CX_INIT %s\n" % dumps_line({"repo": a.repo or "", "dry_run": bool(a.dry_run),
                                     "written": [] if (a.dry_run or conflict) else written,
                                     "unchanged": unchanged, "conflicts": conflicts, "excluded": False,
                                     "detected": {"user_grants": True, "commands": cmds, "worktree_root": root,
                                                  "grok_profile": grok_profile_name(os.path.realpath(a.gcd)) if a.gcd else None}}))
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
    s = sub.add_parser("landlock")
    s.set_defaults(fn=cmd_landlock)
    s = sub.add_parser("grok-sandbox-event")
    s.add_argument("--file", required=True)
    s.add_argument("--from", dest="start", type=int, default=0)
    s.add_argument("--to", dest="end", type=int, default=0)
    s.add_argument("--workspace", required=True)
    s.add_argument("--grok-home", default="")
    s.set_defaults(fn=cmd_grok_sandbox_event)
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
    s = sub.add_parser("record-env")
    s.add_argument("--record", required=True)
    s.add_argument("--config-dir", required=True)
    s.add_argument("--mnt-root", default="/mnt/")
    s.set_defaults(fn=cmd_record_env)
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
    s.add_argument("--caps", default="")
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
    s = sub.add_parser("user-grants")
    s.add_argument("--home", required=True)
    s.add_argument("--grok-home", default="")
    s.add_argument("--root", required=True)
    s.add_argument("--profile", required=True)
    s.add_argument("--template", required=True)
    s.add_argument("--gcd", default="", help="the repository's git common directory (its grok profile)")
    s.add_argument("--routes-root", default="", help="$CX_HOME/routes (read_only in the grok profile: each run's cx-route)")
    s.add_argument("--cx-home", default="")
    s.add_argument("--resolver-root", default=None, help="default $CX_DETECT_ROOT")
    s.add_argument("--repo", default="")
    s.add_argument("--cmd", action="append")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_user_grants)
    s = sub.add_parser("grok-profile")
    s.add_argument("--gcd", default="")
    s.add_argument("--strict", action="store_true", help="conductor's cx-strict profile instead of the repository's")
    s.add_argument("--name-only", action="store_true")
    s.add_argument("--sandbox", default="")
    s.add_argument("--template", default="")
    s.add_argument("--routes-root", default="")
    s.add_argument("--lock", default="")
    s.add_argument("--dry-run", action="store_true")
    s.add_argument("--workspace", default="", help="the run's checkout (never granted)")
    s.add_argument("--home", default="")
    s.add_argument("--grok-home", default="")
    s.add_argument("--cx-home", default="")
    s.add_argument("--resolver-root", default=None, help="default $CX_DETECT_ROOT (a test tree; empty in production)")
    s.set_defaults(fn=cmd_grok_profile)
    s = sub.add_parser("grok-resolver")
    s.add_argument("--section", required=True)
    s.add_argument("--home", default="")
    s.add_argument("--grok-home", default="")
    s.add_argument("--cx-home", default="")
    s.add_argument("--resolver-root", default=None, help="default $CX_DETECT_ROOT")
    s.add_argument("--sandbox", default="")
    s.add_argument("--profile", default="auto", help="option grok_sandbox_profile")
    s.set_defaults(fn=cmd_grok_resolver)
    s = sub.add_parser("agy-grants")
    s.add_argument("file")
    s.set_defaults(fn=cmd_agy_grants)
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
