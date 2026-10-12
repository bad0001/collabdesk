"""Isolated watch client fixtures: no real service, model, key or scheduler."""
import concurrent.futures
from contextlib import redirect_stdout
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import io
import json
import os
from pathlib import Path
import ssl
import tempfile
import threading
import unittest
from unittest.mock import patch
from urllib.parse import parse_qs, urlsplit

import watch_probe
from transport import load_state, save_state

WORKSPACE = "w" * 32
CURSOR_A = "A" * 32
CURSOR_B = "B" * 32


def payload(cursor=CURSOR_A):
    return {"workspaceId": WORKSPACE, "cursor": cursor, "tasks": 3, "auths": 2, "alerts": 1, "messages": 4}


class WatchHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.server.calls.append({"path": self.path, "headers": dict(self.headers)})
        self.send_response(self.server.status)
        self.send_header("Content-Type", self.server.content_type)
        body = self.server.body
        self.send_header("Content-Length", str(self.server.length if self.server.length is not None else len(body)))
        if self.server.location:
            self.send_header("Location", self.server.location)
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    def log_message(self, *args):
        pass


class WatchProbeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = Path(self.temp.name) / "nested" / "watch.json"
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), WatchHandler)
        self.server.status = 200
        self.server.content_type = "application/json; charset=utf-8"
        self.server.body = json.dumps(payload()).encode()
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
        return watch_probe.probe(self.base, WORKSPACE, self.path, allow_loopback=True, **kwargs)

    def test_initial_wake_ack_then_twenty_unchanged_requests(self):
        first = self.run_probe(now=1000)
        self.assertTrue(first["wake"])
        self.assertEqual(first["reason"], "initial-sync")
        self.assertEqual(first["cursor"], CURSOR_A)
        call_count = len(self.server.calls)
        ack = self.run_probe(ack=first["cursor"])
        self.assertEqual(ack["reason"], "acknowledged")
        self.assertEqual(len(self.server.calls), call_count, "ack must be local-only")
        for index in range(20):
            result = self.run_probe(now=1060 + 60 * index)
            self.assertFalse(result["wake"])
            self.assertEqual(result["reason"], "unchanged")
        self.assertEqual(len(self.server.calls), 21)
        self.assertEqual(self.path.stat().st_mode & 0o777, 0o600)
        self.assertEqual((self.path.parent / "watch.json.lock").stat().st_mode & 0o777, 0o600)
        self.assertEqual(self.path.parent.stat().st_mode & 0o777, 0o700)
        for item in self.server.calls:
            parsed = urlsplit(item["path"])
            self.assertEqual(parsed.path, "/v1/watch")
            self.assertEqual(parse_qs(parsed.query), {"workspace": [WORKSPACE]})
            self.assertNotIn("Authorization", item["headers"])
            self.assertNotIn("X-API-Key", item["headers"])
            self.assertNotIn("heartbeat", item["path"])

    def test_cooldown_and_change_after_successful_processing(self):
        self.assertTrue(self.run_probe(now=1000)["wake"])
        self.server.body = json.dumps(payload(CURSOR_B)).encode()
        waiting = self.run_probe(now=1020)
        self.assertFalse(waiting["wake"])
        self.assertEqual(waiting["reason"], "awaiting-agent")
        self.assertEqual(load_state(self.path)["requested"], CURSOR_A)
        self.run_probe(ack=CURSOR_A)
        changed = self.run_probe(now=1030)
        self.assertTrue(changed["wake"])
        self.assertEqual(changed["reason"], "changed")
        self.assertEqual(changed["cursor"], CURSOR_B)

    def test_newer_wake_rejects_stale_ack(self):
        self.run_probe(now=1000)
        self.server.body = json.dumps(payload(CURSOR_B)).encode()
        self.assertTrue(self.run_probe(now=1600)["wake"])
        original = self.path.read_bytes()
        with self.assertRaisesRegex(watch_probe.WatchError, "stale ack rejected"):
            self.run_probe(ack=CURSOR_A)
        self.assertEqual(self.path.read_bytes(), original)
        self.run_probe(ack=CURSOR_B)
        self.assertEqual(load_state(self.path)["acknowledged"], CURSOR_B)

    def test_parallel_requests_lock_the_same_checkpoint(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            results = list(pool.map(lambda _: self.run_probe(now=1000), range(2)))
        self.assertEqual(sum(result["wake"] for result in results), 1)
        self.assertEqual(load_state(self.path)["requested"], CURSOR_A)

    def test_ack_before_a_wake_and_missing_cursor_are_rejected(self):
        with self.assertRaises(watch_probe.WatchError):
            self.run_probe(ack=CURSOR_A)
        self.assertFalse(self.path.exists())
        self.assertEqual(self.server.calls, [])

    def test_dry_run_does_not_write_or_acknowledge(self):
        self.assertTrue(self.run_probe(dry_run=True)["wake"])
        self.assertFalse(self.path.exists())
        self.run_probe(now=1000)
        original = self.path.read_bytes()
        self.run_probe(ack=CURSOR_A, dry_run=True)
        self.assertEqual(self.path.read_bytes(), original)

    def test_origin_and_workspace_scope_checked_before_network(self):
        self.run_probe(now=1000)
        calls = len(self.server.calls)
        original = self.path.read_bytes()
        for base, workspace in [("https://different.example", WORKSPACE), (self.base, "x" * 32)]:
            with self.assertRaisesRegex(watch_probe.WatchError, "separate watch state"):
                watch_probe.probe(base, workspace, self.path, allow_loopback=True)
        self.assertEqual(len(self.server.calls), calls)
        self.assertEqual(self.path.read_bytes(), original)

    def test_origin_validation_and_normalization(self):
        self.assertEqual(watch_probe.validated_origin("https://EXAMPLE.com:443/"), "https://example.com")
        for origin in ["http://example.com", "https://u:p@example.com", "https://example.com/path", "https://example.com?x=1", "https://example.com#x", "https://example.com\n", "https://example.com:bad", "https://example.com:0", "https://exa%40mple.com"]:
            with self.subTest(origin=origin), self.assertRaises(watch_probe.WatchError):
                watch_probe.validated_origin(origin)
        with self.assertRaises(watch_probe.WatchError):
            watch_probe.validated_origin(self.base)

    def test_http_errors_and_redirects_have_one_attempt_and_preserve_state(self):
        self.run_probe(now=1000)
        original = self.path.read_bytes()
        for status in [301, 302, 307, 308, 401, 404, 429, 500, 503]:
            with self.subTest(status=status):
                self.server.status = status
                self.server.location = self.base + "/redirect-target"
                before = len(self.server.calls)
                with self.assertRaises(watch_probe.WatchError) as failure:
                    self.run_probe()
                self.assertEqual(failure.exception.category, "redirect" if status < 400 else "http")
                self.assertEqual(len(self.server.calls), before + 1)
                self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse(any("redirect-target" in item["path"] for item in self.server.calls))

    def test_payload_limits_and_strict_schema_preserve_state(self):
        self.run_probe(now=1000)
        original = self.path.read_bytes()
        cases = [b"x" * 2049, b"{}", b"[]", b"not JSON", b"\xff", json.dumps({**payload(), "text": "private"}).encode(),
                 json.dumps({**payload(), "tasks": True}).encode(), json.dumps({**payload(), "tasks": -1}).encode(),
                 json.dumps({**payload(), "cursor": "invalid"}).encode(), json.dumps({**payload(), "workspaceId": "x" * 32}).encode(),
                 json.dumps({**payload(), "tasks": 2**64}).encode(), b'{"workspaceId":"w","workspaceId":"w"}',
                 json.dumps({**payload(), "tasks": float("nan")}).encode()]
        for body in cases:
            with self.subTest(body=body[:60]):
                self.server.body = body
                with self.assertRaises(watch_probe.WatchError):
                    self.run_probe()
                self.assertEqual(self.path.read_bytes(), original)
        self.server.body = json.dumps(payload()).encode()
        self.server.content_type = "text/html"
        with self.assertRaises(watch_probe.WatchError):
            self.run_probe()
        self.assertEqual(self.path.read_bytes(), original)

    def test_timeout_failure_has_no_automatic_retry(self):
        self.run_probe(now=1000)
        original = self.path.read_bytes()
        with patch("watch_probe.request.build_opener") as build:
            build.return_value.open.side_effect = TimeoutError("fixture")
            with self.assertRaises(watch_probe.WatchError) as failure:
                self.run_probe(timeout=0.1)
        self.assertEqual(failure.exception.category, "timeout")
        self.assertEqual(build.return_value.open.call_count, 1)
        self.assertEqual(self.path.read_bytes(), original)

    def test_existing_environment_proxy_is_respected(self):
        # This fixture proxy directly returns a watch packet; no real egress.
        with patch.dict(os.environ, {"http_proxy": self.base, "HTTP_PROXY": self.base, "no_proxy": "", "NO_PROXY": ""}):
            remote_fixture = "http://localhost:9"
            response = watch_probe.probe(remote_fixture, WORKSPACE, self.path, allow_loopback=True)
        self.assertTrue(response["wake"])
        self.assertEqual(len(self.server.calls), 1)
        self.assertEqual(self.server.calls[0]["path"], "http://localhost:9/v1/watch?workspace=" + WORKSPACE)
        self.assertNotIn("Authorization", self.server.calls[0]["headers"])

    def test_tls_uses_verified_default_context(self):
        with patch("watch_probe.request.build_opener") as build:
            build.return_value.open.side_effect = TimeoutError()
            with self.assertRaises(watch_probe.WatchError):
                watch_probe.fetch_watch("https://example.com", WORKSPACE)
        handlers = build.call_args.args
        self.assertIsInstance(handlers[0], watch_probe.request.ProxyHandler)
        self.assertIsInstance(handlers[1], watch_probe.NoRedirect)
        context = handlers[2]._context
        self.assertEqual(context.verify_mode, ssl.CERT_REQUIRED)
        self.assertTrue(context.check_hostname)

    def test_cli_failure_is_not_quiet_empty_work(self):
        self.run_probe(now=1000)
        self.server.status = 503
        output = io.StringIO()
        args = ["--base-url", self.base, "--workspace", WORKSPACE, "--state", str(self.path), "--allow-loopback"]
        with redirect_stdout(output):
            status = watch_probe.main(args)
        result = json.loads(output.getvalue())
        self.assertEqual(status, 2)
        self.assertFalse(result["ok"])
        self.assertFalse(result["wake"])
        self.assertEqual(result["error"]["category"], "http")
        self.assertTrue(result["statePreserved"])

    def test_atomic_state_failure_preserves_previous_checkpoint(self):
        self.run_probe(now=1000)
        original = self.path.read_bytes()
        with patch("transport.os.replace", side_effect=OSError("fixture storage error")):
            with self.assertRaises(watch_probe.WatchError):
                self.run_probe(ack=CURSOR_A)
        self.assertEqual(self.path.read_bytes(), original)
        self.assertFalse(list(self.path.parent.glob(".collab-*")))

    def test_invalid_state_is_not_reused(self):
        save_state(self.path, {"kind": watch_probe.STATE_KIND, "baseURL": self.base,
                               "workspaceId": WORKSPACE, "requested": CURSOR_A, "requestedAt": "not a number"})
        original = self.path.read_bytes()
        with self.assertRaises(watch_probe.WatchError):
            self.run_probe()
        self.assertEqual(self.server.calls, [])
        self.assertEqual(self.path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
