#!/usr/bin/env python3
"""ledger.py - the conductor's append-only run ledger (docs/DESIGN.md section 15.4).

Always invoked as `python3 -I ledger.py <subcommand> ...` on the executor host; stdlib only.
One JSON line per executor run: result.json without "raw" and "notes" (plus claude_session and
claude_effort, which result.json already carries). The file is only ever appended to, under an
exclusive flock on "<ledger>.lock", then fsync'd; it is never rewritten. Readers skip malformed
lines (split on "\\n" only).

Subcommands:
  append [--ledger PATH] RESULT_JSON     appends one line; prints the ledger path
  month --pool P [--month YYYY-MM] [--ledger PATH]
                                         the sum of cost.ai_credits for pool P in the month (UTC;
                                         default: this month), estimates included; prints a number
  tail [-n N] [--ledger PATH]            the last N lines (default 10), as stored

PATH defaults to $CX_LEDGER, else ~/.conductor/ledger.jsonl (option ledger_path; cx-run passes
the effective value). Exit 0 ok, 1 usage or unreadable input, 2 the ledger could not be written.
"""

import argparse
import datetime
import fcntl
import json
import os
import sys

DROP = ("raw", "notes")


def ledger_path(p):
    p = p or os.environ.get("CX_LEDGER") or "~/.conductor/ledger.jsonl"
    return os.path.expanduser(p)


def lines(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return []
    res = []
    for ln in text.split("\n"):
        ln = ln.strip()
        if not ln:
            continue
        try:
            v = json.loads(ln)
        except ValueError:
            continue
        if isinstance(v, dict):
            res.append(v)
    return res


def cmd_append(a):
    try:
        with open(a.result, encoding="utf-8") as fh:
            res = json.load(fh)
    except (OSError, ValueError) as e:
        sys.stderr.write("ledger: cannot read %s: %s\n" % (a.result, e))
        return 1
    if not isinstance(res, dict):
        return 1
    rec = {k: v for k, v in res.items() if k not in DROP}
    rec.setdefault("claude_session", os.environ.get("CLAUDE_CODE_SESSION_ID") or None)
    rec.setdefault("claude_effort", os.environ.get("CLAUDE_EFFORT") or None)
    line = (json.dumps(rec, ensure_ascii=True) + "\n").encode("utf-8")
    path = ledger_path(a.ledger)
    try:
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        lfd = os.open(path + ".lock", os.O_WRONLY | os.O_CREAT, 0o600)
        try:
            fcntl.flock(lfd, fcntl.LOCK_EX)
            fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
            try:
                # A previous writer killed mid-line leaves no newline: start on a fresh line.
                if os.fstat(fd).st_size > 0:
                    with open(path, "rb") as rh:
                        rh.seek(-1, os.SEEK_END)
                        if rh.read(1) != b"\n":
                            line = b"\n" + line
                os.write(fd, line)
                os.fsync(fd)
            finally:
                os.close(fd)
        finally:
            fcntl.flock(lfd, fcntl.LOCK_UN)
            os.close(lfd)
    except OSError as e:
        sys.stderr.write("ledger: cannot append to %s: %s\n" % (path, e))
        return 2
    sys.stdout.write(path + "\n")
    return 0


def cmd_month(a):
    month = a.month or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m")
    total = 0.0
    for rec in lines(ledger_path(a.ledger)):
        if str(rec.get("ts", "")).startswith(month) and rec.get("pool") == a.pool:
            cost = rec.get("cost") if isinstance(rec.get("cost"), dict) else {}
            cr = cost.get("ai_credits")
            if isinstance(cr, (int, float)) and not isinstance(cr, bool):
                total += cr
    sys.stdout.write("%s\n" % round(total, 4))
    return 0


def cmd_tail(a):
    try:
        with open(ledger_path(a.ledger), encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return 0
    ls = [ln for ln in text.split("\n") if ln.strip()]
    for ln in ls[-max(a.n, 0):] if a.n else []:
        sys.stdout.write(ln + "\n")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(prog="ledger.py")
    sub = ap.add_subparsers(dest="cmd")
    s = sub.add_parser("append")
    s.add_argument("--ledger", default="")
    s.add_argument("result")
    s.set_defaults(fn=cmd_append)
    s = sub.add_parser("month")
    s.add_argument("--pool", required=True)
    s.add_argument("--month", default="")
    s.add_argument("--ledger", default="")
    s.set_defaults(fn=cmd_month)
    s = sub.add_parser("tail")
    s.add_argument("-n", type=int, default=10)
    s.add_argument("--ledger", default="")
    s.set_defaults(fn=cmd_tail)
    a = ap.parse_args(argv)
    if not getattr(a, "fn", None):
        ap.print_help()
        return 1
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
