"""Navigator-owned SQLite cache. Codex files are only read, never edited.

Metadata and per-turn projections are separated: a changed thread does not require
re-reading completed history. Assignment overrides carry their remote baseline.
"""
import base64
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
import tempfile
import time
from urllib.parse import unquote, urlparse
from transcript import clean_response, readable_prompt, present_turns

SCHEMA_VERSION = 3
MEDIA_RE = re.compile(r'(?:file://)?/[^\n<>\"\[\]]{1,2048}?\.(?:png|jpe?g|gif|webp|heic|mp4|mov|m4v|pdf)(?=[\s)\]>\"\x27]|$)', re.I)


def valid_media_path(value):
    """Validate new references AND projections cached by older parser versions."""
    if not isinstance(value, str):
        return None
    value = unquote(value[7:]) if value.startswith('file://') else value
    if not value.startswith('/') or any(ord(c) < 32 for c in value):
        return None
    try:
        if len(os.fsencode(value)) >= 1024 or any(len(os.fsencode(p)) > 255 for p in value.split('/')):
            return None
    except UnicodeError:
        return None
    if value.startswith('/ ') or Path(value).suffix.lower() not in ('.png','.jpg','.jpeg','.gif','.webp','.heic','.mp4','.mov','.m4v','.pdf'):
        return None
    return value


def local_file_available(path):
    # Missing, inaccessible, malformed and replaced assets must never kill history.
    try:
        return Path(path).is_file()
    except (OSError, ValueError):
        return False


def file_revision(path):
    try:
        value=os.stat(path)
        return str(value.st_mtime_ns)+':'+str(value.st_size)
    except OSError:
        return 'missing'


def canonical_media(paths, verify=True):
    result=set()
    for raw in paths:
        path=valid_media_path(raw)
        if path is None:continue
        decoded=valid_media_path(unquote(path))
        if verify and decoded and decoded != path and not local_file_available(path) and local_file_available(decoded):
            path=decoded
        result.add(path)
    return sorted(result)


def turn_media(turns):
    return sorted({path for turn in turns for raw in turn['media']
                   for path in [valid_media_path(raw)] if path is not None})


def stamp(value):
    if isinstance(value, (int, float)):
        return value / 1000 if value > 10**11 else float(value)
    if isinstance(value, str):
        try:
            return dt.datetime.fromisoformat(value.replace('Z', '+00:00')).timestamp()
        except ValueError:
            pass
    return 0.0


def project_key(path):
    return 'cwd:' + str(Path(path).expanduser()) if path else 'unassigned'


def media_paths(item):
    """Only index explicit media references, not arbitrary tool output or base64."""
    found = set()
    def visit(value):
        if isinstance(value, dict):
            for key, val in value.items():
                if key in ('path', 'imageUrl', 'image_url', 'url', 'result', 'text') and isinstance(val, str):
                    if val.startswith('data:'):
                        continue
                    if val.startswith('file://'):
                        val = unquote(urlparse(val).path)
                    if val.startswith('/') and Path(val).suffix.lower() in ('.png','.jpg','.jpeg','.gif','.webp','.heic','.mp4','.mov','.m4v','.pdf') and '\n' not in val:
                        found.add(val)
                    # Tool results can contain megabytes of inline image data. Never
                    # run a path expression across an unbounded binary-like string.
                    snippet = val if len(val) <= 32768 else val[:16384] + '\n' + val[-16384:]
                    found.update(MEDIA_RE.findall(snippet))
                elif isinstance(val, (dict, list)):
                    visit(val)
        elif isinstance(value, list):
            for val in value:
                visit(val)
    visit(item)
    return sorted({path for raw in found for path in [valid_media_path(raw)] if path is not None})


def project_turn(turn, verify_media=True):
    prompts, entries, media, changed = [], [], set(), set()
    last = ''
    messages = 0
    start = stamp(turn.get('startedAt'))
    end = stamp(turn.get('completedAt'))
    for item_number,item in enumerate(turn.get('items', [])):
        kind = item.get('type')
        if kind == 'userMessage':
            text = '\n'.join(x.get('text', '') for x in item.get('content', []) if x.get('type') == 'text')
            item_id=item.get('id') or turn['id']+'-item-'+str(item_number)
            value=text or '[Attachment]'
            prompts.append({'id': item_id, 'text': value, 'time': start})
            entries.append({'id':item_id, 'role':'user', 'text':value, 'time':start})
            messages += 1
        elif kind == 'agentMessage':
            last = item.get('text', '')
            entries.append({'id':item.get('id') or turn['id']+'-item-'+str(item_number), 'role':'assistant', 'text':last,
                            'time':end or start})
            messages += 1
        elif kind == 'fileChange':
            for change in item.get('changes', []):
                if change.get('path'):
                    changed.add(change['path'])
        if kind in ('userMessage', 'agentMessage', 'imageGeneration', 'imageView', 'mcpToolCall'):
            media.update(media_paths(item))
    duration = turn.get('durationMs')
    return {'id': turn['id'], 'start': start, 'end': end,
            'seconds': max(0, duration / 1000) if duration is not None else max(0, end-start) if end and start else None,
            'status': turn.get('status', 'unknown'), 'prompts': prompts, 'entries':entries,
            'media': canonical_media(media,verify_media), 'changed': sorted(changed), 'messages': messages, 'last': last}


