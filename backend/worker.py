#!/usr/bin/env python3
"""One background worker owns SQLite and serializes writes; newline JSON IPC to UI."""
from concurrent.futures import ThreadPoolExecutor
import argparse
import json
import os
from pathlib import Path
import queue
import shutil
import sys
import threading
import time

from index import Index
from library import backup as backup_library, restore as restore_library
from rpc import CodexRPC, RPCError


class Worker:
    def __init__(self, home, cache, demo=False, media_access=True):
        self.index = Index(cache,media_access=media_access)
        self.rpc = CodexRPC(home)
        self.commands = queue.Queue()
        self.selected = set()
        self.connected = False
        self.message = 'Connecting to local Codex…'
        self.next_connect = 0
        self.next_list = 0
        self.demo = demo
        self.closed = False
        self.composer = None
        self.last_output = ''
        self.last_snapshot = None
        self.retry = {}
        self.windows = {}
        self.detail_output = {}
        self.detail_due = {}
        self.future = None
        self.executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix='navigator-rpc')
        self.next_observe = 0
        self.observe_cursor = 0
        self.next_publish = 0
        self.next_schedule = 0
        self.maintenance = []
        self.project_commands=[]
        self.next_projects=0
        self.history_focus = set()
        self.failed_message = None
        if not demo:
            self.index.load_desktop(home)
        if demo:
            from demo import seed
            seed(self.index)
            self.connected = True
            self.message = 'Demo data · no Codex connection'

    def emit(self, obj):
        text=json.dumps(obj, ensure_ascii=False, default=str)
        # A lone surrogate from a damaged file must not raise inside stdout.
        sys.stdout.write(text.encode('utf-8','replace').decode('utf-8')+'\n'); sys.stdout.flush()

    def publish(self):
        try:
            snapshot=self.index.snapshot(self.connected,self.message)
            self.last_snapshot=snapshot
        except Exception:
            # A projection failure must not recursively crash the error handler or
            # send an empty replacement for the user's last good session list.
            if self.last_snapshot is None:
                self.emit({'type':'status','connected':False,'message':'Index update failed; retrying with cached history.'})
                return
            snapshot=dict(self.last_snapshot,connected=False,message='Index update failed; showing last available history.',
                          sessions=[dict(s,status='Status stale',activeStart=0) if s['status']=='Running' else s for s in self.last_snapshot['sessions']])
        previous = self.last_output
        if not isinstance(previous, dict) or snapshot.get('connected') is False and snapshot.get('message','').startswith('Index update failed'):
            self.emit(snapshot)
        elif previous is not snapshot:
            def display(session):
                return {k:v for k,v in session.items() if k != 'lastChecked'}
            old = {v['id']:display(v) for v in previous['sessions']}
            changed = [v for v in snapshot['sessions'] if old.get(v['id']) != display(v)]
            removed = sorted(set(old) - {v['id'] for v in snapshot['sessions']})
            activity = {k:v for k,v in snapshot['activity'].items() if previous['activity'].get(k) != v}
            if changed or removed or activity or previous['projects'] != snapshot['projects']:
                self.emit({'type':'delta','sessions':changed,'removed':removed,'activity':activity,
                           'projects':snapshot['projects'] if previous['projects'] != snapshot['projects'] else None})
            if (previous['connected'],previous['message']) != (snapshot['connected'],snapshot['message']):
                self.emit({'type':'status','connected':snapshot['connected'],'message':snapshot['message']})
        self.last_output = snapshot
        now = time.monotonic()
        for tid in sorted(self.selected):
            version = self.index.turn_version(tid)
            due, last_version = self.detail_due.get(tid, (0, -1))
            if now < due and version == last_version: continue
            self.detail_due[tid] = (now+2, version)
            try:
                detail = dict(type='detail', **self.index.detail(tid))
                if self.detail_output.get(tid) != detail:
                    self.emit(detail); self.detail_output[tid] = detail
            except Exception:
                self.emit({'type':'detailError','id':tid,'message':'Preview unavailable. Try refreshing the index.'})

    def enumeration_request(self):
        records = []
        for archived in (False, True):
            cursor = None; seen = set()
            while not self.closed:
                result = self.rpc.request('thread/list', {'limit':100,'cursor':cursor,'archived':archived,
                    'sortKey':'updated_at','useStateDbOnly':True,
                    'sourceKinds':['cli','vscode','exec','appServer','unknown']})
                records.extend(dict(r, archived=archived) for r in result['data'])
                cursor = result.get('nextCursor')
                if not cursor: break
                if cursor in seen or len(seen) >= 1000: raise RPCError('Codex returned a repeated thread-list cursor.')
                seen.add(cursor)
        return records

    def enumerate(self):
        self.index.load_desktop(self.rpc.home)
        self.index.upsert_metadata(self.enumeration_request())
        self.next_list=time.monotonic()+5

    def hydration_request(self, record):
        tid=record['id']; h=self.index.hydration(tid)
        fingerprint=self.index.fingerprint(tid)
        cursor=h['cursor'] if h['fingerprint']==fingerprint and not h['complete'] else None
        context=(tid,h,fingerprint,cursor,record.get('historyMode') != 'paginated')
        if context[-1]:
            return ('thread/read', {'threadId':tid,'includeTurns':True}, context)
        return ('thread/turns/list',{'threadId':tid,'limit':10,'sortDirection':'desc','itemsView':'full','cursor':cursor},context)

    def apply_hydration(self, context, result):
        tid,h,fingerprint,cursor,legacy=context
        # Enumeration never runs concurrently with hydration, but deleted records may be absent.
        if self.index.fingerprint(tid) != fingerprint: return
        if legacy:
            self.index.cache_page(tid,result['thread'].get('turns',[]),None,fingerprint,True,replace_all=True)
            self.history_focus.discard(tid)
            return
        known={t['id']:t for t in self.index.turns(tid)}
        turns=result.get('data',[]); next_cursor=result.get('nextCursor')
        boundary=h['complete'] and any(t['id'] in known and known[t['id']]['status'] != 'inProgress' for t in turns)
        complete=not next_cursor or boundary
        self.index.cache_page(tid,turns,None if complete else next_cursor,fingerprint,complete,replace_head=cursor is None)
        if complete:self.history_focus.discard(tid)

    def hydrate(self, record):
        method,params,context=self.hydration_request(record)
        self.apply_hydration(context,self.rpc.request(method,params))

    def local_state(self, ids):
        result=[]
        for tid in sorted(set(ids)):
            pref=self.index.db.execute('SELECT data FROM preferences WHERE id=?',(tid,)).fetchone()
            override=self.index.db.execute('SELECT project,baseline FROM overrides WHERE thread=?',(tid,)).fetchone()
            result.append({'id':tid,'preference':json.loads(pref[0]) if pref else None,
                           'override':dict(override) if override else None})
        return result

    def composer_active(self):
        return bool(self.composer and any(client.state.get('active') or client.future
                                          for client in self.composer.clients.values()))

    def reset_index_after_restore(self, database_closed=False):
        """Drop handles/caches that point at the replaced local cache directory."""
        media_access=self.index.media_access
        directory=self.index.directory
        if self.composer:
            self.composer.close()
            self.composer=None
        if not database_closed:
            self.index.db.close()
        self.index=Index(directory,media_access=media_access)
        if not self.demo:
            self.index.load_desktop(self.rpc.home)
        self.last_output='';self.last_snapshot=None
        self.detail_output.clear();self.detail_due.clear();self.retry.clear()
        self.next_list=0;self.next_publish=0;self.next_schedule=0

    def defer_maintenance(self, obj):
        self.maintenance.append(obj)
        self.emit({'type':'maintenancePending','requestID':obj.get('requestID'),
                   'action':obj.get('action'),'message':'Waiting for the current history read to finish.'})

    def run_maintenance(self):
        if self.future or not self.maintenance:
            return
        obj=self.maintenance.pop(0)
        self.handle_command(obj)

    def command(self, obj):
        action=obj.get('action');tid=obj.get('id','')
        if action in ('backup','restoreBackup','rebuildIndex') and self.composer_active():
            raise ValueError('Finish or stop the active Composer task before maintaining the library.')
        if action in ('restoreBackup','rebuildIndex') and self.future:
            self.defer_maintenance(obj)
            return
        ids = (obj.get('ids',[]) if action in ('groupProjects','favouriteMany') else
               list(obj.get('assignments',{})) if action == 'assignMany' else
               [v['id'] for v in obj.get('states',[])] if action == 'restoreLocal' else [tid])
        mutation = action in ('assign','assignMany','restore','preference','groupProjects','restoreLocal','favouriteMany')
        before = self.local_state(ids) if mutation else None
        if action == 'createProject':
            from projects import project_params
            if not self.demo and not self.connected:
                raise ValueError('Connect to Codex before creating a project.')
            params=project_params(obj)
            # Retain an uncertain request's idempotency key across dialog/app restarts.
            import hashlib
            fingerprint=hashlib.sha256((params['name']+'\0'+params['roots'][0]['path']).encode()).hexdigest()
            requests=self.index.preference('__project_creation_requests__')
            params['idempotencyKey']=requests.setdefault(fingerprint,params['idempotencyKey'])
            self.index.save_preference('__project_creation_requests__',requests)
            self.project_commands.append((dict(obj),params))
            return
        if action.startswith('composer'):
            if self.composer is None:
                from composer import ComposerManager
                self.composer = ComposerManager(self.rpc.home, self.index.directory, self.emit, self.composer_thread, demo=self.demo)
            if action == 'composerOpen':
                if tid:
                    record=next((r for r in self.index.records() if r['id']==tid),None)
                    if not record: raise ValueError('This session is no longer available.')
                    obj=dict(obj,cwd=record.get('cwd',''))
                project=obj.get('project','')
                # Resolve desktop legacy IDs to the server identity only for explicit creation.
                if project.startswith('codex:'):
                    legacy=project[6:]
                    mapping=self.index.desktop.get('app-server-project-id-by-legacy-project-id-by-host',{})
                    project=next((m[legacy] for m in mapping.values() if legacy in m),legacy)
                    obj=dict(obj,project=project)
                elif project: obj=dict(obj,project='')
            self.composer.command(obj)
        elif action=='watch':
            window=obj.get('window','default')
            self.windows[window]=set(obj.get('ids',[]))
            if not self.windows[window]: self.windows.pop(window,None)
            old=self.selected
            self.selected=set().union(*self.windows.values()) if self.windows else set()
            for selected in self.selected-old: self.detail_due.pop(selected,None)
            for removed in old-self.selected:
                self.detail_due.pop(removed,None);self.detail_output.pop(removed,None)
        elif action=='mediaAccess':
            self.index.media_access=obj.get('enabled') is True
            if self.index.media_access:self.index.migrate_media()
            else:self.index._deferred_media=True
            self.detail_due.clear();self.detail_output.clear()
            self.index._snapshot_key=None
        elif action=='assign':
            project=obj['project']
            valid={'unassigned'} | {p['id'] for p in self.index.snapshot(self.connected,self.message)['projects']}
            if project not in valid:
                raise ValueError('Project is no longer available')
            self.index.assign(tid,project)
        elif action=='assignMany':
            assignments=obj.get('assignments',{})
            valid={'unassigned'} | {p['id'] for p in self.index.snapshot(self.connected,self.message)['projects']}
            records={r['id']:r for r in self.index.records()}
            if not assignments or any(t not in records or p not in valid for t,p in assignments.items()):
                raise ValueError('Select available sessions and projects')
            with self.index.db:
                for tid,project in assignments.items():
                    baseline=self.index.native_project(records[tid])
                    if project == baseline:
                        self.index.db.execute('DELETE FROM overrides WHERE thread=?',(tid,))
                    else:
                        self.index.db.execute('INSERT OR REPLACE INTO overrides VALUES(?,?,?)',(tid,project,baseline))
        elif action=='favouriteMany':
            ids=obj.get('ids',[]); favourite=obj.get('favourite')
            records={r['id'] for r in self.index.records()}
            if (not isinstance(ids,list) or not ids or len(set(ids)) != len(ids) or
                    any(not isinstance(value,str) or value not in records for value in ids) or
                    not isinstance(favourite,bool)):
                raise ValueError('Select available sessions and a favourite state.')
            with self.index.db:
                for key in ids:
                    pref=self.index.preference(key)
                    pref['favourite']=favourite
                    self.index.db.execute('INSERT OR REPLACE INTO preferences VALUES(?,?)',(key,json.dumps(pref)))
        elif action=='restoreLocal':
            states=obj.get('states',[])
            if any(not isinstance(v.get('id'),str) or v['id'].startswith('__') for v in states):
                raise ValueError('Invalid local undo operation')
            with self.index.db:
                for state in states:
                    key=state['id']
                    if state['preference'] is None: self.index.db.execute('DELETE FROM preferences WHERE id=?',(key,))
                    else: self.index.db.execute('INSERT OR REPLACE INTO preferences VALUES(?,?)',(key,json.dumps(state['preference'])))
                    if state['override'] is None: self.index.db.execute('DELETE FROM overrides WHERE thread=?',(key,))
                    else: self.index.db.execute('INSERT OR REPLACE INTO overrides VALUES(?,?,?)',(key,state['override']['project'],state['override']['baseline']))
        elif action=='groupProjects':
            ids=obj.get('ids',[])
            name=obj.get('name','')
            valid={p['id'] for p in self.index.snapshot(self.connected,self.message)['projects']}
            if not isinstance(ids,list) or not ids or any(not isinstance(i,str) or i not in valid for i in ids):
                raise ValueError('Select available projects')
            if not isinstance(name,str) or len(name.strip())>120:
                raise ValueError('Use a group name of up to 120 characters')
            self.index.group_projects(set(ids),name.strip())
        elif action=='restore':
            self.index.restore_assignment(tid)
        elif action=='preference':
            if not isinstance(tid,str) or not tid or tid.startswith('__'):
                raise ValueError('Invalid preference target')
            pref=self.index.preference(tid)
            for key in ('alias','favourite','colour','name','pinned','group','logoStyle','logoOverview','logoFolder'):
                if key in obj:
                    pref[key]=obj[key]
            if obj.get('resetLogo'):
                for key in ('logo','logoStyle','logoOverview','logoFolder'):
                    pref.pop(key, None)
            if obj.get('logo'):
                path=Path(obj['logo'])
                if path.suffix.lower() not in ('.png','.jpg','.jpeg','.heic','.tiff') or path.stat().st_size>10*1024*1024:
                    raise ValueError('Choose an image smaller than 10 MB')
                import hashlib
                directory=self.index.directory/'logos';directory.mkdir(exist_ok=True)
                dest=directory/(hashlib.sha256(tid.encode()+path.read_bytes()).hexdigest()+path.suffix)
                shutil.copyfile(path,dest)
                pref['logo']=str(dest)
            self.index.save_preference(tid,pref)
        elif action=='search':
            result=self.index.search(obj.get('query'),obj.get('scopeIDs'),obj.get('limit',200))
            self.emit(dict(type='search',requestID=obj.get('requestID'),**result))
        elif action=='conversation':
            result=self.index.conversation(tid,obj.get('cursor'),obj.get('limit',50),obj.get('aroundItemID'))
            # A reader is allowed to prioritise its own durable-history page,
            # but never uses Composer or any write-capable RPC client.
            if result['incomplete']:
                self.history_focus.add(tid)
                if len(self.history_focus)>32:
                    self.history_focus={tid}
            self.emit(dict(type='conversation',requestID=obj.get('requestID'),**result))
        elif action=='backup':
            result=backup_library(self.index.directory,self.index.db,obj.get('path',''),obj.get('uiPreferences'))
            self.emit(dict(type='backup',requestID=obj.get('requestID'),**result))
        elif action=='restoreBackup':
            directory=self.index.directory;media_access=self.index.media_access
            # Closing our handles before the atomic directory replacement keeps
            # SQLite's WAL files out of the restore and works on all supported
            # filesystems. A failed restore immediately reopens the old cache.
            if self.composer:
                self.composer.close();self.composer=None
            self.index.db.close()
            try:
                result=restore_library(directory,obj.get('path',''))
            except Exception:
                self.index=Index(directory,media_access=media_access)
                if not self.demo:self.index.load_desktop(self.rpc.home)
                raise
            self.reset_index_after_restore(database_closed=True)
            self.emit(dict(type='restoreBackup',requestID=obj.get('requestID'),**result))
        elif action=='rebuildIndex':
            self.index.rebuild_history()
            self.next_list=0
            self.emit({'type':'rebuildIndex','requestID':obj.get('requestID'),'message':'History index was cleared. Local organisation and recovery files were kept.'})
        elif action=='diagnostics':
            executable=bool(self.rpc.binary and os.path.isfile(self.rpc.binary) and os.access(self.rpc.binary,os.X_OK))
            running=bool(self.rpc.process and self.rpc.process.poll() is None)
            self.emit(dict(type='diagnostics',requestID=obj.get('requestID'),**self.index.diagnostics(self.connected,executable,running)))
        elif action=='refresh':
            self.next_list=0;self.next_connect=0;self.retry.clear()
        elif action=='newCodex':
            if self.demo or not self.connected:
                raise ValueError('Connect to Codex to create a session')
            # The desktop composer owns creation, ensuring the intended project is selected.
            from urllib.parse import urlencode
            cwd = obj.get('cwd', '')
            if cwd and not Path(cwd).is_dir():
                raise ValueError('The project folder is unavailable: ' + cwd)
            params = {'mode':'codex'}
            if cwd:
                params['path'] = cwd
            if obj.get('project', '').startswith('codex:'):
                params['projectId'] = obj['project'][6:]
            self.emit({'type':'openURL', 'url':'codex://threads/new' + ('?' + urlencode(params) if params else '')})
        elif action=='quit':
            self.closed=True
        if obj.get('requestID'):
            self.emit({'type':'ack','requestID':obj['requestID'],'undo':{'action':'restoreLocal','states':before} if before is not None else None})
        self.publish()

    def handle_command(self, obj):
        if not isinstance(obj, dict):
            self.emit({'type':'error','requestID':None,'message':'Ignored a command that was not a JSON object.'}); return
        try:
            self.command(obj)
        except Exception as exc:
            self.emit({'type':'error','requestID':obj.get('requestID'),'message':str(exc)})

    def composer_thread(self, thread):
        self.index.upsert_metadata([thread],complete=False)
        self.next_list=0;self.next_publish=0

    def run_project_command(self):
        if self.future or not self.project_commands: return
        from projects import create_project
        obj,params=self.project_commands.pop(0)
        if self.demo:
            import uuid
            project=dict(id='demo-project-'+str(uuid.uuid4()),name=params['name'],roots=params['roots'])
            self.finish_project_creation(obj,project)
        else:
            self.submit('createProject',lambda:create_project(self.rpc,params),obj)

    def finish_project_creation(self, obj, project):
        self.index.cache_server_projects([project])
        self.next_projects=0;self.next_list=0
        self.publish()
        key=self.index.canonical_project('codex:'+project['id'])
        item=next(p for p in self.index.snapshot(self.connected,self.message)['projects'] if p['id']==key)
        self.emit(dict(type='projectCreated',requestID=obj.get('requestID'),project=item))

    def connect(self):
        self.rpc.connect()
        if self.closed:self.rpc.close()

    def submit(self, kind, call, context=None):
        self.future=(kind,self.executor.submit(call),context)

    def scheduler_pass(self):
        if self.composer: self.composer.tick()
        now=time.monotonic()
        if self.future and self.future[1].done():
            kind,future,context=self.future;self.future=None
            try:
                result=future.result()
                if kind=='connect': self.connected=True;self.next_list=0
                elif kind=='list':
                    self.index.upsert_metadata(result);self.next_list=now+5
                elif kind=='hydrate': self.apply_hydration(context,result)
                elif kind=='projects': self.index.cache_server_projects(result,replace=True);self.next_projects=now+30
                elif kind=='createProject': self.finish_project_creation(context,result)
            except Exception as exc:
                if kind=='createProject':
                    self.emit(dict(type='error',requestID=context.get('requestID'),message='Project creation could not be confirmed: '+str(exc)+'. Retry to check or complete the same request.'))
                elif kind=='projects': self.next_projects=now+60
                elif kind=='hydrate' and self.rpc.process and self.rpc.process.poll() is None:
                    self.index.mark_error(context[0],str(exc));self.retry[context[0]]=time.time()+60
                else:
                    self.connected=False;self.message='Offline · cached history — '+str(exc)
                    self.next_connect=now+15
            self.next_publish=0;self.next_schedule=0
        # Maintenance waits for an in-flight read, then runs before a
        # scheduler pass can start another RPC request.
        self.run_maintenance()
        self.run_project_command()
        if not self.demo:
            if not self.connected and not self.future and now>=self.next_connect:
                self.submit('connect',self.connect)
            if self.connected and now>=self.next_schedule:
                self.next_schedule=now+0.5
                while not self.rpc.events.empty():
                    event=self.rpc.events.get_nowait()
                    if event.get('method','').startswith(('thread/','turn/','item/')): self.next_list=0
                    if event.get('method') == 'project/changed': self.next_projects=0
                records=self.index.records()
                if now>=self.next_observe:
                    deadline=time.monotonic()+0.006
                    for _ in range(len(records)):
                        if not self.commands.empty() or time.monotonic()>=deadline: break
                        if not records: break
                        self.observe_cursor %= len(records)
                        self.index.observe(records[self.observe_cursor]);self.observe_cursor+=1
                    self.next_observe=now+0.2
                if not self.future:
                    if now>=self.next_projects:
                        from projects import list_projects
                        self.submit('projects',lambda:list_projects(self.rpc))
                    elif now>=self.next_list:
                        self.index.load_desktop(self.rpc.home)
                        self.submit('list',self.enumeration_request)
                    else:
                        candidates=[]
                        for r in records:
                            h=self.index.hydration(r['id'])
                            obs=self.index.observation(r['id'])
                            active=self.index.latest_status(r['id'])=='inProgress' or bool(obs.get('start') and time.time()-obs.get('freshAt',0)<30)
                            if time.time()<self.retry.get(r['id'],0): continue
                            if not h['complete'] or h['fingerprint']!=self.index.fingerprint(r['id']) or (active and time.time()-h['checked']>2):
                                candidates.append(((r['id'] not in self.selected and r['id'] not in self.history_focus,
                                                    not active,-r.get('updatedAt',0)),r))
                        if candidates:
                            r=min(candidates,key=lambda pair:pair[0])[1]
                            method,params,context=self.hydration_request(r)
                            self.submit('hydrate',lambda:self.rpc.request(method,params),context)
                done=sum(self.index.hydration(r['id'])['complete'] for r in records)
                self.message=f'Live · {done} of {len(records)} sessions indexed'
        if now>=self.next_publish:
            self.publish();self.next_publish=now+0.2

    def run(self):
        self.publish()
        try:
            while not self.closed:
                # UI commands always run on the SQLite owner before background results.
                for _ in range(32):
                    try: self.handle_command(self.commands.get_nowait())
                    except queue.Empty: break
                if self.closed: break
                try:
                    self.scheduler_pass()
                    if self.failed_message is not None:
                        self.message=self.failed_message;self.failed_message=None;self.next_publish=0
                except Exception as exc:
                    # Keep IPC alive on a locked/full database or a corrupt cached row; retry shortly.
                    message='Index update failed; retrying — '+str(exc)
                    if message != self.message:
                        if self.failed_message is None: self.failed_message=self.message
                        self.message=message
                        self.emit({'type':'status','connected':self.connected,'message':self.message})
                    self.next_schedule=self.next_publish=time.monotonic()+2
                    try: self.handle_command(self.commands.get(timeout=1))
                    except queue.Empty: pass
                try: self.handle_command(self.commands.get(timeout=0.05))
                except queue.Empty: pass
        finally:
            if self.composer: self.composer.close()
            self.rpc.close()
            self.executor.shutdown(wait=False,cancel_futures=True)


def main():
    parser=argparse.ArgumentParser()
    parser.add_argument('--home',default=os.environ.get('CODEX_HOME',str(Path.home()/'.codex')))
    parser.add_argument('--cache',default=str(Path.home()/'Library/Application Support/Codex Navigator'))
    parser.add_argument('--demo',action='store_true')
    parser.add_argument('--defer-media-access',action='store_true')
    args=parser.parse_args()
    os.umask(0o077)
    worker=Worker(args.home,args.cache,args.demo,media_access=not args.defer_media_access)
    import signal
    signal.signal(signal.SIGTERM,lambda *_:worker.commands.put({"action":"quit"}))
    def read_commands():
        for line in sys.stdin:
            try:
                obj=json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict): worker.commands.put(obj)
        worker.commands.put({'action':'quit'})
    threading.Thread(target=read_commands,daemon=True).start()
    worker.run()


if __name__=='__main__':
    main()
