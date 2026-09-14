"""Regression tests: malformed data and hostile requests must degrade, never kill the worker."""
import io
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import tempfile
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
sys.path.insert(0,str(Path(__file__).resolve().parent))
import launcher
from index import Index
from rpc import CodexRPC, RPCError
from worker import Worker
from test_composer import FakeRPC
from composer import Composer


class WorkerHardeningTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();root=Path(self.temp.name)
        self.worker=Worker(root/'home',root/'cache',demo=True);self.out=[];self.worker.emit=self.out.append
    def tearDown(self):
        self.worker.index.db.close();self.worker.executor.shutdown(wait=False);self.temp.cleanup()
    def test_non_object_commands_are_reported_not_fatal(self):
        for bad in (None,42,[],'x'):
            self.worker.handle_command(bad)
        self.assertTrue(all(o['type']=='error' for o in self.out));self.assertEqual(len(self.out),4)
    def test_preference_cannot_touch_reserved_keys(self):
        self.worker.handle_command({'action':'preference','id':'__server_projects__','name':'x','requestID':'r'})
        self.assertEqual(self.out[0]['type'],'error')
        self.assertNotEqual(self.worker.index.preference('__server_projects__').get('name'),'x')
    def test_scheduler_failure_keeps_worker_alive_and_restores_status(self):
        calls=[];before=self.worker.message
        def failing():
            calls.append(1)
            if len(calls)==1: raise RuntimeError('database is locked')
            if len(calls)==3: self.worker.closed=True
        self.worker.scheduler_pass=failing
        self.worker.run()
        self.assertEqual(len(calls),3)
        self.assertTrue(any(o.get('type')=='status' and 'locked' in o.get('message','') for o in self.out))
        self.assertEqual(self.worker.message,before)
    def test_emit_survives_lone_surrogates(self):
        buffer=io.StringIO();real=sys.stdout;sys.stdout=buffer
        try: Worker.emit(self.worker,{'text':'bad \ud800 char'})
        finally: sys.stdout=real
        self.assertIn('"text"',buffer.getvalue())
    def test_repeated_thread_list_cursor_stops(self):
        class Stuck:
            def request(self,method,params): return {'data':[],'nextCursor':'same'}
        self.worker.rpc=Stuck()
        with self.assertRaises(RPCError): self.worker.enumeration_request()


class IndexHardeningTests(unittest.TestCase):
    def test_observe_ignores_non_object_rollout_lines(self):
        with tempfile.TemporaryDirectory() as temp:
            index=Index(temp)
            try:
                record={'id':'a','name':'Example','cwd':'/projects/one','createdAt':100,'updatedAt':200,'historyMode':'paginated'}
                index.upsert_metadata([record])
                path=Path(temp)/'rollout.jsonl'
                path.write_text('null\n[1,2]\n"text"\n'+json.dumps({'type':'event_msg','payload':'x'})+'\n'
                                +json.dumps({'type':'event_msg','payload':{'type':'token_count','info':[]}})+'\n'
                                +json.dumps({'type':'event_msg','payload':{'type':'token_count','info':{'total_token_usage':{'total_tokens':5}}}})+'\n')
                index.observe(dict(record,path=str(path)))
                self.assertEqual(index.observation('a')['tokens'],5)
            finally: index.db.close()


class ComposerHardeningTests(unittest.TestCase):
    def test_malformed_events_do_not_escape_tick(self):
        with tempfile.TemporaryDirectory() as temp:
            rpc=FakeRPC();c=Composer(Path(temp),Path(temp),lambda *_:None,lambda *_:None,rpc=rpc)
            for event in ({'method':'thread/started','params':{'thread':None}},{'method':'turn/started','params':{}},
                          {'method':'item/reasoning/summaryTextDelta','params':None},{'method':7,'params':{}}):
                rpc.events.put(event)
            c.tick()
            self.assertTrue(rpc.events.empty())
            self.assertIn('could not read',c.state['error'])
    def test_malformed_request_still_gets_an_error_reply(self):
        with tempfile.TemporaryDirectory() as temp:
            rpc=FakeRPC();c=Composer(Path(temp),Path(temp),lambda *_:None,lambda *_:None,rpc=rpc)
            rpc.events.put({'id':9,'method':'item/commandExecution/requestApproval','params':'bad'})
            c.tick()
            self.assertEqual([r[0] for r in rpc.replies],[9]);self.assertIsNotNone(rpc.replies[0][2])
    def test_dead_pipe_reply_is_swallowed(self):
        with tempfile.TemporaryDirectory() as temp:
            rpc=FakeRPC();rpc.respond=lambda *a,**k:(_ for _ in ()).throw(RPCError('Codex is disconnected'))
            c=Composer(Path(temp),Path(temp),lambda *_:None,lambda *_:None,rpc=rpc)
            c.state['threadId']='task'
            c.event({'id':3,'method':'item/commandExecution/requestApproval','params':{'threadId':'other'}})
    def test_corrupt_saved_state_is_ignored(self):
        with tempfile.TemporaryDirectory() as temp:
            cache=Path(temp)/'cache';cache.mkdir();(cache/'composer.json').write_text('[1,2,3]')
            c=Composer(Path(temp),cache,lambda *_:None,lambda *_:None,rpc=FakeRPC())
            self.assertEqual(c.state['messages'],[])
            (cache/'composer.json').write_text(json.dumps({'messages':[None,5,{'id':'m','role':'Codex','text':'ok'}]}))
            c=Composer(Path(temp),cache,lambda *_:None,lambda *_:None,rpc=FakeRPC())
            self.assertEqual([m['id'] for m in c.state['messages']],['m'])


