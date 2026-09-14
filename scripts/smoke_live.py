"""Read-only live integration check. Prints counts, never transcript contents."""
import os
from pathlib import Path
import sys
import tempfile
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'backend'))
from worker import Worker

with tempfile.TemporaryDirectory(prefix='navigator-smoke-') as cache:
    worker=Worker(os.environ.get('CODEX_HOME',str(Path.home()/'.codex')),cache)
    try:
        worker.rpc.connect();worker.connected=True
        worker.enumerate()
        records=sorted(worker.index.records(),key=lambda r:r.get('updatedAt',0),reverse=True)
        assert records,'No local sessions discovered'
        for record in records[:3]:
            for _ in range(8):worker.index.observe(record)
            for _ in range(10):
                worker.hydrate(record)
                if worker.index.hydration(record['id'])['complete']:break
        snapshot=worker.index.snapshot(True,'test')
        counts={'sessions':len(records),'projects':len(snapshot['projects']),
                'hydrated':sum(s['indexed'] for s in snapshot['sessions']),
                'prompts':sum(s['promptCount'] for s in snapshot['sessions']),
                'media':sum(s['mediaCount'] for s in snapshot['sessions']),
                'running':sum(s['status']=='Running' for s in snapshot['sessions'])}
        assert counts['prompts']>0,'No prompts recovered from paginated history'
        first=records[0]
        before=len(worker.index.detail(first['id'])['prompts'])
        worker.hydrate(first)
        after=len(worker.index.detail(first['id'])['prompts'])
        assert after>=before,'Refresh lost prompts'
        worker.index.assign(first['id'],'unassigned')
        assert worker.index.summarize(first)['sync']=='Navigator only'
        worker.index.restore_assignment(first['id'])
        print('Live read-only smoke passed:',counts)
    finally:
        worker.rpc.close();worker.index.db.close()
