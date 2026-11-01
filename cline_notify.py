# -*- coding: utf-8 -*-
r"""cline_notify.py -- one Windows toast when a Cline turn ends.

POLICY
    Notify only when the turn ends, because that is the moment a human is needed:
        finished / asked a question / waiting for approval / aborted  ->  all "your turn".
    Do not notify about mid-run silence. A long tool, a slow MCP call and a genuinely wedged
    process look identical from outside; alerting on silence produced false alarms. Silence is
    normal, so silence is silent.

WHY THE EVENT DATABASE
    Cline writes an append-only SQLite event log under
    ``%USERPROFILE%\\.cline\\data\\db\\hub-events-*.db``. This tool opens the newest database
    read-only and follows ``sequence``. Nothing here calls a model or the network.

USAGE
    python cline_notify.py --follow     resident process
    python cline_notify.py --once       one pass (debug)
    python cline_notify.py --replay     dry run: how many toasts would history produce
    python cline_notify.py --test       one toast, then exit

FILES
    config.json                  hub_db / toast_ps1 / log_dir / poll_interval_s
    logs/state_notify.json       cursor: last hub_events.sequence + announced keys
    logs/events_notify.jsonl     append-only evidence
    logs/toast_notify.log        one line per toast attempt
"""
from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import time

try:
    sys.stdout.reconfigure(errors="replace")
    sys.stderr.reconfigure(errors="replace")
except (AttributeError, ValueError):
    pass

HERE = os.path.dirname(os.path.abspath(__file__))
CONFIG = os.path.join(HERE, "config.json")

DEFAULTS = {
    "hub_db": "",
    "toast_ps1": "",
    "log_dir": "",
    "poll_interval_s": 2.0,
    "parked_after_s": 60,
    "fast_tools": {"ask_question": 15},
    "hung_after_s": 1800,
    "toast_aumid": "",
    "toast_sound": "",
}
CFG = dict(DEFAULTS)
try:
    with open(CONFIG, "r", encoding="utf-8-sig") as fh:
        CFG.update(json.load(fh))
except (OSError, ValueError):
    pass


def _path_setting(key, fallback):
    """Expand a configured path; an empty value means 'next to this script'."""
    value = CFG.get(key) or ""
    value = os.path.expandvars(os.path.expanduser(str(value)))
    if not value:
        return fallback
    if not os.path.isabs(value):
        value = os.path.join(HERE, value)
    return os.path.abspath(value)


def _resolve_db():
    """Configured path if it exists, else auto-detect the newest event DB."""
    p = _path_setting("hub_db", "")
    if p and os.path.exists(p):
        return p
    import glob as _glob
    cands = [f for f in _glob.glob(os.path.expanduser(r"~\.cline\data\db\hub-events-*.db"))]
    if not cands:
        return p
    return max(cands, key=os.path.getmtime)


DB = _resolve_db()
TOAST = _path_setting("toast_ps1", os.path.join(HERE, "toast.ps1"))
LOGDIR = _path_setting("log_dir", os.path.join(HERE, "logs"))
STATE = os.path.join(LOGDIR, "state_notify.json")
EVENTS = os.path.join(LOGDIR, "events_notify.jsonl")
TOASTLOG = os.path.join(LOGDIR, "toast_notify.log")
POWERSHELL = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"),
                          r"System32\WindowsPowerShell\v1.0\powershell.exe")

_db_fail = 0        # consecutive DB read failures (rate-limited logging)


def now():
    return time.strftime("%Y-%m-%d %H:%M:%S")


def load_state():
    try:
        with open(STATE, "r", encoding="utf-8") as fh:
            st = json.load(fh)
    except (OSError, ValueError):
        st = {}
    st.setdefault("seq", 0)
    st.setdefault("announced", [])
    st.setdefault("pending", {})
    st.setdefault("last_event_ms", 0)
    st.setdefault("run_active", False)
    st.setdefault("run_id", None)
    st.setdefault("db_path", "")
    st.setdefault("run_id_from_started", False)
    return st


