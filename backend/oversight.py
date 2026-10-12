"""Persistent, deduplicated alerts. This observes records; it never runs an AI."""
import json
import re
import authorizations
import notifications
from datetime import timedelta
from common import APIError, choice, field, link, parse_time, timestamp, seconds_since

DEFAULT_RULES = {"staleYellowSeconds": 7200, "staleRedSeconds": 14400,
                 "heartbeatYellowMisses": 2, "heartbeatRedMisses": 4,
                 "heartbeatGraceSeconds": 60}
TERMINAL = {"completed", "cancelled"}
STATUSES = {"pending", "in_progress", "needs_help", "awaiting_review", *TERMINAL}
KINDS = {"accepted", "progress", "question", "completed", "review", "read", "handoff",
         "blocked", "unblocked", "submitted", "approved", "rejected", "forward_user"}


def migrate(db):
    version = db.execute("PRAGMA user_version").fetchone()[0]
    if version > 6:
        raise RuntimeError("Database is newer than this application")
    if version >= 2:
        return
    db.execute("BEGIN IMMEDIATE")
    try:
        additions = {
            "members": {"participation": "TEXT NOT NULL DEFAULT 'idle'", "last_poll_at": "TEXT",
                        "rest_started_at": "TEXT"},
            "tasks": {"requires_review": "INTEGER NOT NULL DEFAULT 0", "last_progress_at": "TEXT",
                      "started_at": "TEXT", "review_submitted_at": "TEXT", "submission_seq": "INTEGER NOT NULL DEFAULT 0",
                      "rejection_streak": "INTEGER NOT NULL DEFAULT 0", "blocked_severity": "TEXT",
                      "blocked_reason": "TEXT NOT NULL DEFAULT ''"}
        }
        for table, columns in additions.items():
            current = {r[1] for r in db.execute(f"PRAGMA table_info({table})")}
            for column, declaration in columns.items():
                if column not in current:
                    db.execute(f"ALTER TABLE {table} ADD COLUMN {column} {declaration}")
        # Existing active tasks retain their original time evidence.
        db.execute("UPDATE tasks SET last_progress_at=updated_at, started_at=updated_at WHERE status='in_progress' AND last_progress_at IS NULL")
        statements = [
            """CREATE TABLE IF NOT EXISTS rules(id INTEGER PRIMARY KEY CHECK(id=1), version INTEGER NOT NULL, value TEXT NOT NULL)""",
            """CREATE TABLE IF NOT EXISTS alerts(
                id INTEGER PRIMARY KEY AUTOINCREMENT, dedup_key TEXT UNIQUE NOT NULL,
                kind TEXT NOT NULL, task_id TEXT REFERENCES tasks(id), member_id TEXT NOT NULL REFERENCES members(id),
                severity TEXT NOT NULL, title TEXT NOT NULL, detail TEXT NOT NULL, state TEXT NOT NULL,
                created_at TEXT NOT NULL, updated_at TEXT NOT NULL, snoozed_until TEXT, resolved_at TEXT,
                version INTEGER NOT NULL DEFAULT 1)""",
            """CREATE TABLE IF NOT EXISTS alert_events(
                id INTEGER PRIMARY KEY AUTOINCREMENT, alert_id INTEGER NOT NULL REFERENCES alerts(id),
                kind TEXT NOT NULL, actor_id TEXT, body TEXT NOT NULL, timestamp TEXT NOT NULL)""",
            """CREATE TABLE IF NOT EXISTS member_events(
                id INTEGER PRIMARY KEY AUTOINCREMENT, member_id TEXT NOT NULL REFERENCES members(id),
                kind TEXT NOT NULL, body TEXT NOT NULL, timestamp TEXT NOT NULL)""",
            """CREATE TABLE IF NOT EXISTS submissions(
                task_id TEXT NOT NULL REFERENCES tasks(id), seq INTEGER NOT NULL, producer_id TEXT NOT NULL REFERENCES members(id),
                timestamp TEXT NOT NULL, body TEXT NOT NULL, result_url TEXT NOT NULL, PRIMARY KEY(task_id,seq))""",
            """CREATE TABLE IF NOT EXISTS outputs(
                task_id TEXT NOT NULL REFERENCES tasks(id), kind TEXT NOT NULL, producer_id TEXT NOT NULL REFERENCES members(id),
                timestamp TEXT NOT NULL, PRIMARY KEY(task_id,kind))""",
            """CREATE TABLE IF NOT EXISTS messages(
                id INTEGER PRIMARY KEY AUTOINCREMENT, sender_id TEXT NOT NULL REFERENCES members(id), sender_name TEXT NOT NULL,
                recipient_id TEXT NOT NULL REFERENCES members(id), body TEXT NOT NULL, created_at TEXT NOT NULL, read_at TEXT)""",
            "CREATE INDEX IF NOT EXISTS alerts_member ON alerts(member_id, state)",
        ]
        for statement in statements:
            db.execute(statement)
        for table in ["alert_events", "member_events", "submissions", "outputs"]:
            for action in ["UPDATE", "DELETE"]:
                db.execute(f"CREATE TRIGGER IF NOT EXISTS {table}_no_{action} BEFORE {action} ON {table} BEGIN SELECT RAISE(ABORT, 'append-only'); END")
        db.execute("INSERT OR IGNORE INTO rules VALUES(1,1,?)", (json.dumps(DEFAULT_RULES),))
        # Backfill distinct legacy completions once, preserving attribution to their recorded actor.
        db.execute("""INSERT OR IGNORE INTO outputs(task_id,kind,producer_id,timestamp)
                    SELECT task_id,'submitted',actor_id,timestamp FROM events
                    WHERE kind='completed' AND task_id IS NOT NULL ORDER BY id""")
        db.execute("PRAGMA user_version=2")
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise


def read_rules(db):
    row = db.execute("SELECT * FROM rules WHERE id=1").fetchone()
    return {"version": row["version"], **json.loads(row["value"])}


def alert_event(db, alert_id, kind, body, stamp, actor=None):
    db.execute("INSERT INTO alert_events(alert_id,kind,actor_id,body,timestamp) VALUES(?,?,?,?,?)", (alert_id, kind, actor, body, stamp))


def conditions(db, stamp):
    rules = read_rules(db)
    result = {}
    members = {r["id"]: r for r in db.execute("SELECT * FROM members")}
    for member in members.values():
        if member["participation"] != "active" or member["heartbeat_mode"] != "periodic" or not member["last_poll_at"]:
            continue
        silence = seconds_since(stamp, member["last_poll_at"])
        yellow = member["poll_seconds"] * rules["heartbeatYellowMisses"] + rules["heartbeatGraceSeconds"]
        red = member["poll_seconds"] * rules["heartbeatRedMisses"] + rules["heartbeatGraceSeconds"]
        if silence >= yellow:
            severity = "red" if silence >= red else "yellow"
            result[f"heartbeat:{member['id']}"] = ("heartbeat", None, member["id"], severity, "成员未按约定访问",
                f"最近访问 {member['last_poll_at']}；约定每 {member['poll_seconds']} 秒轮询。心跳仅代表接口访问。")
    for task in db.execute("SELECT * FROM tasks"):
        if task["status"] in TERMINAL:
            continue
        owner = members[task["owner_id"]]
        if task["status"] == "in_progress" and owner["participation"] != "resting" and task["last_progress_at"]:
            elapsed = seconds_since(stamp, task["last_progress_at"])
            if elapsed >= rules["staleYellowSeconds"]:
                severity = "red" if elapsed >= rules["staleRedSeconds"] else "yellow"
                result[f"stale:{task['id']}"] = ("stale", task["id"], task["owner_id"], severity, "任务进展长时间未更新",
                    f"{task['title']}；最近实质进展 {task['last_progress_at']}。轮询与已读不算进展。")
        if task["blocked_severity"]:
            result[f"blocked:{task['id']}"] = ("blocked", task["id"], task["owner_id"], task["blocked_severity"],
                "Worker 需要协助", task["blocked_reason"])
        if task["rejection_streak"] >= 2:
            result[f"rejected:{task['id']}"] = ("rejected", task["id"], task["owner_id"], "red", "连续两轮验收被打回",
                f"{task['title']}；连续打回 {task['rejection_streak']} 轮，请 Leader 协助核对要求。")
    return result


