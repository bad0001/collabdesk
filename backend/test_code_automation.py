"""Synthetic localhost OTP fixtures; no real SMS, external network, APNs or keys."""
from datetime import timedelta
import hashlib
import http.client
import json
import sqlite3
import threading
import unittest
from unittest import mock
import uuid

import code_automation
import sync
from common import APIError, timestamp
from server import Store, Server
from test_user_inbox import Fixture


class AutomaticFixture(Fixture):
    def setUp(self):
        super().setUp()
        self.cap=self.enable()

    def enable(self,installation='fixture-device-001',actor='user'):
        return self.write(actor,'/v1/codes/automation/enable',{'installationId':installation})['credential']

    def payload(self,**kwargs):
        return {'codes':['731924'],'source':'Fixture Service','purpose':'login',
                'receivedAt':timestamp(self.date),'timeSource':'received','expiresIn':300,**kwargs}

    def ingest(self,cap=None,**kwargs):
        return self.store.ingest_codes('CodeIngest '+(cap or self.cap),self.payload(**kwargs))

    def ingest_fail(self,code,data=None,header=None):
        with self.assertRaises(APIError) as error:
            self.store.ingest_codes(header or 'CodeIngest '+self.cap,data or self.payload())
        self.assertEqual(error.exception.status,code)

    def auto_request(self,actor='b',service='Fixture Service',purpose='登录',account='Fixture account'):
        return self.request(actor=actor,namespace={'service':service,'accountLabel':account,'purpose':purpose})

    def cap_status(self,actor='user'):
        with self.store.connection() as db:return code_automation.status(db,self.actors[actor])


