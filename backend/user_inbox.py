"""User-facing requests and a task-scoped, memory-only short-lived code vault.

SQLite stores request/audit and code *metadata* only. OTP values, import request
hashes and import idempotency responses never enter SQLite, backups or snapshots.
A single Store/process owns the vault; restart deliberately invalidates codes.
"""
from contextlib import contextmanager
from datetime import timedelta
import copy
import re
import hashlib
import hmac

import code_automation
import secrets
import threading

import notifications
import authorizations
from common import APIError, choice, field, parse_time, timestamp

ACTIVE_CODES = {'available', 'assigned'}
LIVE_REQUESTS = {'open', 'replied'}
CODE_ID = r'[A-Za-z0-9_-]{32}'


def migrate(db):
    version = db.execute('PRAGMA user_version').fetchone()[0]
    if version > 6:
        raise RuntimeError('Database is newer than this application')
    if version >= 6:
        return
    db.execute('BEGIN IMMEDIATE')
    try:
        statements = [
            """CREATE TABLE help_requests(
              id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT REFERENCES tasks(id),
              requester_id TEXT NOT NULL REFERENCES members(id), requester_name TEXT NOT NULL,
              recipient_id TEXT NOT NULL REFERENCES members(id), kind TEXT NOT NULL,
              subject TEXT NOT NULL, body TEXT NOT NULL, state TEXT NOT NULL DEFAULT 'open',
              version INTEGER NOT NULL DEFAULT 1, created_at TEXT NOT NULL, updated_at TEXT NOT NULL,
              response_body TEXT NOT NULL DEFAULT '', response_by TEXT REFERENCES members(id), response_at TEXT)""",
            "CREATE INDEX help_requester ON help_requests(requester_id,id)",
            """CREATE TABLE help_events(
              id INTEGER PRIMARY KEY AUTOINCREMENT, request_id INTEGER NOT NULL REFERENCES help_requests(id),
              kind TEXT NOT NULL, actor_id TEXT REFERENCES members(id), actor_name TEXT NOT NULL,
              body TEXT NOT NULL, timestamp TEXT NOT NULL)""",
            """CREATE TABLE code_requests(
              id INTEGER PRIMARY KEY AUTOINCREMENT, task_id TEXT NOT NULL REFERENCES tasks(id),
              requester_id TEXT NOT NULL REFERENCES members(id), requester_name TEXT NOT NULL,
              help_request_id INTEGER NOT NULL REFERENCES help_requests(id),
              service TEXT NOT NULL, account_label TEXT NOT NULL, purpose TEXT NOT NULL,
              state TEXT NOT NULL DEFAULT 'waiting', version INTEGER NOT NULL DEFAULT 1,
              code_id TEXT, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)""",
            "CREATE INDEX code_requester ON code_requests(requester_id,state,id)",
            """CREATE TABLE codes_metadata(
              id TEXT PRIMARY KEY, service TEXT NOT NULL, account_label TEXT NOT NULL, purpose TEXT NOT NULL,
              state TEXT NOT NULL DEFAULT 'available', version INTEGER NOT NULL DEFAULT 1,
              received_at TEXT NOT NULL, expires_at TEXT NOT NULL, created_at TEXT NOT NULL,
              imported_by TEXT NOT NULL REFERENCES members(id), assigned_request_id INTEGER REFERENCES code_requests(id),
              assigned_member_id TEXT REFERENCES members(id), task_id TEXT REFERENCES tasks(id))""",
            "CREATE INDEX code_namespace ON codes_metadata(service,account_label,purpose,state)",
            """CREATE TABLE code_events(
              id INTEGER PRIMARY KEY AUTOINCREMENT, code_id TEXT REFERENCES codes_metadata(id),
              request_id INTEGER REFERENCES code_requests(id), kind TEXT NOT NULL,
              actor_id TEXT REFERENCES members(id), timestamp TEXT NOT NULL)""",
        ]
        for statement in statements:
            db.execute(statement)
        for table in ('help_events', 'code_events'):
            for action in ('UPDATE', 'DELETE'):
                db.execute(f"CREATE TRIGGER {table}_no_{action} BEFORE {action} ON {table} BEGIN SELECT RAISE(ABORT,'append-only'); END")
        db.execute('PRAGMA user_version=6')
        db.execute('COMMIT')
    except Exception:
        db.execute('ROLLBACK')
        raise


