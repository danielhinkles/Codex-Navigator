# Codex Navigator

## Complete documentation

- [User Guide & Product Overview](docs/USER-GUIDE.md) — a complete introduction, interface manual, feature reference and practical workflows.
- [Technical Reference & Agent Editing Map](docs/TECHNICAL-REFERENCE.md) — source-file routes, architecture, storage, IPC, execution, tests and maintenance guidance.

- [Purple Surge inside Codex Navigator — Design](docs/PURPLE-SURGE-DESIGN.md) and [Implementation](docs/PURPLE-SURGE-IMPLEMENTATION.md) — the bundled offline puzzle game and online arena panel.

These guides were checked against the source on 14 September 2026 and clarify current behaviour where older notes below describe earlier versions.

A native macOS history browser built from the supplied Overview/List mockup. SwiftUI owns presentation; a local Python worker owns a persistent SQLite index and Codex integration. No third-party dependencies, API key, or model calls are required for browsing.

## Install

Codex Navigator is built from source on your Mac. There is no installer download and no account to create.

### Requirements

- macOS 14 (Sonoma) or later on Apple Silicon or Intel.
- Xcode Command Line Tools (Swift 5.9 or newer). Install with `xcode-select --install`, or install Xcode from the App Store.
- The Codex desktop app or the Codex CLI, signed in. Navigator reads its local history from `~/.codex` and talks to the `codex` executable for live features.
- `/usr/bin/python3`, which the Command Line Tools provide. No pip packages are needed.

### Build and open

```sh
git clone https://github.com/danielhinkles/Codex-Navigator.git
cd Codex-Navigator
bash scripts/build.sh
open 'dist/Codex Navigator.app'
```

The build takes about a minute the first time. It produces `dist/Codex Navigator.app`, which you can drag into `/Applications` if you like. The app is ad-hoc signed on your own machine and is not notarised; if macOS asks, right-click the app and choose **Open** once.

The first launch indexes your local Codex history progressively; recently updated sessions come first. Later launches show cached sessions immediately. Navigator keeps its own data in `~/Library/Application Support/Codex Navigator/` and never edits Codex's files.