class CapabilityTests(AutomaticFixture):
    def test_cap_only_hash_persisted_and_once_return(self):
        self.assertRegex(self.cap,r'^[A-Za-z0-9_-]{43}$')
        with self.store.connection() as db:
            content='\n'.join(db.iterdump())
        self.assertNotIn(self.cap,content)
        self.assertIn(hashlib.sha256(self.cap.encode()).hexdigest(),content)
        self.assertNotIn('tokenHash',json.dumps(self.cap_status()))
        self.assertNotIn(self.cap,json.dumps(self.store.snapshot(self.actors['user'])))
        result=self.write('user','/v1/codes/automation/enable',{'installationId':'fixture-device-001'},key='fixture-enable-once')
        self.fail(409,'user','/v1/codes/automation/enable',{'installationId':'fixture-device-001'},key='fixture-enable-once')
        self.assertNotIn(result['credential'],self.path.read_bytes().decode(errors='ignore'))

    def test_cap_cannot_authenticate_member_api_and_bearer_cannot_ingest(self):
        for header in ['Bearer '+self.cap,'CodeIngest '+self.cap,'',self.cap]:
            with self.assertRaises(APIError) as error:self.store.authenticate(header)
            self.assertEqual(error.exception.status,401)
        for header in ['Bearer '+self.tokens['user'],'CodeIngest '+self.tokens['user'],'CodeIngest wrong','Bearer '+self.cap]:
            self.ingest_fail(401,header=header)

    def test_only_admin_can_enable_disable_status(self):
        for actor in ('leader','b','c'):
            for action in ('enable','disable'):
                self.fail(403,actor,'/v1/codes/automation/'+action,{'installationId':'fixture-device-001'})
            with self.assertRaises(APIError) as error:self.cap_status(actor)
            self.assertEqual(error.exception.status,403)
        self.assertEqual(self.cap_status('zzuser'),{'installations':[]})

    def test_rotate_revoke_and_installation_isolation_preserve_bearers(self):
        other=self.enable('fixture-device-002')
        hashes=self.scalar('SELECT group_concat(token_hash) FROM members ORDER BY id')
        rotated=self.enable()
        self.ingest_fail(401)
        self.cap=rotated
        self.write('user','/v1/codes/automation/disable',{'installationId':'fixture-device-001'})
        self.ingest_fail(401)
        self.assertEqual(self.ingest(cap=other)[0],201)
        self.assertEqual(self.scalar('SELECT group_concat(token_hash) FROM members ORDER BY id'),hashes)
        self.assertFalse(self.cap_status()['installations'][0]['enabled'])

    def test_installation_validation_and_admin_prefix_do_not_leak(self):
        for id in ['short','a:b'*10,'中文安装','a'*129]:
            self.fail(422,'user','/v1/codes/automation/enable',{'installationId':id})
        self.fail(422,'user','/v1/codes/automation/enable',{'installationId':'fixture-device-001','scope':'all'})
        self.fail(404,'zzuser','/v1/codes/automation/disable',{'installationId':'fixture-device-001'})
        self.tokens['user_extra']=self.store.add_member('user_extra','Fixture other admin','admin')
        self.actors['user_extra']=self.store.authenticate('Bearer '+self.tokens['user_extra'])
        self.enable(actor='user_extra')
        self.assertEqual(len(self.cap_status()['installations']),1)

    def test_owner_token_rotation_or_role_change_invalidates_capability(self):
        with self.store.connection() as db:
            db.execute("UPDATE members SET token_hash=? WHERE id='user'",(hashlib.sha256(b'fixture-rotated-token').hexdigest(),))
        self.ingest_fail(401)
        self.tokens['user']='fixture-rotated-token'
        self.actors['user']=self.store.authenticate('Bearer '+self.tokens['user'])
        self.cap=self.enable()
        self.assertEqual(self.ingest()[0],201)
        with self.store.connection() as db:db.execute("UPDATE members SET role='worker' WHERE id='user'")
        self.ingest_fail(401)

    def test_workspace_change_invalidates_capability_without_member_api_change(self):
        with self.store.connection() as db:db.execute("UPDATE sync_meta SET value='fixture-other-workspace' WHERE key='workspace_id'")
        self.ingest_fail(401)
        self.assertEqual(self.store.authenticate('Bearer '+self.tokens['user'])['id'],'user')
        self.assertNotIn('ownerTokenHash',json.dumps(self.cap_status()))
        self.assertNotIn('workspaceId',json.dumps(self.cap_status()))

    def test_cap_state_survives_restart_but_codes_do_not(self):
        _,result=self.ingest(); code=result['codes'][0]
        self.date+=timedelta(seconds=1)
        restarted=Store(self.path,clock=lambda:timestamp(self.date))
        self.assertEqual(restarted.code_vault.values,{})
        self.assertEqual(self.scalar('PRAGMA user_version'),6)
        with self.assertRaises(APIError) as error:
            restarted.ingest_codes('CodeIngest '+self.cap,self.payload(receivedAt=code['receivedAt']))
        self.assertEqual(error.exception.status,410)
        # captured is explicitly not SMS received proof: a fresh captured time
        # is accepted after restart, and docs must not claim global anti-replay.
        status,result=restarted.ingest_codes('CodeIngest '+self.cap,self.payload(timeSource='captured',codes=['846193']))
        self.assertEqual(status,201);self.assertEqual(result['codes'][0]['timeSource'],'captured')