def fallback_title(text):
    text = readable_prompt(text).strip()
    marker = re.search(r'^## My request:\s*$', text, re.M)
    if marker:
        text = text[marker.end():].strip()
    for line in text.splitlines():
        line = line.strip().lstrip('#').strip()
        if line and line != 'Files mentioned by the user:' and not line.startswith(('/Users/', '/tmp/', 'Distinguish instructions')):
            return line[:120]
    return 'Untitled session'


class Index:
    def __init__(self, directory, media_access=True):
        self.media_access=media_access
        self._deferred_media=not media_access
        self.desktop = {}
        self._turn_cache = {}
        self._projection_cache = {}
        self._presentation_cache = {}
        self._turn_costs = {}
        self._latest_states = {}
        self._summary_cache = {}
        self._snapshot_key = None
        self._snapshot_value = None
        self._snapshot_expiry = 0
        self._media_counts = {}
        self._tail = {}
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(str(self.directory / 'navigator.sqlite'), timeout=5)
        self.db.row_factory = sqlite3.Row
        self.db.executescript('''
            PRAGMA journal_mode=WAL;
            CREATE TABLE IF NOT EXISTS metadata(id TEXT PRIMARY KEY, data TEXT NOT NULL, fingerprint TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS turns(thread TEXT, id TEXT, data TEXT NOT NULL, PRIMARY KEY(thread,id));
            CREATE TABLE IF NOT EXISTS hydration(thread TEXT PRIMARY KEY, fingerprint TEXT, cursor TEXT, complete INTEGER DEFAULT 0, checked REAL DEFAULT 0, error TEXT);
            CREATE TABLE IF NOT EXISTS overrides(thread TEXT PRIMARY KEY, project TEXT NOT NULL, baseline TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS preferences(id TEXT PRIMARY KEY, data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS observations(thread TEXT PRIMARY KEY, data TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS turn_versions(thread TEXT PRIMARY KEY, version INTEGER NOT NULL);
            CREATE TRIGGER IF NOT EXISTS turn_insert AFTER INSERT ON turns BEGIN
                INSERT INTO turn_versions VALUES(NEW.thread,1) ON CONFLICT(thread) DO UPDATE SET version=version+1;
            END;
            CREATE TRIGGER IF NOT EXISTS turn_update AFTER UPDATE ON turns BEGIN
                INSERT INTO turn_versions VALUES(NEW.thread,1) ON CONFLICT(thread) DO UPDATE SET version=version+1;
            END;
            CREATE TRIGGER IF NOT EXISTS turn_delete AFTER DELETE ON turns BEGIN
                INSERT INTO turn_versions VALUES(OLD.thread,1) ON CONFLICT(thread) DO UPDATE SET version=version+1;
            END;

        ''')
        self.server_projects=self.preference("__server_projects__")
        self.migrate_media()

    def migrate_media(self):
        version=self.db.execute('PRAGMA user_version').fetchone()[0]
        if (self.media_access and self._deferred_media) or version < SCHEMA_VERSION:
            # One-time Navigator projection migration; original history/media stay untouched.
            with self.db:
                for row in self.db.execute('SELECT thread,id,data FROM turns').fetchall():
                    turn=json.loads(row['data'])
                    paths=canonical_media(turn.get('media',[])) if self.media_access else turn.get('media',[])
                    changed=paths != turn.get('media',[])
                    if changed:
                        turn['media']=paths
                    # Version 3 keeps every projected conversational item. Old
                    # cache rows can only reconstruct their retained prompt and
                    # final assistant text, but remain readable and searchable.
                    if not isinstance(turn.get('entries'),list):
                        entries=[]
                        for prompt in turn.get('prompts',[]):
                            if isinstance(prompt,dict):
                                entries.append({'id':prompt.get('id',turn['id']), 'role':'user',
                                                'text':prompt.get('text',''), 'time':prompt.get('time',turn.get('start',0))})
                        if turn.get('last'):
                            entries.append({'id':turn['id']+'-assistant', 'role':'assistant',
                                            'text':turn['last'], 'time':turn.get('end') or turn.get('start',0)})
                        turn['entries']=entries
                        self.db.execute("UPDATE hydration SET complete=0,cursor=NULL,fingerprint='' WHERE thread=?",(row['thread'],))
                        changed=True
                    if changed:
                        self.db.execute('UPDATE turns SET data=? WHERE thread=? AND id=?',(json.dumps(turn),row['thread'],row['id']))
                self.db.execute('PRAGMA user_version='+str(SCHEMA_VERSION))
            if self.media_access:self._deferred_media=False

    def upsert_metadata(self, records, complete=True):
        ids = set()
        with self.db:
            for record in records:
                ids.add(record['id'])
                fingerprint = hashlib.sha256(json.dumps({k: record.get(k) for k in
                    ('updatedAt','path','historyMode','name','projectId','cwd','archived')}, sort_keys=True).encode()).hexdigest()
                self.db.execute('INSERT INTO metadata VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data,fingerprint=excluded.fingerprint WHERE metadata.data != excluded.data',
                                (record['id'], json.dumps(record), fingerprint))
            if complete:
                # Only reconcile after a successful complete enumeration, never on disconnect.
                for row in self.db.execute('SELECT id FROM metadata').fetchall():
                    if row['id'] not in ids:
                        self.db.execute('DELETE FROM metadata WHERE id=?', (row['id'],))
                        self.db.execute('DELETE FROM turns WHERE thread=?', (row['id'],))
                        self.db.execute('DELETE FROM hydration WHERE thread=?', (row['id'],))

    def records(self):
        return [json.loads(r['data']) for r in self.db.execute('SELECT data FROM metadata')]

    def fingerprint(self, tid):
        row = self.db.execute('SELECT fingerprint FROM metadata WHERE id=?', (tid,)).fetchone()
        return row[0] if row else ''

    def hydration(self, tid):
        r = self.db.execute('SELECT * FROM hydration WHERE thread=?', (tid,)).fetchone()
        return dict(r) if r else {'complete': 0, 'cursor': None, 'fingerprint': '', 'checked': 0, 'error': None}

    def cache_page(self, tid, turns, cursor, fingerprint, complete, replace_head=False, replace_all=False):
        with self.db:
            if replace_all:
                self.db.execute('DELETE FROM turns WHERE thread=?',(tid,))
            elif replace_head:
                # A rollback can remove the newest turns. Reconcile the refreshed
                # head, not just upsert it, so removed prompts do not linger.
                ids={t['id'] for t in turns}
                boundary=min(((stamp(t.get('startedAt')),t['id']) for t in turns),default=None)
                for old in self.turns(tid):
                    if old['id'] not in ids and (boundary is None or (old['start'],old['id'])>=boundary):
                        self.db.execute('DELETE FROM turns WHERE thread=? AND id=?',(tid,old['id']))
            for turn in turns:
                projected = project_turn(turn,self.media_access)
                self.db.execute('INSERT INTO turns VALUES(?,?,?) ON CONFLICT(thread,id) DO UPDATE SET data=excluded.data WHERE turns.data != excluded.data', (tid, turn['id'], json.dumps(projected)))
            self.db.execute('INSERT OR REPLACE INTO hydration VALUES(?,?,?,?,?,NULL)',
                            (tid, fingerprint, cursor, int(complete), time.time()))

    def mark_error(self, tid, error):
        h = self.hydration(tid)
        with self.db:
            self.db.execute('INSERT OR REPLACE INTO hydration VALUES(?,?,?,?,?,?)',
                (tid, h['fingerprint'], h['cursor'], h['complete'], h['checked'], error))

    def turn_version(self, tid):
        row = self.db.execute('SELECT version FROM turn_versions WHERE thread=?',(tid,)).fetchone()
        return row[0] if row else 0

    def turns(self, tid):
        version = self.turn_version(tid)
        cached = self._turn_cache.get(tid)
        if cached is None or cached[0] != version:
            rows=self.db.execute('SELECT data FROM turns WHERE thread=?',(tid,)).fetchall()
            cost=sum(len(r[0])*3 for r in rows)
            value = sorted((json.loads(r[0]) for r in rows),
                           key=lambda x:(x['start'],x['id']))
            # Remove the old entry before budgeting its replacement. Otherwise an
            # eviction of this same ID can accidentally erase the new cost.
            self._turn_cache.pop(tid,None);self._turn_costs.pop(tid,None)
            self._projection_cache.pop(tid,None);self._presentation_cache.pop(tid,None)
            while self._turn_cache and (len(self._turn_cache) >= 512 or sum(self._turn_costs.values())+cost>64*1024*1024):
                oldest = next(iter(self._turn_cache))
                self._turn_cache.pop(oldest, None); self._projection_cache.pop(oldest, None);self._presentation_cache.pop(oldest,None);self._turn_costs.pop(oldest,None)
            # A single oversized history may exceed the estimate, but displaces
            # every other history and remains accounted for on the next load.
            self._turn_costs[tid]=cost
            self._turn_cache[tid] = (version, value)
            self._latest_states[tid]=(version,value[-1]['status'] if value else 'unknown')
        return self._turn_cache[tid][1]

    def latest_status(self, tid):
        cached=self._latest_states.get(tid)
        if cached is None or cached[0] != self.turn_version(tid):
            self.turns(tid)
        return self._latest_states[tid][1]

    def projection(self, tid):
        turns = self.turns(tid)
        version = self._turn_cache[tid][0]
        cached = self._projection_cache.get(tid)
        if cached is None or cached[0] != version:
            prompts=[dict(p,text=readable_prompt(p['text'])) for t in turns for p in t['prompts']]
            prompt_text={(p['id'],p.get('time',0)):p['text'] for p in prompts}
            entries=[]
            for turn in turns:
                for entry in turn.get('entries',[]):
                    if not isinstance(entry,dict) or entry.get('role') not in ('user','assistant'):
                        continue
                    text=(prompt_text.get((entry.get('id'),entry.get('time',0))) if entry.get('role')=='user' else None)
                    entries.append(dict(entry,turnID=turn['id'],text=text if text is not None else readable_prompt(str(entry.get('text','')))))
            conversation=[]
            paths = turn_media(turns)
            value = {'paths':paths, 'prompts':prompts, 'voiceMessages':conversation,
                     'entries':entries,
                     'searchText':'\n'.join(e['text'] for e in entries),
                     'promptSearchText':'\n'.join(p['text'] for p in prompts),
                     'seconds':sum(t['seconds'] or 0 for t in turns),
                     'messages':sum(t['messages'] for t in turns),
                     'filesChanged':len({p for t in turns for p in t['changed']}),
                     'activity':[{'start':t['start'],'end':t['end'],'seconds':t['seconds'] or 0} for t in turns if t['start']]}
            self._projection_cache[tid] = (version, value)
            self._media_counts.pop(tid, None)
        return self._projection_cache[tid][1]

    def search(self, query, scope_ids=None, limit=200):
        """Local substring search; reuse summaries to avoid decoding unrelated histories."""
        if not isinstance(query,str) or not query.strip() or len(query) > 500:
            raise ValueError('Enter a search phrase of up to 500 characters.')
        if type(limit) is not int or not 1 <= limit <= 200:
            raise ValueError('Search limit must be between 1 and 200.')
        records={record['id']:record for record in self.records()}
        if scope_ids is None:
            ids=list(records)
        elif isinstance(scope_ids,list) and all(isinstance(value,str) for value in scope_ids):
            ids=list(set(scope_ids) & set(records))
        else:
            raise ValueError('Search scope is invalid.')
        ids.sort(key=lambda tid:(-records[tid].get('updatedAt',0),tid))
        needle=query.casefold().strip(); results=[]
        incomplete=[tid for tid in ids if not self.hydration(tid)['complete']]
        for tid in ids:
            cached=self._summary_cache.get(tid)
            if cached and cached[0][1]==self.turn_version(tid) and needle not in cached[2]['searchText'].casefold():
                continue
            for entry in self.projection(tid)['entries']:
                text=entry['text']; folded=text.casefold(); location=folded.find(needle)
                if location < 0: continue
                # Map the folded offset back to original characters (ß and other
                # case folds can change length), preserving an accurate excerpt.
                original=0;folded_offset=0
                while original<len(text) and folded_offset<location:
                    folded_offset+=len(text[original].casefold());original+=1
                start=max(0,original-100); end=min(len(text),original+len(query)+140)
                snippet=text[start:end].replace('\n',' ').strip()
                if start: snippet='…'+snippet
                if end<len(text): snippet += '…'
                results.append({'threadID':tid,'turnID':entry['turnID'],'itemID':entry['id'],
                                'role':entry['role'],'snippet':snippet,'start':entry.get('time',0)})
                if len(results)>limit:
                    return {'query':query,'results':results[:limit],'incompleteIDs':incomplete,'complete':not incomplete,'truncated':True}
        return {'query':query,'results':results,'incompleteIDs':incomplete,'complete':not incomplete,'truncated':False}

    def conversation(self, tid, cursor=None, limit=50, around_item_id=None):
        if not isinstance(tid,str) or not self.db.execute('SELECT 1 FROM metadata WHERE id=?',(tid,)).fetchone():
            raise ValueError('Session is no longer available.')
        if type(limit) is not int or not 1 <= limit <= 100:
            raise ValueError('Conversation limit must be between 1 and 100.')
        entries=self.projection(tid)['entries']; end=len(entries)
        if around_item_id:
            if not isinstance(around_item_id,str): raise ValueError('Conversation item is invalid.')
            position=next((i for i,v in enumerate(entries) if v['id']==around_item_id),None)
            if position is None: raise ValueError('This passage changed since the search. Search again or choose Latest.')
            end=min(len(entries),position+1+max(0,(limit-1)//2))
        elif cursor is not None:
            if not isinstance(cursor,str) or not cursor.startswith('before-item:') or len(cursor)>8192:
                raise ValueError('Conversation cursor is invalid.')
            try:
                boundary=json.loads(base64.urlsafe_b64decode(cursor[12:].encode()).decode())
                if not isinstance(boundary,list) or len(boundary)!=2: raise ValueError()
            except Exception as exc: raise ValueError('Conversation cursor is invalid.') from exc
            position=next((i for i,v in enumerate(entries) if [v['turnID'],v['id']]==boundary),None)
            if position is None: raise ValueError('History changed while reading. Choose Latest to refresh it.')
            end=position
        begin=max(0,end-limit)
        items=[{'turnID':entry['turnID'],'itemID':entry['id'],'role':entry['role'],
                'text':entry['text'],'time':entry.get('time',0)} for entry in entries[begin:end]]
        next_cursor=None
        if begin:
            boundary=[entries[begin]['turnID'],entries[begin]['id']]
            next_cursor='before-item:'+base64.urlsafe_b64encode(json.dumps(boundary).encode()).decode()
        return {'id':tid,'items':items,'nextCursor':next_cursor,
                'indexed':bool(self.hydration(tid)['complete']),
                'incomplete':not bool(self.hydration(tid)['complete'])}

    def rebuild_history(self):
        """Delete only replaceable history projections, retaining all local state."""
        with self.db:
            self.db.execute('DELETE FROM turns')
            self.db.execute('DELETE FROM hydration')
            self.db.execute('DELETE FROM observations')
        self._turn_cache.clear();self._projection_cache.clear();self._presentation_cache.clear()
        self._turn_costs.clear();self._latest_states.clear();self._summary_cache.clear()
        self._media_counts.clear();self._tail.clear();self._snapshot_key=None

    def diagnostics(self, connected, executable_available=None, server_running=None):
        """A compact report that contains no prompts, source paths or credentials."""
        total=self.db.execute('SELECT COUNT(*) FROM metadata').fetchone()[0]
        indexed=self.db.execute('SELECT COUNT(*) FROM hydration WHERE complete=1').fetchone()[0]
        failed=self.db.execute("SELECT COUNT(*) FROM hydration WHERE error IS NOT NULL AND error != ''").fetchone()[0]
        try:
            descriptor, temporary=tempfile.mkstemp(prefix='.navigator-check-',dir=self.directory)
            os.close(descriptor);os.unlink(temporary);cache_state='ok'
        except OSError:
            cache_state='error'
        checks=[
            {'id':'cache','title':'Navigator library','state':cache_state,
             'detail':'Local cache is readable and writable.' if cache_state == 'ok' else 'Navigator cannot write its local cache.'},
            {'id':'history','title':'History coverage','state':'ok' if indexed==total else 'warning',
             'detail':str(indexed)+' of '+str(total)+' sessions have complete cached history.'},
            {'id':'connection','title':'Codex connection','state':'ok' if connected else 'warning',
             'detail':'Connected to local Codex.' if connected else 'Using cached history while Codex is unavailable.'},
        ]
        if executable_available is not None:
            checks.append({'id':'codexExecutable','title':'Codex executable',
                           'state':'ok' if executable_available else 'error',
                           'detail':'A local Codex executable is available.' if executable_available else 'No local Codex executable is available.'})
        if server_running is not None:
            checks.append({'id':'appServer','title':'Codex app server',
                           'state':'ok' if server_running else 'warning',
                           'detail':'The local Codex app server is running.' if server_running else 'The local Codex app server is not running.'})
        if failed:
            checks.append({'id':'hydration','title':'History refresh','state':'warning',
                           'detail':str(failed)+' session'+('s need' if failed != 1 else ' needs')+' another refresh.'})
        return {'indexed':indexed,'total':total,'connected':bool(connected),'checks':checks,
                'recoveryActions':['refresh','rebuildIndex','backup','restoreBackup']}

    def observe(self, record, budget=256*1024):
        """Tail complete JSONL records; partial trailing writes wait until next poll.

        A private app-server cannot authoritatively see another process's runtime.
        This only calls a turn running when an unmatched start has recent disk activity.
        """
        tid=record['id'];path=record.get('path')
        if not path:
            return
        try:
            stat=os.stat(path)
            row=self.db.execute('SELECT data FROM observations WHERE thread=?',(tid,)).fetchone()
            old=json.loads(row[0]) if row else {}
            identity=[stat.st_dev,stat.st_ino]
            if old.get('identity')!=identity or old.get('offset',0)>stat.st_size or 'tokens' not in old:
                old={'identity':identity,'offset':0,'start':0,'turn':'','last':0,'tokens':None}
            if old.get('size')==stat.st_size and old.get('mtime')==stat.st_mtime_ns:
                return
            # In-memory partial line state never advances the durable complete-record cursor.
            pending = self._tail.get(tid)
            if not pending or pending['identity'] != identity or pending['position'] > stat.st_size or pending['offset'] != old['offset']:
                pending = {'identity':identity,'position':old['offset'],'offset':old['offset'],'data':b'', 'skip':False}
            with open(path,'rb') as stream:
                stream.seek(pending['position'])
                while budget > 0:
                    chunk = stream.readline(min(budget, 65536))
                    if not chunk: break
                    budget -= len(chunk)
                    pending['position'] = stream.tell()
                    # Oversized payload records are irrelevant to lifecycle observation.
                    # Skip through their newline in bounded passes, retaining the last complete cursor.
                    if not pending['skip']:
                        pending['data'] += chunk
                        if len(pending['data']) > 1024*1024:
                            pending['data'] = b''; pending['skip'] = True
                    if not chunk.endswith(b'\n'): continue
                    line = pending['data']
                    pending['data'] = b''
                    old['offset'] = stream.tell(); pending['offset'] = old['offset']
                    if pending['skip']:
                        pending['skip'] = False
                        continue
                    try:
                        event=json.loads(line)
                    except (ValueError,UnicodeError):
                        continue
                    if not isinstance(event, dict): continue  # valid JSON, but not a rollout record
                    when=stamp(event.get('timestamp'))
                    old['last']=max(old.get('last',0),when)
                    payload=event.get('payload')
                    if not isinstance(payload, dict): payload={}
                    if event.get('type')=='event_msg':
                        kind=payload.get('type')
                        if kind == 'token_count':
                            info = payload.get('info') if isinstance(payload.get('info'), dict) else {}
                            usage = info.get('total_token_usage') if isinstance(info.get('total_token_usage'), dict) else {}
                            if isinstance(usage.get('total_tokens'), int):
                                old['tokens'] = usage['total_tokens']
                        if kind=='task_started':
                            old['turn']=payload.get('turn_id','')
                            old['start']=stamp(payload.get('started_at')) or when
                        elif kind in ('task_complete','task_completed','turn_aborted') and (not payload.get('turn_id') or payload.get('turn_id')==old.get('turn')):
                            old['start']=0
                self._tail[tid] = pending
                old['size']=stat.st_size if old['offset']==stat.st_size else -1
                old['mtime']=stat.st_mtime_ns
                old['freshAt']=min(time.time(),stat.st_mtime)
            with self.db:
                self.db.execute('INSERT OR REPLACE INTO observations VALUES(?,?)',(tid,json.dumps(old)))
        except OSError:
            return

    def observation(self, tid):
        row=self.db.execute('SELECT data FROM observations WHERE thread=?',(tid,)).fetchone()
        return json.loads(row[0]) if row else {}

    def preference(self, key):
        row = self.db.execute('SELECT data FROM preferences WHERE id=?', (key,)).fetchone()
        return json.loads(row[0]) if row else {}

    def save_preference(self, key, data):
        with self.db:
            self.db.execute('INSERT INTO preferences VALUES(?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data WHERE preferences.data != excluded.data', (key, json.dumps(data)))

    def group_projects(self, ids, name):
        # Navigator-only metadata. Never write Codex storage or move directories.
        with self.db:
            for key in ids:
                pref = self.preference(key)
                pref['group'] = name
                self.db.execute('INSERT OR REPLACE INTO preferences VALUES(?,?)', (key, json.dumps(pref)))

    def load_desktop(self, home):
        try:
            state = json.loads((Path(home)/'.codex-global-state.json').read_text())
            # Only copy project metadata; never retain authentication or arbitrary app state.
            self.desktop = {k: state.get(k, {}) for k in (
                'local-projects', 'thread-project-assignments',
                'app-server-project-id-by-legacy-project-id-by-host')}
            for k in ('projectless-thread-ids', 'pinned-project-ids', 'pinned-thread-ids'):
                self.desktop[k] = state.get(k, [])
            self.save_preference('__desktop__', self.desktop)
        except (OSError, ValueError):
            self.desktop = self.preference('__desktop__')

    def cache_server_projects(self, projects, replace=False):
        if replace: self.server_projects={}
        for project in projects:
            self.server_projects[project['id']]=project
        self.save_preference('__server_projects__',self.server_projects)

    def saved_projects(self):
        projects=dict(self.desktop.get('local-projects', {}))
        for pid, project in self.server_projects.items():
            key=self.legacy_project(pid)
            projects[key]=dict(project,rootPaths=[root['path'] for root in project.get('roots',[])])
        return projects

    def legacy_project(self, pid):
        for mapping in self.desktop.get('app-server-project-id-by-legacy-project-id-by-host', {}).values():
            for legacy, server in mapping.items():
                if server == pid:
                    return legacy
        return pid

    def canonical_project(self, key):
        if key.startswith('codex:'):
            return 'codex:' + self.legacy_project(key[6:])
        if key.startswith('cwd:'):
            for pid, project in self.saved_projects().items():
                if key[4:] in project.get('rootPaths', []):
                    return 'codex:' + pid
        return key

    def native_project(self, record):
        if record['id'] in self.desktop.get('projectless-thread-ids', []):
            return 'unassigned'
        pid = record.get('projectId')
        if pid:
            return 'codex:' + self.legacy_project(pid)
        assignment = self.desktop.get('thread-project-assignments', {}).get(record['id'], {})
        if assignment.get('projectId'):
            return 'codex:' + self.legacy_project(assignment['projectId'])
        if record['id'] in self.desktop.get('projectless-thread-ids', []):
            return 'unassigned'
        cwd = record.get('cwd') or ''
        matches = [(len(root), pid) for pid, project in self.saved_projects().items()
                   for root in project.get('rootPaths', [])
                   if cwd == root or cwd.startswith(root.rstrip('/') + '/')]
        if matches:
            return 'codex:' + max(matches)[1]
        # Generated projectless folders are not user projects.
        if self.desktop or '/.codex/' in cwd or re.search(r'/Codex/\d{4}-\d{2}-\d{2}/', cwd):
            return 'unassigned'
        return project_key(cwd)

    def assign(self, tid, project):
        row = self.db.execute('SELECT data FROM metadata WHERE id=?', (tid,)).fetchone()
        if not row:
            raise ValueError('Session no longer exists')
        baseline = self.native_project(json.loads(row[0]))
        with self.db:
            if project == baseline:
                self.db.execute('DELETE FROM overrides WHERE thread=?', (tid,))
            else:
                self.db.execute('INSERT OR REPLACE INTO overrides VALUES(?,?,?)', (tid, project, baseline))

    def restore_assignment(self, tid):
        with self.db:
            self.db.execute('DELETE FROM overrides WHERE thread=?', (tid,))

    def summarize(self, record, connected=True):
        tid = record['id']; h = self.hydration(tid)
        native = self.native_project(record)
        override = self.db.execute('SELECT project,baseline FROM overrides WHERE thread=?',(tid,)).fetchone()
        project = self.canonical_project(override['project']) if override else native
        sync = 'Conflict' if override and self.canonical_project(override['baseline']) != native else 'Navigator only' if override and project != native else 'Unassigned' if native == 'unassigned' else 'Codex project' if record.get('projectId') else 'Codex project' if self.desktop.get('thread-project-assignments',{}).get(tid,{}).get('projectId') else 'From working folder' if native != 'unassigned' else 'Unassigned'
        observation=self.observation(tid)
        pref=self.preference(tid)
        try:size=os.path.getsize(record.get('path') or '')
        except OSError:size=0
        key=(record,self.turn_version(tid),h,native,project,sync,observation,pref,size,connected,
             self._media_counts.get(tid),tid in self.desktop.get('pinned-thread-ids', []))
        cached=self._summary_cache.get(tid)
        if cached and cached[0]==key and time.time()<cached[1]:return cached[2]
        turns=self.turns(tid);projection=self.projection(tid)
        latest = turns[-1] if turns else None
        observed_start=observation.get('start',0)
        observed_fresh=connected and observed_start>0 and time.time()-observation.get('freshAt',0)<30
        state = latest['status'] if latest else 'unknown'
        running = state == 'inProgress' or observed_fresh
        fresh = connected and time.time() - h['checked'] < 20
        status = ('Running' if fresh or observed_fresh else 'Status stale') if running else 'Status stale' if observed_start else {'completed':'Idle','interrupted':'Interrupted','failed':'Failed'}.get(state, 'Not indexed')
        seconds = projection['seconds']
        active_start = observed_start if observed_fresh else latest['start'] if running and fresh and latest else 0
        # Completed turn runtime is accumulated; running elapsed is rendered live in SwiftUI.
        if active_start:
            if latest and (latest['id']==observation.get('turn') or state=='inProgress'):
                seconds -= latest['seconds'] or 0
        paths = projection['paths']
        result = {'id':tid, 'title':pref.get('alias') or record.get('name') or fallback_title(record.get('preview','') or projection['searchText']) or 'Untitled session',
            'project':project, 'nativeProject':native, 'sync':sync, 'cwd':record.get('cwd') or '',
            'created':record.get('createdAt',0), 'modified':record.get('updatedAt',0),
            'seconds':seconds, 'activeStart':active_start, 'status':status,
            'runtimeCoverage':'complete' if h['complete'] and turns and all(t['seconds'] is not None or t['id']==observation.get('turn') or t['status']=='inProgress' for t in turns) else 'partial' if any(t['seconds'] is not None for t in turns) or active_start else 'unavailable',
            'indexed':bool(h['complete']), 'indexError':h['error'] or '',
            'size':size, 'mediaCount':self._media_counts.get(tid,len(paths)), 'promptCount':len(projection['prompts']),
            'messages':projection['messages'], 'filesChanged':projection['filesChanged'],
            'archived':bool(record.get('archived')), 'favourite':pref.get('favourite',tid in self.desktop.get('pinned-thread-ids', [])),
            'sessionType':record.get('sessionType') if record.get('sessionType') in ('Work','Chat','Codex') else 'Codex',
            'tokenUsage':observation.get('tokens'),
            'searchText':projection['searchText'],'promptSearchText':projection['promptSearchText'],
            'source':record.get('originator') or str(record.get('source','Codex')), 'model':record.get('model') or '',
            'lastChecked':h['checked']}
        now=time.time()
        expiry=min((t for t in (h['checked']+20,observation.get('freshAt',0)+30) if t>now),default=float('inf')) if status=='Running' else float('inf')
        self._summary_cache[tid]=(key,expiry,result,projection['activity'])
        return result

    def detail(self, tid):
        turns = self.turns(tid)
        media = []
        seen = set()
        projection = self.projection(tid)
        for path in projection['paths']:
            # Cached Markdown links may contain URL-encoded spaces. Prefer the
            # literal filename when it exists; resolve only a verified local alias.
            available = self.media_access and local_file_available(path)
            decoded = valid_media_path(unquote(path))
            if self.media_access and not available and decoded and decoded != path and local_file_available(decoded):
                path = decoded
                available = True
            if path in seen:
                continue
            seen.add(path)
            suffix = Path(path).suffix.lower()
            reason = None
            if not self.media_access:
                reason='Preview access not enabled'
            elif available:
                try:
                    with open(path,'rb'):pass
                except PermissionError:available=False;reason='Access denied'
                except OSError:available=False;reason='Cannot read this file'
            if self.media_access and not available and reason is None:
                try:
                    Path(path).stat()
                    reason = 'Not a regular file'
                except PermissionError:
                    reason = 'Access denied'
                except FileNotFoundError:
                    reason = 'Temporary file no longer present' if path.startswith(('/tmp/','/private/tmp/','/var/folders/','/private/var/folders/')) else 'File no longer at this path'
                except (OSError, ValueError):
                    reason = 'Cannot access this path'
            media.append({'id':path,'path':path,'name':Path(path).name,'available':available,'unavailableReason':reason,
                          'revision':file_revision(path) if available else 'missing',
                          'kind':'video' if suffix in ('.mp4','.mov','.m4v') else 'document' if suffix=='.pdf' else 'image'})
        version=self.turn_version(tid)
        presentation=self._presentation_cache.get(tid)
        if presentation is None or presentation[0] != version:
            presentation=(version,present_turns(turns));self._presentation_cache[tid]=presentation
        prompts, conversation = presentation[1]
        if self._media_counts.get(tid) != len(media):
            self._media_counts[tid] = len(media); self._snapshot_key = None
        last = next((t['last'] for t in reversed(turns) if t['last']), '')
        return {'id':tid,'prompts':prompts, 'media':media, 'voiceMessages':conversation,
                'lastResponse':clean_response(last) if conversation else last,
                'activity':projection['activity']}

    def snapshot(self, connected, message):
        key = (self.db.total_changes, connected, message)
        if self._snapshot_key == key and time.time() < self._snapshot_expiry:
            return self._snapshot_value
        records = self.records()
        ids={r['id'] for r in records}
        for cache in (self._summary_cache,self._latest_states):
            for tid in set(cache)-ids:cache.pop(tid,None)
        sessions = [self.summarize(r,connected) for r in records]
        keys = set(s['project'] for s in sessions) | set(s['nativeProject'] for s in sessions) | {'codex:' + k for k in self.saved_projects()}
        projects=[]
        for key in sorted(keys - {'unassigned'}):
            pref=self.preference(key)
            saved = self.saved_projects().get(key.removeprefix('codex:'), {})
            roots = saved.get('rootPaths', [])
            path=key[4:] if key.startswith('cwd:') else roots[0] if roots else ''
            if path and self.db.execute('SELECT 1 FROM preferences WHERE id=?',(key,)).fetchone() is None:
                pref=self.preference(project_key(path))
                if pref:
                    self.save_preference(key,pref)
            projects.append({'id':key,'name':pref.get('name') or saved.get('name') or Path(path).name or key.removeprefix('codex:'),
                             'path':path,'colour':pref.get('colour','blue'),'logo':pref.get('logo',''),
                             'logoStyle':pref.get('logoStyle','As is'), 'logoOverview':pref.get('logoOverview',True),
                             'logoFolder':pref.get('logoFolder',True),
                             'pinned':pref.get('pinned',False) or key in {self.canonical_project('codex:' + pid) for pid in self.desktop.get('pinned-project-ids', [])},
                             'codexPinned':key in {self.canonical_project('codex:' + pid) for pid in self.desktop.get('pinned-project-ids', [])},
                             'group':pref.get('group',''), 'sessionType':'Codex'})
        result = {'type':'snapshot','sessions':sessions,'projects':projects,'connected':connected,'message':message,
                # Summary updates must not touch media files at all.
                'activity':{s['id']:self._summary_cache[s['id']][3] for s in sessions}}
        # Only time-dependent running/stale transitions expire a display snapshot.
        now = time.time()
        expiries = []
        for session in sessions:
            if session['status'] == 'Running':
                observation = self.observation(session['id'])
                expiries.extend(t for t in (session['lastChecked']+20, observation.get('freshAt',0)+30) if t > now)
        self._snapshot_expiry = min(expiries, default=now+3600)
        self._snapshot_key = (self.db.total_changes, connected, message)
        self._snapshot_value = result
        return result
