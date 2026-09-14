import json
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from index import Index, project_turn, media_paths, valid_media_path, local_file_available
from worker import Worker


class IndexTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.index=Index(self.temp.name)
        self.record={'id':'a','name':'Example','cwd':'/projects/one','createdAt':100,'updatedAt':200,'historyMode':'paginated'}
        self.index.upsert_metadata([self.record])

    def tearDown(self):
        self.index.db.close();self.temp.cleanup()

    def turn(self,status='completed',duration=60000):
        return {'id':'t1','status':status,'startedAt':100,'completedAt':160 if status=='completed' else None,
                'durationMs':duration,'items':[{'type':'userMessage','id':'p1','content':[{'type':'text','text':'Hello'}]}]}

    def save(self,turn):
        self.index.cache_page('a',[turn],None,self.index.fingerprint('a'),True)

    def test_cached_encoded_media_resolves_and_deduplicates(self):
        path=Path(self.temp.name)/'image with spaces.png';path.write_bytes(b'image')
        turn=self.turn()
        turn['items']=[{'type':'userMessage','id':'p','content':[{'type':'text','text':str(path)+'\n'+str(path).replace(' ','%20')}]}]
        self.save(turn)
        media=self.index.detail('a')['media']
        self.assertEqual(len(media),1)
        self.assertEqual(media[0]['path'],str(path))
        self.assertTrue(media[0]['available'])

    def test_literal_percent_filename_is_preserved(self):
        path=Path(self.temp.name)/'image%20name.png';path.write_bytes(b'image')
        turn=self.turn();turn['items']=[{'type':'userMessage','id':'p','content':[{'type':'text','text':str(path)}]}]
        self.save(turn)
        self.assertEqual(self.index.detail('a')['media'][0]['path'],str(path))

    def test_missing_temporary_reference_explains_unavailability(self):
        turn=self.turn();turn['items']=[{'type':'userMessage','id':'p','content':[{'type':'text','text':'/private/tmp/navigator-nonexistent-test.png'}]}]
        self.save(turn)
        media=self.index.detail('a')['media'][0]
        self.assertFalse(media['available'])
        self.assertEqual(media['unavailableReason'],'Temporary file no longer present')

    def test_idempotent_turn_refresh(self):
        self.save(self.turn());self.save(self.turn())
        s=self.index.summarize(self.record)
        self.assertEqual(s['seconds'],60)
        self.assertEqual(s['promptCount'],1)

    def test_running_completion_replaces_live_elapsed(self):
        self.save(self.turn('inProgress',None))
        self.assertEqual(self.index.summarize(self.record)['status'],'Running')
        self.save(self.turn())
        s=self.index.summarize(self.record)
        self.assertEqual(s['status'],'Idle');self.assertEqual(s['activeStart'],0);self.assertEqual(s['seconds'],60)

    def test_offline_does_not_claim_running(self):
        self.save(self.turn('inProgress',None))
        self.assertEqual(self.index.summarize(self.record,False)['status'],'Status stale')
        self.assertEqual(self.index.summarize(self.record,False)['activeStart'],0)

    def test_assignment_persists_and_detects_conflict(self):
        self.index.assign('a','unassigned')
        self.assertEqual(self.index.summarize(self.record)['sync'],'Navigator only')
        changed=dict(self.record,cwd='/projects/two')
        self.index.upsert_metadata([changed])
        s=self.index.summarize(changed)
        self.assertEqual(s['project'],'unassigned');self.assertEqual(s['sync'],'Conflict')
        self.index.restore_assignment('a')
        self.assertEqual(self.index.summarize(changed)['project'],'cwd:/projects/two')

    def test_matching_assignment_clears_override(self):
        self.index.assign('a','unassigned');self.index.assign('a','cwd:/projects/one')
        self.assertEqual(self.index.summarize(self.record)['sync'],'From working folder')

    def test_incomplete_enumeration_does_not_delete(self):
        self.index.upsert_metadata([],complete=False)
        self.assertEqual(len(self.index.records()),1)
        self.index.upsert_metadata([],complete=True)
        self.assertEqual(self.index.records(),[])

    def test_missing_media_retained_and_deduplicated(self):
        turn=self.turn()
        turn['items'] += [{'type':'agentMessage','text':'![art](/missing/a.png) and ![art](/missing/a.png)'}]
        self.save(turn)
        assets=self.index.detail('a')['media']
        self.assertEqual(len(assets),1);self.assertFalse(assets[0]['available'])

    def test_runtime_is_not_session_span(self):
        self.save(self.turn())
        self.assertEqual(self.index.summarize(dict(self.record,updatedAt=10000000))['seconds'],60)

    def test_unknown_runtime_not_invented(self):
        turn=self.turn();turn.pop('durationMs');turn.pop('startedAt');turn.pop('completedAt')
        self.assertIsNone(project_turn(turn)['seconds'])

    def test_cache_survives_restart(self):
        self.save(self.turn());self.index.assign('a','unassigned')
        second=Index(self.temp.name)
        self.assertEqual(second.summarize(self.record)['project'],'unassigned')
        self.assertEqual(second.detail('a')['prompts'][0]['text'],'Hello');second.db.close()

    def test_base64_never_indexed_as_media(self):
        self.assertEqual(media_paths({'url':'data:image/png;base64,abcdef'}),[])

    def test_large_inline_tool_result_is_bounded(self):
        start=time.monotonic()
        result=media_paths({'text':'inline output: '+('/aaaa'*500000)+'\nSaved /tmp/result.png'})
        self.assertIn('/tmp/result.png',result)
        self.assertLess(time.monotonic()-start,2)

    def test_lifecycle_tail_handles_partial_records_and_completion(self):
        path=Path(self.temp.name)/'rollout.jsonl'
        event={'timestamp':time.time(),'type':'event_msg','payload':{'type':'task_started','turn_id':'t1','started_at':time.time()-10}}
        text=json.dumps(event)
        path.write_text(text[:20])
        record=dict(self.record,path=str(path))
        self.save(self.turn('interrupted',None))
        self.index.observe(record)
        self.assertEqual(self.index.observation('a')['offset'],0)
        with path.open('a') as out:out.write(text[20:]+'\n')
        self.index.observe(record)
        self.assertEqual(self.index.summarize(record)['status'],'Running')
        with path.open('a') as out:out.write(json.dumps({'type':'event_msg','payload':{'type':'task_complete','turn_id':'t1'}})+'\n')
        self.index.observe(record)
        self.assertEqual(self.index.observation('a')['start'],0)

    def test_lifecycle_truncation_resets_cursor(self):
        path=Path(self.temp.name)/'rollout.jsonl'
        path.write_text(json.dumps({'type':'event_msg','payload':{'type':'task_started','turn_id':'t1','started_at':100}})+'\n')
        record=dict(self.record,path=str(path));self.index.observe(record)
        path.write_text('{}\n');self.index.observe(record)
        self.assertEqual(self.index.observation('a')['start'],0)

    def test_rollback_removes_newer_cached_prompts(self):
        self.save(self.turn())
        newer=dict(self.turn(),id='t2',startedAt=200)
        self.index.cache_page('a',[newer],None,self.index.fingerprint('a'),True)
        self.assertEqual(len(self.index.turns('a')),2)
        self.index.cache_page('a',[self.turn()],None,self.index.fingerprint('a'),True,replace_head=True)
        self.assertEqual([t['id'] for t in self.index.turns('a')],['t1'])

    def test_prose_mistaken_for_filename_is_rejected(self):
        prose='/ '+('This is a paragraph about the interface. '*40)+'screen.jpg'
        self.assertIsNone(valid_media_path(prose))
        self.assertEqual(media_paths({'text':prose}),[])
        self.assertIsNone(valid_media_path('/tmp/'+('x'*256)+'.png'))
        self.assertIsNone(valid_media_path('/tmp/null\0.png'))
        self.assertEqual(valid_media_path('/Users/alex/My Project/screen one.png'),'/Users/alex/My Project/screen one.png')

    def test_cached_bad_paths_cannot_crash_snapshot_or_preview(self):
        self.save(self.turn())
        turn=self.index.turns('a')[0]
        turn['media']=['/'+('text '*300)+'.jpg','/tmp/'+('x'*300)+'.png','/tmp/valid.png']
        with self.index.db:
            self.index.db.execute('UPDATE turns SET data=? WHERE thread=?',(json.dumps(turn),'a'))
        with patch('pathlib.Path.is_file',side_effect=OSError(63,'File name too long')):
            self.assertEqual(len(self.index.snapshot(True,'test')['sessions']),1)
            detail=self.index.detail('a')
            self.assertEqual(len(detail['media']),1)
            self.assertFalse(detail['media'][0]['available'])

    def test_snapshot_does_not_stat_media(self):
        self.save(self.turn())
        with patch('pathlib.Path.is_file',side_effect=AssertionError('Should not inspect media')):
            self.assertEqual(len(self.index.snapshot(True,'test')['sessions']),1)

    def test_publish_preserves_last_good_snapshot(self):
        worker=Worker('/unused',str(Path(self.temp.name)/'publish'))
        worker.index.upsert_metadata([self.record]);output=[];worker.emit=output.append
        worker.publish()
        with patch.object(worker.index,'snapshot',side_effect=ValueError('bad projection')):
            worker.publish()
        self.assertEqual(len(output[-1]['sessions']),1)
        self.assertFalse(output[-1]['connected'])
        worker.index.db.close()

    def test_pagination_resume_and_incremental_boundary(self):
        worker=Worker('/unused',str(Path(self.temp.name)/'worker'))
        worker.index.upsert_metadata([self.record])
        class FakeRPC:
            def __init__(self):self.calls=[]
            def request(self,method,params):
                self.calls.append(params)
                if params['cursor']=='older':
                    return {'data':[{'id':'old','startedAt':1,'status':'completed','items':[]}],'nextCursor':None}
                return {'data':[{'id':'new','startedAt':2,'status':'completed','items':[]}],'nextCursor':'older'}
        worker.rpc=FakeRPC()
        worker.hydrate(self.record)
        self.assertFalse(worker.index.hydration('a')['complete'])
        worker.hydrate(self.record)
        self.assertEqual(worker.rpc.calls[-1]['cursor'],'older')
        self.assertTrue(worker.index.hydration('a')['complete'])
        worker.hydrate(self.record)
        self.assertEqual(len(worker.index.turns('a')),2)
        self.assertTrue(worker.index.hydration('a')['complete'])
        worker.index.db.close()


if __name__=='__main__':unittest.main()
