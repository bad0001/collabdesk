import http.client
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import time
import unittest
import uuid
from datetime import datetime, timedelta, timezone

from common import APIError, parse_time, timestamp
from server import SCHEMA, Server, Store, digest, register_members


class OversightTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.date = datetime(2026, 10, 1, 0, 0, tzinfo=timezone.utc)
        self.store = Store(Path(self.temp.name) / "test.sqlite3", clock=lambda: timestamp(self.date))
        self.tokens = {m: self.store.add_member(m, m, r) for m, r in [("user", "admin"), ("leader", "leader"), ("b", "worker"), ("c", "worker")]}
        self.actors = {m: self.store.authenticate("Bearer " + t) for m, t in self.tokens.items()}

    def tearDown(self):
        self.temp.cleanup()

    def advance(self, seconds):
        self.date += timedelta(seconds=seconds)

    def send(self, actor, path, data, key=None):
        return self.store.mutate(self.actors[actor], path, data, key or uuid.uuid4().hex)[1]

    def snap(self, actor="leader"):
        return self.store.snapshot(self.actors[actor])

    def create(self, owner="b", review=False):
        return self.send("leader", "/v1/tasks", {"title": "测试任务", "ownerId": owner, "source": "user", "requiresReview": review})["task"]

    def task(self, task_id):
        return next(t for t in self.snap()["tasks"] if t["id"] == task_id)

    def update(self, task, actor="b", **kw):
        data = {"version": task["version"], "kind": "progress", "body": "具体进展及下一步"}
        data.update(kw)
        return self.send(actor, f"/v1/tasks/{task['id']}/updates", data)["task"]

    def live(self, kind=None):
        return [a for a in self.snap()["alerts"] if a["state"] != "resolved" and (kind is None or a["kind"] == kind)]

    def participation(self, actor, state="active", seconds=300):
        self.send(actor, "/v1/members/me/participation", {"state": state, "pollSeconds": seconds, "reason": "测试中的明确参与声明"})

    def assert_error(self, status, fn):
        with self.assertRaises(APIError) as ctx:
            fn()
        self.assertEqual(ctx.exception.status, status, ctx.exception.message)

    def test_stale_exact_boundaries_and_dedup_escalation(self):
        task = self.update(self.create(), kind="accepted")
        self.advance(7199); self.store.scan()
        self.assertEqual(self.live(), [])
        self.advance(1); self.store.scan()
        first = self.live()[0]
        self.assertEqual(first["severity"], "yellow")
        for _ in range(4): self.store.scan()
        self.assertEqual(len(self.snap()["alertEvents"]), 1)
        self.advance(7200); self.store.scan()
        red = self.live()[0]
        self.assertEqual(red["id"], first["id"])
        self.assertEqual(red["severity"], "red")
        self.assertEqual(self.snap()["alertEvents"][0]["kind"], "escalated")

    def test_poll_and_read_do_not_reset_progress(self):
        task = self.update(self.create(), kind="accepted")
        original = task["lastProgressAt"]
        self.advance(7200)
        self.store.poll(self.actors["b"])
        task = self.update(task, kind="read", body="已阅读")
        self.assertEqual(task["lastProgressAt"], original)
        self.assertEqual(self.live("stale")[0]["severity"], "yellow")

    def test_substantive_progress_resolves_stale_but_preserves_started_at(self):
        task = self.update(self.create(), kind="accepted")
        self.advance(14400); self.store.scan()
        task2 = self.update(task)
        self.assertEqual(task2["startedAt"], task["startedAt"])
        self.assertEqual(self.live(), [])
        self.assertEqual(self.snap()["alerts"][0]["state"], "resolved")

    def test_pending_review_and_completed_do_not_stale(self):
        task = self.create(review=True)
        self.advance(20000); self.store.scan()
        self.assertEqual(self.live(), [])
        task = self.update(task, kind="submitted")
        self.assertEqual(task["status"], "awaiting_review")
        self.advance(20000); self.store.scan()
        self.assertEqual(self.live(), [])
        task = self.update(task, "leader", kind="approved")
        self.assertEqual(task["status"], "completed")
        self.advance(20000); self.store.scan()
        self.assertEqual(self.live(), [])

    def test_heartbeat_requires_opt_in_and_respects_grace(self):
        self.advance(50000); self.store.scan()
        self.assertEqual(self.live(), [])
        self.participation("b")
        self.advance(659); self.store.scan()
        self.assertEqual(self.live(), [])
        self.advance(1); self.store.scan()
        self.assertEqual(self.live("heartbeat")[0]["severity"], "yellow")
        self.advance(600); self.store.scan()
        self.assertEqual(self.live("heartbeat")[0]["severity"], "red")
        self.store.poll(self.actors["b"])
        self.assertEqual(self.live(), [])

    def test_different_member_poll_intervals(self):
        self.participation("leader", seconds=120)
        self.participation("b", seconds=300)
        self.advance(300); self.store.scan()
        self.assertEqual([a["memberId"] for a in self.live()], ["leader"])

    def test_rest_excludes_paused_time_and_heartbeat(self):
        task = self.update(self.create(), kind="accepted")
        self.participation("b")
        self.advance(3600)
        self.participation("b", "resting")
        self.advance(10 * 3600); self.store.scan()
        self.assertEqual(self.live(), [])
        self.participation("b", "active")
        self.assertEqual(self.live(), [])
        task2 = self.task(task["id"])
        self.assertEqual(parse_time(task2["lastProgressAt"]) - parse_time(task["lastProgressAt"]), timedelta(hours=10))
        self.advance(3600); self.store.scan()
        self.assertEqual(self.live("stale")[0]["severity"], "yellow")

    def test_manual_block_is_immediate_and_does_not_transfer(self):
        task = self.update(self.create(), kind="blocked", severity="red", body="额度耗尽；需要换一个成员继续")
        self.assertEqual(task["status"], "needs_help")
        self.assertEqual(task["ownerId"], "b")
        self.assertEqual(self.live("blocked")[0]["severity"], "red")
        self.assertEqual(self.snap("c")["alerts"], [])
        self.assertEqual(len(self.snap("b")["alerts"]), 1)

    def test_heartbeat_recovery_does_not_clear_blocker(self):
        self.participation("b")
        self.update(self.create(), kind="blocked", severity="yellow", body="缺少原始材料")
        self.advance(1260); self.store.scan()
        self.assertEqual(len(self.live()), 2)
        self.store.poll(self.actors["b"])
        self.assertEqual([a["kind"] for a in self.live()], ["blocked"])

    def test_acknowledge_is_not_resolution_and_snooze_expires(self):
        self.update(self.create(), kind="blocked", severity="yellow", body="请补充资料")
        alert = self.live()[0]
        path = f"/v1/alerts/{alert['id']}/actions"
        self.send("leader", path, {"version": alert["version"], "action": "acknowledge", "note": "已看，稍后处理"})
        alert = self.live()[0]
        self.assertEqual(alert["state"], "acknowledged")
        self.send("leader", path, {"version": alert["version"], "action": "snooze", "minutes": 5, "note": "等待用户补充"})
        self.advance(299); self.store.scan()
        self.assertEqual(self.live()[0]["state"], "snoozed")
        self.advance(1); self.store.scan()
        self.assertEqual(self.live()[0]["state"], "open")

    def test_escalation_interrupts_snooze(self):
        self.update(self.create(), kind="accepted")
        self.advance(7200); self.store.scan()
        a = self.live()[0]
        self.send("leader", f"/v1/alerts/{a['id']}/actions", {"version": a["version"], "action": "snooze", "minutes": 240, "note": "先观察"})
        self.advance(7200); self.store.scan()
        self.assertEqual(self.live()[0]["state"], "open")
        self.assertEqual(self.live()[0]["severity"], "red")

    def test_resolve_blocker_requires_reason_and_adds_task_event(self):
        task = self.update(self.create(), kind="blocked", severity="red", body="缺资料")
        alert = self.live()[0]
        path = f"/v1/alerts/{alert['id']}/actions"
        self.assert_error(422, lambda: self.send("leader", path, {"version": alert["version"], "action": "resolve", "note": ""}))
        self.send("leader", path, {"version": alert["version"], "action": "resolve", "note": "资料已补齐，继续原任务"})
        self.assertEqual(self.live(), [])
        self.assertEqual(self.task(task["id"])["status"], "in_progress")
        self.assertEqual(self.snap()["events"][0]["kind"], "unblocked")

    def test_auto_condition_cannot_be_hidden_by_resolve(self):
        self.update(self.create(), kind="accepted")
        self.advance(14400); self.store.scan()
        a = self.live()[0]
        self.assert_error(409, lambda: self.send("leader", f"/v1/alerts/{a['id']}/actions", {"version": a["version"], "action": "resolve", "note": "忽略"}))

    def test_two_distinct_rejections_and_idempotent_replay(self):
        task = self.update(self.create(review=True), kind="submitted")
        path = f"/v1/tasks/{task['id']}/updates"
        data = {"version": task["version"], "kind": "rejected", "body": "缺少项目结果"}
        task = self.send("leader", path, data, "review-key-001")["task"]
        self.send("leader", path, data, "review-key-001")
        self.assertEqual(self.task(task["id"])["rejectionStreak"], 1)
        self.assertEqual(self.live(), [])
        self.assert_error(409, lambda: self.update(task, "leader", kind="rejected"))
        task = self.update(task, kind="submitted")
        task = self.update(task, "leader", kind="rejected")
        self.assertEqual(task["rejectionStreak"], 2)
        self.assertEqual(self.live("rejected")[0]["severity"], "red")
        task = self.update(task, kind="submitted")
        self.assertEqual(task["rejectionStreak"], 2)
        task = self.update(task, "leader", kind="approved")
        self.assertEqual(task["rejectionStreak"], 0)
        self.assertEqual(self.live(), [])

    def test_worker_cannot_bypass_review(self):
        task = self.update(self.create(review=True), kind="submitted")
        self.assert_error(403, lambda: self.update(task, kind="approved"))
        self.assert_error(409, lambda: self.update(task, kind="question", status="in_progress"))
        self.assert_error(409, lambda: self.update(task, kind="progress", status="completed"))
        self.assertEqual(self.task(task["id"])["status"], "awaiting_review")

    def test_normal_task_submission_still_requires_leader_approval(self):
        created = self.create(review=False)
        self.assertFalse(created["requiresReview"])
        task = self.update(created, kind="completed")
        self.assertEqual(task["status"], "awaiting_review")
        self.assertTrue(task["requiresReview"])
        self.assertEqual((task["ownerId"], task["reviewStage"], task["submissionSeq"]), ("b", "leader", 1))
        self.assert_error(403, lambda: self.update(task, kind="approved"))
        self.assert_error(403, lambda: self.update(task, "user", kind="approved"))
        self.assert_error(409, lambda: self.update(task, kind="progress", status="completed"))
        self.assertEqual(self.task(task["id"])["status"], "awaiting_review")
        self.assertEqual(self.live(), [])
        approved = self.update(task, "leader", kind="approved")
        self.assertEqual((approved["status"], approved["ownerId"]), ("completed", "b"))
        self.assert_error(409, lambda: self.update(task, "leader", kind="approved"))
        with self.store.connection() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM submissions WHERE task_id=?", (task["id"],)).fetchone()[0], 1)
            self.assertEqual(db.execute("SELECT producer_id FROM outputs WHERE task_id=? AND kind='approved'", (task["id"],)).fetchone()[0], "b")

    def test_transfer_is_pending_and_keeps_original_source(self):
        task = self.update(self.create(), kind="blocked", severity="red", body="额度不足")
        self.assert_error(403, lambda: self.update(task, kind="handoff", ownerId="c"))
        task = self.update(task, "leader", kind="handoff", ownerId="c", body="C 额度更充足，由 C 接手")
        self.assertEqual((task["ownerId"], task["status"], task["source"]), ("c", "pending", "user"))
        self.assertEqual(self.live(), [])
        self.assertEqual(self.snap("b")["tasks"], [])
        self.assertEqual(self.snap("b")["alerts"], [])

    def test_dashboard_counts_and_producer_attribution(self):
        task = self.update(self.create(review=True), kind="submitted")
        row = next(r for r in self.snap()["dashboard"] if r["memberId"] == "b")
        self.assertEqual((row["openTasks"], row["awaitingReview"], row["submitted24h"], row["approved24h"]), (1, 1, 1, 0))
        task = self.update(task, "leader", kind="rejected")
        task = self.update(task, "leader", kind="handoff", ownerId="c")
        task = self.update(task, "c", kind="submitted")
        task = self.update(task, "leader", kind="approved")
        rows = {r["memberId"]: r for r in self.snap()["dashboard"]}
        self.assertEqual(rows["b"]["submitted24h"], 1)
        self.assertEqual(rows["c"]["submitted24h"], 0)  # one first delivery per task
        self.assertEqual(rows["c"]["approved24h"], 1)  # final accepted producer, not reviewer
        self.assertEqual(rows["leader"]["approved24h"], 0)
        self.advance(86400)
        self.assertEqual(sum(r["submitted24h"] + r["approved24h"] for r in self.snap()["dashboard"]), 0)

    def test_dashboard_longest_does_not_reset_on_progress(self):
        first = self.update(self.create(), kind="accepted")
        self.advance(120)
        self.update(self.create(), kind="accepted")
        self.advance(120)
        self.update(first)
        row = next(r for r in self.snap()["dashboard"] if r["memberId"] == "b")
        self.assertEqual(row["oldestTaskId"], first["id"])
        self.assertEqual(row["oldestStartedAt"], first["startedAt"])

    def test_worker_dashboard_and_alert_history_isolation(self):
        self.update(self.create(owner="c"), "c", kind="blocked", severity="red", body="仅 C 的问题")
        snap = self.snap("b")
        self.assertEqual(snap["dashboard"], [])
        self.assertEqual(snap["alerts"], [])
        self.assertEqual(snap["alertEvents"], [])

    def test_directed_summary_does_not_grant_task_access(self):
        self.create(owner="leader")
        self.send("leader", "/v1/messages", {"recipientId": "b", "body": "方案已整理，这是给 B 的摘要"})
        b = self.snap("b")
        self.assertEqual(b["tasks"], [])
        self.assertEqual(len(b["messages"]), 1)
        self.assertEqual(self.snap("c")["messages"], [])
        mid = b["messages"][0]["id"]
        self.assert_error(404, lambda: self.send("c", f"/v1/messages/{mid}/read", {}))
        self.send("b", f"/v1/messages/{mid}/read", {})
        self.assertIsNotNone(self.snap()["messages"][0]["readAt"])

    def test_rules_are_versioned_and_audited(self):
        self.assert_error(403, lambda: self.send("b", "/v1/rules", {"version": 1, "reason": "test"}))
        self.assert_error(422, lambda: self.send("leader", "/v1/rules", {"version": 1, "staleYellowSeconds": 18000, "reason": "test"}))
        self.send("leader", "/v1/rules", {"version": 1, "staleYellowSeconds": 60, "staleRedSeconds": 120, "reason": "联调短时规则"})
        self.assertEqual(self.snap()["rules"]["version"], 2)
        self.assertEqual(self.snap()["memberEvents"][0]["kind"], "rules")
        self.assert_error(409, lambda: self.send("leader", "/v1/rules", {"version": 1, "reason": "过期版本"}))

    def test_append_only_alert_audit(self):
        self.update(self.create(), kind="blocked", severity="red")
        with self.store.connection() as db:
            for table in ["alert_events", "member_events", "submissions", "outputs"]:
                # Ensure a row exists for triggers whose table would otherwise be empty.
                if table == "alert_events":
                    with self.assertRaises(sqlite3.IntegrityError):
                        db.execute(f"DELETE FROM {table}")

    def test_periodic_checker_runs_without_leader_poll(self):
        self.update(self.create(), kind="accepted")
        self.advance(14400)
        server = Server(("127.0.0.1", 0), self.store, check_interval=0.05)
        try:
            deadline = time.monotonic() + 2
            found = False
            while time.monotonic() < deadline:
                with self.store.connection() as db:
                    found = db.execute("SELECT count(*) FROM alerts WHERE severity='red'").fetchone()[0] == 1
                if found: break
                time.sleep(0.02)
            self.assertTrue(found)
            self.assertIsNone(server.check_error)
        finally:
            server.server_close()
        self.assertFalse(server.check_thread.is_alive())

    def test_v1_migration_makes_backup_and_preserves_rows(self):
        path = Path(self.temp.name) / "legacy.sqlite3"
        with sqlite3.connect(path) as db:
            db.executescript(SCHEMA)
            db.execute("INSERT INTO members(id,name,role,token_hash,poll_seconds) VALUES('old','旧成员','worker',?,300)", (digest("legacy-token"),))
            stamp = timestamp(self.date)
            db.execute("""INSERT INTO tasks(id,title,owner_id,source,category,priority,status,details,acceptance,version,created_by,created_at,updated_at)
                        VALUES('TASK-000001','旧任务','old','user','other','normal','in_progress','','',1,'old',?,?)""", (stamp,stamp))
            member_columns = [r[1] for r in db.execute("PRAGMA table_info(members)")]
            task_columns = [r[1] for r in db.execute("PRAGMA table_info(tasks)")]
            original_members = db.execute("SELECT * FROM members ORDER BY id").fetchall()
            original_tasks = db.execute("SELECT * FROM tasks ORDER BY number").fetchall()
            original_tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        migrated = Store(path)
        actor = migrated.authenticate("Bearer legacy-token")
        snap = migrated.snapshot(actor)
        self.assertEqual(snap["tasks"][0]["source"], "user")
        self.assertEqual(snap["tasks"][0]["lastProgressAt"], stamp)
        backups = list(Path(self.temp.name).glob("legacy.sqlite3.pre-v6-*.sqlite3"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(backups[0].stat().st_mode & 0o777, 0o600)
        backup_bytes = backups[0].read_bytes()
        with sqlite3.connect(backups[0]) as db:
            self.assertEqual(db.execute("PRAGMA quick_check").fetchone()[0], "ok")
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 0)
            self.assertEqual(db.execute("SELECT * FROM members ORDER BY id").fetchall(), original_members)
            self.assertEqual(db.execute("SELECT * FROM tasks ORDER BY number").fetchall(), original_tasks)
            self.assertEqual({r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}, original_tables)
        with migrated.connection() as db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 6)
            self.assertEqual([tuple(r) for r in db.execute("SELECT " + ",".join(member_columns) + " FROM members ORDER BY id")], original_members)
            self.assertEqual([tuple(r) for r in db.execute("SELECT " + ",".join(task_columns) + " FROM tasks ORDER BY number")], original_tasks)
        reopened = Store(path)
        self.assertEqual(reopened.authenticate("Bearer legacy-token")["id"], "old")
        self.assertEqual(len(list(Path(self.temp.name).glob("legacy.sqlite3.pre-v6-*.sqlite3"))), 1)
        self.assertEqual(backups[0].read_bytes(), backup_bytes)

    def test_registration_failure_preserves_database_and_credentials(self):
        destination = Path(self.temp.name) / "existing.json"
        destination.write_text("original")
        with self.assertRaises(FileExistsError):
            register_members(self.store, destination, [("new", "新增", "worker")])
        self.assertEqual(destination.read_text(), "original")
        with self.store.connection() as db:
            self.assertIsNone(db.execute("SELECT 1 FROM members WHERE id='new'").fetchone())
        absent = Path(self.temp.name) / "absent.json"
        with self.assertRaises(ValueError):
            register_members(self.store, absent, [("b", "重复成员", "worker")])
        self.assertFalse(absent.exists())

    def test_registration_writes_private_file_and_authenticates(self):
        destination = Path(self.temp.name) / "private.json"
        register_members(self.store, destination, [("new", "新增成员", "worker")])
        token = json.loads(destination.read_text())["new"]["token"]
        self.assertEqual(self.store.authenticate("Bearer " + token)["id"], "new")
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)


if __name__ == "__main__":
    unittest.main(verbosity=2)
