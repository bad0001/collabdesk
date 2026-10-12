"""Private SQLite fixtures and simulated APNs only; never contact Apple or production."""
from datetime import datetime, timedelta, timezone
import json
import os
from pathlib import Path
import tempfile
import threading
import unittest
from unittest import mock
import uuid

import notifications
from common import APIError, timestamp
from server import Store


class MessagePushTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.date=datetime(2026,10,8,tzinfo=timezone.utc)
        self.store=Store(Path(self.temp.name)/'fixture.sqlite3',clock=lambda:timestamp(self.date))
        self.actors={}
        for name,role in [('user','admin'),('other','admin'),('leader','leader'),('b','worker'),('c','worker')]:
            token=self.store.add_member(name,'Fixture '+name,role)
            self.actors[name]=self.store.authenticate('Bearer '+token)

    def tearDown(self): self.temp.cleanup()

    def write(self,actor,path,payload,key=None):
        return self.store.mutate(self.actors[actor],path,payload,key or uuid.uuid4().hex)[1]

    def register(self,actor='user',installation='fixture-installation-user',token='a'*64,enabled=True):
        return self.write(actor,'/v1/push/devices',{'installationId':installation,'token':token,'environment':'sandbox','enabled':enabled})

    def message(self,recipient='user',sender='b',body='PRIVATE fixture body',key=None):
        return self.write(sender,'/v1/messages',{'recipientId':recipient,'body':body},key)

    def outbox(self):
        with self.store.connection() as db:
            return [dict(r) for r in db.execute('SELECT * FROM push_outbox ORDER BY id')]

    def drain(self,reply=(200,''),stop_event=None):
        with mock.patch.object(notifications,'configured',return_value=True),mock.patch.object(notifications,'send',return_value=reply) as sender:
            notifications.drain(self.store,stop_event=stop_event)
            return sender

    def test_message_targets_exact_admin_devices_and_has_no_body(self):
        self.register()
        self.register('user','fixture-installation-user-two','b'*64)
        self.register('other','fixture-installation-other','c'*64)
        message=self.message()
        rows=self.outbox()
        self.assertEqual(len(rows),2)
        self.assertEqual({r['member_id'] for r in rows},{'user'})
        for row in rows:
            payload=json.loads(row['payload'])
            self.assertEqual(payload['route'],f"collabdesk://message/{message['id']}")
            self.assertEqual(payload['kind'],'message_user')
            self.assertNotIn('PRIVATE',row['payload'])
            self.assertNotIn('Fixture b',row['payload'])
            self.assertNotIn('body',payload)

    def test_user_reply_and_worker_to_leader_do_not_push_to_user(self):
        self.register()
        self.message(recipient='b',sender='user')
        self.message(recipient='leader')
        self.assertEqual(self.outbox(),[])

    def test_message_idempotency_keeps_single_message_and_delivery(self):
        self.register()
        first=self.message(key='fixture-message-0001')
        self.assertEqual(self.message(key='fixture-message-0001'),first)
        self.assertEqual(len(self.outbox()),1)
        self.assertEqual(len(self.store.snapshot(self.actors['b'])['messages']),1)

    def test_message_and_outbox_are_one_transaction(self):
        self.register()
        with mock.patch.object(notifications,'enqueue',side_effect=RuntimeError('fixture rollback')):
            with self.assertRaises(RuntimeError): self.message(key='fixture-atomic-message')
        self.assertEqual(self.outbox(),[])
        self.assertEqual(self.store.snapshot(self.actors['b'])['messages'],[])
        self.message(key='fixture-atomic-message')
        self.assertEqual(len(self.outbox()),1)

    def test_worker_cross_worker_forbidden_and_messages_stay_private(self):
        self.register()
        message=self.message()
        with self.assertRaises(APIError) as error: self.message(recipient='c')
        self.assertEqual(error.exception.status,403)
        self.assertEqual(self.store.snapshot(self.actors['c'])['messages'],[])
        with self.assertRaises(APIError) as error: self.write('other',f"/v1/messages/{message['id']}/read",{})
        self.assertEqual(error.exception.status,404)
        self.assertEqual(self.outbox()[0]['state'],'pending')

    def test_read_cancels_pending_even_without_apns_configuration(self):
        self.register()
        message=self.message()
        self.write('user',f"/v1/messages/{message['id']}/read",{})
        self.assertEqual(self.outbox()[0]['state'],'cancelled')
        self.assertEqual(self.drain().call_count,0)

    def test_drain_rechecks_read_and_recipient_not_only_event_id(self):
        self.register()
        message=self.message()
        with self.store.connection() as db:
            db.execute('UPDATE messages SET read_at=? WHERE id=?',(self.store.now(),message['id']))
        self.assertEqual(self.drain().call_count,0)
        self.assertEqual(self.outbox()[0]['state'],'cancelled')
        second=self.message()
        with self.store.connection() as db:
            db.execute("UPDATE messages SET recipient_id='other' WHERE id=?",(second['id'],))
        self.assertEqual(self.drain().call_count,0)
        self.assertEqual(self.outbox()[1]['state'],'cancelled')

    def test_first_registration_catches_only_latest_own_unread_message(self):
        self.message()
        latest=self.message()
        self.message(recipient='other')
        self.register()
        self.assertEqual(len(self.outbox()),1)
        self.assertEqual(self.outbox()[0]['event_key'],f"message:{latest['id']}")
        self.assertEqual(len(self.store.snapshot(self.actors['user'])['messages']),3)
        self.register()
        self.assertEqual(len(self.outbox()),1)

    def test_new_registration_catchup_does_not_reenqueue_other_installation(self):
        self.register()
        message=self.message()
        self.assertEqual(self.drain().call_count,1)
        self.register('user','fixture-installation-user-two','b'*64)
        rows=self.outbox()
        self.assertEqual(len(rows),2)
        self.assertEqual(rows[0]['state'],'accepted')
        self.assertEqual(rows[1]['state'],'pending')
        self.assertEqual(rows[1]['event_key'],f"message:{message['id']}")

    def test_read_history_not_caught_up(self):
        message=self.message()
        self.write('user',f"/v1/messages/{message['id']}/read",{})
        self.register()
        self.assertEqual(self.outbox(),[])

    def test_device_disable_cancels_and_reenable_rearms_latest(self):
        self.register()
        self.message()
        self.register(enabled=False)
        self.assertEqual(self.outbox()[0]['state'],'cancelled')
        self.assertEqual(self.drain().call_count,0)
        self.register()
        self.assertEqual(len(self.outbox()),1)
        self.assertEqual(self.outbox()[0]['state'],'pending')

    def test_device_owner_change_cancels_previous_recipient_delivery(self):
        self.register()
        self.message()
        self.register('other','fixture-installation-user','a'*64)
        self.assertEqual(self.outbox()[0]['state'],'cancelled')
        self.assertEqual(self.drain().call_count,0)

    def test_device_disabled_outside_endpoint_is_rechecked(self):
        self.register()
        self.message()
        with self.store.connection() as db: db.execute('UPDATE push_devices SET enabled=0')
        self.assertEqual(self.drain().call_count,0)
        self.assertEqual(self.outbox()[0]['state'],'cancelled')

    def test_transient_failure_retries_after_backoff_then_accepts(self):
        self.register(); self.message()
        self.assertEqual(self.drain((503,'ServiceUnavailable')).call_count,1)
        row=self.outbox()[0]
        self.assertEqual((row['state'],row['attempts'],row['last_error']),('pending',1,'503:ServiceUnavailable'))
        self.assertEqual(self.drain().call_count,0)
        self.date+=timedelta(seconds=60)
        self.assertEqual(self.drain().call_count,1)
        self.assertEqual((self.outbox()[0]['state'],self.outbox()[0]['attempts']),('accepted',2))

    def test_transient_failure_attempts_are_bounded(self):
        self.register(); self.message()
        for _ in range(10):
            self.drain((0,'TransportError'))
            self.date+=timedelta(hours=2)
        self.assertEqual((self.outbox()[0]['state'],self.outbox()[0]['attempts']),('failed',10))
        self.assertEqual(self.drain().call_count,0)

    def test_bad_device_token_disables_device(self):
        self.register(); self.message()
        self.drain((410,'Unregistered'))
        self.assertEqual(self.outbox()[0]['state'],'failed')
        with self.store.connection() as db: self.assertEqual(db.execute('SELECT enabled FROM push_devices').fetchone()[0],0)

    def test_stop_event_stops_before_next_notification(self):
        self.register(); self.message(); self.message()
        stop=threading.Event()
        def send(*args): stop.set(); return 200,''
        with mock.patch.object(notifications,'configured',return_value=True),mock.patch.object(notifications,'send',side_effect=send) as sender:
            notifications.drain(self.store,stop_event=stop)
            self.assertEqual(sender.call_count,1)
        self.assertEqual([r['state'] for r in self.outbox()],['accepted','pending'])

    def test_stopped_batch_sends_nothing(self):
        self.register(); self.message()
        stop=threading.Event(); stop.set()
        self.assertEqual(self.drain(stop_event=stop).call_count,0)
        self.assertEqual(self.outbox()[0]['attempts'],0)

    def test_unconfigured_drain_keeps_pending_without_transport(self):
        self.register(); self.message()
        with mock.patch.object(notifications,'configured',return_value=False),mock.patch.object(notifications,'send') as sender:
            notifications.drain(self.store)
            self.assertEqual(sender.call_count,0)
        self.assertEqual((self.outbox()[0]['state'],self.outbox()[0]['attempts']),('pending',0))

    def test_worker_cannot_register_phone_and_status_is_admin_only(self):
        with self.assertRaises(APIError) as error: self.register('b')
        self.assertEqual(error.exception.status,403)
        with self.store.connection() as db:
            self.assertIsNone(notifications.status(db,self.actors['b']))
            self.assertIsNone(notifications.status(db,self.actors['leader']))

    def test_authorization_and_user_review_push_remain_compatible(self):
        self.register()
        task=self.write('leader','/v1/tasks',{'title':'Fixture authorization','ownerId':'b','source':'leader'})['task']
        self.write('b','/v1/authorizations',{'taskId':task['id'],'kind':'card','subject':'Fixture approval','reason':'Fixture reason','accountLabel':'Fixture account'})
        review=self.write('leader','/v1/tasks',{'title':'Fixture review','ownerId':'b','source':'leader','requiresReview':True})['task']
        review=self.write('b',f"/v1/tasks/{review['id']}/updates",{'version':review['version'],'kind':'submitted','body':'Fixture result'})['task']
        self.write('leader',f"/v1/tasks/{review['id']}/updates",{'version':review['version'],'kind':'forward_user','body':'Fixture final review'})
        self.assertEqual({json.loads(r['payload'])['kind'] for r in self.outbox()},{'authorization_card','review_user'})
        self.assertEqual(self.drain().call_count,2)
        self.assertTrue(all(r['state']=='accepted' for r in self.outbox()))

    def test_normal_user_authorization_catchup_remains_compatible(self):
        task=self.write('leader','/v1/tasks',{'title':'Fixture authorization','ownerId':'b','source':'leader'})['task']
        self.write('b','/v1/authorizations',{'taskId':task['id'],'kind':'normal','reviewer':'user','subject':'Fixture approval','reason':'Fixture reason'})
        latest=self.message()
        self.register()
        rows=self.outbox()
        self.assertEqual({json.loads(r['payload'])['kind'] for r in rows},{'authorization_user','message_user'})
        self.assertEqual(len(rows),2)
        self.assertIn(f"message:{latest['id']}",{r['event_key'] for r in rows})
        self.assertEqual(self.drain().call_count,2)


class PushConfigurationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.key=Path(self.temp.name)/'fixture-private-key.p8'
        self.key.write_bytes(b'FAKE fixture key, never used for signing')
        self.key.chmod(0o600)
        self.env={'COLLAB_APNS_KEY_FILE':str(self.key),'COLLAB_APNS_KEY_ID':'ABCDEFGHIJ','COLLAB_APNS_TEAM_ID':'1234567890'}
        self.patch=mock.patch.dict(os.environ,self.env,clear=True); self.patch.start()

    def tearDown(self): self.patch.stop(); self.temp.cleanup()

    def test_ready_is_only_local_readiness_not_delivery(self):
        self.assertTrue(notifications.configured())
        self.assertIsNone(notifications.config_problem())

    def test_missing_or_partial_fields(self):
        for key in self.env:
            with mock.patch.dict(os.environ,{key:''}):
                self.assertFalse(notifications.configured())
                self.assertIn('待提供',notifications.config_problem())

    def test_invalid_identifier(self):
        with mock.patch.dict(os.environ,{'COLLAB_APNS_KEY_ID':' invalid '}):
            self.assertIn('格式',notifications.config_problem())

    def test_missing_file(self):
        self.key.unlink()
        self.assertFalse(notifications.configured())
        self.assertNotIn(str(self.key),notifications.config_problem())

    def test_wrong_file_permissions(self):
        self.key.chmod(0o644)
        self.assertIn('0600',notifications.config_problem())
        self.assertFalse(notifications.configured())

    def test_empty_file(self):
        self.key.write_bytes(b'')
        self.assertIn('为空',notifications.config_problem())

    def test_unreadable_file(self):
        with mock.patch.object(Path,'open',side_effect=PermissionError('fixture')):
            self.assertIn('读取',notifications.config_problem())

    def test_status_explains_config_and_preserves_count_fields(self):
        store=Store(Path(self.temp.name)/'fixture.sqlite3')
        actor=store.authenticate('Bearer '+store.add_member('user','Fixture user','admin'))
        with mock.patch.dict(os.environ,{'COLLAB_APNS_KEY_FILE':''}),store.connection() as db:
            value=notifications.status(db,actor)
            self.assertFalse(value['configured'])
            self.assertIn('待提供',value['configProblem'])
            self.assertEqual({key:value[key] for key in ('registeredDevices','queued','acceptedByAPNs','failed')},dict.fromkeys(('registeredDevices','queued','acceptedByAPNs','failed'),0))
            self.assertIn('不等于',value['deliveryNote'])


if __name__=='__main__': unittest.main()
