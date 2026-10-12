"""SQLite online backups, local private retention. No remote deployment here."""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
from datetime import datetime, timezone
from common import parse_time


def create(store):
    folder=Path(store.path).resolve().parent/'backups'; folder.mkdir(mode=0o700,exist_ok=True); folder.chmod(0o700)
    name='collab-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ')+'.sqlite3'
    path=folder/name; tmp=folder/(name+'.tmp')
    with store.connection() as source, sqlite3.connect(tmp) as target:
        source.backup(target)
        if target.execute('PRAGMA quick_check').fetchone()[0]!='ok': raise RuntimeError('Backup integrity check failed')
    target.close()
    tmp.chmod(0o600); os.replace(tmp,path)
    sha=hashlib.sha256(path.read_bytes()).hexdigest()
    meta=folder/(name+'.json'); meta.write_text(json.dumps({'createdAt':store.now(),'filename':name,'sha256':sha,'bytes':path.stat().st_size},indent=2)+'\n'); meta.chmod(0o600)
    with store.connection() as db:
        db.execute('INSERT INTO backup_runs(created_at,filename,sha256,size) VALUES(?,?,?,?)',(store.now(),name,sha,path.stat().st_size))
    for old in sorted(folder.glob('collab-*.sqlite3'),reverse=True)[14:]:
        old.unlink(); old.with_suffix(old.suffix+'.json').unlink(missing_ok=True)
    return {'filename':name,'sha256':sha,'bytes':path.stat().st_size,'createdAt':store.now()}


def due(store):
    with store.connection() as db: row=db.execute('SELECT created_at FROM backup_runs ORDER BY id DESC LIMIT 1').fetchone()
    if row is None or (parse_time(store.now())-parse_time(row[0])).total_seconds()>=86400: create(store)


def status(db,actor):
    if actor['role'] not in {'admin','leader'}: return None
    r=db.execute('SELECT * FROM backup_runs ORDER BY id DESC LIMIT 1').fetchone()
    return {'intervalSeconds':86400,'retainedCopies':14,'location':'Database-adjacent private backups folder',
            'latest':None if r is None else {'createdAt':r['created_at'],'filename':r['filename'],'sha256':r['sha256'],'bytes':r['size']},
            'offsiteConfigured':False}