### Check the install

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo
```

The first command runs the backend tests. The second opens the app with fictional demo data and no Codex connection, which is a safe way to look around.

### Update or uninstall

To update, pull the latest source and run `bash scripts/build.sh` again. To uninstall, delete `Codex Navigator.app` and, if you also want to remove the local index and preferences, delete `~/Library/Application Support/Codex Navigator/`.

Optional environment overrides: `NAVIGATOR_CODEX` (path to the `codex` executable), `CODEX_HOME` (Codex history location, default `~/.codex`), `NAVIGATOR_CACHE` (Navigator data directory).

## Interface

- **Overview:** project activity for the last fourteen days, sessions, and selected-session inspector.
- **List:** the full-width session table; no activity chart or inspector. Search, sorting, filters, expandable prompts, and New remain available.
- Click a disclosure chevron to expand a session’s bullet-point user prompts. Click **User prompts (n)** to choose First to Last or Last to First.
- Drag either vertical panel divider to resize Projects or Preview; widths are saved. Drag the horizontal divider below activity to change its height. As the chart narrows, older days drop off the left while recent bars and the vertical scale stay stable. Drag the top bar to move the window, and click **Codex Navigator** to return to All Sessions and clear filters.
- Click a column heading to sort; click again to reverse. Drag its right edge to resize or drag its label to reorder. View Options adds **Prompts**, **Created**, and **Token usage**, and can reset the columns.
- Search matches names and indexed user prompts. Date filters cover 1/3/6/12 hours, 1/3 days, one week, and one month. Time, asset, running, and session-type filters combine. Only supported history types are offered. At narrow widths, additional filters move into a Filters menu; Clear filters resets an empty search.
- Drag a session onto a project or **Unassigned**. Expand Unassigned to select its individual active sessions directly from the sidebar. Selecting a child clears table filters so it is visible. The context menu offers the same assignment action without dragging.
- Command-click project rows to select several, then choose **Group projects…**. The dialog lets you select more projects and choose an existing group or enter a name once. Dragging onto another project reorders the sidebar and selects Custom. Dropping onto a group header opens the grouping dialog. **Remove from group** reverses grouping.
- Organisation is local to Navigator: grouping, dragging, assigning and pinning never rearrange Codex projects or move folders on disk.
- Inspector labels distinguish **From working folder**, **Codex project**, **Navigator only**, and **Conflict**. **Use Codex location** removes an override. Dragging never silently changes Codex's working directory.
- Running rows show a green indicator and live elapsed time. An unfinished turn without fresh evidence is **Status stale**.
- Voice previews show a readable conversation with **You** and **Assistant** labels. Internal voice wrappers and repeated handoff context are removed for display, including already cached history; original session files stay unchanged.
- Select a session and press Space for its preview; double-click to open its Codex link. Preview offers text-size and contrast controls. Click an asset to select it, then press Space (or double-click) to preview; images support pinch zoom and a zoom slider. In an image preview, Space or Escape closes it; Left/Right follow the thumbnail row; Up/Down move between rows in the same column. Navigation uses the gallery’s actual width and stops at edges; an incomplete last row selects its nearest image. Right-click assets to open, reveal in Finder, or copy their path. Missing media stays visible as unavailable.
- Markdown and web links are coloured and underlined. Existing bare local paths are detected too. Right-click text for link actions; project paths offer Open, Reveal in Finder, and Copy Path.
- Project context menus provide **Logo & appearance**, folder colour, pinning, and named groups. The logo editor has a larger preview, As is / Button trim / Folder background styles, independent Overview and Project Folder checkboxes, and Reset to default (saved when you press Save). Changes refresh live.
- Sort projects alphabetically, by last update, by indexed rollout size, or by saved **Custom** order. Drag projects before another project, or onto the end drop area, to save a Custom arrangement. Switching sort modes or filtering sessions retains that arrangement. Codex project pins are mirrored read-only; Navigator pins remain local. Named groups can contain multiple projects. **Organise voice chats**, under View Options, lets you review exact project-name matches in indexed prompts before applying Navigator assignments.
- File access setup explains local-only previews and offers Full Disk Access settings to avoid separate protected-folder prompts, or ordinary folder-by-folder access. Media checks wait for this choice. Denied files show a red explanation and Retry; permission messages clear when files become readable. File access can be reopened from View Options.
- System, Light, and Dark appearance; saved view/theme choices. View Options includes app-wide text size (100–150%) and Comfortable/Compact row density.
- Up/Down and Home/End select sessions; Return opens the selected session; Command-F focuses search. Filtering out the selected row clears its inspector. Gallery arrows move image selection, and Escape restores focus when a preview closes.
- Local assignments, favourites, pins, and grouping support Undo/Redo. Save dialogs retain edits and show errors if persistence fails.

## Integration boundaries

This version indexes **local interactive Codex sessions**. ChatGPT Chat/Work histories and remote-host histories are not provided by the local App Server and are not fabricated. New Chat/Work entries are visibly disabled until a supported desktop bridge is available.

**New task in Navigator** opens Composer for the selected project. **Continue in Navigator** resumes a selected task. Write a prompt and click **Send to Codex** (Command-Return); responses stream inside Navigator, with expandable command/file-change details, approval and input cards, and Stop. The toolbar composer button reopens the current task while you browse. Multiple tasks can run concurrently, including across projects. Use the Composer menu to switch between them; each retains its own connection and approval cards. An orange Composer toolbar icon also flags input needed by a background task. Right-click a project and choose **New Task** to start there. Recent conversation and recovery state are saved in Navigator’s cache; full history remains in Codex. A disconnected prompt is never automatically resent. Lost transports get up to three automatic reconnection checks; the Reconnect button also checks the task. Tasks owned by another Codex window are followed through their saved history until that window releases ownership.

Composer uses the installed Codex App Server and its existing sign-in/model configuration. New tasks start with workspace-write access and on-request approvals. Existing tasks keep their Codex settings. Projectless tasks get their own working folder under Navigator’s Application Support directory. Submitted prompts and task context are processed by Codex’s configured provider; opening file previews does not transmit their contents. Closing Composer leaves the task connected; quitting Navigator disconnects its execution client. Reconnect checks the durable task on the next launch. Unsupported interaction types are rejected visibly and offer an Open in Codex route.

**Open new task in Codex** retains the desktop handoff using `codex://threads/new`. Desktop integration and the App Server protocol are version-sensitive. No organisation gesture invokes the execution client or changes Codex assignments.

