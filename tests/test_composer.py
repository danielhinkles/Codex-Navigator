import copy
import json
from pathlib import Path
import queue
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from composer import Composer, ComposerManager
from worker import Worker

class Process:
    def poll(self): return None
class FakeRPC:
    def __init__(self):
        self.process=Process();self.connection=1;self.events=queue.Queue();self.calls=[];self.replies=[];self.fail_start=False
        self.turns=[];self.thread={'id':'task','cwd':'/tmp','createdAt':1,'updatedAt':2}
    def connect(self): self.process=Process();self.connection+=1
    def close(self): self.process=None
    def respond(self, serial, result=None, error=None): self.replies.append((serial,result,error))
    def request(self, method, params):
        self.calls.append((method,params))
        if method=='account/read':return {'account':{'type':'chatgpt'}}
        if method in ('thread/start','thread/resume','thread/read'):return {'thread':self.thread}
        if method=='thread/turns/list':return {'data':self.turns}
        if method=='turn/start':
            if self.fail_start:raise TimeoutError('Lost start response')
            return {'turn':{'id':'turn','status':'inProgress'}}
        if method=='turn/interrupt':return {}
        raise AssertionError(method)

class ComposerTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.rpc=FakeRPC();self.output=[];self.threads=[]
        self.c=Composer(self.root,self.root,lambda v:self.output.append(copy.deepcopy(v)),self.threads.append,rpc=self.rpc)
    def tearDown(self):self.c.close();self.temp.cleanup()
    def settle(self):
        for _ in range(100):
            self.c.tick()
            if not self.c.future:break
            time.sleep(.005)
        self.c.next_publish=0;self.c.tick()
    def send(self):
        self.c.command({'action':'composerOpen','cwd':str(self.root),'project':'server-project'})
        self.c.command({'action':'composerSend','text':'Please inspect this project'})
        self.settle()
    def approval(self, method='item/commandExecution/requestApproval', **params):
        self.c.event({'id':7,'method':method,'params':dict(threadId='task',turnId='turn',command='test command',**params)})
    def test_work_timer_preserves_start_across_updates_and_reconnect(self):
        with patch('composer.time.time', return_value=100):
            self.c.change(status='starting', turnId='')
        with patch('composer.time.time', return_value=120):
            self.c.change(status='running', turnId='first')
            self.c.change(status='approval')
            self.c.change(status='running')
            self.c.change(status='disconnected')
            self.c.change(status='reconnecting')
            self.c.change(status='running', turnId='first')
        self.assertEqual(self.c.state['workStartedAt'], 100)
        self.c.change(status='completed')
        with patch('composer.time.time', return_value=200):
            self.c.change(status='starting', turnId='')
            self.c.change(status='running', turnId='second')
        self.assertEqual(self.c.state['workStartedAt'], 200)

    def test_explicit_send_uses_existing_account_and_creates_one_turn(self):
        self.send()
        self.assertEqual(self.c.state['status'],'running')
        start=next(p for m,p in self.rpc.calls if m=='thread/start')
        self.assertEqual(start,dict(cwd=str(self.root),sandbox='workspace-write',approvalPolicy='on-request',approvalsReviewer='user',projectId='server-project'))
        self.assertNotIn('model',start)
        with self.assertRaises(ValueError):self.c.command({'action':'composerSend','text':'Duplicate'})
        self.assertEqual(sum(m=='turn/start' for m,_ in self.rpc.calls),1)
    def test_image_file_folder_and_link_inputs_are_sent_once(self):
        image=self.root/'image.png';image.write_bytes(b'image fixture')
        document=self.root/'report \"quoted\".pdf';document.write_bytes(b'document fixture')
        attached=[dict(kind='image',path=str(image),name=image.name),dict(kind='file',path=str(document),name=document.name),dict(kind='file',path=str(self.root),name='Folder'),dict(kind='url',path='https://example.com/reference',name='Reference')]
        self.c.command({'action':'composerSend','text':'Review these','attachments':attached});self.settle()
        turns=[p for m,p in self.rpc.calls if m=='turn/start']
        self.assertEqual(len(turns),1)
        inputs=turns[0]['input']
        self.assertEqual(inputs[1],{'type':'localImage','path':str(image)})
        self.assertIn(json.dumps(str(document)),inputs[2]['text'])
        self.assertIn('folder',inputs[3]['text'])
        self.assertIn('https://example.com/reference',inputs[4]['text'])
        self.assertEqual(document.read_bytes(),b'document fixture')
        self.assertEqual(image.read_bytes(),b'image fixture')
        self.assertEqual(len(self.c.state['messages'][-1]['attachments']),4)
        self.c.item({'type':'userMessage','id':'server-user','content':inputs})
        self.assertEqual(len([m for m in self.c.state['messages'] if m['role']=='You']),1)
        self.assertEqual(len(self.c.state['messages'][-1]['attachments']),4)

    def test_attachment_only_submission_and_missing_file_validation(self):
        with self.assertRaises(ValueError):
            self.c.command({'action':'composerSend','text':'Review','attachments':[dict(kind='file',path=str(self.root/'missing.pdf'))]})
        self.assertFalse(any(m=='turn/start' for m,_ in self.rpc.calls))
        image=self.root/'only.png';image.write_bytes(b'image fixture')
        self.c.command({'action':'composerSend','text':'','attachments':[dict(kind='image',path=str(image))]});self.settle()
        turn=next(p for m,p in self.rpc.calls if m=='turn/start')
        self.assertEqual(turn['input'][1],dict(type='localImage',path=str(image)))

    def test_remote_image_uses_image_input(self):
        self.assertEqual(Composer.attachment_inputs([dict(kind='remoteImage',path='https://example.com/photo.png')]),[dict(type='image',url='https://example.com/photo.png')])

    def test_invalid_attachment_payloads_do_not_start_a_turn(self):
        for attachments in ({},[None],[dict(kind='file',path='relative.pdf')],[dict(kind='url',path='javascript:bad')],[dict(kind='unknown',path='/tmp')]):
            with self.assertRaises(ValueError):self.c.command({'action':'composerSend','text':'Review','attachments':attachments})
        self.assertFalse(any(m=='turn/start' for m,_ in self.rpc.calls))

    def test_stream_coalesces_and_completed_item_replaces_deltas(self):
        self.send()
        for text in ['Hello',' world']:
            self.c.event({'method':'item/agentMessage/delta','params':{'threadId':'task','itemId':'answer','delta':text}})
        self.c.event({'method':'item/completed','params':{'threadId':'task','item':{'id':'answer','type':'agentMessage','text':'Hello world'}}})
        self.assertEqual([m['text'] for m in self.c.state['messages'] if m['role']=='Codex'],['Hello world'])
        self.c.event({'method':'turn/completed','params':{'threadId':'task','turn':{'id':'turn','status':'completed'}}})
        self.assertFalse(self.c.state['active'])
    def test_approval_waits_for_explicit_reply_and_rejects_duplicate(self):
        self.send();self.approval()
        self.assertEqual(self.rpc.replies,[])
        self.assertEqual(self.c.state['status'],'approval')
        self.c.command({'action':'composerReply','token':'7','accept':True})
        self.assertEqual(self.rpc.replies,[(7,{'decision':'accept'},None)])
        with self.assertRaises(ValueError):self.c.command({'action':'composerReply','token':'7','accept':True})
    def test_session_and_saved_rule_approvals_require_advertised_choice(self):
        self.send()
        rule={'acceptWithExecpolicyAmendment':{'execpolicy_amendment':['swift','build']}}
        self.approval(availableDecisions=['accept','acceptForSession',rule])
        choices=self.c.state['approvals'][0]['choices']
        self.assertEqual(len(choices),2)
        self.c.command({'action':'composerReply','token':'7','accept':True,'choice':choices[1]['id']})
        self.assertEqual(self.rpc.replies[-1][1],{'decision':rule})
        self.approval(availableDecisions=['accept'])
        with self.assertRaises(ValueError):
            self.c.command({'action':'composerReply','token':'7','accept':True,'choice':json.dumps('acceptForSession')})
        self.assertIn('7',self.c.pending)

    def test_optional_decisions_use_protocol_defaults_and_exact_proposed_rule(self):
        self.send();self.approval(proposedExecpolicyAmendment=['swift','test'])
        choices=self.c.state['approvals'][0]['choices']
        self.assertEqual(len(choices),2)
        self.c.command({'action':'composerReply','token':'7','accept':True,'choice':choices[1]['id']})
        self.assertEqual(self.rpc.replies[-1][1],{'decision':{'acceptWithExecpolicyAmendment':{'execpolicy_amendment':['swift','test']}}})

    def test_permission_session_grant_preserves_requested_permissions(self):
        self.send();self.approval('item/permissions/requestApproval',permissions={'network':{'enabled':True}})
        self.c.command({'action':'composerReply','token':'7','accept':True,'choice':'session'})
        self.assertEqual(self.rpc.replies[-1][1],{'permissions':{'network':{'enabled':True}},'scope':'session'})

    def test_decline_and_input_answers_have_valid_shapes(self):
        self.send();self.approval();self.c.command({'action':'composerReply','token':'7','accept':False})
        self.assertEqual(self.rpc.replies[-1][1],{'decision':'decline'})
        self.approval('item/tool/requestUserInput',questions=[{'id':'q','question':'Which?'}])
        with self.assertRaises(ValueError):self.c.command({'action':'composerReply','token':'7','answers':{}})
        self.c.command({'action':'composerReply','token':'7','answers':{'q':'first'}})
        self.assertEqual(self.rpc.replies[-1][1],{'answers':{'q':{'answers':['first']}}})
    def test_permission_grant_is_exactly_request_scoped_to_turn(self):
        self.send();self.approval('item/permissions/requestApproval',permissions={'network':{'enabled':True}})
        self.c.command({'action':'composerReply','token':'7','accept':True})
        self.assertEqual(self.rpc.replies[-1][1],{'permissions':{'network':{'enabled':True}},'scope':'turn'})
    def test_stop_denies_pending_and_interrupts_current_turn(self):
        self.send();self.approval();self.c.command({'action':'composerStop'});self.settle()
        self.assertEqual(self.rpc.replies[-1][1],{'decision':'cancel'})
        self.assertIn(('turn/interrupt',{'threadId':'task','turnId':'turn'}),self.rpc.calls)
    def test_failed_send_is_not_retried_and_durable_id_survives(self):
        self.rpc.fail_start=True;self.send()
        self.assertEqual(self.c.state['threadId'],'task')
        self.assertEqual(self.c.state['status'],'disconnected')
        self.settle();self.assertEqual(sum(m=='turn/start' for m,_ in self.rpc.calls),1)
        with self.assertRaises(ValueError):self.c.command({'action':'composerSend','text':'retry'})
    def test_resume_does_not_start_model_and_rehydrates_recent_history(self):
        self.rpc.turns=[{'id':'old','status':'completed','items':[{'id':'answer','type':'agentMessage','text':'Saved response'}]}]
        self.c.command({'action':'composerOpen','id':'task'});self.settle()
        self.assertEqual(self.c.state['messages'][0]['text'],'Saved response')
        self.assertFalse(any(m in ('thread/start','turn/start') for m,_ in self.rpc.calls))
    def test_reopen_restores_task_but_never_replays_approval_or_prompt(self):
        self.send();self.approval();self.c.next_publish=0;self.c.tick()
        other=Composer(self.root,self.root,lambda _:None,lambda _:None,rpc=FakeRPC())
        try:
            self.assertEqual(other.state['status'],'disconnected');self.assertEqual(other.state['threadId'],'task')
            self.assertEqual(other.state['approvals'],[]);self.assertEqual(other.rpc.calls,[])
        finally:other.close()
    def test_other_thread_requests_and_unsupported_interactions_are_not_approved(self):
        self.send()
        self.c.event({'id':8,'method':'item/tool/call','params':{'threadId':'task'}})
        self.c.event({'id':9,'method':'item/fileChange/requestApproval','params':{'threadId':'different'}})
        self.assertTrue(all(reply[2] for reply in self.rpc.replies))
        self.assertEqual(self.c.state['approvals'],[])
    def test_send_on_reconnected_transport_resumes_before_start(self):
        self.c.command({'action':'composerOpen','id':'task'});self.settle()
        self.rpc.process=None
        self.c.command({'action':'composerSend','text':'Follow up'});self.settle()
        methods=[m for m,_ in self.rpc.calls]
        self.assertEqual(methods.count('thread/resume'),2)
        self.assertEqual(methods[-1],'turn/start')
        self.assertEqual(methods[-2],'thread/read')
    def test_task_running_elsewhere_is_not_steered(self):
        self.c.command({'action':'composerOpen','id':'task'});self.settle()
        self.rpc.thread['status']={'type':'active','activeFlags':[]}
        self.c.command({'action':'composerSend','text':'Must not steer another run'});self.settle()
        self.assertFalse(any(m=='turn/start' for m,_ in self.rpc.calls))
        self.assertEqual(self.c.state['status'],'disconnected')
    def test_reconnect_reuses_loaded_writer_after_uncertain_send(self):
        self.rpc.fail_start=True;self.send()
        self.c.command({'action':'composerReconnect'});self.settle()
        self.assertFalse(any(m=='thread/resume' for m,_ in self.rpc.calls))
        self.assertEqual(sum(m=='turn/start' for m,_ in self.rpc.calls),1)

    def test_dead_transport_recovers_without_replaying_prompt(self):
        self.send()
        self.rpc.process=None
        self.c.tick()
        self.assertEqual(self.c.state['status'],'disconnected')
        self.c.next_reconnect=0
        self.settle()
        self.assertEqual(self.c.state['status'],'idle')
        self.assertEqual(sum(m=='turn/start' for m,_ in self.rpc.calls),1)
        self.assertIsNone(self.c.next_reconnect)

    def test_external_writer_is_observed_without_retrying_submission(self):
        original=self.rpc.request
        def request(method, params):
            if method=='thread/resume': raise RuntimeError('thread task already has an active writer')
            return original(method, params)
        self.rpc.request=request
        self.rpc.turns=[{'id':'external','status':'inProgress','items':[]}]
        self.c.command({'action':'composerOpen','id':'task'});self.settle()
        self.assertEqual(self.c.state['status'],'running')
        self.assertTrue(self.c.state['observing'])
        with self.assertRaises(ValueError): self.c.command({'action':'composerSend','text':'duplicate'})
        self.assertFalse(any(m=='turn/start' for m,_ in self.rpc.calls))
        self.rpc.turns=[{'id':'external','status':'completed','items':[]}]
        self.rpc.request=original
        self.c.next_observe=0;self.settle()
        self.assertFalse(self.c.state['observing'])
        self.assertEqual(self.c.state['status'],'idle')

    def test_parallel_tasks_keep_connections_and_approvals_isolated(self):
        rpcs=[];output=[]
        def factory(home,directory,emit,on_thread,**kwargs):
            rpc=FakeRPC();rpc.thread=dict(rpc.thread,id='task-'+str(len(rpcs)))
            rpcs.append(rpc)
            return Composer(home,directory,emit,on_thread,rpc=rpc)
        manager=ComposerManager(self.root,self.root/'multiple',lambda v:output.append(copy.deepcopy(v)),lambda _:None,factory=factory)
        def settle():
            for _ in range(100):
                manager.tick()
                if all(not c.future for c in manager.clients.values()): break
                time.sleep(.005)
        try:
            for project in ('one','two'):
                manager.command({'action':'composerOpen','cwd':str(self.root),'title':project})
                manager.command({'action':'composerSend','text':project});settle()
            clients=list(manager.clients.values());keys=list(manager.clients)
            self.assertTrue(all(c.state['active'] for c in clients))
            rpcs[0].events.put({'id':7,'method':'item/commandExecution/requestApproval','params':{'threadId':'task-0','turnId':'turn','command':'first only'}})
            clients[0].next_publish=0;manager.tick()
            self.assertTrue(output[-1]['tasks'][0]['needsInput'])
            self.assertEqual(output[-1]['threadId'],'task-1')
            manager.command({'action':'composerOpen','id':'task-0'});manager.tick()
            self.assertEqual(manager.selected,keys[0])
            self.assertFalse(any(m=='thread/resume' for rpc in rpcs for m,_ in rpc.calls))
            manager.command({'action':'composerReply','token':'7','accept':False})
            self.assertEqual(len(rpcs[0].replies),1);self.assertEqual(rpcs[1].replies,[])
            manager.command({'action':'composerStop'});settle()
            self.assertTrue(any(m=='turn/interrupt' for m,_ in rpcs[0].calls))
            self.assertFalse(any(m=='turn/interrupt' for m,_ in rpcs[1].calls))
            manager.close()
            recovered=ComposerManager(self.root,self.root/'multiple',lambda _:None,lambda _:None,factory=factory)
            try:
                self.assertEqual(len(recovered.clients),2)
                self.assertTrue(all(c.state['status']=='disconnected' for c in recovered.clients.values()))
                self.assertTrue(all(not rpc.calls for rpc in rpcs[2:]))
            finally: recovered.close()
        finally: manager.close()

    def test_output_volume_is_bounded(self):
        for i in range(200):self.c.message(str(i),'Command','x'*100000)
        self.assertLessEqual(sum(len(m['text']) for m in self.c.state['messages']),1000000)

    def test_removing_idle_task_is_local_and_does_not_delete_recovery_or_work(self):
        output=[]
        manager=ComposerManager(self.root,self.root/'multiple',lambda v:output.append(copy.deepcopy(v)),lambda _:None,
                                factory=lambda home,directory,emit,on_thread,**kwargs: Composer(home,directory,emit,on_thread,rpc=FakeRPC()))
        try:
            manager.command({'action':'composerOpen','cwd':str(self.root),'title':'Disposable view'})
            key=manager.selected;client=manager.clients[key]
            work=Path(client.directory)/'tasks'/'kept';work.mkdir(parents=True);(work/'note.txt').write_text('keep')
            manager.command({'action':'composerRemoveTask','key':key})
            self.assertNotIn(key,manager.clients)
            self.assertTrue((Path(client.directory)/'composer.json').exists())
            self.assertTrue((work/'note.txt').exists())
            manifest=json.loads((self.root/'multiple'/'composer-manifest.json').read_text())
            self.assertIn(key,manifest['removed'])
            recovered=ComposerManager(self.root,self.root/'multiple',lambda _:None,lambda _:None,
                                      factory=lambda home,directory,emit,on_thread,**kwargs: Composer(home,directory,emit,on_thread,rpc=FakeRPC()))
            try:self.assertNotIn(key,recovered.clients)
            finally:recovered.close()
        finally:manager.close()

    def test_removing_active_task_is_refused(self):
        manager=ComposerManager(self.root,self.root/'multiple',lambda _:None,lambda _:None,
                                factory=lambda home,directory,emit,on_thread,**kwargs: Composer(home,directory,emit,on_thread,rpc=FakeRPC()))
        try:
            manager.command({'action':'composerOpen','cwd':str(self.root)})
            key=manager.selected;manager.clients[key].change(status='running')
            with self.assertRaises(ValueError): manager.command({'action':'composerRemoveTask','key':key})
            self.assertIn(key,manager.clients)
        finally:manager.close()

    def test_task_key_is_directory_stable_across_recovery(self):
        manager=ComposerManager(self.root,self.root/'multiple',lambda _:None,lambda _:None,
                                factory=lambda home,directory,emit,on_thread,**kwargs: Composer(home,directory,emit,on_thread,rpc=FakeRPC()))
        try:
            manager.command({'action':'composerOpen','cwd':str(self.root),'title':'Stable key'})
            key=manager.selected
            self.assertEqual(manager.clients[key].state['taskKey'],key)
        finally:manager.close()
        recovered=ComposerManager(self.root,self.root/'multiple',lambda _:None,lambda _:None,
                                  factory=lambda home,directory,emit,on_thread,**kwargs: Composer(home,directory,emit,on_thread,rpc=FakeRPC()))
        try:
            self.assertIn(key,recovered.clients)
            self.assertEqual(recovered.clients[key].state['taskKey'],key)
        finally:recovered.close()

    def test_recovery_keeps_manifest_selected_task_not_last_directory(self):
        manager=ComposerManager(self.root,self.root/'multiple',lambda _:None,lambda _:None,
                                factory=lambda home,directory,emit,on_thread,**kwargs: Composer(home,directory,emit,on_thread,rpc=FakeRPC()))
        try:
            manager.command({'action':'composerOpen','cwd':str(self.root),'title':'first'});first=manager.selected
            manager.command({'action':'composerOpen','cwd':str(self.root),'title':'second'})
            manager.command({'action':'composerSelect','key':first})
        finally:manager.close()
        recovered=ComposerManager(self.root,self.root/'multiple',lambda _:None,lambda _:None,
                                  factory=lambda home,directory,emit,on_thread,**kwargs: Composer(home,directory,emit,on_thread,rpc=FakeRPC()))
        try:self.assertEqual(recovered.selected,first)
        finally:recovered.close()

    def test_failed_removal_manifest_keeps_task_visible(self):
        manager=ComposerManager(self.root,self.root/'multiple',lambda _:None,lambda _:None,
                                factory=lambda home,directory,emit,on_thread,**kwargs: Composer(home,directory,emit,on_thread,rpc=FakeRPC()))
        try:
            manager.command({'action':'composerOpen','cwd':str(self.root)});key=manager.selected
            with patch.object(manager,'_save_manifest',side_effect=ValueError('disk full')):
                with self.assertRaisesRegex(ValueError,'disk full'):
                    manager.command({'action':'composerRemoveTask','key':key})
            self.assertIn(key,manager.clients)
            self.assertNotIn(key,manager.removed)
            self.assertEqual(manager.selected,key)
        finally:manager.close()

    def test_send_routes_to_captured_task_key_after_selection_changes(self):
        rpcs=[]
        def factory(home,directory,emit,on_thread,**kwargs):
            rpc=FakeRPC();rpcs.append(rpc);return Composer(home,directory,emit,on_thread,rpc=rpc)
        manager=ComposerManager(self.root,self.root/'multiple',lambda _:None,lambda _:None,factory=factory)
        try:
            manager.command({'action':'composerOpen','cwd':str(self.root),'title':'first'});first=manager.selected
            manager.command({'action':'composerOpen','cwd':str(self.root),'title':'second'});second=manager.selected
            manager.command({'action':'composerSelect','key':second})
            manager.command({'action':'composerSend','taskKey':first,'text':'first only'})
            for _ in range(100):
                manager.tick()
                if not manager.clients[first].future: break
                time.sleep(.005)
            self.assertTrue(any(m=='turn/start' for m,_ in rpcs[0].calls))
            self.assertFalse(any(m=='turn/start' for m,_ in rpcs[1].calls))
            self.assertEqual(manager.selected,second)
        finally:manager.close()

    def test_completed_idle_transport_is_released_and_next_send_resumes(self):
        rpcs=[]
        def factory(home,directory,emit,on_thread,**kwargs):
            rpc=FakeRPC();rpcs.append(rpc);return Composer(home,directory,emit,on_thread,rpc=rpc)
        manager=ComposerManager(self.root,self.root/'multiple',lambda _:None,lambda _:None,factory=factory)
        try:
            manager.command({'action':'composerOpen','cwd':str(self.root)})
            key=manager.selected;manager.command({'action':'composerSend','taskKey':key,'text':'first'})
            for _ in range(100):
                manager.tick()
                if not manager.clients[key].future:break
                time.sleep(.005)
            manager.clients[key].event({'method':'turn/completed','params':{'turn':{'id':'turn','status':'completed'}}})
            manager.idle_since[key]=time.monotonic()-61;manager.tick()
            self.assertIsNone(rpcs[0].process)
            manager.command({'action':'composerSend','taskKey':key,'text':'second'})
            for _ in range(100):
                manager.tick()
                if not manager.clients[key].future:break
                time.sleep(.005)
            self.assertGreaterEqual(sum(method=='thread/resume' for method,_ in rpcs[0].calls),1)
            self.assertEqual(sum(method=='turn/start' for method,_ in rpcs[0].calls),2)
        finally:manager.close()

    def test_idle_reaper_never_releases_active_transport(self):
        rpc=FakeRPC()
        manager=ComposerManager(self.root,self.root/'multiple',lambda _:None,lambda _:None,
                                factory=lambda home,directory,emit,on_thread,**kwargs: Composer(home,directory,emit,on_thread,rpc=rpc))
        try:
            manager.command({'action':'composerOpen','cwd':str(self.root)})
            key=manager.selected;manager.command({'action':'composerSend','taskKey':key,'text':'still running'})
            for _ in range(100):
                manager.tick()
                if not manager.clients[key].future:break
                time.sleep(.005)
            manager.idle_since[key]=time.monotonic()-61;manager.tick()
            self.assertIsNotNone(rpc.process)
        finally:manager.close()
    def test_cache_write_failure_does_not_stop_task(self):
        self.send()
        self.c.next_save=0;self.c.next_publish=0;self.c.dirty=True
        with patch.object(Path,'write_text',side_effect=OSError('disk full')):self.c.tick()
        self.assertTrue(self.c.state['active'])
        self.assertIn('recovery cache',self.c.state['error'])
    def test_old_connection_approval_cannot_be_answered_on_new_connection(self):
        self.send()
        self.c.event({'_connection':-1,'id':7,'method':'item/commandExecution/requestApproval','params':{'threadId':'task','turnId':'turn'}})
        self.assertEqual(self.c.state['approvals'],[])
        self.assertEqual(self.rpc.replies,[])
    def test_new_thread_index_does_not_remove_other_sessions(self):
        worker=Worker(self.root,self.root/'worker',demo=True);worker.emit=lambda _:None
        try:
            before={r['id'] for r in worker.index.records()}
            worker.composer_thread(self.rpc.thread)
            self.assertTrue(before.issubset({r['id'] for r in worker.index.records()}))
        finally:worker.index.db.close();worker.executor.shutdown(wait=False)
    def test_organisation_never_connects_execution_client_or_writes_upstream(self):
        worker=Worker(self.root,self.root/'worker',demo=True);worker.emit=lambda _:None
        try:
            with patch.object(worker.rpc,'request',side_effect=AssertionError('Upstream mutation')):
                worker.command({'action':'assign','id':'demo-0','project':'unassigned'})
                worker.command({'action':'preference','id':'demo-0','favourite':True})
                worker.command({'action':'groupProjects','ids':[worker.index.snapshot(True,'')['projects'][0]['id']],'name':'Local group'})
            self.assertIsNone(worker.composer)
        finally:worker.index.db.close();worker.executor.shutdown(wait=False)

if __name__=='__main__':unittest.main()
