# Purple Surge integration

14 September 2026

## Experience

Purple Surge lives in a retractable right-hand panel in Navigator and Composer. The persistent tab is 40 points wide; play uses 360 points, and the first-use preview uses 328. In the main window the game temporarily replaces the inspector, preserving the session list. Composer keeps a minimum 640-point task column next to the game. Below 760 points of panel height, the header and task notice compact and the shared game HUD compacts its cards, banner and board, keeping all six rows and the Surge control visible together at 1080 × 740. Hints and secondary controls can scroll; all six game destinations stay above the content.

The bundled 200-puzzle Purple Surge pack uses the standalone game's **unchanged rule book and deterministic opponent defence**, inside JavaScriptCore, with a local WebKit renderer using the original board chassis, octagonal token artwork, CSS and unchanged selected visual methods. The renderer preserves drop timing, armed row previews, laser vaporisation, gravity collapse, screen shake and winning-line effects. Reduced motion presents the settled board immediately. Puzzles remain silent. `Resources/PurpleSurge/provenance.json` records source paths and SHA-256 hashes. The standalone project is never written or built by Navigator.

The destination menu opens the existing live game's Puzzles library, Tower, Speed Run, My profile, and Online arena inside one isolated persistent website profile. The Puzzles destination opens the puzzle hub rather than the single bundled board. Account sign-in and progress remain owned by Purple Surge; sign in inside this profile to access account progress from other devices. Navigator does not import browser cookies or merge the separate offline archive. Offline puzzle retains the previous bundled board and save. A saved online match is resumed only when selecting Online arena, never when opening another mode. Changing destinations recreates the document while retaining website storage. Demos and introductions use the offline board without connecting automatically.

Online match clocks remain server controlled while hidden. The panel says this explicitly. Hiding destroys the online document and suspends media, stopping its polls and animation. A committed online match URL is retained with only `online`, `matchId`, and `twist` parameters so opening the arena can recover from authoritative server state. OAuth callback URLs are never saved. The arena may have to rejoin a lobby queue after hiding; hiding does not pause or resign a match.

## Attention rules

- First introduction: an observed running task, 15 seconds without keyboard/mouse activity, active app, no text editor focus, no required-input task and no unrelated sheet. It reveals a real puzzle with the agreed copy, Sergio, Play and Hide. It never requests focus.
- Later invitations: one static waving Sergio appearance lasting 3 seconds, at most once per rolling 24 hours and never twice in a continuous task wait. No sound, drawer opening or lingering text. Reduced motion removes the reveal transition.
- The invitation preference affects automatic invitations only. Manual access always remains available.
- Host task snapshots contain only local identifiers and coarse statuses. Completion requires an observed running-to-completed transition; stale/disconnected states are never called complete. Required-input notices take priority; simultaneous notices remain queued.
- Return to task is an explicit user action. It preserves the puzzle and selects the relevant Composer task or session. Native task execution and organisation APIs are unchanged.

## Persistence and isolation

Puzzle identity, move history, completed puzzle IDs, discovery state and invitation preference are written atomically to `purple-surge.json` inside Navigator's own support directory (the isolated cache in demos/tests). Every legal move, undo, restart and next-puzzle action saves. A restored game replays moves through the original rules rather than trusting a stored board. Corrupt or unsupported saves are retained; an explicit recovery action copies a backup before starting fresh. Save failures stay visible.

Offline JavaScriptCore has no native objects or callbacks, timers, DOM, network or filesystem bindings. It receives only puzzle and move JSON. The runtime is lazy and released on hide. No game logic receives prompts, conversations, task text, repositories or credentials.

The online web view uses its own persistent WebKit profile (an ephemeral profile in demos), HTTPS navigation restricted to Purple Surge and named sign-in providers, no native message handlers, no file loading/upload picker, and no media capture permission. Website cookies belong to the game profile. Live content loads when the player opens the game or chooses a live destination; invitation previews remain offline. Remote game state never overwrites the local puzzle archive.

## Measurement contract

The standalone marketing measurement contract currently allows only its existing production counters; richer return/cohort collection requires a separate measurement/privacy decision. This integration adds **no parallel telemetry, tracking identity or offline event-upload buffer**. Online play continues using the game's existing instrumentation. The local solved set exists for player progress, not cross-session marketing identity. Invitation conversion and Navigator-specific D1/D7 attribution remain unavailable; do not infer them from opens or combine local puzzle progress with online counters.

## Verification

