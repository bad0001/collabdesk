"""Private SQLite/RAM fixtures only. No production, SMS history or APNs traffic."""
from datetime import datetime, timedelta, timezone
import http.client
import json
from pathlib import Path
import sqlite3
import tempfile
import threading
import unittest
from unittest import mock
import uuid

import notifications
import sync
from common import APIError, timestamp
from server import Store, Server


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.date=datetime(2026,10,8,12,tzinfo=timezone.utc)
        self.path=Path(self.temp.name)/'fixture.sqlite3'
        self.store=Store(self.path,clock=lambda:timestamp(self.date))
        self.actors={}; self.tokens={}
        for id,role in [('user','admin'),('zzuser','admin'),('leader','leader'),('b','worker'),('c','worker')]:
            self.tokens[id]=self.store.add_member(id,'Fixture '+id,role)
            self.actors[id]=self.store.authenticate('Bearer '+self.tokens[id])
        with self.store.connection() as db:
            self.workspace=db.execute("SELECT value FROM sync_meta WHERE key='workspace_id'").fetchone()[0]

    def tearDown(self): self.temp.cleanup()

    def write(self,actor,path,data,key=None):
        return self.store.mutate(self.actors[actor],path,data,key or uuid.uuid4().hex)[1]

    def fail(self,code,actor,path,data,key=None):
        with self.assertRaises(APIError) as error:
            self.write(actor,path,data,key)
        self.assertEqual(error.exception.status,code)

    def task(self,owner='b'):
        return self.write('leader','/v1/tasks',{'title':'Fixture task','ownerId':owner,'source':'leader'})['task']

    def help(self,actor='b',task=None,kind='question',key=None):
        return self.write(actor,'/v1/user-requests',{'taskId':task['id'] if task else None,'kind':kind,'subject':'Fixture subject','body':'PRIVATE help body'},key)['userRequest']

    def request(self,actor='b',task=None,namespace=None,key=None):
        task=task or self.task(actor)
        return self.write(actor,'/v1/code-requests',{'taskId':task['id'],**(namespace or self.namespace())},key)['codeRequest']

    @staticmethod
    def namespace(): return {'service':'Fixture Service','accountLabel':'Fixture account','purpose':'sign in'}

    def import_code(self,secret='A7X9K2',namespace=None,key=None,**other):
        return self.write('user','/v1/codes',{'code':secret,**(namespace or self.namespace()),**other},key)['code']

    def claim(self,code,request,actor='b',assign=False,key=None):
        return self.write(actor,f"/v1/codes/{code['id']}/{'assign' if assign else 'claim'}",{'requestId':request['id'],'version':code['version']},key)

    def watch(self,actor): return self.store.watch(self.workspace,actor)

    def scalar(self,sql,args=()):
        with self.store.connection() as db: return db.execute(sql,args).fetchone()[0]


