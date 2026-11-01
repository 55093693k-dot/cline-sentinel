"""Sandbox tests for cline_notify.py: fake SQLite database, no toast, no real Cline data."""
import contextlib
import copy
import importlib.util
import io
import json
import os
import sqlite3
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("cline_notify", ROOT / "cline_notify.py")
notifier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(notifier)


class NotifierTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.logs = self.dir / "logs"
        self.logs.mkdir()
        self.db_path = self.dir / "hub-events-test.db"
        self.con = sqlite3.connect(str(self.db_path))
        self.con.execute(
            "create table hub_events (sequence integer primary key autoincrement, "
            "event text not null, session_id text, envelope_json text not null, "
            "created_at integer not null)"
        )
        self.con.commit()
        self.now = int(time.time() * 1000)

        notifier.DB = str(self.db_path)
        self._orig_resolve_db = notifier._resolve_db
        notifier._resolve_db = lambda: str(self.db_path)
        notifier.LOGDIR = str(self.logs)
        notifier.STATE = str(self.logs / "state_notify.json")
        notifier.EVENTS = str(self.logs / "events_notify.jsonl")
        notifier.TOASTLOG = str(self.logs / "toast_notify.log")
        notifier.TOAST = str(self.dir / "missing-toast.ps1")
        notifier.CFG = copy.deepcopy(notifier.DEFAULTS)
        notifier._db_fail = 0

    def tearDown(self):
        self.con.close()
        notifier._resolve_db = self._orig_resolve_db
        self.tmp.cleanup()

    def add(self, event, payload=None, when_ms=None):
        self.con.execute(
            "insert into hub_events(event, session_id, envelope_json, created_at) "
            "values (?, ?, ?, ?)",
            (event, "test-session",
             json.dumps({"payload": payload or {}}, ensure_ascii=False),
             self.now if when_ms is None else when_ms),
        )
        self.con.commit()

    def poll(self, initial=False):
        return notifier.poll(allow_toast=False, initial=initial)

    def test_agent_done_fires_once(self):
        self.add("run.started", when_ms=self.now - 3000)
        self.add("agent.done", {"reason": "completed", "text": "finished"}, self.now - 1000)
        self.assertEqual(len(self.poll()), 1)
        self.assertEqual(self.poll(), [])

    def test_run_failed_without_agent_done(self):
        self.add("run.started", when_ms=self.now - 3000)
        self.add("run.failed", {"error": "quota exhausted", "reason": "error"}, self.now - 1000)
        events = self.poll()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["reason"], "error")

    def test_aborted_plus_agent_done_is_one(self):
        self.add("run.started", when_ms=self.now - 3000)
        self.add("run.aborted", {"reason": "aborted"}, self.now - 2000)
        self.add("agent.done", {"reason": "aborted"}, self.now - 1000)
        self.assertEqual(len(self.poll()), 1)

    def test_completed_plus_agent_done_is_one(self):
        self.add("run.started", when_ms=self.now - 3000)
        self.add("run.completed", {"reason": "completed"}, self.now - 2000)
        self.add("agent.done", {"reason": "completed"}, self.now - 1000)
        self.assertEqual(len(self.poll()), 1)

    def test_two_orphan_terminals_are_both_announced(self):
        # No run.started: two same-type terminals are two separate lost turns,
        # not one run's sibling pair.
        self.add("agent.done", {"reason": "completed", "text": "first"}, self.now - 3000)
        self.add("agent.done", {"reason": "completed", "text": "second"}, self.now - 1000)
        self.assertEqual(len(self.poll()), 2)

    def test_two_orphan_terminals_of_different_types_are_both_announced(self):
        self.add("run.completed", {"reason": "completed", "result": {"text": "first"}},
                 self.now - 3000)
        self.add("agent.done", {"reason": "completed", "text": "second"}, self.now - 1000)
        self.assertEqual(len(self.poll()), 2)

    def test_hung_run_after_33_minutes(self):
        self.add("run.started", when_ms=self.now - 33 * 60 * 1000)
        events = self.poll()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["reason"], "no-activity")

    def test_quiet_run_after_5_minutes_is_negative(self):
        self.add("run.started", when_ms=self.now - 5 * 60 * 1000)
        self.assertEqual(self.poll(), [])

    def test_ask_question_parked_20_seconds(self):
        self.add("run.started", when_ms=self.now - 30 * 1000)
        self.add("tool.started", {"toolCallId": "q1", "toolName": "ask_question"},
                 self.now - 20 * 1000)
        events = self.poll()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["kind"], "PARKED")

    def test_normal_tool_20_seconds_is_negative(self):
        self.add("run.started", when_ms=self.now - 30 * 1000)
        self.add("tool.started", {"toolCallId": "c1", "toolName": "run_commands"},
                 self.now - 20 * 1000)
        self.assertEqual(self.poll(), [])

    def test_normal_tool_65_seconds_is_parked(self):
        self.add("run.started", when_ms=self.now - 90 * 1000)
        self.add("tool.started", {"toolCallId": "c1", "toolName": "run_commands"},
                 self.now - 65 * 1000)
        events = self.poll()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["kind"], "PARKED")

    def test_long_tool_with_recent_progress_is_negative(self):
        self.add("run.started", when_ms=self.now - 620 * 1000)
        self.add("tool.started", {"toolCallId": "m1", "toolName": "mcp_call"},
                 self.now - 600 * 1000)
        self.add("tool.updated", {"toolCallId": "m1", "toolName": "mcp_call"},
                 self.now - 5 * 1000)
        self.assertEqual(self.poll(), [])

    def test_stale_open_call_is_forgotten(self):
        self.add("run.started", when_ms=self.now - 3600 * 1000)
        self.add("tool.started", {"toolCallId": "old", "toolName": "run_commands"},
                 self.now - 3000 * 1000)
        self.add("tool.updated", {"toolCallId": "new", "toolName": "other_tool"},
                 self.now - 5 * 1000)
        self.assertEqual(self.poll(), [])

    def test_first_start_swallows_history(self):
        self.add("run.started", when_ms=self.now - 3000)
        self.add("agent.done", {"reason": "completed"}, self.now - 1000)
        self.assertEqual(self.poll(initial=True), [])
        self.assertEqual(self.poll(), [])

    def test_replay_handles_tool_events(self):
        self.add("run.started", when_ms=self.now - 5000)
        self.add("tool.started", {"toolCallId": "t1", "toolName": "run_commands"},
                 self.now - 4000)
        self.add("tool.finished", {"toolCallId": "t1", "toolName": "run_commands"},
                 self.now - 3000)
        self.add("agent.done", {"reason": "completed"}, self.now - 1000)
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = notifier.replay()
        self.assertEqual(rc, 0)
        self.assertIn("total turn-end toasts in history = 1", buf.getvalue())

    def test_blank_paths_mean_next_to_the_script(self):
        notifier.CFG["log_dir"] = ""
        notifier.CFG["toast_ps1"] = ""
        self.assertEqual(notifier._path_setting("log_dir", "fallback"), "fallback")
        self.assertEqual(notifier._path_setting("toast_ps1", "toast.ps1"), "toast.ps1")
        notifier.CFG["log_dir"] = "logs"
        self.assertEqual(notifier._path_setting("log_dir", "fallback"),
                         os.path.join(notifier.HERE, "logs"))

    def test_missing_database_does_not_crash(self):
        self.con.close()
        os.remove(self.db_path)
        self.assertEqual(self.poll(), [])

    def test_database_switch_is_followed(self):
        self.add("run.started", when_ms=self.now - 3000)
        self.add("agent.done", {"reason": "completed", "text": "old"}, self.now - 1000)
        self.assertEqual(len(self.poll()), 1)

        new_path = self.dir / "hub-events-new.db"
        con = sqlite3.connect(str(new_path))
        con.execute(
            "create table hub_events (sequence integer primary key autoincrement, "
            "event text not null, session_id text, envelope_json text not null, "
            "created_at integer not null)"
        )
        con.execute(
            "insert into hub_events(event, session_id, envelope_json, created_at) "
            "values (?, ?, ?, ?)",
            ("run.started", "test-session",
             json.dumps({"payload": {}}, ensure_ascii=False), self.now - 1000))
        con.execute(
            "insert into hub_events(event, session_id, envelope_json, created_at) "
            "values (?, ?, ?, ?)",
            ("agent.done", "test-session",
             json.dumps({"payload": {"reason": "completed", "text": "new"}},
                        ensure_ascii=False), self.now))
        con.commit()
        con.close()
        notifier._resolve_db = lambda: str(new_path)
        events = self.poll()
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["last"], "new")

    def test_heartbeat_records_database_failure(self):
        self.con.close()
        os.remove(self.db_path)
        self.poll()
        hb = json.loads((self.logs / "heartbeat.json").read_text(encoding="utf-8"))
        self.assertGreaterEqual(hb["db_fail"], 1)

    def test_once_returns_nonzero_when_database_is_unreadable(self):
        self.con.close()
        os.remove(self.db_path)
        old_argv = sys.argv
        sys.argv = ["cline_notify.py", "--once"]
        try:
            with contextlib.redirect_stdout(io.StringIO()):
                rc = notifier.main()
        finally:
            sys.argv = old_argv
        self.assertEqual(rc, 2)


if __name__ == "__main__":
    unittest.main()

