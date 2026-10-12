"""Private APNs outbox. Queue in the business transaction, send after commit."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import stat
import tempfile
import time
from datetime import timedelta
from common import APIError, field, parse_time, timestamp


def enqueue(db, event_key, kind, route, stamp, rearm=False, *, recipient_id=None, installation_id=None):
    if kind in {'message_user','help_user'} and recipient_id is None:
        raise ValueError('Message notifications require an exact recipient')
    label={'authorization_card':'有一项授权卡需要你亲自处理。','authorization_user':'有一项授权申请等待你决定。','review_user':'Leader 转来一项成果，请你终审。','message_user':'有一条新消息，打开协作台查看并回复。','help_user':'有一项请求需要你提供信息，打开协作台查看。'}[kind]
    title='协作台 · 新消息' if kind == 'message_user' else '协作台 · 待你处理'
    payload=json.dumps({'aps':{'alert':{'title':title,'body':label},'sound':'default'},'route':route,'kind':kind,'workspaceId':db.execute("SELECT value FROM sync_meta WHERE key='workspace_id'").fetchone()[0]},ensure_ascii=False)
    for device in db.execute("""SELECT d.* FROM push_devices d JOIN members m ON m.id=d.member_id
                              WHERE d.enabled=1 AND m.role='admin'
                              AND (? IS NULL OR d.member_id=?)
                              AND (? IS NULL OR d.installation_id=?)""",
                             (recipient_id,recipient_id,installation_id,installation_id)):
        if rearm:
            db.execute("UPDATE push_outbox SET state='pending',attempts=0,next_attempt_at=?,last_error='' WHERE event_key=? AND installation_id=? AND state='cancelled'",(stamp,event_key,device['installation_id']))
        db.execute('INSERT OR IGNORE INTO push_outbox(event_key,installation_id,member_id,payload,next_attempt_at,created_at) VALUES(?,?,?,?,?,?)',
                   (event_key,device['installation_id'],device['member_id'],payload,stamp,stamp))


def apply(store,db,actor,path,data):
    if path!='/v1/push/devices': return None
    if actor['role']!='admin': raise APIError(403,'手机通知接收端由用户登记')
    store.reject_unknown(data,{'installationId','token','environment','enabled'})
    installation=field(data,'installationId',limit=64,required=True)
    if not re.fullmatch('[A-Za-z0-9_-]{16,64}',installation): raise APIError(422,'安装标识格式有误')
    enabled=data.get('enabled',True)
    if type(enabled) is not bool: raise APIError(422,'enabled 应为布尔值')
    if not enabled:
        db.execute('UPDATE push_devices SET enabled=0,updated_at=? WHERE installation_id=? AND member_id=?',(store.now(),installation,actor['id']))
        db.execute("UPDATE push_outbox SET state='cancelled' WHERE installation_id=? AND member_id=? AND state='pending'",(installation,actor['id']))
        return 200,{'registered':False}
    token=field(data,'token',limit=256,required=True).lower(); env=data.get('environment')
    if not re.fullmatch('[a-fA-F0-9]{64,256}',token) or len(token)%2 or env not in {'sandbox','production'}: raise APIError(422,'设备凭据或推送环境有误')
    previous=db.execute('SELECT * FROM push_devices WHERE installation_id=?',(installation,)).fetchone()
    if previous and previous['enabled'] and previous['member_id']==actor['id'] and previous['token']==token and previous['environment']==env:
        return 200,{'registered':True,'environment':env}
    # A token belongs to one active member per server; re-registration cancels old queues.
    db.execute("UPDATE push_outbox SET state='cancelled' WHERE state='pending' AND installation_id IN (SELECT installation_id FROM push_devices WHERE (token=? AND environment=?) OR installation_id=?)",(token,env,installation))
    db.execute('DELETE FROM push_devices WHERE token=? AND environment=? AND installation_id<>? AND NOT EXISTS(SELECT 1 FROM push_outbox o WHERE o.installation_id=push_devices.installation_id)',(token,env,installation))
    other=db.execute('SELECT installation_id FROM push_devices WHERE token=? AND environment=? AND installation_id<>?',(token,env,installation)).fetchone()
    if other: # Keep immutable delivery record references, disable the previous installation and free its token identity.
        db.execute("UPDATE push_devices SET enabled=0,token='retired-'||installation_id WHERE installation_id=?",(other[0],))
    db.execute('''INSERT INTO push_devices VALUES(?,?,?,?,1,?) ON CONFLICT(installation_id) DO UPDATE SET
                  member_id=excluded.member_id,token=excluded.token,environment=excluded.environment,enabled=1,updated_at=excluded.updated_at''',(installation,actor['id'],token.lower(),env,store.now()))
    # Include existing pending user decisions on first registration (never add demo records).
    for row in db.execute("SELECT id,kind FROM authorization_requests WHERE state='awaiting_user'"):
        enqueue(db,f'authorization:{row[0]}:user', 'authorization_card' if row[1]=='card' else 'authorization_user','collabdesk://authorizations',store.now(),rearm=True)
    for row in db.execute("SELECT id,submission_seq FROM tasks WHERE status='awaiting_review' AND review_stage='user'"):
        enqueue(db,f'review:{row[0]}:{row[1]}','review_user',f'collabdesk://task/{row[0]}',store.now(),rearm=True)
    # One catch-up reminder per newly registered installation, not a burst of history.
    row=db.execute("SELECT id FROM messages WHERE recipient_id=? AND read_at IS NULL ORDER BY id DESC LIMIT 1",(actor['id'],)).fetchone()
    if row:
        enqueue(db,f'message:{row[0]}','message_user',f'collabdesk://message/{row[0]}',store.now(),rearm=True,
                recipient_id=actor['id'],installation_id=installation)
    for request in db.execute("SELECT id FROM help_requests WHERE recipient_id=? AND state='open' ORDER BY id DESC LIMIT 1",(actor['id'],)):
        enqueue(db,f"help:{request['id']}",'help_user',f"collabdesk://user-request/{request['id']}",store.now(),rearm=True,
                recipient_id=actor['id'],installation_id=installation)
    return 200,{'registered':True,'environment':env}


def status(db,actor):
    if actor['role']!='admin': return None
    enabled=db.execute('SELECT count(*) FROM push_devices WHERE member_id=? AND enabled=1',(actor['id'],)).fetchone()[0]
    counts={r[0]:r[1] for r in db.execute('SELECT state,count(*) FROM push_outbox WHERE member_id=? GROUP BY state',(actor['id'],))}
    problem=config_problem()
    return {'configured':problem is None,'configProblem':problem,'registeredDevices':enabled,'queued':counts.get('pending',0),
            'acceptedByAPNs':counts.get('accepted',0),'failed':counts.get('failed',0),
            'deliveryNote':'APNs 接受请求不等于手机已经显示；提醒受系统权限、网络和专注模式影响。'}


def config_problem():
    """Local readiness only; neither disclose secret paths nor promise APNs delivery."""
    values={k:os.environ.get(k,'') for k in ('COLLAB_APNS_KEY_FILE','COLLAB_APNS_KEY_ID','COLLAB_APNS_TEAM_ID')}
    if not all(v.strip() for v in values.values()): return '待提供 Apple 推送密钥、Key ID 和 Team ID'
    if any(not re.fullmatch('[A-Z0-9]{10}',values[k]) for k in ('COLLAB_APNS_KEY_ID','COLLAB_APNS_TEAM_ID')):
        return 'Key ID 或 Team ID 格式有误'
    key=Path(values['COLLAB_APNS_KEY_FILE'])
    try:
        if not key.is_file(): return 'Apple 推送密钥文件尚未就绪'
        if stat.S_IMODE(key.stat().st_mode) != 0o600: return 'Apple 推送密钥文件权限应为 0600'
        with key.open('rb') as stream:
            if not stream.read(1): return 'Apple 推送密钥文件为空'
    except OSError:
        return '服务进程读取 Apple 推送密钥失败'
    return None


def configured():
    return config_problem() is None


def b64(data): return base64.urlsafe_b64encode(data).rstrip(b'=').decode()
_cached_jwt=None

def jwt():
    global _cached_jwt
    now=int(time.time())
    if _cached_jwt and now-_cached_jwt[0]<2700: return _cached_jwt[1]
    key=Path(os.environ['COLLAB_APNS_KEY_FILE'])
    if not key.is_file() or key.stat().st_mode & 0o077: raise RuntimeError('APNs key file must be private (0600)')
    header=b64(json.dumps({'alg':'ES256','kid':os.environ['COLLAB_APNS_KEY_ID']},separators=(',',':')).encode())
    claims=b64(json.dumps({'iss':os.environ['COLLAB_APNS_TEAM_ID'],'iat':now},separators=(',',':')).encode())
    message=f'{header}.{claims}'.encode()
    result=subprocess.run(['openssl','dgst','-sha256','-sign',str(key)],input=message,capture_output=True,timeout=10)
    if result.returncode: raise RuntimeError('APNs signing failed')
    der=result.stdout
    def length(offset):
        n=der[offset]; offset+=1
        if n&128:
            size=n&127; n=int.from_bytes(der[offset:offset+size],'big'); offset+=size
        return n,offset
    if not der or der[0]!=0x30: raise RuntimeError('APNs signing format invalid')
    _,pos=length(1); values=[]
    for _ in range(2):
        if der[pos]!=2: raise RuntimeError('APNs signing format invalid')
        size,start=length(pos+1); values.append(int.from_bytes(der[start:start+size],'big').to_bytes(32,'big')); pos=start+size
    token=message.decode()+'.'+b64(b''.join(values)); _cached_jwt=(now,token); return token


def send(device,payload,event_id):
    host='api.sandbox.push.apple.com' if device['environment']=='sandbox' else 'api.push.apple.com'
    topic=os.environ.get('COLLAB_APNS_TOPIC','org.example.collabdesk')
    with tempfile.TemporaryDirectory(prefix='collab-apns-') as folder:
        body=Path(folder)/'body.json'; response=Path(folder)/'response.json'; body.write_text(payload); body.chmod(0o600)
        # Secrets go through stdin config, never process argv, logs or API responses.
        config='\n'.join(f'{k} = {json.dumps(v)}' for k,v in [
            ('url',f'https://{host}/3/device/{device["token"]}'),('header','authorization: bearer '+jwt()),
            ('header','apns-topic: '+topic),('header','apns-push-type: alert'),('header','apns-priority: 10'),
            ('header',f'apns-collapse-id: collab-{event_id}'),('header','apns-expiration: '+str(int(time.time())+3600)),
            ('data-binary','@'+str(body)),('output',str(response))])+'\n'
        r=subprocess.run(['curl','--http2','--silent','--show-error','--max-time','15','--write-out','%{http_code}','--config','-'],
                         input=config,text=True,capture_output=True,timeout=20)
        if r.returncode: return 0,'TransportError'
        code=int(r.stdout) if r.stdout.isdigit() else 0
        try: reason=json.loads(response.read_text()).get('reason','')
        except (ValueError,OSError): reason=''
        return code,reason if re.fullmatch('[A-Za-z0-9_]{0,80}',reason) else 'APNsError'


def drain(store, stop_event=None):
    if not configured(): return
    with store.connection() as db:
        rows=db.execute("SELECT * FROM push_outbox WHERE state='pending' AND next_attempt_at<=? ORDER BY id LIMIT 20",(store.now(),)).fetchall()
    for row in rows:
        if stop_event is not None and stop_event.is_set(): return
        with store.connection() as db:
            # A read/disable may have cancelled a row since this batch was captured.
            current=db.execute("SELECT state FROM push_outbox WHERE id=?",(row['id'],)).fetchone()
            if current is None or current['state']!='pending': continue
            parts=row['event_key'].split(':')
            relevant=False
            if parts[0]=='authorization' and len(parts)==3:
                relevant=db.execute("SELECT 1 FROM authorization_requests WHERE id=? AND state='awaiting_user'",(parts[1],)).fetchone() is not None
            elif parts[0]=='review' and len(parts)==3:
                relevant=db.execute("SELECT 1 FROM tasks WHERE id=? AND submission_seq=? AND status='awaiting_review' AND review_stage='user'",(parts[1],parts[2])).fetchone() is not None
            elif parts[0]=='help' and len(parts)==2:
                relevant=db.execute("SELECT 1 FROM help_requests WHERE id=? AND recipient_id=? AND state='open'",(parts[1],row['member_id'])).fetchone() is not None
            elif parts[0]=='message' and len(parts)==2:
                relevant=db.execute("SELECT 1 FROM messages m JOIN members r ON r.id=m.recipient_id WHERE m.id=? AND m.recipient_id=? AND m.read_at IS NULL AND r.role='admin'",(parts[1],row['member_id'])).fetchone() is not None
            if not relevant:
                db.execute("UPDATE push_outbox SET state='cancelled' WHERE id=?",(row['id'],)); continue
            device=db.execute('SELECT * FROM push_devices WHERE installation_id=?',(row['installation_id'],)).fetchone()
            if device is None or not device['enabled'] or device['member_id']!=row['member_id']:
                db.execute("UPDATE push_outbox SET state='cancelled' WHERE id=?",(row['id'],)); continue
        if stop_event is not None and stop_event.is_set(): return
        try: code,reason=send(device,row['payload'],row['id'])
        except Exception: code,reason=0,'ConfigurationOrTransportError'
        attempts=row['attempts']+1
        state='accepted' if code==200 else ('pending' if (code in {0,429,500,503} and attempts<10) else 'failed')
        due=timestamp(parse_time(store.now())+timedelta(seconds=min(3600,30*(2**min(attempts,7)))))
        with store.connection() as db:
            db.execute("UPDATE push_outbox SET state=?,attempts=?,next_attempt_at=?,last_error=? WHERE id=? AND state='pending'",(state,attempts,due,'' if code==200 else f'{code}:{reason}',row['id']))
            if code==410 or reason in {'BadDeviceToken','DeviceTokenNotForTopic','Unregistered'}:
                db.execute('UPDATE push_devices SET enabled=0 WHERE installation_id=? AND token=?',(device['installation_id'],device['token']))