def evaluate(db, stamp):
    """Caller holds a write transaction; changes and audit entries commit together."""
    active = conditions(db, stamp)
    existing = {r["dedup_key"]: r for r in db.execute("SELECT * FROM alerts")}
    for key, item in active.items():
        kind, task, member, severity, title, detail = item
        old = existing.get(key)
        if not old:
            cur = db.execute("""INSERT INTO alerts(dedup_key,kind,task_id,member_id,severity,title,detail,state,created_at,updated_at)
                              VALUES(?,?,?,?,?,?,?,'open',?,?)""", (key, kind, task, member, severity, title, detail, stamp, stamp))
            alert_event(db, cur.lastrowid, "opened", f"{severity} · {detail}", stamp)
            continue
        state, snoozed = old["state"], old["snoozed_until"]
        event = None
        if state == "resolved":
            state, snoozed, event = "open", None, "reopened"
        elif old["severity"] == "yellow" and severity == "red":
            state, snoozed, event = "open", None, "escalated"
        elif state == "snoozed" and snoozed and parse_time(stamp) >= parse_time(snoozed):
            state, snoozed, event = "open", None, "snooze_expired"
        changed = old["severity"] != severity or old["detail"] != detail or old["member_id"] != member or old["state"] != state
        if changed:
            db.execute("""UPDATE alerts SET member_id=?,severity=?,title=?,detail=?,state=?,snoozed_until=?,resolved_at=NULL,
                          updated_at=?,version=version+1 WHERE id=?""", (member, severity, title, detail, state, snoozed, stamp, old["id"]))
            alert_event(db, old["id"], event or "updated", f"{severity} · {detail}", stamp)
    for key, old in existing.items():
        if key not in active and old["state"] != "resolved":
            db.execute("UPDATE alerts SET state='resolved',resolved_at=?,updated_at=?,snoozed_until=NULL,version=version+1 WHERE id=?",
                       (stamp, stamp, old["id"]))
            alert_event(db, old["id"], "resolved", "异常条件已解除；历史记录保留。", stamp)


def visible_alerts(db, actor):
    if actor["role"] in {"admin", "leader"}:
        return db.execute("SELECT * FROM alerts ORDER BY id DESC").fetchall()
    return db.execute("""SELECT a.* FROM alerts a LEFT JOIN tasks t ON a.task_id=t.id
                         WHERE (a.task_id IS NULL AND a.member_id=?) OR t.owner_id=? ORDER BY a.id DESC""",
                      (actor["id"], actor["id"])).fetchall()


def serialize_alert(row):
    mapping = {"task_id": "taskId", "member_id": "memberId", "created_at": "createdAt", "updated_at": "updatedAt",
               "snoozed_until": "snoozedUntil", "resolved_at": "resolvedAt"}
    return {mapping.get(k, k): v for k, v in dict(row).items() if k != "dedup_key"}