class UserRequestTests(Fixture):
    def test_user_request_creation_identity_scope_and_null_task(self):
        request=self.help()
        self.assertEqual(request['requesterId'],'b')
        self.assertEqual(request['state'],'open')
        self.assertIsNone(request['taskId'])
        self.assertEqual(self.store.snapshot(self.actors['c'])['userRequests'],[])
        self.assertEqual(self.store.snapshot(self.actors['zzuser'])['userRequests'],[])
        self.assertEqual(self.store.snapshot(self.actors['leader'])['userRequests'][0],request)
        self.assertEqual(self.store.snapshot(self.actors['user'])['userRequests'][0],request)

    def test_user_request_only_owner_can_attach_task(self):
        task=self.task('c')
        self.fail(404,'b','/v1/user-requests',{'taskId':task['id'],'kind':'material','subject':'s','body':'b'})
        self.fail(403,'leader','/v1/user-requests',{'taskId':task['id'],'kind':'material','subject':'s','body':'b'})
        self.fail(403,'user','/v1/user-requests',{'kind':'question','subject':'s','body':'b'})

    def test_kind_and_actor_fields_are_validated(self):
        self.fail(422,'b','/v1/user-requests',{'kind':'approval','subject':'s','body':'b'})
        self.fail(422,'b','/v1/user-requests',{'kind':'question','subject':'s','body':'b','requesterId':'c'})
        self.fail(422,'b','/v1/user-requests',{'taskId':'TASK-1','kind':'question','subject':'s','body':'b'})

    def test_reply_targets_requester_and_can_resolve(self):
        request=self.help(task=self.task())
        result=self.write('user',f"/v1/user-requests/{request['id']}/reply",{'version':1,'body':'Fixture reply','resolve':True})
        self.assertEqual(result['userRequest']['state'],'resolved')
        self.assertEqual(result['userRequest']['responseBy'],'user')
        message=self.store.snapshot(self.actors['b'])['messages'][0]
        self.assertEqual(message['recipientId'],'b')
        self.assertIn(f"#{request['id']}",message['body'])
        self.assertEqual(self.store.snapshot(self.actors['c'])['messages'],[])
        self.assertEqual(self.scalar('SELECT count(*) FROM help_events'),2)

    def test_reply_not_read_marker_and_cas(self):
        request=self.help()
        result=self.write('user',f"/v1/user-requests/{request['id']}/reply",{'version':1,'body':'reply'})
        self.assertEqual(result['userRequest']['state'],'replied')
        self.fail(409,'user',f"/v1/user-requests/{request['id']}/resolve",{'version':1})
        message_id=result['messageId']
        self.write('b',f'/v1/messages/{message_id}/read',{})
        self.assertEqual(self.store.snapshot(self.actors['b'])['userRequests'][0]['state'],'replied')
        result=self.write('b',f"/v1/user-requests/{request['id']}/resolve",{'version':2})
        self.assertEqual(result['userRequest']['state'],'resolved')
        self.fail(409,'user',f"/v1/user-requests/{request['id']}/reply",{'version':3,'body':'late'})

    def test_leader_and_other_worker_cannot_answer_for_user(self):
        request=self.help()
        self.fail(403,'leader',f"/v1/user-requests/{request['id']}/reply",{'version':1,'body':'reply'})
        self.fail(403,'b',f"/v1/user-requests/{request['id']}/reply",{'version':1,'body':'reply'})
        self.fail(404,'c',f"/v1/user-requests/{request['id']}/resolve",{'version':1})
        self.fail(404,'zzuser',f"/v1/user-requests/{request['id']}/reply",{'version':1,'body':'reply'})
        self.fail(403,'leader',f"/v1/user-requests/{request['id']}/resolve",{'version':1})

    def test_user_request_idempotency_and_append_only_history(self):
        first=self.help(key='fixture-help-once')
        self.assertEqual(first,self.help(key='fixture-help-once'))
        self.assertEqual(self.scalar('SELECT count(*) FROM help_requests'),1)
        self.write('b',f"/v1/user-requests/{first['id']}/cancel",{'version':1})
        with self.store.connection() as db:
            for sql in ('DELETE FROM help_events','UPDATE help_events SET body=\'changed\''):
                with self.assertRaises(sqlite3.IntegrityError): db.execute(sql)

    def test_general_reply_does_not_bypass_external_authorization_card(self):
        task=self.task()
        auth=self.write('b','/v1/authorizations',{'taskId':task['id'],'kind':'card','subject':'external login','reason':'needs human account','accountLabel':'fixture'})['authorization']
        request=self.help(task=task,kind='external_action')
        self.write('user',f"/v1/user-requests/{request['id']}/reply",{'version':1,'body':'I will look','resolve':True})
        self.assertEqual(self.scalar('SELECT state FROM authorization_requests WHERE id=?',(auth['id'],)),'awaiting_user')
        self.fail(409,'b',f"/v1/tasks/{task['id']}/updates",{'kind':'accepted','version':task['version'],'body':'continue'})

    def test_code_request_cannot_be_fulfilled_through_ordinary_reply(self):
        pending=self.request()
        request=next(r for r in self.store.snapshot(self.actors['user'])['userRequests'] if r['id']==pending['userRequestId'])
        self.fail(409,'user',f"/v1/user-requests/{request['id']}/reply",{'version':1,'body':'123456'})
        self.assertEqual(self.scalar('SELECT count(*) FROM messages'),0)

    def test_help_push_is_generic_and_rechecked_before_send(self):
        self.write('user','/v1/push/devices',{'installationId':'fixture-installation-user','token':'a'*64,'environment':'sandbox'})
        request=self.help()
        with self.store.connection() as db:
            row=dict(db.execute('SELECT * FROM push_outbox').fetchone())
        self.assertNotIn('PRIVATE',row['payload'])
        self.assertNotIn('Fixture b',row['payload'])
        self.assertEqual(json.loads(row['payload'])['route'],f"collabdesk://user-request/{request['id']}")
        self.write('user',f"/v1/user-requests/{request['id']}/reply",{'version':1,'body':'reply'})
        with mock.patch.object(notifications,'configured',return_value=True),mock.patch.object(notifications,'send',return_value=(200,'')) as sender:
            notifications.drain(self.store)
            self.assertEqual(sender.call_count,0)
        self.assertEqual(self.scalar('SELECT state FROM push_outbox'),'cancelled')

    def test_help_watch_scoping_incremental_and_heartbeat(self):
        before={id:self.watch(id) for id in ('user','leader','b','c')}
        incremental=self.store.incremental(self.actors['b'])
        request=self.help()
        for id in ('user','leader','b'):
            after=self.watch(id)
            self.assertNotEqual(after['cursor'],before[id]['cursor'])
            self.assertNotEqual(after['revisions']['messages'],before[id]['revisions']['messages'])
            self.assertNotIn('PRIVATE',json.dumps(after))
        self.assertEqual(self.watch('c'),before['c'])
        self.store.poll(self.actors['b'])
        stable=self.watch('b')
        self.store.poll(self.actors['b'])
        self.assertEqual(self.watch('b'),stable)
        delta=self.store.incremental(self.actors['b'],incremental['new_cursor'])
        self.assertIn('userRequests',{i['collection'] for i in delta['items']})
        self.assertIn('userRequestEvents',{i['collection'] for i in delta['items']})
        self.assertEqual(len(self.watch('b')),9)
        self.assertEqual(len(self.store.watch(self.workspace)),6)


