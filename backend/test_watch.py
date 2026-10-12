"""Synthetic, local-only acceptance checks for the secret-free watch surface."""
import concurrent.futures
import contextlib
from datetime import datetime, timedelta, timezone
import hashlib
import http.client
import json
import os
from pathlib import Path
import re
import sqlite3
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock
import uuid

from common import APIError, timestamp
from server import Server, Store


class WatchTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "watch fixture.sqlite3"
        self.date = datetime(2026, 10, 3, tzinfo=timezone.utc)
        self.store = Store(self.path, clock=lambda: timestamp(self.date))
        self.tokens = {mid: self.store.add_member(mid, name, role) for mid, name, role in
                       [("user", "用户", "admin"), ("leader", "Leader", "leader"),
                        ("b", "Worker B", "worker"), ("c", "Worker C", "worker")]}
        self.actors = {mid: self.store.authenticate("Bearer " + token) for mid, token in self.tokens.items()}
        with self.store.connection() as db:
            self.workspace = db.execute("SELECT value FROM sync_meta WHERE key='workspace_id'").fetchone()[0]
        self.route = "/v1/watch?workspace=" + self.workspace
        self.server = Server(("127.0.0.1", 0), self.store, public_watch=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.temp.cleanup()

    def request(self, path=None, method="GET", headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        started = time.perf_counter()
        connection.request(method, self.route if path is None else path, headers=headers or {})
        response = connection.getresponse()
        raw = response.read()
        result = response.status, json.loads(raw) if raw else None, dict(response.getheaders()), time.perf_counter() - started
        connection.close()
        return result

    def read(self):
        status, value, _, _ = self.request()
        self.assertEqual(status, 200)
        return value

    def send(self, path, data, actor="leader", key=None):
        return self.store.mutate(self.actors[actor], path, data, key or uuid.uuid4().hex)[1]

    def create(self, owner="b"):
        return self.send("/v1/tasks", {"title": "PRIVATE task title", "ownerId": owner,
                                     "details": "PRIVATE task body", "source": "leader"})["task"]

    def update(self, task, kind="progress", actor="b", **fields):
        return self.send(f"/v1/tasks/{task['id']}/updates",
                         {"version": task["version"], "kind": kind, "body": "PRIVATE task progress", **fields}, actor)["task"]

    @staticmethod
    def counts(value):
        return {key: value[key] for key in ("tasks", "auths", "alerts", "messages")}

    def assert_changed_same_counts(self, previous):
        current = self.read()
        self.assertNotEqual(current["cursor"], previous["cursor"])
        self.assertEqual(self.counts(current), self.counts(previous))
        return current

    def test_opt_in_default_404_independent_of_public_signal(self):
        self.assertFalse(Server.__init__.__defaults__[-1])
        self.server.public_watch = False
        self.server.public_signal = True
        disabled = self.request()
        self.assertEqual(disabled[0], 404)
        self.assertEqual(disabled[2]["Cache-Control"], "no-store")
        self.assertEqual(self.request("/v1/watch")[0], 404)
        self.assertEqual(self.request("/v1/update-signal")[0], 200)
        self.server.public_watch = True
        self.assertEqual(self.request()[0], 200)
        self.server.public_signal = False
        self.assertEqual(self.request("/v1/update-signal")[0], 404)

    def test_exact_fields_no_bearer_no_private_content(self):
        self.create()
        self.send("/v1/messages", {"recipientId": "c", "body": "PRIVATE message"})
        self.assertEqual(self.request(headers={"Authorization": "Bearer deliberately-invalid"})[0], 401)
        status, value, headers, _ = self.request()
        self.assertEqual(status, 200)
        self.assertEqual(set(value), {"workspaceId", "cursor", "tasks", "auths", "alerts", "messages"})
        self.assertEqual(value["workspaceId"], self.workspace)
        self.assertEqual(self.counts(value), {"tasks": 1, "auths": 0, "alerts": 0, "messages": 1})
        self.assertTrue(re.fullmatch(r"[A-Za-z0-9_-]{32}", value["cursor"]))
        body = json.dumps(value)
        for private in ("PRIVATE", "token", "worker", "TASK-", *self.tokens.values()):
            self.assertNotIn(private, body)
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertTrue(headers["Content-Type"].startswith("application/json"))
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertNotIn("ETag", headers)
        self.assertEqual(self.request(headers={"If-None-Match": '"' + value["cursor"] + '"'})[0], 200)
        self.assertEqual(self.request("/v1/snapshot")[0], 401)

    def test_query_required_single_bounded_and_no_extra_fields(self):
        invalid = ["", "?workspace=", "?workspace", "?workspace=a&workspace=b",
                   "?workspace=" + self.workspace + "&cursor=x",
                   "?workspace=" + self.workspace + "&heartbeat=1",
                   "?workspace=" + self.workspace + "&extra=1",
                   "?workspace=" + self.workspace + "&extra=1&third=1",
                   "?Workspace=" + self.workspace, "?workspace=" + "x" * 65,
                   "?workspace=%2F", "?workspace=%20", "?workspace=%FF",
                   "?workspace=%", "?workspace=a;b=c"]
        for suffix in invalid:
            with self.subTest(suffix=suffix):
                status, _, headers, _ = self.request("/v1/watch" + suffix)
                self.assertEqual(status, 422)
                self.assertEqual(headers["Cache-Control"], "no-store")
        mismatch = self.request("/v1/watch?workspace=not-this-workspace")
        self.assertEqual(mismatch[0], 404)
        self.assertEqual(mismatch[1], {"error": "接口不存在"})

    def test_post_is_405_before_auth_and_does_not_write(self):
        before = self.path.read_bytes()
        for enabled in (True, False):
            self.server.public_watch = enabled
            status, _, headers, _ = self.request(method="POST")
            self.assertEqual(status, 405)
            self.assertEqual(headers["Allow"], "GET")
            self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(before, self.path.read_bytes())

    def test_reads_never_snapshot_poll_scan_authenticate_or_write(self):
        self.create()
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        with self.store.connection() as db:
            schema = db.execute("SELECT sql FROM sqlite_master ORDER BY name").fetchall()
            poll = db.execute("SELECT id,last_poll_at FROM members ORDER BY id").fetchall()
        with mock.patch.object(self.store, "snapshot", side_effect=AssertionError("snapshot used")), \
             mock.patch.object(self.store, "snapshot_in", side_effect=AssertionError("full snapshot used")), \
             mock.patch.object(self.store, "poll", side_effect=AssertionError("heartbeat used")), \
             mock.patch.object(self.store, "scan", side_effect=AssertionError("scanner used")), \
             mock.patch.object(self.store, "authenticate", side_effect=AssertionError("auth used")), \
             mock.patch.object(self.store, "connection", side_effect=AssertionError("10 s connection used")):
            first = self.read()
            for _ in range(10):
                self.assertEqual(self.read(), first)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before)
        with self.store.connection() as db:
            self.assertEqual(db.execute("SELECT sql FROM sqlite_master ORDER BY name").fetchall(), schema)
            self.assertEqual(db.execute("SELECT id,last_poll_at FROM members ORDER BY id").fetchall(), poll)
            self.assertEqual(db.execute("SELECT count(*) FROM sync_cursors").fetchone()[0], 0)
        self.assertFalse(Path(str(self.path) + "-journal").exists())

    def test_task_content_and_state_rotate_cursor_with_unchanged_total(self):
        previous = self.read()
        task = self.create()
        current = self.read()
        self.assertNotEqual(previous["cursor"], current["cursor"])
        self.assertEqual(current["tasks"], 1)
        task = self.update(task, "accepted")
        current = self.assert_changed_same_counts(current)
        self.update(task)
        self.assert_changed_same_counts(current)

    def test_authorization_decision_rotates_same_count(self):
        task = self.create()
        before = self.read()
        authorization = self.send("/v1/authorizations", {"taskId": task["id"], "kind": "normal",
                                    "subject": "PRIVATE authorization", "reason": "PRIVATE reason"}, "b")["authorization"]
        current = self.read()
        self.assertEqual(current["auths"], 1)
        self.assertNotEqual(current["cursor"], before["cursor"])
        self.send(f"/v1/authorizations/{authorization['id']}/decision",
                  {"version": authorization["version"], "action": "approved", "note": "PRIVATE decision"})
        self.assert_changed_same_counts(current)

    def test_alert_acknowledge_and_resolve_rotate_total_history_count(self):
        task = self.update(self.create(), "accepted")
        before = self.read()
        self.update(task, "blocked", severity="red")
        current = self.read()
        self.assertEqual(current["alerts"], 1)
        self.assertNotEqual(current["cursor"], before["cursor"])
        with self.store.connection() as db:
            alert = dict(db.execute("SELECT * FROM alerts").fetchone())
        self.send(f"/v1/alerts/{alert['id']}/actions",
                  {"version": alert["version"], "action": "acknowledge", "note": "PRIVATE acknowledgement"})
        current = self.assert_changed_same_counts(current)
        self.send(f"/v1/alerts/{alert['id']}/actions",
                  {"version": alert["version"] + 1, "action": "resolve", "note": "PRIVATE resolution"})
        self.assert_changed_same_counts(current)

    def test_message_read_rotates_cursor_without_unread_count_semantics(self):
        before = self.read()
        message = self.send("/v1/messages", {"recipientId": "b", "body": "PRIVATE message"})
        current = self.read()
        self.assertEqual(current["messages"], 1)
        self.assertNotEqual(current["cursor"], before["cursor"])
        self.send(f"/v1/messages/{message['id']}/read", {}, "b")
        self.assert_changed_same_counts(current)

    def test_watch_cursor_separate_from_member_sync_and_quiet_auth_reads(self):
        watch = self.read()
        first = self.store.incremental(self.actors["b"])
        self.assertNotEqual(first["new_cursor"], watch["cursor"])
        self.assertEqual(self.read(), watch)
        self.assertEqual(self.store.incremental(self.actors["b"], first["new_cursor"])["items"], [])
        with self.assertRaises(APIError) as error:
            self.store.incremental(self.actors["b"], watch["cursor"])
        self.assertEqual(error.exception.status, 410)
        self.store.snapshot(self.actors["leader"])
        self.assertEqual(self.read(), watch)

    def test_authenticated_heartbeat_and_quiet_checker_do_not_cause_wake_loop(self):
        self.send("/v1/members/me/participation", {"state": "active", "heartbeatMode": "event_driven", "reason": "sentinel"}, "b")
        watch = self.read()
        for _ in range(3):
            self.date += timedelta(minutes=1)
            self.store.poll(self.actors["b"])
            self.store.scan()
            self.assertEqual(self.read(), watch)
        self.date += timedelta(hours=4)
        self.store.scan()
        self.assertEqual(self.read(), watch)

    def test_real_alert_transition_rotates_but_watch_does_not_run_clock_checks(self):
        self.update(self.create(), "accepted")
        before = self.read()
        self.date += timedelta(hours=2)
        self.assertEqual(self.read(), before)
        self.store.scan()
        changed = self.read()
        self.assertNotEqual(changed["cursor"], before["cursor"])
        self.assertEqual(changed["alerts"], 1)
        self.store.scan()
        self.assertEqual(self.read(), changed)

    def test_announcements_quota_and_rules_also_rotate_global_signal(self):
        before = self.read()
        self.send("/v1/announcements", {"title": "PRIVATE notice", "body": "PRIVATE announcement"})
        before = self.assert_changed_same_counts(before)
        self.send("/v1/members/me/quota", {"note": "PRIVATE remaining quota", "budgetGroup": "PRIVATE group"}, "c")
        before = self.assert_changed_same_counts(before)
        self.send("/v1/rules", {"version": 1, "staleYellowSeconds": 3600, "reason": "PRIVATE changed rule"})
        self.assert_changed_same_counts(before)

    def test_failed_write_and_idempotent_replay_keep_cursor(self):
        data = {"title": "PRIVATE replay fixture", "ownerId": "b"}
        key = uuid.uuid4().hex
        self.send("/v1/tasks", data, key=key)
        before = self.read()
        self.send("/v1/tasks", data, key=key)
        self.assertEqual(self.read(), before)
        with self.assertRaises(APIError):
            self.send("/v1/tasks", {"title": "PRIVATE", "ownerId": "missing"})
        self.assertEqual(self.read(), before)

    def test_cursor_persists_server_restart_and_workspace_rebuild_differs(self):
        before = self.read()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)
        self.store = Store(self.path, clock=lambda: timestamp(self.date))
        self.server = Server(("127.0.0.1", 0), self.store, public_watch=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()
        self.assertEqual(self.read(), before)
        replacement = Store(Path(self.temp.name) / "other.sqlite3")
        self.assertNotEqual(replacement.signal(), before["cursor"])
        with self.assertRaises(APIError) as error:
            replacement.watch(self.workspace)
        self.assertEqual(error.exception.status, 404)

    def test_database_lock_has_bounded_503_and_recovers(self):
        with contextlib.closing(sqlite3.connect(self.path, isolation_level=None)) as blocked:
            blocked.execute("BEGIN EXCLUSIVE")
            status, body, headers, elapsed = self.request()
            self.assertEqual(status, 503)
            self.assertEqual(headers["Cache-Control"], "no-store")
            self.assertEqual(set(body), {"error"})
            self.assertLess(elapsed, 0.5)
            blocked.execute("ROLLBACK")
        self.assertEqual(self.request()[0], 200)

    def test_missing_database_503_never_creates_new_file(self):
        missing = Path(self.temp.name) / "uncreated.sqlite3"
        original = self.store.path
        try:
            self.store.path = str(missing)
            self.assertEqual(self.request()[0], 503)
            self.assertFalse(missing.exists())
        finally:
            self.store.path = original

    def test_atomic_snapshot_during_concurrent_commits(self):
        # Synthetic atomic counter+signal writes isolate snapshot coherence,
        # rather than comparing independently read application snapshots.
        with self.store.connection() as db:
            db.execute("UPDATE sync_meta SET value='fixture-0' WHERE key='signal'")
        failures = []
        def writer():
            try:
                with self.store.connection() as db:
                    for sequence in range(1, 41):
                        db.execute("BEGIN IMMEDIATE")
                        db.execute("INSERT INTO messages(sender_id,sender_name,recipient_id,body,created_at) VALUES('leader','Leader','b','PRIVATE',?)", (timestamp(self.date),))
                        db.execute("UPDATE sync_meta SET value=? WHERE key='signal'", (f"fixture-{sequence}",))
                        db.execute("COMMIT")
            except Exception as error:
                failures.append(error)
        writer_thread = threading.Thread(target=writer)
        writer_thread.start()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as readers:
            responses = list(readers.map(lambda _: self.request(), range(80)))
        writer_thread.join(timeout=5)
        self.assertFalse(writer_thread.is_alive())
        self.assertEqual(failures, [])
        for status, value, _, _ in responses:
            self.assertEqual(status, 200)
            self.assertEqual(value["messages"], int(value["cursor"].split("-")[1]))

    def test_representative_seeded_payload_performance(self):
        rows = 5000
        stamp = timestamp(self.date)
        # Large text fixture: SELECT COUNT(*) must not deserialize any bodies.
        body = "PRIVATE seeded payload " + "x" * 4000
        with self.store.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            db.executemany("""INSERT INTO tasks(id,title,owner_id,source,category,priority,status,details,acceptance,version,created_by,created_at,updated_at)
                VALUES(?,'PRIVATE','b','leader','other','normal','pending',?,'',1,'leader',?,?)""",
                           ((f"TASK-{n:06d}", body, stamp, stamp) for n in range(1, rows + 1)))
            db.executemany("""INSERT INTO authorization_requests(task_id,requester_id,kind,subject,reason,state,created_at,updated_at)
                VALUES(?,'b','normal','PRIVATE',?,'approved',?,?)""",
                           ((f"TASK-{n:06d}", body, stamp, stamp) for n in range(1, rows + 1)))
            db.executemany("""INSERT INTO alerts(dedup_key,kind,task_id,member_id,severity,title,detail,state,created_at,updated_at)
                VALUES(?,'blocked',?,'b','yellow','PRIVATE',?,'resolved',?,?)""",
                           ((f"fixture-{n}", f"TASK-{n:06d}", body, stamp, stamp) for n in range(1, rows + 1)))
            db.executemany("INSERT INTO messages(sender_id,sender_name,recipient_id,body,created_at) VALUES('leader','Leader','b',?,?)",
                           ((body, stamp) for _ in range(rows)))
            db.execute("COMMIT")
        baseline = self.read()
        self.assertEqual(self.counts(baseline), dict.fromkeys(("tasks", "auths", "alerts", "messages"), rows))
        responses = [self.request() for _ in range(20)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as readers:
            responses += list(readers.map(lambda _: self.request(), range(40)))
        for status, value, _, _ in responses:
            self.assertEqual(status, 200)
            self.assertEqual(value, baseline)
        durations = sorted(item[3] for item in responses)
        self.assertLess(durations[-1], 0.5)
        encoded = json.dumps(baseline, separators=(",", ":")).encode()
        self.assertLess(len(encoded), 256)
        print(f"WATCH_BENCH rows_per_collection={rows} samples={len(durations)} concurrent=4 bytes={len(encoded)} "
              f"median_ms={statistics.median(durations) * 1000:.3f} p95_ms={durations[int(len(durations) * .95)-1] * 1000:.3f} "
              f"max_ms={durations[-1] * 1000:.3f}", flush=True)

    def test_cli_flag_and_env_opt_in(self):
        for flag, environment, expected in [(False, "0", 404), (False, "1", 200), (True, "0", 200), (False, "true", 404)]:
            with self.subTest(flag=flag, environment=environment):
                command = [sys.executable, str(Path(__file__).with_name("server.py")), "--db", str(self.path), "serve", "--port", "0", "--check-seconds", "3600"]
                if flag:
                    command.append("--public-watch")
                env = dict(os.environ, COLLABDESK_PUBLIC_WATCH=environment)
                process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
                try:
                    line = process.stdout.readline()
                    port = int(re.search(r"127\.0\.0\.1:(\d+)", line)[1])
                    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                    connection.request("GET", self.route)
                    response = connection.getresponse()
                    response.read()
                    self.assertEqual(response.status, expected)
                    connection.close()
                finally:
                    process.terminate()
                    process.communicate(timeout=5)


if __name__ == "__main__":
    unittest.main(verbosity=2)