class AutomaticVaultTests(AutomaticFixture):
    def test_extraction_imports_metadata_without_manual_account(self):
        status,result=self.ingest()
        self.assertEqual(status,201);self.assertEqual(result['imported'],1)
        code=result['codes'][0]
        self.assertEqual(code['service'],'Fixture Service')
        self.assertEqual(code['accountLabel'],'未知账号')
        self.assertEqual(code['purpose'],'登录')
        self.assertTrue(code['sourceKnown']);self.assertTrue(code['purposeKnown'])
        self.assertEqual(code['importMethod'],'automatic');self.assertEqual(code['timeSource'],'received')
        self.assertNotIn('731924',json.dumps(result))
        self.assertEqual(self.store.code_value(self.actors['user'],code['id'])['code'],'731924')

    def test_source_body_phone_control_and_unknown_fields_rejected(self):
        for source in ['短信验证码731924','13800000000','https://site.example','Brand\n','Brand\tName','@account','品牌'*25,'Brand731924','Brand1234','12306']:
            self.ingest_fail(422,self.payload(source=source))
        for extra in [{'rawSMS':'body'},{'sender':'13800000000'},{'accountLabel':'my account'},{'ownerId':'b'}]:
            self.ingest_fail(422,self.payload(**extra))
        for codes in [[],['123'],['731924']*7,[731924],['AB1234'],['123456789'],True]:
            self.ingest_fail(422,self.payload(codes=codes))
        for ttl in [0,901,'300',True]:self.ingest_fail(422,self.payload(expiresIn=ttl))
        for changes in [{'purpose':'payment'},{'timeSource':'guessed'},{'receivedAt':'no time'},{'receivedAt':'2026-10-10T00:00:00'}]:
            self.ingest_fail(422,self.payload(**changes))
        self.assertEqual(self.scalar('SELECT count(*) FROM codes_metadata'),0)

    def test_multiple_candidates_batch_kept_and_known_namespace_latest(self):
        _,result=self.ingest(codes=['731924','846193','731924'])
        self.assertEqual(result['imported'],2)
        ids=[c['id'] for c in result['codes']]
        self.assertEqual(len(self.store.code_vault.values),2)
        self.date+=timedelta(seconds=3)
        _,next_batch=self.ingest(codes=['592816','263851'])
        self.assertEqual(next_batch['imported'],2)
        for id in ids:
            self.assertNotIn(id,self.store.code_vault.values)
            self.assertEqual(self.scalar('SELECT state FROM codes_metadata WHERE id=?',(id,)),'replaced')
        self.assertEqual(len(self.store.code_vault.values),2)
        self.ingest_fail(409,self.payload(codes=['958271'],receivedAt=timestamp(self.date-timedelta(seconds=1))))

    def test_unknown_source_batches_not_overwritten_and_manual_compatible(self):
        _,first=self.ingest(source='',purpose='unknown')
        self.date+=timedelta(seconds=1)
        _,second=self.ingest(source='',purpose='unknown',codes=['846193'])
        self.assertIn(first['codes'][0]['id'],self.store.code_vault.values)
        self.assertIn(second['codes'][0]['id'],self.store.code_vault.values)
        manual=self.import_code()
        self.assertIn(manual['id'],self.store.code_vault.values)
        self.assertNotIn('importMethod',manual)

    def test_duplicate_does_not_extend_expiry_or_wake_and_consumed_replay_stays_dead(self):
        request=self.auto_request(); _,result=self.ingest();code=result['codes'][0]
        before=self.watch('b')
        self.date+=timedelta(seconds=25)
        status,duplicate=self.ingest(expiresIn=900)
        self.assertEqual((status,duplicate['imported']),(200,0))
        self.assertEqual(self.watch('b'),before)
        self.assertEqual(self.scalar('SELECT expires_at FROM codes_metadata WHERE id=?',(code['id'],)),code['expiresAt'])
        assigned=self.claim(code,request)['code']
        self.write('b',f"/v1/codes/{code['id']}/consume",{'version':assigned['version']})
        self.date+=timedelta(seconds=1)
        self.assertEqual(self.ingest()[1]['imported'],0)
        self.assertNotIn(code['id'],self.store.code_vault.values)
        self.assertEqual(self.scalar('SELECT count(*) FROM codes_metadata'),1)

    def test_known_fields_must_match_but_unknown_account_matches_own_request(self):
        request=self.auto_request()
        self.auto_request('c',service='Other Service')
        _,result=self.ingest();code=result['codes'][0]
        self.assertEqual(len(self.store.codes(self.actors['b'])['codes']),1)
        self.assertEqual(self.store.codes(self.actors['c'])['codes'],[])
        self.claim(code,request)
        self.assertEqual(self.store.code_value(self.actors['b'],code['id'])['code'],'731924')
        with self.assertRaises(APIError) as error:self.store.code_value(self.actors['leader'],code['id'])
        self.assertEqual(error.exception.status,403)
        with self.assertRaises(APIError) as error:self.store.code_value(self.actors['c'],code['id'])
        self.assertEqual(error.exception.status,404)

    def test_no_request_no_inventory_or_value_and_unknown_contenders_need_leader(self):
        _,result=self.ingest(source='',purpose='unknown');code=result['codes'][0]
        self.assertEqual(self.store.codes(self.actors['b'])['codes'],[])
        with self.assertRaises(APIError) as error:self.store.code_value(self.actors['b'],code['id'])
        self.assertEqual(error.exception.status,403)
        b=self.auto_request();c=self.auto_request('c',service='Other Service',purpose='注册')
        self.assertEqual(len(self.store.codes(self.actors['b'])['codes']),1)
        for actor,request in [('b',b),('c',c)]:
            self.fail(409,actor,f"/v1/codes/{code['id']}/claim",{'requestId':request['id'],'version':code['version']})
        assigned=self.claim(code,b,'leader',assign=True)['code']
        self.assertEqual(assigned['assignedMemberId'],'b')
        self.assertEqual(self.store.code_value(self.actors['b'],code['id'])['code'],'731924')
        self.assertEqual(self.store.codes(self.actors['c'])['codes'],[])

    def test_formal_authorization_and_handoff_still_gate_values(self):
        task=self.task();request=self.request(task=task,namespace={'service':'Fixture Service','accountLabel':'Fixture account','purpose':'登录'})
        auth=self.write('b','/v1/authorizations',{'taskId':task['id'],'kind':'card','subject':'needs human','reason':'fixture','accountLabel':'fixture'})
        _,result=self.ingest();code=result['codes'][0]
        self.fail(409,'b',f"/v1/codes/{code['id']}/claim",{'requestId':request['id'],'version':1})
        self.fail(409,'leader',f"/v1/codes/{code['id']}/assign",{'requestId':request['id'],'version':1})
        task=self.store.snapshot(self.actors['leader'])['tasks'][0]
        self.write('leader',f"/v1/tasks/{task['id']}/updates",{'version':task['version'],'kind':'handoff','ownerId':'c','body':'fixture'})
        self.assertEqual(self.scalar('SELECT state FROM code_requests WHERE id=?',(request['id'],)),'cancelled')

    def test_known_source_or_purpose_mismatch_never_assigns(self):
        b=self.auto_request(service='Other Service');c=self.auto_request('c',purpose='注册')
        _,result=self.ingest();code=result['codes'][0]
        for actor,request in [('b',b),('c',c)]:
            self.assertEqual(self.store.codes(self.actors[actor])['codes'],[])
            self.fail(409,actor,f"/v1/codes/{code['id']}/claim",{'requestId':request['id'],'version':1})
            self.fail(409,'leader',f"/v1/codes/{code['id']}/assign",{'requestId':request['id'],'version':1})

    def test_unknown_purpose_relaxes_only_purpose_not_source(self):
        b=self.auto_request(purpose='注册');self.auto_request('c',service='Other Service')
        _,result=self.ingest(purpose='unknown');code=result['codes'][0]
        self.assertFalse(code['purposeKnown']);self.assertTrue(code['sourceKnown'])
        self.assertEqual(self.store.codes(self.actors['c'])['codes'],[])
        assigned=self.claim(code,b)['code']
        self.assertEqual(assigned['assignedRequestId'],b['id'])

    def test_declined_card_still_blocks_and_new_pending_blocks_reveal(self):
        request=self.auto_request();_,result=self.ingest();code=result['codes'][0]
        assigned=self.claim(code,request)['code']
        auth=self.write('b','/v1/authorizations',{'taskId':request['taskId'],'kind':'card','subject':'human action','reason':'fixture','accountLabel':'fixture'})['authorization']
        with self.assertRaises(APIError) as error:self.store.code_value(self.actors['b'],code['id'])
        self.assertEqual(error.exception.status,409)
        # Cleanup remains possible without exposing the value or bypassing card.
        result=self.write('b',f"/v1/codes/{code['id']}/consume",{'version':assigned['version']})
        self.assertEqual(result['code']['state'],'consumed')
        self.assertEqual(self.scalar('SELECT state FROM authorization_requests WHERE id=?',(auth['id'],)),'awaiting_user')

    def test_atomic_ingest_restores_ram_fingerprints_and_db_on_failure(self):
        with mock.patch.object(sync,'rotate_signal',side_effect=RuntimeError('synthetic commit failure')):
            with self.assertRaises(RuntimeError):self.ingest()
        self.assertEqual(self.store.code_vault.values,{})
        self.assertEqual(self.store.code_vault.auto_seen,{})
        self.assertEqual(self.scalar('SELECT count(*) FROM codes_metadata'),0)
        self.assertEqual(self.ingest()[1]['imported'],1)

    def test_concurrent_duplicate_import_and_claim_have_one_winner(self):
        results=[];barrier=threading.Barrier(3)
        def ingest():
            barrier.wait();results.append(self.ingest()[1]['imported'])
        workers=[threading.Thread(target=ingest) for _ in range(2)]
        for t in workers:t.start()
        barrier.wait()
        for t in workers:t.join(timeout=10)
        self.assertEqual(sorted(results),[0,1])
        code=self.store.codes(self.actors['user'])['codes'][0];request=self.auto_request()
        results=[];barrier=threading.Barrier(3)
        def claim():
            barrier.wait()
            try:self.claim(code,request);results.append('ok')
            except APIError as error:results.append(error.status)
        workers=[threading.Thread(target=claim) for _ in range(2)]
        for t in workers:t.start()
        barrier.wait()
        for t in workers:t.join(timeout=10)
        self.assertCountEqual(results,['ok',409])

    def test_ttl_and_task_bound_watch_changes_no_other_wake(self):
        self.auto_request();self.auto_request('c',service='Other Service')
        before_b=self.watch('b');before_c=self.watch('c')
        _,result=self.ingest(expiresIn=1);code=result['codes'][0]
        self.assertNotEqual(self.watch('b')['cursor'],before_b['cursor'])
        self.assertEqual(self.watch('c'),before_c)
        self.date+=timedelta(seconds=2);self.store.scan()
        self.assertNotIn(code['id'],self.store.code_vault.values)
        self.assertEqual(self.scalar('SELECT state FROM codes_metadata WHERE id=?',(code['id'],)),'expired')
        for response in (self.watch('b'),self.watch('c')):
            self.assertNotIn('731924',json.dumps(response));self.assertNotIn('Fixture Service',json.dumps(response))

    def test_no_secret_fingerprint_in_sqlite_backup_sync_push_or_snapshot(self):
        request=self.auto_request();_,result=self.ingest();code=result['codes'][0];self.claim(code,request)
        payload=self.payload();request_hash=hashlib.sha256(json.dumps(payload,sort_keys=True).encode()).hexdigest()
        with self.store.connection() as db:
            dbtext='\n'.join(db.iterdump())
            with sqlite3.connect(str(self.path)+'.backup') as backup:
                db.backup(backup);backuptext='\n'.join(backup.iterdump())
        for text in (dbtext,backuptext):
            self.assertNotIn('731924',text);self.assertNotIn(self.cap,text);self.assertNotIn(request_hash,text)
        for actor in self.actors.values():
            for response in (self.store.snapshot(actor),self.store.incremental(actor),self.store.codes(actor)):
                self.assertNotIn('731924',json.dumps(response));self.assertNotIn(self.cap,json.dumps(response))
        self.assertEqual(self.scalar("SELECT count(*) FROM idempotency WHERE response LIKE '%automatically_imported%'"),0)
        self.assertEqual(self.scalar('PRAGMA user_version'),6)


