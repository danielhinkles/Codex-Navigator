"""Explicit local launch runner. Discovery and organisation never invoke this file."""
import functools
import http.server
import json
import mimetypes
import os
from pathlib import Path
import re
import queue
import shutil
import shlex
import signal
import subprocess
import sys
import threading
import time
from urllib.parse import urlparse, quote
from urllib.request import urlopen


def local_url(text):
    text = re.sub(r'\x1b\[[0-?]*[ -/]*[@-~]', '', text)
    for value in re.findall(r'https?://[^\s<>\x1b]+', text):
        value = value.rstrip(').,;')
        try:
            parsed = urlparse(value)
            if parsed.hostname in ('localhost','127.0.0.1','::1','0.0.0.0') and not parsed.username:
                return value.replace('://0.0.0.0', '://127.0.0.1')
        except ValueError: pass
    return None


def executable(name, candidates=()):
    found = shutil.which(name)
    if found: return found
    for path in candidates:
        if os.access(path, os.X_OK): return path
    raise ValueError(f'{name} is not installed or is not on PATH. Install it or use a custom launch command with its full path.')


def command(plan):
    path = Path(plan['path'])
    kind = plan['kind']
    if kind == 'command': return ['/bin/zsh','-lc',plan['command']], path
    if kind == 'python':
        python = next((str(path.parent / v / 'bin/python') for v in ('.venv','venv') if os.access(path.parent / v / 'bin/python', os.X_OK)), '/usr/bin/python3')
        return [python,str(path)], path.parent
    if kind == 'shell':
        with path.open() as source: first=source.readline(4096).strip()
        interpreter=shlex.split(first[2:]) if first.startswith('#!') else ['/bin/bash']
        if not interpreter or not interpreter[0].startswith('/'): raise ValueError('The script needs an absolute interpreter in its shebang.')
        return interpreter+[str(path)], path.parent
    if kind == 'executable': return [str(path)], path.parent
    if kind == 'godot':
        binary = executable('godot', ['/Applications/Godot.app/Contents/MacOS/Godot',str(Path.home()/'Applications/Godot.app/Contents/MacOS/Godot')])
        return [binary,'--path',str(path)], path
    if kind == 'unity':
        version_file = path/'ProjectSettings/ProjectVersion.txt'
        match = re.search(r'^m_EditorVersion:\s*(\S+)',version_file.read_text(),re.M)
        if not match: raise ValueError('Could not determine this project’s Unity editor version.')
        version=match.group(1)
        if not re.fullmatch(r'[\w.\-]+',version): raise ValueError('Invalid Unity version.')
        binary=Path('/Applications/Unity/Hub/Editor')/version/'Unity.app/Contents/MacOS/Unity'
        if not binary.is_file(): raise ValueError(f'Unity {version} is required. Install that version in Unity Hub or choose a custom launch command. Navigator will not upgrade the project.')
        return ['/usr/bin/open','-a',str(binary.parents[2]),'--args','-projectPath',str(path)],path
    raise ValueError('Unsupported launch type. Choose a launch setup or custom command.')


class LocalHandler(http.server.SimpleHTTPRequestHandler):
    def _permitted(self):
        # Only the loopback origin Navigator opened may read this folder: a rebinding
        # page on another host name gets 403, and nothing outside the folder is served.
        port=self.server.server_port
        host=(self.headers.get('Host') or '').strip().lower()
        if host not in {f'127.0.0.1:{port}',f'localhost:{port}',f'[::1]:{port}'}:
            self.send_error(403,'Unexpected Host header'); return False
        root=os.path.realpath(self.directory)
        target=os.path.realpath(self.translate_path(self.path))
        if target!=root and not target.startswith(root+os.sep):
            self.send_error(404,'File not found'); return False
        return True

    def do_GET(self):
        if self._permitted(): super().do_GET()

    def do_HEAD(self):
        if self._permitted(): super().do_HEAD()

    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy','same-origin')
        self.send_header('Cross-Origin-Embedder-Policy','require-corp')
        super().end_headers()

    def guess_type(self, path):
        # Unity/Godot web exports may ship precompressed assets.
        raw = path[:-3] if path.endswith('.gz') else path[:-3] if path.endswith('.br') else path
        return {'.wasm':'application/wasm','.js':'application/javascript','.data':'application/octet-stream'}.get(Path(raw).suffix, mimetypes.guess_type(raw)[0] or 'application/octet-stream')

    def send_header(self, keyword, value):
        if keyword == 'Content-type':
            clean=urlparse(self.path).path
            if clean.endswith('.gz'): super().send_header('Content-Encoding','gzip')
            elif clean.endswith('.br'): super().send_header('Content-Encoding','br')
        super().send_header(keyword,value)