def save_state(st):
    os.makedirs(LOGDIR, exist_ok=True)
    st["announced"] = st["announced"][-100:]
    tmp = STATE + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(st, fh)
    os.replace(tmp, STATE)
    # heartbeat: lets an external guard tell "dead" from "just quiet" without guessing
    try:
        with open(os.path.join(LOGDIR, "heartbeat.json"), "w", encoding="utf-8") as fh:
            json.dump({"ts": time.time(), "pid": os.getpid(), "seq": st["seq"],
                       "db_fail": _db_fail}, fh)
    except OSError:
        pass


def append(obj):
    os.makedirs(LOGDIR, exist_ok=True)
    with open(EVENTS, "a", encoding="utf-8") as fh:
        fh.write(json.dumps(obj, ensure_ascii=False) + "\n")


def notify(title, body):
    os.makedirs(LOGDIR, exist_ok=True)
    msg = os.path.join(LOGDIR, "_toast_msg.txt")
    with open(msg, "w", encoding="utf-8") as fh:
        fh.write(title + "\n" + body + "\n")
    try:
        cmd = [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass",
               "-File", TOAST, "-TextFile", msg, "-LogFile", TOASTLOG]
        if CFG.get("toast_aumid"):
            cmd += ["-AppId", str(CFG["toast_aumid"])]
        if CFG.get("toast_sound"):
            sound = os.path.expandvars(os.path.expanduser(str(CFG["toast_sound"])))
            cmd += ["-SoundFile", sound]
        return subprocess.call(cmd, timeout=30)
    except Exception:
        return 1


def read_turns(st):
    """New rows since the cursor: turn ends (agent.done) and tool start/finish (for the parked rule)."""
    global _db_fail
    out = []

    # Resolve on EVERY read, not once at import: Cline creates a new
    # hub-events-*.db when the database is replaced, and --follow must follow it.
    db = _resolve_db()
    old_db = st.get("db_path") or ""
    db_changed = bool(old_db) and db != old_db
    if db_changed:
        print("%s DB SWITCH %s" % (now(), db), flush=True)
        st["seq"] = 0
        st["announced"] = []
        st["pending"] = {}
        st["run_id"] = None
        st["run_active"] = False
        st["last_event_ms"] = 0
        st["run_id_from_started"] = False

    started_run = bool(st.get("run_id_from_started", False))
    terminal_seen = False
    try:
        con = sqlite3.connect("file:%s?mode=ro" % db.replace("\\", "/"), uri=True, timeout=5)
        if db_changed:
            # A new database may already contain many finished turns.  Adopt
            # its current maximum as the baseline (the same silence as a first
            # start); only rows written after the switch can notify.
            max_seq = con.execute(
                "select coalesce(max(sequence), 0) from hub_events").fetchone()[0]
            st["seq"] = int(max_seq)
        st["db_path"] = db
        rows = list(con.execute(
            "select sequence, event, created_at, envelope_json from hub_events "
            "where sequence > ? and event in "
            "('agent.done','run.started','run.failed','run.aborted','run.completed',"
            "'tool.started','tool.updated','tool.finished') "
            "order by sequence limit 400", (st["seq"],)))
        con.close()
        _db_fail = 0
    except Exception as exc:
        # A silent reader is a silent notifier.  Log the first failure, then every 30th, so a
        # broken DB is diagnosable without flooding the log (a poll runs every 2 s).
        _db_fail += 1
        if _db_fail == 1 or _db_fail % 30 == 0:
            print("%s DB READ FAILED (%d) %s: %s"
                  % (now(), _db_fail, type(exc).__name__, exc), flush=True)
        return out
    for seq, ev, created, env in rows:
        st["seq"] = seq
        st["last_event_ms"] = created
        try:
            p = json.loads(env).get("payload") or {}
            if not isinstance(p, dict):
                p = {}
        except Exception:
            p = {}
        if ev == "run.started":
            st["run_id"] = created            # a new turn: fresh key for its terminal event
            st["run_active"] = True
            st["pending"] = {}
            st["run_id_from_started"] = True
            started_run = True
            continue
        if ev == "tool.started":
            tid = p.get("toolCallId")
            if tid:
                st["pending"][tid] = {"ts": created, "prog": created,
                                      "name": p.get("toolName")}
            continue
        if ev == "tool.updated":
            # progress on a long-running tool (Lumerical / MCP): it is ALIVE, not parked.
            tid = p.get("toolCallId")
            if tid and tid in st["pending"]:
                st["pending"][tid]["prog"] = created
            continue
        if ev == "tool.finished":
            st["pending"].pop(p.get("toolCallId"), None)
            continue

        st["pending"] = {}                     # a terminal event means nothing is parked any more
        st["run_active"] = False
        terminal_seen = True
        # A terminal sibling (run.completed + agent.done) shares the run id set by
        # run.started. With NO run.started, every terminal is an orphan and gets
        # its own id. A no-start run that emits two siblings may produce two
        # toasts; that is the safer failure mode than silence.
        if not started_run or st.get("run_id") is None:
            st["run_id"] = created
        result = p.get("result") or {}
        text = p.get("text") or (result.get("text") if isinstance(result, dict) else "") or ""
        if not isinstance(text, str):
            text = str(text)
        err = p.get("error") or ""
        if not isinstance(err, str):
            err = str(err)
        reason = p.get("reason") or ""
        if not isinstance(reason, str):
            reason = str(reason)
        reason = reason.lower()
        if ev == "agent.done" and not reason:
            reason = "completed"
        last = ""
        for line in reversed([l.strip() for l in text.splitlines() if l.strip()]):
            last = line
            break
        if last[:1] in ("#", "|", "`", ">", "-"):
            last = ""            # markdown furniture carries no information
        if err:
            detail = "error: %s" % str(err)[:120]
        elif last:
            detail = last[:140]
        else:
            detail = "reason=%s" % (reason or ev)
        # ONE notification per run: agent.done / run.completed / run.aborted / run.failed are
        # siblings of the same turn (2026-11-01: token exhaustion emitted run.failed with NO
        # agent.done at all, which the old agent.done-only rule missed completely).
        out.append({"key": "run:%d" % st["run_id"], "kind": "TURN",
                    "reason": reason or ev, "last": detail[:140]})
    if terminal_seen and started_run:
        # The run.started id has now covered this run's terminal siblings; a
        # later terminal without a new run.started gets its own id.
        st["run_id_from_started"] = False
    return out