class AutomaticHTTPTests(AutomaticFixture):
    def setUp(self):
        super().setUp();self.http=Server(('127.0.0.1',0),self.store,public_watch=True)
        self.thread=threading.Thread(target=self.http.serve_forever,daemon=True);self.thread.start()

    def tearDown(self):
        self.http.shutdown();self.http.server_close();self.thread.join(timeout=5);super().tearDown()

    def http_request(self,method,path,auth=None,data=None):
        c=http.client.HTTPConnection(*self.http.server_address,timeout=5)
        try:
            headers={'Content-Type':'application/json','Idempotency-Key':'fixture-'+uuid.uuid4().hex}
            if auth is not None:headers['Authorization']=auth
            body=None if data is None else json.dumps(data)
            c.request(method,path,body=body,headers=headers)
            response=c.getresponse();body=response.read()
            return response.status,dict(response.getheaders()),json.loads(body)
        finally:c.close()

    def test_ingest_authentication_response_no_store_and_credential_scope(self):
        for auth in (None,'Bearer '+self.tokens['user'],'Bearer '+self.cap):
            status,headers,body=self.http_request('POST','/v1/codes/ingest',auth,self.payload())
            self.assertEqual(status,401);self.assertEqual(headers['Cache-Control'],'no-store')
        status,headers,body=self.http_request('POST','/v1/codes/ingest','CodeIngest '+self.cap,self.payload())
        self.assertEqual(status,201);self.assertEqual(headers['Cache-Control'],'no-store')
        self.assertEqual(body['imported'],1);self.assertNotIn('731924',json.dumps(body))
        for method,path,data in [('GET','/v1/snapshot',None),('GET','/v1/codes',None),('GET','/v1/codes/automation/status',None),('POST','/v1/messages',{'body':'fixture','recipientId':'b'})]:
            self.assertEqual(self.http_request(method,path,'CodeIngest '+self.cap,data)[0],401)
        self.assertEqual(self.http_request('GET','/v1/codes/ingest','Bearer '+self.tokens['user'])[0],404)

    def test_status_admin_only_no_store_and_query_rejected(self):
        status,headers,body=self.http_request('GET','/v1/codes/automation/status','Bearer '+self.tokens['user'])
        self.assertEqual(status,200);self.assertEqual(headers['Cache-Control'],'no-store')
        self.assertEqual(body['installations'][0]['scope'],'code-ingest')
        self.assertNotIn(self.cap,json.dumps(body));self.assertNotIn('tokenHash',json.dumps(body))
        for actor in ('leader','b'):
            self.assertEqual(self.http_request('GET','/v1/codes/automation/status','Bearer '+self.tokens[actor])[0],403)
        for path in ('/v1/codes/automation/status?x=1','/v1/codes/ingest?code=synthetic'):
            self.assertEqual(self.http_request('GET' if 'status' in path else 'POST',path,'Bearer '+self.tokens['user'],None if 'status' in path else self.payload())[0],422)

    def test_invalid_payload_and_failure_do_not_echo_secret_or_ask_retry(self):
        _,headers,body=self.http_request('POST','/v1/codes/ingest','CodeIngest '+self.cap,self.payload(rawSMS='synthetic body 731924'))
        self.assertEqual(headers['Cache-Control'],'no-store');self.assertNotIn('731924',json.dumps(body))
        with mock.patch.object(self.store,'ingest_codes',side_effect=RuntimeError('synthetic hidden 731924')):
            status,headers,body=self.http_request('POST','/v1/codes/ingest','CodeIngest '+self.cap,self.payload())
        self.assertEqual(status,500);self.assertEqual(headers['Cache-Control'],'no-store')
        self.assertNotIn('731924',json.dumps(body));self.assertNotIn('重试',json.dumps(body))

    def test_duplicate_authorization_headers_rejected(self):
        c=http.client.HTTPConnection(*self.http.server_address,timeout=5)
        try:
            body=json.dumps(self.payload());c.putrequest('POST','/v1/codes/ingest')
            c.putheader('Authorization','CodeIngest '+self.cap);c.putheader('Authorization','CodeIngest '+self.cap)
            c.putheader('Content-Type','application/json');c.putheader('Content-Length',str(len(body)))
            c.endheaders(body.encode());r=c.getresponse();r.read();self.assertEqual(r.status,401)
        finally:c.close()


if __name__=='__main__':unittest.main()