def serialize_help(row):
    keys = {'task_id':'taskId', 'requester_id':'requesterId', 'requester_name':'requesterName',
            'created_at':'createdAt', 'updated_at':'updatedAt', 'response_body':'responseBody',
            'response_by':'responseBy', 'response_at':'responseAt'}
    return {keys.get(k,k):v for k,v in dict(row).items() if k != 'recipient_id'}


def serialize_code(row):
    keys = {'account_label':'accountLabel', 'received_at':'receivedAt', 'expires_at':'expiresAt',
            'created_at':'createdAt', 'assigned_request_id':'assignedRequestId',
            'assigned_member_id':'assignedMemberId', 'task_id':'taskId'}
    return {keys.get(k,k):v for k,v in dict(row).items() if k != 'imported_by'}


def serialize_code_request(row):
    keys = {'task_id':'taskId', 'requester_id':'requesterId', 'requester_name':'requesterName',
            'help_request_id':'userRequestId', 'account_label':'accountLabel', 'code_id':'codeId',
            'created_at':'createdAt', 'updated_at':'updatedAt'}
    return {keys.get(k,k):v for k,v in dict(row).items()}


def help_event(db, row, actor, kind, body, stamp):
    db.execute('INSERT INTO help_events(request_id,kind,actor_id,actor_name,body,timestamp) VALUES(?,?,?,?,?,?)',
               (row['id'], kind, actor['id'] if actor else None, actor['name'] if actor else '', body, stamp))


def code_event(db, code_id, request_id, actor, kind, stamp):
    db.execute('INSERT INTO code_events(code_id,request_id,kind,actor_id,timestamp) VALUES(?,?,?,?,?)',
               (code_id, request_id, kind, actor['id'] if actor else None, stamp))


def get_help(db, actor, request_id):
    row = db.execute('SELECT * FROM help_requests WHERE id=?', (request_id,)).fetchone()
    if row is None or actor['role'] == 'worker' and row['requester_id'] != actor['id']:
        raise APIError(404, '请求不存在或不属于当前成员')
    if actor['role'] == 'admin' and row['recipient_id'] != actor['id']:
        raise APIError(404, '请求不存在或并非当前用户收件')
    return row


def require_version(data, row):
    if type(data.get('version')) is not int or data['version'] != row['version']:
        raise APIError(409, '记录已有更新，请刷新后再处理')


def own_task(store, db, actor, task_id):
    task = store.get_task(db, actor, task_id)
    if task['owner_id'] != actor['id']:
        raise APIError(403, '请求仅可关联自己负责的任务')
    if task['status'] in {'completed', 'cancelled', 'awaiting_review'}:
        raise APIError(409, '此任务阶段不接受新的协助或验证码请求')
    return task


def help_task_current(db, row):
    if row['task_id'] is None:
        return True
    task = db.execute('SELECT owner_id,status FROM tasks WHERE id=?', (row['task_id'],)).fetchone()
    return (task is not None and task['owner_id'] == row['requester_id']
            and task['status'] not in {'completed', 'cancelled', 'awaiting_review'})


def create_help(store, db, actor, task_id, kind, subject, body):
    if actor['role'] not in {'worker', 'leader'}:
        raise APIError(403, '由需要协助的 AI 发起用户请求')
    if task_id is not None:
        own_task(store, db, actor, task_id)
    recipient = db.execute("SELECT id FROM members WHERE role='admin' ORDER BY id LIMIT 1").fetchone()
    if recipient is None:
        raise APIError(409, '平台尚未登记用户接收端')
    stamp = store.now()
    cursor = db.execute('''INSERT INTO help_requests(task_id,requester_id,requester_name,recipient_id,kind,subject,body,created_at,updated_at)
                           VALUES(?,?,?,?,?,?,?,?,?)''',
                        (task_id,actor['id'],actor['name'],recipient[0],kind,subject,body,stamp,stamp))
    row = db.execute('SELECT * FROM help_requests WHERE id=?',(cursor.lastrowid,)).fetchone()
    help_event(db,row,actor,'created',body,stamp)
    notifications.enqueue(db,f"help:{row['id']}",'help_user',f"collabdesk://user-request/{row['id']}",stamp,recipient_id=recipient[0])
    return row


