import http.client
import json
from pathlib import Path
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import uuid

from server import Store, Server


class PushWorkerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.store = Store(Path(self.temp.name) / 'fixture.sqlite3')
        self.tokens = {k: self.store.add_member(k, k, role) for k, role in
                       [('user', 'admin'), ('leader', 'leader'), ('b', 'worker'), ('c', 'worker')]}
        self.server = None

    def tearDown(self):
        if self.server:
            self.server.shutdown()
            self.http_thread.join(5)
            self.server.server_close()
        self.temp.cleanup()

    def start(self, interval=None):
        self.server = Server(('127.0.0.1', 0), self.store, check_interval=interval)
        self.http_thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.http_thread.start()

    def request(self, member, method, path, data=None):
        c = http.client.HTTPConnection(*self.server.server_address, timeout=3)
        headers = {'Authorization': 'Bearer ' + self.tokens[member]} if member else {}
        if data is not None:
            headers.update({'Content-Type': 'application/json', 'Idempotency-Key': uuid.uuid4().hex})
        c.request(method, path, None if data is None else json.dumps(data), headers)
        r = c.getresponse(); result = r.status, json.loads(r.read()); c.close()
        return result

    def test_contacts_are_minimal_and_do_not_expand_worker_snapshot(self):
        self.start()
        code, body = self.request('b', 'GET', '/v1/messages/recipients')
        self.assertEqual(code, 200)
        self.assertEqual({m['id'] for m in body['members']}, {'leader', 'user'})
        self.assertTrue(all(set(m) == {'id', 'name', 'role'} for m in body['members']))
        self.assertEqual(self.request(None, 'GET', '/v1/messages/recipients')[0], 401)
        self.assertEqual(self.request('b', 'GET', '/v1/messages/recipients?memberId=c')[0], 422)
        self.assertEqual({m['id'] for m in self.request('user', 'GET', '/v1/messages/recipients')[1]['members']}, {'leader', 'b', 'c'})
        snap = self.request('b', 'GET', '/v1/snapshot')[1]
        self.assertEqual({m['id'] for m in snap['members']}, {'leader', 'b'})
        self.assertEqual(self.request('b', 'POST', '/v1/messages', {'recipientId': 'c', 'body': 'not permitted'})[0], 403)

    def test_slow_push_does_not_block_http_or_checker(self):
        started = threading.Event(); release = threading.Event()
        def drain(store, stop_event=None):
            started.set(); release.wait(3)
        with patch('server.notifications.drain', side_effect=drain):
            self.start(.03)
            self.assertTrue(started.wait(2))
            initial = self.request(None, 'GET', '/healthz')
            self.assertEqual(initial[0], 200)
            self.assertTrue(self.server.check_thread.is_alive())
            self.assertIsNot(self.server.check_thread, self.server.push_thread)
            result = self.request('b', 'POST', '/v1/messages', {'recipientId': 'user', 'body': 'fixture'})
            self.assertEqual(result[0], 201)
            self.assertTrue(self.server.push_wake.is_set())
            release.set()
            self.server.shutdown(); self.http_thread.join(5); self.server.server_close()
            self.assertFalse(self.server.push_thread.is_alive())
            self.server = None

    def test_message_commit_wakes_push_without_waiting_checker_period(self):
        calls = 0; ready = threading.Event(); woken = threading.Event(); lock = threading.Lock()
        def drain(store, stop_event=None):
            nonlocal calls
            with lock:
                calls += 1
                if calls == 1: ready.set()
                else:
                    with store.connection() as db:
                        self.assertEqual(db.execute('SELECT count(*) FROM messages').fetchone()[0], 1)
                    woken.set()
        with patch('server.notifications.drain', side_effect=drain):
            self.start(60)
            self.assertTrue(ready.wait(2))
            code, _ = self.request('b', 'POST', '/v1/messages', {'recipientId': 'user', 'body': 'fixture'})
            self.assertEqual(code, 201)
            self.assertTrue(woken.wait(2))
            self.server.shutdown(); self.http_thread.join(5); self.server.server_close()
            self.server = None


if __name__ == '__main__': unittest.main()
