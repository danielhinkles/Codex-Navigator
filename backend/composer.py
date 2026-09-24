"""Execution client, separate from the read-only index and local organisation.

Only explicit Composer commands start turns or reply to a server request. All
state changes happen on the worker thread; blocking RPC runs on a separate pool.
"""
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import queue
import re
import time
import threading
import uuid
from rpc import CodexRPC, RPCError
from composer_voice import ComposerVoice

ACTIVE = {'starting', 'reconnecting', 'running', 'approval', 'stopping'}
APPROVALS = {'item/commandExecution/requestApproval', 'item/fileChange/requestApproval',
             'item/permissions/requestApproval'}
IDLE_TRANSPORT_SECONDS = 60


class Composer:
    def __init__(self, home, directory, emit, on_thread, rpc=None, demo=False):
        self.rpc = rpc or CodexRPC(home, interactive=True)
        self.directory = Path(directory)
        self.path = self.directory / 'composer.json'
        self.emit, self.on_thread = emit, on_thread
        self.demo = demo
        self.pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix='navigator-composer')
        self.future = None
        self.closed = threading.Event()
        self.finished = set()
        self.reasoning_parts = {}
        self.pending = {}
        self.dirty = True
        self.next_publish = 0
        self.next_save = 0
        self.stop_requested = False
        self.stop_sent = False
        self.loaded_connection = None
        self.observing = False
        self.next_observe = 0
        self.reconnect_attempts = 0
        self.next_reconnect = None
        self.state = self.empty()
        self.voice = ComposerVoice(self)
        try:
            saved = json.loads(self.path.read_text())
            if isinstance(saved, dict) and isinstance(saved.get('messages'), list):
                saved['messages'] = [m for m in saved['messages'] if isinstance(m, dict) and isinstance(m.get('id'), str)]
                self.state.update({k:v for k,v in saved.items() if k in self.state})
                self.state.update(approvals=[], active=False, voiceStatus='idle', voiceError='', voiceID='', status='disconnected' if saved.get('threadId') else 'idle',
                                  error='Reconnect to check this task before continuing.' if saved.get('threadId') else '')
        except (OSError, ValueError):
            pass

    @staticmethod
    def empty():
        return dict(type='composer', threadId='', turnId='', title='New task', cwd='', project='',
                    status='idle', active=False, error='', messages=[], approvals=[], revision=0, models=[], skills=[], plugins=[], capabilityError='', effectiveModel='', effectiveEffort='',
                    metadataLoading=False, tokenUsage=None, fiveHourUsage=None, observing=False, workStartedAt=None, voiceStatus="idle", voiceError="", voiceID="")

    def change(self, **values):
        status = values.get('status', self.state['status'])
        turn = values.get('turnId')
        if status in ACTIVE and (
            status == 'starting' and self.state['status'] != 'starting'
            or not self.state.get('workStartedAt')
            or turn and turn != self.state['turnId'] and self.state['status'] not in {'starting', 'reconnecting'}
        ):
            self.state['workStartedAt'] = time.time()
        self.state.update(values)
        self.state['active'] = self.state['status'] in ACTIVE
        self.dirty = True

    def ensure_connection(self):
        if self.closed.is_set(): raise ValueError('Composer is closed.')
        reconnected=False
        if not self.rpc.process or self.rpc.process.poll() is not None:
            self.rpc.connect()
            if self.closed.is_set():
                self.rpc.close()
                raise ValueError('Composer is closed.')
            reconnected=True
        account = self.rpc.request('account/read', {})
        if not account.get('account') and account.get('requiresOpenaiAuth', True):
            raise ValueError('Sign in to Codex, then reconnect Composer.')
        return reconnected

    def submit(self, kind, fn):
        if self.future:
            raise ValueError('Composer is still connecting. Please wait.')
        self.future = (kind, self.pool.submit(fn))

    def command(self, obj):
        action = obj['action']
        if action.startswith('composerVoice'):
            self.voice.command(obj)
            return
        if action == 'composerOpen':
            if self.future: raise ValueError('Composer is still connecting. Please wait.')
            if self.state['active']:
                raise ValueError('Finish or stop the current Composer task before opening another.')
            tid = obj.get('id', '')
            if tid and tid == self.state['threadId'] and self.state['status'] != 'disconnected':
                return
            self.pending.clear()
            self.state = self.empty()
            self.change(threadId=tid, cwd=obj.get('cwd', ''), project=obj.get('project', ''),
                        title=obj.get('title') or 'New task')
            if tid: self.reconnect()

        elif action == 'composerRefresh':
            self.refresh_capabilities()
        elif action == 'composerReconnect':
            if self.future or self.state['status'] in {'running','approval','stopping'}:
                raise ValueError('Composer already has an active connection.')
            self.reconnect()
        elif action == 'composerSend':
            if self.future: raise ValueError('Composer is still connecting. Please wait.')
            if self.observing: raise ValueError('This task is owned by another Codex window. Wait for it to release the task.')
            options = self.turn_options(obj)
            text = obj.get('text', '').strip()
            if (not text and not obj.get('attachments')) or len(text) > 200000:
                raise ValueError('Enter a prompt of up to 200,000 characters.')
            if self.state['active'] or self.state['status'] == 'disconnected':
                raise ValueError('Reconnect, or wait for the current task to finish.')
            if not text: text = 'Please review the attached items.'
            cwd = self.state['cwd']
            if not cwd:
                # Projectless work gets its own folder, never Navigator's source directory.
                cwd = str(self.directory / 'tasks' / uuid.uuid4().hex)
                Path(cwd).mkdir(parents=True)
            if not Path(cwd).is_absolute() or not Path(cwd).is_dir():
                raise ValueError('Choose an available working folder.')
            self.stop_requested = False
            self.stop_sent = False
            self.change(cwd=cwd, status='starting', error='', turnId='')
            display_text='\n'.join([text]+[v['text'] for v in options['input'] if v.get('type') == 'text'])
            self.message('local-user-'+uuid.uuid4().hex, 'You', display_text, attachments=obj.get('attachments', []))
            if self.demo:
                self.change(threadId='demo-composer', turnId='demo-turn', status='running')
                self.demo_due = time.monotonic()+0.3
                return
            tid, project = self.state['threadId'], self.state['project']
            def start():
                reconnected=self.ensure_connection()
                if self.closed.is_set(): raise ValueError('Composer closed before submission.')
                if not tid:
                    params = dict(cwd=cwd, sandbox='workspace-write', approvalPolicy='on-request', approvalsReviewer='user')
                    if project: params['projectId'] = project
                    result = self.rpc.request('thread/start', params)
                    thread = result['thread']
                    self.loaded_connection = self.rpc.process
                    # Queue the durable ID before turn/start: even a lost start response
                    # must never cause an automatic retry/new duplicate task.
                    self.rpc.events.put({'method':'thread/started','params':{'thread':thread}})
                    thread_id = thread['id']
                else:
                    if reconnected:
                        self.rpc.request('thread/resume', {'threadId':tid,'excludeTurns':True})
                        self.loaded_connection = self.rpc.process
                    current=self.rpc.request('thread/read', {'threadId':tid,'includeTurns':False})['thread']
                    if current.get('status',{}).get('type')=='active':
                        raise ValueError('This task is already running in Codex. Reconnect to follow it.')
                    thread_id = tid
                if self.closed.is_set(): raise ValueError('Composer closed before submission.')
                return self.rpc.request('turn/start', dict(threadId=thread_id, input=[{'type':'text','text':text}] + options.pop('input'), **options))
            self.submit('send', start)
        elif action == 'composerStop':
            if self.observing: raise ValueError('This task is running in another Codex window. Stop it there.')
            if not self.state['active']: return
            self.stop_requested = True
            self.change(status='stopping')
            for token in list(self.pending): self.reply(token, accept=False, answers={}, cancelling=True)
            if self.demo:
                self.change(status='interrupted');return
            # The tick sends the interrupt after any pending start returns.
        elif action == 'composerReply':
            self.reply(obj.get('token'), obj.get('accept') is True, obj.get('answers', {}), choice=obj.get('choice'))

    def turn_options(self, obj):
        model, effort = obj.get('model', ''), obj.get('effort', '')
        result = {'input': self.attachment_inputs(obj.get('attachments', [])), 'summary':'auto'}
        if model:
            entry = next((m for m in self.state['models'] if m['model'] == model), None)
            if not entry: raise ValueError('Refresh and choose an available model.')
            result['model'] = model
            if effort:
                if effort not in entry['efforts']: raise ValueError('Choose a supported effort level.')
                result['effort'] = effort
        elif effort:
            raise ValueError('Select a model before choosing effort.')
        for path in dict.fromkeys(obj.get('skills', [])):
            skill = next((s for s in self.state['skills'] if s['path'] == path and s['enabled']), None)
            if not skill: raise ValueError('A selected skill is unavailable. Refresh skills before sending.')
            result['input'].append(dict(type='skill', name=skill['name'], path=path))
        return result

    @staticmethod
    def attachment_inputs(attachments):
        if not isinstance(attachments, list):
            raise ValueError('Attachments must be a list.')
        result=[]
        for attachment in attachments:
            if not isinstance(attachment, dict): raise ValueError('Invalid attachment.')
            kind, path = attachment.get('kind'), attachment.get('path')
            if not isinstance(path, str) or not path or '\x00' in path:
                raise ValueError('An attachment has no valid path.')
            if kind in ('url','remoteImage'):
                from urllib.parse import urlparse
                parsed=urlparse(path)
                if parsed.scheme not in ('http','https') or not parsed.netloc:
                    raise ValueError('Only HTTP and HTTPS links are supported.')
                result.append(dict(type='image',url=path) if kind == 'remoteImage' else dict(type='text',text='Attached web reference: '+json.dumps(path,ensure_ascii=False)))
            elif kind in ('image','file'):
                source=Path(path)
                if not source.is_absolute() or not source.exists() or not (source.is_file() or source.is_dir()):
                    raise ValueError('Attachment is missing or unavailable: '+path)
                if kind == 'image':
                    if not source.is_file(): raise ValueError('Image attachment must be a file.')
                    result.append(dict(type='localImage',path=path))
                else:
                    result.append(dict(type='text',text='Attached local '+('folder' if source.is_dir() else 'file')+' reference (read this item as needed): '+json.dumps(path,ensure_ascii=False)))
            else: raise ValueError('Unsupported attachment kind: '+str(kind))
        return result

    def capabilities(self, cwd):
        result = dict(models=[], skills=[], plugins=[], capabilityError='')
        errors = []
        try:
            cursor = None
            while True:
                page = self.rpc.request('model/list', dict(limit=100, includeHidden=False, cursor=cursor))
                result['models'].extend(dict(model=m['model'], name=m.get('displayName') or m['model'],
                    defaultEffort=m.get('defaultReasoningEffort'), isDefault=m.get('isDefault', False),
                    efforts=[e['reasoningEffort'] for e in m.get('supportedReasoningEfforts', [])]) for m in page.get('data', []))
                cursor = page.get('nextCursor')
                if not cursor: break
        except Exception as exc:
            result['models'] = self.state.get('models', [])
            errors.append('Model choices unavailable: '+str(exc))
        try:
            config = self.rpc.request('config/read', dict(includeLayers=False, cwd=cwd or None)).get('config', {})
        except Exception:
            config = {}
        default = next((m for m in result['models'] if m.get('isDefault')), None)
        result['effectiveModel'] = self.state.get('effectiveModel') or config.get('model') or (default or {}).get('model', '')
        entry = next((m for m in result['models'] if m['model'] == result['effectiveModel']), None)
        result['effectiveEffort'] = self.state.get('effectiveEffort') or config.get('model_reasoning_effort') or (entry or {}).get('defaultEffort') or ''
        try:
            page = self.rpc.request('skills/list', dict(cwds=[cwd] if cwd else [], forceReload=True))
            result['skills'] = [dict(name=s['name'], path=s['path'], description=s.get('description',''), enabled=s.get('enabled',False))
                for entry in page.get('data',[]) for s in entry.get('skills',[])]
            if any(entry.get('errors') for entry in page.get('data', [])): errors.append('Some skills could not be loaded')
        except Exception: errors.append('Skills unavailable')
        try:
            page = self.rpc.request('plugin/installed', dict(cwds=[cwd] if cwd else []))
            result['plugins'] = [dict(name=(p.get('interface') or {}).get('displayName') or p['name'], enabled=p['enabled'])
                for market in page.get('marketplaces',[]) for p in market.get('plugins',[]) if p.get('installed')]
        except Exception: errors.append('Plugin inventory unavailable')
        try:
            result['fiveHourUsage'] = self.five_hour(self.rpc.request('account/rateLimits/read', {}))
        except Exception:
            result['fiveHourUsage'] = None
            errors.append('Account limits unavailable')
        result['capabilityError'] = ' · '.join(errors)
        return result

    @staticmethod
    def five_hour(params):
        buckets = params.get('rateLimitsByLimitId') or {}
        bucket = buckets.get('codex') or params.get('rateLimits') or {}
        for key in ('primary', 'secondary'):
            window = bucket.get(key) or {}
            if window.get('windowDurationMins') == 300:
                return window
        return None

    def refresh_capabilities(self):
        if self.future or self.voice.busy: return
        if self.demo: return
        cwd = self.state['cwd']
        self.change(metadataLoading=True)
        def read():
            self.ensure_connection()
            return self.capabilities(cwd)
        self.submit('capabilities', read)

    def reconnect(self):
        tid = self.state['threadId']
        self.change(status='reconnecting', error='')
        if self.demo:
            self.change(status='idle');return
        def resume():
            self.ensure_connection()
            if not tid: return None
            try:
                if self.loaded_connection is self.rpc.process:
                    result = self.rpc.request('thread/read', {'threadId':tid, 'includeTurns':False})
                else:
                    result = self.rpc.request('thread/resume', {'threadId':tid, 'excludeTurns':True})
                    self.loaded_connection = self.rpc.process
                self.observing = False
            except Exception as exc:
                if 'active writer' not in str(exc).lower(): raise
                # Another app owns execution. Read its durable history without
                # stealing ownership, retrying a prompt, or reporting a disconnect.
                result = self.rpc.request('thread/read', {'threadId':tid, 'includeTurns':False})
                self.observing = True
            page = self.rpc.request('thread/turns/list', {'threadId':tid,'limit':10,'sortDirection':'desc','itemsView':'full'})
            return result['thread'], list(reversed(page.get('data', []))), result.get('model'), result.get('reasoningEffort')
        self.submit('resume', resume)

    def interrupt(self):
        if self.future: return  # turn/start result will supply the turn ID.
        tid, turn = self.state['threadId'], self.state['turnId']
        if tid and turn:
            self.stop_sent = True
            self.submit('stop', lambda:self.rpc.request('turn/interrupt', {'threadId':tid,'turnId':turn}))

    def respond(self, serial, result=None, error=None):
        try: self.rpc.respond(serial, result=result, error=error)
        except RPCError: pass  # Server already gone; tick() reports the disconnect.

    def message(self, mid, role, text, append=False, attachments=None, **metadata):
        messages = self.state['messages']
        existing = next((v for v in messages if v['id'] == mid), None)
        if existing:
            existing['text'] = (existing['text'] + text if append else text)[-100000:]
        else:
            messages.append(dict(id=mid, role=role, text=text[-100000:]))
            del messages[:-200]
        target=next(v for v in messages if v['id'] == mid)
        target.update(metadata)
        if attachments is not None:
            target=next(v for v in messages if v['id'] == mid)
            target['attachments']=[dict(a,id=mid+'-attachment-'+str(i)) for i,a in enumerate(attachments)]
        # Bound the live viewport; full history remains in Codex's durable task.
        while len(messages)>1 and sum(len(m['text']) for m in messages)>1000000:
            messages.pop(0)
        self.dirty = True

    def work_item(self, turn, completed=False, historical=False):
        mid='work-'+turn['id']
        existing=next((m for m in self.state['messages'] if m['id']==mid), {})
        started=turn.get('startedAt') or existing.get('startedAt') or (None if historical else self.state.get('workStartedAt'))
        ended=turn.get('completedAt') or existing.get('completedAt') or (time.time() if completed and not historical else None)
        duration=turn.get('durationMs')
        duration=duration/1000 if duration is not None else max(0, ended-started) if ended and started else None
        self.message(mid, 'Work', '', startedAt=started, completedAt=ended, durationSeconds=duration)
        if started and not completed: self.state['workStartedAt']=started

    def item(self, item):
        kind, mid = item.get('type'), item.get('id', '')
        if not mid: return
        if kind == 'agentMessage': self.message(mid, 'Codex', item.get('text', ''), phase=item.get('phase'))
        elif kind == 'reasoning':
            # Only the API's readable summaries belong in the UI.
            summary=item.get('summary') or []
            if summary:
                self.reasoning_parts[mid]={i:text for i,text in enumerate(summary)}
                self.message(mid, 'Thinking', '\n\n'.join(summary))
        elif kind == 'contextCompaction': self.message(mid, 'Activity', 'Conversation context compacted')
        elif kind == 'userMessage':
            text = '\n'.join(v.get('text','') for v in item.get('content',[]) if v.get('type') == 'text')
            # Replace the optimistic submitted message with its server identity.
            local = next((m for m in reversed(self.state['messages']) if m['id'].startswith('local-user-') and m['text'] == text), None)
            if local: local['id'] = mid
            attached=[dict(path=v['path'],name=Path(v['path']).name,kind='image') for v in item.get('content',[]) if v.get('type') == 'localImage' and v.get('path')]
            self.message(mid, 'You', text, attachments=attached if not local else None)
        elif kind == 'commandExecution':
            self.message(mid, 'Command', (item.get('command') or '')+'\n'+(item.get('aggregatedOutput') or '')+'\n'+item.get('status',''))
        elif kind == 'fileChange':
            self.message(mid, 'File changes', '\n\n'.join(v.get('path','')+'\n'+v.get('diff','') for v in item.get('changes',[])))
        elif kind == 'plan': self.message(mid, 'Plan', item.get('text',''))
        elif kind in ('mcpToolCall','dynamicToolCall','webSearch'):
            self.message(mid, 'Activity', (item.get('tool') or kind)+' · '+item.get('status',''))

    def event(self, event):
        if event.get('_connection') is not None and event['_connection'] != self.rpc.connection:
            return  # Never reply to an old connection's approval ID on a new server.
        method, p = event.get('method',''), event.get('params') or {}
        if not isinstance(method, str) or not isinstance(p, dict):
            if 'id' in event: self.respond(event['id'], error='Navigator could not read this request.')
            return
        thread = p.get('thread') if isinstance(p.get('thread'), dict) else {}
        tid = p.get('threadId') or thread.get('id')
        if tid and self.state['threadId'] and tid != self.state['threadId']:
            if 'id' in event: self.respond(event['id'], error='This request is not for the active Composer task.')
            return
        if method.startswith('thread/realtime/'):
            self.voice.event(method,p)
            return
        if 'id' in event:
            if method not in APPROVALS | {'item/tool/requestUserInput'}:
                self.respond(event['id'], error='Navigator does not support this interactive request: '+method)
                self.change(error='Codex requested an unsupported interaction ('+method+'). Open the task in Codex to continue.')
                return
            token = json.dumps(event['id'])
            self.pending[token] = event
            questions = p.get('questions', []) if method == 'item/tool/requestUserInput' else []
            self.state['approvals'].append(dict(id=token, title='Codex needs your input' if questions else 'Approval required',
                detail=self.request_detail(p),
                choices=self.approval_choices(method, p), questions=questions, canAccept=not p.get('availableDecisions') or 'accept' in p['availableDecisions']))
            self.change(status='approval', turnId=p.get('turnId') or self.state['turnId'])
            if self.stop_requested: self.reply(token, False, {}, cancelling=True)
        elif method == 'thread/tokenUsage/updated':
            self.change(tokenUsage=p.get('tokenUsage'))
        elif method == 'account/rateLimits/updated':
            self.change(fiveHourUsage=self.five_hour(p))
        elif method == 'thread/started':
            thread = p['thread']; self.change(threadId=thread['id'], cwd=thread.get('cwd') or self.state['cwd'])
            self.on_thread(thread)
        elif method == 'turn/started':
            self.change(turnId=p['turn']['id'], status='stopping' if self.stop_requested else 'running')
            self.work_item(p['turn'])
        elif method == 'item/reasoning/summaryTextDelta':
            parts=self.reasoning_parts.setdefault(p['itemId'], {})
            index=p.get('summaryIndex', 0)
            parts[index]=(parts.get(index, '')+p.get('delta', ''))[-100000:]
            self.message(p['itemId'], 'Thinking', '\n\n'.join(parts[i] for i in sorted(parts)))
        elif method == 'item/reasoning/summaryPartAdded':
            self.reasoning_parts.setdefault(p['itemId'], {}).setdefault(p.get('summaryIndex', 0), '')
        elif method == 'item/plan/delta': self.message(p['itemId'], 'Plan', p.get('delta', ''), True)
        elif method == 'turn/plan/updated':
            self.message('plan-'+p['turnId'], 'Plan', '\n'.join(
                ('✓ ' if step.get('status') == 'completed' else '→ ' if step.get('status') == 'inProgress' else '○ ')+step.get('step','')
                for step in p.get('plan', [])))
        elif method == 'turn/diff/updated': self.message('diff-'+p['turnId'], 'File changes', p.get('diff',''))
        elif method == 'item/agentMessage/delta': self.message(p['itemId'], 'Codex', p.get('delta',''), True)
        elif method == 'item/commandExecution/outputDelta': self.message(p['itemId'], 'Command', p.get('delta',''), True)
        elif method in ('item/started','item/completed'): self.item(p.get('item',{}))
        elif method == 'turn/completed':
            turn = p['turn']; self.finished.add(turn['id']); self.pending.clear()
            self.work_item(turn, completed=True)
            self.change(status=turn.get('status','completed'), approvals=[], error=(turn.get('error') or {}).get('message',''))
        elif method == 'serverRequest/resolved':
            token=json.dumps(p.get('requestId'));self.pending.pop(token,None)
            self.change(approvals=[a for a in self.state['approvals'] if a['id'] != token])
            if not self.pending and self.state['status']=='approval': self.change(status='running')
        elif method == 'error':
            self.change(error=(p.get('error') or {}).get('message','Codex reported an error.'))
            if not p.get('willRetry'): self.change(status='failed', approvals=[]); self.pending.clear()

    def request_detail(self, params):
        parts=[]
        for key in ('command','reason','cwd','grantRoot'):
            if params.get(key):
                label={'reason':'','command':'Command\n','cwd':'Working folder\n','grantRoot':'Requested folder access\n'}[key]
                parts.append(label+str(params[key]))
        for key,value in params.items():
            if key not in {'reason','command','cwd','grantRoot','questions','threadId','turnId','itemId','startedAtMs','availableDecisions','approvalId'} and value is not None:
                label=re.sub(r'([a-z])([A-Z])',r'\1 \2',key).capitalize()
                parts.append(label+'\n'+(value if isinstance(value,str) else json.dumps(value,ensure_ascii=False,indent=2)))
        item=next((m for m in self.state['messages'] if m['id']==params.get('itemId') and m['role']=='File changes'),None)
        if item:parts.append('File changes\n'+item['text'])
        return '\n\n'.join(parts) or 'Codex is waiting for your decision.'

    @staticmethod
    def approval_choices(method, params):
        choices = []
        decisions = params.get('availableDecisions')
        if decisions is None and method in {'item/commandExecution/requestApproval', 'item/fileChange/requestApproval'}:
            decisions = ['acceptForSession']
            proposal = params.get('proposedExecpolicyAmendment')
            if method == 'item/commandExecution/requestApproval' and proposal:
                decisions.append({'acceptWithExecpolicyAmendment': {'execpolicy_amendment': proposal}})
        for decision in decisions or []:
            if decision == 'acceptForSession':
                choices.append(dict(id=json.dumps(decision), label='Allow for session'))
            elif isinstance(decision, dict) and 'acceptWithExecpolicyAmendment' in decision:
                choices.append(dict(id=json.dumps(decision), label='Always allow this command rule'))
        if method == 'item/permissions/requestApproval':
            choices.append(dict(id='session', label='Allow for session'))
        return choices

    def reply(self, token, accept, answers, cancelling=False, choice=None):
        event = self.pending.get(token)
        if not event: raise ValueError('This request has already been resolved.')
        p, method = event.get('params',{}), event['method']
        if choice and (not accept or choice not in {c['id'] for c in self.approval_choices(method, p)}):
            raise ValueError('This approval choice is not offered by Codex.')
        if method == 'item/tool/requestUserInput':
            result = {'answers':{}}
            for question in p.get('questions',[]):
                answer = answers.get(question['id'], '').strip()
                if not answer and not cancelling: raise ValueError('Answer each question before continuing.')
                result['answers'][question['id']] = {'answers':[answer] if answer else []}
        elif method == 'item/permissions/requestApproval':
            result = {'permissions':p['permissions'] if accept else {}, 'scope':'session' if choice == 'session' else 'turn'}
        else:
            allowed = p.get('availableDecisions')
            if accept and not choice and allowed and 'accept' not in allowed: raise ValueError('This request does not allow a one-time approval.')
            result = {'decision':json.loads(choice) if choice else 'accept' if accept else 'cancel' if cancelling else 'decline'}
        if not self.demo: self.rpc.respond(event['id'], result=result)
        self.pending.pop(token)
        self.change(approvals=[v for v in self.state['approvals'] if v['id'] != token],
                    status='stopping' if self.stop_requested else 'approval' if self.pending else 'running')
        if self.demo and not cancelling:
            self.message('demo-response','Codex','The demo task is complete. No model request was sent and no project files were changed.')
            self.change(status='completed')

    def tick(self):
        self.voice.tick()
        if self.future and self.future[1].done():
            kind, future = self.future;self.future=None
            try:
                result = future.result()
                if kind == 'capabilities':
                    self.change(**result, metadataLoading=False)
                elif kind == 'resume':
                    self.next_reconnect = None
                    self.reconnect_attempts = 0
                    self.change(status='idle')
                    if result:
                        thread, turns, runtime_model, runtime_effort = result
                        self.change(effectiveModel=runtime_model or self.state.get('effectiveModel', ''), effectiveEffort=runtime_effort or self.state.get('effectiveEffort', ''))
                        self.on_thread(thread)
                        unsent=[m for m in self.state['messages'] if m['id'].startswith('local-user-')]
                        self.change(threadId=thread['id'], cwd=thread.get('cwd') or self.state['cwd'],messages=[])
                        self.reasoning_parts.clear()
                        for turn in turns:
                            for item in turn.get('items',[]): self.item(item)
                            self.work_item(turn, completed=turn.get('status') != 'inProgress', historical=True)
                        for message in unsent:
                            if not any(m['role']=='You' and m['text']==message['text'] for m in self.state['messages']):
                                self.message(message['id'], 'Unconfirmed prompt', message['text'])
                        active = next((v for v in turns if v.get('status') == 'inProgress'), None)
                        if active:
                            self.change(status='running', turnId=active['id'])
                            self.work_item(active)
                        elif thread.get('status',{}).get('type')=='active':
                            self.change(status='disconnected',error='This task is active but its current turn is unavailable. Open it in Codex before continuing.')
                    self.change(observing=self.observing)
                    self.next_observe = time.monotonic()+3
                    if self.observing:
                        self.change(error='This task is owned by another Codex window. Navigator is following its saved progress.')
                    self.refresh_capabilities()
                elif kind == 'send':
                    turn = result['turn']
                    if turn['id'] not in self.finished:
                        self.change(turnId=turn['id'], status='stopping' if self.stop_requested else 'running')
            except Exception as exc:
                if kind == 'capabilities':
                    self.change(metadataLoading=False, capabilityError='Could not load Codex options. Reconnect or refresh to try again.')
                    return
                self.pending.clear()
                # Never retry a turn/start after a timeout: it may already be running.
                self.change(status='disconnected', approvals=[], error=str(exc)+' Reconnect to check the task; your prompt was not automatically resent.')
        if self.next_reconnect is not None and not self.future and time.monotonic() >= self.next_reconnect:
            self.reconnect_attempts += 1
            self.next_reconnect = time.monotonic()+5*self.reconnect_attempts if self.reconnect_attempts < 3 else None
            self.reconnect()
        if self.observing and not self.future and time.monotonic() >= self.next_observe:
            self.reconnect()
        for _ in range(500):
            try: event=self.rpc.events.get_nowait()
            except queue.Empty: break
            try: self.event(event)
            except RPCError: pass  # The lost connection is detected and reported below.
            except Exception as exc:
                # One unexpected notification shape must never take the whole worker down.
                try:
                    if isinstance(event, dict) and 'id' in event:
                        self.pending.pop(json.dumps(event['id']), None)
                        self.respond(event['id'], error='Navigator could not read this request.')
                    self.change(error='Codex sent an event Navigator could not read ('+str(event.get('method','') if isinstance(event, dict) else '')+'): '+str(exc))
                except Exception: pass
        if self.stop_requested and not self.stop_sent and self.state['active'] and self.state['turnId'] and not self.future:
            self.interrupt()
        if not self.demo and (self.state['active'] or self.voice.busy) and not self.future and (not self.rpc.process or self.rpc.process.poll() is not None):
            self.pending.clear();self.change(status='disconnected',voiceStatus='error',approvals=[],error='Connection lost. Reconnecting to check the task; your prompt will not be resent.')
            self.next_reconnect = time.monotonic()+2
        if self.demo and self.state['status']=='running' and time.monotonic()>=getattr(self,'demo_due',float('inf')):
            self.demo_due=float('inf')
            self.message('demo-commentary','Codex','I can work on this task from Navigator. This demonstration pauses for your approval.')
            self.event({'id':1,'method':'item/commandExecution/requestApproval','params':{'threadId':'demo-composer','turnId':'demo-turn','command':'Demo: validate the selected project','reason':'Demonstrates a one-time approval. No command will run.'}})
        if self.dirty and time.monotonic()>=self.next_publish:
            self.state['revision']+=1
            self.emit(self.state)
            # Do not persist secrets entered into input cards or actionable approval IDs.
            saved=dict(self.state, approvals=[])
            if not self.state['active'] or self.state['approvals'] or time.monotonic()>=self.next_save:
                try:
                    temp=self.path.with_suffix('.tmp');temp.write_text(json.dumps(saved,ensure_ascii=False));temp.replace(self.path)
                except OSError:
                    self.state['error']='Composer could not save its recovery cache. Full task history remains in Codex.'
                    self.emit(self.state)
                self.next_save=time.monotonic()+1
            self.next_publish=time.monotonic()+0.15;self.dirty=False

    def close(self):
        self.closed.set()
        self.voice.close()
        if self.state['active']:
            self.change(status='disconnected',approvals=[],error='Navigator closed while this task was active. Reconnect to check its status.')
        saved=dict(self.state, approvals=[])
        try:
            temp=self.path.with_suffix('.tmp');temp.write_text(json.dumps(saved,ensure_ascii=False));temp.replace(self.path)
        except OSError: pass
        self.rpc.close()
        self.pool.shutdown(wait=False,cancel_futures=True)

    def release_idle_transport(self):
        """Release only an unused RPC process; recovery and task files remain."""
        if self.state['active'] or self.future or self.pending or self.voice.busy:
            return False
        if self.rpc.process:
            self.rpc.close()
            self.loaded_connection = None
            return True
        return False


