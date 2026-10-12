#!/usr/bin/env python3
"""Disposable loopback-only fixture for iOS integration tests. No user records."""
from pathlib import Path
import json
import os
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
from server import Server, Store, digest

os.umask(0o077)
with tempfile.TemporaryDirectory(prefix="collab-qa-") as directory:
    store = Store(Path(directory) / "qa.sqlite3")
    admin_token = store.add_member("qa-user", "接口联调用户", "admin")
    leader_token = store.add_member("leader", "Leader", "leader")
    worker_token = store.add_member("b", "AI B", "worker")
    leader = store.authenticate("Bearer " + leader_token)
    worker = store.authenticate("Bearer " + worker_token)
    card_task = store.mutate(leader, "/v1/tasks", {"title": "实时接口联调任务", "ownerId": "b", "source": "user"}, "qa-fixture-create")[1]["task"]
    store.mutate(worker, "/v1/authorizations", {"taskId": card_task["id"], "kind": "card", "subject": "需要账号授权卡",
                                                  "reason": "一次性本地 UI 测试申请", "accountLabel": "测试招聘账号"}, "qa-fixture-auth-card")
    normal_task = store.mutate(leader, "/v1/tasks", {"title": "联调普通授权任务", "ownerId": "b", "source": "leader"}, "qa-fixture-normal-task")[1]["task"]
    store.mutate(worker, "/v1/authorizations", {"taskId": normal_task["id"], "kind": "normal", "subject": "继续处理普通任务",
                                                  "reason": "一次性本地 UI 测试申请"}, "qa-fixture-auth-normal")
    server = Server(("127.0.0.1", 0), store, check_interval=1)
    connection = {"url": f"http://127.0.0.1:{server.server_port}", "token": admin_token, "leaderToken": leader_token,
                  "workerToken": worker_token}
    fixture = ROOT / "ios/CollabDeskUITests/qa-connection.json"
    fixture.write_text(json.dumps(connection))
    print(f"QA server listening on loopback port {server.server_port}; throwaway fixture written, token not printed.", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        fixture.unlink(missing_ok=True)
        print("QA server stopped; disposable database and credential fixture removed.", flush=True)
