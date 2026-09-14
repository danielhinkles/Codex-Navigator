#!/usr/bin/env python3
"""Opt-in native snapshots, isolated demo data only; never loads the arena."""
from pathlib import Path
import subprocess
import sys
ROOT = Path(__file__).resolve().parents[1]
APP = ROOT / 'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator'
OUT = ROOT / 'output/purple-surge'
OUT.mkdir(parents=True, exist_ok=True)
for name, flags in [
    ('wide', ['--surge-preview']),
    ('narrow', ['--surge-preview', '--small-window']),
    ('narrow-light', ['--surge-preview', '--small-window', '--light']),
    ('introduction', ['--surge-intro-preview', '--small-window']),
    ('composer', ['--surge-preview', '--composer-preview']),
]:
    if len(sys.argv) > 1 and name not in sys.argv[1:]:
        continue
    target = OUT / (name + '.png')
    subprocess.run([str(APP), '--demo', *flags, '--snapshot', str(target)], cwd=ROOT, check=True, timeout=30)
    assert target.is_file() and target.stat().st_size > 10000, name
    print(f'Captured {name}: {target}', flush=True)