def run(plan, open_browser=True):
    stopped=threading.Event()
    owner=os.getppid()
    child=None
    def stop(*_):
        stopped.set()
        if child and child.poll() is None:
            try: os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError: pass
    signal.signal(signal.SIGTERM,stop)
    signal.signal(signal.SIGINT,stop)
    # Every helper launch is owned by its Navigator parent. This includes
    # Python, shell, executable and Godot children as well as static servers
    # and custom commands. If Navigator disappears, clean up the whole process
    # group instead of leaving a project process running unattended.
    def watch_owner():
        while not stopped.wait(1):
            if os.getppid()!=owner:
                stop()
                return
    threading.Thread(target=watch_owner,daemon=True).start()
    opened=threading.Event()
    def browse(url):
        if not open_browser or opened.is_set(): return
        opened.set()
        def wait():
            for _ in range(120):
                if stopped.is_set(): return
                try:
                    with urlopen(url,timeout=1): pass
                    subprocess.run(['/usr/bin/open',url],check=False)
                    return
                except Exception: stopped.wait(.5)
            print('Browser could not connect yet. Open this address when the server is ready: '+url,flush=True)
        threading.Thread(target=wait,daemon=True).start()
    if plan['kind']=='static':
        page=Path(plan['path'])
        handler=functools.partial(LocalHandler,directory=str(page.parent))
        server=http.server.ThreadingHTTPServer(('127.0.0.1',0),handler)
        server.timeout=.3
        url=f'http://127.0.0.1:{server.server_port}/'+quote(page.name)
        print('Serving '+url,flush=True);browse(url)
        try:
            while not stopped.is_set(): server.handle_request()
        finally: server.server_close()
        return 0
    args,cwd=command(plan)
    if not cwd.is_dir(): raise ValueError('The working folder is unavailable.')
    print('Working folder: '+str(cwd)+'\nStarting '+plan['title'],flush=True)
    child=subprocess.Popen(args,cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,stdin=subprocess.DEVNULL,start_new_session=True)
    if plan.get('browserURL'):
        url=local_url(plan['browserURL'])
        if not url: stop();raise ValueError('Use a localhost HTTP or HTTPS browser address.')
        browse(url)
    lines=queue.Queue(maxsize=1000)
    def read_output():
        for line in iter(child.stdout.readline,b''):
            while not stopped.is_set():
                try: lines.put(line,timeout=.1);break
                except queue.Full: pass
        lines.put(None)
    threading.Thread(target=read_output,daemon=True).start()
    try:
        while not stopped.is_set():
            try: line=lines.get(timeout=.1)
            except queue.Empty: continue
            if line is None: break
            text=line.decode('utf-8',errors='replace');print(text,end='',flush=True)
            url=local_url(text)
            if url and plan['kind']=='command': browse(url)
        code=child.poll() if stopped.is_set() else child.wait()
        return 0 if stopped.is_set() else code
    finally:
        stop()
        if child.poll() is None:
            try: child.wait(timeout=3)
            except subprocess.TimeoutExpired: os.killpg(child.pid,signal.SIGKILL);child.wait()


def load_plan(argv):
    # Navigator sends the plan on stdin so custom command text never appears in `ps` output.
    if argv[1:2]==['--stdin']: plan=json.loads(sys.stdin.read())
    elif len(argv)>1: plan=json.loads(argv[1])
    else: raise ValueError('No launch plan was provided.')
    if not isinstance(plan,dict) or not isinstance(plan.get('kind'),str) or not isinstance(plan.get('path'),str):
        raise ValueError('The launch plan is invalid.')
    return plan


if __name__=='__main__':
    try: sys.exit(run(load_plan(sys.argv),open_browser='--no-browser' not in sys.argv[2:]))
    except Exception as exc: print('Launch failed: '+str(exc),file=sys.stderr,flush=True);sys.exit(1)
