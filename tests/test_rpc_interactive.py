import io
import json
from pathlib import Path
import queue
import sys
import unittest
from unittest.mock import patch
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from rpc import CodexRPC

class ExecutableDiscoveryTests(unittest.TestCase):
    def discover(self, installed=(), path_binary=None, override=None, binary=None):
        with patch.dict('os.environ', {'NAVIGATOR_CODEX':override} if override else {}, clear=True), \
             patch('rpc.shutil.which', return_value=path_binary), \
             patch('rpc.os.path.isfile', side_effect=lambda path:path in installed):
            return CodexRPC('/tmp', binary=binary).binary

    def test_finder_launch_discovers_current_and_legacy_bundle_layouts(self):
        for app in ('ChatGPT', 'Codex'):
            for relative in ('codex-cli/bin/codex', 'codex-cli/CodexCLI.app/Contents/MacOS/codex', 'codex'):
                candidate=f'/Applications/{app}.app/Contents/Resources/{relative}'
                with self.subTest(candidate=candidate):
                    self.assertEqual(self.discover(installed={candidate}),candidate)

    def test_packaged_entrypoint_precedes_raw_and_legacy_binaries(self):
        root='/Applications/ChatGPT.app/Contents/Resources/'
        wrapper=root+'codex-cli/bin/codex'
        self.assertEqual(self.discover(installed={wrapper,root+'codex-cli/CodexCLI.app/Contents/MacOS/codex',root+'codex'}),wrapper)

    def test_explicit_override_and_path_keep_precedence(self):
        installed={'/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex'}
        self.assertEqual(self.discover(installed,path_binary='/path/codex'),'/path/codex')
        self.assertEqual(self.discover(installed,path_binary='/path/codex',override='/override/codex'),'/override/codex')
        self.assertEqual(self.discover(installed,path_binary='/path/codex',override='/override/codex',binary='/explicit/codex'),'/explicit/codex')

    def test_missing_installation_stays_unavailable(self):
        self.assertIsNone(self.discover())

class FakeProcess:
    def __init__(self, message):
        self.stdout=io.BytesIO((json.dumps(message)+'\n').encode())
        self.stdin=io.BytesIO()

class InteractiveTransportTests(unittest.TestCase):
    def test_interactive_request_is_tagged_and_waits_for_user(self):
        rpc=CodexRPC('/tmp',binary='unused',interactive=True)
        process=FakeProcess({'id':7,'method':'item/fileChange/requestApproval','params':{}})
        rpc.process=process;rpc._read(process)
        event=rpc.events.get_nowait()
        self.assertEqual(event['_connection'],rpc.connection)
        self.assertEqual(event['id'],7)
        self.assertEqual(process.stdin.getvalue(),b'')
    def test_browsing_transport_rejects_approval(self):
        rpc=CodexRPC('/tmp',binary='unused')
        process=FakeProcess({'id':7,'method':'item/fileChange/requestApproval','params':{}})
        rpc.process=process;rpc._read(process)
        response=json.loads(process.stdin.getvalue())
        self.assertIn('error',response);self.assertNotIn('result',response)
        self.assertTrue(rpc.events.empty())
    def test_old_reader_cannot_fail_new_requests_or_queue_old_events(self):
        rpc=CodexRPC('/tmp',binary='unused',interactive=True)
        old=FakeProcess({'id':7,'method':'item/fileChange/requestApproval','params':{}})
        rpc.process=FakeProcess({});waiting=queue.Queue();rpc.pending[12]=waiting
        rpc._read(old)
        self.assertTrue(waiting.empty());self.assertTrue(rpc.events.empty())

if __name__=='__main__':unittest.main()
