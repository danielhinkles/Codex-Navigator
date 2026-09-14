import json
import base64
from concurrent.futures import Future
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
import zipfile
from types import SimpleNamespace

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from index import Index
from library import backup, restore
from worker import Worker


class LibraryBackendTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.cache=self.root/'cache'
        self.index=Index(self.cache)
        self.record={'id':'thread','name':'Library','createdAt':1,'updatedAt':2,'historyMode':'paginated'}
        self.index.upsert_metadata([self.record])
        self.turn={'id':'turn','startedAt':1,'completedAt':2,'status':'completed','items':[
            {'type':'userMessage','id':'user-1','content':[{'type':'text','text':'First user question'}]},
            {'type':'agentMessage','id':'assistant-1','text':'First assistant answer'},
            {'type':'userMessage','id':'user-2','content':[{'type':'text','text':'Second user question'}]},
            {'type':'agentMessage','id':'assistant-2','text':'Second assistant answer'},
        ]}
        self.index.cache_page('thread',[self.turn],None,self.index.fingerprint('thread'),True)

    def tearDown(self):
        try:self.index.db.close()
        except sqlite3.Error:pass
        self.temp.cleanup()

    def test_portable_attachment_restore_rebases_only_imported_copies(self):
        imported=self.cache/'attachments'/'image.png';imported.parent.mkdir();imported.write_bytes(b'png fixture')
        external=self.root/'original.pdf';external.write_bytes(b'original')
        editor=self.cache/'composer-editors.json'
        editor.write_text(json.dumps({'editors':{'task':{'attachments':[{'kind':'image','path':str(imported)},{'kind':'file','path':str(external)}]}}}))
        archive=self.root/'attachments.zip';backup(self.cache,self.index.db,archive)
        other=self.root/'other-cache';other.mkdir();restore(other,archive)
        attached=json.loads((other/'composer-editors.json').read_text())['editors']['task']['attachments']
        self.assertEqual(attached[0]['path'],str(other/'attachments'/'image.png'))
        self.assertEqual(attached[1]['path'],str(external))
        self.assertEqual((other/'attachments'/'image.png').read_bytes(),b'png fixture')
        self.assertEqual(external.read_bytes(),b'original')

    def test_search_and_conversation_keep_every_user_and_assistant_item(self):
        result=self.index.search('second assistant')
        self.assertEqual(result['results'][0]['role'],'assistant')
        self.assertEqual(result['results'][0]['itemID'],'assistant-2')
        page=self.index.conversation('thread',limit=2,around_item_id='assistant-1')
        self.assertEqual([item['itemID'] for item in page['items']],['user-1','assistant-1'])
        newest=self.index.conversation('thread',limit=2)
        self.assertEqual([item['itemID'] for item in newest['items']],['user-2','assistant-2'])
        self.assertTrue(newest['nextCursor'].startswith('before-item:'))
        older=self.index.conversation('thread',cursor=newest['nextCursor'],limit=2)
        self.assertEqual([item['itemID'] for item in older['items']],['user-1','assistant-1'])

    def test_legacy_projection_migrates_without_losing_preferences(self):
        self.index.save_preference('thread',{'alias':'Kept locally','favourite':True})
        old={'id':'old','start':1,'end':2,'seconds':1,'status':'completed',
             'prompts':[{'id':'old-user','text':'old prompt','time':1}],
             'media':[],'changed':[],'messages':2,'last':'old response'}
        with self.index.db:
            self.index.db.execute('INSERT INTO turns VALUES(?,?,?)',('thread','old',json.dumps(old)))
            self.index.db.execute('PRAGMA user_version=2')
        self.index.db.close()
        self.index=Index(self.cache)
        entries=next(turn for turn in self.index.turns('thread') if turn['id']=='old')['entries']
        self.assertEqual([entry['role'] for entry in entries],['user','assistant'])
        self.assertEqual(self.index.preference('thread')['alias'],'Kept locally')

    def test_backup_restore_preserves_local_metadata_and_projectless_working_files(self):
        self.index.save_preference('thread',{'alias':'Backed up','favourite':True})
        logo=self.cache/'logos'/'mark.png';logo.parent.mkdir();logo.write_bytes(b'logo')
        draft=self.cache/'composers'/'one'/'composer.json';draft.parent.mkdir(parents=True);draft.write_text('{"draft":"keep"}')
        task=self.cache/'composers'/'one'/'tasks'/'projectless'/'work.txt';task.parent.mkdir(parents=True);task.write_text('backup source')
        output=self.root/'navigator-backup.zip'
        data={'__navigatorData':base64.b64encode(b'column-state').decode()}
        report=backup(self.cache,self.index.db,output,{'navigator.theme':'dark','navigator.columnsData':data,
                                                        'navigator.previewAccess':'exclude','auth.token':'discard'})
        self.assertTrue(output.is_file());self.assertEqual(report['uiPreferences'],{'navigator.theme':'dark','navigator.columnsData':data})
        self.index.save_preference('thread',{'alias':'Changed after backup'})
        task.write_text('newer user work')
        self.index.db.close()
        restored=restore(self.cache,output)
        self.index=Index(self.cache)
        self.assertEqual(self.index.preference('thread')['alias'],'Backed up')
        self.assertEqual(logo.read_bytes(),b'logo')
        self.assertEqual(draft.read_text(),'{"draft":"keep"}')
        self.assertEqual(task.read_text(),'newer user work')
        self.assertEqual(restored['uiPreferences'],{'navigator.theme':'dark','navigator.columnsData':data})

    def test_restore_to_another_cache_rebases_cache_owned_logo_path(self):
        logo=self.cache/'logos'/'mark.png';logo.parent.mkdir();logo.write_bytes(b'logo')
        self.index.save_preference('thread',{'logo':str(logo)})
        archive=self.root/'portable.zip';backup(self.cache,self.index.db,archive)
        self.index.db.close()
        other=self.root/'other-cache';other.mkdir()
        restore(other,archive)
        self.index=Index(other)
        restored=Path(self.index.preference('thread')['logo'])
        self.assertEqual(restored,(other/'logos'/'mark.png').resolve())
        self.assertEqual(restored.read_bytes(),b'logo')

    def test_portable_restore_rebases_projectless_composer_and_launch_paths_only(self):
        work=self.cache/'tasks'/'portable';work.mkdir(parents=True);(work/'run.py').write_text('print(1)')
        external=self.root/'external-cwd';external.mkdir()
        composer=self.cache/'composer.json';composer.write_text(json.dumps({'cwd':str(work),'messages':[]}))
        other_composer=self.cache/'composers'/'external'/'composer.json';other_composer.parent.mkdir(parents=True)
        other_composer.write_text(json.dumps({'cwd':str(external),'messages':[]}))
        plan={'title':'Run','kind':'python','path':str(work/'run.py'),'command':'','browserURL':''}
        encoded=base64.b64encode(json.dumps(plan).encode()).decode()
        archive=self.root/'portable-cwd.zip';backup(self.cache,self.index.db,archive,{'navigator.launchPlan.project':{'__navigatorData':encoded}})
        self.index.db.close();other=self.root/'other-cache';other.mkdir();restored=restore(other,archive)
        self.index=Index(other)
        saved=json.loads((other/'composer.json').read_text())
        external_saved=json.loads((other/'composers'/'external'/'composer.json').read_text())
        self.assertEqual(Path(saved['cwd']),(other/'tasks'/'portable').resolve())
        self.assertEqual(external_saved['cwd'],str(external))
        plan_data=restored['uiPreferences']['navigator.launchPlan.project']['__navigatorData']
        self.assertEqual(Path(json.loads(base64.b64decode(plan_data))['path']),(other/'tasks'/'portable'/'run.py').resolve())

    def test_restore_rejects_symlink_archive_without_replacing_cache(self):
        source=self.root/'unsafe.zip'
        with zipfile.ZipFile(source,'w') as archive:
            archive.writestr('manifest.json',json.dumps({'format':1}))
            link=zipfile.ZipInfo('cache/link')
            link.external_attr=0o120777 << 16
            archive.writestr(link,'/outside')
            archive.writestr('cache/navigator.sqlite',b'not sqlite')
        self.index.db.close()
        with self.assertRaisesRegex(ValueError,'symlinks'):
            restore(self.cache,source)
        self.index=Index(self.cache)
        self.assertEqual(self.index.preference('thread'),{})

    def test_invalid_database_restore_rolls_back_without_deleting_cache(self):
        archive=self.root/'invalid-db.zip'
        with zipfile.ZipFile(archive,'w') as contents:
            contents.writestr('manifest.json',json.dumps({'format':1}))
            contents.writestr('cache/navigator.sqlite',b'not an sqlite database')
        self.index.save_preference('thread',{'alias':'Current local state'})
        self.index.db.close()
        with self.assertRaisesRegex(ValueError,'database'):
            restore(self.cache,archive)
        self.index=Index(self.cache)
        self.assertEqual(self.index.preference('thread')['alias'],'Current local state')

    def test_rebuild_favourites_and_diagnostics_are_local_and_sanitised(self):
        worker=Worker('/nonexistent',str(self.cache))
        worker.index.upsert_metadata([self.record])
        worker.index.cache_page('thread',[self.turn],None,worker.index.fingerprint('thread'),True)
        events=[];worker.emit=events.append
        worker.command({'action':'favouriteMany','ids':['thread'],'favourite':True,'requestID':'fav'})
        self.assertTrue(worker.index.preference('thread')['favourite'])
        undo=next(event['undo'] for event in events if event['type']=='ack')
        worker.command(undo)
        self.assertNotIn('favourite',worker.index.preference('thread'))
        worker.index.mark_error('thread','contains prompt text that must not appear')
        worker.command({'action':'diagnostics','requestID':'report'})
        diagnostics=next(event for event in events if event['type']=='diagnostics')
        self.assertNotIn('prompt text',json.dumps(diagnostics))
        worker.command({'action':'rebuildIndex','requestID':'rebuild'})
        self.assertFalse(worker.index.turns('thread'))
        self.assertEqual(worker.index.preference('thread'),{})
        worker.executor.shutdown(wait=True,cancel_futures=True)
        worker.index.db.close()

    def test_delayed_maintenance_waits_for_read_then_acks_once(self):
        worker=Worker('/nonexistent',str(self.root/'worker-cache'))
        worker.index.upsert_metadata([self.record])
        events=[];worker.emit=events.append
        pending=Future();worker.future=('hydrate',pending,('thread',{},'',None,False))
        worker.command({'action':'rebuildIndex','requestID':'later'})
        self.assertEqual(events[0]['type'],'maintenancePending')
        self.assertFalse(any(event['type']=='ack' for event in events))
        pending.set_result({})
        # Worker.run clears a completed future before calling run_maintenance.
        worker.future=None
        worker.run_maintenance()
        self.assertEqual(sum(event['type']=='ack' for event in events),1)
        worker.executor.shutdown(wait=True,cancel_futures=True)
        worker.index.db.close()

    def test_backup_restore_and_rebuild_refuse_active_composer(self):
        worker=Worker('/nonexistent',str(self.root/'busy-cache'))
        worker.composer=SimpleNamespace(clients={'active':SimpleNamespace(state={'active':True},future=None)})
        for action in ('backup','restoreBackup','rebuildIndex'):
            with self.assertRaisesRegex(ValueError,'Finish or stop'):
                worker.command({'action':action,'path':str(self.root/'unused.zip')})
        worker.executor.shutdown(wait=True,cancel_futures=True)
        worker.index.db.close()

    def test_conversation_reader_prioritises_incomplete_durable_history_locally(self):
        worker=Worker('/nonexistent',str(self.root/'reader-cache'))
        worker.index.upsert_metadata([self.record])
        worker.index.cache_page('thread',[self.turn],'older',worker.index.fingerprint('thread'),False)
        worker.emit=lambda _:None
        worker.command({'action':'conversation','id':'thread','requestID':'read'})
        self.assertIn('thread',worker.history_focus)
        worker.executor.shutdown(wait=True,cancel_futures=True)
        worker.index.db.close()

    def test_restore_never_deletes_external_working_files(self):
        external=self.root/'projectless-working-file';external.write_text('user source')
        archive=self.root/'restore-source.zip';backup(self.cache,self.index.db,archive)
        self.index.db.close()
        restore(self.cache,archive)
        self.index=Index(self.cache)
        self.assertEqual(external.read_text(),'user source')

    def test_restore_keeps_legacy_projectless_task_and_its_symlink(self):
        legacy=self.cache/'tasks'/'legacy'/'work.txt';legacy.parent.mkdir(parents=True);legacy.write_text('at backup')
        external=self.root/'external-work';external.write_text('outside cache')
        link=self.cache/'tasks'/'legacy'/'linked-work';link.symlink_to(external)
        archive=self.root/'legacy-task.zip';backup(self.cache,self.index.db,archive)
        legacy.write_text('newer local work')
        self.index.db.close();restore(self.cache,archive);self.index=Index(self.cache)
        self.assertEqual(legacy.read_text(),'newer local work')
        self.assertTrue(link.is_symlink())
        self.assertEqual(link.readlink(),external)
        self.assertEqual(external.read_text(),'outside cache')

    def test_cache_and_source_symlinks_are_rejected_before_restore(self):
        archive=self.root/'safe.zip';backup(self.cache,self.index.db,archive)
        link=self.root/'cache-link';link.symlink_to(self.cache,target_is_directory=True)
        with self.assertRaisesRegex(ValueError,'symlink'):
            backup(link,self.index.db,self.root/'bad.zip')
        self.index.db.close()
        with self.assertRaisesRegex(ValueError,'symlink'):
            restore(link,archive)
        self.index=Index(self.cache)
        self.assertTrue(self.index.db.execute("SELECT 1 FROM metadata WHERE id='thread'").fetchone())

    def test_restore_does_not_write_through_retained_projectless_symlink(self):
        archive=self.root/'safe.zip';backup(self.cache,self.index.db,archive)
        external=self.root/'external-directory';external.mkdir()
        (self.cache/'tasks').symlink_to(external,target_is_directory=True)
        with zipfile.ZipFile(archive,'a') as contents:
            contents.writestr('cache/tasks/from-backup.txt','must not escape')
        self.index.db.close();restore(self.cache,archive);self.index=Index(self.cache)
        self.assertTrue((self.cache/'tasks').is_symlink())
        self.assertFalse((external/'from-backup.txt').exists())

    def test_partial_sqlite_schema_is_rejected_before_cache_swap(self):
        partial=self.root/'partial.sqlite';connection=sqlite3.connect(partial)
        connection.execute('CREATE TABLE metadata(id TEXT PRIMARY KEY, data TEXT, fingerprint TEXT)');connection.close()
        archive=self.root/'partial.zip'
        with zipfile.ZipFile(archive,'w') as contents:
            contents.writestr('manifest.json',json.dumps({'format':1}))
            contents.write(partial,'cache/navigator.sqlite')
        self.index.save_preference('thread',{'alias':'Keep current'})
        self.index.db.close()
        with self.assertRaisesRegex(ValueError,'validation'):
            restore(self.cache,archive)
        self.index=Index(self.cache)
        self.assertEqual(self.index.preference('thread')['alias'],'Keep current')

    def test_malformed_database_json_is_rejected_before_cache_swap(self):
        source=self.root/'malformed-source';other=Index(source)
        other.db.execute("INSERT INTO metadata VALUES('bad','not json','fingerprint')");other.db.commit();other.db.close()
        archive=self.root/'malformed.zip'
        with zipfile.ZipFile(archive,'w') as contents:
            contents.writestr('manifest.json',json.dumps({'format':1}))
            contents.write(source/'navigator.sqlite','cache/navigator.sqlite')
        self.index.save_preference('thread',{'alias':'Keep current'})
        self.index.db.close()
        with self.assertRaisesRegex(ValueError,'validation'):
            restore(self.cache,archive)
        self.index=Index(self.cache)
        self.assertEqual(self.index.preference('thread')['alias'],'Keep current')


if __name__=='__main__': unittest.main()