def check_hung(st, now_ms, out):
    """A run that started and never produced ANY terminal event = the process died silently.

    Distinct from the parked rule (that one has a tool open).  Threshold is deliberately long:
    the longest legitimate quiet inside a live run is a 600 s MCP call, and tools emit progress.
    """
    if not st.get("run_active"):
        return
    limit = float(CFG.get("hung_after_s", 1800)) * 1000.0
    silent = now_ms - max(st.get("last_event_ms", 0), 1)
    if silent < limit:
        return
    key = "hung:%d" % (st.get("run_id") or 0)
    out.append({"key": key, "kind": "TURN", "reason": "no-activity",
                "last": "run never ended; no events for %d min" % int(silent / 60000)})


def check_parked(st, now_ms, out):
    """A tool that started and never finished = Cline is parked on you (approval prompt / question).

    Guards against stale records (a leftover `ask_question` from an aborted run can otherwise
    produce a phantom "waiting" toast right after a restart):
      * only the NEWEST open call is considered;
      * nothing may have happened after it started (last_event_ms == its start);
      * it must be younger than max_age_ms.
    Silence alone never notifies -- that was the false-alarm source.
    """
    pending = st.get("pending") or {}
    if not pending:
        return
    max_age = 30 * 60 * 1000.0
    for tid, rec in list(pending.items()):
        if now_ms - rec.get("prog", rec["ts"]) > max_age:   # ancient leftover: forget it
            pending.pop(tid, None)
    if not pending:
        return
    tid = max(pending, key=lambda k: pending[k].get("prog", pending[k]["ts"]))
    rec = pending[tid]
    age = now_ms - rec.get("prog", rec["ts"])      # silence since the LAST progress update
    # Per-tool threshold: tools that inherently wait for a human (ask_question) get a short one;
    # ordinary tools get a long one, because a legitimate command can run up to the 30 s tool cap
    # (measured p99 = 30.6 s) and must never look like "parked".
    fast = CFG.get("fast_tools") or {}
    limit = float(fast.get(rec.get("name") or "", CFG["parked_after_s"])) * 1000.0
    if age < limit or age > max_age:
        return
    if st.get("last_event_ms", 0) > rec.get("prog", rec["ts"]) + 2000:
        return                                    # something happened after it -> not parked
    out.append({"key": "parked:" + tid, "kind": "PARKED", "reason": "waiting-for-you",
                "last": "tool %s pending %d s" % (rec.get("name") or "?", int(age / 1000))})