`python3 scripts/verify.py --build` includes the Swift game check and Python bundling/isolation tests, alongside Navigator's existing organisation-boundary regression tests. It makes no live model request.

The game check covers all 200 initial boards, a real authored Surge solution, illegal actions, save/reopen/restart, undo, next puzzle, corrupt archive preservation, hidden VM unloading, invitation suppression/cooldown, stale task status and attention priority. Initial local engine/persistence test runtime: 0.080 seconds; original bundled resource directory before board artwork: 352 KB on disk. These are observed development measurements, not cross-machine performance guarantees.

Native layout screenshots and final regression results are recorded below after verification. Live arena navigation was denied by browser approval in this session. Consequently **real matchmaking, opponent interaction and provider sign-in are not claimed as tested**. Some OAuth providers can reject embedded web views; that compatibility must be confirmed in a permitted live check before release. No standalone or production changes were made to work around it.

### Recorded results

- Full offline regression suite and signed app packaging: passed (`python3 scripts/verify.py --build`). Existing Navigator organisation tests remain passing; no model request was made.
- Additional game/online-route tests: passed, including URL allowlisting, rejection of files/HTTP/untrusted hosts/credentials/nonstandard ports, resumable-match recognition and exclusion of OAuth callbacks. The tests caught and fixed Foundation's trailing-slash normalisation before packaging.
- Native captures: 1460 × 900 workspace, 1080 × 740 light/dark workspace and introduction, and Composer. Minimum-height review prompted a compact board layout; the real puzzle and primary controls now remain visible together. Source images are generated locally by `scripts/snapshot_purple_surge.py` into the git-ignored `output/purple-surge/` folder.
- Isolated engine/persistence test runs: 0.055–0.154 seconds for the full game check on this Mac. A hidden store has no loaded JS VM. This is not a measurement of live arena CPU, network or sign-in performance.
- Browser approval was declined for the live arena; its end-to-end verification remains outstanding. A permitted pre-release check should join and finish a human match, hide/reopen it during the clock, exercise a disconnect, and complete each configured provider's sign-in.

- Composer emitted a transient SwiftUI AttributeGraph warning during snapshot presentation. The saved pre-integration Navigator build was run with the same isolated Composer preview and emitted the same warning, confirming it predates this feature. The final capture remained usable; this integration does not claim to repair that existing warning.

### Original puzzle presentation

The offline renderer serves a fixed allowlist of bundled files through `surge-board://bundle`; its content security policy disallows connections and frames. Its native messages are readiness, revision-checked puzzle actions (column choice, arm, undo, restart and next), and animation completion. Snapshots contain puzzle data only. Moves save before animation; undo/retry/next are disabled until the board settles. Hiding destroys the renderer and reopening restores the saved final position. No ambient animation loop runs.

`tests/PurpleSurgeRendererCheck.swift` is an opt-in native WebKit check using temporary puzzle storage. It verifies all 42 cells, a real authored Surge solution through the message bridge, the laser phase and winning-token highlights. Compile with PurpleSurgeEngine.swift, PurpleSurgeStore.swift and PurpleSurgeBoard.swift; run with a graphical macOS session. No live arena is accessed.

### Shared game HUD correction

Puzzles now reuse the original game's player-card, turn-banner and power-cell markup with the unchanged main and shell stylesheets. Red/yellow turn lighting follows the move being animated, and Surge playback uses purple lighting. Native duplicate puzzle controls were removed: the embedded game owns arm/disarm, undo, restart, hint, rules and next-puzzle controls, with revision-checked native actions retaining the existing saved-move format. Player cards show remaining Surges rather than invented match points. The normal online arena is unchanged. Local renderer checks cover all three lighting states and the real ARM control.

### 22 September 2026 — full game navigation

Added direct entries for the live puzzle library, Tower, Speed Run, and profile alongside Online arena and the preserved offline board. Verified the production entry routes in a browser: the puzzle library displays packs, tier selection and saved solved/star totals; Tower displays floor progress; Speed Run displays pool selection and the start action; profile displays account and match-history access. This browser check does not establish sign-in compatibility in Navigator's separate WKWebView profile. Route regression checks cover arena-only match resumption and ensure changing destinations leaves the offline save untouched.

Validation: release build and signed app packaging passed. All 177 Python tests passed with local-server access; all seven standalone Swift checks passed (the isolated project-order preference check required access outside the sandbox). No live model request was made. Native panel layout and embedded provider sign-in were not exercised in this update.