def dashboard(db, stamp):
    rows = []
    cutoff = timestamp(parse_time(stamp) - timedelta(hours=24))
    for member in db.execute("SELECT * FROM members WHERE role IN ('worker','leader') ORDER BY id"):
        tasks = db.execute("SELECT * FROM tasks WHERE owner_id=? AND status NOT IN ('completed','cancelled')", (member["id"],)).fetchall()
        running = sorted([t for t in tasks if t["status"] == "in_progress" and t["started_at"]], key=lambda t: t["started_at"])
        waiting = sorted([t for t in tasks if t["status"] == "awaiting_review" and t["review_submitted_at"]], key=lambda t: t["review_submitted_at"])
        alerts = db.execute("SELECT severity,state FROM alerts WHERE member_id=? AND state!='resolved'", (member["id"],)).fetchall()
        counts = {r["kind"]: r["n"] for r in db.execute("SELECT kind,count(*) n FROM outputs WHERE producer_id=? AND timestamp>? AND timestamp<=? GROUP BY kind", (member["id"], cutoff, stamp))}
        rows.append({"memberId": member["id"], "name": member["name"], "role": member["role"], "participation": member["participation"],
                     "lastPollAt": member["last_poll_at"], "heartbeatMode": member["heartbeat_mode"], "openTasks": len(tasks), "inProgress": len(running),
                     "needsHelp": sum(t["status"] == "needs_help" for t in tasks), "awaitingReview": len(waiting),
                     "oldestTaskId": running[0]["id"] if running else None,
                     "oldestTaskTitle": running[0]["title"] if running else None,
                     "oldestStartedAt": running[0]["started_at"] if running else None,
                     "oldestReviewAt": waiting[0]["review_submitted_at"] if waiting else None,
                     "submitted24h": counts.get("submitted", 0), "approved24h": counts.get("approved", 0),
                     "redAlerts": sum(a["severity"] == "red" for a in alerts),
                     "yellowAlerts": sum(a["severity"] == "yellow" for a in alerts)})
    return sorted(rows, key=lambda r: (-r["redAlerts"], -r["yellowAlerts"], -r["openTasks"], r["memberId"]))


def extend_snapshot(db, actor, stamp):
    privileged = actor["role"] in {"admin", "leader"}
    alerts = visible_alerts(db, actor)
    ids = [r["id"] for r in alerts]
    histories = []
    if ids:
        histories = [{"id": r["id"], "alertId": r["alert_id"], "kind": r["kind"], "actorId": r["actor_id"],
                      "body": r["body"], "timestamp": r["timestamp"]} for r in db.execute(
                          f"SELECT * FROM alert_events WHERE alert_id IN ({','.join('?' for _ in ids)}) ORDER BY id DESC", ids)]
    messages = db.execute("SELECT * FROM messages ORDER BY id DESC" if privileged else
                          "SELECT * FROM messages WHERE sender_id=? OR recipient_id=? ORDER BY id DESC",
                          () if privileged else (actor["id"], actor["id"])).fetchall()
    member_events = db.execute("SELECT * FROM member_events ORDER BY id DESC" if privileged else
                              "SELECT * FROM member_events WHERE member_id=? ORDER BY id DESC", () if privileged else (actor["id"],)).fetchall()
    return {"alerts": [serialize_alert(r) for r in alerts], "alertEvents": histories,
            "dashboard": dashboard(db, stamp) if privileged else [], "rules": read_rules(db),
            "messages": [{"id": r["id"], "senderId": r["sender_id"], "senderName": r["sender_name"],
                          "recipientId": r["recipient_id"], "body": r["body"], "createdAt": r["created_at"], "readAt": r["read_at"]} for r in messages],
            "memberEvents": [dict(r) for r in member_events]}


