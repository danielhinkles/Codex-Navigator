import json
from pathlib import Path
import sys
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from index import Index

class SearchReaderTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.index=Index(self.temp.name)
        self.index.upsert_metadata([{'id':'a','createdAt':0,'updatedAt':10},{'id':'b','createdAt':0,'updatedAt':5}])
    def tearDown(self):self.index.db.close();self.temp.cleanup()
    def turn(self,n,text='answer'):
        return {'id':'turn-'+str(n),'startedAt':n*10,'completedAt':n*10+1,'status':'completed','items':[{'type':'userMessage','id':'u'+str(n),'content':[{'type':'text','text':'question'}]},{'type':'agentMessage','id':'a'+str(n),'text':text}]}
    def test_cursor_keeps_boundary_when_older_history_is_prepended(self):
        self.index.cache_page('a',[self.turn(2),self.turn(3)],'old',self.index.fingerprint('a'),False)
        page=self.index.conversation('a',limit=2)
        self.index.cache_page('a',[self.turn(1)],None,self.index.fingerprint('a'),True)
        older=self.index.conversation('a',cursor=page['nextCursor'],limit=4)
        self.assertEqual([i['itemID'] for i in older['items']],['u1','a1','u2','a2'])
        self.assertIsNone(older['nextCursor'])
    def test_generated_item_ids_are_unique_for_unidentified_assistant_messages(self):
        turn=self.turn(1);turn['items'] += [{'type':'agentMessage','text':'one'},{'type':'agentMessage','text':'two'}]
        self.index.cache_page('a',[turn],None,self.index.fingerprint('a'),True)
        page=self.index.conversation('a');self.assertEqual(len({i['itemID'] for i in page['items']}),4)
    def test_limit_is_not_reported_truncated_when_no_extra_match_exists(self):
        self.index.cache_page('a',[self.turn(1,'Straße matching')],None,self.index.fingerprint('a'),True)
        result=self.index.search('STRASSE',limit=1)
        self.assertIn('Straße',result['results'][0]['snippet']);self.assertFalse(result['truncated'])
        self.assertFalse(result['complete']);self.assertIn('b',result['incompleteIDs'])
    def test_missing_around_target_does_not_silently_open_wrong_message(self):
        self.index.cache_page('a',[self.turn(1)],None,self.index.fingerprint('a'),True)
        with self.assertRaisesRegex(ValueError,'passage changed'):self.index.conversation('a',around_item_id='missing')
    def test_old_projection_marks_history_incomplete_for_full_backfill(self):
        self.index.cache_page('a',[self.turn(1)],None,self.index.fingerprint('a'),True)
        row=self.index.db.execute("SELECT data FROM turns WHERE thread='a'").fetchone()
        old=json.loads(row[0]);old.pop('entries')
        with self.index.db:
            self.index.db.execute("UPDATE turns SET data=? WHERE thread='a'",(json.dumps(old),))
            self.index.db.execute('PRAGMA user_version=2')
        self.index.migrate_media()
        self.assertFalse(self.index.hydration('a')['complete'])
        self.assertTrue(self.index.conversation('a')['incomplete'])
    def test_voice_suggestion_text_stays_user_only(self):
        self.index.cache_page('a',[self.turn(1,'Assistant names a project')],None,self.index.fingerprint('a'),True)
        projection=self.index.projection('a')
        self.assertIn('Assistant names',projection['searchText'])
        self.assertNotIn('Assistant names',projection['promptSearchText'])
    def test_search_skips_decoding_unrelated_published_summaries(self):
        self.index.cache_page('a',[self.turn(1,'needle')],None,self.index.fingerprint('a'),True)
        self.index.cache_page('b',[self.turn(2,'unrelated')],None,self.index.fingerprint('b'),True)
        self.index.snapshot(True,'test');self.index._turn_cache.clear();self.index._projection_cache.clear()
        self.index.search('needle')
        self.assertNotIn('b',self.index._turn_cache)

if __name__=='__main__':unittest.main()
