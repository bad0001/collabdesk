"""Member watch fixtures: anonymous loopback polling and captured local ack only."""
import concurrent.futures
from contextlib import redirect_stdout
import io
import json
import os
from pathlib import Path
import ssl
import tempfile
import threading
import unittest
from unittest.mock import patch
from http.server import ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

import watch_probe
from test_watch_probe import WatchHandler, WORKSPACE, CURSOR_A, CURSOR_B, payload as global_payload
from transport import load_state, save_state

MEMBER = "worker-one"
OTHER_MEMBER = "worker-two"
CURSOR_C = "C" * 32
TYPES = ("tasks", "auths", "alerts", "messages", "announcements")
BASE_REVISIONS = {key: chr(ord("a") + index) * 32 for index, key in enumerate(TYPES)}


def member_payload(cursor=CURSOR_A, changed=None, member_id=MEMBER):
    return {"workspaceId": WORKSPACE, "memberId": member_id, "cursor": cursor,
            "tasks": 3, "auths": 2, "alerts": 1, "messages": 4, "announcements": 5,
            "revisions": {**BASE_REVISIONS, **(changed or {})}}


class MemberWatchProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "nested" / "member-watch.json"
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), WatchHandler)
        self.server.status = 200
        self.server.content_type = "application/json; charset=utf-8"
        self.server.body = json.dumps(member_payload()).encode()
        self.server.length = None
        self.server.location = None
        self.server.calls = []
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.environment = patch.dict(os.environ, {"http_proxy": "", "https_proxy": "", "HTTP_PROXY": "", "HTTPS_PROXY": "", "all_proxy": "", "ALL_PROXY": "", "no_proxy": "*", "NO_PROXY": "*"})
        self.environment.start()

    def tearDown(self):
        self.environment.stop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join()
        self.temp.cleanup()

    def run_probe(self, **kwargs):
        return watch_probe.probe(self.base, WORKSPACE, self.path, allow_loopback=True, member_id=MEMBER, **kwargs)

    def set_payload(self, value):
        self.server.body = json.dumps(value).encode()

    def acknowledge_initial(self):
        first = self.run_probe(now=1000)
        self.run_probe(ack=first["cursor"])
        return first

    def test_initial_sync_private_snapshot_local_ack_and_unchanged(self):
        first = self.run_probe(now=1000)
        self.assertTrue(first["wake"])
        self.assertEqual(first["reason"], "initial-sync")
        self.assertEqual(first["changeTypes"], list(TYPES))
        self.assertEqual(first["memberId"], MEMBER)
        self.assertEqual(first["counts"], {key: member_payload()[key] for key in TYPES})
        state = load_state(self.path)
        self.assertEqual(state["kind"], watch_probe.MEMBER_STATE_KIND)
        self.assertEqual((state["baseURL"], state["workspaceId"], state["memberId"]), (self.base, WORKSPACE, MEMBER))
        self.assertEqual(state["requested"], CURSOR_A)
        self.assertEqual(state["requestedRevisions"], BASE_REVISIONS)
        self.assertIsNone(state["acknowledgedRevisions"])
        calls = len(self.server.calls)
        with patch("watch_probe.fetch_watch", side_effect=AssertionError("ack contacted network")):
            ack = self.run_probe(ack=first["cursor"])
        self.assertEqual(ack["reason"], "acknowledged")
        self.assertEqual(ack["changeTypes"], [])
        self.assertEqual(len(self.server.calls), calls)
        state = load_state(self.path)
        self.assertEqual(state["acknowledgedRevisions"], BASE_REVISIONS)
        self.assertIsNone(state["requested"])
        self.assertIsNone(state["requestedRevisions"])
        for index in range(20):
            unchanged = self.run_probe(now=1060 + index * 60)
            self.assertFalse(unchanged["wake"])
            self.assertEqual(unchanged["reason"], "unchanged")
            self.assertEqual(unchanged["changeTypes"], [])
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.path.parent / "member-watch.json.lock").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.parent.stat().st_mode & 0o777, 0o700)
        for call in self.server.calls:
            parsed = urlsplit(call["path"])
            self.assertEqual(parsed.path, "/v1/watch")
            self.assertEqual(parse_qs(parsed.query), {"workspace": [WORKSPACE], "memberId": [MEMBER]})
            self.assertNotIn("Authorization", call["headers"])
            self.assertNotIn("X-API-Key", call["headers"])
            self.assertNotIn("heartbeat", call["path"])

    def test_each_collection_change_is_measured_against_ack_not_poll(self):
        for kind in TYPES:
            with self.subTest(kind=kind):
                self.path.unlink(missing_ok=True)
                self.set_payload(member_payload())
                self.acknowledge_initial()
                changed = member_payload(CURSOR_B, {kind: "z" * 32})
                self.set_payload(changed)
                wake = self.run_probe(now=1100)
                self.assertTrue(wake["wake"])
                self.assertEqual(wake["reason"], "changed")
                self.assertEqual(wake["changeTypes"], [kind])
                waiting = self.run_probe(now=1101)
                self.assertFalse(waiting["wake"])
                self.assertEqual(waiting["reason"], "awaiting-agent")
                self.assertEqual(waiting["changeTypes"], [kind], "a mere poll never acknowledges revisions")
                self.assertEqual(load_state(self.path)["acknowledgedRevisions"], BASE_REVISIONS)
                self.run_probe(ack=CURSOR_B)
                self.assertEqual(self.run_probe(now=1102)["changeTypes"], [])

    def test_concurrent_change_then_captured_old_ack_preserves_new_work(self):
        self.acknowledge_initial()
        revisions_b = {"tasks": "x" * 32}
        revisions_c = {**revisions_b, "messages": "y" * 32}
        self.set_payload(member_payload(CURSOR_B, revisions_b))
        self.assertEqual(self.run_probe(now=1100)["changeTypes"], ["tasks"])
        captured = load_state(self.path)
        self.set_payload(member_payload(CURSOR_C, revisions_c))
        waiting = self.run_probe(now=1120)
        self.assertFalse(waiting["wake"])
        self.assertEqual(waiting["reason"], "awaiting-agent")
        self.assertEqual(waiting["cursor"], CURSOR_C)
        self.assertEqual(waiting["changeTypes"], ["tasks", "messages"])
        self.assertEqual(load_state(self.path), captured, "awaiting polls retain the captured snapshot")
        self.run_probe(ack=CURSOR_B)
        state = load_state(self.path)
        self.assertEqual(state["acknowledged"], CURSOR_B)
        self.assertEqual(state["acknowledgedRevisions"], {**BASE_REVISIONS, **revisions_b})
        newer = self.run_probe(now=1130)
        self.assertTrue(newer["wake"])
        self.assertEqual(newer["cursor"], CURSOR_C)
        self.assertEqual(newer["changeTypes"], ["messages"])
        self.assertEqual(load_state(self.path)["requestedRevisions"], {**BASE_REVISIONS, **revisions_c})

    def test_initial_capture_is_preserved_before_first_ack(self):
        self.run_probe(now=1000)
        self.set_payload(member_payload(CURSOR_B, {"announcements": "z" * 32}))
        waiting = self.run_probe(now=1001)
        self.assertFalse(waiting["wake"])
        self.assertEqual(waiting["changeTypes"], list(TYPES))
        self.assertEqual(load_state(self.path)["requestedRevisions"], BASE_REVISIONS)
        self.run_probe(ack=CURSOR_A)
        wake = self.run_probe(now=1002)
        self.assertTrue(wake["wake"])
        self.assertEqual(wake["changeTypes"], ["announcements"])

    def test_cooldown_retry_replaces_latest_capture_and_rejects_stale_ack(self):
        self.acknowledge_initial()
        self.set_payload(member_payload(CURSOR_B, {"tasks": "x" * 32}))
        self.run_probe(now=1100)
        latest = member_payload(CURSOR_C, {"tasks": "x" * 32, "alerts": "y" * 32})
        self.set_payload(latest)
        self.assertFalse(self.run_probe(now=1699)["wake"])
        retry = self.run_probe(now=1700)
        self.assertTrue(retry["wake"])
        self.assertEqual(retry["changeTypes"], ["tasks", "alerts"])
        before = self.path.read_bytes()
        with self.assertRaisesRegex(watch_probe.WatchError, "stale ack rejected"):
            self.run_probe(ack=CURSOR_B)
        self.assertEqual(self.path.read_bytes(), before)
        self.run_probe(ack=CURSOR_C)
        self.assertEqual(load_state(self.path)["acknowledgedRevisions"], latest["revisions"])
        self.assertEqual(self.run_probe(now=1701)["changeTypes"], [])

    def test_retry_same_capture_retains_revisions_and_zero_cooldown(self):
        self.run_probe(now=1000)
        retry = self.run_probe(now=1600)
        self.assertTrue(retry["wake"])
        self.assertEqual(retry["reason"], "initial-sync")
        self.assertEqual(load_state(self.path)["requestedRevisions"], BASE_REVISIONS)
        self.assertTrue(self.run_probe(now=1601, cooldown=0)["wake"])
        self.run_probe(ack=CURSOR_A)
        self.assertFalse(self.run_probe(now=1602, cooldown=0)["wake"])

    def test_parallel_poll_captures_only_one_wake(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.run_probe(now=1000), range(2)))
        self.assertEqual(sum(result["wake"] for result in results), 1)
        self.assertEqual(load_state(self.path)["requestedRevisions"], BASE_REVISIONS)

    def test_scope_rejects_global_other_member_workspace_and_origin_before_network(self):
        self.run_probe(now=1000)
        before = self.path.read_bytes()
        calls = len(self.server.calls)
        scopes = [(self.base, WORKSPACE, None), (self.base, WORKSPACE, OTHER_MEMBER),
                  (self.base, "x" * 32, MEMBER), ("https://different.example", WORKSPACE, MEMBER)]
        for base, workspace, member_id in scopes:
            with self.subTest(scope=(base, workspace, member_id)):
                with self.assertRaisesRegex(watch_probe.WatchError, "separate watch state"):
                    watch_probe.probe(base, workspace, self.path, member_id=member_id, allow_loopback=True)
                self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(len(self.server.calls), calls)
        global_path = Path(self.temp.name) / "global.json"
        self.set_payload(global_payload())
        watch_probe.probe(self.base, WORKSPACE, global_path, allow_loopback=True, now=1000)
        before = global_path.read_bytes()
        with self.assertRaises(watch_probe.WatchError):
            watch_probe.probe(self.base, WORKSPACE, global_path, member_id=MEMBER, allow_loopback=True)
        self.assertEqual(global_path.read_bytes(), before)

    def test_member_validation_happens_before_state_or_network(self):
        invalid = ["", "Worker", "1worker", "a" * 49, "a b", "a/b", "a\n", None, 12, True]
        for member_id in invalid:
            if member_id is None:
                continue  # None deliberately selects the legacy scope.
            with self.subTest(member_id=member_id), self.assertRaises(watch_probe.WatchError):
                watch_probe.probe(self.base, WORKSPACE, self.path, member_id=member_id, allow_loopback=True)
        self.assertFalse(self.path.exists())
        self.assertEqual(self.server.calls, [])
        for member_id in ["a", "worker_1-2", "a" * 48]:
            self.assertEqual(watch_probe.validated_member_id(member_id), member_id)

    def test_member_schema_is_exact_and_errors_preserve_checkpoint(self):
        self.run_probe(now=1000)
        before = self.path.read_bytes()
        good = member_payload()
        cases = [global_payload(), {**good, "memberId": OTHER_MEMBER}, {**good, "workspaceId": "x" * 32},
                 {**good, "cursor": "bad"}, {**good, "tasks": True}, {**good, "announcements": -1},
                 {**good, "announcements": 2**63}, {**good, "secret": "fixture"},
                 {**good, "revisions": None}, {**good, "revisions": []},
                 {**good, "revisions": {**BASE_REVISIONS, "extra": "x" * 32}}]
        for key in good:
            cases.append({field: value for field, value in good.items() if field != key})
        for key in TYPES:
            cases.append({**good, "revisions": {field: value for field, value in BASE_REVISIONS.items() if field != key}})
            for invalid in ["x" * 31, "x" * 33, "/" * 32, 1, True, None]:
                cases.append({**good, "revisions": {**BASE_REVISIONS, key: invalid}})
        for value in cases:
            with self.subTest(value=value):
                self.set_payload(value)
                with self.assertRaises(watch_probe.WatchError) as failure:
                    self.run_probe()
                self.assertEqual(failure.exception.category, "protocol")
                self.assertEqual(self.path.read_bytes(), before)
        self.server.body = json.dumps(good).replace('"tasks": "' + BASE_REVISIONS["tasks"] + '"',
                            '"tasks": "' + BASE_REVISIONS["tasks"] + '", "tasks": "z"').encode()
        with self.assertRaises(watch_probe.WatchError):
            self.run_probe()
        self.assertEqual(self.path.read_bytes(), before)
        self.server.body = b"x" * 2049
        with self.assertRaises(watch_probe.WatchError):
            self.run_probe()
        self.assertEqual(self.path.read_bytes(), before)

    def test_identical_cursor_with_inconsistent_revision_snapshot_is_error(self):
        for acknowledged in [False, True]:
            with self.subTest(acknowledged=acknowledged):
                self.path.unlink(missing_ok=True)
                self.set_payload(member_payload())
                self.run_probe(now=1000)
                if acknowledged:
                    self.run_probe(ack=CURSOR_A)
                before = self.path.read_bytes()
                self.set_payload(member_payload(CURSOR_A, {"tasks": "z" * 32}))
                with self.assertRaisesRegex(watch_probe.WatchError, "conflicts") as failure:
                    self.run_probe(now=1001)
                self.assertEqual(failure.exception.category, "protocol")
                self.assertEqual(self.path.read_bytes(), before)

    def test_invalid_snapshot_state_never_resets_or_fetches(self):
        self.run_probe(now=1000)
        valid = load_state(self.path)
        cases = [{key: value for key, value in valid.items() if key != "requestedRevisions"},
                 {key: value for key, value in valid.items() if key != "requestedAt"},
                 {**valid, "requestedRevisions": None}, {**valid, "requestedRevisions": {"tasks": "x" * 32}},
                 {**valid, "requested": None}, {**valid, "acknowledgedRevisions": BASE_REVISIONS},
                 {**valid, "acknowledged": CURSOR_B}, {**valid, "requestedAt": True},
                 {**valid, "requested": "bad"}, {**valid, "requestedAt": float("nan")}]
        calls = len(self.server.calls)
        for state in cases:
            with self.subTest(state=state):
                save_state(self.path, state)
                before = self.path.read_bytes()
                with self.assertRaises(watch_probe.WatchError) as failure:
                    self.run_probe()
                self.assertEqual(failure.exception.category, "state")
                self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(len(self.server.calls), calls)

    def test_invalid_current_time_never_corrupts_snapshot(self):
        self.run_probe(now=1000)
        before = self.path.read_bytes()
        for now in [True, "later", float("nan"), float("inf")]:
            with self.subTest(now=now), self.assertRaises(watch_probe.WatchError) as failure:
                self.run_probe(now=now)
            self.assertEqual(failure.exception.category, "config")
            self.assertEqual(self.path.read_bytes(), before)

    def test_dry_run_preserves_capture_and_acknowledged_snapshot(self):
        first = self.run_probe(dry_run=True, now=1000)
        self.assertTrue(first["wake"])
        self.assertEqual(first["changeTypes"], list(TYPES))
        self.assertFalse(self.path.exists())
        self.acknowledge_initial()
        before = self.path.read_bytes()
        self.set_payload(member_payload(CURSOR_B, {"auths": "x" * 32}))
        self.assertEqual(self.run_probe(dry_run=True, now=1100)["changeTypes"], ["auths"])
        self.assertEqual(self.path.read_bytes(), before)
        self.run_probe(now=1101)
        before = self.path.read_bytes()
        self.run_probe(ack=CURSOR_B, dry_run=True)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertEqual(load_state(self.path)["acknowledgedRevisions"], BASE_REVISIONS)

    def test_ack_requires_current_capture_and_is_atomic(self):
        with self.assertRaises(watch_probe.WatchError):
            self.run_probe(ack=CURSOR_A)
        self.assertFalse(self.path.exists())
        self.assertEqual(self.server.calls, [])
        self.run_probe(now=1000)
        before = self.path.read_bytes()
        with patch("transport.os.replace", side_effect=OSError("fixture storage error")):
            with self.assertRaises(watch_probe.WatchError):
                self.run_probe(ack=CURSOR_A)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertFalse(list(self.path.parent.glob(".collab-*")))
        self.assertIsNone(load_state(self.path)["acknowledgedRevisions"])

    def test_http_redirect_timeout_tls_errors_are_one_attempt_not_unchanged(self):
        self.run_probe(now=1000)
        before = self.path.read_bytes()
        for status in [301, 302, 307, 308, 401, 404, 429, 500, 503]:
            with self.subTest(status=status):
                self.server.status = status
                self.server.location = self.base + "/redirect-target"
                calls = len(self.server.calls)
                with self.assertRaises(watch_probe.WatchError) as failure:
                    self.run_probe()
                self.assertEqual(failure.exception.category, "redirect" if status < 400 else "http")
                self.assertEqual(len(self.server.calls), calls + 1)
                self.assertEqual(self.path.read_bytes(), before)
        for error, category in [(TimeoutError("fixture"), "timeout"), (ssl.SSLError("fixture"), "tls"),
                                (OSError("fixture"), "network")]:
            with patch("watch_probe.request.build_opener") as build:
                build.return_value.open.side_effect = error
                with self.assertRaises(watch_probe.WatchError) as failure:
                    self.run_probe(timeout=0.1)
                self.assertEqual(build.return_value.open.call_count, 1)
                self.assertEqual(failure.exception.category, category)
                self.assertEqual(self.path.read_bytes(), before)

    def test_member_proxy_and_tls_reuse_existing_transport_policy(self):
        with patch.dict(os.environ, {"http_proxy": self.base, "HTTP_PROXY": self.base, "no_proxy": "", "NO_PROXY": ""}):
            response = watch_probe.probe("http://localhost:9", WORKSPACE, self.path, member_id=MEMBER, allow_loopback=True)
        self.assertTrue(response["wake"])
        self.assertEqual(self.server.calls[0]["path"], f"http://localhost:9/v1/watch?workspace={WORKSPACE}&memberId={MEMBER}")
        self.assertNotIn("Authorization", self.server.calls[0]["headers"])
        with patch("watch_probe.request.build_opener") as build:
            build.return_value.open.side_effect = TimeoutError()
            with self.assertRaises(watch_probe.WatchError):
                watch_probe.fetch_watch("https://example.com", WORKSPACE, member_id=MEMBER)
        handlers = build.call_args.args
        self.assertIsInstance(handlers[0], watch_probe.request.ProxyHandler)
        self.assertIsInstance(handlers[1], watch_probe.NoRedirect)
        self.assertEqual(handlers[2]._context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(handlers[2]._context.check_hostname)

    def test_cli_member_success_ack_and_failure_schema(self):
        args = ["--base-url", self.base, "--workspace", WORKSPACE, "--member-id", MEMBER,
                "--state", str(self.path), "--allow-loopback"]
        output = io.StringIO()
        with redirect_stdout(output):
            status = watch_probe.main(args)
        initial = json.loads(output.getvalue())
        self.assertEqual(status, 0)
        self.assertEqual(initial["changeTypes"], list(TYPES))
        output = io.StringIO()
        with redirect_stdout(output):
            status = watch_probe.main(args + ["--ack", initial["cursor"]])
        self.assertEqual(status, 0)
        self.assertEqual(json.loads(output.getvalue())["reason"], "acknowledged")
        self.server.status = 503
        before = self.path.read_bytes()
        output = io.StringIO()
        with redirect_stdout(output):
            status = watch_probe.main(args)
        failure = json.loads(output.getvalue())
        self.assertEqual(status, 2)
        self.assertFalse(failure["ok"])
        self.assertTrue(failure["statePreserved"])
        self.assertEqual(failure["error"]["category"], "http")
        self.assertNotEqual(failure.get("reason"), "unchanged")
        self.assertNotIn("changeTypes", failure)
        self.assertEqual(self.path.read_bytes(), before)

    def test_legacy_output_and_schema_are_unextended(self):
        self.set_payload(global_payload())
        result = watch_probe.probe(self.base, WORKSPACE, self.path, allow_loopback=True, now=1000)
        self.assertNotIn("memberId", result)
        self.assertNotIn("changeTypes", result)
        self.assertEqual(set(result["counts"]), set(watch_probe.COUNTS))
        state = load_state(self.path)
        self.assertNotIn("requestedRevisions", state)
        self.assertNotIn("acknowledgedRevisions", state)
        self.assertEqual(state["kind"], watch_probe.STATE_KIND)
        self.assertEqual(watch_probe.validate_payload(json.dumps(global_payload()).encode(), WORKSPACE), global_payload())
        with self.assertRaises(watch_probe.WatchError):
            watch_probe.validate_payload(json.dumps(member_payload()).encode(), WORKSPACE)


if __name__ == "__main__":
    unittest.main()
