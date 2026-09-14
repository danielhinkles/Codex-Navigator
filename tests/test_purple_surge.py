"""Bundling/isolation checks. Never connect to the live game or Codex."""
import hashlib
import json
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / 'Sources/Navigator/Resources/PurpleSurge'

class PurpleSurgeBoundaryTests(unittest.TestCase):
    def test_vendored_game_is_exact_and_bundled(self):
        manifest = json.loads((RESOURCES / 'provenance.json').read_text())
        for name, provenance in manifest.items():
            self.assertEqual(hashlib.sha256((RESOURCES / name).read_bytes()).hexdigest(), provenance['sha256'], name)
        self.assertIn('.copy("Resources/PurpleSurge")', (ROOT / 'Package.swift').read_text())
        self.assertIn('Resources/PurpleSurge "$app/Contents/Resources/PurpleSurge"', (ROOT / 'scripts/build.sh').read_text())
        self.assertLess(sum(p.stat().st_size for p in RESOURCES.rglob("*") if p.is_file()), 2_000_000)

    def test_game_has_no_execution_or_organisation_transport(self):
        for name in ['PurpleSurgeEngine.swift', 'PurpleSurgeStore.swift', 'PurpleSurgeOnline.swift', 'PurpleSurgeView.swift', 'PurpleSurgeBoard.swift']:
            source = (ROOT / 'Sources/Navigator' / name).read_text()
            for forbidden in ['model.send(', 'composerDraft', 'composer.messages', 'thread-project-assignments', '.codex-global-state', 'NSWorkspace.shared.open', 'loadFileURL', 'addScriptMessageHandler', 'JSExport']:
                self.assertNotIn(forbidden, source, (name, forbidden))
        engine = (ROOT / 'Sources/Navigator/PurpleSurgeEngine.swift').read_text()
        self.assertNotIn('setObject(', engine)
        self.assertNotIn('URLSession', engine)

    def test_offline_renderer_is_constrained(self):
        html = (RESOURCES / 'board.html').read_text()
        self.assertIn("connect-src 'none'", html)
        self.assertIn("frame-src 'none'", html)
        host = (ROOT / 'Sources/Navigator/PurpleSurgeBoard.swift').read_text()
        self.assertIn('message.frameInfo.isMainFrame', host)
        self.assertIn('body["key"] as? String == key', host)
        self.assertIn('Self.paths.contains', host)
        self.assertIn('.nonPersistent()', host)
        adapter = (RESOURCES / 'navigator-board.js').read_text()
        self.assertIn('next.position.line.map(({row,col})=>({r:row,c:col}))', adapter)
        for forbidden in ['fetch(', 'XMLHttpRequest', 'setInterval', 'requestAnimationFrame']:
            self.assertNotIn(forbidden, adapter)

    def test_no_parallel_tracking_or_online_requests_in_puzzles(self):
        for name in ['rules.js', 'puzzle-defence.js', 'navigator-engine.js']:
            source = (RESOURCES / name).read_text()
            for forbidden in ['fetch(', 'XMLHttpRequest', 'setInterval', 'setTimeout', '/api/count']:
                self.assertNotIn(forbidden, source)
        self.assertNotIn('https://', (ROOT / 'Sources/Navigator/PurpleSurgeStore.swift').read_text())

if __name__ == '__main__':
    unittest.main()