class ComposerManager:
    """Keep each task's transport, approvals and in-flight RPC alive while browsing."""
    def __init__(self, home, directory, emit, on_thread, demo=False, factory=Composer):
        self.home, self.directory = home, Path(directory)
        self.emit, self.on_thread, self.demo, self.factory = emit, on_thread, demo, factory
        self.clients = {}
        self.selected = ''
        self.dirty = False
        self.revision = 0
        self.idle_since = {}
        self.manifest_path = self.directory / 'composer-manifest.json'
        self.removed = set()
        self._load_manifest()
        saved_selected = self._manifest.get('selected', '')
        # Recover all task caches without acquiring writers or replaying prompts.
        paths = [self.directory] if (self.directory / 'composer.json').exists() else []
        paths += sorted(path for path in (self.directory / 'composers').glob('*') if path.is_dir())
        for path in paths:
            if (path / 'composer.json').exists():
                key = self._key_for_path(path)
                if key not in self.removed: self.add(path, key)
        if saved_selected in self.clients: self.selected = saved_selected
        self._save_manifest()

    def _load_manifest(self):
        self._manifest = {}
        try:
            value = json.loads(self.manifest_path.read_text())
            if isinstance(value, dict): self._manifest = value
        except (OSError, ValueError): pass
        self.removed = set(v for v in self._manifest.get('removed', []) if isinstance(v, str))

    def _save_manifest(self, required=False):
        self._manifest = {'removed':sorted(self.removed), 'selected':self.selected}
        try:
            self.directory.mkdir(parents=True, exist_ok=True)
            temporary = self.manifest_path.with_suffix('.tmp')
            temporary.write_text(json.dumps(self._manifest, ensure_ascii=False))
            temporary.replace(self.manifest_path)
        except OSError:
            # The task is still usable; only this local presentation choice is
            # not durable. Do not turn a cache failure into an execution error.
            if required:
                raise ValueError('Could not save the local Composer removal. The task was kept visible.')
            return False
        return True

    @staticmethod
    def _key_for_path(path):
        # A recovery directory is immutable local metadata. Its basename is a
        # stable task key across restart and never depends on title/CWD.
        return path.name if path.parent.name == 'composers' else 'legacy-'+uuid.uuid5(uuid.NAMESPACE_URL, str(path.resolve())).hex

    def add(self, path=None, key=None):
        key = key or uuid.uuid4().hex
        path = path or self.directory / 'composers' / key
        path.mkdir(parents=True, exist_ok=True)
        client = self.factory(self.home, path, lambda value: self.changed(value), self.on_thread, demo=self.demo)
        client.state['taskKey'] = key
        client.dirty = True
        self.clients[key] = client
        self.selected = key
        self._save_manifest()
        self.dirty = True
        return client

    def changed(self, value=None):
        if value and value.get("type")=="composerVoiceAudio":
            self.emit(value)
            return
        self.dirty = True

    def command(self, obj):
        action = obj['action']
        if action == 'composerSelect':
            if obj.get('key') not in self.clients: raise ValueError('Task is no longer available.')
            self.selected = obj['key']
            self._save_manifest()
            self.dirty = True
        elif action == 'composerRemoveTask':
            key = obj.get('key', self.selected)
            client = self.clients.get(key)
            if not client: raise ValueError('Task is no longer available.')
            if client.state['active'] or client.future or client.state['approvals'] or client.voice.busy:
                raise ValueError('Stop or finish this active task before removing it from Composer.')
            # Removal is a Navigator-only visibility choice. Keep composer.json
            # and projectless task folders intact for explicit recovery; close
            # only the idle transport and retain the key in a local manifest.
            previous_selected=self.selected
            self.removed.add(key)
            self.selected=next((candidate for candidate in self.clients if candidate != key),'')
            try:
                self._save_manifest(required=True)
            except Exception:
                self.removed.discard(key);self.selected=previous_selected
                raise
            client.close()
            self.clients.pop(key)
            self.dirty = True
        elif action == 'composerOpen':
            tid = obj.get('id')
            match = next((key for key, client in self.clients.items() if tid and client.state['threadId'] == tid), None)
            if match:
                self.selected = match
                client = self.clients[match]
                if client.state['status'] == 'disconnected' and not client.future: client.reconnect()
            else:
                client=self.add()
                client.command(obj)
                client.state['taskKey']=self.selected
                client.dirty=True
            self.dirty = True
        else:
            # A submission carries the editor's task key. Route it to that
            # exact client without changing the visible task, so a switch while
            # a UI acknowledgement is in flight cannot send to the wrong task.
            key = (obj.get('taskKey') or self.selected) if action == 'composerSend' or action.startswith('composerVoice') else self.selected
            if key and key not in self.clients:
                raise ValueError('This Composer task is no longer available.')
            if not key:
                key = self.add().state['taskKey']
            self.clients[key].command(obj)

    def tick(self):
        now=time.monotonic()
        for key, client in self.clients.items():
            client.tick()
            if client.state['active'] or client.future or client.pending:
                self.idle_since.pop(key,None)
                continue
            since=self.idle_since.setdefault(key,now)
            if now-since >= IDLE_TRANSPORT_SECONDS:
                client.release_idle_transport()
        if self.dirty:
            self.revision += 1
            tasks = []
            for key, c in self.clients.items():
                status=c.state['status']
                category='Waiting' if c.state['approvals'] else 'Active' if status in ACTIVE else 'Completed'
                tasks.append(dict(id=key, title=c.state['title'], status=status, needsInput=bool(c.state['approvals']), category=category))
            if self.selected:
                self.emit(dict(self.clients[self.selected].state, tasks=tasks, taskKey=self.selected, revision=self.revision))
            else:
                self.emit(dict(Composer.empty(), tasks=[], taskKey='', revision=self.revision))
            self.dirty = False

    def close(self):
        for client in self.clients.values(): client.close()
