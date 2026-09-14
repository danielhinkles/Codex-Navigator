import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.parse import urlparse, parse_qs

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from index import Index
from worker import Worker

class NavigationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.root=Path(self.temp.name)
        self.index=Index(self.root/'index')
        self.state={
            'local-projects':{'saved':{'id':'saved','name':'Purple Surge','rootPaths':[str(self.root/'Purple Surge')]}},
            'thread-project-assignments':{'assigned':{'projectId':'saved'}},
            'projectless-thread-ids':['voice'],
            'pinned-project-ids':['saved'],
            'app-server-project-id-by-legacy-project-id-by-host':{'local:home':{'saved':'server-id'}}}
        (self.root/'.codex-global-state.json').write_text(json.dumps(self.state))
        self.index.load_desktop(self.root)
    def tearDown(self):
        self.index.db.close();self.temp.cleanup()
    def record(self,tid='a',**kw):
        return dict(id=tid,createdAt=100,updatedAt=200,**kw)
    def test_projectless_and_unsaved_cwds_are_unassigned(self):
        records=[self.record('voice',cwd='/Users/test/Documents/Codex/2026-09-13/realtime-voice-chat/outputs'),self.record(cwd='/tmp/unrelated')]
        self.index.upsert_metadata(records)
        snapshot=self.index.snapshot(True,'test')
        self.assertTrue(all(s['project']=='unassigned' for s in snapshot['sessions']))
        self.assertEqual(len(snapshot['projects']),1)
    def test_assignment_server_id_and_root_resolve_same_project(self):
        records=[self.record('assigned',cwd='/tmp/worktree'),self.record('server',projectId='server-id'),self.record('root',cwd=str(self.root/'Purple Surge/subfolder'))]
        self.index.upsert_metadata(records)
        snapshot=self.index.snapshot(True,'test')
        self.assertEqual({s['project'] for s in snapshot['sessions']},{'codex:saved'})
        project=snapshot['projects'][0]
        self.assertEqual(project['name'],'Purple Surge');self.assertTrue(project['pinned'])
        self.assertEqual(project['path'],str(self.root/'Purple Surge'))
    def test_old_logo_preference_migrates(self):
        self.index.save_preference('cwd:'+str(self.root/'Purple Surge'),{'logo':'/test.png','colour':'purple'})
        project=self.index.snapshot(True,'test')['projects'][0]
        self.assertEqual(project['logo'],'/test.png')
        self.assertEqual(self.index.preference('codex:saved')['colour'],'purple')
    def test_desktop_cache_survives_missing_state(self):
        (self.root/'.codex-global-state.json').unlink()
        self.index.load_desktop(self.root)
        self.assertEqual(self.index.snapshot(False,'offline')['projects'][0]['name'],'Purple Surge')
    def test_explicit_unassigned_override_survives(self):
        r=self.record('assigned',cwd='/tmp/worktree');self.index.upsert_metadata([r])
        self.index.assign('assigned','unassigned')
        self.assertEqual(self.index.summarize(r)['project'],'unassigned')
        self.index.restore_assignment('assigned')
        self.assertEqual(self.index.summarize(r)['project'],'codex:saved')
    def test_cumulative_token_count_is_not_summed(self):
        path=self.root/'rollout.jsonl'
        path.write_text('\n'.join(json.dumps({'type':'event_msg','payload':{'type':'token_count','info':{'total_token_usage':{'total_tokens':n}}}}) for n in [100,250,250])+'\n')
        record=self.record(path=str(path))
        self.index.upsert_metadata([record]);self.index.observe(record)
        self.assertEqual(self.index.summarize(record)['tokenUsage'],250)
        self.assertIsNone(self.index.summarize(self.record('other'))['tokenUsage'])
    def test_new_session_opens_project_composer_without_starting_model(self):
        worker=Worker(str(self.root),str(self.root/'worker'))
        worker.connected=True;events=[];worker.emit=events.append
        project=self.root/'Purple Surge';project.mkdir()
        try:
            with patch.object(worker.rpc,'request',side_effect=AssertionError('Must use desktop composer')):
                worker.command({'action':'newCodex','cwd':str(project),'project':'codex:saved'})
            route=next(e['url'] for e in events if e['type']=='openURL')
            self.assertEqual(urlparse(route).netloc,'threads')
            self.assertEqual(urlparse(route).path,'/new')
            self.assertEqual(parse_qs(urlparse(route).query),{'mode':['codex'],'path':[str(project)],'projectId':['saved']})
        finally:worker.index.db.close()
    def test_logo_replacement_has_new_url_and_reset(self):
        worker=Worker(str(self.root),str(self.root/'worker'));worker.emit=lambda _:None
        image=self.root/'logo.png';image.write_bytes(b'first')
        try:
            worker.command({'action':'preference','id':'codex:saved','logo':str(image),'logoFolder':False,'logoStyle':'Button trim'})
            first=worker.index.preference('codex:saved')['logo']
            image.write_bytes(b'second')
            worker.command({'action':'preference','id':'codex:saved','logo':str(image)})
            second=worker.index.preference('codex:saved')['logo']
            self.assertNotEqual(first,second)
            self.assertEqual(Path(first).read_bytes(),b'first')
            self.assertFalse(worker.index.preference('codex:saved')['logoFolder'])
            worker.command({'action':'preference','id':'codex:saved','resetLogo':True})
            self.assertNotIn('logo',worker.index.preference('codex:saved'))
        finally:worker.index.db.close()

    def test_organisation_never_writes_codex_or_calls_service(self):
        worker=Worker(str(self.root),str(self.root/'worker'));worker.emit=lambda _:None
        source=self.root/'.codex-global-state.json'
        state=json.loads(source.read_text())
        state['local-projects']['second']={'id':'second','name':'Another project','rootPaths':[]}
        source.write_text(json.dumps(state))
        original=source.read_bytes()
        folder=self.root/'Purple Surge';folder.mkdir()
        asset=folder/'keep.txt';asset.write_text('unchanged')
        try:
            worker.index.load_desktop(self.root)
            worker.index.upsert_metadata([self.record('assigned')])
            with patch.object(worker.rpc,'request',side_effect=AssertionError('Organisation must stay local')):
                worker.command({'action':'groupProjects','ids':['codex:saved','codex:second'],'name':'Together'})
                self.assertEqual(worker.index.preference('codex:saved')['group'],'Together')
                self.assertEqual(worker.index.preference('codex:second')['group'],'Together')
                worker.command({'action':'assign','id':'assigned','project':'unassigned'})
                worker.command({'action':'preference','id':'codex:saved','pinned':True})
                worker.command({'action':'restore','id':'assigned'})
                worker.command({'action':'groupProjects','ids':['codex:saved'],'name':''})
            self.assertEqual(source.read_bytes(),original)
            self.assertEqual(asset.read_text(),'unchanged')
            self.assertEqual(worker.index.preference('codex:saved')['group'],'')
        finally:worker.index.db.close()

    def test_group_rejects_stale_projects_without_partial_changes(self):
        worker=Worker(str(self.root),str(self.root/'worker'));worker.emit=lambda _:None
        try:
            worker.index.load_desktop(self.root)
            with self.assertRaises(ValueError):
                worker.command({'action':'groupProjects','ids':['codex:saved','missing'],'name':'Together'})
            self.assertNotIn('group',worker.index.preference('codex:saved'))
        finally:worker.index.db.close()

if __name__=='__main__':unittest.main()