def update_task(store, db, actor, task_id, data):
    store.reject_unknown(data, {"version", "kind", "body", "status", "ownerId", "resultURL", "notifyMemberId", "severity"})
    row = store.get_task(db, actor, task_id)
    if type(data.get("version")) is not int or data["version"] != row["version"]:
        raise APIError(409, "任务已更新，请刷新后使用最新 version 提交")
    kind = choice(data, "kind", KINDS, "progress")
    authorizations.gate(db, actor, task_id, kind)
    body = field(data, "body", limit=12000, required=True)
    owner = field(data, "ownerId", row["owner_id"], 48, True)
    status = choice(data, "status", STATUSES, row["status"])
    notify = field(data, "notifyMemberId", "", 48) or None
    stamp = store.now()
    if kind in {"handoff", "review", "approved", "rejected", "forward_user"} and not store.privileged(actor):
        raise APIError(403, "交接与验收由 Leader 或用户记录")
    if owner != row["owner_id"] and (not store.privileged(actor) or kind != "handoff"):
        raise APIError(403, "请由 Leader 使用 handoff 记录负责人变更")
    if notify:
        store.check_member(db, notify)
        if not store.privileged(actor) and notify != actor["id"]:
            if db.execute("SELECT role FROM members WHERE id=?", (notify,)).fetchone()[0] != "leader":
                raise APIError(403, "Worker 汇报给 Leader；后续协作由 Leader 安排")
    store.check_member(db, owner)
    if "severity" in data and kind != "blocked":
        raise APIError(422, "severity 只用于受阻上报")
    values = dict(row)
    values.update(owner_id=owner, status=status, version=row["version"] + 1, updated_at=stamp)
    if row["status"] == "awaiting_review" and kind not in {"approved", "rejected", "forward_user"} and status != row["status"]:
        raise APIError(409, "当前成果需先验收或打回，不通过附注跳过验收")
    if kind == "question" and status not in {row["status"], "needs_help"}:
        raise APIError(422, "提问保留当前状态，或标为待协助")
    if "resultURL" in data:
        values["result_url"] = link(data, "resultURL")
    if kind in {"read", "review"}:
        if status != row["status"] or "resultURL" in data:
            raise APIError(422, "已读或验过事件只留痕，不改变任务状态或成果")
    elif kind == "forward_user":
        if actor["role"] != "leader" or row["status"] != "awaiting_review" or row["review_stage"] != "leader":
            raise APIError(409, "只有 Leader 可将当前待验收成果转交用户终审")
        if status != "awaiting_review" or ("resultURL" in data and values["result_url"] != row["result_url"]):
            raise APIError(422, "转交用户不改变成果或任务状态")
        values["review_stage"] = "user"
        notifications.enqueue(db, f"review:{task_id}:{row['submission_seq']}", "review_user", f"collabdesk://task/{task_id}", stamp)
    elif kind in {"approved", "rejected"}:
        expected_role = "admin" if row["review_stage"] == "user" else "leader"
        if actor["role"] != expected_role: raise APIError(403, "按当前验收阶段交给 Leader 或用户处理")
        if not row["requires_review"] or row["status"] != "awaiting_review":
            raise APIError(409, "当前任务没有等待验收的成果版本")
        desired = "completed" if kind == "approved" else "in_progress"
        if "status" in data and status != desired:
            raise APIError(422, "验收操作与状态不一致")
        if "resultURL" in data and values["result_url"] != row["result_url"]:
            raise APIError(422, "验收不修改已经提交的成果链接")
        values["review_stage"] = "leader"
        values["status"] = desired
        values["review_submitted_at"] = None
        values["rejection_streak"] = 0 if kind == "approved" else row["rejection_streak"] + 1
        if kind == "rejected":
            values["last_progress_at"] = stamp
        else:
            producer = db.execute("SELECT producer_id FROM submissions WHERE task_id=? AND seq=?", (task_id, row["submission_seq"])).fetchone()[0]
            db.execute("INSERT OR IGNORE INTO outputs VALUES(?,?,?,?)", (task_id, "approved", producer, stamp))
    elif kind in {"completed", "submitted"}:
        desired = "awaiting_review"
        if row["status"] in TERMINAL or row["status"] == "awaiting_review":
            raise APIError(409, "该任务已提交或结束，请先处理已有结果")
        if "status" in data and status != desired:
            raise APIError(422, "所有任务先提交到 awaiting_review，由当前验收人批准后才 completed")
        values.update(requires_review=1, review_stage="leader", status=desired, submission_seq=row["submission_seq"] + 1, last_progress_at=stamp,
                      blocked_severity=None, blocked_reason="", review_submitted_at=stamp)
        db.execute("INSERT INTO submissions VALUES(?,?,?,?,?,?)", (task_id, values["submission_seq"], row["owner_id"], stamp, body, values["result_url"]))
        db.execute("INSERT OR IGNORE INTO outputs VALUES(?,?,?,?)", (task_id, "submitted", row["owner_id"], stamp))
        kind = "submitted"
    elif kind == "blocked":
        if row["status"] in TERMINAL or row["status"] == "awaiting_review":
            raise APIError(409, "请对执行中的任务上报受阻")
        if "status" in data and status != "needs_help":
            raise APIError(422, "受阻任务状态应为 needs_help")
        values.update(status="needs_help", blocked_severity=choice(data, "severity", {"yellow", "red"}, "yellow"), blocked_reason=body)
    elif kind == "unblocked":
        if row["status"] != "needs_help" or ("status" in data and status != "in_progress"):
            raise APIError(409, "请对待协助任务记录恢复执行")
        values.update(status="in_progress", blocked_severity=None, blocked_reason="", last_progress_at=stamp)
        values["started_at"] = row["started_at"] or stamp
    else:
        if status in {"awaiting_review", "completed"} and status != row["status"]:
            raise APIError(422, "请使用完成汇报或验收操作改变成果状态")
        if row["status"] == "awaiting_review" and (kind != "question" and kind != "handoff"):
            raise APIError(409, "先验收或打回当前成果，再更新执行状态")
        if kind == "handoff":
            if row["status"] == "awaiting_review" and owner != row["owner_id"]:
                raise APIError(409, "先验收或打回，再转派执行人")
            if owner != row["owner_id"]:
                # A handoff is a new execution segment, never auto-start the new worker.
                if "status" in data and status != "pending":
                    raise APIError(422, "转派后状态为 pending，由新负责人接单")
                values.update(status="pending", started_at=None, last_progress_at=None, blocked_severity=None, blocked_reason="")
        elif kind in {"accepted", "progress"}:
            if row["status"] in TERMINAL:
                raise APIError(409, "已结束任务保留历史；新工作请建立新任务")
            if kind == "accepted":
                if "status" in data and status != "in_progress":
                    raise APIError(422, "接单后状态应为 in_progress")
                values["status"] = "in_progress"
            if row["blocked_severity"] and values["status"] == "in_progress":
                raise APIError(422, "先用 unblocked 说明问题如何解决")
            values["last_progress_at"] = stamp
            if values["status"] == "in_progress":
                values["started_at"] = row["started_at"] or stamp
        # Questions are not progress and do not reset the timer.
        if values["status"] == "needs_help" and not values["blocked_severity"]:
            values.update(blocked_severity="yellow", blocked_reason=body)
    if values["status"] == "cancelled":
        values.update(blocked_severity=None, blocked_reason="", review_submitted_at=None)
    if kind in {"read", "review", "question", "handoff"} and row["status"] in TERMINAL and values["status"] != row["status"]:
        raise APIError(409, "已结束任务不通过附注重启")
    fields = ["owner_id", "status", "result_url", "version", "updated_at", "last_progress_at", "started_at", "review_submitted_at",
              "submission_seq", "rejection_streak", "blocked_severity", "blocked_reason", "review_stage", "requires_review"]
    db.execute(f"UPDATE tasks SET {','.join(f'{f}=?' for f in fields)} WHERE id=?", [values[f] for f in fields] + [task_id])
    if kind == "handoff" and owner != row["owner_id"]:
        authorizations.on_handoff(db, task_id, actor, row["owner_id"], stamp)
    if owner != row["owner_id"]:
        body = f"负责人：{row['owner_id']} → {owner}。\n" + body
    if values["status"] != row["status"]:
        body = f"状态：{row['status']} → {values['status']}。\n" + body
    store.add_event(db, actor, task_id, kind, body, notify or owner)
    return 200, {"task": store.task(db.execute("SELECT * FROM tasks WHERE id=?", (task_id,)).fetchone())}


