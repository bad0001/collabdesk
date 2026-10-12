import concurrent.futures
import http.client
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
import uuid

from server import APIError, Server, Store


class APITests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name) / "test.sqlite3")
        self.tokens = {mid: self.store.add_member(mid, mid, role) for mid, role in
                       [("user", "admin"), ("leader", "leader"), ("b", "worker"), ("c", "worker")]}
        self.server = Server(("127.0.0.1", 0), self.store)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def request(self, method, path, actor="user", data=None, key=None, headers=None):
        conn = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=10)
        hs = {"Authorization": "Bearer " + self.tokens.get(actor, "invalid")}
        if data is not None:
            hs.update({"Content-Type": "application/json", "Idempotency-Key": key or uuid.uuid4().hex})
        hs.update(headers or {})
        conn.request(method, path, json.dumps(data).encode() if data is not None else None, hs)
        response = conn.getresponse()
        raw = response.read()
        result = json.loads(raw) if raw and response.getheader("Content-Type", "").startswith("application/json") else raw.decode()
        status, response_headers = response.status, dict(response.getheaders())
        conn.close()
        return status, result, response_headers

    def create(self, owner="b", actor="leader", **extra):
        data = {"title": "为产品岗位做简历", "ownerId": owner, "source": "leader", "category": "resume", "acceptance": "关联岗位、成果链接"}
        data.update(extra)
        status, result, _ = self.request("POST", "/v1/tasks", actor, data)
        self.assertEqual(status, 201, result)
        return result["task"]

    def update(self, task, actor="b", **extra):
        data = {"version": task["version"], "kind": "progress", "body": "已整理岗位要求"}
        data.update(extra)
        return self.request("POST", f"/v1/tasks/{task['id']}/updates", actor, data)

    def test_authentication_required(self):
        self.assertEqual(self.request("GET", "/v1/snapshot", "missing")[0], 401)

    def test_worker_only_sees_own_tasks(self):
        b = self.create()
        c = self.create(owner="c")
        snap = self.request("GET", "/v1/snapshot", "b")[1]
        self.assertEqual([t["id"] for t in snap["tasks"]], [b["id"]])
        self.assertNotIn("c", [m["id"] for m in snap["members"]])
        self.assertEqual(self.update(c, "b")[0], 404)
        self.assertEqual(len(self.request("GET", "/v1/snapshot", "leader")[1]["tasks"]), 2)

    def test_direct_user_assignment_and_authenticated_identity(self):
        task = self.create(actor="b", source="user")
        self.assertEqual(task["createdBy"], "b")
        self.assertEqual(task["source"], "user")
        event = self.request("GET", "/v1/snapshot", "leader")[1]["events"][0]
        self.assertEqual(event["actorId"], "b")
        self.assertTrue(event["toLeader"])

    def test_spoofed_actor_or_timestamp_rejected(self):
        status, _, _ = self.request("POST", "/v1/tasks", "b", {"title": "fake", "actorId": "user", "createdAt": "yesterday"})
        self.assertEqual(status, 422)

    def test_worker_does_not_assign_other_worker(self):
        self.assertEqual(self.request("POST", "/v1/tasks", "b", {"title": "transfer", "ownerId": "c"})[0], 403)
        self.assertEqual(self.request("POST", "/v1/tasks", "b", {"title": "fake leader", "source": "leader"})[0], 403)

    def test_completion_report_requires_explicit_leader_approval_without_handoff(self):
        task = self.create()
        # A worker completion report is a submission, never a completed state
        # override or an implicit change of owner/reviewer.
        self.assertEqual(self.update(task, kind="completed", status="completed", body="报告完成但不得跳过验收")[0], 422)
        status, result, _ = self.update(task, kind="completed", body="简历已完成，等待 Leader 验收并安排后续")
        self.assertEqual(status, 200)
        submitted = result["task"]
        self.assertEqual((submitted["status"], submitted["ownerId"], submitted["reviewStage"]), ("awaiting_review", "b", "leader"))
        self.assertEqual(submitted["submissionSeq"], 1)
        self.assertEqual(self.update(submitted, "b", kind="approved")[0], 403)
        self.assertEqual(self.update(submitted, "user", kind="approved")[0], 403)
        snap = self.request("GET", "/v1/snapshot", "leader")[1]
        self.assertEqual(snap["events"][0]["kind"], "submitted")
        self.assertFalse(any(e["kind"] in {"handoff", "review", "approved"} for e in snap["events"]))
        self.assertEqual(self.request("GET", "/v1/snapshot", "c")[1]["tasks"], [])
        status, result, _ = self.update(submitted, "leader", kind="approved", body="验收已通过，负责人保持 B")
        self.assertEqual(status, 200)
        self.assertEqual((result["task"]["status"], result["task"]["ownerId"]), ("completed", "b"))
        self.assertEqual(self.update(submitted, "leader", kind="approved")[0], 409)
        snap = self.request("GET", "/v1/snapshot", "leader")[1]
        self.assertEqual(snap["events"][0]["kind"], "approved")
        self.assertFalse(any(e["kind"] == "handoff" for e in snap["events"]))

    def test_leader_handoff_preserves_source_and_revokes_old_owner(self):
        task = self.create(actor="b", source="user")
        status, result, _ = self.update(task, "leader", kind="handoff", ownerId="c", body="按额度余量调整负责人")
        self.assertEqual(status, 200)
        self.assertEqual(result["task"]["source"], "user")
        self.assertEqual(self.request("GET", "/v1/snapshot", "b")[1]["tasks"], [])
        self.assertEqual(len(self.request("GET", "/v1/snapshot", "c")[1]["tasks"]), 1)
        events = self.request("GET", "/v1/snapshot", "leader")[1]["events"]
        self.assertIn("b → c", events[0]["body"])

    def test_leader_result_can_notify_worker(self):
        task = self.create(owner="leader")
        status, _, _ = self.update(task, "leader", kind="handoff", ownerId="b", notifyMemberId="b", body="已完成方案整理，交给 B 跟进")
        self.assertEqual(status, 200)
        event = self.request("GET", "/v1/snapshot", "b")[1]["events"][0]
        self.assertEqual(event["notifyMemberId"], "b")
        self.assertTrue(event["toLeader"])

    def test_optimistic_lock(self):
        task = self.create()
        self.assertEqual(self.update(task)[0], 200)
        self.assertEqual(self.update(task)[0], 409)

    def test_concurrent_updates_only_one_wins(self):
        task = self.create()
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            statuses = list(pool.map(lambda i: self.update(task, body=f"进展 {i}")[0], range(8)))
        self.assertEqual(statuses.count(200), 1)
        self.assertEqual(statuses.count(409), 7)

    def test_idempotent_retry_and_mismatch(self):
        data = {"title": "one task", "source": "user"}
        key = "same-key-001"
        first = self.request("POST", "/v1/tasks", "b", data, key)
        repeat = self.request("POST", "/v1/tasks", "b", data, key)
        self.assertEqual(first[:2], repeat[:2])
        self.assertEqual(self.request("POST", "/v1/tasks", "b", {"title": "different"}, key)[0], 409)
        self.assertEqual(len(self.request("GET", "/v1/snapshot", "leader")[1]["tasks"]), 1)

    def test_old_idempotency_does_not_leak_after_transfer(self):
        data = {"title": "private", "source": "user"}
        task = self.request("POST", "/v1/tasks", "b", data, "same-key-002")[1]["task"]
        self.update(task, "leader", kind="handoff", ownerId="c", body="交给 C")
        self.assertEqual(self.request("POST", "/v1/tasks", "b", data, "same-key-002")[0], 404)

    def test_read_and_review_are_separate_from_completion(self):
        task = self.create()
        status, result, _ = self.update(task, kind="read", body="已阅读")
        self.assertEqual(status, 200)
        self.assertEqual(result["task"]["status"], "pending")
        task = result["task"]
        self.assertEqual(self.update(task, kind="review")[0], 403)
        self.assertEqual(self.update(task, "leader", kind="review", status="completed")[0], 422)
        result = self.update(task, "leader", kind="review", body="核对需求通过")[1]
        self.assertEqual(result["task"]["status"], "pending")

    def test_completion_requires_explicit_report(self):
        task = self.create()
        self.assertEqual(self.update(task, status="completed")[0], 422)
        self.assertEqual(self.update(task, kind="completed", status="completed", body="")[0], 422)

    def test_announcements_visible_to_all_but_leader_writes(self):
        data = {"kind": "rule", "title": "协作约定", "body": "完成后汇报 Leader，不自动交给其他 Worker。"}
        self.assertEqual(self.request("POST", "/v1/announcements", "b", data)[0], 403)
        self.assertEqual(self.request("POST", "/v1/announcements", "leader", data)[0], 201)
        self.assertEqual(self.request("GET", "/v1/snapshot", "c")[1]["announcements"][0]["kind"], "rule")

    def test_cache_etag_only_changes_for_visible_data(self):
        status, snap, headers = self.request("GET", "/v1/snapshot", "b")
        self.assertEqual(status, 200)
        h = {"If-None-Match": headers["ETag"]}
        self.create(owner="c")
        self.assertEqual(self.request("GET", "/v1/snapshot", "b", headers=h)[0], 304)
        self.create(owner="b")
        self.assertEqual(self.request("GET", "/v1/snapshot", "b", headers=h)[0], 200)

    def test_summary_and_markdown_share_permissions(self):
        self.create()
        self.create(owner="c", title="秘密 C 任务")
        self.assertEqual(self.request("GET", "/v1/summary", "b")[1]["total"], 1)
        body = self.request("GET", "/v1/summary.md", "b")[1]
        self.assertIn("TASK-000001", body)
        self.assertNotIn("秘密 C", body)

    def test_quota_has_server_timestamp_and_group(self):
        data = {"note": "账户页面显示本周余量约 60%；手动记录", "budgetGroup": "shared-account-1"}
        self.assertEqual(self.request("POST", "/v1/members/me/quota", "b", data)[0], 200)
        me = self.request("GET", "/v1/snapshot", "b")[1]["me"]
        self.assertIn("60%", me["quotaNote"])
        self.assertTrue(me["quotaUpdatedAt"].endswith("Z"))
        self.assertEqual(me["budgetGroup"], "shared-account-1")

    def test_event_log_append_only(self):
        self.create()
        with self.store.connection() as db:
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("DELETE FROM events")
            with self.assertRaises(sqlite3.IntegrityError):
                db.execute("UPDATE events SET body='tampered'")

    def test_bad_types_links_and_injection(self):
        self.assertEqual(self.request("POST", "/v1/tasks", "b", ["bad"])[0], 422)
        self.assertEqual(self.request("POST", "/v1/tasks", "b", {"title": 7})[0], 422)
        self.assertEqual(self.request("POST", "/v1/tasks", "b", {"title": "bad", "jobURL": "javascript:alert(1)"})[0], 422)
        task = self.create(actor="b", source="self", title="'; DROP TABLE tasks; --")
        self.assertEqual(task["title"], "'; DROP TABLE tasks; --")
        self.assertEqual(len(self.request("GET", "/v1/snapshot", "b")[1]["tasks"]), 1)


if __name__ == "__main__":
    unittest.main(verbosity=2)
