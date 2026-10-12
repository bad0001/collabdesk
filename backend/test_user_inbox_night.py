"""Regression fixtures for approval boundaries and stale worker help; no live data."""
import unittest
from test_user_inbox import Fixture

class InboxBoundaryTests(Fixture):
    def authorization(self,task):
        return self.write('b','/v1/authorizations',{'taskId':task['id'],'kind':'normal','reviewer':'leader','subject':'Fixture approval','reason':'Fixture needs approval'})['authorization']
    def decide(self,auth,action):
        return self.write('leader',f"/v1/authorizations/{auth['id']}/decision",{'version':auth['version'],'action':action,'note':'Fixture decision'})['authorization']
    def test_pending_or_denied_blocks_claim_and_assignment_until_approved(self):
        task=self.task();auth=self.authorization(task);request=self.request(task=task);code=self.import_code()
        for actor,operation in [('b','claim'),('leader','assign'),('user','assign')]:
            self.fail(409,actor,f"/v1/codes/{code['id']}/{operation}",{'version':code['version'],'requestId':request['id']})
        auth=self.decide(auth,'denied')
        self.fail(409,'b',f"/v1/codes/{code['id']}/claim",{'version':code['version'],'requestId':request['id']})
        # A denied application is not silently reopened: a fresh decision request.
        auth=self.authorization(task);self.decide(auth,'approved')
        allocated=self.claim(code,request)['code']
        self.assertEqual(self.store.code_value(self.actors['b'],allocated['id'])['code'],'A7X9K2')
    def test_new_pending_approval_blocks_value_but_consumption_still_destroys(self):
        task=self.task();request=self.request(task=task);code=self.import_code();allocated=self.claim(code,request)['code']
        self.authorization(task)
        with self.assertRaises(Exception) as caught:self.store.code_value(self.actors['b'],allocated['id'])
        self.assertEqual(caught.exception.status,409)
        self.write('b',f"/v1/codes/{allocated['id']}/consume",{'version':allocated['version']})
        self.assertEqual(self.scalar('SELECT state FROM codes_metadata WHERE id=?',(allocated['id'],)),'consumed')
        self.assertNotIn(allocated['id'],self.store.code_vault.values)
    def test_handoff_cancels_task_help_and_pending_push_but_general_question_survives(self):
        self.write('user','/v1/push/devices',{'installationId':'fixture-installation-user','token':'a'*64,'environment':'sandbox'})
        task=self.task();request=self.help(task=task,kind='material');general=self.help()
        self.write('leader',f"/v1/tasks/{task['id']}/updates",{'version':task['version'],'kind':'handoff','ownerId':'c','body':'Fixture handoff'})
        self.assertEqual(self.scalar('SELECT state FROM help_requests WHERE id=?',(request['id'],)),'cancelled')
        self.assertEqual(self.scalar('SELECT state FROM push_outbox WHERE event_key=?',(f"help:{request['id']}",)),'cancelled')
        self.fail(409,'user',f"/v1/user-requests/{request['id']}/reply",{'version':2,'body':'Late answer'})
        self.assertEqual(self.scalar('SELECT state FROM help_requests WHERE id=?',(general['id'],)),'open')
        self.assertEqual(self.scalar("SELECT count(*) FROM help_events WHERE request_id=? AND kind='task_changed'",(request['id'],)),1)
    def test_submission_cancels_task_bound_help(self):
        task=self.task();request=self.help(task=task)
        self.write('b',f"/v1/tasks/{task['id']}/updates",{'version':task['version'],'kind':'submitted','body':'Fixture result'})
        self.assertEqual(self.scalar('SELECT state FROM help_requests WHERE id=?',(request['id'],)),'cancelled')
        self.fail(409,'user',f"/v1/user-requests/{request['id']}/reply",{'version':2,'body':'Late answer'})
    def test_generic_code_help_requires_specialized_task_request(self):
        self.fail(422,'b','/v1/user-requests',{'kind':'code','subject':'Code please','body':'No task or namespace'})
        self.assertEqual(self.scalar('SELECT count(*) FROM help_requests'),0)
        code_request=self.request()
        self.assertEqual(self.scalar('SELECT kind FROM help_requests WHERE id=?',(code_request['userRequestId'],)),'code')

if __name__=='__main__':unittest.main()
