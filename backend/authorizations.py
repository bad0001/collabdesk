"""Task-scoped worker authorization requests with distinct Leader/user decisions."""
import re
import notifications
from common import APIError, choice, field


def migrate(db):
    version = db.execute("PRAGMA user_version").fetchone()[0]
    if version > 6:
        raise RuntimeError("Database is newer than this application")
    if version >= 4:
        return
    db.execute("BEGIN IMMEDIATE")
    try:
        db.execute("ALTER TABLE members ADD COLUMN profile_version INTEGER NOT NULL DEFAULT 1")
        db.execute("""CREATE TABLE authorization_requests(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            task_id TEXT NOT NULL REFERENCES tasks(id),
            requester_id TEXT NOT NULL REFERENCES members(id),
            kind TEXT NOT NULL CHECK(kind IN ('normal','card')),
            subject TEXT NOT NULL, reason TEXT NOT NULL, account_label TEXT NOT NULL DEFAULT '',
            state TEXT NOT NULL CHECK(state IN ('pending_leader','awaiting_user','approved','confirmed_external','denied','cancelled')),
            version INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
            decided_by TEXT REFERENCES members(id), decided_at TEXT, decision_note TEXT NOT NULL DEFAULT ''
        )""")
        db.execute("CREATE INDEX authorizations_task ON authorization_requests(task_id,id)")
        db.execute("""CREATE TABLE authorization_events(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            authorization_id INTEGER NOT NULL REFERENCES authorization_requests(id),
            task_id TEXT NOT NULL REFERENCES tasks(id), kind TEXT NOT NULL,
            actor_id TEXT NOT NULL REFERENCES members(id), actor_name TEXT NOT NULL,
            body TEXT NOT NULL, timestamp TEXT NOT NULL
        )""")
        for action in ("UPDATE", "DELETE"):
            db.execute(f"CREATE TRIGGER authorization_events_no_{action} BEFORE {action} ON authorization_events "
                       "BEGIN SELECT RAISE(ABORT, 'append-only'); END")
        db.execute("PRAGMA user_version=4")
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise


def serialize(row):
    keys = {"task_id": "taskId", "requester_id": "requesterId", "account_label": "accountLabel",
            "created_at": "createdAt", "updated_at": "updatedAt", "decided_by": "decidedBy",
            "decided_at": "decidedAt", "decision_note": "decisionNote"}
    return {keys.get(key, key): value for key, value in dict(row).items()}


def event(db, request_id, task_id, kind, actor, body, stamp):
    db.execute("INSERT INTO authorization_events(authorization_id,task_id,kind,actor_id,actor_name,body,timestamp) VALUES(?,?,?,?,?,?,?)",
               (request_id, task_id, kind, actor["id"], actor["name"], body, stamp))


def snapshot(db, actor):
    if actor["role"] in {"admin", "leader"}:
        requests = db.execute("SELECT * FROM authorization_requests ORDER BY id DESC").fetchall()
    else:
        requests = db.execute("SELECT * FROM authorization_requests WHERE requester_id=? ORDER BY id DESC", (actor["id"],)).fetchall()
    ids = [row["id"] for row in requests]
    events = []
    if ids:
        events = [{"id": row["id"], "authorizationId": row["authorization_id"], "taskId": row["task_id"],
                   "kind": row["kind"], "actorId": row["actor_id"], "actorName": row["actor_name"],
                   "body": row["body"], "timestamp": row["timestamp"]} for row in db.execute(
                       f"SELECT * FROM authorization_events WHERE authorization_id IN ({','.join('?' for _ in ids)}) ORDER BY id DESC", ids)]
    return {"authorizations": [serialize(row) for row in requests], "authorizationEvents": events}


def gate(db, actor, task_id, kind):
    if actor["role"] != "worker" or kind not in {"accepted", "progress", "completed", "submitted", "unblocked"}:
        return
    row = db.execute("""SELECT state FROM authorization_requests WHERE task_id=? AND requester_id=?
                        ORDER BY id DESC LIMIT 1""", (task_id, actor["id"])).fetchone()
    if row and row["state"] in {"pending_leader", "awaiting_user", "denied"}:
        raise APIError(409, "本任务有未获授权或被驳回的申请；请等待审批或联系 Leader")


def on_handoff(db, task_id, actor, old_owner, stamp):
    for row in db.execute("""SELECT * FROM authorization_requests WHERE task_id=? AND requester_id=?
                            AND state IN ('pending_leader','awaiting_user','denied')""", (task_id, old_owner)).fetchall():
        db.execute("""UPDATE authorization_requests SET state='cancelled',version=version+1,updated_at=?,
                      decided_by=?,decided_at=?,decision_note=? WHERE id=?""",
                   (stamp, actor["id"], stamp, "任务已转派，旧授权申请不延续给新负责人。", row["id"]))
        event(db, row["id"], task_id, "cancelled_on_handoff", actor, "任务已转派，旧申请终止。", stamp)


