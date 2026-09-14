import gzip
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.request import urlopen
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
import launcher

class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix="launch ' spaces ")
        self.root=Path(self.temp.name)
    def tearDown(self): self.temp.cleanup()
    def test_python_paths_are_literal_and_virtualenv_is_used_when_present(self):
        target=self.root/"main ' $(nothing).py"
        args,cwd=launcher.command(dict(kind='python',path=str(target)))
        self.assertEqual(args,['/usr/bin/python3',str(target)])
        self.assertEqual(cwd,self.root)
        python=self.root/'.venv/bin/python';python.parent.mkdir(parents=True);python.write_text('');python.chmod(0o755)
        self.assertEqual(launcher.command(dict(kind='python',path=str(target)))[0][0],str(python))
    def test_godot_runs_project_not_file_association(self):
        with patch.object(launcher,'executable',return_value='/Applications/Godot.app/Contents/MacOS/Godot'):
            args,cwd=launcher.command(dict(kind='godot',path=str(self.root)))
        self.assertEqual(args[1:],['--path',str(self.root)])
        self.assertEqual(cwd,self.root)
    def test_unity_requires_exact_editor_and_does_not_upgrade(self):
        settings=self.root/'ProjectSettings';settings.mkdir()
        (settings/'ProjectVersion.txt').write_text('m_EditorVersion: 6000.6.0f1\n')
        with patch.object(Path,'is_file',return_value=True):
            args,cwd=launcher.command(dict(kind='unity',path=str(self.root)))
        self.assertEqual(args[:2],['/usr/bin/open','-a']);self.assertIn('/6000.6.0f1/',args[2]);self.assertTrue(args[2].endswith('Unity.app'));self.assertEqual(args[3:],['--args','-projectPath',str(self.root)])
        with patch.object(Path,'is_file',return_value=False):
            with self.assertRaisesRegex(ValueError,'Install that version'):launcher.command(dict(kind='unity',path=str(self.root)))
    def test_only_local_server_urls_are_automatically_opened(self):
        self.assertEqual(launcher.local_url('\x1b[32mLocal: http://localhost:5173/\x1b[0m'),'http://localhost:5173/')
        self.assertEqual(launcher.local_url('http://0.0.0.0:8000'),'http://127.0.0.1:8000')
        self.assertIsNone(launcher.local_url('Visit https://example.com'))
        self.assertIsNone(launcher.local_url('http://localhost.evil.test:8000'))
        self.assertIsNone(launcher.local_url('http://user:password@localhost:8000'))
    def start(self,plan):
        log=self.root/(str(time.monotonic_ns())+'.log')
        output=log.open('wb')
        proc=subprocess.Popen([sys.executable,launcher.__file__,json.dumps(plan),'--no-browser'],stdout=output,stderr=subprocess.STDOUT)
        self.addCleanup(output.close)
        def stop():
            if proc.poll() is None:proc.terminate()
            try:proc.wait(timeout=6)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        self.addCleanup(stop)
        return proc,log
    def wait_for(self,condition):
        deadline=time.monotonic()+5
        while time.monotonic()<deadline:
            result=condition()
            if result:return result
            time.sleep(.03)
        self.fail('Launch condition timed out')
    def test_static_server_uses_free_ports_and_serves_engine_assets(self):
        page=self.root/'index.html';page.write_text('GAME')
        (self.root/'game.wasm.gz').write_bytes(gzip.compress(b'wasm-data'))
        plan=dict(kind='static',path=str(page),title='web')
        first,log=self.start(plan)
        url=self.wait_for(lambda:next(iter(re.findall(r'http://127\.0\.0\.1:\d+/index.html',log.read_text())),None))
        with urlopen(url) as response:
            self.assertEqual(response.read(),b'GAME');self.assertEqual(response.headers['Cross-Origin-Opener-Policy'],'same-origin')
        with urlopen(url.replace('index.html','game.wasm.gz')) as response:
            self.assertEqual(response.headers['Content-Type'],'application/wasm')
            self.assertEqual(response.headers['Content-Encoding'],'gzip')
            self.assertEqual(gzip.decompress(response.read()),b'wasm-data')
        second,log2=self.start(plan)
        other=self.wait_for(lambda:next(iter(re.findall(r'http://127\.0\.0\.1:\d+/index.html',log2.read_text())),None))
        self.assertNotEqual(url,other)
        first.terminate();self.assertEqual(first.wait(timeout=5),0)
        self.assertIsNone(second.poll())
    def test_stop_kills_stubborn_child_without_stopping_other_launch(self):
        script=self.root/'run.py'
        script.write_text("import signal,time\nsignal.signal(signal.SIGTERM,signal.SIG_IGN)\nprint('READY',flush=True)\ntime.sleep(120)\n")
        proc,log=self.start(dict(kind='python',path=str(script),title='stubborn'))
        self.wait_for(lambda:'READY' in log.read_text())
        proc.terminate();self.assertEqual(proc.wait(timeout=6),0)
    def test_nonzero_exit_is_propagated_with_error_output(self):
        proc,log=self.start(dict(kind='command',path=str(self.root),title='failure',command='echo launch-failed; exit 7'))
        self.assertEqual(proc.wait(timeout=5),7)
        self.assertIn('launch-failed',log.read_text())

    def test_custom_command_is_preserved(self):
        command="printf '%s' \"literal ' spaces\"; sleep 120"
        args,cwd=launcher.command(dict(kind='command',path=str(self.root),command=command))
        self.assertEqual(args,['/bin/zsh','-lc',command]);self.assertEqual(cwd,self.root)

if __name__=='__main__':unittest.main()
