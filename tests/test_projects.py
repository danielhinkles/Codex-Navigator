import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from projects import project_params,create_project,list_projects
from worker import Worker
from index import Index

class ProjectTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name).resolve()
        self.folder=self.root/'Project';self.folder.mkdir()
        self.params=project_params(dict(name='New Project',path=str(self.folder),idempotencyKey='one'))
    def tearDown(self):self.temp.cleanup()
    def test_native_create_receives_name_root_and_idempotency(self):
        calls=[]
        class RPC:
            def request(_,method,params):
                calls.append((method,params))
                if method=='project/list':return dict(data=[],nextCursor=None)
                if method=='project/create':return dict(project=dict(id='native-id',name=params['name'],roots=params['roots']))
                raise AssertionError('Unexpected upstream mutation '+method)
        result=create_project(RPC(),self.params)
        self.assertEqual(result['id'],'native-id')
        self.assertEqual(calls[-1],('project/create',self.params))
        self.assertEqual(list(self.folder.iterdir()),[])
    def test_existing_folder_reuses_native_project_without_renaming(self):
        class RPC:
            def request(_,method,params):
                self.assertEqual(method,'project/list')
                return dict(data=[dict(id='existing',name='Keep name',roots=[dict(path=str(self.folder))])],nextCursor=None)
        self.assertEqual(create_project(RPC(),self.params)['name'],'Keep name')
    def test_validation_does_not_create_or_change_folders(self):
        for obj in (dict(name='',path=str(self.folder),idempotencyKey='one'),dict(name='Name',path=str(self.root/'missing'),idempotencyKey='one'),dict(name='Name',path='relative',idempotencyKey='one')):
            with self.assertRaises(ValueError):project_params(obj)
        self.assertFalse((self.root/'missing').exists())
    def test_native_projects_are_cached_and_legacy_mapping_deduplicates(self):
        cache=self.root/'index';index=Index(cache)
        try:
            index.desktop={'local-projects':{'legacy':dict(name='Legacy',rootPaths=[str(self.folder)])},'app-server-project-id-by-legacy-project-id-by-host':{'host':{'legacy':'native'}}}
            index.cache_server_projects([dict(id='native',name='Native',roots=[dict(path=str(self.folder))])])
            projects=index.snapshot(True,'')['projects']
            self.assertEqual([(p['id'],p['name'],p['path']) for p in projects],[('codex:legacy','Native',str(self.folder))])
            index.db.close();index=Index(cache)
            self.assertEqual(index.snapshot(False,'')['projects'][0]['name'],'Native')
        finally:index.db.close()
    def test_worker_queues_explicit_creation_and_persists_retry_key(self):
        worker=Worker(str(self.root/'home'),str(self.root/'cache'));worker.connected=True
        events=[];worker.emit=events.append
        try:
            obj=dict(action='createProject',name='Project',path=str(self.folder),idempotencyKey='first',requestID='ui')
            worker.command(obj)
            self.assertFalse(any(e.get('type') in ('ack','projectCreated') for e in events))
            first=worker.project_commands[0][1]
            worker.command(dict(obj,idempotencyKey='second'))
            self.assertEqual(worker.project_commands[1][1]['idempotencyKey'],first['idempotencyKey'])
            worker.finish_project_creation(obj,dict(id='native',name='Project',roots=first['roots']))
            result=next(e for e in events if e.get('type')=='projectCreated')
            self.assertEqual(result['project']['id'],'codex:native')
            self.assertEqual(result['project']['path'],str(self.folder))
            self.assertFalse((self.root/'home'/'.codex-global-state.json').exists())
            class Composer:
                def command(_,obj):self.assertEqual(obj['project'],'native');self.assertEqual(obj['cwd'],str(self.folder))
            worker.composer=Composer()
            worker.command(dict(action='composerOpen',project='codex:native',cwd=str(self.folder)))
        finally:worker.executor.shutdown(wait=True);worker.index.db.close()
    def test_organisation_never_calls_project_api(self):
        worker=Worker(str(self.root/'home'),str(self.root/'cache'));worker.emit=lambda _:None
        try:
            worker.index.cache_server_projects([dict(id='native',name='Project',roots=self.params['roots'])])
            worker.index.upsert_metadata([dict(id='task',createdAt=1,updatedAt=2,cwd=str(self.folder))])
            with patch.object(worker.rpc,'request',side_effect=AssertionError('Organisation must stay local')):
                worker.command(dict(action='assign',id='task',project='codex:native'))
                worker.command(dict(action='groupProjects',ids=['codex:native'],name='Group'))
                worker.command(dict(action='preference',id='codex:native',pinned=True))
            self.assertEqual(worker.project_commands,[])
            self.assertEqual(list(self.folder.iterdir()),[])
        finally:worker.executor.shutdown(wait=True);worker.index.db.close()

if __name__=='__main__':unittest.main()
