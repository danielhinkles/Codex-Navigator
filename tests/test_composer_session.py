import base64
import copy
import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from composer import Composer, ComposerManager
from test_composer import FakeRPC

class VoiceRPC(FakeRPC):
    def request(self,method,params):
        if method.startswith('thread/realtime/'):
            self.calls.append((method,params));return {}
        return super().request(method,params)

class SessionTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.rpc=VoiceRPC();self.output=[]
        self.c=Composer(self.root,self.root,lambda v:self.output.append(copy.deepcopy(v)),lambda _:None,rpc=self.rpc)
        self.c.state.update(threadId='task',taskKey='first')
    def tearDown(self): self.c.close();self.temp.cleanup()
    def event(self,method,**p): self.c.event({'method':method,'params':dict(threadId='task',**p)})
    def settle_voice(self):
        for _ in range(100):
            self.c.tick()
            if not self.c.voice.pending:return
            time.sleep(.005)
        self.fail('Voice transport did not settle')
    def test_readable_thinking_sections_stream_and_reconcile(self):
        self.event('item/reasoning/summaryTextDelta',itemId='thought',summaryIndex=1,delta='Second')
        self.event('item/reasoning/summaryPartAdded',itemId='thought',summaryIndex=0)
        self.event('item/reasoning/summaryTextDelta',itemId='thought',summaryIndex=0,delta='First')
        self.event('item/reasoning/summaryTextDelta',itemId='thought',summaryIndex=0,delta=' section')
        self.assertEqual(self.c.state['messages'][0]['text'],'First section\n\nSecond')
        self.c.item({'id':'thought','type':'reasoning','summary':['Final summary'],'content':['not a readable summary']})
        self.assertEqual(len(self.c.state['messages']),1)
        self.assertEqual(self.c.state['messages'][0]['text'],'Final summary')
        self.event('item/reasoning/textDelta',itemId='private',delta='not for presentation')
        self.assertEqual(len(self.c.state['messages']),1)
    def test_turns_request_readable_summaries(self):
        self.assertEqual(self.c.turn_options({})['summary'],'auto')
    def test_plan_diff_and_final_phase_are_retained(self):
        self.event('item/plan/delta',itemId='plan',delta='Plan')
        self.event('turn/plan/updated',turnId='turn',plan=[{'step':'Check UI','status':'completed'}])
        self.event('turn/diff/updated',turnId='turn',diff='+ a change')
        self.c.item({'type':'agentMessage','id':'answer','text':'Done','phase':'final_answer'})
        self.assertEqual(self.c.state['messages'][-1]['phase'],'final_answer')
        self.assertIn('✓ Check UI',str(self.c.state['messages']))
        self.assertIn('+ a change',str(self.c.state['messages']))
    def test_work_duration_uses_server_timestamps_and_survives_history(self):
        self.c.change(status='starting')
        self.event('turn/started',turn={'id':'turn','startedAt':100})
        self.event('turn/completed',turn={'id':'turn','status':'completed','startedAt':100,'completedAt':194,'durationMs':94000})
        work=next(m for m in self.c.state['messages'] if m['role']=='Work')
        self.assertEqual(work['durationSeconds'],94)
        self.c.state['messages']=[]
        self.c.work_item({'id':'turn','startedAt':100,'completedAt':194,'durationMs':94000},completed=True,historical=True)
        self.assertEqual(self.c.state['messages'][0],work)
    def test_voice_is_opt_in_audio_is_transient_and_stale_audio_is_ignored(self):
        self.assertFalse(any(m.startswith('thread/realtime') for m,_ in self.rpc.calls))
        self.c.command({'action':'composerVoiceStart','voiceID':'v1'});self.settle_voice()
        self.assertEqual(self.c.state['voiceStatus'],'active')
        chunk={'data':base64.b64encode(b'\0\0'*2400).decode(),'numChannels':1,'sampleRate':24000}
        self.c.command({'action':'composerVoiceAudio','voiceID':'old','audio':chunk})
        self.assertFalse(any(m.endswith('appendAudio') for m,_ in self.rpc.calls))
        self.c.command({'action':'composerVoiceAudio','voiceID':'v1','audio':chunk});self.settle_voice()
        self.assertEqual(sum(m.endswith('appendAudio') for m,_ in self.rpc.calls),1)
        self.event('thread/realtime/outputAudio/delta',audio=chunk)
        self.assertEqual(self.output[-1]['type'],'composerVoiceAudio')
        self.assertNotIn(chunk['data'],json.dumps(self.c.state))
        self.c.command({'action':'composerVoiceStop','voiceID':'old'})
        self.assertEqual(self.c.state['voiceStatus'],'active')
        self.c.command({'action':'composerVoiceStop','voiceID':'v1'});self.settle_voice()
        self.assertEqual(self.c.state['voiceStatus'],'idle')
    def test_voice_cannot_steal_an_owned_or_running_task(self):
        self.c.observing=True
        with self.assertRaises(ValueError):self.c.command({'action':'composerVoiceStart','voiceID':'v1'})
        self.c.observing=False;self.c.change(status='running')
        with self.assertRaises(ValueError):self.c.command({'action':'composerVoiceStart','voiceID':'v1'})
        self.assertFalse(any(m.startswith('thread/realtime') for m,_ in self.rpc.calls))
    def test_voice_failure_stops_and_surfaces_error(self):
        self.c.command({'action':'composerVoiceStart','voiceID':'v1'});self.settle_voice()
        self.event('thread/realtime/error',message='Not enabled for this account')
        self.settle_voice()
        self.assertEqual(self.c.state['voiceStatus'],'idle')
        self.assertIn('Not enabled',self.c.state['voiceError'])
        self.assertTrue(any(m=='thread/realtime/stop' for m,_ in self.rpc.calls))
    def test_voice_creates_new_task_only_after_explicit_start(self):
        self.c.state['threadId']=''
        self.c.command({'action':'composerVoiceStart','voiceID':'v1'});self.settle_voice()
        self.assertEqual(sum(m=='thread/start' for m,_ in self.rpc.calls),1)
        self.assertTrue(any(m=='thread/realtime/start' and p['threadId']=='task' for m,p in self.rpc.calls))
    def test_manager_routes_voice_to_original_task_and_forwards_audio(self):
        manager=ComposerManager(self.root,self.root/'manager',self.output.append,lambda _:None,
            factory=lambda h,d,e,t,demo=False:Composer(h,d,e,t,rpc=VoiceRPC()))
        try:
            first=manager.add();key=first.state['taskKey'];first.state['threadId']='task'
            second=manager.add()
            manager.command({'action':'composerVoiceStart','taskKey':key,'voiceID':'v1'})
            for _ in range(100):
                manager.tick()
                if not first.voice.pending:break
                time.sleep(.005)
            self.assertEqual(first.state['voiceStatus'],'active')
            self.assertEqual(second.state['voiceStatus'],'idle')
            self.assertFalse(first.release_idle_transport())
            first.event({'method':'thread/realtime/outputAudio/delta','params':{'threadId':'task','audio':{'data':'AAA='}}})
            self.assertEqual(self.output[-1]['type'],'composerVoiceAudio')
            self.assertEqual(self.output[-1]['taskKey'],key)
        finally: manager.close()

if __name__=='__main__':unittest.main()
