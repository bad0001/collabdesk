"""Small-team, permission-scoped incremental synchronisation.

The cursor is a random, actor-bound receipt, not an authorization credential.
We retain keys/hashes, not historical response bodies: every response projects
CURRENT permissions. All audit events are separate immutable entities, so
coalescing a task's current state does not discard its history.
"""
import hashlib
import json
import re
import secrets
from datetime import timedelta
from common import APIError, parse_time, timestamp

RETENTION_DAYS = 7
COLLECTIONS = ("tasks", "events", "members", "announcements", "messages", "alerts", "alertEvents", "memberEvents",
               "authorizations", "authorizationEvents", "libraries", "records", "recordEvents", "userRequests", "userRequestEvents", "codeRequests")


def canonical(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def migrate(db):
    if db.execute("PRAGMA user_version").fetchone()[0] >= 3:
        return
    db.execute("BEGIN IMMEDIATE")
    try:
        db.execute("ALTER TABLE members ADD COLUMN heartbeat_mode TEXT NOT NULL DEFAULT 'periodic'")
        for statement in [
            "CREATE TABLE sync_heads(actor TEXT PRIMARY KEY REFERENCES members(id), seq INTEGER NOT NULL)",
            "CREATE TABLE sync_documents(actor TEXT NOT NULL REFERENCES members(id), collection TEXT NOT NULL, id TEXT NOT NULL, hash TEXT NOT NULL, PRIMARY KEY(actor,collection,id))",
            "CREATE TABLE sync_changes(actor TEXT NOT NULL REFERENCES members(id), seq INTEGER NOT NULL, collection TEXT NOT NULL, id TEXT NOT NULL, PRIMARY KEY(actor,seq))",
            "CREATE TABLE sync_cursors(hash TEXT PRIMARY KEY, actor TEXT NOT NULL REFERENCES members(id), seq INTEGER NOT NULL, created_at TEXT NOT NULL)",
            "CREATE INDEX sync_cursor_actor ON sync_cursors(actor,created_at)",
            "CREATE TABLE sync_meta(key TEXT PRIMARY KEY,value TEXT NOT NULL)",
        ]:
            db.execute(statement)
        rotate_signal(db)
        db.execute("PRAGMA user_version=3")
        db.execute("COMMIT")
    except Exception:
        db.execute("ROLLBACK")
        raise


def rotate_signal(db):
    db.execute("INSERT OR REPLACE INTO sync_meta VALUES('signal',?)", (secrets.token_urlsafe(24),))


def documents(snapshot):
    result = {}
    for collection in COLLECTIONS:
        for value in snapshot.get(collection, []):
            value = dict(value)
            # A visit must not create an endless wake->visit->wake loop.
            # Live liveness/rolling dashboard statistics use /v1/snapshot.
            if collection == "members":
                value.pop("lastPollAt", None)
            result[collection, str(value["id"])] = value
    result["rules", "global"] = snapshot["rules"]
    return result


def incremental(db, actor, snapshot, cursor, stamp):
    """Caller holds a single write transaction, including the scoped snapshot."""
    actor_id = actor["id"]
    cutoff = timestamp(parse_time(stamp) - timedelta(days=RETENTION_DAYS))
    previous = None
    if cursor:
        if not isinstance(cursor, str) or not re.fullmatch(r"[A-Za-z0-9_-]{43}", cursor):
            raise APIError(410, "游标失效，请删除 cursor 参数重新获取完整工作区")
        previous = db.execute("SELECT * FROM sync_cursors WHERE hash=? AND actor=? AND created_at>?",
                              (digest(cursor), actor_id, cutoff)).fetchone()
        if previous is None:
            # Identical response for expired, unknown and another member's cursors.
            raise APIError(410, "游标失效，请删除 cursor 参数重新获取完整工作区")
    db.execute("INSERT OR IGNORE INTO sync_heads VALUES(?,0)", (actor_id,))
    head = db.execute("SELECT seq FROM sync_heads WHERE actor=?", (actor_id,)).fetchone()[0]
    current = documents(snapshot)
    known = {(r["collection"], r["id"]): r["hash"] for r in db.execute("SELECT * FROM sync_documents WHERE actor=?", (actor_id,))}
    hashes = {key: digest(canonical(value)) for key, value in current.items()}
    for key in sorted(known.keys() | hashes.keys()):
        if known.get(key) == hashes.get(key):
            continue
        head += 1
        db.execute("INSERT INTO sync_changes VALUES(?,?,?,?)", (actor_id, head, *key))
        if key in hashes:
            db.execute("INSERT OR REPLACE INTO sync_documents VALUES(?,?,?,?)", (actor_id, *key, hashes[key]))
        else:
            db.execute("DELETE FROM sync_documents WHERE actor=? AND collection=? AND id=?", (actor_id, *key))
    db.execute("UPDATE sync_heads SET seq=? WHERE actor=?", (head, actor_id))
    if previous is None:
        keys = sorted(current)
    else:
        keys = [(r["collection"], r["id"]) for r in db.execute(
            "SELECT collection,id FROM sync_changes WHERE actor=? AND seq>? GROUP BY collection,id ORDER BY collection,id",
            (actor_id, previous["seq"]))]
    items = [{"collection": c, "id": i, "op": "upsert", "value": current[c, i]} if (c, i) in current else
             {"collection": c, "id": i, "op": "delete"} for c, i in keys]
    if previous is not None and previous["seq"] == head:
        next_cursor = cursor
    else:
        next_cursor = secrets.token_urlsafe(32)
        db.execute("INSERT INTO sync_cursors VALUES(?,?,?,?)", (digest(next_cursor), actor_id, head, stamp))
    # At most seven days of receipts; retain changes needed by every valid
    # reader, including two independent windows using the same member token.
    db.execute("DELETE FROM sync_cursors WHERE created_at<=?", (cutoff,))
    for row in db.execute("SELECT actor FROM sync_heads").fetchall():
        minimum = db.execute("SELECT min(seq) FROM sync_cursors WHERE actor=?", (row[0],)).fetchone()[0]
        if minimum is None:
            db.execute("DELETE FROM sync_changes WHERE actor=?", (row[0],))
        else:
            db.execute("DELETE FROM sync_changes WHERE actor=? AND seq<=?", (row[0], minimum))
    return {"schemaVersion": 2, "syncVersion": 1, "workspaceId": snapshot["workspaceId"], "memberId": actor_id, "reset": previous is None,
            "items": items, "new_cursor": next_cursor, "cursorRetentionDays": RETENTION_DAYS}
