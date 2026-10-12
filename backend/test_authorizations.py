import http.client
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
import uuid

import oversight
import sync
from server import SCHEMA, Server, Store, digest


class AuthorizationFlowTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "workspace.sqlite3"
        self.store = Store(self.path)
        self.tokens = {name: self.store.add_member(name, display, role) for name, display, role in
                       [("user", "我", "admin"), ("leader", "我的助理", "leader"),
                        ("b", "资料搭档", "worker"), ("c", "简历搭档", "worker")]}
        self.server = Server(("127.0.0.1", 0), self.store)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.thread.join(timeout=5)
        self.server.server_close()
        self.temp.cleanup()

    def request(self, actor, method, path, data=None, key=None, token=None):
        conn = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        headers = {"Authorization": "Bearer " + (token if token is not None else self.tokens[actor])}
        if data is not None:
            headers.update({"Content-Type": "application/json", "Idempotency-Key": key or uuid.uuid4().hex})
        conn.request(method, path, None if data is None else json.dumps(data).encode(), headers)
        result = conn.getresponse()
        payload = result.read()
        answer = (result.status, json.loads(payload) if payload else None)
        conn.close()
        return answer

    def task(self, owner="b"):
        status, value = self.request("leader", "POST", "/v1/tasks", {"title": "核对岗位", "ownerId": owner, "source": "user"})
        self.assertEqual(status, 201)
        return value["task"]

    def update(self, actor, task, kind, version=None, **fields):
        return self.request(actor, "POST", f"/v1/tasks/{task['id']}/updates",
                            {"version": task["version"] if version is None else version, "kind": kind,
                             "body": "具体工作或处理理由", **fields})

    def ask(self, task, kind="normal", **fields):
        return self.request("b", "POST", "/v1/authorizations",
                            {"taskId": task["id"], "kind": kind, "subject": "继续处理岗位", "reason": "该任务下一步需要明确授权", **fields})

    def test_normal_approval_blocks_work_until_leader_decides(self):
        task = self.task()
        start = self.request("leader", "GET", "/v1/updates")[1]["new_cursor"]
        status, payload = self.ask(task)
        self.assertEqual(status, 201)
        authorization = payload["authorization"]
        self.assertEqual(authorization["state"], "pending_leader")
        self.assertEqual(self.update("b", task, "accepted")[0], 409)
        self.assertEqual(self.request("c", "GET", "/v1/snapshot")[1]["authorizations"], [])
        self.assertEqual(self.request("b", "POST", f"/v1/authorizations/{authorization['id']}/decision",
                                      {"version": 1, "action": "approved", "note": "冒用审批"})[0], 403)
        status, approved = self.request("leader", "POST", f"/v1/authorizations/{authorization['id']}/decision",
                                        {"version": 1, "action": "approved", "note": "此范围内可以继续"})
        self.assertEqual(status, 200)
        self.assertEqual(approved["authorization"]["decidedBy"], "leader")
        self.assertEqual(approved["authorization"]["state"], "approved")
        self.assertEqual(self.request("leader", "POST", f"/v1/authorizations/{authorization['id']}/decision",
                                      {"version": 1, "action": "denied", "note": "重复操作"})[0], 409)
        self.assertEqual(self.update("b", task, "accepted")[1]["task"]["status"], "in_progress")
        delta = self.request("leader", "GET", "/v1/updates?cursor=" + start)[1]
        self.assertTrue(any(item["collection"] == "authorizations" and item["value"]["state"] == "approved" for item in delta["items"]))
        self.assertTrue(any(item["collection"] == "authorizationEvents" and item["value"]["kind"] == "approved" for item in delta["items"]))

    def test_card_requires_user_external_confirmation_and_is_user_inbox(self):
        task = self.task()
        self.assertEqual(self.ask(task, "card")[0], 422)
        status, payload = self.ask(task, "card", accountLabel="招聘账号 A")
        self.assertEqual(status, 201)
        authorization = payload["authorization"]
        self.assertEqual(authorization["state"], "awaiting_user")
        self.assertIn(authorization["id"], [r["id"] for r in self.request("user", "GET", "/v1/snapshot")[1]["authorizations"]])
        self.assertIn(authorization["id"], [r["id"] for r in self.request("leader", "GET", "/v1/leader/overview")[1]["authorizations"]])
        route = f"/v1/authorizations/{authorization['id']}/decision"
        for actor, action in [("leader", "approved"), ("leader", "confirmed_external"), ("b", "confirmed_external")]:
            self.assertEqual(self.request(actor, "POST", route, {"version": 1, "action": action, "note": "不能代办"})[0], 403)
        self.assertEqual(self.request("user", "POST", route, {"version": 1, "action": "approved", "note": "不是外部确认"})[0], 422)
        self.assertEqual(self.update("b", task, "accepted")[0], 409)
        status, payload = self.request("user", "POST", route, {"version": 1, "action": "confirmed_external", "note": "已亲自在外部账号完成授权"})
        self.assertEqual(status, 200)
        self.assertEqual(payload["authorization"]["state"], "confirmed_external")
        self.assertEqual(payload["authorization"]["decidedBy"], "user")
        self.assertEqual(self.update("b", task, "accepted")[0], 200)
        with self.store.connection() as db:
            self.assertEqual(db.execute("SELECT count(*) FROM authorization_events WHERE authorization_id=?", (authorization["id"],)).fetchone()[0], 2)

    def test_denial_and_handoff_keep_audit_but_release_new_owner(self):
        task = self.task()
        authorization = self.ask(task)[1]["authorization"]
        route = f"/v1/authorizations/{authorization['id']}/decision"
        self.assertEqual(self.request("leader", "POST", route, {"version": 1, "action": "denied", "note": "当前条件不满足"})[0], 200)
        self.assertEqual(self.update("b", task, "accepted")[0], 409)
        prior = self.request("b", "GET", "/v1/updates")[1]["new_cursor"]
        transferred = self.update("leader", task, "handoff", ownerId="c")[1]["task"]
        self.assertEqual(transferred["ownerId"], "c")
        self.assertEqual(self.request("leader", "GET", "/v1/snapshot")[1]["authorizations"][0]["state"], "cancelled")
        changes = self.request("b", "GET", "/v1/updates?cursor=" + prior)[1]["items"]
        self.assertTrue(any(i["collection"] == "tasks" and i["id"] == task["id"] and i["op"] == "delete" for i in changes))
        self.assertEqual(self.update("c", transferred, "accepted")[0], 200)

    def test_member_add_rename_rotate_and_one_time_secret(self):
        data = {"id": "muse_resume", "name": "我的简历伙伴", "role": "worker"}
        self.assertEqual(self.request("leader", "POST", "/v1/members", data)[0], 403)
        status, payload = self.request("user", "POST", "/v1/members", data, key="create-muse-001")
        self.assertEqual(status, 201)
        credential = payload["credential"]
        self.assertEqual(payload["member"]["name"], "我的简历伙伴")
        self.assertEqual(self.request("user", "POST", "/v1/members", data, key="create-muse-001")[0], 409)
        with self.store.connection() as db:
            self.assertNotIn(credential, db.execute("SELECT response FROM idempotency WHERE key='create-muse-001'").fetchone()[0])
            self.assertNotIn(credential, db.execute("SELECT body FROM member_events WHERE member_id='muse_resume'").fetchone()[0])
        self.assertEqual(self.request("user", "GET", "/v1/snapshot", token=credential)[1]["me"]["id"], "muse_resume")
        route = "/v1/members/muse_resume/rename"
        self.assertEqual(self.request("leader", "POST", route, {"version": 1, "name": "新名称"})[0], 403)
        status, payload = self.request("user", "POST", route, {"version": 1, "name": "求职搭档"})
        self.assertEqual(status, 200)
        self.assertEqual(payload["member"]["id"], "muse_resume")
        self.assertEqual(payload["member"]["profileVersion"], 2)
        status, payload = self.request("user", "POST", "/v1/members/muse_resume/rotate-credential", {"version": 2})
        self.assertEqual(status, 200)
        self.assertEqual(self.request("user", "GET", "/v1/snapshot", token=credential)[0], 401)
        self.assertEqual(self.request("user", "GET", "/v1/snapshot", token=payload["credential"])[1]["me"]["name"], "求职搭档")

    def test_v3_migration_backs_up_existing_members_before_new_tables(self):
        path = Path(self.temp.name) / "legacy-v3.sqlite3"
        with sqlite3.connect(path, isolation_level=None) as db:
            db.executescript(SCHEMA)
            oversight.migrate(db)
            sync.migrate(db)
            db.execute("INSERT INTO members(id,name,role,token_hash,poll_seconds) VALUES('old','旧成员','worker',?,300)", (digest("legacy"),))
            member_columns = [r[1] for r in db.execute("PRAGMA table_info(members)")]
            original_members = db.execute("SELECT * FROM members ORDER BY id").fetchall()
            original_tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        migrated = Store(path)
        self.assertEqual(migrated.authenticate("Bearer legacy")["profile_version"], 1)
        # Store now performs one consistent backup before the entire upgrade to
        # v6, not a separate named backup for each intermediate migration.
        backup, = path.parent.glob("legacy-v3.sqlite3.pre-v6-*.sqlite3")
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        backup_bytes = backup.read_bytes()
        with sqlite3.connect(backup) as db:
            self.assertEqual(db.execute("PRAGMA quick_check").fetchone()[0], "ok")
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 3)
            self.assertEqual(db.execute("SELECT * FROM members ORDER BY id").fetchall(), original_members)
            self.assertEqual({r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}, original_tables)
        with migrated.connection() as db:
            self.assertEqual(db.execute("PRAGMA user_version").fetchone()[0], 6)
            self.assertEqual([tuple(r) for r in db.execute("SELECT " + ",".join(member_columns) + " FROM members ORDER BY id")], original_members)
            tables = {r[0] for r in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            self.assertTrue({"authorization_requests", "help_requests", "code_requests", "codes_metadata"} <= tables)
        reopened = Store(path)
        self.assertEqual(reopened.authenticate("Bearer legacy")["id"], "old")
        self.assertEqual(len(list(path.parent.glob("legacy-v3.sqlite3.pre-v6-*.sqlite3"))), 1)
        self.assertEqual(backup.read_bytes(), backup_bytes)