def poll(allow_toast=True, initial=False):
    st = load_state()
    if initial:                        # first start: swallow history, announce nothing
        while True:
            before = st["seq"]
            read_turns(st)
            if st["seq"] == before:
                break
        st["pending"] = {}
        st["last_event_ms"] = int(time.time() * 1000)
        save_state(st)
        return []

    fired = []
    out = read_turns(st)
    check_parked(st, int(time.time() * 1000), out)
    check_hung(st, int(time.time() * 1000), out)
    for t in out:
        if t["key"] in st["announced"]:
            continue
        st["announced"].append(t["key"])
        if t.get("kind") == "PARKED":
            title = "Cline needs you"                      # approval prompt / question
            body = "%s\n%s" % (now(), t["last"])
        else:
            title = "Cline needs you"                      # one title for every case
            body = "%s\nreason=%s%s" % (now(), t["reason"],
                                        ("\n" + t["last"]) if t["last"] else "")
        ev = {"ts": now(), "key": t["key"], "kind": t.get("kind"), "reason": t["reason"],
              "last": t["last"]}
        ev["toast_rc"] = notify(title, body) if allow_toast else None
        append(ev)
        fired.append(ev)
    save_state(st)
    return fired


def replay():
    st = {"seq": 0, "announced": [], "pending": {}, "last_event_ms": 0,
          "run_active": False, "run_id": None, "db_path": "",
          "run_id_from_started": False}
    n = 0
    while True:
        before = st["seq"]
        for t in read_turns(st):
            if t["key"] in st["announced"]:
                continue
            st["announced"].append(t["key"])
            n += 1
            print("  %-9s %s" % (t["reason"],
                                 t["last"][:70].encode("ascii", "replace").decode()))
        if st["seq"] == before:
            break
    print("total turn-end toasts in history = %d" % n)
    return 0


def main():
    args = sys.argv[1:]
    if "--test" in args:
        print("test toast rc=%s" % notify("Cline needs you", "self-test\n" + now()))
        return 0
    if "--replay" in args:
        return replay()

    first = not os.path.exists(STATE)
    if "--once" in args:
        events = poll(True, first)
        for e in events:
            print("%s %-9s toast_rc=%s  %s" % (e["ts"], e["reason"], e["toast_rc"], e["last"][:60]))
        if not events:
            print("%s no verdict" % now())
        return 2 if _db_fail else 0

    interval = float(CFG["poll_interval_s"])
    # startup self-check: a watcher that cannot work must say so, not sit there silently
    db_now = _resolve_db()
    problems = []
    if not os.path.exists(db_now):
        problems.append("db missing: " + db_now)
    if not os.path.exists(TOAST):
        problems.append("toast.ps1 missing: " + TOAST)
    print("%s STARTED pid=%d db=%s %s" % (now(), os.getpid(), db_now,
                                         ("PROBLEMS: " + "; ".join(problems)) if problems else "ok"),
          flush=True)
    print("%s follow, poll %.1fs, first=%s" % (now(), interval, first), flush=True)
    while True:
        try:
            for e in poll(True, first):
                print("%s %-9s toast_rc=%s" % (e["ts"], e["reason"], e["toast_rc"]), flush=True)
            first = False
        except Exception as exc:
            print("%s ERROR %s: %s" % (now(), type(exc).__name__, exc), flush=True)
        time.sleep(interval)


if __name__ == "__main__":
    raise SystemExit(main())
