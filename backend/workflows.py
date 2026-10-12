import secrets

"""v5 explicit approval routing, record library and private push/backup tables."""
def migrate(db):
    if db.execute('PRAGMA user_version').fetchone()[0] >= 5:
        return
    db.execute('BEGIN IMMEDIATE')
    try:
        db.execute("ALTER TABLE tasks ADD COLUMN review_stage TEXT NOT NULL DEFAULT 'leader'")
        db.execute("ALTER TABLE authorization_requests ADD COLUMN reviewer TEXT NOT NULL DEFAULT 'leader'")
        db.execute("UPDATE authorization_requests SET reviewer='user' WHERE kind='card'")
        statements = [
            """CREATE TABLE libraries(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
            fields TEXT NOT NULL, views TEXT NOT NULL, worker_access TEXT NOT NULL,
            version INTEGER NOT NULL DEFAULT 1, created_by TEXT NOT NULL REFERENCES members(id),
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL)""",
            """CREATE TABLE records(id INTEGER PRIMARY KEY AUTOINCREMENT, library_id INTEGER NOT NULL REFERENCES libraries(id),
            title TEXT NOT NULL, values_json TEXT NOT NULL, body TEXT NOT NULL DEFAULT '', archived INTEGER NOT NULL DEFAULT 0,
            version INTEGER NOT NULL DEFAULT 1, created_by TEXT NOT NULL REFERENCES members(id),
            created_at TEXT NOT NULL, updated_at TEXT NOT NULL)""",
            """CREATE TABLE record_tasks(record_id INTEGER NOT NULL REFERENCES records(id), task_id TEXT NOT NULL REFERENCES tasks(id),
            PRIMARY KEY(record_id,task_id))""",
            """CREATE TABLE record_events(id INTEGER PRIMARY KEY AUTOINCREMENT, library_id INTEGER NOT NULL REFERENCES libraries(id),
            record_id INTEGER REFERENCES records(id), kind TEXT NOT NULL, actor_id TEXT NOT NULL REFERENCES members(id),
            actor_name TEXT NOT NULL, before_json TEXT NOT NULL, after_json TEXT NOT NULL, timestamp TEXT NOT NULL)""",
            "CREATE INDEX records_library ON records(library_id,id)",
            "CREATE INDEX record_tasks_task ON record_tasks(task_id)",
            """CREATE TABLE push_devices(installation_id TEXT PRIMARY KEY, member_id TEXT NOT NULL REFERENCES members(id),
            token TEXT NOT NULL, environment TEXT NOT NULL, enabled INTEGER NOT NULL, updated_at TEXT NOT NULL,
            UNIQUE(token,environment))""",
            """CREATE TABLE push_outbox(id INTEGER PRIMARY KEY AUTOINCREMENT, event_key TEXT NOT NULL,
            installation_id TEXT NOT NULL REFERENCES push_devices(installation_id), member_id TEXT NOT NULL REFERENCES members(id),
            payload TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'pending', attempts INTEGER NOT NULL DEFAULT 0,
            next_attempt_at TEXT NOT NULL, created_at TEXT NOT NULL, last_error TEXT NOT NULL DEFAULT '',
            UNIQUE(event_key,installation_id))""",
            """CREATE TABLE backup_runs(id INTEGER PRIMARY KEY AUTOINCREMENT, created_at TEXT NOT NULL,
            filename TEXT NOT NULL, sha256 TEXT NOT NULL, size INTEGER NOT NULL)"""
        ]
        for sql in statements: db.execute(sql)
        for action in ('UPDATE','DELETE'):
            db.execute(f"CREATE TRIGGER record_events_no_{action} BEFORE {action} ON record_events BEGIN SELECT RAISE(ABORT,'append-only'); END")
        db.execute("INSERT OR IGNORE INTO sync_meta VALUES('workspace_id',?)", (secrets.token_urlsafe(24),))
        db.execute('PRAGMA user_version=5')
        db.execute('COMMIT')
    except Exception:
        db.execute('ROLLBACK'); raise
