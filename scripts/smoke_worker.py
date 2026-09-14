"""Exercise real process IPC, live refresh, and local assignment round-trip."""
import json
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time

with tempfile.TemporaryDirectory(prefix='navigator-ipc-') as cache:
    p=subprocess.Popen([sys.executable,str(Path(__file__).resolve().parents[1]/'backend/worker.py'),'--cache',cache],
        stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
    events=queue.Queue()
    def read():
        snapshot=None
        for line in p.stdout:
            value=json.loads(line)
            if value['type']=='snapshot':snapshot=value
            elif value['type']=='delta' and snapshot:
                sessions={s['id']:s for s in snapshot['sessions']}
                for tid in value['removed']:sessions.pop(tid,None)
                sessions.update({s['id']:s for s in value['sessions']})
                snapshot=dict(snapshot,sessions=list(sessions.values()))
                if value['projects'] is not None:snapshot['projects']=value['projects']
                snapshot['activity'].update(value['activity'])
                value=snapshot
            elif value['type']=='status' and snapshot:
                snapshot=dict(snapshot,connected=value['connected'],message=value['message']);value=snapshot
            events.put(value)
    threading.Thread(target=read,daemon=True).start()
    def send(obj):p.stdin.write(json.dumps(obj)+'\n');p.stdin.flush()
    def until(predicate,timeout=30):
        deadline=time.monotonic()+timeout
        while time.monotonic()<deadline:
            try:obj=events.get(timeout=1)
            except queue.Empty:continue
            if obj.get('type')=='error':raise AssertionError(obj['message'])
            if predicate(obj):return obj
        raise AssertionError('Worker event timeout')
    try:
        first=until(lambda o:o.get('type')=='snapshot' and o['connected'] and any(s['indexed'] for s in o['sessions']))
        session=max((s for s in first['sessions'] if s['indexed']),key=lambda s:s['modified'])
        tid=session['id'];send({'action':'watch','ids':[tid]})
        detail=until(lambda o:o.get('type')=='detail' and o['id']==tid)
        assert detail['prompts']
        send({'action':'assign','id':tid,'project':'unassigned'})
        until(lambda o:o.get('type')=='snapshot' and any(s['id']==tid and s['project']=='unassigned' and s['sync']=='Navigator only' for s in o['sessions']))
        send({'action':'restore','id':tid})
        until(lambda o:o.get('type')=='snapshot' and any(s['id']==tid and s['project']==session['nativeProject'] for s in o['sessions']))
        send({'action':'refresh','requestID':'alive'})
        until(lambda o:o.get('type')=='ack' and o.get('requestID')=='alive')
        print('Worker IPC passed: history, prompt detail, assignment/restore, live refresh')
    finally:
        send({'action':'quit'})
        try:p.wait(timeout=10)
        except subprocess.TimeoutExpired:p.terminate();p.wait(timeout=5)