def help_snapshot(db, actor):
    if actor['role'] == 'worker':
        where, args = 'requester_id=?', (actor['id'],)
    elif actor['role'] == 'admin':
        where, args = 'recipient_id=?', (actor['id'],)
    else:
        where, args = '1=1', ()
    requests = db.execute(f'SELECT * FROM help_requests WHERE {where} ORDER BY id DESC',args).fetchall()
    events = db.execute(f'''SELECT e.* FROM help_events e JOIN help_requests h ON h.id=e.request_id
                           WHERE {where.replace('requester_id','h.requester_id').replace('recipient_id','h.recipient_id')}
                           ORDER BY e.id DESC''',args)
    return {'userRequests':[serialize_help(r) for r in requests],
            'userRequestEvents':[{'id':r['id'],'requestId':r['request_id'],'kind':r['kind'],
                                 'actorId':r['actor_id'],'actorName':r['actor_name'],'body':r['body'],
                                 'timestamp':r['timestamp']} for r in events]}


def cancel_help_push(db, request_id):
    db.execute("UPDATE push_outbox SET state='cancelled' WHERE event_key=? AND state='pending'",(f'help:{request_id}',))


def apply_help(store, db, actor, path, data):
    if path == '/v1/user-requests':
        store.reject_unknown(data,{'taskId','kind','subject','body'})
        task_id=data.get('taskId')
        if task_id is not None and (not isinstance(task_id,str) or not re.fullmatch(r'TASK-\d{6,}',task_id)):
            raise APIError(422,'taskId 格式有误')
        kind=choice(data,'kind',{'question','material','code','external_action'},'question')
        if kind == 'code':
            raise APIError(422, '验证码请使用 /v1/code-requests，并填写任务、服务、账号标签和用途')
        row=create_help(store,db,actor,task_id,kind,field(data,'subject',limit=200,required=True),field(data,'body',limit=4000,required=True))
        return 201,{'userRequest':serialize_help(row)}
    match=re.fullmatch(r'/v1/user-requests/([1-9]\d*)/(reply|resolve|cancel)',path)
    if not match:
        return None
    request_id,operation=int(match[1]),match[2]
    row=get_help(db,actor,request_id)
    require_version(data,row)
    if row['state'] not in LIVE_REQUESTS:
        raise APIError(409,'请求已经结束')
    if operation == 'reply':
        if not help_task_current(db, row):
            raise APIError(409, '任务归属或阶段已变化，旧请求不再接收回复')
        store.reject_unknown(data,{'version','body','resolve'})
        if actor['role'] != 'admin':
            raise APIError(403,'需要用户提供的信息由用户本人答复')
        resolve=data.get('resolve',False)
        if type(resolve) is not bool:
            raise APIError(422,'resolve 应为布尔值')
        body=field(data,'body',limit=4000,required=True)
        # OTP transfer is a separate scoped secret endpoint, not chat or audit text.
        if row['kind']=='code':
            raise APIError(409,'验证码请导入验证码库并按任务分派，普通回复只处理其他请求')
        stamp=store.now(); state='resolved' if resolve else 'replied'
        db.execute('''UPDATE help_requests SET state=?,version=version+1,updated_at=?,response_body=?,response_by=?,response_at=? WHERE id=?''',
                   (state,stamp,body,actor['id'],stamp,request_id))
        help_event(db,row,actor,'replied_and_resolved' if resolve else 'replied',body,stamp)
        message=db.execute('INSERT INTO messages(sender_id,sender_name,recipient_id,body,created_at) VALUES(?,?,?,?,?)',
                           (actor['id'],actor['name'],row['requester_id'],f'关于请求 #{request_id}：{body}',stamp))
        cancel_help_push(db,request_id)
        return 200,{'userRequest':serialize_help(get_help(db,actor,request_id)),'messageId':message.lastrowid}
    store.reject_unknown(data,{'version'})
    if actor['role'] != 'admin' and row['requester_id'] != actor['id']:
        raise APIError(403,'请求由用户或原请求人结束')
    stamp=store.now(); state='resolved' if operation=='resolve' else 'cancelled'
    db.execute('UPDATE help_requests SET state=?,version=version+1,updated_at=? WHERE id=?',(state,stamp,request_id))
    help_event(db,row,actor,state,'',stamp)
    cancel_help_push(db,request_id)
    # A resolved/cancelled code request must not leave access to a secret open.
    if row['kind']=='code':
        for request in db.execute("SELECT * FROM code_requests WHERE help_request_id=? AND state IN ('waiting','assigned')",(request_id,)).fetchall():
            store.code_vault.release_request(store,db,request,actor,'cancelled')
    return 200,{'userRequest':serialize_help(get_help(db,actor,request_id))}


