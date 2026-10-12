import concurrent.futures
from pathlib import Path
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
import uuid
from unittest.mock import MagicMock, patch
from email.utils import formatdate
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
from server import Server, Store
from connect import connect
from pull import apply_response, pull
from signal_probe import decision
from transport import ClientError, endpoint, get_json, load_state, save_state


class ClientTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.directory = Path(self.temp.name)
        self.store = Store(self.directory / "api.sqlite3")
        self.tokens = {m: self.store.add_member(m, m, role) for m, role in [("leader", "leader"), ("b", "worker"), ("c", "worker")]}
        self.actors = {m: self.store.authenticate("Bearer " + t) for m, t in self.tokens.items()}
        self.server = Server(("127.0.0.1", 0), self.store, public_signal=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True); self.thread.start()
        self.base = f"http://127.0.0.1:{self.server.server_port}"
        self.path = self.directory / "nested" / "workspace.json"

    def tearDown(self):
        self.server.shutdown(); self.server.server_close(); self.thread.join()
        self.temp.cleanup()

    def send(self, path, data):
        return self.store.mutate(self.actors["leader"], path, data, uuid.uuid4().hex)[1]

    def test_real_pull_atomic_save_then_revoke(self):
        task = self.send("/v1/tasks", {"title": "real client fixture", "ownerId": "b"})["task"]
        result = pull(self.base, self.tokens["b"], self.path, dry_run=True)
        self.assertFalse(result["saved"]); self.assertFalse(self.path.exists())
        pull(self.base, self.tokens["b"], self.path)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual(load_state(self.path)["workspaceId"], self.store.snapshot(self.actors["b"])["workspaceId"])
        self.assertIn("tasks:" + task["id"], load_state(self.path)["entities"])
        self.send(f"/v1/tasks/{task['id']}/updates", {"version": task["version"], "kind": "handoff", "ownerId": "c", "body": "reassign"})
        pull(self.base, self.tokens["b"], self.path)
        self.assertNotIn("tasks:" + task["id"], load_state(self.path)["entities"])
        self.assertNotIn("real client fixture", self.path.read_text())

    def test_client_expired_cursor_resets_and_member_cannot_mix(self):
        pull(self.base, self.tokens["b"], self.path)
        with self.store.connection() as db:
            db.execute("UPDATE sync_cursors SET created_at='2000-01-01T00:00:00.000Z'")
        self.assertTrue(pull(self.base, self.tokens["b"], self.path)["reset"])
        original = self.path.read_bytes()
        with self.assertRaises(ClientError):
            pull(self.base, self.tokens["c"], self.path)
        self.assertEqual(self.path.read_bytes(), original)

    def test_auth_error_and_atomic_write_failure_preserve_checkpoint(self):
        pull(self.base, self.tokens["b"], self.path)
        original = self.path.read_bytes()
        with self.assertRaises(ClientError):
            pull(self.base, "incorrect", self.path)
        self.assertEqual(self.path.read_bytes(), original)
        with patch("transport.os.replace", side_effect=OSError("fixture write failure")):
            with self.assertRaises(OSError):
                save_state(self.path, {"cursor": "new"})
        self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse(list(self.path.parent.glob(".collab-*")))

    def test_parallel_same_checkpoint_serializes(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            values = list(pool.map(lambda _: pull(self.base, self.tokens["b"], self.path), range(2)))
        self.assertTrue(all(v["saved"] for v in values))
        self.assertEqual(pull(self.base, self.tokens["b"], self.path)["changes"], 0)

    def test_envelope_validation_preserves_old_state(self):
        old = {"baseURL": "https://example.com", "memberId": "b", "workspaceId": "fixture-workspace", "entities": {"tasks:1": {"title": "old"}}}
        before = json.dumps(old)
        with self.assertRaises(ClientError):
            apply_response(old, {"schemaVersion": 2, "syncVersion": 1, "memberId": "b", "workspaceId": "fixture-workspace", "new_cursor": "x" * 43, "reset": False,
                                 "items": [{"collection": "tasks", "id": "1", "op": "delete"}, {"op": "invalid"}]}, "https://example.com")
        self.assertEqual(json.dumps(old), before)

    def test_same_origin_and_member_database_rebuild_rejected(self):
        task = self.send("/v1/tasks", {"title": "Original audit record", "ownerId": "b"})["task"]
        pull(self.base, self.tokens["b"], self.path)
        original = self.path.read_bytes()
        old_state = load_state(self.path)
        replacement = Store(self.directory / "replacement.sqlite3")
        token = replacement.add_member("b", "b", "worker")
        actor = replacement.authenticate("Bearer " + token)
        self.assertNotEqual(replacement.snapshot(actor)["workspaceId"], old_state["workspaceId"])
        self.server.store = replacement
        with self.assertRaisesRegex(ClientError, "different workspace"):
            pull(self.base, token, self.path)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertIn("tasks:" + task["id"], load_state(self.path)["entities"])
        self.assertTrue(any(k.startswith("events:") for k in old_state["entities"]))

    def make_legacy(self):
        self.send("/v1/tasks", {"title": "Keep immutable audit during upgrade", "ownerId": "b"})
        pull(self.base, self.tokens["b"], self.path)
        legacy = load_state(self.path)
        legacy.pop("workspaceId")
        legacy["localNotes"] = "Existing notes are not proof of processing"
        save_state(self.path, legacy)
        return legacy, self.path.read_bytes(), self.path.with_name(self.path.name + ".pre-workspace-v1")

    def test_legacy_checkpoint_full_sync_preserves_audit_and_private_original(self):
        legacy, original, backup = self.make_legacy()
        with patch("pull.get_json", wraps=get_json) as request:
            result = pull(self.base, self.tokens["b"], self.path)
        self.assertNotIn("cursor=", request.call_args.args[1])
        self.assertTrue(result["reset"])
        self.assertTrue(result["checkpointMigrated"])
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(backup.stat().st_mode & 0o777, 0o600)
        current = load_state(self.path)
        self.assertEqual(current["workspaceId"], self.store.snapshot(self.actors["b"])["workspaceId"])
        self.assertEqual({k: v for k, v in legacy["entities"].items() if k.startswith("events:")},
                         {k: v for k, v in current["entities"].items() if k.startswith("events:")})
        self.assertNotIn("processed", current)
        self.assertNotIn("acknowledged", current)
        self.assertFalse(pull(self.base, self.tokens["b"], self.path)["checkpointMigrated"])
        self.assertEqual(backup.read_bytes(), original)

    def test_legacy_dry_run_forces_reset_without_file_changes(self):
        _, original, backup = self.make_legacy()
        with patch("pull.get_json", wraps=get_json) as request:
            result = pull(self.base, self.tokens["b"], self.path, dry_run=True)
        self.assertTrue(result["reset"])
        self.assertFalse(result["saved"])
        self.assertFalse(result["checkpointMigrated"])
        self.assertNotIn("cursor=", request.call_args.args[1])
        self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse(backup.exists())

    def test_legacy_delta_response_rejected_without_archive(self):
        _, original, backup = self.make_legacy()
        response = self.store.incremental(self.actors["b"])
        response["reset"] = False
        with patch("pull.get_json", return_value=(200, response, {})):
            with self.assertRaisesRegex(ClientError, "requires a full reset"):
                pull(self.base, self.tokens["b"], self.path)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse(backup.exists())

    def test_initial_delta_response_rejected_without_creating_cache(self):
        response = self.store.incremental(self.actors["b"])
        response["reset"] = False
        with patch("pull.get_json", return_value=(200, response, {})):
            with self.assertRaisesRegex(ClientError, "requires a full reset"):
                pull(self.base, self.tokens["b"], self.path)
        self.assertFalse(self.path.exists())

    def test_legacy_archive_failure_keeps_original_and_cleans_temporary_file(self):
        _, original, backup = self.make_legacy()
        with patch("pull.os.link", side_effect=OSError("fixture archive failure")):
            with self.assertRaises(OSError):
                pull(self.base, self.tokens["b"], self.path)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse(backup.exists())
        self.assertFalse(list(self.path.parent.glob(".collab-*")))

    def test_legacy_backup_conflict_and_atomic_save_failure_preserve_original(self):
        _, original, backup = self.make_legacy()
        backup.write_bytes(b"Different historical cache")
        with self.assertRaisesRegex(ClientError, "backup conflict"):
            pull(self.base, self.tokens["b"], self.path)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(backup.read_bytes(), b"Different historical cache")
        backup.unlink()
        with patch("transport.os.replace", side_effect=OSError("fixture write failure")):
            with self.assertRaises(OSError):
                pull(self.base, self.tokens["b"], self.path)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertEqual(backup.read_bytes(), original)
        self.assertTrue(pull(self.base, self.tokens["b"], self.path)["checkpointMigrated"])
        self.assertFalse(list(self.path.parent.glob(".collab-*")))

    def test_missing_workspace_fail_closed_even_on_reset(self):
        pull(self.base, self.tokens["b"], self.path)
        original = self.path.read_bytes()
        response = self.store.incremental(self.actors["b"])
        for value in (None, "", 42):
            with self.subTest(value=value):
                bad = {**response, "workspaceId": value}
                with patch("pull.get_json", return_value=(200, bad, {})):
                    with self.assertRaisesRegex(ClientError, "Missing workspace identity"):
                        pull(self.base, self.tokens["b"], self.path)
                self.assertEqual(self.path.read_bytes(), original)
        bad = dict(response)
        bad.pop("workspaceId")
        with patch("pull.get_json", return_value=(200, bad, {})):
            with self.assertRaisesRegex(ClientError, "Missing workspace identity"):
                pull(self.base, self.tokens["b"], self.path)
        self.assertEqual(self.path.read_bytes(), original)

    def test_expired_cursor_failed_full_sync_keeps_cache_and_heartbeat(self):
        pull(self.base, self.tokens["b"], self.path)
        original = self.path.read_bytes()
        with patch("pull.get_json", side_effect=[(410, {"error": "expired"}, {}), (503, {"error": "retry"}, {})]) as request:
            with self.assertRaisesRegex(ClientError, "HTTP 503"):
                pull(self.base, self.tokens["b"], self.path, heartbeat=True)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertIn("cursor=", request.call_args_list[0].args[1])
        self.assertNotIn("cursor=", request.call_args_list[1].args[1])
        self.assertTrue(all("heartbeat=1" in call.args[1] for call in request.call_args_list))

    def test_connect_rejects_wrong_role_member_or_workspace_before_save(self):
        workspace = self.store.snapshot(self.actors["b"])["workspaceId"]
        cases = [("b", "leader", workspace), ("c", "worker", workspace), ("b", "worker", "wrong-workspace")]
        for member, role, expected_workspace in cases:
            with self.subTest(member=member, role=role, workspace=expected_workspace):
                with self.assertRaisesRegex(ClientError, "Identity or workspace mismatch"):
                    connect(self.base, self.tokens["b"], self.path, member, role, expected_workspace, save=True)
                self.assertFalse(self.path.exists())

    def test_connect_binds_verified_snapshot_to_incremental_response(self):
        snapshot = self.store.snapshot(self.actors["leader"])
        response = self.store.incremental(self.actors["leader"])
        response["workspaceId"] = "Changed between requests"
        with patch("connect.get_json", return_value=(200, snapshot, {})), patch("pull.get_json", return_value=(200, response, {})):
            with self.assertRaisesRegex(ClientError, "Verified identity or workspace changed"):
                connect(self.base, self.tokens["leader"], self.path, "leader", "leader", snapshot["workspaceId"], save=True)
        self.assertFalse(self.path.exists())

    def test_connect_success_saves_bound_cache_without_starting_polling(self):
        workspace = self.store.snapshot(self.actors["leader"])["workspaceId"]
        result = connect(self.base, self.tokens["leader"], self.path, "leader", "leader", workspace, save=True)
        self.assertTrue(result["sync"]["saved"])
        self.assertFalse(result["pollingStarted"])
        self.assertEqual(load_state(self.path)["workspaceId"], workspace)

    def test_https_guard_and_home_expansion_cli(self):
        for value in ["http://example.com", "https://me:secret@example.com", "https://example.com?q=1", "https://example.com/path"]:
            with self.assertRaises(ClientError):
                endpoint(value)
        env = {**os.environ, "HOME": str(self.directory), "COLLAB_TOKEN": self.tokens["b"]}
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("pull.py")), "--base-url", self.base, "--allow-loopback",
                                 "--state", "~/platform/workspace.json"], capture_output=True, text=True, env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.directory / "platform/workspace.json").exists())
        self.assertNotIn(self.tokens["b"], result.stdout + result.stderr)

    def test_hook_needs_ack_and_retries_after_failed_wake(self):
        state, result = decision({}, "x" * 32, 1000)
        self.assertTrue(result["wake"])
        self.assertFalse(decision(state, "x" * 32, 1120)[1]["wake"])
        self.assertTrue(decision(state, "x" * 32, 1600)[1]["wake"])
        ack = {**state, "acknowledged": "x" * 32, "requested": None}
        self.assertFalse(decision(ack, "x" * 32, 1700)[1]["wake"])
        self.assertTrue(decision(ack, "y" * 32, 1700)[1]["wake"])

    def test_hook_cli_no_secret_no_heartbeat_and_ack_race(self):
        env = {k: v for k, v in os.environ.items() if k != "COLLAB_TOKEN"}
        cmd = [sys.executable, str(Path(__file__).with_name("signal_probe.py")), "--base-url", self.base, "--allow-loopback", "--state", str(self.directory / "signal.json")]
        def run(extra=()):
            result = subprocess.run([*cmd, *extra], env=env, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return json.loads(result.stdout)
        self.assertTrue(run(["--dry-run"])["wake"])
        self.assertFalse((self.directory / "signal.json").exists())
        revision = run()["revision"]
        self.assertFalse(run()["wake"])
        self.send("/v1/tasks", {"title": "Arrived during processing"})
        run(["--ack", revision])
        self.assertTrue(run()["wake"], "ack captured signal must not hide newer work")
        self.assertTrue(all(m["lastPollAt"] is None for m in self.store.snapshot(self.actors["leader"])["members"]))


class TransportTests(unittest.TestCase):
    def response(self, status, retry=""):
        value = MagicMock()
        value.status = status
        value.read.return_value = b'{"ok": true}'
        value.getheader.return_value = retry
        value.getheaders.return_value = []
        return value

    def test_retry_respects_short_retry_after(self):
        connection = MagicMock()
        connection.getresponse.side_effect = [self.response(429, "5"), self.response(200)]
        with patch("transport.http.client.HTTPSConnection", return_value=connection), patch("transport.time.sleep") as sleep:
            self.assertEqual(get_json("https://example.com", "/v1/updates", "test-token")[0], 200)
            self.assertEqual(sleep.call_args.args[0], 5)
            self.assertEqual(connection.request.call_count, 2)

    def test_long_date_retry_after_returns_to_caller(self):
        connection = MagicMock()
        connection.getresponse.return_value = self.response(429, formatdate(time.time() + 180, usegmt=True))
        with patch("transport.http.client.HTTPSConnection", return_value=connection), patch("transport.time.sleep") as sleep:
            with self.assertRaises(ClientError): get_json("https://example.com", "/v1/updates")
            sleep.assert_not_called()
            self.assertEqual(connection.request.call_count, 1)

    def test_redirect_does_not_forward_token(self):
        connection = MagicMock()
        connection.getresponse.return_value = self.response(302)
        with patch("transport.http.client.HTTPSConnection", return_value=connection):
            with self.assertRaises(ClientError): get_json("https://example.com", "/v1/updates", "test-token")
            self.assertEqual(connection.request.call_count, 1)

    def test_network_retries_are_bounded(self):
        connection = MagicMock()
        connection.request.side_effect = OSError("fixture")
        with patch("transport.http.client.HTTPSConnection", return_value=connection), patch("transport.time.sleep") as sleep:
            with self.assertRaises(ClientError): get_json("https://example.com", "/v1/updates")
            self.assertEqual(connection.request.call_count, 3)
            self.assertEqual(sleep.call_count, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