class CodeVaultTests(Fixture):
    def test_code_import_is_user_only_validated_and_not_a_credential(self):
        payload={'code':'A7X9K2',**self.namespace()}
        self.fail(403,'b','/v1/codes',payload)
        self.fail(403,'leader','/v1/codes',payload)
        self.fail(422,'user','/v1/codes',{**payload,'rawSMS':'private text'})
        for value in [True,29,901,'300']:
            self.fail(422,'user','/v1/codes',{**payload,'expiresIn':value})
        self.fail(422,'user','/v1/codes',{**payload,'code':'12'})

    def test_value_not_in_metadata_snapshot_sync_sqlite_or_backup(self):
        request=self.request()
        code=self.import_code()
        self.claim(code,request)
        value=self.store.code_value(self.actors['b'],code['id'])
        self.assertEqual(value['code'],'A7X9K2')
        for actor in self.actors.values():
            snapshot=self.store.snapshot(actor)
            self.assertNotIn('codes',snapshot)
            self.assertNotIn('A7X9K2',json.dumps(snapshot))
            self.assertNotIn('A7X9K2',json.dumps(self.store.incremental(actor)))
            self.assertNotIn('A7X9K2',json.dumps(self.store.codes(actor)))
        self.assertNotIn(b'A7X9K2',self.path.read_bytes())
        with self.store.connection() as db, sqlite3.connect(Path(self.temp.name)/'backup.sqlite3') as backup:
            db.backup(backup)
            self.assertNotIn('A7X9K2',''.join(backup.iterdump()))
        self.assertNotIn(b'A7X9K2',(Path(self.temp.name)/'backup.sqlite3').read_bytes())
        self.assertEqual(self.scalar("SELECT count(*) FROM idempotency WHERE key='fixture-code-import-once'"),0)

    def test_import_idempotency_is_ram_only_and_not_replayed_after_restart(self):
        code=self.import_code(key='fixture-code-import-once')
        self.assertEqual(code,self.import_code(key='fixture-code-import-once'))
        self.assertEqual(self.scalar('SELECT count(*) FROM codes_metadata'),1)
        self.assertEqual(self.scalar("SELECT count(*) FROM idempotency WHERE key='fixture-code-import-once'"),0)
        restarted=Store(self.path,clock=lambda:timestamp(self.date))
        self.assertEqual(restarted.code_vault.values,{})
        self.assertEqual(restarted.code_vault.import_cache,{})
        with self.assertRaises(APIError) as error: restarted.code_value(self.actors['user'],code['id'])
        self.assertEqual(error.exception.status,410)
        self.assertEqual(self.scalar('SELECT state FROM codes_metadata WHERE id=?',(code['id'],)),'lost')

    def test_worker_candidates_only_match_own_live_requested_namespace(self):
        code=self.import_code()
        self.assertEqual(self.store.codes(self.actors['b'])['codes'],[])
        request=self.request()
        self.assertEqual(self.store.codes(self.actors['b'])['codes'][0]['id'],code['id'])
        self.assertEqual(self.store.codes(self.actors['c'])['codes'],[])
        with self.assertRaises(APIError) as error: self.store.code_value(self.actors['b'],code['id'])
        self.assertEqual(error.exception.status,403)
        self.claim(code,request)
        self.assertEqual(self.store.code_value(self.actors['b'],code['id'])['code'],'A7X9K2')
        with self.assertRaises(APIError) as error: self.store.code_value(self.actors['c'],code['id'])
        self.assertEqual(error.exception.status,404)
        with self.assertRaises(APIError) as error: self.store.code_value(self.actors['leader'],code['id'])
        self.assertEqual(error.exception.status,403)

    def test_code_request_creates_user_request_and_duplicate_request_conflicts(self):
        task=self.task()
        request=self.request(task=task)
        help_row=self.store.snapshot(self.actors['user'])['userRequests'][0]
        self.assertEqual(help_row['id'],request['userRequestId'])
        self.assertEqual(help_row['kind'],'code')
        self.fail(409,'b','/v1/code-requests',{'taskId':task['id'],**self.namespace()})
        self.fail(404,'c','/v1/code-requests',{'taskId':task['id'],**self.namespace()})
        self.fail(403,'leader','/v1/code-requests',{'taskId':task['id'],**self.namespace()})

    def test_namespace_latest_not_global_and_older_sms_cannot_override(self):
        request=self.request(); first=self.import_code()
        claimed=self.claim(first,request)['code']
        unrelated=self.import_code(secret='Q8W7E6',namespace={**self.namespace(),'purpose':'payment confirm'})
        self.assertEqual(self.store.code_value(self.actors['b'],first['id'])['code'],'A7X9K2')
        self.date+=timedelta(seconds=5)
        latest=self.import_code(secret='N6B5V4')
        with self.assertRaises(APIError) as error:self.store.code_value(self.actors['b'],first['id'])
        self.assertEqual(error.exception.status,410)
        self.assertNotIn(first['id'],self.store.code_vault.values)
        self.assertIn(unrelated['id'],self.store.code_vault.values)
        self.assertEqual(self.scalar('SELECT state FROM codes_metadata WHERE id=?',(first['id'],)),'replaced')
        self.assertEqual(self.scalar('SELECT state FROM code_requests WHERE id=?',(request['id'],)),'waiting')
        self.fail(409,'user','/v1/codes',{'code':'K4L3M2',**self.namespace(),'receivedAt':timestamp(self.date-timedelta(seconds=2))})
        self.assertEqual(self.store.codes(self.actors['b'])['codes'][0]['id'],latest['id'])

    def test_expiry_is_from_received_at_and_cleans_metadata_and_ram(self):
        request=self.request(); code=self.import_code(expiresIn=30)
        self.claim(code,request)
        before=self.watch('b')
        self.date+=timedelta(seconds=31)
        self.assertEqual(self.store.codes(self.actors['b'])['codes'],[])
        with self.assertRaises(APIError) as error: self.store.code_value(self.actors['b'],code['id'])
        self.assertEqual(error.exception.status,410)
        self.store.scan()
        self.assertNotIn(code['id'],self.store.code_vault.values)
        self.assertEqual(self.scalar('SELECT state FROM codes_metadata WHERE id=?',(code['id'],)),'expired')
        self.assertNotEqual(self.watch('b')['cursor'],before['cursor'])
        self.fail(410,'user','/v1/codes',{'code':'N6B5V4',**self.namespace(),'expiresIn':30,'receivedAt':timestamp(self.date-timedelta(seconds=31))})
        self.fail(422,'user','/v1/codes',{'code':'N6B5V4',**self.namespace(),'receivedAt':timestamp(self.date+timedelta(seconds=31))})

    def test_competing_workers_need_explicit_leader_assignment(self):
        b_request=self.request('b'); c_request=self.request('c'); code=self.import_code()
        for actor,request in [('b',b_request),('c',c_request)]:
            self.fail(409,actor,f"/v1/codes/{code['id']}/claim",{'requestId':request['id'],'version':1})
        result=self.claim(code,b_request,'leader',assign=True)
        self.assertEqual(result['code']['assignedMemberId'],'b')
        self.fail(404,'c',f"/v1/codes/{code['id']}/claim",{'requestId':c_request['id'],'version':1})
        self.assertEqual(self.store.code_value(self.actors['b'],code['id'])['code'],'A7X9K2')

    def test_same_worker_two_tasks_same_namespace_needs_leader(self):
        first=self.request(); second=self.request(); code=self.import_code()
        self.fail(409,'b',f"/v1/codes/{code['id']}/claim",{'requestId':first['id'],'version':1})
        result=self.claim(code,second,'user',assign=True)
        self.assertEqual(result['code']['assignedRequestId'],second['id'])

    def test_two_concurrent_claims_exactly_one_allocation(self):
        request=self.request(); code=self.import_code()
        barrier=threading.Barrier(3); results=[]
        def attempt():
            barrier.wait()
            try: results.append(('ok',self.claim(code,request)))
            except APIError as error:results.append(('error',error.status))
        workers=[threading.Thread(target=attempt) for _ in range(2)]
        for worker in workers:worker.start()
        barrier.wait()
        for worker in workers:worker.join(timeout=10)
        self.assertEqual(sorted(r[0] for r in results),['error','ok'])
        self.assertEqual([r[1] for r in results if r[0]=='error'],[409])
        self.assertEqual(self.scalar("SELECT count(*) FROM code_events WHERE kind='assigned'"),1)

    def test_code_claim_replay_metadata_no_secret_and_consume_erases_value(self):
        request=self.request(); code=self.import_code()
        first=self.claim(code,request,key='fixture-claim-once')
        self.assertEqual(self.claim(code,request,key='fixture-claim-once'),first)
        self.assertNotIn('A7X9K2',json.dumps(first))
        result=self.write('b',f"/v1/codes/{code['id']}/consume",{'version':first['code']['version']})
        self.assertEqual(result['code']['state'],'consumed')
        self.assertEqual(result['codeRequest']['state'],'consumed')
        self.assertNotIn(code['id'],self.store.code_vault.values)
        with self.assertRaises(APIError) as error: self.store.code_value(self.actors['b'],code['id'])
        self.assertEqual(error.exception.status,410)
        self.assertEqual(self.scalar('SELECT state FROM help_requests WHERE id=?',(request['userRequestId'],)),'resolved')
        self.assertNotIn('A7X9K2',self.path.read_bytes().decode(errors='ignore'))

    def test_cancel_user_request_erases_assigned_code_and_preserves_audit(self):
        request=self.request(); code=self.import_code(); self.claim(code,request)
        self.write('user',f"/v1/user-requests/{request['userRequestId']}/cancel",{'version':1})
        self.assertNotIn(code['id'],self.store.code_vault.values)
        self.assertEqual(self.scalar('SELECT state FROM code_requests WHERE id=?',(request['id'],)),'cancelled')
        with self.store.connection() as db:
            for statement in ['DELETE FROM code_events',"UPDATE code_events SET kind='changed'"]:
                with self.assertRaises(sqlite3.IntegrityError): db.execute(statement)

    def test_task_handoff_cancels_old_request_and_blocks_reveal(self):
        task=self.task(); request=self.request(task=task); code=self.import_code(); self.claim(code,request)
        self.write('leader',f"/v1/tasks/{task['id']}/updates",{'version':task['version'],'kind':'handoff','ownerId':'c','body':'fixture handoff'})
        self.assertEqual(self.scalar('SELECT state FROM code_requests WHERE id=?',(request['id'],)),'cancelled')
        self.assertNotIn(code['id'],self.store.code_vault.values)
        with self.assertRaises(APIError) as error: self.store.code_value(self.actors['b'],code['id'])
        self.assertEqual(error.exception.status,410)
        self.assertEqual(self.scalar('SELECT state FROM help_requests WHERE id=?',(request['userRequestId'],)),'cancelled')

    def test_mutation_failure_restores_ram_and_sqlite(self):
        request=self.request(); first=self.import_code()
        with mock.patch.object(sync,'rotate_signal',side_effect=RuntimeError('fixture commit failure')):
            with self.assertRaises(RuntimeError): self.import_code(secret='N6B5V4')
        self.assertEqual(self.scalar('SELECT count(*) FROM codes_metadata'),1)
        self.assertEqual(self.store.code_vault.values,{first['id']:'A7X9K2'})
        assigned=self.claim(first,request)['code']
        with mock.patch.object(sync,'rotate_signal',side_effect=RuntimeError('fixture commit failure')):
            with self.assertRaises(RuntimeError):self.write('user',f"/v1/user-requests/{request['userRequestId']}/resolve",{'version':1})
        self.assertEqual(self.store.code_value(self.actors['b'],first['id'])['code'],'A7X9K2')
        self.assertEqual(self.scalar('SELECT state FROM code_requests WHERE id=?',(request['id'],)),'assigned')

    def test_code_namespace_mismatch_does_not_auto_associate_by_time(self):
        request=self.request()
        code=self.import_code(namespace={**self.namespace(),'accountLabel':'Other account'})
        self.fail(409,'b',f"/v1/codes/{code['id']}/claim",{'requestId':request['id'],'version':1})
        self.fail(409,'leader',f"/v1/codes/{code['id']}/assign",{'requestId':request['id'],'version':1})
        self.assertEqual(self.store.codes(self.actors['b'])['codes'],[])

    def test_watch_own_code_changes_and_other_worker_not_woken(self):
        request=self.request()
        before_b=self.watch('b'); before_c=self.watch('c')
        code=self.import_code()
        after_b=self.watch('b')
        self.assertNotEqual(after_b['revisions']['messages'],before_b['revisions']['messages'])
        self.assertEqual(self.watch('c'),before_c)
        self.assertNotIn('Fixture Service',json.dumps(after_b))
        self.assertNotIn('Fixture account',json.dumps(after_b))
        self.assertNotIn('A7X9K2',json.dumps(after_b))
        self.claim(code,request)
        after_claim=self.watch('b')
        self.assertNotEqual(after_claim['cursor'],after_b['cursor'])
        self.store.poll(self.actors['b'])
        self.assertEqual(self.watch('b'),after_claim)

    def test_restart_invalidates_assignment_and_changes_watch_without_losing_members(self):
        request=self.request(); code=self.import_code(); self.claim(code,request)
        before=self.watch('b'); hashes=self.scalar('SELECT group_concat(token_hash) FROM members ORDER BY id')
        restarted=Store(self.path,clock=lambda:timestamp(self.date))
        self.assertEqual(restarted.code_vault.values,{})
        self.assertEqual(self.scalar('SELECT group_concat(token_hash) FROM members ORDER BY id'),hashes)
        self.assertEqual(self.scalar('SELECT state FROM code_requests WHERE id=?',(request['id'],)),'waiting')
        self.assertNotEqual(restarted.watch(self.workspace,'b')['cursor'],before['cursor'])
        self.assertEqual(restarted.codes(self.actors['b'])['codes'],[])