class CodeVault:
    """One process, atomic SQLite+RAM writes; no code on disk and bounded TTL."""
    def __init__(self):
        self.lock=threading.RLock()
        self.values={}
        self.import_cache={}
        self.auto_seen={}
        self.auto_key=secrets.token_bytes(32)
        self.started_at=None

    @contextmanager
    def atomic(self):
        with self.lock:
            previous_values=self.values.copy(); previous_cache=copy.deepcopy(self.import_cache)
            previous_seen=copy.deepcopy(self.auto_seen)
            try:
                yield
            except Exception:
                self.values=previous_values; self.import_cache=previous_cache
                self.auto_seen=previous_seen
                raise

    def startup(self,store,db):
        self.started_at=store.now()
        # A process has no previous values. Persist metadata invalidation explicitly,
        # so watch sees a real change rather than claiming the old code still works.
        for row in db.execute("SELECT * FROM codes_metadata WHERE state IN ('available','assigned')").fetchall():
            self.invalidate(store,db,row,None,'lost')

    def invalidate(self,store,db,row,actor,state):
        self.values.pop(row['id'],None)
        db.execute('UPDATE codes_metadata SET state=?,version=version+1 WHERE id=?',(state,row['id']))
        if row['assigned_request_id'] is not None:
            request=db.execute('SELECT * FROM code_requests WHERE id=?',(row['assigned_request_id'],)).fetchone()
            if request and request['state']=='assigned':
                db.execute("UPDATE code_requests SET state='waiting',code_id=NULL,version=version+1,updated_at=? WHERE id=?",(store.now(),request['id']))
        code_event(db,row['id'],row['assigned_request_id'],actor,state,store.now())

    def purge(self,store,db):
        changed=False
        for row in db.execute("SELECT * FROM codes_metadata WHERE state IN ('available','assigned')").fetchall():
            state='expired' if row['expires_at'] <= store.now() else 'lost' if row['id'] not in self.values else None
            if state:
                self.invalidate(store,db,row,None,state); changed=True
        # A task handoff closes the old person's request and secret allocation.
        for request in db.execute("SELECT * FROM code_requests WHERE state IN ('waiting','assigned')").fetchall():
            if not self.current_owner(db,request):
                self.release_request(store,db,request,None,'cancelled')
                help_row=db.execute('SELECT * FROM help_requests WHERE id=?',(request['help_request_id'],)).fetchone()
                if help_row['state'] in LIVE_REQUESTS:
                    db.execute("UPDATE help_requests SET state='cancelled',version=version+1,updated_at=? WHERE id=?",(store.now(),help_row['id']))
                    help_event(db,help_row,None,'task_changed','任务已转派或进入结束阶段，旧待码请求终止。',store.now())
                    cancel_help_push(db,help_row['id'])
                changed=True
        # Ordinary task-bound requests belong to the original live assignment.
        # General questions without a task remain independent.
        for row in db.execute("SELECT * FROM help_requests WHERE kind!='code' AND state IN ('open','replied') AND task_id IS NOT NULL").fetchall():
            if not help_task_current(db, row):
                db.execute("UPDATE help_requests SET state='cancelled',version=version+1,updated_at=? WHERE id=?", (store.now(), row['id']))
                help_event(db, row, None, 'task_changed', '任务已转派或进入结束阶段，原请求关闭；新负责人需要时另发请求。', store.now())
                cancel_help_push(db, row['id'])
                changed = True
        # Values and cache disappear even if no UI/agent opens the platform.
        for key,entry in list(self.import_cache.items()):
            if entry['expiresAt'] <= store.now():
                self.import_cache.pop(key,None)
        for key,entry in list(self.auto_seen.items()):
            if entry['forgetAt'] <= store.now():
                self.auto_seen.pop(key,None)
        return changed

    def ingest(self,store,db,actor,installation,data):
        """Import locally extracted candidates without storing body/fingerprint.

        captured timestamps are explicitly a capture time, not proof of SMS
        freshness. RAM tombstones prevent consumed duplicates during this boot;
        old true received timestamps are rejected after restart.
        """
        store.reject_unknown(data,{'codes','source','purpose','receivedAt','timeSource','expiresIn'})
        codes=data.get('codes')
        if not isinstance(codes,list) or not 1 <= len(codes) <= 6 or any(not isinstance(c,str) or not re.fullmatch(r'[0-9]{4,8}',c) for c in codes):
            raise APIError(422,'codes 应为最多 6 个 4–8 位数字候选')
        codes=list(dict.fromkeys(codes))
        source=field(data,'source',limit=48)
        if (any(ord(c)<32 or ord(c)==127 for c in data.get('source','')) or re.search(r'[0-9]{4,}',source)
                or not re.fullmatch(r'[A-Za-z0-9 _&.·\-\u3400-\u9fff]*',source)
                or '验证码' in source or any(code in source for code in codes)):
            raise APIError(422,'source 仅接受短品牌标识，不接受短信正文、号码或网址')
        purpose=choice(data,'purpose',set(code_automation.PURPOSES),'unknown')
        time_source=choice(data,'timeSource',{'received','captured'},'captured')
        ttl=data.get('expiresIn',300)
        if type(ttl) is not int or not 1 <= ttl <= 900:
            raise APIError(422,'expiresIn 应为 1–900 秒整数')
        try:
            received=parse_time(data['receivedAt'])
        except (KeyError,TypeError,ValueError,AttributeError):
            raise APIError(422,'receivedAt 应为带时区的接收或提取时间') from None
        now=parse_time(store.now())
        if received > now+timedelta(seconds=30):
            raise APIError(422,'时间超出当前时间')
        if received < parse_time(self.started_at):
            raise APIError(410,'此时间早于服务启动，请等待新短信')
        expires=received+timedelta(seconds=ttl)
        if expires <= now:
            raise APIError(410,'这批验证码已过有效期')
        fingerprints={c:(actor['id'],hmac.new(self.auto_key,c.encode(),hashlib.sha256).digest()) for c in codes}
        unseen=[c for c in codes if fingerprints[c] not in self.auto_seen]
        if not unseen:
            return 200,{'imported':0,'codes':[]}
        if len(self.values)+len(unseen)>512 or len(self.auto_seen)+len(unseen)>4096:
            raise APIError(429,'短期验证码库已满，等待现有码到期后再导入')
        known_source=bool(source); known_purpose=purpose!='unknown'
        service=source or '未知来源'; label='未知账号'; display_purpose=code_automation.PURPOSES[purpose]
        namespace=(service,label,display_purpose)
        if known_source:
            newer=db.execute('''SELECT 1 FROM codes_metadata c JOIN sync_meta sm ON sm.key=?||c.id
                                 WHERE c.service=? AND c.account_label=? AND c.purpose=? AND c.received_at>? LIMIT 1''',
                             (code_automation.META_PREFIX,*namespace,timestamp(received))).fetchone()
            if newer:
                raise APIError(409,'同来源和用途已有更新的自动验证码')
            for row in db.execute('''SELECT c.* FROM codes_metadata c JOIN sync_meta sm ON sm.key=?||c.id
                                      WHERE c.service=? AND c.account_label=? AND c.purpose=? AND c.state IN ('available','assigned')''',
                                  (code_automation.META_PREFIX,*namespace)).fetchall():
                self.invalidate(store,db,row,actor,'replaced')
        batch=secrets.token_urlsafe(24); result=[]
        for code in unseen:
            code_id=secrets.token_urlsafe(24)
            db.execute('''INSERT INTO codes_metadata(id,service,account_label,purpose,received_at,expires_at,created_at,imported_by)
                          VALUES(?,?,?,?,?,?,?,?)''',(code_id,*namespace,timestamp(received),timestamp(expires),store.now(),actor['id']))
            info={'importMethod':'automatic','sourceKnown':known_source,'purposeKnown':known_purpose,
                  'timeSource':time_source,'installationId':installation,'batchId':batch}
            db.execute('INSERT INTO sync_meta(key,value) VALUES(?,?)',(code_automation.META_PREFIX+code_id,code_automation.compact(info)))
            unknown=['account_label']+([] if known_source else ['service'])+([] if known_purpose else ['purpose'])
            for column in unknown:
                db.execute('INSERT INTO sync_meta(key,value) VALUES(?,?)',(code_automation.UNKNOWN_PREFIX+column+':'+code_id,'1'))
            self.values[code_id]=code
            self.auto_seen[fingerprints[code]]={'forgetAt':timestamp(received+timedelta(seconds=900))}
            code_event(db,code_id,None,actor,'automatically_imported',store.now())
            result.append(code_automation.serialize(db,self.get_code(db,actor,code_id),serialize_code))
        return 201,{'imported':len(result),'codes':result}

    def current_owner(self,db,request):
        task=db.execute('SELECT owner_id,status FROM tasks WHERE id=?',(request['task_id'],)).fetchone()
        return task is not None and task['owner_id']==request['requester_id'] and task['status'] not in {'completed','cancelled','awaiting_review'}

    def release_request(self,store,db,request,actor,state):
        if request['code_id']:
            code=db.execute('SELECT * FROM codes_metadata WHERE id=?',(request['code_id'],)).fetchone()
            if code and code['state']=='assigned':
                # Do not let reassignment make an already revealed code usable by a
                # different worker. Discard it and wait for a newly imported code.
                self.invalidate(store,db,code,actor,'expired')
        db.execute('UPDATE code_requests SET state=?,code_id=NULL,version=version+1,updated_at=? WHERE id=?',
                   (state,store.now(),request['id']))
        code_event(db,request['code_id'],request['id'],actor,state,store.now())

    def code_snapshot(self,store,db,actor):
        stamp=store.now()
        if actor['role']=='worker':
            requests=db.execute('SELECT * FROM code_requests WHERE requester_id=? ORDER BY id DESC',(actor['id'],)).fetchall()
            # Metadata requires a current owned request. Manual imports remain exact;
            # automatic candidates relax only explicitly unknown namespace fields.
            codes=db.execute(f'''SELECT c.* FROM codes_metadata c WHERE c.state IN ('available','assigned') AND c.expires_at>?
                               AND (c.assigned_member_id=? OR (c.state='available' AND EXISTS(
                                 SELECT 1 FROM code_requests r JOIN tasks t ON t.id=r.task_id WHERE r.requester_id=?
                                 AND t.owner_id=r.requester_id AND t.status NOT IN ('completed','cancelled','awaiting_review') AND r.state='waiting'
                                 AND {code_automation.namespace_sql()}))) ORDER BY c.created_at DESC,c.id''',
                             (stamp,actor['id'],actor['id'])).fetchall()
        else:
            requests=db.execute('SELECT * FROM code_requests ORDER BY id DESC').fetchall()
            codes=db.execute("SELECT * FROM codes_metadata WHERE state IN ('available','assigned') AND expires_at>? ORDER BY created_at DESC,id",(stamp,)).fetchall()
        return {'codes':[code_automation.serialize(db,r,serialize_code) for r in codes if r['id'] in self.values],
                'codeRequests':[serialize_code_request(r) for r in requests]}

    def get_code(self,db,actor,code_id):
        row=db.execute('SELECT * FROM codes_metadata WHERE id=?',(code_id,)).fetchone()
        if row is None or actor['role']=='worker' and row['assigned_member_id'] not in {None,actor['id']}:
            raise APIError(404,'验证码不存在或不在当前成员范围')
        return row

    def get_request(self,db,actor,request_id):
        row=db.execute('SELECT * FROM code_requests WHERE id=?',(request_id,)).fetchone()
        if row is None or actor['role']=='worker' and row['requester_id']!=actor['id']:
            raise APIError(404,'待码请求不存在或不属于当前成员')
        return row

    def value(self,store,db,actor,code_id,*,check_authorization=True):
        row=self.get_code(db,actor,code_id)
        if row['state'] not in ACTIVE_CODES or row['expires_at'] <= store.now() or code_id not in self.values:
            self.values.pop(code_id,None)
            raise APIError(410,'验证码已过期、替换、用完或随服务重启清除')
        if actor['role'] != 'admin':
            if actor['role'] != 'worker' or row['assigned_member_id'] != actor['id'] or row['state']!='assigned':
                raise APIError(403,'验证码内容仅供获分派的执行 Worker 或用户本人读取')
            request=self.get_request(db,actor,row['assigned_request_id'])
            if request['state']!='assigned' or request['code_id']!=code_id or not self.current_owner(db,request):
                raise APIError(403,'任务或待码请求已变化，请重新申请验证码')
            if check_authorization:
                authorizations.gate(db, actor, request['task_id'], 'accepted')
        return {'code':self.values[code_id], 'expiresAt':row['expires_at']}

    def apply(self,store,db,actor,path,data):
        if path=='/v1/codes':
            if actor['role']!='admin':
                raise APIError(403,'验证码由用户确认导入并允许按任务共享')
            store.reject_unknown(data,{'code','service','accountLabel','purpose','expiresIn','receivedAt'})
            code=field(data,'code',limit=16,required=True)
            if not re.fullmatch(r'[A-Za-z0-9]{4,16}',code):
                raise APIError(422,'验证码应为 4–16 位字母或数字')
            namespace=tuple(field(data,key,limit=100,required=True) for key in ('service','accountLabel','purpose'))
            ttl=data.get('expiresIn',300)
            if type(ttl) is not int or not 30 <= ttl <= 900:
                raise APIError(422,'expiresIn 应为 30–900 秒整数')
            try:
                received=parse_time(data.get('receivedAt',store.now()))
            except (TypeError,ValueError,AttributeError):
                raise APIError(422,'receivedAt 应为带时区的时间') from None
            now=parse_time(store.now())
            if received > now+timedelta(seconds=30):
                raise APIError(422,'接收时间超出当前时间')
            # Lifetime starts at reception, not at a later import or client retry.
            expires=received+timedelta(seconds=ttl)
            if expires <= now:
                raise APIError(410,'这条验证码已过有效期，请等待新验证码')
            newer=db.execute('''SELECT 1 FROM codes_metadata WHERE service=? AND account_label=? AND purpose=?
                                 AND received_at>? LIMIT 1''',(*namespace,timestamp(received))).fetchone()
            if newer:
                raise APIError(409,'该用途已有更新验证码，旧短信不覆盖新码')
            for row in db.execute("SELECT * FROM codes_metadata WHERE service=? AND account_label=? AND purpose=? AND state IN ('available','assigned')",namespace).fetchall():
                self.invalidate(store,db,row,actor,'replaced')
            code_id=secrets.token_urlsafe(24)
            db.execute('''INSERT INTO codes_metadata(id,service,account_label,purpose,received_at,expires_at,created_at,imported_by)
                          VALUES(?,?,?,?,?,?,?,?)''',(code_id,*namespace,timestamp(received),timestamp(expires),store.now(),actor['id']))
            self.values[code_id]=code
            code_event(db,code_id,None,actor,'imported',store.now())
            return 201,{'code':serialize_code(self.get_code(db,actor,code_id))}
        if path=='/v1/code-requests':
            if actor['role']!='worker':
                raise APIError(403,'由执行 Worker 在自己的任务发起待码请求')
            store.reject_unknown(data,{'taskId','service','accountLabel','purpose'})
            task_id=field(data,'taskId',limit=32,required=True)
            own_task(store,db,actor,task_id)
            namespace=tuple(field(data,key,limit=100,required=True) for key in ('service','accountLabel','purpose'))
            if db.execute("SELECT 1 FROM code_requests WHERE task_id=? AND requester_id=? AND service=? AND account_label=? AND purpose=? AND state IN ('waiting','assigned')",(task_id,actor['id'],*namespace)).fetchone():
                raise APIError(409,'本任务已有同用途待码请求')
            help_row=create_help(store,db,actor,task_id,'code',namespace[0]+' 验证码',f'账号标识：{namespace[1]}；用途：{namespace[2]}。请通过验证码库导入并按任务分派。')
            cursor=db.execute('''INSERT INTO code_requests(task_id,requester_id,requester_name,help_request_id,service,account_label,purpose,created_at,updated_at)
                                 VALUES(?,?,?,?,?,?,?,?,?)''',(task_id,actor['id'],actor['name'],help_row['id'],*namespace,store.now(),store.now()))
            code_event(db,None,cursor.lastrowid,actor,'requested',store.now())
            return 201,{'codeRequest':serialize_code_request(self.get_request(db,actor,cursor.lastrowid))}
        cancel=re.fullmatch(r'/v1/code-requests/([1-9]\d*)/cancel',path)
        if cancel:
            store.reject_unknown(data,{'version'})
            row=self.get_request(db,actor,int(cancel[1])); require_version(data,row)
            if actor['role'] not in {'admin','worker'}:
                raise APIError(403,'待码请求由用户或原请求人取消')
            if row['state'] not in {'waiting','assigned'}:
                raise APIError(409,'待码请求已经结束')
            self.release_request(store,db,row,actor,'cancelled')
            h=db.execute('SELECT * FROM help_requests WHERE id=?',(row['help_request_id'],)).fetchone()
            db.execute("UPDATE help_requests SET state='cancelled',version=version+1,updated_at=? WHERE id=?",(store.now(),h['id']))
            help_event(db,h,actor,'cancelled','',store.now()); cancel_help_push(db,h['id'])
            return 200,{'codeRequest':serialize_code_request(self.get_request(db,actor,row['id']))}
        match=re.fullmatch(r'/v1/codes/('+CODE_ID+r')/(claim|assign|consume)',path)
        if not match:
            return None
        code_id,operation=match.groups()
        row=self.get_code(db,actor,code_id); require_version(data,row)
        if row['state'] not in ACTIVE_CODES or row['expires_at'] <= store.now() or code_id not in self.values:
            raise APIError(410,'验证码已失效，请等待新验证码')
        if operation=='consume':
            store.reject_unknown(data,{'version'})
            if actor['role']!='admin':
                self.value(store,db,actor,code_id,check_authorization=False)
            if row['state']!='assigned' or row['assigned_request_id'] is None:
                raise APIError(409,'验证码尚未按任务分派')
            request=self.get_request(db,actor,row['assigned_request_id'])
            db.execute("UPDATE codes_metadata SET state='consumed',version=version+1 WHERE id=?",(code_id,))
            db.execute("UPDATE code_requests SET state='consumed',version=version+1,updated_at=? WHERE id=?",(store.now(),request['id']))
            self.values.pop(code_id,None)
            code_event(db,code_id,request['id'],actor,'consumed',store.now())
            h=db.execute('SELECT * FROM help_requests WHERE id=?',(request['help_request_id'],)).fetchone()
            db.execute("UPDATE help_requests SET state='resolved',version=version+1,updated_at=? WHERE id=?",(store.now(),h['id']))
            help_event(db,h,actor,'code_consumed','验证码已使用并销毁；本记录不包含码内容。',store.now()); cancel_help_push(db,h['id'])
            return 200,{'code':serialize_code(self.get_code(db,actor,code_id)), 'codeRequest':serialize_code_request(self.get_request(db,actor,request['id']))}
        store.reject_unknown(data,{'requestId','version'})
        if type(data.get('requestId')) is not int or data['requestId'] <= 0:
            raise APIError(422,'requestId 应为正整数')
        if operation=='claim' and actor['role']!='worker':
            raise APIError(403,'由执行 Worker 领取自己任务的验证码')
        if operation=='assign' and actor['role'] not in {'admin','leader'}:
            raise APIError(403,'有歧义时由用户或 Leader 明确分派')
        request=self.get_request(db,actor,data['requestId'])
        if not self.current_owner(db,request) or request['state']!='waiting':
            raise APIError(409,'待码请求或任务归属已变化，请刷新')
        requester = db.execute('SELECT * FROM members WHERE id=?', (request['requester_id'],)).fetchone()
        if requester is None or requester['role'] != 'worker':
            raise APIError(409, '请求成员不再是执行 Worker')
        authorizations.gate(db, dict(requester), request['task_id'], 'accepted')
        if row['state']!='available':
            raise APIError(409,'验证码已被领取，等待新码或联系 Leader')
        if not code_automation.matches(db,row,request):
            raise APIError(409,'服务、账号标识和用途需与待码请求完全一致')
        if operation=='claim':
            contenders=[r for r in db.execute('''SELECT r.* FROM code_requests r JOIN tasks t ON t.id=r.task_id
                                     WHERE r.state='waiting' AND t.owner_id=r.requester_id
                                     AND t.status NOT IN ('completed','cancelled','awaiting_review')''')
                        if code_automation.matches(db,row,r)]
            if len(contenders)!=1 or contenders[0]['id']!=request['id']:
                raise APIError(409,'同用途存在多个待码请求，请由 Leader 或用户指定')
        db.execute("UPDATE codes_metadata SET state='assigned',version=version+1,assigned_request_id=?,assigned_member_id=?,task_id=? WHERE id=?",(request['id'],request['requester_id'],request['task_id'],code_id))
        db.execute("UPDATE code_requests SET state='assigned',version=version+1,code_id=?,updated_at=? WHERE id=?",(code_id,store.now(),request['id']))
        code_event(db,code_id,request['id'],actor,'assigned',store.now())
        return 200,{'code':serialize_code(self.get_code(db,actor,code_id)), 'codeRequest':serialize_code_request(self.get_request(db,actor,request['id']))}