The exposed stable metadata-update interface does not provide a verified project-assignment operation. Assignments therefore remain Navigator-only, with a saved Codex baseline for conflict detection. There is no misleading “synced” state or automatic write to Codex databases.

Saved project metadata, explicit assignments, and pins are read from Codex’s desktop state. Generated standalone session directories go into Unassigned. Project names and roots are cached for offline browsing; old Navigator logo preferences are retained when working-folder IDs resolve to saved projects.

Token Usage is the most recently recorded cumulative total from rollout token events, never the sum of repeated totals. Missing totals show **—** / **Unavailable**. Runtime is accumulated from available turn timings. `≥` denotes a partial total; `—` means unavailable. Session span is separate. **Size** is the on-disk local rollout file size, not the total of paginated history and media. Media counts include unique explicit local references that the index can recover; embedded base64 and remote assets are not downloaded. Activity uses recorded runtime distributed across the days of each turn. These are measurements of available data, not estimates of hidden history.

## Development and verification

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
PYTHONDONTWRITEBYTECODE=1 python3 scripts/smoke_live.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/smoke_worker.py
```

The live smoke test only reads Codex and creates an isolated temporary Navigator cache. It does not create, resume, edit, or run sessions.

```sh
# Isolated demo UI; never mixes fixture data with the real index.
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo

# Render this app's own view for layout verification.
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo --snapshot /tmp/overview.png
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo --list --snapshot /tmp/list.png

# Exercise native Space, gallery focus, search, selection, and local undo.
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo --interaction-check

# Divider limits and theme changes without requiring a fullscreen-capable test host.
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo --window-check

