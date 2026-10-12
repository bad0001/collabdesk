"""Read-only, member-scoped wake metadata; never a snapshot or sync receipt.

The public-watch opt-in intentionally makes member IDs, scoped activity counts
and opaque change metadata public. A memberId selects a scope, not an identity.
Credentials still authenticate every supplied Authorization header, and workers
may select only themselves. No titles, names, bodies or credential material are
returned. All reads, including authentication, share one bounded transaction.
"""
import base64
import hashlib
import hmac
import json
from pathlib import Path
import re
import sqlite3
import threading
import time

from common import APIError
import code_automation

TYPES = ("tasks", "auths", "alerts", "messages", "announcements")
MEMBER_ID = re.compile(r"[a-z][a-z0-9_-]{0,47}")
WORKSPACE_ID = re.compile(r"[A-Za-z0-9_-]{1,64}")
# Compact signature computation is short CPU/SQLite work, with Python callbacks
# only for streamed broadcast content. Serialize that computation (not opening,
# authenticating or legacy reads) to prevent a callback/GIL convoy under concurrent
# polling. Acquiring this gate consumes the same 400 ms request read budget.
_SIGNATURE_GATE = threading.Lock()


def validate_query(query):
    """Validate an already strictly parsed watch query without defaulting IDs."""
    if (set(query) - {"workspace", "memberId"} or "workspace" not in query
            or any(len(values) != 1 for values in query.values())
            or not WORKSPACE_ID.fullmatch(query["workspace"][0])):
        raise APIError(422, "仅支持单个 workspace 和可选 memberId 参数")
    member_id = query.get("memberId", [None])[0]
    if member_id is not None and not MEMBER_ID.fullmatch(member_id):
        raise APIError(422, "memberId 须为 1–48 位有效成员 ID")
    return query["workspace"][0], member_id


