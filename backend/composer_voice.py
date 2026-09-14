"""Opt-in Codex realtime transport. Audio is transient and never recovery state."""
import base64
from concurrent.futures import ThreadPoolExecutor
import queue
from pathlib import Path
import uuid

class ComposerVoice:
    def __init__(self, owner):
        self.owner=owner
        self.pool=ThreadPoolExecutor(max_workers=1, thread_name_prefix='navigator-voice')
        self.results=queue.Queue()
        self.pending=0
        self.generation=0
        self.stopping=False
        self.transcripts={}
        self.canonical=False
        self.thread_id=""
        self.fallback_ids=set()

    @property
    def busy(self):
        return self.owner.state.get('voiceStatus') in {'starting','active','stopping'}

    def command(self, obj):
        c=self.owner
        action=obj['action']
        if action == 'composerVoiceStart':
            if self.busy: raise ValueError('A voice session is already open.')
            if c.future or c.state['active'] or c.observing or c.state['status']=='disconnected':
                raise ValueError('Wait for this task to be ready before starting voice chat.')
            self.generation+=1;self.stopping=False;self.transcripts={};self.canonical=False
            cwd=c.state['cwd']
            if not cwd:
                cwd=str(c.directory/'tasks'/uuid.uuid4().hex)
                Path(cwd).mkdir(parents=True)
            if not Path(cwd).is_absolute() or not Path(cwd).is_dir(): raise ValueError('Choose an available working folder.')
            self.thread_id=c.state['threadId'];self.fallback_ids=set()
            c.change(cwd=cwd,voiceStatus='starting',voiceError='',voiceID=obj.get('voiceID',''))
            def start():
                reconnected=c.ensure_connection()
                if not self.thread_id:
                    params=dict(cwd=cwd,sandbox='workspace-write',approvalPolicy='on-request',approvalsReviewer='user')
                    if c.state['project']: params['projectId']=c.state['project']
                    thread=c.rpc.request('thread/start',params)['thread']
                    self.thread_id=thread['id']
                    c.rpc.events.put({'method':'thread/started','params':{'thread':thread}})
                elif reconnected:
                    c.rpc.request('thread/resume', {'threadId':self.thread_id,'excludeTurns':True})
                    c.loaded_connection=c.rpc.process
                return c.rpc.request('thread/realtime/start', {
                    'threadId':self.thread_id, 'outputModality':'audio', 'transport':{'type':'websocket'}})
            self.submit('start',start)
        elif action == 'composerVoiceStop':
            if obj.get('voiceID') == c.state.get('voiceID'): self.stop()
        elif action == 'composerVoiceAudio':
            if c.state.get('voiceStatus') != 'active' or obj.get('voiceID') != c.state.get('voiceID'): return
            audio=obj.get('audio') or {}
            try: data=base64.b64decode(audio.get('data',''),validate=True)
            except (ValueError,TypeError): raise ValueError('Invalid voice audio.')
            if audio.get('sampleRate')!=24000 or audio.get('numChannels')!=1 or not data or len(data)>48000 or len(data)%2:
                raise ValueError('Invalid voice audio format.')
            if self.pending>=12:
                c.change(voiceError='Voice connection is too slow. Please reconnect voice chat.')
                self.stop()
                return
            tid=c.state['threadId']
            self.submit('audio',lambda:None if self.stopping else c.rpc.request('thread/realtime/appendAudio',{'threadId':tid,'audio':audio}))

    def submit(self, kind, fn):
        generation=self.generation
        self.pending+=1
        future=self.pool.submit(fn)
        future.add_done_callback(lambda value:self.results.put((generation,kind,value)))

    def stop(self):
        if not self.busy or self.stopping: return
        self.stopping=True
        self.owner.change(voiceStatus='stopping')
        self.submit('stop',lambda:self.owner.rpc.request('thread/realtime/stop',{'threadId':self.thread_id}) if self.thread_id else None)

    def tick(self):
        while not self.results.empty():
            generation,kind,future=self.results.get_nowait();self.pending-=1
            if generation != self.generation: continue
            try:
                future.result()
                if kind=='start' and not self.stopping and self.owner.state.get('voiceStatus')=='starting':
                    self.owner.change(voiceStatus='active')
                elif kind=='stop': self.owner.change(voiceStatus='idle')
            except Exception as exc:
                self.owner.change(voiceError='Voice chat unavailable: '+str(exc))
                if kind=='start':
                    # A timeout may still have started the server session.
                    self.stop()
                elif kind=='audio': self.stop()
                else: self.owner.change(voiceStatus='error')

    def event(self, method, p):
        c=self.owner
        if method=='thread/realtime/error':
            c.change(voiceError=p.get('message','Voice connection failed.'))
            self.stop()
        elif method=='thread/realtime/closed':
            c.change(voiceStatus='error' if c.state.get('voiceError') else 'idle')
        elif method=='thread/realtime/outputAudio/delta' and c.state.get('voiceStatus')=='active':
            c.emit(dict(type='composerVoiceAudio',taskKey=c.state.get('taskKey',''),voiceID=c.state.get('voiceID',''),audio=p.get('audio',{})))
        elif method in {'thread/realtime/item/started','thread/realtime/item/completed'}:
            item=p.get('item',{})
            if item.get('type')=='transcriptSegment':
                if not self.canonical:
                    c.state['messages']=[m for m in c.state['messages'] if m['id'] not in self.fallback_ids]
                self.canonical=True
                c.message('voice-'+item['id'], 'You' if item.get('role')=='user' else 'Codex',item.get('text',''),phase='final_answer')
        elif method=='thread/realtime/item/transcript/delta':
            mid='voice-'+p['itemId']
            existing=next((m for m in c.state['messages'] if m['id']==mid),None)
            if existing: c.message(mid,existing['role'],p.get('delta',''),True)
        elif method in {'thread/realtime/transcript/delta','thread/realtime/transcript/done'} and not self.canonical:
            role=p.get('role','assistant')
            mid=self.transcripts.setdefault(role,'voice-'+uuid.uuid4().hex)
            self.fallback_ids.add(mid)
            c.message(mid,'You' if role=='user' else 'Codex',p.get('delta',p.get('text','')),
                      append=method.endswith('/delta'),phase='final_answer')
            if method.endswith('/done'): self.transcripts.pop(role,None)

    def close(self):
        self.generation+=1
        self.pool.shutdown(wait=False,cancel_futures=True)
