"""Explicit, revocable, write-only SMS-ingest capability; metadata only on disk.

It is not a member credential and authenticates only POST /v1/codes/ingest.
No payload, OTP, SMS body or low-entropy request fingerprint is persisted.
"""
import hashlib
import json
import re
import secrets
from common import APIError, field

CAP_PREFIX = 'sms-ingest-cap:'
META_PREFIX = 'sms-code-meta:'
UNKNOWN_PREFIX = 'sms-code-unknown:'
INSTALLATION = re.compile(r'[A-Za-z0-9_-]{8,128}')
CREDENTIAL = re.compile(r'[A-Za-z0-9_-]{43}')
PURPOSES = {'login':'登录', 'register':'注册', 'reset':'重置密码', 'verification':'验证', 'unknown':'未知用途'}


def compact(value):
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(',', ':'))


def metadata(db, code_id):
    row = db.execute('SELECT value FROM sync_meta WHERE key=?', (META_PREFIX + code_id,)).fetchone()
    return json.loads(row[0]) if row else None


def serialize(db, row, serializer):
    result = serializer(row)
    extra = metadata(db, row['id'])
    if extra:
        result.update({k:extra[k] for k in ('importMethod','sourceKnown','purposeKnown','timeSource')})
    return result


def namespace_sql(code='c', request='r'):
    # No JSON1 extension is required. Immutable unknown flags are separate,
    # code-ID-scoped metadata keys; manual imports have none and remain exact.
    return ' AND '.join(
        f"({request}.{column}={code}.{column} OR EXISTS(SELECT 1 FROM sync_meta sx WHERE sx.key='{UNKNOWN_PREFIX}{column}:'||{code}.id AND sx.value='1'))"
        for column in ('service','account_label','purpose'))


def matches(db, code, request):
    extra = metadata(db, code['id'])
    if not extra:
        return all(code[k] == request[k] for k in ('service','account_label','purpose'))
    return ((not extra['sourceKnown'] or code['service'] == request['service'])
            and (not extra['purposeKnown'] or code['purpose'] == request['purpose']))


def public_installation(value):
    return {k:value[k] for k in ('installationId','enabled','scope','enabledAt','disabledAt')}


def status(db, actor):
    if actor['role'] != 'admin':
        raise APIError(403, '短信自动导入仅用户本人设置')
    prefix = CAP_PREFIX + actor['id'] + ':'
    rows = db.execute('SELECT value FROM sync_meta WHERE substr(key,1,?)=? ORDER BY key', (len(prefix),prefix))
    return {'installations':[public_installation(json.loads(row[0])) for row in rows]}


def apply(store, db, actor, path, data):
    if path not in {'/v1/codes/automation/enable','/v1/codes/automation/disable'}:
        return None
    if actor['role'] != 'admin':
        raise APIError(403, '短信自动导入仅用户本人设置')
    store.reject_unknown(data, {'installationId'})
    installation = field(data, 'installationId', limit=128, required=True)
    if not INSTALLATION.fullmatch(installation):
        raise APIError(422, 'installationId 应为 8–128 位安装标识')
    key = CAP_PREFIX + actor['id'] + ':' + installation
    if path.endswith('/enable'):
        credential = secrets.token_urlsafe(32)
        value = {'installationId':installation,'ownerId':actor['id'], 'enabled':True,
                 'scope':'code-ingest','enabledAt':store.now(),'disabledAt':None,
                 'workspaceId':db.execute("SELECT value FROM sync_meta WHERE key='workspace_id'").fetchone()[0],
                 'ownerTokenHash':actor['token_hash'],
                 'tokenHash':hashlib.sha256(credential.encode()).hexdigest()}
        db.execute('INSERT OR REPLACE INTO sync_meta(key,value) VALUES(?,?)',(key,compact(value)))
        return 201, {'credential':credential,'installation':public_installation(value)}
    row = db.execute('SELECT value FROM sync_meta WHERE key=?',(key,)).fetchone()
    if row is None:
        raise APIError(404, '此安装未开启自动导入')
    value = json.loads(row[0]); value.update(enabled=False, disabledAt=store.now())
    # Deleted hash leaves no reusable disabled capability. Existing member/API
    # credentials and other installations are never rotated.
    value.pop('tokenHash', None)
    db.execute('UPDATE sync_meta SET value=? WHERE key=?',(compact(value),key))
    return 200, {'installation':public_installation(value)}


def authenticate(db, header):
    if not isinstance(header, str) or not header.startswith('CodeIngest ') or not CREDENTIAL.fullmatch(header[11:]):
        raise APIError(401, '请提供专用短信写入凭据')
    hashed = hashlib.sha256(header[11:].encode()).hexdigest()
    for row in db.execute('SELECT value FROM sync_meta WHERE key LIKE ?', (CAP_PREFIX+'%',)):
        value = json.loads(row[0])
        if value.get('enabled') and secrets.compare_digest(value.get('tokenHash',''), hashed):
            actor = db.execute('SELECT * FROM members WHERE id=? AND role=\'admin\'', (value['ownerId'],)).fetchone()
            workspace=db.execute("SELECT value FROM sync_meta WHERE key='workspace_id'").fetchone()
            if (actor is not None and workspace is not None
                    and value.get('workspaceId')==workspace[0]
                    and secrets.compare_digest(value.get('ownerTokenHash',''),actor['token_hash'])):
                return dict(actor), value['installationId']
    raise APIError(401, '短信写入凭据已失效或被关闭')