def apply(store, db, actor, path, data):
    if path == "/v1/authorizations":
        store.reject_unknown(data, {"taskId", "kind", "subject", "reason", "accountLabel", "reviewer"})
        if actor["role"] != "worker":
            raise APIError(403, "授权申请由执行 Worker 在自己的任务中发起")
        task_id = field(data, "taskId", limit=32, required=True)
        task = store.get_task(db, actor, task_id)
        if task["status"] in {"completed", "cancelled", "awaiting_review"}:
            raise APIError(409, "当前任务阶段不接受新的授权申请")
        if db.execute("""SELECT 1 FROM authorization_requests WHERE task_id=? AND requester_id=?
                        AND state IN ('pending_leader','awaiting_user') LIMIT 1""", (task_id, actor["id"])).fetchone():
            raise APIError(409, "本任务已有待处理的授权申请")
        kind = choice(data, "kind", {"normal", "card"}, "normal")
        subject = field(data, "subject", limit=200, required=True)
        reason = field(data, "reason", limit=4000, required=True)
        account_label = field(data, "accountLabel", limit=100, required=kind == "card")
        if kind == "normal" and account_label:
            raise APIError(422, "普通授权不填写外部账号名称")
        reviewer = choice(data, "reviewer", {"leader", "user"}, "user" if kind == "card" else "leader")
        if kind == "card" and reviewer != "user": raise APIError(422, "授权卡只交给用户")
        state = "awaiting_user" if reviewer == "user" else "pending_leader"
        stamp = store.now()
        cursor = db.execute("""INSERT INTO authorization_requests(task_id,requester_id,kind,subject,reason,account_label,state,created_at,updated_at)
                               VALUES(?,?,?,?,?,?,?,?,?)""",
                            (task_id, actor["id"], kind, subject, reason, account_label, state, stamp, stamp))
        db.execute("UPDATE authorization_requests SET reviewer=? WHERE id=?", (reviewer, cursor.lastrowid))
        event(db, cursor.lastrowid, task_id, "requested", actor, reason, stamp)
        if reviewer == "user": notifications.enqueue(db, f"authorization:{cursor.lastrowid}:user", "authorization_card" if kind == "card" else "authorization_user", "collabdesk://authorizations", stamp)
        return 201, {"authorization": serialize(db.execute("SELECT * FROM authorization_requests WHERE id=?", (cursor.lastrowid,)).fetchone())}

    escalation = re.fullmatch(r"/v1/authorizations/(\d+)/escalate", path)
    if escalation:
        store.reject_unknown(data, {"version", "note"})
        if actor["role"] != "leader": raise APIError(403, "由 Leader 转交用户审批")
        row = db.execute("SELECT * FROM authorization_requests WHERE id=?", (int(escalation[1]),)).fetchone()
        if row is None: raise APIError(404, "授权申请不存在")
        if type(data.get("version")) is not int or data["version"] != row["version"]: raise APIError(409, "申请已更新，请刷新")
        if row["kind"] != "normal" or row["state"] != "pending_leader": raise APIError(409, "当前申请不在 Leader 审批阶段")
        note = field(data, "note", limit=2000, required=True)
        stamp=store.now()
        db.execute("UPDATE authorization_requests SET reviewer='user',state='awaiting_user',version=version+1,updated_at=? WHERE id=?", (stamp,row["id"]))
        event(db,row["id"],row["task_id"],"escalated_to_user",actor,note,stamp)
        notifications.enqueue(db,f"authorization:{row['id']}:user","authorization_user","collabdesk://authorizations",stamp)
        return 200, {"authorization":serialize(db.execute("SELECT * FROM authorization_requests WHERE id=?",(row["id"],)).fetchone())}

    match = re.fullmatch(r"/v1/authorizations/(\d+)/decision", path)
    if match:
        store.reject_unknown(data, {"version", "action", "note"})
        row = db.execute("SELECT * FROM authorization_requests WHERE id=?", (int(match[1]),)).fetchone()
        if row is None:
            raise APIError(404, "授权申请不存在")
        if type(data.get("version")) is not int or data["version"] != row["version"]:
            raise APIError(409, "授权申请已有更新，请刷新后再处理")
        if row["kind"] == "card":
            if actor["role"] != "admin":
                raise APIError(403, "授权卡需用户在外部账号完成操作；Leader 只能查看和提醒")
            if row["state"] != "awaiting_user":
                raise APIError(409, "授权卡申请已处理")
            action = choice(data, "action", {"confirmed_external", "denied"}, "")
        else:
            if row["reviewer"] == "user" and actor["role"] != "admin": raise APIError(403, "此授权申请明确交由用户决定")
            if row["reviewer"] == "leader" and actor["role"] != "leader": raise APIError(403, "此授权申请交由 Leader 审批")
            if actor["role"] not in {"admin", "leader"}:
                raise APIError(403, "普通授权由 Leader 审批")
            if row["state"] != ("awaiting_user" if row["reviewer"] == "user" else "pending_leader"):
                raise APIError(409, "普通授权申请已处理")
            action = choice(data, "action", {"approved", "denied"}, "")
        note = field(data, "note", limit=2000, required=True)
        stamp = store.now()
        db.execute("""UPDATE authorization_requests SET state=?,version=version+1,updated_at=?,
                      decided_by=?,decided_at=?,decision_note=? WHERE id=?""",
                   (action, stamp, actor["id"], stamp, note, row["id"]))
        event(db, row["id"], row["task_id"], action, actor, note, stamp)
        return 200, {"authorization": serialize(db.execute("SELECT * FROM authorization_requests WHERE id=?", (row["id"],)).fetchone())}
    return None
