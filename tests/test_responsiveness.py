"""Behavioral regressions for the September responsiveness and interaction audit."""
import json
from pathlib import Path
import queue
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from index import Index, fallback_title
from worker import Worker

class ResponsivenessTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.worker=Worker('/nonexistent-audit-home',self.temp.name)
        self.index=self.worker.index
        self.record={'id':'one','name':'One','cwd':'/projects/one','createdAt':100,'updatedAt':200,'historyMode':'paginated'}
        self.index.upsert_metadata([self.record])
        self.turn={'id':'turn','status':'completed','startedAt':100,'completedAt':160,'durationMs':60000,
                   'items':[{'type':'userMessage','id':'prompt','content':[{'type':'text','text':'Hello'}]}]}
        self.index.cache_page('one',[self.turn],None,self.index.fingerprint('one'),True)
        self.events=[];self.worker.emit=self.events.append
    def tearDown(self):
        self.worker.executor.shutdown(wait=True,cancel_futures=True)
        self.index.db.close();self.temp.cleanup()
    def test_cached_selection_does_not_wait_for_rpc(self):
        worker=self.worker;worker.connected=True
        released=threading.Event();started=[None];response=[None]
        class Fake:
            home='/nonexistent-audit-home'
            events=queue.Queue()
            process=None
            def request(self,method,params):
                if started[0] is None:
                    started[0]=time.perf_counter()
                    worker.commands.put({'action':'watch','ids':['one']})
                released.wait(2)
                return {'data':[], 'nextCursor':None}
            def close(self):released.set()
        worker.rpc=Fake()
        def emit(value):
            if value['type']=='detail':
                response[0]=time.perf_counter();worker.commands.put({'action':'quit'})
        worker.emit=emit
        worker.run()
        self.assertIsNotNone(response[0])
        self.assertLess(response[0]-started[0],0.1)
    def test_idle_snapshot_never_reparses_history(self):
        self.index.snapshot(True,'Ready')
        with patch('index.present_turns',side_effect=AssertionError('Reparsed unchanged history')):
            for _ in range(5):self.index.snapshot(True,'Ready')
            self.index.cache_page('one',[self.turn],None,self.index.fingerprint('one'),True)
            self.index.snapshot(True,'Ready')
    def test_cache_invalidates_after_direct_turn_change(self):
        self.index.snapshot(True,'Ready')
        projected=dict(self.index.turns('one')[0],messages=42)
        self.index.db.execute('UPDATE turns SET data=? WHERE thread=?',(json.dumps(projected),'one'))
        self.assertEqual(self.index.snapshot(True,'Ready')['sessions'][0]['messages'],42)
    def test_timestamp_alone_does_not_republish_history(self):
        self.worker.publish();self.events.clear()
        self.index.db.execute('UPDATE hydration SET checked=checked+1')
        self.worker.publish()
        self.assertFalse(any(e['type'] in ('snapshot','delta') for e in self.events))
    def test_cache_replacement_keeps_memory_accounted_during_eviction(self):
        self.index.turns('one')
        self.index._turn_cache['other']=(0,[])
        self.index._turn_costs['other']=64*1024*1024
        projected=dict(self.index.turns('one')[0],messages=42)
        self.index.db.execute('UPDATE turns SET data=? WHERE thread=?',(json.dumps(projected),'one'))
        self.assertEqual(self.index.turns('one')[0]['messages'],42)
        self.assertEqual(set(self.index._turn_cache),set(self.index._turn_costs))
        self.assertNotIn('other',self.index._turn_cache)
        self.assertGreater(self.index._turn_costs['one'],0)
    def test_large_index_does_not_redecode_evicted_histories_on_local_edit(self):
        records=[dict(self.record,id='session-'+str(i)) for i in range(600)]
        self.index.upsert_metadata(records)
        for record in records:
            self.index.cache_page(record['id'],[self.turn],None,self.index.fingerprint(record['id']),True)
        self.index.snapshot(True,'Ready')
        self.assertLessEqual(len(self.index._turn_cache),512)
        with patch.object(self.index,'turns',side_effect=AssertionError('Scheduling decoded evicted history')):
            for record in records:self.assertEqual(self.index.latest_status(record['id']),'completed')
        self.index.save_preference('session-0',{'alias':'Renamed'})
        with patch('index.readable_prompt',wraps=__import__('index').readable_prompt) as parse:
            snapshot=self.index.snapshot(True,'Ready')
        self.assertEqual(next(s['title'] for s in snapshot['sessions'] if s['id']=='session-0'),'Renamed')
        self.assertLessEqual(parse.call_count,1)
    def test_only_changed_sessions_are_sent(self):
        self.worker.publish();self.events.clear()
        self.worker.command({'action':'preference','id':'one','alias':'Renamed'})
        delta=next(e for e in self.events if e['type']=='delta')
        self.assertEqual([s['title'] for s in delta['sessions']],['Renamed'])
        self.assertIsNone(delta['projects'])
    def test_unchanged_detail_is_not_reemitted_even_after_poll(self):
        self.worker.command({'action':'watch','ids':['one']})
        self.events.clear();self.worker.detail_due.clear();self.worker.publish()
        self.assertFalse(any(e['type']=='detail' for e in self.events))
    def test_window_watches_union_and_release(self):
        self.worker.command({'action':'watch','window':'a','ids':['one']})
        self.worker.command({'action':'watch','window':'b','ids':['two']})
        self.assertEqual(self.worker.selected,{'one','two'})
        self.worker.command({'action':'watch','window':'a','ids':[]})
        self.assertEqual(self.worker.selected,{'two'})
        self.assertNotIn('one',self.worker.detail_output)
    def test_incomplete_runtime_and_offline_lifecycle(self):
        self.index.cache_page('one',[self.turn],'older',self.index.fingerprint('one'),False)
        self.assertEqual(self.index.summarize(self.record)['runtimeCoverage'],'partial')
        self.index.db.execute('INSERT INTO observations VALUES(?,?)',('one',json.dumps({'start':time.time()-5,'freshAt':time.time()})))
        value=self.index.summarize(self.record,False)
        self.assertEqual(value['status'],'Status stale');self.assertEqual(value['activeStart'],0)
    def test_bulk_assignment_and_undo_are_atomic_and_local(self):
        source=Path(self.temp.name)/'source';source.mkdir();asset=source/'keep.txt';asset.write_text('original')
        second=dict(self.record,id='two');self.index.upsert_metadata([self.record,second])
        trace=[];self.index.db.set_trace_callback(trace.append)
        with patch.object(self.worker.rpc,'request',side_effect=AssertionError('Must remain local')):
            self.worker.command({'action':'assignMany','assignments':{'one':'unassigned','two':'unassigned'},'requestID':'bulk'})
            inverse=next(e['undo'] for e in self.events if e['type']=='ack')
            self.assertEqual(sum(q=='COMMIT' for q in trace),1)
            self.assertEqual(self.index.summarize(self.record)['project'],'unassigned')
            self.worker.command(inverse)
            self.assertEqual(self.index.summarize(self.record)['project'],'cwd:/projects/one')
            self.assertEqual(self.index.summarize(second)['project'],'cwd:/projects/one')
        self.assertEqual(asset.read_text(),'original');self.assertTrue(source.is_dir())
    def test_bulk_validation_prevents_partial_assignment(self):
        with self.assertRaises(ValueError):
            self.worker.command({'action':'assignMany','assignments':{'one':'unassigned','missing':'unassigned'}})
        self.assertEqual(self.index.summarize(self.record)['project'],'cwd:/projects/one')
    def test_error_ack_is_correlated(self):
        self.worker.handle_command({'action':'assign','id':'one','project':'missing','requestID':'failed-save'})
        self.assertEqual(self.events[-1]['type'],'error');self.assertEqual(self.events[-1]['requestID'],'failed-save')
    def test_oversized_rollout_keeps_complete_cursor_and_finishes(self):
        path=Path(self.temp.name)/'rollout.jsonl'
        path.write_bytes(b'{"payload":"'+b'x'*(2*1024*1024)+b'"}\n'+json.dumps({'type':'event_msg','payload':{'type':'task_started','started_at':123}}).encode()+b'\n')
        record=dict(self.record,path=str(path))
        self.index.observe(record,budget=65536)
        self.assertEqual(self.index.observation('one')['offset'],0)
        self.assertLessEqual(len(self.index._tail['one']['data']),65536)
        for _ in range(40):self.index.observe(record,budget=65536)
        self.assertEqual(self.index.observation('one')['offset'],path.stat().st_size)
        self.assertEqual(self.index.observation('one')['start'],123)
    def test_media_revision_and_summary_count_agree(self):
        image=Path(self.temp.name)/'my image.png';image.write_bytes(b'one')
        turn=dict(self.turn,items=[{'type':'agentMessage','text':str(image)+'\n'+str(image).replace(' ','%20')}])
        self.index.cache_page('one',[turn],None,self.index.fingerprint('one'),True)
        self.assertEqual(self.index.snapshot(True,'Ready')['sessions'][0]['mediaCount'],1)
        detail=self.index.detail('one');first=detail['media'][0]['revision']
        self.assertEqual(len(detail['media']),1)
        self.assertEqual(self.index.snapshot(True,'Ready')['sessions'][0]['mediaCount'],1)
        image.write_bytes(b'new image bytes')
        self.assertNotEqual(self.index.detail('one')['media'][0]['revision'],first)
    def test_fallback_title_skips_attachment_wrapper(self):
        self.assertEqual(fallback_title('# Files mentioned by the user:\n\n/Users/test/image.png\n\n## My request:\nFix the preview'),'Fix the preview')

if __name__=='__main__':unittest.main()
