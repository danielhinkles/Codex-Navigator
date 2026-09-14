import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from index import Index
from worker import Worker

class PreviewAccessTests(unittest.TestCase):
    def test_deferred_indexing_and_detail_never_probe_media(self):
        with tempfile.TemporaryDirectory() as directory:
            index=Index(directory,media_access=False)
            record={'id':'test','name':'Test','createdAt':1,'updatedAt':2}
            index.upsert_metadata([record])
            turn={'id':'one','items':[{'type':'agentMessage','text':'/Users/test/Documents/my%20image.png'}]}
            with patch('index.local_file_available',side_effect=AssertionError('Premature file access')),patch('index.file_revision',side_effect=AssertionError('Premature file stat')):
                index.cache_page('test',[turn],None,index.fingerprint('test'),True)
                asset=index.detail('test')['media'][0]
                self.assertFalse(asset['available']);self.assertEqual(asset['unavailableReason'],'Preview access not enabled')
            index.db.close()

    def test_denial_is_reported_and_disappears_when_readable(self):
        with tempfile.TemporaryDirectory() as directory:
            index=Index(directory);path=Path(directory)/'image.png';path.write_bytes(b'fixture')
            record={'id':'test','createdAt':1,'updatedAt':2};index.upsert_metadata([record])
            index.cache_page('test',[{'id':'one','items':[{'type':'agentMessage','text':str(path)}]}],None,index.fingerprint('test'),True)
            with patch('builtins.open',side_effect=PermissionError()):
                asset=index.detail('test')['media'][0]
                self.assertFalse(asset['available']);self.assertEqual(asset['unavailableReason'],'Access denied')
            asset=index.detail('test')['media'][0]
            self.assertTrue(asset['available']);self.assertIsNone(asset['unavailableReason'])
            index.db.close()

    def test_enabling_after_deferral_reconciles_encoded_aliases(self):
        with tempfile.TemporaryDirectory() as directory:
            # Start from an already migrated cache, then add history while access is disabled.
            index=Index(directory);index.db.close()
            worker=Worker('/nonexistent',directory,media_access=False);events=[];worker.emit=events.append
            path=Path(directory)/'my image.png';path.write_bytes(b'fixture')
            worker.index.upsert_metadata([{'id':'test','createdAt':1,'updatedAt':2}])
            worker.index.cache_page('test',[{'id':'one','items':[{'type':'agentMessage','text':str(path).replace(' ','%20')}]}],None,worker.index.fingerprint('test'),True)
            worker.command({'action':'watch','ids':['test']})
            worker.command({'action':'mediaAccess','enabled':True})
            asset=next(e for e in reversed(events) if e['type']=='detail')['media'][0]
            self.assertEqual(asset['path'],str(path));self.assertTrue(asset['available'])
            worker.executor.shutdown(wait=True);worker.index.db.close()

    def test_explicit_projectless_beats_stale_project_hint(self):
        with tempfile.TemporaryDirectory() as directory:
            index=Index(directory);index.desktop={'projectless-thread-ids':['test']}
            record={'id':'test','projectId':'old-project','createdAt':1,'updatedAt':2}
            index.upsert_metadata([record]);self.assertEqual(index.native_project(record),'unassigned');self.assertEqual(index.summarize(record)['sync'],'Unassigned')
            index.db.close()

    def test_inferred_folder_is_not_labelled_explicit_assignment(self):
        with tempfile.TemporaryDirectory() as directory:
            index=Index(directory);index.desktop={'local-projects':{'p':{'name':'Project','rootPaths':['/test/project']}}}
            record={'id':'test','cwd':'/test/project','createdAt':1,'updatedAt':2}
            index.upsert_metadata([record]);self.assertEqual(index.summarize(record)['sync'],'From working folder')
            index.db.close()
