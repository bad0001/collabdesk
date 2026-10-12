import concurrent.futures
import http.client
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
import uuid
from datetime import datetime, timedelta, timezone

import oversight
from common import APIError, timestamp
from server import SCHEMA, Server, Store, digest


class SyncTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.date = datetime(2026, 10, 1, tzinfo=timezone.utc)
        self.store = Store(Path(self.temp.name) / "sync.sqlite3", clock=lambda: timestamp(self.date))
        self.tokens = {m: self.store.add_member(m, m, r) for m, r in [("leader", "leader"), ("b", "worker"), ("c", "worker")]}
        self.actors = {m: self.store.authenticate("Bearer " + t) for m, t in self.tokens.items()}

    def tearDown(self):
        self.temp.cleanup()

    def send(self, path, data, actor="leader", key=None):
        return self.store.mutate(self.actors[actor], path, data, key or uuid.uuid4().hex)[1]

    def read(self, actor="b", cursor=None):
        return self.store.incremental(self.actors[actor], cursor)

    def create(self, owner="b"):
        return self.send("/v1/tasks", {"title": "Scoped task " + owner, "ownerId": owner, "source": "user"})["task"]

    def update(self, task, actor="b", **kw):
        return self.send(f"/v1/tasks/{task['id']}/updates", {"version": task["version"], "kind": "progress", "body": "recorded work", **kw}, actor)["task"]

    def assert_error(self, status, fn):
        with self.assertRaises(APIError) as ctx:
            fn()
        self.assertEqual(ctx.exception.status, status)

    def test_bootstrap_scope_and_quiet_cursor(self):
        task = self.create(); self.create("c")
        first = self.read()
        self.assertTrue(first["reset"])
        self.assertEqual(first["workspaceId"], self.store.snapshot(self.actors["b"])["workspaceId"])
        self.assertEqual([i["value"]["id"] for i in first["items"] if i["collection"] == "tasks"], [task["id"]])
        self.assertNotIn("token_hash", json.dumps(first))
        self.assertNotIn("Scoped task c", json.dumps(first))
        quiet = self.read(cursor=first["new_cursor"])
        self.assertFalse(quiet["reset"])
        self.assertEqual(quiet["items"], [])
        self.assertEqual(first["new_cursor"], quiet["new_cursor"])
        self.assertEqual(first["workspaceId"], quiet["workspaceId"])

    def test_workspace_identity_persists_restart_and_changes_on_rebuild(self):
        workspace = self.read()["workspaceId"]
        self.store = Store(self.store.path, clock=lambda: timestamp(self.date))
        self.assertEqual(self.read()["workspaceId"], workspace)
        replacement = Store(Path(self.temp.name) / "replacement.sqlite3", clock=lambda: timestamp(self.date))
        token = replacement.add_member("b", "b", "worker")
        actor = replacement.authenticate("Bearer " + token)
        self.assertNotEqual(replacement.incremental(actor)["workspaceId"], workspace)

    def test_coalesced_states_keep_every_audit_event_and_retry(self):
        first = self.read()
        task = self.update(self.update(self.create(), kind="accepted"))
        delta = self.read(cursor=first["new_cursor"])
        self.assertEqual([i["value"]["version"] for i in delta["items"] if i["collection"] == "tasks"], [task["version"]])
        self.assertEqual(len([i for i in delta["items"] if i["collection"] == "events"]), 3)
        self.assertEqual(delta["items"], self.read(cursor=first["new_cursor"])["items"])

    def test_handoff_tombstones_and_old_cursor_never_replays_private_body(self):
        task = self.create()
        before = self.read()
        self.update(task, actor="leader", kind="handoff", ownerId="c", body="Private handoff instruction")
        after = self.read(cursor=before["new_cursor"])
        self.assertTrue(any(i == {"collection": "tasks", "id": task["id"], "op": "delete"} for i in after["items"]))
        self.assertTrue(any(i["collection"] == "events" and i["op"] == "delete" for i in after["items"]))
        self.assertNotIn("Scoped task", json.dumps(after))
        self.assertNotIn("Private handoff", json.dumps(after))
        self.assertIn("Private handoff", json.dumps(self.read("c")))
        self.assertEqual(after["items"], self.read(cursor=before["new_cursor"])["items"])

    def test_other_member_cursor_and_expiry_have_same_error(self):
        cursor = self.read()["new_cursor"]
        self.assert_error(410, lambda: self.read("c", cursor))
        self.assert_error(410, lambda: self.read(cursor="wrong"))
        self.date += timedelta(days=7)
        self.assert_error(410, lambda: self.read(cursor=cursor))
        self.assertTrue(self.read()["reset"])

    def test_independent_readers_and_restart(self):
        cursors = [self.read()["new_cursor"] for _ in range(2)]
        self.create()
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda c: self.read(cursor=c), cursors))
        self.assertEqual(results[0]["items"], results[1]["items"])
        self.store = Store(self.store.path, clock=lambda: timestamp(self.date))
        self.assertEqual(self.read(cursor=results[0]["new_cursor"])["items"], [])

    def test_permissions_include_only_own_messages_alerts_and_history(self):
        cursor = self.read()["new_cursor"]
        self.send("/v1/messages", {"recipientId": "c", "body": "private to c"})
        self.update(self.create("c"), actor="c", kind="blocked", severity="red", body="private c blocker")
        self.assertEqual(self.read(cursor=cursor)["items"], [])
        self.send("/v1/messages", {"recipientId": "b", "body": "private to b"})
        body = json.dumps(self.read(cursor=cursor))
        self.assertIn("private to b", body)
        self.assertNotIn("private to c", body)
        self.assertNotIn("private c blocker", body)

    def test_event_driven_idle_has_no_false_heartbeat_but_stale_tasks_alert(self):
        self.send("/v1/members/me/participation", {"state": "active", "heartbeatMode": "event_driven", "reason": "Hook wakes only on change"}, "b")
        task = self.update(self.create(), kind="accepted")
        self.date += timedelta(hours=4)
        self.store.scan()
        alerts = self.store.snapshot(self.actors["leader"])["alerts"]
        self.assertFalse(any(a["kind"] == "heartbeat" and a["state"] != "resolved" for a in alerts))
        self.assertTrue(any(a["kind"] == "stale" and a["severity"] == "red" and a["taskId"] == task["id"] for a in alerts))

    def test_periodic_mode_still_alerts_and_mode_change_is_audited(self):
        self.send("/v1/members/me/participation", {"state": "active", "heartbeatMode": "periodic", "reason": "timer enabled"}, "b")
        self.date += timedelta(seconds=661)
        self.store.scan()
        self.assertTrue(any(a["kind"] == "heartbeat" and a["state"] == "open" for a in self.store.snapshot(self.actors["b"])["alerts"]))
        self.send("/v1/members/me/participation", {"state": "active", "heartbeatMode": "event_driven", "reason": "use hook"}, "b")
        snap = self.store.snapshot(self.actors["b"])
        self.assertEqual(snap["alerts"][0]["state"], "resolved")
        self.assertIn("periodic → event_driven", snap["memberEvents"][0]["body"])

    def test_poll_does_not_change_signal_or_cursor_or_progress(self):
        self.send("/v1/members/me/participation", {"state": "active", "reason": "start"}, "b")
        task = self.update(self.create(), kind="accepted")
        before = self.read(); signal = self.store.signal()
        self.date += timedelta(seconds=120)
        self.store.poll(self.actors["b"])
        self.assertEqual(self.store.signal(), signal)
        self.assertEqual(self.read(cursor=before["new_cursor"])["items"], [])
        self.assertEqual(self.store.snapshot(self.actors["b"])["tasks"][0]["lastProgressAt"], task["lastProgressAt"])

    def test_alert_checker_rotates_signal_only_on_real_change(self):
        self.update(self.create(), kind="accepted")
        signal = self.store.signal()
        self.store.scan(); self.assertEqual(self.store.signal(), signal)
        self.date += timedelta(hours=2)
        self.store.scan(); self.assertNotEqual(self.store.signal(), signal)
        signal = self.store.signal()
        self.store.scan(); self.assertEqual(self.store.signal(), signal)

    def test_idempotent_retry_does_not_wake_again(self):
        data = {"title": "idempotent"}; key = uuid.uuid4().hex
        self.send("/v1/tasks", data, key=key)
        signal = self.store.signal()
        self.send("/v1/tasks", data, key=key)
        self.assertEqual(self.store.signal(), signal)

    def test_v2_migration_backup_and_reopening(self):
        path = Path(self.temp.name) / "v2.sqlite3"
        with sqlite3.connect(path, isolation_level=None) as db:
            db.executescript(SCHEMA)
            oversight.migrate(db)
            db.execute("INSERT INTO members(id,name,role,token_hash,poll_seconds) VALUES('old','old','worker',?,300)", (digest("token"),))
            member_columns = [r[1] for r in db.execute("PRAGMA table_info(members)")]
            original_members = db.execute("SELECT * FROM members ORDER BY id").fetchall()
            original_tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        migrated = Store(path)
        self.assertEqual(migrated.authenticate("Bearer token")["heartbeat_mode"], "periodic")
        backup, = path.parent.glob("v2.sqlite3.pre-v6-*.sqlite3")
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        backup_bytes = backup.read_bytes()
        with sqlite3.connect(backup) as db:
            self.assertEqual(db.execute("PRAGMA quick_check").fetchone()[0], "ok")
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 2)
            self.assertEqual(db.execute("SELECT * FROM members ORDER BY id").fetchall(), original_members)
            self.assertEqual({r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}, original_tables)
        with migrated.connection() as db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 6)
            self.assertEqual([tuple(r) for r in db.execute("SELECT " + ",".join(member_columns) + " FROM members ORDER BY id")], original_members)
        reopened = Store(path)
        self.assertEqual(reopened.authenticate("Bearer token")["id"], "old")
        self.assertEqual(len(list(path.parent.glob("v2.sqlite3.pre-v6-*.sqlite3"))), 1)
        self.assertEqual(backup.read_bytes(), backup_bytes)

    def test_http_public_opt_in_etag_and_spoofed_name(self):
        server = Server(("127.0.0.1", 0), self.store)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        def get(path, headers=None):
            conn = http.client.HTTPConnection(*server.server_address, timeout=5)
            conn.request("GET", path, headers=headers or {})
            res = conn.getresponse(); raw = res.read()
            result = res.status, json.loads(raw) if raw else None, dict(res.getheaders()); conn.close()
            return result
        try:
            self.create()
            self.assertEqual(get("/v1/update-signal")[0], 404)
            self.assertEqual(get("/v1/updates")[0], 401)
            response = get("/v1/updates", {"Authorization": "Bearer " + self.tokens["c"], "X-AI-Name": "leader"})
            self.assertEqual(response[1]["memberId"], "c")
            self.assertFalse(any(i["collection"] == "tasks" for i in response[1]["items"]))
            server.public_signal = True
            status, payload, headers = get("/v1/update-signal")
            self.assertEqual(status, 200); self.assertEqual(set(payload), {"revision"})
            self.assertEqual(get("/v1/update-signal", {"If-None-Match": headers["ETag"]})[0], 304)
            self.assertIsNone(self.store.snapshot(self.actors["b"])["me"]["lastPollAt"])
        finally:
            server.shutdown(); server.server_close(); thread.join()


if __name__ == "__main__":
    unittest.main(verbosity=2)