# Exercise native divider limits and theme changes across full-screen transitions.
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo --interface-check
```

Environment overrides: `NAVIGATOR_CODEX` (CLI executable), `CODEX_HOME` (history location), `NAVIGATOR_CACHE` (Navigator data directory). The UI worker communicates through private stdin/stdout pipes; it exposes no HTTP listener.

See [ARCHITECTURE.md](ARCHITECTURE.md) for the data and update pipeline.

## Focused review workflows

Navigator keeps one local history library across Codex sign-ins within your macOS user profile. Switching accounts keeps locally stored work easy to find; it does not download another account’s cloud history or synchronise between machines.

The inspector leads with the latest request and response. Continue in Navigator is the primary action, with Open in Codex secondary. The activity chart remains visible by default as a visual memory aid, with a smaller heading and a saved collapse setting.

Quick Prompts keep their instructions separate from your context. Switching presets replaces the instructions, and clearing a preset preserves your text. Evaluate Design requests an interactive review: five positives (Love/Like), then five negatives (Dislike/Hate), agreement menus, optional explanations, and selectable recommendations. Preparing feedback creates an editable follow-up; only Send to Codex submits it. With nothing selected, the follow-up requests discussion only. Responses that do not match the structured format remain readable as ordinary conversation. Feedback controls survive closing and reopening Composer during the current Navigator run; unsent ratings are not saved across app restarts.


### Launching projects

Right-click a project and choose **Launch Project**. On first use, Navigator detects launch options and asks you to choose when there is more than one. **Launch setup…** changes the saved choice. **Choose launch target…** selects a specific app, HTML file, Python or shell script, executable, or `project.godot`; **Custom command…** in the setup picker accepts a Terminal command, working folder, and optional localhost browser address.

- Web projects: discovers `dev`, `start`, and `serve` package scripts, respecting npm, pnpm, Yarn or Bun. Runs the selected script and opens its localhost address when ready. Existing dependencies are required; package scripts can run their normal pre/post hooks.
- Static sites and Unity/Godot web exports: serves the selected HTML file on a free localhost port, including WebAssembly MIME types, gzip/Brotli headers, and isolation headers for engine exports.
- Unity: discovers nested Mac app builds and Unity project folders. The editor option opens the exact installed version from `ProjectVersion.txt`; press Play in Unity. It does not build, install editors, or upgrade the project.
- Godot: runs `project.godot` with an installed Godot executable from PATH or the usual Applications folder. Custom commands cover other engine locations and versions.
- Python: runs the entry script from its folder, using `.venv/bin/python` or `venv/bin/python` when present, otherwise `/usr/bin/python3`.
- Other projects: shell scripts honour their shebang; native executables and saved custom commands cover other launch workflows. Windows executables require a suitable runtime and custom command.

**Show launch log** opens process output and errors. **Stop launched process** stops the process owned by Navigator for that project. Repeated clicks do not start duplicate managed processes; different projects can run concurrently. Web/custom-command processes stop when Navigator quits. Native app builds and Unity editors run independently. Detection is bounded to three subfolder levels and skips dependency/source asset caches; choose a target manually for deeper layouts. Preferences remain local to Navigator; detection does not execute scripts or modify project files.

Launch integration references: [Godot command line](https://docs.godotengine.org/en/4.4/tutorials/editor/command_line_tutorial.html), [Unity editor arguments](https://docs.unity3d.com/6000.0/Documentation/Manual/EditorCommandLineArguments.html), [npm script lifecycle](https://docs.npmjs.com/cli/v8/using-npm/scripts/).

### Purple Surge

The right-edge Purple Surge tab opens a compact game drawer in Navigator and Composer. Play 200 bundled offline puzzles, or choose **Play online** to enter Purple Surge’s existing arena inside the panel. Puzzle moves save locally, task attention stays visible, and invitations can be disabled. Online match clocks continue while hidden. See [integration notes and verification limits](docs/PURPLE-SURGE-IMPLEMENTATION.md).

### Composer, approvals, and attention

Double-click a session (or press Return in the sessions list) to continue in the
main Composer panel. **Sessions** returns to the list and preserves the draft.
The toolbar's right-sidebar button hides or reopens the inspector.
Hover over an available media thumbnail and press Space to preview it; Space
again closes the preview. Space still types normally in text editors.

Approval cards expose Codex's supported **Allow for session** and **Always allow
this command rule** choices, as well as one-time approval. Saved rules use the
exact rule proposed by Codex; session grants do not mean permanent unrestricted
access. Navigator never invents a command prefix or silently approves a request.

Navigator requests macOS notification access when a task first needs attention.
Input requests and failures trigger a banner/sound and Dock attention; repeated
state refreshes do not repeat the notification. Click a notification to open its
task in Composer. macOS notification settings control banner/sound delivery.

Browsing, indexing, previews, and notifications do not submit model turns.
Opening Composer resumes/reads history, and sending submits one Codex turn using
the existing account. Quick Prompt instructions, selected skills, and supplied
context are part of that submitted turn and can affect usage, alongside model,
reasoning, tools, and caching. Navigator does not guarantee identical token counts
for two independently executed tasks.

### Prompt attachments

Drop one or more files, images, folders, or web links into the Composer prompt,
use **Attach**, or paste an image/file from the clipboard. Images appear as
thumbnails; other items appear as named cards. Click a card to preview it (web
links open in the browser), or use its × button to remove it. Attachments are
saved separately for each task and remain in the draft if submission is rejected.

PNG/JPEG/WebP/GIF images use Codex's `localImage` input, and direct web image
links use `image`. Other readable image formats, including HEIC/TIFF, are
converted to a local PNG copy when supported by macOS. Conversion uses the first
image/frame. Documents, code, spreadsheets, audio, video, archives, arbitrary
other local files, and folders are accepted without an extension whitelist and
sent as local references for Codex's tools to inspect. Actual interpretation
still depends on the model, available tools, and task permissions.

Finder file drops reference the original item without moving or editing it.
Clipboard image data and files promised by another app are saved in Navigator's
attachment cache. Those imported copies are included in Navigator backups;
external source files are not bundled or modified. Removing a card does not
delete the original file. Browser/app-specific drags must provide a file URL,
file promise, image data, or web URL; unreadable drops show an error.

### New projects and sessions

Use **New** above **All Sessions**:

- **New Project** asks for a name and a folder. The folder picker supports
  selecting an existing folder or creating a new one with **New Folder**.
  Navigator registers it through Codex's native `project/create` API and uses
  the returned project identity. A folder already registered with Codex reuses
  its existing project. No prompt or model turn is sent during project creation.
- **New Session** lets you select a project (defaulting to the selected project)
  or start without one, then opens the embedded Composer. Project sessions send
  the native project ID and use the selected project's working folder.

Project creation is the explicit exception to Navigator's local organisation
boundary. Dragging, grouping, pinning, sorting, and assigning existing items
still change only Navigator metadata. Codex state files are never edited
 directly; registered projects are read through `project/list` and cached locally.
Retries reuse a durable idempotency key and first check for an existing project
for the folder, so an uncertain response does not create duplicates.
