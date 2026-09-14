"""Opt-in live Composer smoke: one tiny ephemeral, read-only model turn.

No durable task/project assignment is created. Uses the existing Codex login.
"""
import os
from pathlib import Path
import sys
import tempfile
import time
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from composer import Composer
from rpc import CodexRPC

if '--live' not in sys.argv:
    raise SystemExit('Pass --live to send one ephemeral read-only test prompt through Codex.')

class SmokeRPC(CodexRPC):
    def request(self,method,params=None,timeout=20):
        if method=='thread/start':
            params=dict(params,ephemeral=True,sandbox='read-only',approvalPolicy='never')
            params.pop('projectId',None)
        return super().request(method,params,timeout)

with tempfile.TemporaryDirectory(prefix='navigator-composer-smoke-') as directory:
    rpc=SmokeRPC(os.environ.get('CODEX_HOME',str(Path.home()/'.codex')),interactive=True)
    c=Composer(rpc.home,directory,lambda _:None,lambda _:None,rpc=rpc)
    try:
        c.command({'action':'composerOpen','cwd':directory})
        c.command({'action':'composerSend','text':'Reply with exactly NAVIGATOR_COMPOSER_OK. Do not call tools, read files, or perform any other action.'})
        deadline=time.monotonic()+50
        while time.monotonic()<deadline:
            c.tick()
            if c.state['status'] not in ('starting','running','approval'): break
            if c.state['approvals']:raise AssertionError('Unexpected approval for no-tool smoke')
            time.sleep(.05)
        success=c.state['status']=='completed' and any(m['role']=='Codex' and 'NAVIGATOR_COMPOSER_OK' in m['text'] for m in c.state['messages'])
        print('Ephemeral Composer smoke:',c.state['status'],'response verified:',success)
        if not success:
            print('Error:',c.state['error'])
            if c.state['active']:c.command({'action':'composerStop'});c.tick()
            raise SystemExit(1)
    finally:c.close()