def _pack(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode()


def _opaque(mac):
    # 24 bytes encode as precisely 32 URL-safe characters, with no padding.
    return base64.urlsafe_b64encode(mac.digest()[:24]).decode("ascii")


def _revision(db, key, kind, queries):
    signature = hmac.new(key, b"member-watch-revision-v1\0" + kind.encode(), hashlib.sha256)
    count = 0
    for counts_entities, sql, args in queries:
        # SQLite assembles compact ordered metadata in C, rather than passing
        # thousands of rows through Python/GIL on concurrent watch requests.
        signature.update(b"\0query\0")
        row_count, metadata = db.execute(sql, args).fetchone()
        packed = metadata.encode()
        signature.update(row_count.to_bytes(8, "big"))
        signature.update(len(packed).to_bytes(8, "big"))
        signature.update(packed)
        if counts_entities:
            count += row_count
    return count, _opaque(signature)


def _metadata(columns, source, order, where=""):
    # NULL and empty string have distinct markers. Hexadecimal cells and fixed
    # separators are unambiguous without relying on an optional SQLite JSON
    # extension. Only metadata fields enter this materialization, never bodies.
    cells = [("'v'||" + column if column.startswith("watch_content(")
              else f"CASE WHEN {column} IS NULL THEN 'n' ELSE 'v'||hex(CAST({column} AS BLOB)) END")
             for column in columns]
    encoded = "||','||".join(cells)
    return ("SELECT count(*),COALESCE(group_concat(signature,';'),'') FROM "
            f"(SELECT {encoded} AS signature FROM {source} "
            f"{'WHERE ' + where if where else ''} ORDER BY {order})")


def _member_result(db, workspace, member):
    member_id, role, token_hash = member
    # Persisted credential hash is secret key material only, never response data.
    # Separate scope/type domains also prevent cross-member/content fingerprints.
    key = hmac.new(token_hash.encode(), _pack(["member-watch-v1", workspace, member_id, role]),
                   hashlib.sha256).digest()
    if role == "worker":
        auth_where, auth_args = "requester_id=?", (member_id,)
    else:
        reviewer = "user" if role == "admin" else "leader"
        auth_where = "requester_id=? OR decided_by=? OR reviewer=?"
        auth_args = (member_id, member_id, reviewer)

    queries = {
        "tasks": [
            (True, _metadata(("id", "owner_id", "version", "status", "updated_at"),
                             "tasks", "number", "owner_id=?"), (member_id,)),
            (False, _metadata(("e.id", "e.task_id"), "events e JOIN tasks t ON t.id=e.task_id",
                              "e.id", "t.owner_id=?"), (member_id,)),
        ],
        "auths": [
            (True, _metadata(("id", "requester_id", "reviewer", "state", "version", "decided_by", "updated_at"),
                             "authorization_requests", "id", auth_where), auth_args),
            (False, _metadata(("e.id", "e.authorization_id"),
                              "authorization_events e JOIN authorization_requests a ON a.id=e.authorization_id", "e.id",
                              auth_where.replace('requester_id', 'a.requester_id').replace('decided_by', 'a.decided_by').replace('reviewer', 'a.reviewer')),
             auth_args),
        ],
        "alerts": [
            (True, _metadata(("id", "member_id", "version", "state", "severity", "updated_at", "snoozed_until", "resolved_at"),
                             "alerts", "id", "member_id=?"), (member_id,)),
            (False, _metadata(("e.id", "e.alert_id"), "alert_events e JOIN alerts a ON a.id=e.alert_id",
                              "e.id", "a.member_id=?"), (member_id,)),
        ],
        "messages": [
            (True, _metadata(("id", "recipient_id", "created_at", "read_at"), "messages", "id", "recipient_id=?"), (member_id,)),
        ],
        # Announcements have no audience or version column: every row is a
        # broadcast. Hash content transiently in SQL; fetch only its keyed digest.
        "announcements": [
            (True, _metadata(("id", "kind", "created_at", "watch_content(title,body)"), "announcements", "id"), ()),
            # Shared rules configuration is broadcast policy metadata, not an
            # extra announcement entity. It wakes every scope without inflating
            # the announcement history count or including member activity.
            (False, _metadata(("id", "version", "watch_content('',value)"), "rules", "id"), ()),
        ],
    }
    # v6 adds user requests and code allocation metadata without exposing new
    # public fields or another change-type: old sentinels wake on "messages".
    # Code values are process-only and never take part in this signature.
    if db.execute("PRAGMA user_version").fetchone()[0] >= 6:
        if role == "worker":
            help_where, help_args = "h.requester_id=?", (member_id,)
            code_request_where, code_request_args = "r.requester_id=?", (member_id,)
            code_where = ("c.assigned_member_id=? OR (c.state='available' AND EXISTS("
                          "SELECT 1 FROM code_requests r JOIN tasks t ON t.id=r.task_id "
                          "WHERE r.requester_id=? AND r.state='waiting' AND t.owner_id=r.requester_id "
                          "AND t.status NOT IN ('completed','cancelled','awaiting_review') "
                          "AND " + code_automation.namespace_sql() + "))")
            code_args = (member_id,member_id)
        elif role == "admin":
            help_where, help_args = "h.recipient_id=?", (member_id,)
            code_request_where, code_request_args = "1=1", ()
            code_where, code_args = "1=1", ()
        else:
            help_where, help_args = "1=1", ()
            code_request_where, code_request_args = "1=1", ()
            code_where, code_args = "1=1", ()
        queries["messages"].extend([
            (True, _metadata(("h.id","h.requester_id","h.recipient_id","h.state","h.version","h.updated_at"),
                             "help_requests h","h.id",help_where),help_args),
            (False,_metadata(("e.id","e.request_id"),"help_events e JOIN help_requests h ON h.id=e.request_id",
                              "e.id",help_where),help_args),
            (False,_metadata(("r.id","r.requester_id","r.state","r.version","r.code_id","r.updated_at"),
                              "code_requests r","r.id",code_request_where),code_request_args),
            (False,_metadata(("c.id","c.state","c.version","c.expires_at","c.assigned_member_id","c.assigned_request_id"),
                              "codes_metadata c","c.id",code_where),code_args),
        ])
    def content_signature(title, body):
        signature = hmac.new(key, b"announcement-content-v1", hashlib.sha256)
        for value in (title, body):
            packed = value.encode()
            signature.update(len(packed).to_bytes(8, "big"))
            signature.update(packed)
        return signature.hexdigest()

    db.create_function("watch_content", 2, content_signature)
    counts, revisions = {}, {}
    for kind in TYPES:
        counts[kind], revisions[kind] = _revision(db, key, kind, queries[kind])
    cursor = _opaque(hmac.new(key, _pack(["member-watch-cursor-v1", workspace, member_id, revisions]),
                             hashlib.sha256))
    return {"workspaceId": workspace, "memberId": member_id, "cursor": cursor,
            **counts, "revisions": revisions}


def read(path, workspace, member_id=None, authorization=None):
    """Return legacy global metadata or selected member metadata atomically.

    No application write connection, alert evaluation, heartbeat, schema change
    or sync-cursor access occurs. Locks wait at most 200 ms; a progress handler
    bounds SQL work so pathological databases return 503 rather than queue work.
    """
    db = None
    deadline = time.monotonic() + 0.4
    try:
        uri = Path(path).resolve().as_uri() + "?mode=ro"
        db = sqlite3.connect(uri, uri=True, timeout=0.2, isolation_level=None)
        db.set_progress_handler(lambda: int(time.monotonic() > deadline), 10000)
        db.execute("BEGIN")
        actor = None
        if authorization is not None:
            if not authorization.startswith("Bearer ") or len(authorization) > 256:
                raise APIError(401, "请提供成员 API 凭据")
            credential_hash = hashlib.sha256(authorization[7:].encode()).hexdigest()
            actor = db.execute("SELECT id,role FROM members WHERE token_hash=?", (credential_hash,)).fetchone()
            if actor is None:
                raise APIError(401, "成员 API 凭据无效")
            if member_id is None:
                member_id = actor[0]
            elif actor[1] == "worker" and member_id != actor[0]:
                raise APIError(403, "Worker 仅可选择自己的成员范围")
        meta = dict(db.execute("SELECT key,value FROM sync_meta WHERE key IN ('workspace_id','signal')"))
        if meta.get("workspace_id") != workspace:
            raise APIError(404, "接口不存在")
        if member_id is None:
            if not meta.get("signal"):
                raise APIError(503, "状态暂不可用，请稍后检查")
            counts = db.execute("""SELECT (SELECT count(*) FROM tasks),
                (SELECT count(*) FROM authorization_requests), (SELECT count(*) FROM alerts),
                (SELECT count(*) FROM messages)""").fetchone()
            result = {"workspaceId": workspace, "cursor": meta["signal"],
                      **dict(zip(TYPES[:4], counts))}
        else:
            member = db.execute("SELECT id,role,token_hash FROM members WHERE id=?", (member_id,)).fetchone()
            if member is None:
                raise APIError(404, "接口不存在")
            if not _SIGNATURE_GATE.acquire(timeout=max(0, deadline - time.monotonic())):
                raise APIError(503, "状态暂不可用，请稍后检查")
            try:
                result = _member_result(db, workspace, member)
            finally:
                _SIGNATURE_GATE.release()
        db.execute("COMMIT")
        return result
    except sqlite3.OperationalError:
        raise APIError(503, "状态暂不可用，请稍后检查") from None
    finally:
        if db is not None:
            db.close()