class RPCHardeningTests(unittest.TestCase):
    def test_close_releases_pending_waiters(self):
        class P:
            def terminate(self): pass
            def wait(self, timeout=None): return 0
        rpc=CodexRPC('/tmp',binary='unused');rpc.process=P();waiting=queue.Queue();rpc.pending[5]=waiting
        rpc.close()
        self.assertEqual(waiting.get(timeout=1)['error']['message'],'Codex connection closed')
    def test_closed_stdin_raises_rpc_error(self):
        class Closed:
            stdin=io.BytesIO()
        rpc=CodexRPC('/tmp',binary='unused');rpc.process=Closed();rpc.process.stdin.close()
        with self.assertRaises(RPCError): rpc._send({'method':'x'})
    def test_non_object_lines_are_skipped(self):
        class P:
            stdout=io.BytesIO(b'null\n[1]\n{"id":1,"result":{}}\n');stdin=io.BytesIO()
        rpc=CodexRPC('/tmp',binary='unused');rpc.process=P();waiting=queue.Queue();rpc.pending[1]=waiting
        rpc._read(rpc.process)
        self.assertEqual(waiting.get_nowait()['result'],{})


class LauncherHardeningTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()
    def start(self,plan,stdin=False):
        log=self.root/'launch.log';output=log.open('wb');self.addCleanup(output.close)
        if stdin:
            proc=subprocess.Popen([sys.executable,launcher.__file__,'--stdin','--no-browser'],stdin=subprocess.PIPE,stdout=output,stderr=subprocess.STDOUT)
            proc.stdin.write(json.dumps(plan).encode());proc.stdin.close()
        else:
            proc=subprocess.Popen([sys.executable,launcher.__file__,json.dumps(plan),'--no-browser'],stdout=output,stderr=subprocess.STDOUT)
        def stop():
            if proc.poll() is None:proc.terminate()
            try:proc.wait(timeout=6)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        self.addCleanup(stop)
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            found=re.findall(r'http://127\.0\.0\.1:\d+/index.html',log.read_text())
            if found: return found[0]
            time.sleep(.03)
        self.fail('server did not start: '+log.read_text())
    def test_plan_is_read_from_stdin(self):
        site=self.root/'site';site.mkdir();(site/'index.html').write_text('GAME')
        url=self.start(dict(kind='static',path=str(site/'index.html'),title='web'),stdin=True)
        with urlopen(url) as response: self.assertEqual(response.read(),b'GAME')
    def test_static_server_rejects_foreign_hosts_and_symlink_escapes(self):
        site=self.root/'site';site.mkdir();(site/'index.html').write_text('GAME')
        secret=self.root/'secret.txt';secret.write_text('private')
        os.symlink(secret,site/'leak.txt')
        url=self.start(dict(kind='static',path=str(site/'index.html'),title='web'))
        with self.assertRaises(HTTPError) as caught: urlopen(Request(url,headers={'Host':'evil.example'}))
        self.assertEqual(caught.exception.code,403)
        with self.assertRaises(HTTPError) as caught: urlopen(url.replace('index.html','leak.txt'))
        self.assertEqual(caught.exception.code,404)
        with self.assertRaises(HTTPError) as caught: urlopen(url.replace('index.html','..%2fsecret.txt'))
        self.assertIn(caught.exception.code,(403,404))
        with urlopen(url) as response: self.assertEqual(response.read(),b'GAME')
    def test_invalid_plan_is_rejected(self):
        with self.assertRaises(ValueError): launcher.load_plan(['launcher.py','[1,2]'])
        with self.assertRaises(ValueError): launcher.load_plan(['launcher.py'])


if __name__=='__main__':unittest.main()