class HTTPInboxTests(Fixture):
    def setUp(self):
        super().setUp()
        self.server=Server(('127.0.0.1',0),self.store,public_watch=True)
        self.thread=threading.Thread(target=self.server.serve_forever,daemon=True);self.thread.start()

    def tearDown(self):
        self.server.shutdown();self.server.server_close();self.thread.join(timeout=5)
        super().tearDown()

    def get(self,path,actor='b'):
        connection=http.client.HTTPConnection(*self.server.server_address,timeout=5)
        try:
            connection.request('GET',path,headers={'Authorization':'Bearer '+self.tokens[actor]})
            response=connection.getresponse(); data=response.read()
            return response.status,dict(response.getheaders()),json.loads(data)
        finally:connection.close()

    def test_secret_and_metadata_responses_no_store_and_queries_rejected(self):
        request=self.request();code=self.import_code();self.claim(code,request)
        status,headers,body=self.get('/v1/codes')
        self.assertEqual(status,200);self.assertEqual(headers['Cache-Control'],'no-store');self.assertNotIn('A7X9K2',json.dumps(body))
        status,headers,body=self.get(f"/v1/codes/{code['id']}/value")
        self.assertEqual(status,200);self.assertEqual(headers['Cache-Control'],'no-store');self.assertEqual(body['code'],'A7X9K2')
        for path in ['/v1/codes?code=A7X9K2',f"/v1/codes/{code['id']}/value?taskId=TASK-000001"]:
            status,headers,body=self.get(path)
            self.assertEqual(status,422);self.assertEqual(headers['Cache-Control'],'no-store');self.assertNotIn('A7X9K2',json.dumps(body))
        status,headers,body=self.get(f"/v1/codes/{code['id']}/value",'c')
        self.assertEqual(status,404);self.assertEqual(headers['Cache-Control'],'no-store')

    def test_post_import_response_no_store_and_push_wake_after_commit(self):
        connection=http.client.HTTPConnection(*self.server.server_address,timeout=5)
        try:
            connection.request('POST','/v1/codes',body=json.dumps({'code':'A7X9K2',**self.namespace()}),headers={'Authorization':'Bearer '+self.tokens['user'],'Content-Type':'application/json','Idempotency-Key':'fixture-http-import'})
            response=connection.getresponse();body=response.read()
            self.assertEqual(response.status,201);self.assertEqual(response.getheader('Cache-Control'),'no-store');self.assertNotIn(b'A7X9K2',body)
            self.assertTrue(self.server.push_wake.is_set())
        finally:connection.close()


if __name__=='__main__': unittest.main()
