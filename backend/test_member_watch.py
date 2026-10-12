"""Synthetic member-scoped watch checks; no deployed database or credentials."""
import concurrent.futures
import contextlib
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import statistics
import threading
import time
import unittest
from unittest import mock

import member_watch
from common import APIError, timestamp
import test_watch


class MemberWatchTests(unittest.TestCase):
    setUp = test_watch.WatchTests.setUp
    tearDown = test_watch.WatchTests.tearDown
    request = test_watch.WatchTests.request
    send = test_watch.WatchTests.send
    create = test_watch.WatchTests.create
    update = test_watch.WatchTests.update

    def member_route(self, member="b"):
        return self.route + ("&memberId=" + member if member is not None else "")

    def read(self, member="b", actor=None):
        headers = {"Authorization": "Bearer " + self.tokens[actor]} if actor else {}
        status, result, _, _ = self.request(self.member_route(member), headers=headers)
        self.assertEqual(status, 200)
        return result

    @staticmethod
    def counts(result):
        return {kind: result[kind] for kind in member_watch.TYPES}

    def assert_changes(self, before, types, member="b", actor=None, same_counts=True):
        after = self.read(member, actor)
        self.assertNotEqual(after["cursor"], before["cursor"])
        changed = {kind for kind in member_watch.TYPES
                   if after["revisions"][kind] != before["revisions"][kind]}
        self.assertEqual(changed, set(types))
        if same_counts:
            self.assertEqual(self.counts(after), self.counts(before))
        return after

    def test_exact_member_and_legacy_fields_public_selector_not_identity(self):
        self.create("b")
        self.create("c")
        self.send("/v1/messages", {"recipientId": "b", "body": "PRIVATE incoming"})
        self.send("/v1/announcements", {"title": "PRIVATE title", "body": "PRIVATE broadcast"})
        selected = self.read()
        self.assertEqual(set(selected), {"workspaceId", "memberId", "cursor", *member_watch.TYPES, "revisions"})
        self.assertEqual(set(selected["revisions"]), set(member_watch.TYPES))
        self.assertEqual(selected["memberId"], "b")
        self.assertEqual(self.counts(selected), {"tasks": 1, "auths": 0, "alerts": 0, "messages": 1, "announcements": 1})
        for opaque in (selected["cursor"], *selected["revisions"].values()):
            self.assertRegex(opaque, r"^[A-Za-z0-9_-]{32}$")
        raw = json.dumps(selected)
        for secret in ("PRIVATE", "Worker", "Leader", "TASK-", "token_hash", *self.tokens.values()):
            self.assertNotIn(secret, raw)
        legacy = self.request()[1]
        self.assertEqual(set(legacy), {"workspaceId", "cursor", "tasks", "auths", "alerts", "messages"})
        self.assertEqual(legacy["tasks"], 2)
        self.assertEqual(self.request("/v1/snapshot?memberId=b")[0], 401)
        headers = self.request(self.member_route())[2]
        self.assertEqual(headers["Cache-Control"], "no-store")
        self.assertEqual(headers["X-Content-Type-Options"], "nosniff")
        self.assertNotIn("ETag", headers)

    def test_authenticated_actor_derivation_selection_and_public_opt_in(self):
        public_b = self.read()
        self.assertEqual(self.read(None, "b"), public_b)
        self.assertEqual(self.read("b", "b"), public_b)
        for privileged in ("leader", "user"):
            self.assertEqual(self.read("b", privileged), public_b)
            self.assertEqual(self.read(None, privileged)["memberId"], privileged)
        for target in ("c", "leader", "user", "absent"):
            self.assertEqual(self.request(self.member_route(target), headers={"Authorization": "Bearer " + self.tokens["b"]})[0], 403)
        self.assertEqual(self.read("c")["memberId"], "c")
        self.server.public_watch = False
        for route in (self.route, self.member_route()):
            for headers in ({}, {"Authorization": "Bearer " + self.tokens["b"]}):
                self.assertEqual(self.request(route, headers=headers)[0], 404)

    def test_present_authorization_always_validated_including_empty_and_duplicate(self):
        for authorization in ("", "Basic fixture", "Bearer ", "Bearer bad", "Bearer " + "x" * 257):
            for member in (None, "b"):
                with self.subTest(header=authorization, member=member):
                    response = self.request(self.member_route(member), headers={"Authorization": authorization})
                    self.assertEqual(response[0], 401)
                    self.assertEqual(response[2]["Cache-Control"], "no-store")
        # Header duplication is ambiguous even when both values are valid.
        import http.client
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        connection.putrequest("GET", self.member_route())
        for _ in range(2):
            connection.putheader("Authorization", "Bearer " + self.tokens["b"])
        connection.endheaders()
        response = connection.getresponse()
        response.read()
        self.assertEqual(response.status, 401)
        connection.close()

    def test_query_validation_member_workspace_unknowns_and_post(self):
        invalid = ["", "?memberId=b", "?workspace=&memberId=b", "?workspace=" + self.workspace + "&memberId=",
                   "?workspace=" + self.workspace + "&memberId=B", "?workspace=" + self.workspace + "&memberId=1b",
                   "?workspace=" + self.workspace + "&memberId=" + "b" * 49,
                   "?workspace=" + self.workspace + "&memberId=%2F", "?workspace=" + self.workspace + "&memberId=%FF",
                   "?workspace=" + self.workspace + "&memberId=b&memberId=b",
                   "?workspace=" + self.workspace + "&memberId=b&cursor=x",
                   "?workspace=" + self.workspace + "&memberId=b&heartbeat=1",
                   "?workspace=" + self.workspace + "&MemberId=b",
                   "?workspace=" + self.workspace + "&memberId=b;cursor=x"]
        for suffix in invalid:
            with self.subTest(suffix=suffix):
                self.assertEqual(self.request("/v1/watch" + suffix)[0], 422)
        for route in ("/v1/watch?workspace=wrong&memberId=b", self.member_route("missing")):
            status, value, _, _ = self.request(route)
            self.assertEqual((status, value), (404, {"error": "接口不存在"}))
        before = self.path.read_bytes()
        self.assertEqual(self.request(self.member_route(), method="POST")[0], 405)
        self.assertEqual(before, self.path.read_bytes())

    def test_reads_are_read_only_bounded_consistent_and_do_not_use_snapshot_or_auth_writer(self):
        self.create()
        self.send("/v1/messages", {"recipientId": "b", "body": "PRIVATE"})
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        with self.store.connection() as db:
            state = list(db.execute("SELECT id,last_poll_at FROM members ORDER BY id"))
            schema = list(db.execute("SELECT sql FROM sqlite_master ORDER BY name"))
        with mock.patch.object(self.store, "snapshot", side_effect=AssertionError("snapshot")), \
             mock.patch.object(self.store, "snapshot_in", side_effect=AssertionError("snapshot_in")), \
             mock.patch.object(self.store, "authenticate", side_effect=AssertionError("writer authentication")), \
             mock.patch.object(self.store, "connection", side_effect=AssertionError("writer connection")), \
             mock.patch.object(self.store, "poll", side_effect=AssertionError("poll")), \
             mock.patch.object(self.store, "scan", side_effect=AssertionError("scan")):
            baseline = self.read()
            for _ in range(4):
                self.assertEqual(self.read(), baseline)
                self.assertEqual(self.read(None, "b"), baseline)
        self.assertEqual(hashlib.sha256(self.path.read_bytes()).hexdigest(), before)
        with self.store.connection() as db:
            self.assertEqual(list(db.execute("SELECT id,last_poll_at FROM members ORDER BY id")), state)
            self.assertEqual(list(db.execute("SELECT sql FROM sqlite_master ORDER BY name")), schema)
            self.assertEqual(db.execute("SELECT count(*) FROM sync_cursors").fetchone()[0], 0)
        with contextlib.closing(sqlite3.connect(self.path, isolation_level=None)) as blocked:
            blocked.execute("BEGIN EXCLUSIVE")
            for actor in (None, "b"):
                headers = {"Authorization": "Bearer " + self.tokens[actor]} if actor else {}
                status, _, _, elapsed = self.request(self.member_route(), headers=headers)
                self.assertEqual(status, 503)
                self.assertLess(elapsed, 0.5)
            blocked.execute("ROLLBACK")
        self.assertEqual(self.read(), baseline)
        missing = Path(self.temp.name) / "missing.sqlite3"
        with self.assertRaises(APIError) as failure:
            member_watch.read(missing, self.workspace, "b")
        self.assertEqual(failure.exception.status, 503)
        self.assertFalse(missing.exists())

    def test_signature_gate_timeout_error_cleanup_and_connection_close(self):
        connections = []
        original_connect = sqlite3.connect
        def connect(*args, **kwargs):
            self.assertTrue(args[0].endswith("?mode=ro"))
            self.assertEqual(kwargs["timeout"], 0.2)
            self.assertTrue(kwargs["uri"])
            db = original_connect(*args, **kwargs)
            connections.append(db)
            return db
        with mock.patch.object(member_watch.sqlite3, "connect", side_effect=connect):
            baseline = self.read()
            # A failed signature query releases the gate and closes/rolls back
            # its read transaction; subsequent requests recover immediately.
            with mock.patch.object(member_watch, "_member_result", side_effect=sqlite3.OperationalError("synthetic query failure")):
                self.assertEqual(self.request(self.member_route())[0], 503)
            self.assertFalse(member_watch._SIGNATURE_GATE.locked())
            self.assertEqual(self.read(), baseline)
            member_watch._SIGNATURE_GATE.acquire()
            try:
                status, _, _, elapsed = self.request(self.member_route())
                self.assertEqual(status, 503)
                self.assertLess(elapsed, 0.5)
            finally:
                member_watch._SIGNATURE_GATE.release()
            self.assertEqual(self.read(), baseline)
        self.assertEqual(len(connections), 5)
        for db in connections:
            with self.assertRaises(sqlite3.ProgrammingError):
                db.execute("SELECT 1")

    def test_task_state_events_handoff_away_and_back_with_same_count(self):
        task = self.create()
        before = self.read()
        task = self.update(task, "accepted")
        before = self.assert_changes(before, {"tasks"})
        task = self.update(task)
        before = self.assert_changes(before, {"tasks"})
        # Events are independently immutable; their IDs change even with a
        # deliberately unchanged task version in this synthetic model fixture.
        with self.store.connection() as db:
            self.store.add_event(db, self.actors["leader"], task["id"], "read", "PRIVATE")
        before = self.assert_changes(before, {"tasks"})
        task = self.update(task, "handoff", "leader", ownerId="c")
        away = self.assert_changes(before, {"tasks"}, same_counts=False)
        self.assertEqual(away["tasks"], 0)
        c_task = self.update(task, "accepted", "c")
        self.assertEqual(self.read(), away)
        task = self.update(c_task, "handoff", "leader", ownerId="b")
        returned = self.assert_changes(away, {"tasks"}, same_counts=False)
        self.assertEqual(returned["tasks"], 1)
        self.assertNotEqual(returned["revisions"]["tasks"], before["revisions"]["tasks"])
        # Two handoffs between samples preserve counts/current owner but must wake.
        task = self.update(task, "handoff", "leader", ownerId="c")
        self.update(task, "handoff", "leader", ownerId="b")
        self.assert_changes(returned, {"tasks"})

    def test_worker_unrelated_activity_and_member_liveness_metadata_are_quiet(self):
        before = self.read()
        leader_before = self.read("leader")
        ctask = self.create("c")
        ctask = self.update(ctask, "accepted", "c")
        ctask = self.update(ctask, "blocked", "c", severity="red")
        self.send("/v1/authorizations", {"taskId": ctask["id"], "subject": "PRIVATE", "reason": "PRIVATE"}, "c")
        self.send("/v1/messages", {"recipientId": "c", "body": "PRIVATE"})
        self.send("/v1/members/me/quota", {"note": "PRIVATE", "budgetGroup": "PRIVATE"}, "c")
        self.send("/v1/members/me/participation", {"state": "active", "heartbeatMode": "event_driven", "reason": "PRIVATE"}, "c")
        self.send("/v1/members/c/rename", {"version": 1, "name": "PRIVATE new name"}, "user")
        self.store.poll(self.actors["c"])
        self.store.incremental(self.actors["c"])
        self.store.snapshot(self.actors["leader"])
        self.assertEqual(self.read(), before)
        # Auth reviewer relevance may wake a Leader, but tasks authored for
        # another owner do not broaden the Leader's own tasks signature.
        self.assertEqual(self.read("leader")["revisions"]["tasks"], leader_before["revisions"]["tasks"])

    def test_formal_authorization_request_decision_scope_and_immutable_events(self):
        task = self.create()
        before = self.read()
        authorization = self.send("/v1/authorizations", {"taskId": task["id"], "subject": "PRIVATE auth", "reason": "PRIVATE reason"}, "b")["authorization"]
        current = self.assert_changes(before, {"auths"}, same_counts=False)
        self.assertEqual(current["auths"], 1)
        self.assertEqual(self.read("leader")["auths"], 1)
        self.assertEqual(self.read("user")["auths"], 0)
        self.send(f"/v1/authorizations/{authorization['id']}/decision", {"version": authorization["version"], "action": "approved", "note": "PRIVATE decision"})
        current = self.assert_changes(current, {"auths"})
        with self.store.connection() as db:
            db.execute("INSERT INTO authorization_events(authorization_id,task_id,kind,actor_id,actor_name,body,timestamp) VALUES(?,?,'read','leader','PRIVATE','PRIVATE',?)",
                       (authorization["id"], task["id"], timestamp(self.date)))
        self.assert_changes(current, {"auths"})

    def test_authorization_reviewer_role_escalation_and_decided_by(self):
        task = self.create("c")
        authorization = self.send("/v1/authorizations", {"taskId": task["id"], "subject": "PRIVATE", "reason": "PRIVATE"}, "c")["authorization"]
        worker = self.read()
        leader = self.read("leader")
        admin = self.read("user")
        self.assertEqual((leader["auths"], admin["auths"]), (1, 0))
        authorization = self.send(f"/v1/authorizations/{authorization['id']}/escalate", {"version": 1, "note": "PRIVATE"})["authorization"]
        leader = self.assert_changes(leader, {"auths"}, "leader", same_counts=False)
        admin = self.assert_changes(admin, {"auths"}, "user", same_counts=False)
        self.assertEqual((leader["auths"], admin["auths"]), (0, 1))
        self.send(f"/v1/authorizations/{authorization['id']}/decision", {"version": authorization["version"], "action": "approved", "note": "PRIVATE"}, "user")
        self.assert_changes(admin, {"auths"}, "user")
        self.assertEqual(self.read(), worker)
        # Model permits requester/decider attribution even if reviewer later
        # differs; do not invent member-specific reviewer fields.
        with self.store.connection() as db:
            db.execute("UPDATE authorization_requests SET decided_by='leader' WHERE id=?", (authorization["id"],))
        self.assertEqual(self.read("leader")["auths"], 1)

    def test_received_messages_only_and_same_count_read(self):
        before = self.read()
        self.send("/v1/messages", {"recipientId": "leader", "body": "PRIVATE sent"}, "b")
        self.assertEqual(self.read(), before)
        message = self.send("/v1/messages", {"recipientId": "b", "body": "PRIVATE incoming"})
        current = self.assert_changes(before, {"messages"}, same_counts=False)
        self.assertEqual(current["messages"], 1)
        self.send(f"/v1/messages/{message['id']}/read", {}, "b")
        current = self.assert_changes(current, {"messages"})
        self.send(f"/v1/messages/{message['id']}/read", {}, "b")
        self.assertEqual(self.read(), current)

    def test_alert_scope_acknowledge_resolve_and_event_id(self):
        task = self.update(self.create(), "accepted")
        before = self.read()
        self.update(task, "blocked", severity="red")
        current = self.assert_changes(before, {"tasks", "alerts"}, same_counts=False)
        self.assertEqual(current["alerts"], 1)
        with self.store.connection() as db:
            alert = dict(db.execute("SELECT * FROM alerts WHERE member_id='b'").fetchone())
        self.send(f"/v1/alerts/{alert['id']}/actions", {"version": alert["version"], "action": "acknowledge", "note": "PRIVATE"})
        current = self.assert_changes(current, {"alerts"})
        self.send(f"/v1/alerts/{alert['id']}/actions", {"version": alert["version"] + 1, "action": "resolve", "note": "PRIVATE"})
        # Resolving the model's blocked alert also records an unblocked task.
        current = self.assert_changes(current, {"tasks", "alerts"})
        with self.store.connection() as db:
            db.execute("INSERT INTO alert_events(alert_id,kind,body,timestamp) VALUES(?,'read','PRIVATE',?)", (alert["id"], timestamp(self.date)))
        self.assert_changes(current, {"alerts"})

    def test_all_broadcasts_rule_announcements_and_global_policy_wake_every_scope(self):
        baseline = {member: self.read(member) for member in self.actors}
        notice = self.send("/v1/announcements", {"title": "PRIVATE", "body": "PRIVATE body", "kind": "rule"})
        current = {member: self.assert_changes(value, {"announcements"}, member, same_counts=False)
                   for member, value in baseline.items()}
        self.assertTrue(all(value["announcements"] == 1 for value in current.values()))
        with self.store.connection() as db:
            db.execute("UPDATE announcements SET body='PRIVATE same-count new body' WHERE id=?", (notice["id"],))
        current = {member: self.assert_changes(value, {"announcements"}, member) for member, value in current.items()}
        self.send("/v1/rules", {"version": 1, "staleYellowSeconds": 3600, "reason": "PRIVATE"})
        for member, value in current.items():
            self.assert_changes(value, {"announcements"}, member)

    def test_cursor_scope_separation_credential_rotation_and_sync_receipt_independence(self):
        before = self.read()
        empty_c = self.read("c")
        self.assertNotEqual(before["cursor"], empty_c["cursor"])
        for kind in member_watch.TYPES:
            self.assertNotEqual(before["revisions"][kind], empty_c["revisions"][kind])
        receipt = self.store.incremental(self.actors["b"])["new_cursor"]
        self.assertNotEqual(before["cursor"], receipt)
        self.assertEqual(self.read(), before)
        with self.assertRaises(APIError) as failure:
            self.store.incremental(self.actors["b"], before["cursor"])
        self.assertEqual(failure.exception.status, 410)
        self.send("/v1/members/b/rotate-credential", {"version": 1}, "user")
        rotated = self.read()
        self.assertNotEqual(before["cursor"], rotated["cursor"])
        self.assertEqual(self.counts(before), self.counts(rotated))
        self.assertEqual(self.request(self.member_route(), headers={"Authorization": "Bearer " + self.tokens["b"]})[0], 401)

    def test_atomic_counts_and_revisions_during_concurrent_commits(self):
        # Recompute the exact revision from captured count inside a separate
        # controlled fixture, so each response proves an internally consistent
        # state even while actual watched DB commits race the readers.
        expected = {0: self.read()}
        stamp = timestamp(self.date)
        for sequence in range(1, 21):
            with self.store.connection() as db:
                db.execute("INSERT INTO messages(sender_id,sender_name,recipient_id,body,created_at) VALUES('leader','Leader','b','PRIVATE',?)", (stamp,))
            expected[sequence] = self.read()
        with self.store.connection() as db:
            db.execute("DELETE FROM messages")
            db.execute("DELETE FROM sqlite_sequence WHERE name='messages'")
        failures = []
        def writer():
            try:
                with self.store.connection() as db:
                    for _ in range(20):
                        db.execute("BEGIN IMMEDIATE")
                        db.execute("INSERT INTO messages(sender_id,sender_name,recipient_id,body,created_at) VALUES('leader','Leader','b','PRIVATE',?)", (stamp,))
                        db.execute("COMMIT")
            except Exception as error:
                failures.append(error)
        thread = threading.Thread(target=writer)
        thread.start()
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as readers:
            results = list(readers.map(lambda _: self.read(), range(60)))
        thread.join(timeout=5)
        self.assertFalse(thread.is_alive())
        self.assertEqual(failures, [])
        for result in results:
            self.assertEqual(result, expected[result["messages"]])

    def test_representative_5000_scoped_entities_http_performance(self):
        rows, stamp = 5000, timestamp(self.date)
        body = "PRIVATE seeded payload " + "x" * 4000
        with self.store.connection() as db:
            db.execute("BEGIN IMMEDIATE")
            db.executemany("""INSERT INTO tasks(id,title,owner_id,source,category,priority,status,details,acceptance,version,created_by,created_at,updated_at)
                VALUES(?,'PRIVATE','b','leader','other','normal','pending',?,'',1,'leader',?,?)""",
                           ((f"TASK-{n:06d}", body, stamp, stamp) for n in range(1, rows + 1)))
            db.executemany("""INSERT INTO events(task_id,kind,body,actor_id,actor_name,timestamp,to_leader,notify_member_id)
                VALUES(?,'created',?,'leader','PRIVATE',?,1,'b')""",
                           ((f"TASK-{n:06d}", body, stamp) for n in range(1, rows + 1)))
            db.executemany("""INSERT INTO authorization_requests(task_id,requester_id,kind,subject,reason,state,created_at,updated_at)
                VALUES(?,'b','normal','PRIVATE',?,'approved',?,?)""",
                           ((f"TASK-{n:06d}", body, stamp, stamp) for n in range(1, rows + 1)))
            db.executemany("""INSERT INTO alerts(dedup_key,kind,task_id,member_id,severity,title,detail,state,created_at,updated_at)
                VALUES(?,'blocked',?,'b','yellow','PRIVATE',?,'resolved',?,?)""",
                           ((f"fixture-{n}", f"TASK-{n:06d}", body, stamp, stamp) for n in range(1, rows + 1)))
            db.executemany("INSERT INTO messages(sender_id,sender_name,recipient_id,body,created_at) VALUES('leader','Leader','b',?,?)",
                           ((body, stamp) for _ in range(rows)))
            db.executemany("INSERT INTO announcements(kind,title,body,actor_id,actor_name,created_at) VALUES('announcement','PRIVATE',?,'leader','PRIVATE',?)",
                           ((body, stamp) for _ in range(rows)))
            db.execute("COMMIT")
        baseline = self.read()
        self.assertEqual(self.counts(baseline), dict.fromkeys(member_watch.TYPES, rows))
        responses = [self.request(self.member_route()) for _ in range(6)]
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as readers:
            responses += list(readers.map(lambda _: self.request(self.member_route()), range(12)))
        for status, result, _, elapsed in responses:
            self.assertEqual(status, 200)
            self.assertEqual(result, baseline)
            self.assertLess(elapsed, 0.5)
        durations = sorted(response[3] for response in responses)
        print(f"MEMBER_WATCH_BENCH rows_per_collection={rows} samples={len(responses)} concurrent=4 "
              f"bytes={len(json.dumps(baseline, separators=(',', ':')).encode())} "
              f"median_ms={statistics.median(durations)*1000:.3f} "
              f"p95_ms={durations[int(len(durations)*.95)-1]*1000:.3f} max_ms={durations[-1]*1000:.3f}", flush=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
