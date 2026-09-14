import io
import json
from pathlib import Path
import queue
import sys
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from rpc import CodexRPC

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