def apply(store, db, actor, path, data):
    stamp = store.now()
    if path == "/v1/members/me/participation":
        store.reject_unknown(data, {"state", "pollSeconds", "reason", "heartbeatMode"})
        state = choice(data, "state", {"active", "resting", "idle"}, "idle")
        reason = field(data, "reason", limit=1000, required=True)
        row = db.execute("SELECT * FROM members WHERE id=?", (actor["id"],)).fetchone()
        mode = choice(data, "heartbeatMode", {"periodic", "event_driven"}, row["heartbeat_mode"])
        seconds = data.get("pollSeconds", row["poll_seconds"])
        if type(seconds) is not int or not 30 <= seconds <= 86400:
            raise APIError(422, "pollSeconds 应为 30–86400 秒")
        if state == "active" and row["rest_started_at"]:
            for task in db.execute("SELECT * FROM tasks WHERE owner_id=? AND status='in_progress'", (actor["id"],)).fetchall():
                adjusted = {}
                for name in ["last_progress_at", "started_at"]:
                    if task[name]:
                        start = max(parse_time(task[name]), parse_time(row["rest_started_at"]))
                        adjusted[name] = timestamp(parse_time(task[name]) + max(timedelta(0), parse_time(stamp) - start))
                if adjusted:
                    db.execute(f"UPDATE tasks SET {','.join(f'{k}=?' for k in adjusted)},version=version+1,updated_at=? WHERE id=?", [*adjusted.values(), stamp, task["id"]])
                    store.add_event(db, actor, task["id"], "resumed_clock", "恢复协作；进展计时扣除已声明的休息时间。", actor["id"])
        resting_at = (row["rest_started_at"] or stamp) if state == "resting" else None
        last_poll = stamp if state == "active" else row["last_poll_at"]
        db.execute("UPDATE members SET participation=?,poll_seconds=?,last_poll_at=?,rest_started_at=?,heartbeat_mode=? WHERE id=?", (state, seconds, last_poll, resting_at, mode, actor["id"]))
        db.execute("INSERT INTO member_events(member_id,kind,body,timestamp) VALUES(?,?,?,?)", (actor["id"], "participation", f"{row['participation']} → {state}；轮询 {seconds} 秒；心跳模式 {row['heartbeat_mode']} → {mode}；{reason}", stamp))
        return 200, {"ok": True}

    match = re.fullmatch(r"/v1/alerts/(\d+)/actions", path)
    if match:
        if not store.privileged(actor):
            raise APIError(403, "异常待办由 Leader 或用户处理")
        store.reject_unknown(data, {"version", "action", "note", "minutes"})
        row = db.execute("SELECT * FROM alerts WHERE id=?", (int(match[1]),)).fetchone()
        if row is None:
            raise APIError(404, "异常记录不存在")
        if type(data.get("version")) is not int or data["version"] != row["version"]:
            raise APIError(409, "异常已变化，请刷新后操作")
        action = choice(data, "action", {"acknowledge", "snooze", "resolve"}, "acknowledge")
        note = field(data, "note", limit=2000, required=True)
        if row["state"] == "resolved":
            raise APIError(409, "异常已解除，历史仍保留")
        until = None
        state = "acknowledged"
        if action == "snooze":
            minutes = data.get("minutes")
            if type(minutes) is not int or not 1 <= minutes <= 1440:
                raise APIError(422, "暂缓时间为 1–1440 分钟")
            until = timestamp(parse_time(stamp) + timedelta(minutes=minutes))
            state = "snoozed"
        elif action == "resolve":
            if row["kind"] != "blocked":
                raise APIError(409, "自动检测条件仍存在；请处理原因或暂缓跟进，而非只清除标记")
            task = db.execute("SELECT * FROM tasks WHERE id=?", (row["task_id"],)).fetchone()
            update_task(store, db, actor, task["id"], {"version": task["version"], "kind": "unblocked", "body": note})
            evaluate(db, stamp)
            alert_event(db, row["id"], "resolution_note", note, stamp, actor["id"])
            return 200, {"ok": True}
        db.execute("UPDATE alerts SET state=?,snoozed_until=?,updated_at=?,version=version+1 WHERE id=?", (state, until, stamp, row["id"]))
        alert_event(db, row["id"], action, note, stamp, actor["id"])
        return 200, {"ok": True}

    if path == "/v1/rules":
        if not store.privileged(actor):
            raise APIError(403, "规则由 Leader 或用户调整")
        store.reject_unknown(data, {*DEFAULT_RULES, "version", "reason"})
        current = read_rules(db)
        if type(data.get("version")) is not int or data["version"] != current["version"]:
            raise APIError(409, "规则已更新，请刷新")
        reason = field(data, "reason", limit=1000, required=True)
        values = {k: data.get(k, current[k]) for k in DEFAULT_RULES}
        if any(type(v) is not int for v in values.values()) or not (60 <= values["staleYellowSeconds"] < values["staleRedSeconds"] <= 604800) or not (1 <= values["heartbeatYellowMisses"] < values["heartbeatRedMisses"] <= 100) or not 0 <= values["heartbeatGraceSeconds"] <= 3600:
            raise APIError(422, "阈值应为有效整数，且黄灯阈值小于红灯阈值")
        db.execute("UPDATE rules SET version=version+1,value=? WHERE id=1", (json.dumps(values),))
        db.execute("INSERT INTO member_events(member_id,kind,body,timestamp) VALUES(?,?,?,?)", (actor["id"], "rules", json.dumps({"before":current,"after":values,"reason":reason},ensure_ascii=False),stamp))
        return 200, {"ok": True}

    if path == "/v1/messages":
        store.reject_unknown(data, {"recipientId", "body"})
        recipient = field(data, "recipientId", limit=48, required=True)
        store.check_member(db, recipient)
        if not store.privileged(actor) and db.execute("SELECT role FROM members WHERE id=?", (recipient,)).fetchone()[0] not in {"leader", "admin"}:
            raise APIError(403, "Worker 的跨成员协作由 Leader 统筹")
        body = field(data, "body", limit=12000, required=True)
        cur = db.execute("INSERT INTO messages(sender_id,sender_name,recipient_id,body,created_at) VALUES(?,?,?,?,?)", (actor["id"],actor["name"],recipient,body,stamp))
        if db.execute("SELECT role FROM members WHERE id=?",(recipient,)).fetchone()[0] == "admin":
            notifications.enqueue(db,f"message:{cur.lastrowid}","message_user",f"collabdesk://message/{cur.lastrowid}",stamp,
                                  recipient_id=recipient)
        return 201, {"id":cur.lastrowid}
    match = re.fullmatch(r"/v1/messages/(\d+)/read",path)
    if match:
        store.reject_unknown(data,set())
        row=db.execute("SELECT * FROM messages WHERE id=? AND recipient_id=?",(int(match[1]),actor["id"])).fetchone()
        if row is None:
            raise APIError(404,"消息不存在或并非当前成员收件")
        db.execute("UPDATE messages SET read_at=COALESCE(read_at,?) WHERE id=?",(stamp,row["id"]))
        db.execute("UPDATE push_outbox SET state='cancelled' WHERE event_key=? AND member_id=? AND state='pending'",
                   (f"message:{row['id']}",actor['id']))
        return 200,{"ok":True}
    return None
