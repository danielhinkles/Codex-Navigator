"""Local Codex JSON-RPC transport; interactive requests are opt-in."""
import json
import os
import queue
import shutil
import subprocess
import threading


class RPCError(RuntimeError):
    pass


class CodexRPC:
    def __init__(self, home, binary=None, interactive=False):
        self.home = str(home)
        self.interactive = interactive
        self.write_lock = threading.Lock()
        self.binary = binary or os.environ.get('NAVIGATOR_CODEX') or shutil.which('codex')
        if not self.binary:
            for candidate in ['/Applications/ChatGPT.app/Contents/Resources/codex',
                              '/Applications/Codex.app/Contents/Resources/codex']:
                if os.path.isfile(candidate):
                    self.binary = candidate
                    break
        self.process = None
        self.connection = 0  # Monotonic serial; never reuse id(process), which CPython can recycle.
        self.pending = {}
        self.lock = threading.Lock()
        self.serial = 0
        self.events = queue.Queue()

    def connect(self):
        self.close()
        while not self.events.empty():
            try: self.events.get_nowait()
            except queue.Empty: break
        if not self.binary:
            raise RPCError('Codex executable not found. Set NAVIGATOR_CODEX.')
        env = dict(os.environ, CODEX_HOME=self.home)
        self.connection += 1
        self.process = subprocess.Popen([self.binary, 'app-server'], env=env,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        threading.Thread(target=self._read, args=(self.process, self.connection), daemon=True).start()
        self.request('initialize', {'clientInfo': {'name': 'codex_navigator', 'version': '0.1.0'},
                                   'capabilities': {'experimentalApi': True}})
        self._send({'method': 'initialized'})

    def _read(self, process, connection=None):
        if connection is None: connection = self.connection
        try:
            for line in process.stdout:
                try:
                    obj = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                if not isinstance(obj, dict): continue
                if process is not self.process: break
                if 'method' in obj: obj['_connection'] = connection
                if 'id' in obj and 'method' not in obj:
                    with self.lock:
                        target = self.pending.get(obj['id'])
                    if target:
                        target.put(obj)
                elif 'method' in obj and 'id' not in obj:
                    # A bounded wake-up signal; persistent history remains the source of truth.
                    if self.interactive or self.events.qsize() < 100:
                        self.events.put(obj)
                elif 'method' in obj and 'id' in obj:
                    if self.interactive: self.events.put(obj)
                    else: self.respond(obj['id'], error='The Navigator index is read-only.')
        finally:
            with self.lock:
                for target in self.pending.values() if process is self.process else []:
                    target.put({'error': {'message': 'Codex connection closed'}})

    def _send(self, obj):
        try:
            with self.write_lock:
                self.process.stdin.write((json.dumps(obj) + '\n').encode())
                self.process.stdin.flush()
        except (OSError, AttributeError, ValueError) as exc:
            # ValueError: write to a closed pipe after the server exited.
            raise RPCError('Codex is disconnected') from exc

    def respond(self, serial, result=None, error=None):
        obj = {'id':serial}
        if error is not None: obj['error'] = {'code':-32601, 'message':error}
        else: obj['result'] = result or {}
        self._send(obj)

    def request(self, method, params=None, timeout=20):
        target = queue.Queue()
        with self.lock:
            self.serial += 1
            serial = self.serial
            self.pending[serial] = target
        try:
            self._send({'id': serial, 'method': method, 'params': params or {}})
            try:
                obj = target.get(timeout=timeout)
            except queue.Empty as exc:
                raise RPCError('Codex request timed out: ' + method) from exc
            if 'error' in obj:
                raise RPCError(obj['error'].get('message', str(obj['error'])))
            return obj['result']
        finally:
            with self.lock:
                self.pending.pop(serial, None)

    def close(self):
        # No write_lock here: a writer blocked on a full pipe must be freed by terminate(), not waited for.
        process, self.process = self.process, None
        if process:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill(); process.wait()
            # Everything still pending was sent to the closed server; release the waiters now.
            with self.lock:
                for target in self.pending.values():
                    target.put({'error': {'message': 'Codex connection closed'}})
