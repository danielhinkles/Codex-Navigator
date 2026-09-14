# Codex Navigator — Technical Reference & Agent Editing Map

Implementation reference reviewed **14 September 2026**. The packaging script declares version **0.4.0**, build **4**; the RPC handshake independently advertises client version **0.1.0**. This document describes the source tree currently present in the workspace, not a verified Git revision: the workspace was not a Git repository at review time.

The companion `docs/USER-GUIDE.md` explains the product for users. This reference maps visible behaviour to symbols, data, boundaries and validation. It supersedes conflicting historical statements in `ARCHITECTURE.md`; runtime code and regression tests remain authoritative.

## Contents

1. [Start here: rules and editing routes](#1-start-here-rules-and-editing-routes)
2. [System architecture and lifecycle](#2-system-architecture-and-lifecycle)
3. [Complete source map](#3-complete-source-map)
4. [Storage, identifiers and data contracts](#4-storage-identifiers-and-data-contracts)
5. [Indexing, history and running status](#5-indexing-history-and-running-status)
6. [Local organisation and undo](#6-local-organisation-and-undo)
7. [UI composition, interaction and presentation](#7-ui-composition-interaction-and-presentation)
8. [Preview and transcript pipeline](#8-preview-and-transcript-pipeline)
9. [Composer execution and recovery](#9-composer-execution-and-recovery)
10. [Quick Prompts and structured design reviews](#10-quick-prompts-and-structured-design-reviews)
11. [Project launching](#11-project-launching)
12. [IPC action and event reference](#12-ipc-action-and-event-reference)
13. [Performance contracts](#13-performance-contracts)
14. [Build, tests and diagnostics](#14-build-tests-and-diagnostics)
15. [Change recipes and maintenance limits](#15-change-recipes-and-maintenance-limits)

## 1. Start here: rules and editing routes

Read `AGENTS.md` before changing this project. Its mandatory organisation boundary is:

> dragging, dropping, grouping, pinning, sorting, and assigning items in Navigator must only change Navigator's own local metadata.

The rest of that rule prohibits changes to Codex project assignments, saved folders and source files, filesystem moves or renames as an organisation side effect, and upstream organisation synchronisation. It explicitly requires regression coverage. This applies even when a future Codex API could technically change an assignment.

There are three distinct operating boundaries:

| Operation | Allowed effects in the current design |
| --- | --- |
| Browse/index/preview | Read local Codex history and project metadata, persist Navigator projections, read preview files after access selection. No model turn. |
| Organise/personalise | Write Navigator SQLite preferences/overrides, Navigator UserDefaults and copied local logos. No source writes or execution client connection. |
| Explicit Composer send or project launch | Execute through Codex or a selected local program. These operations can change working files according to the explicit request, project behaviour and permissions. |

The app is consequently not globally read-only. The browser transport is read-only, while the Composer transport is deliberately interactive. Do not route ordinary browsing or organisation through the latter.

### Find the files for a requested change

Paths in tables below are repository-relative search keys. Symbol names are more durable than line numbers. Paths are relative to the repository root.

| Change requested | Start at | Follow through / regression coverage |
| --- | --- | --- |
| Search, conversation reader, scope, filters, table sorting | `Sources/Navigator/NavigatorView.swift`: `computeFiltered`, `requestSearch`, `conversationTarget`; `LibraryViews.swift`: `ConversationReader` | `Model.swift`: request correlation; `backend/index.py`: `projection`, `search`, `conversation`; responsiveness/library tests. |
| Add a table column | `NavigatorView.swift`: `allColumns`, `width`, `column`, `cell`, `computeFiltered` | Update `Session` and backend projection if new data is needed; `InterfaceCheck.swift` for resizing. |
| Inspector or session preview | `NavigatorView.swift`: `inspector`; `PreviewViews.swift`: `SessionPreview` | `Model.swift`: `Detail`; `index.py`: `detail`; `InteractionCheck.swift`. |
| Activity or runtime | `NavigatorView.swift`: `ActivityChart`, `overviewHeader`; `Model.swift`: `duration`, `durationLabel` | `index.py`: `project_turn`, `summarize`, `observe`; timing tests in `test_index.py` and `test_responsiveness.py`. |
| Source project matching or assignment labels | `backend/index.py`: `native_project`, `canonical_project`, `summarize`, `snapshot` | `test_navigation.py`, `test_preview_access.py`; preserve source/local separation. |
| Session assignment, bulk favourites, rename or undo | `backend/worker.py`: `command`, `local_state`; `Model.swift`: `perform`, `applyUndo`; `NavigatorView.swift`: multi-selection | `index.py`: `assign`, `restore_assignment`, `save_preference`; organisation boundary tests. |
| Backup, restore, rebuild or health report | `LibraryViews.swift`: `LibrarySettings`; `backend/library.py`; `worker.py`: maintenance commands | `index.py`: `rebuild_history`, `diagnostics`; `test_library_backend.py`. |
| Sidebar order, project dragging | `ProjectOrder.swift`; `ProjectDragSurface.swift`; `NavigatorView.swift`: `reorderProjects`, `drop`, `projectSections` | `tests/ProjectOrderCheck.swift`, `ProjectDragCheck.swift`, `InteractionCheck.swift`. |
| Group projects | `ProjectGroupingView.swift`; `NavigatorView.swift`: `beginGrouping` | `worker.py`: `groupProjects`; `index.py`: `group_projects`; navigation tests. |
| Logo or folder appearance | `PreviewViews.swift`: `LogoEditor`, `LogoMark`, `ProjectIcon`; `Model.swift`: `folderColour` | `worker.py`: `preference`; `index.py`: `snapshot`; logo tests in `test_navigation.py`. |
| Theme, density, text scale, panel resizing | `AppAppearance.swift`, `ResizeHandle.swift`, `NavigatorView.swift` | `PreviewViews.swift`: divider wrappers; `InterfaceCheck.swift`. |
| Keyboard focus or Find | `KeyboardSurface.swift`, `NavigatorCommands.swift`, `PreviewKeyboard.swift` | `NavigatorView.swift`, `PreviewViews.swift`, `GridNavigation.swift`; native interaction and grid checks. |
| File access or missing images | `PreviewAccess.swift`; `index.py`: media helpers, `detail` | `PreviewViews.swift`: gallery/caches; `Model.swift`: `setPreviewAccess`; `test_preview_access.py`. |
| Image grid, zoom or Quick Look | `PreviewViews.swift`: `MediaGallery`, `AssetPreview`, `ZoomImage`, `NativeAssetPreview` | `GridNavigation.swift`, `PreviewKeyboard.swift`; grid and native interaction checks. |
| Voice text cleanup or suggestions | `backend/transcript.py`; `PreviewViews.swift`: `VoiceConversation`, `VoiceOrganizer` | `index.py`: `projection`, `detail`; `test_transcript.py`. |
| Start/send/stop/reconnect a task | `backend/composer.py`: `Composer.command`, `tick`, `reconnect` | `worker.py`: composer routing; `Model.swift`: `submitComposer`; `test_composer.py`. |
| Model, skill, plugin or usage controls | `ComposerView.swift`: `runtimeControls`; `composer.py`: `capabilities`, `turn_options`, `five_hour` | `ComposerState` wire types; validate against the installed server's protocol. |
| Concurrent tasks | `composer.py`: `ComposerManager` | `ComposerView.swift`: menu; `test_parallel_tasks_keep_connections_and_approvals_isolated`. |
| Approval or input card | `ComposerView.swift`: `ComposerApprovalCard`; `composer.py`: `event`, `reply` | `rpc.py`: interactive routing; `test_rpc_interactive.py`, `test_composer.py`. |
| Quick Prompt text | `QuickPrompts.swift`: `QuickPrompt.standard` | `ComposerView.swift`: `ComposerStore.select`, `submissionText`; interaction checks. |
| Structured design review | `DesignReviewModel.swift`, `DesignReview.swift` | `ComposerView.swift`: rendering and prepared feedback; fixture and `DesignReviewCheck.swift`. |
| Launch target discovery | `LaunchPlan.swift`: `LaunchDiscovery.plans`, `file` | `tests/ProjectLauncherCheck.swift`; discovery must remain non-executing. |
| Launch command/process/server | `ProjectLauncher.swift`; `backend/launcher.py` | `test_launcher.py`, `ProjectLauncherCheck.swift`. |
| RPC compatibility / missing history | `backend/rpc.py`, `worker.py`: `enumeration_request`, `hydration_request` | `test_rpc_interactive.py`, `test_index.py`, read-only smoke scripts. |
| Bundle, deployment target or permissions strings | `Package.swift`, `scripts/build.sh` | `NavigatorApp.swift` for window/startup hooks. |

Use targeted searches rather than scanning generated bundles:

```sh
rg -n 'func computeFiltered|func cell|func inspector' Sources/Navigator
rg -n 'def native_project|def assign|def summarize' backend/index.py
rg -n 'organisation_never|bulk_assignment|parallel_tasks' tests
rg --files Sources backend tests scripts docs
```

## 2. System architecture and lifecycle

```text
NavigatorApp / shared NavigatorModel
  ├─ SwiftUI window(s): NavigatorView, previews, ComposerView
  ├─ AppKit bridges: keyboard, dragging, resizing, Quick Look, launching
  ├─ UserDefaults: interface + local launch settings
  │
  └─ private newline-delimited JSON stdin/stdout pipes
       └─ Python Worker (one SQLite owner thread)
            ├─ Index → navigator.sqlite (WAL), logos/
            ├─ browsing CodexRPC → local codex app-server subprocess
            │    thread/list, thread/turns/list, thread/read
            ├─ read-only desktop state + rollout lifecycle tail
            └─ lazily created ComposerManager
                 └─ one Composer per task
                      ├─ dedicated interactive CodexRPC + one-thread executor
                      └─ composers/<key>/composer.json, optional tasks/<uuid>/

Explicit ProjectLauncher action (separate from worker IPC)
  ├─ NSWorkspace → native app
  └─ python3 backend/launcher.py --stdin   (JSON plan written to stdin)
       ├─ command/script/game process group + temporary log
       └─ static localhost HTTP server / browser readiness check
```

### Startup and shutdown

`NavigatorApp` creates one `@StateObject NavigatorModel` shared by its WindowGroup. The window uses a hidden title bar, a 1460 × 900 default size and 1080 × 680 minimum. `AppDelegate` activates the app and provides demo/snapshot/native-test hooks. Closing the last window terminates the app.

`NavigatorModel.init → start` locates the bundled `backend/worker.py`, falling back to the current directory for development. It launches `/usr/bin/python3` with private pipes. The UI decodes input on `navigator.ipc`, updates published state on the main queue and writes commands on a separate serial `navigator.write` queue. It never opens SQLite or directly indexes Codex files.

The worker opens its cache, loads whitelisted desktop metadata (or demo fixtures), publishes cached results and begins reconciliation. One background executor runs blocking index RPC; the worker thread applies completed results and all SQLite writes. Commands are drained before background results, keeping cached selection and local writes responsive.

If the worker exits unexpectedly, Model retains history, marks running rows stale, fails outstanding save callbacks, marks Composer disconnected and restarts with delays of `min(30, 2 × restartAttempts)` seconds. The counter is not reset on successful start in current code. `stop` marks shutdown intentional, queues `quit`, closes stdin and terminates the process if still running. Worker shutdown closes Composer clients, closes browsing RPC and shuts down its executor.

## 3. Complete source map

### Swift production and verification files

| File under `Sources/Navigator/` | Responsibility / main symbols |
| --- | --- |
| [NavigatorApp.swift](../Sources/Navigator/NavigatorApp.swift) | App entry, preferences suite, shared model, delegate, initial sizing, demo/test/snapshot dispatch. |
| [Model.swift](../Sources/Navigator/Model.swift) | Wire models (`Session`, `Project`, `Detail`, etc.); worker process/IPC; published browser state; derived project stats; watches; correlated mutations/undo; submission assembly bridge; URL opening; formatting helpers. |
| [NavigatorView.swift](../Sources/Navigator/NavigatorView.swift) | Main screen, scopes, filters, table, column layout, sidebar grouping/order, context menus, inspector, sheets, watch calculation, activity chart. Largest UI composition file. |
| [LibraryViews.swift](../Sources/Navigator/LibraryViews.swift) | Conversation reader, local search presentation, Library & diagnostics sheet, safe preference export/restore and local Undo toast. |
| [ComposerView.swift](../Sources/Navigator/ComposerView.swift) | Composer wire models and `ComposerStore`; sheet, per-task editor switching, messages, runtime options, preset input, approval/input cards, toolbar indicator. |
| [ComposerLocalState.swift](../Sources/Navigator/ComposerLocalState.swift) | Debounced per-task editor archive, personal-prompt persistence and synchronous flush/reload for backup and restore. |
| [QuickPrompts.swift](../Sources/Navigator/QuickPrompts.swift) | Four built-in preset IDs, titles, length labels and full instruction text. |
| [DesignReviewModel.swift](../Sources/Navigator/DesignReviewModel.swift) | Decodable review schema, strict parser, model-format instructions, `ReviewFeedback.prompt`. Foundation-only and independently testable. |
| [DesignReview.swift](../Sources/Navigator/DesignReview.swift) | Interactive findings, ratings, notes, recommendation selection and feedback preparation view. |
| [PreviewViews.swift](../Sources/Navigator/PreviewViews.swift) | Titlebar drag bridge, logos/editor, local path/attributed links, text/image/thumbnail caches, galleries, image/Quick Look preview, voice organiser/conversation, session preview, divider wrappers and rename dialog. |
| [PreviewAccess.swift](../Sources/Navigator/PreviewAccess.swift) | Saved access-choice interpretation, System Settings route, setup sheet and access notices. |
| [PreviewKeyboard.swift](../Sources/Navigator/PreviewKeyboard.swift) | Local keyboard monitor bound to the preview's exact NSWindow, allowing preview keys to survive nested responder changes. |
| [KeyboardSurface.swift](../Sources/Navigator/KeyboardSurface.swift) | Focusable native responder for table/gallery keyboard actions; avoids application-wide key interception. |
| [NavigatorCommands.swift](../Sources/Navigator/NavigatorCommands.swift) | Window-specific search registration and native Command-F menu command. |
| [GridNavigation.swift](../Sources/Navigator/GridNavigation.swift) | Pure geometry: adaptive column count and edge-stopping arrow movement. |
| [ResizeHandle.swift](../Sources/Navigator/ResizeHandle.swift) | Native drag mechanics with fixed start coordinates/limits, cursor and commit callback. |
| [AppAppearance.swift](../Sources/Navigator/AppAppearance.swift) | Shared coalesced theme controller; system appearance notifications and application/window override handling. |
| [ProjectGroupingView.swift](../Sources/Navigator/ProjectGroupingView.swift) | Searchable multi-project checklist, existing/new group name and asynchronous save/error state. |
| [ProjectOrder.swift](../Sources/Navigator/ProjectOrder.swift) | Pure order encode/decode, current/saved reconciliation and block move semantics. |
| [ProjectDragSurface.swift](../Sources/Navigator/ProjectDragSurface.swift) | Native project drag initiation, selection click forwarding and string-payload drop handling. |
| [SessionSelection.swift](../Sources/Navigator/SessionSelection.swift) | Pure visible-range and toggle selection rules for bulk session actions. |
| [LaunchPlan.swift](../Sources/Navigator/LaunchPlan.swift) | Codable launch plan, bounded read-only discovery and manual file classification. |
| [ProjectLauncher.swift](../Sources/Navigator/ProjectLauncher.swift) | Saved plan preferences, setup/target dialogs, native launch, Python helper lifecycle and log/stop actions. |
| [InteractionCheck.swift](../Sources/Navigator/InteractionCheck.swift) | Demo native interaction harness and `InteractionProbe` registry used by production views only when enabled. |
| [InterfaceCheck.swift](../Sources/Navigator/InterfaceCheck.swift) | Native resize/theme/window/fullscreen test harness, including actual hit targets and achieved widths. |
| [ProjectDragCheck.swift](../Sources/Navigator/ProjectDragCheck.swift) | Demo mouse-event verification of native project dragging. |
| [DragTestInfo.swift](../Sources/Navigator/DragTestInfo.swift) | Native test-view geometry lookup support for drag verification. |

### Backend and repository assets

| Path | Role |
| --- | --- |
| [backend/index.py](../backend/index.py) | SQLite schema, metadata, complete user/Codex turn projections, local search/conversation pages, hydration checkpoints, media, summaries and diagnostics. |
| [backend/worker.py](../backend/worker.py) | CLI entry, command queue/IPC dispatch, index scheduler, delta publication, local mutation validation/acknowledgements, library maintenance and lazy Composer routing. |
| [backend/library.py](../backend/library.py) | Portable SQLite snapshot backup, archive validation, atomic restore, containment checks and projectless-working-file preservation. |
| [backend/rpc.py](../backend/rpc.py) | Codex executable discovery, app-server subprocess, JSON request correlation, timeout/EOF handling, interactive opt-in and connection tags. |
| [backend/composer.py](../backend/composer.py) | Execution state machine, capabilities, streaming events, user decisions, stop, ownership observation, recovery persistence and multiple-client manager. |
| [backend/transcript.py](../backend/transcript.py) | Voice wrapper parsing, delta overlap reconciliation and presentation cleanup. |
| [backend/launcher.py](../backend/launcher.py) | Standalone explicit execution helper, interpreter/engine selection, localhost discovery/readiness and static server. |
| [backend/demo.py](../backend/demo.py) | Deterministic fixture sessions/projects/history for isolated app demonstrations. |
| `Package.swift` | Swift tools 5.9, macOS 14 target, one executable target named Navigator/product CodexNavigator; no third-party Swift packages. |
| [scripts/build.sh](../scripts/build.sh) | Release compilation, bundle assembly, usage descriptions, signing and staged replacement of `dist` app. |
| [scripts/smoke_live.py](../scripts/smoke_live.py) | Read-only live Codex enumeration/hydration smoke using isolated cache. |
| [scripts/smoke_worker.py](../scripts/smoke_worker.py) | Live worker IPC/selection/latency smoke with temporary cache. |
| [scripts/smoke_composer.py](../scripts/smoke_composer.py) | Explicit opt-in model smoke; ephemeral read-only task, still sends a real provider request. |
| `tests/` | Python unittest suites, independently compiled Swift checks and design-review fixture. |
| `codex-navigator-mockup.png` | Original visual reference and packaged demo-preview image required by build script. |
| `README.md`, `ARCHITECTURE.md` | Earlier project overview/architecture notes, now linked to these comprehensive guides. |
| `AGENTS.md` | Mandatory local-only organisation boundary. |
| `audit/` | Local-only dated measurements, test logs and captures (git-ignored); historical evidence, not runtime source. |
| `output/` | Local-only generated media and snapshots (git-ignored); not an application dependency. |
| `.build/`, `dist/` | Generated Swift artifacts/staged old bundles and packaged application. Edit original source, never bundled copies. |

## 4. Storage, identifiers and data contracts

### Persistent locations

| Data | Location / owner |
| --- | --- |
| History cache and organisation | Default `~/Library/Application Support/Codex Navigator/navigator.sqlite`; Python Index. SQLite uses WAL. |
| Copied logo images | `<cache>/logos/<content-derived hash>.<extension>`; worker preference action. |
| Library backup | User-selected ZIP archive; `backend/library.py` writes a SQLite snapshot plus regular Navigator-owned cache files and a sanitised UI-preference manifest. |
| Current Composer recovery | `<cache>/composers/<key>/composer.json`; one client per directory. |
| Per-task Composer editor | `<cache>/composer-editors.json`; debounced archive of drafts, options, prompt instructions and review feedback keyed by Composer task key. |
| Legacy Composer recovery | `<cache>/composer.json`, loaded by manager if present. |
| Projectless working folders | `<composer-directory>/tasks/<uuid>/`, allocated on first send without a CWD. With current manager this is normally nested under `composers/<key>/`. |
| UI and launch preferences | UserDefaults, normally bundle domain `local.navigator.codex`. |
| Demo worker cache | A per-process temporary `navigator-demo-<pid>` directory. Demo view preferences use an isolated `navigator.demo.<pid>` suite. |
| Launch output | Temporary `navigator-launch-<uuid>.log`; an in-memory map keeps project-to-log associations for this run. |
| Source metadata | Read-only `<CODEX_HOME>/.codex-global-state.json`; history through App Server plus rollout paths returned in metadata. |

The worker sets `umask(0o077)` at its entry point. The cache contains prompt text, metadata and recent Composer output; it is not encrypted by application code. Library & diagnostics can make a portable Navigator backup, but it is not a Codex-source archive. Never recommend deleting the entire directory as a harmless reindex: it also holds unique organisation, drafts and potentially projectless working files.

### Database schema

`Index.__init__` creates tables idempotently. `SCHEMA_VERSION = 3` / `PRAGMA user_version=3` track media and conversational-entry projection migration, rather than a general migration framework. Old rows are upgraded from retained prompts and final response without touching preferences, overrides, logos or Composer data.

| Table | Columns / key | Purpose |
| --- | --- | --- |
| `metadata` | `id` PK, `data`, `fingerprint` | Raw thread metadata JSON and a fingerprint for hydration decisions. |
| `turns` | `(thread,id)` PK, `data` | Reduced per-turn JSON projection. |
| `hydration` | `thread` PK, `fingerprint`, `cursor`, `complete`, `checked`, `error` | Durable backfill continuation and last check/error. |
| `overrides` | `thread` PK, `project`, `baseline` | Local desired project and source project at time of assignment. |
| `preferences` | `id` PK, `data` | Session/project JSON preferences plus reserved `__desktop__` metadata cache. |
| `observations` | `thread` PK, `data` | Rollout inode/offset/lifecycle/token/freshness checkpoint. |
| `turn_versions` | `thread` PK, `version` | Revision bumped by turn insert/update/delete triggers for cache invalidation. |

### Stable identities and precedence

Thread IDs come from Codex. Projects use `codex:<legacy-project-id>` for saved desktop projects, `cwd:<path>` for legacy CWD grouping or `unassigned`. Never derive user overrides from a display name.

Desktop state is whitelisted to `local-projects`, `thread-project-assignments`, `app-server-project-id-by-legacy-project-id-by-host`, `projectless-thread-ids`, `pinned-project-ids` and `pinned-thread-ids`. Authentication or arbitrary global state is not copied. On read failure, Index uses cached `__desktop__` metadata.

`native_project(record)` resolves in this order:

1. Explicit desktop projectless membership wins, including over stale server project hints.
2. Server `projectId`, normalised through the server-to-legacy mapping.
3. Explicit desktop thread assignment.
4. Longest matching saved root for the task's CWD.
5. Unassigned when desktop metadata exists or the path resembles generated standalone work.
6. CWD grouping for legacy CLI-only data without desktop metadata.

`canonical_project` normalises old project IDs and exact CWD roots. During project publication, missing new-ID preferences may inherit old CWD-key preferences, preserving custom logos and related settings. A saved project can have several roots; its displayed/launch root is the first root in the current implementation.

### UI wire records

`Session` is a summary: identity/title, effective and native project, `sync` provenance, CWD, dates, accumulated seconds/activeStart, status/coverage, hydration state/error, sizes/counts, archive/favourite, type, indexed search text, optional tokens, source/model and last-check time. `running` is derived from `status == "Running"`.

`Detail` contains ID, prompts, local media, last response, voice messages and activity intervals. A prompt has ID/text/time; media has path-based ID, path/name/kind, availability, optional reason and revision. An activity interval has start/end/seconds. `Project` includes name/path/colour/logo/style, independent logo placement flags, group, pin and source-pin flags.

`Snapshot` has sessions/projects/activity plus health. `Delta` has changed sessions, removed IDs, optional changed projects and changed activity. `Envelope.type` selects decoding. New non-optional Swift fields require coordinated Python output changes; optional additions are easier to roll out safely.

### Preferences

View preference keys use `navigator.`: `theme`, `view`, `textScale`, `density`, `projectSort`, `customProjectOrder`, `nameFillsSpace`, `columns`, `columnWidths`, `unassignedExpanded`, `showActivity`, `sidebarWidth`, `inspectorWidth`, `activityHeight`, `previewAccess`, `previewFont`, `previewContrast`.

`columns` is a pipe-separated sequence of internal names; `columnWidths` is JSON; Custom order is a JSON ID array. Internal column names include `Date Created` and `Token Usage`, displayed as Created and Token usage. Internal project sort `Biggest` is displayed as Largest history.

Launch preferences use `navigator.launchPlan.<project-id>` with encoded `LaunchPlan`; legacy `navigator.launchTarget.<project-id>` paths are still read and removed when a plan is saved. ProjectLauncher uses `UserDefaults.standard` directly, so its settings are not automatically isolated by the demo view suite.

SQLite preference fields include `alias`, `favourite`, `colour`, `name`, `pinned`, `group`, `logo`, `logoStyle`, `logoOverview`, `logoFolder`. Backend support for `name` does not imply a project rename control exists in the UI.

## 5. Indexing, history and running status

### Enumeration and hydration

`Worker.enumeration_request` pages `thread/list` separately for active and archived records, limit 100, sorted by `updated_at`, with `useStateDbOnly=True` and source kinds `cli`, `vscode`, `exec`, `appServer`, `unknown`. Subagents are intentionally excluded. Only complete successful enumeration reconciles missing IDs; disconnects or partial upserts never replace history with an empty library.

`Index.upsert_metadata` fingerprints `updatedAt`, `path`, `historyMode`, `name`, `projectId`, `cwd` and `archived`. Stable completed records need no new hydration. For paginated history, the worker requests `thread/turns/list` with ten turns, descending order and `itemsView=full`. A matching incomplete fingerprint resumes its cursor. Changed heads read newest-first until exhaustion or a known completed boundary. Legacy records use `thread/read(includeTurns=True)`.

`cache_page` stores reduced projections idempotently. A refreshed head removes cached newer turns absent from the response, supporting rollback. Legacy replacement replaces all turns. It does not perform arbitrary deep-history diffing beyond an unchanged boundary; deep historical rewrites can need a deliberate cache repair strategy.

The scheduler prioritises watched sessions, then active sessions, then most recent updates. Enumeration is due every five seconds; active hydration is eligible after two seconds. Scheduling runs at 0.5-second intervals, publication at 0.2 seconds, and the command wait is 0.05 seconds. A failed history retains its data and retries after 60 seconds; a connection failure retries after 15 seconds.

### Turn projection

`project_turn` retains every projected user and assistant item with its turn/item identity, plus media references from supported item kinds, unique file-change paths, user/assistant message count, start/end/duration/status. It does not persist generic tool output or inline images in the index. Composer has a separate bounded live-output cache that can include command output and file diffs.

`projection` aggregates prompt/search text, conversational entries, seconds, media paths, changed-file counts, messages and activity. `search(query, scope_ids, limit)` returns up to 200 local matching passages with thread/turn/item/role IDs and incomplete-history coverage. `conversation(id, cursor, limit, around_item_id)` returns chronological pages with an opaque earlier-page cursor. A conversation request prioritises that thread's normal read-only paginated hydration; it never uses Composer or starts a model. `detail` adds readable voice presentation and file availability. User prompt times currently come from turn start, rather than a distinct timestamp for each user item.

### Observed status and tokens

The private App Server cannot authoritatively reflect another desktop process's execution at every moment. `Index.observe` therefore reads rollout JSONL files without mutation. It tracks device/inode, a durable complete-line offset, in-memory partial buffers and file revision. Replacement/truncation resets the checkpoint. Each call has a default 256 KiB read budget; the worker's observation pass has a global 6 ms budget and advances a round-robin cursor.

An unmatched `task_started` records a turn/start. Matching completion or abort clears it. A recently modified file supplies freshness for 30 seconds. API `inProgress` is accepted with a hydration check less than 20 seconds old while connected. An unmatched start without fresh evidence becomes Status stale. Live seconds are added in Swift only for `Running`; stale timers do not keep growing.

`token_count.info.total_token_usage.total_tokens` replaces the last observed cumulative total. Never sum repeated cumulative events. Records over 1 MiB are skipped to their newline in bounded passes; the durable cursor never advances halfway through a record.

Runtime prefers `durationMs`, otherwise a usable start/end interval. Coverage is complete, partial or unavailable. Session span is a separate modified-minus-created value. File size is `getsize(rollout path)`, not project size or all paginated transcript bytes. Media counts are deduplicated references, not only readable files.

## 6. Local organisation and undo

For assignment, Worker validates the destination against current projects plus Unassigned. `Index.assign` stores `(thread, desiredProject, baselineNativeProject)`; assigning back to the current native location removes the override. `restore` deletes it. Source metadata remains independent.

`summarize` keeps the local destination while comparing the stored baseline with the current native project. A changed source baseline is Conflict; a differing local destination with unchanged baseline is Navigator only. Root inference is labelled From working folder, not an explicit Codex project assignment.

Bulk assignment and `favouriteMany` validate every thread ID and destination/state before entering one transaction. `favouriteMany` changes only Navigator preference blobs and is undoable through the same `restoreLocal` snapshot path. Grouping validates selected projects and trims a group name up to 120 characters. It writes each project's preference blob. Pins are the local pin OR a mirrored source pin. Favourites use a local preference when present and fall back to source pinned-thread membership otherwise.

`Model.send` redirects organisation actions without request IDs through `perform`. A UUID correlates the worker acknowledgement with a completion closure and UndoManager. `Worker.local_state` captures previous preference and override rows; `ack.undo` returns a `restoreLocal` command. Undo restores exactly those local rows, with Redo replaying the opposite operation. `LocalChangeNotice` exposes a short, correlated Undo toast. Commands fail visibly if the worker disconnects before acknowledgement. UI completion means the local action was accepted, not that Codex was modified.

Sidebar Custom order bypasses SQLite and uses UserDefaults. `ProjectOrder` reconciles saved IDs, removes unknowns, appends new IDs deterministically and preserves block order during moves. `projectSections` assembles group blocks after sorting; do not assume the flattened Custom array can visually split a group. Sorting/filtering must never mutate the stored Custom array.

Organisation regression anchors include `test_organisation_never_writes_codex_or_calls_service`, `test_organisation_never_connects_execution_client_or_writes_upstream` and `test_bulk_assignment_and_undo_are_atomic_and_local`. Keep them passing and extend them for new organisation gestures.

## 7. UI composition, interaction and presentation

`NavigatorView` owns per-window scope, search, single/multiple selection, expansion, table sort/filter state and a watch ID. `SessionSelection` supplies range and toggle semantics only over the current visible IDs; the selection bar routes bulk favourite/assignment actions to local worker mutations. Both modes use the same cached `visibleSessions`. All Sessions excludes archived records; Recent uses a rolling seven-day modification window; Favourites also excludes archived records; Archived is read-only. The type picker exposes only Codex even though some internal models contain Chat/Work strings.

Search first matches displayed title/project/summary locally, then debounces a 120 ms worker request for full projected user and assistant passages. `SearchHit` exposes the identity needed to open `ConversationReader` at an item. The UI marks partial coverage and 200-result truncation; request failures leave local-summary matching available. Date storage is named `days` but its values are hours; minimum-duration values are seconds. A 30-second UI timer refreshes relevant time-based filters. `refreshVisible` intersects bulk selection with visible rows and clears unavailable quick previews.

The toolbar home button returns to Overview/All Sessions and clears filters and expansion. The project hover action and project New Task route are explicit execution entry points. Session drag strings are `navigator-session:<id>`; project drag strings are `navigator-projects:<JSON ID array>`. Column dragging uses `local.navigator.column`. Do not interpret arbitrary dropped file paths as source move requests.

Columns have independent label/reorder and 14-point resize targets. Name stays first and normally fills available width. Manual Name resizing disables that fill until reset. Per-column limits are 170 for Name, 65 × text scale for Media, 110 × scale for other columns, with upper limit 1200. Row height is 38 or 48 times text scale for Compact/Comfortable.

`ResizeHandle` captures window-coordinate origin and limits at drag start so layout updates do not feed back into displacement. Panel saves debounce 250 ms; column saves occur on drag completion. `AppAppearance` coalesces rapid requests and uses system preference observation independently of its own override.

`KeyboardSurface` gives each table/gallery a real AppKit responder. The table handles key codes 49 Space, 36 Return, 125/126 Down/Up and 115/119 Home/End. Gallery and image preview arrows use `GridNavigation`. `PreviewKeyboard` scopes monitoring to the sheet window, and Find uses `SearchRegistration` / `WindowSearch` to target the active window. Preserve normal text-field handling and focus restoration.

`ActivityChart` builds fourteen calendar-day buckets from the same filtered sessions. Each turn contributes runtime in proportion to overlap with each day; active unclosed turns use current elapsed time only while Running. Clicking a bucket sets `activityDate`, and `SessionSelection.hasActivity` filters the existing scope to sessions overlapping that day. Width determines 3–14 visible days. The y-range uses the entire fourteen-day set, and older days are hidden from the left as space narrows. Running chart views refresh every 30 seconds; only running duration cells tick every second.

## 8. Preview and transcript pipeline

### Media extraction and access

`media_paths` recursively inspects explicit path/text/result fields for supported local media. Data URLs are excluded. Large strings are reduced to first/last 16 KiB before path matching; `valid_media_path` rejects malformed, non-absolute, oversized and unsupported paths. Supported index suffixes are PNG/JPEG/GIF/WebP/HEIC, MP4/MOV/M4V and PDF. TIFF is accepted for logos but is not a general indexed-media suffix.

`canonical_media` deduplicates and can resolve URL-encoded paths only when an actual decoded local file exists and the literal path does not. Literal percent filenames are preserved. `detail` checks access/readability, creates reason strings and attaches `mtime_ns:size` revisions. Media summary publication avoids probing every referenced asset.

The Swift worker launch passes `--defer-media-access` unless `PreviewAccess.enabled` is true. Saved choices `folders` and `broad` enable checking; absent/denied choices defer it. `mediaAccess` toggles the flag, optionally migrates cached media, invalidates details and republishes. Deferral also gates bare-path resolution and logo loading. It does not stop reading local Codex history metadata.

Actual macOS permissions remain authoritative. The System Settings URL opens Full Disk Access; Navigator never edits TCC databases. Six usage descriptions in the build script explain protected folder/volume/application-data access.

### Rendering

`PreparedText` prepares attributed links away from the main thread. `LinkedText` exposes selectable text and link actions; `PathLink` provides explicit working-folder operations. ImageIO downsampling backs `PreparedImages`; Quick Look thumbnail generation backs `PreparedThumbnails`. Cache keys include revisions/access state so previously missing or changed files can render correctly.

`MediaGallery` filters the interactive grid to available assets and retains unavailable references separately. Its measured width determines the column count. `AssetPreview` uses that geometry for keyboard moves and skips non-image destinations while preserving layout. Movement stops at boundaries; it does not wrap. Previous/next toolbar buttons walk available image order separately. `ZoomImage` wraps a magnifiable NSScrollView. PDFs/videos use `QLPreviewView` with path/revision updates.

Session preview contains first request, last response, media and recognised voice messages; the inspector prioritises latest request/response. Neither is a complete transcript browser.

### Voice presentation

`transcript.py` recognises supported voice envelopes, parses speaker utterances and reconciles overlapping transcript fragments at boundaries. Its functions include `parse_voice`, `append_delta`, `readable_prompt`, `clean_response` and `present_turns`. Ordinary code and quoted examples must survive unchanged. Presentation is derived when details are requested, so fixes can improve cached sessions without editing original history.

`VoiceOrganizer.matches` is a separate UI helper: only non-archived Unassigned titles matching `realtimevoice` after space removal qualify. Names are tokenised case-insensitively and must contain at least five normalised characters. Only unique whole-name matches get suggestions. Apply sends one validated `assignMany`; reading or selecting suggestions does not assign automatically.

## 9. Composer execution and recovery

### Ownership and task management

`Worker.command` creates `ComposerManager` only on a `composer*` action. `composerOpen` validates an existing thread against the index and takes the real record CWD, ignoring a local presentation assignment. For explicit new-project creation it converts a `codex:` legacy ID to the server project ID. Non-Codex grouping IDs do not become server assignments.

Manager keeps a dictionary of independent Composer clients keyed by UUID, selects one for publication and ticks all clients. Opening an already retained thread selects it; opening another creates a client. Each has a dedicated RPC process, pending-approval map, single-thread executor and recovery directory. Idle transport cleanup can release a completed client connection while retaining its recovery directory. `tasks` is a compact menu summary; `taskKey` identifies the selected client for this run. Recovery scans legacy/current cache directories without acquiring writers or replaying prompts. `composerRemoveTask` is a Navigator-only visibility choice: it rejects active/pending/connecting clients, closes an idle transport and records the key as hidden without removing recovery or projectless files.

`ComposerStore` switches editor state by `taskKey`. `ComposerLocalState` persists each task's draft, selected model/effort/skills, preset instructions, prepared feedback and review ratings in `composer-editors.json`; personal prompts are shared in the same local archive. Writes debounce on a utility queue, while `flushLocalState` durably saves before backup/restore and surfaces failure. `reloadLocalState` replaces, rather than pre-saves over, restored data. A local send acknowledgement clears only the captured matching editor fields, including if the UI has switched tasks; it never clears text typed later. Review feedback is keyed by message ID within its task editor.

### Submission lifecycle

`NavigatorModel.submitComposer` assembles `ComposerStore.submissionText`, captures the original draft values and calls `perform(composerSend)` without UndoManager. Send stays disabled until a nonempty manager `taskKey` arrives, avoiding the initial open/ack race. On local acknowledgement it clears only fields still equal to the captured values in the correct task editor, avoiding deletion of newly typed text. The acknowledgement is not proof of model completion or even a confirmed server turn/start result.

Backend submission validates text length 1–200,000, current activity/ownership, model/effort/skill availability and an absolute existing CWD. A missing CWD creates a unique task folder. It adds an optimistic `local-user-*` message and enters starting.

`ensure_connection` launches an interactive RPC if needed and calls `account/read` to verify usable sign-in. New tasks issue `thread/start` with `sandbox=workspace-write`, `approvalPolicy=on-request`, `approvalsReviewer=user` and optional project ID. The durable thread ID is queued before `turn/start`. Existing tasks resume only as necessary, preserve settings and check for already active execution before sending.

`turn/start` receives text input plus selected skill inputs and optional model/effort. There is no file attachment upload field. Only explicit send reaches this path. Opening/resuming/options refresh can make API calls but do not start a model turn.

### States and event handling

Backend ACTIVE states are starting, reconnecting, running, approval and stopping. Idle, completed, interrupted, failed and disconnected are not active. Swift displays Ready, Starting…, Connecting…, Working…, Needs your input, Stopping…, Completed, Stopped, Failed and Disconnected respectively. `observing` is an additional ownership flag.

`event` accepts streamed assistant deltas and command-output deltas, reconciles completed items, handles thread/turn start/completion, error, token/limit updates and resolved requests. `finished` turn IDs prevent a late start reply from overwriting an already completed event. Server user messages replace matching optimistic identities. Command/File changes/Activity roles render in disclosure groups; complete Codex text gets link rendering.

### Capabilities and usage

`capabilities` paginates `model/list`, loads folder-specific `skills/list`, installed plugins through `plugin/installed`, and rate limits with `account/rateLimits/read`. Partial capability failures are collected into `capabilityError`. `turn_options` verifies explicit model/effort against the returned list and selected enabled skills against their paths before submission.

`five_hour` selects the Codex bucket from `rateLimitsByLimitId`, falling back to legacy `rateLimits`, then finds a 300-minute primary or secondary window. `usedPercent` is consumed usage. Context display is `last.totalTokens / modelContextWindow`, while the token total comes from `total.totalTokens`. These are server-reported values, not locally estimated cost.

### Approval and input protocol

Supported server requests:

| Method | Reply shape |
| --- | --- |
| `item/commandExecution/requestApproval` | `decision: accept`, `decline`, or `cancel` while stopping; accept must be allowed. |
| `item/fileChange/requestApproval` | Same decision family; available file changes included in displayed details. |
| `item/permissions/requestApproval` | Exactly requested `permissions` or `{}`, with `scope: turn`. |
| `item/tool/requestUserInput` | `answers[questionId].answers` arrays of answer strings; every question must be answered unless cancelling. |

The pending-map key is the JSON representation of the server request ID. A `_connection` tag guards against replaying IDs from an old transport; other-task requests are rejected. Unsupported interactions receive an explicit error and user-visible Open in Codex guidance. Browsing RPC rejects all server requests with a read-only error.

`ComposerApprovalCard` displays the first pending request. It supports options, free text and secret text fields, but no blanket allow or persistent approval. Submitted secret answers are not stored in the approval recovery structure; this is not a guarantee that an upstream conversation could never repeat user-provided text.

### Stop, reconnection and recovery

Stop marks stopping, declines/cancels pending requests and interrupts the turn when its ID is available and no prior RPC is pending. It cannot stop a task owned by another window. Closing the sheet leaves clients alive; application shutdown disconnects them.

If resume fails with an active-writer error, Composer reads recent durable history, sets observing and checks again after roughly three seconds. It neither steals ownership nor steers the active task. Recovery retrieves the newest ten turns and replays them into the bounded recent viewport. Unmatched optimistic text becomes Unconfirmed prompt.

A dead active transport schedules up to three automatic reconnection checks; explicit **Reconnect and check task** also recovers state. A failed or timed-out send is never replayed automatically. Saving the durable thread ID before send is essential to avoid accidental duplicate tasks.

Recovery writes `composer.json` via `.tmp` replacement. Approval IDs are always stripped; recovered clients with thread IDs start disconnected. Messages are capped at 200, each text at 100,000 characters and aggregate text at approximately 1,000,000 characters. During activity, saving is throttled to about once a second; publication to 150 ms. Save failures display an error without stopping the model task. The authoritative full task history stays in Codex.

## 10. Quick Prompts and structured design reviews

Preset IDs are `resume`, `repo`, `design`, `bugs`. `ComposerStore.select` inserts the complete prompt into the normal editable chat draft. Selecting another preset replaces only an exact untouched previously inserted block; context and user edits are preserved. There is no separate prompt-instructions editor or confirmation. Submission uses the visible draft (plus explicitly prepared review feedback, if present). Existing editors with separately saved instructions are migrated into the draft when restored.

Quick Prompts are instructions, not hard-coded analysis engines. Repo Check and Bug Hunt do not run local tooling until explicitly sent to Codex. Their requested no-change behaviour is prompt text, independent of the task's permission configuration.

The design schema is `{summary, limitations, findings, recommendations}`. Each finding has `id`, `sentiment`, `title`, `detail`, `evidence`, `rank`, `impactPerEffort`; recommendations have `id`, `title`, `action`, `benefit`, `effort`.

`DesignReview.parse` accepts raw JSON or an exact surrounding ```json fence. It requires ten uniquely identified findings, five Love/Like and five Dislike/Hate, unique ranks 1–10, impact values 1–5, and five uniquely identified recommendations. The instruction asks for positives first; the renderer groups and sorts by rank even if raw array order differs. Invalid shape falls back to normal conversation rendering.

`DesignReviewView` exposes agreement ratings, evidence/notes, recommendation checkboxes and clarifications. `ReviewFeedback.prompt` serialises only entered feedback and selected actions. With no selections it says to respond only and not implement. Otherwise it authorises selected recommendations, excludes unselected work and asks about unresolved design decisions. Preparation only populates an editable field; Send remains a separate action. Do not collapse those stages.

## 11. Project launching

`LaunchPlan` contains title, kind, path, command and browserURL. Discovery is native Swift, asynchronous, read-only and bounded to depth three / 500 visited directories. Hidden entries, symlinks and common dependency/engine cache directories are skipped. Exclusions include node_modules, Library, Temp, Logs, obj, .git, .next, .vinext, Assets and Packages.

It discovers app bundles, package `dev`/`start`/`serve` scripts, Unity ProjectVersion, Godot project.godot, static index.html when no recognised package script exists, and main.py. Package manager preference is recognised packageManager metadata, then lockfiles, then npm. Apps sort newest first; web and project plans follow. Manual file classification adds `.htm`, shell/command scripts and executable files.

`ProjectLauncher` saves the plan in UserDefaults. A sole discovered option saves/launches directly; otherwise setup offers candidates, file picker and custom command. Setup confirmation is Save & Launch. Native `.app` uses NSWorkspace. Other kinds spawn `/usr/bin/python3 backend/launcher.py --stdin`, write the JSON plan to its stdin (so custom command text never appears in `ps` output), with an extended PATH and a temporary combined output log. Literal paths are arguments rather than interpolated shell code; custom commands intentionally use `/bin/zsh -lc`.

`launcher.command` resolves Python virtualenvs next to the script, shell shebangs (Bash fallback), native executables, Godot from PATH/usual app locations, and exact Unity Hub editor versions. Unity uses `open -a <version app> --args -projectPath <path>` and does not upgrade or install. No general dependency installation is performed.

For static pages, `ThreadingHTTPServer` binds `127.0.0.1` on port zero, serving the selected file's parent directory. It supplies WASM/JS/data MIME types, `.gz`/`.br` Content-Encoding and COOP/COEP headers. This is the project's HTTP listener; the browsing worker itself exposes no HTTP API.

Command output is scanned for localhost URLs, with ANSI cleanup, credentials rejected and `0.0.0.0` rewritten to loopback. Explicit browser URLs are restricted to localhost HTTP/HTTPS. The browser opens after a successful readiness request, not simply after process creation. Server output is handled through a bounded queue.

Swift tracks managed processes by project ID to prevent duplicate concurrent launches. The helper starts children in a new process group; stop sends TERM, waits up to three seconds and escalates to KILL if necessary. Static/command helpers watch parent lifetime. Native apps and launched Unity editors are independent; other helper kinds do not have the same parent-watch guarantee. Logs and running maps are in memory, not durable launch session state.

`LaunchStatus` is per project for the current app run: idle, running, opened externally, or exited with a process status. Navigator shows that state in the project menu, enables stop only for its managed running process and copies a saved launch command through `ProjectLauncher.copyLaunchCommand`. These are presentation and process-control helpers; they do not alter source project configuration.

### Library maintenance and diagnostics

`LibrarySettings` is the UI entry point for backup, restore, rebuild and diagnostics. It calls `ComposerStore.flushLocalState` before maintenance; an editor persistence failure stops the request and is displayed to the user. Active Composer work rejects backup, restore and rebuild rather than racing task recovery. Restore/rebuild requests that arrive during a browsing RPC emit `maintenancePending`, then execute before the scheduler starts another read.

`library.backup` first makes a SQLite online backup, then writes a temporary ZIP and atomically replaces the requested destination. It walks only regular files below the Navigator cache, does not follow symlink files or directories and excludes live SQLite sidecars. Its manifest carries only safe `navigator.*` preferences, excluding preview-access choice and secret-shaped keys; Foundation `Data` values use a bounded base64 wrapper.

`library.restore` validates ZIP paths, duplicate entries, file count/size bounds, symlink mode and manifest/version before staging. It copies current regular cache files into a staged sibling, overlays validated archive files, validates `PRAGMA integrity_check` and required tables, rebases cache-owned logo paths when restoring at a different cache root, then swaps directories with rollback on failure. Existing projectless task files are retained and never overwritten by an older archive; legacy `tasks/` paths are treated the same way. It never follows a backup path outside the staging root, calls Codex, or deletes external project/source files.

`Index.rebuild_history` deletes only `turns`, `hydration` and `observations`, invalidates derived caches and lets ordinary read-only enumeration/hydration repopulate them. Preferences, overrides, logo files, Composer recovery/editor archive and projectless working files remain intact. Diagnostics are intentionally aggregate: library availability, complete-history count, connection/executable/worker health and safe recovery actions. They must not serialize prompts, auth/account values or personal paths.

## 12. IPC action and event reference

UI/worker messages are one JSON object per newline. Keep stdout exclusively for protocol output. Diagnostic text belongs on stderr. This protocol is internal and has no HTTP listener or authentication layer because it uses private child-process pipes.

### UI → worker

| `action` | Important fields | Result / scope |
| --- | --- | --- |
| `watch` | `window`, `ids` | Per-window details subscription; worker watches union. |
| `mediaAccess` | `enabled` Boolean | Enable/defer preview checks and invalidate details. |
| `assign` | `id`, `project` | Validated local override. |
| `assignMany` | `assignments` mapping thread→project | Validated atomic local batch. |
| `restore` | `id` | Remove local override. |
| `preference` | `id`, allowed preference fields; optional `logo` / `resetLogo` | Local preferences / validated copied logo. |
| `groupProjects` | `ids`, `name` | Local group preference transaction. |
| `favouriteMany` | `ids`, `favourite` Boolean | Validated atomic Navigator-only favourite mutation with normal undo snapshot. |
| `restoreLocal` | `states` | Undo preference/override rows; reserved IDs rejected. |
| `search` | `query`, optional `scopeIDs`, optional `limit` ≤ 200 | Read-only full projected conversation search. |
| `conversation` | `id`, optional `cursor`, `limit` ≤ 100, `aroundItemID` | Read-only chronological local page; incomplete requests prioritise normal hydration. |
| `backup` | absolute `path`, optional sanitised `uiPreferences` | Atomic local ZIP creation using a SQLite backup snapshot; no source reads beyond Navigator cache. |
| `restoreBackup` | absolute archive `path` | Validate/stage/atomically replace Navigator cache; rejected while Composer is active and deferred until a browse read finishes. |
| `rebuildIndex` | None | Clear only replaceable turns/hydration/observation tables; preserve local organisation, logos, Composer archive and projectless files. |
| `diagnostics` | None | Sanitised local status report and recovery action IDs. |
| `refresh` | None | Reset list/connect schedule and history retry delays. |
| `newCodex` | `cwd`, optional `project` | Emit encoded `codex://threads/new` desktop URL; no model turn. |
| `composerOpen` | optional `id`, `cwd`, `project`, `title` | Select/create client; existing task may resume/read. |
| `composerGet` | None | Ensure manager/client exists and publish through subsequent ticking; no explicit Composer branch or send. |
| `composerSelect` | `key` | Select retained client. |
| `composerRefresh` | None | Refresh options/account usage. |
| `composerReconnect` | None | Inspect/recover existing task. |
| `composerSend` | `text`, optional `model`, `effort`, `skills` | Explicit model turn submission. |
| `composerStop` | None | Stop selected owned turn. |
| `composerReply` | `token`, `accept`, `answers` | Explicit server request response. |
| `quit` | None | End worker loop. |

`requestID` is optional protocol correlation. Swift uses it for acknowledged local edits and selected Composer operations. There is no formal JSON schema validator for all incoming actions; UI-generated messages are the current contract. Unknown Composer actions can effectively be no-ops, so add explicit routing and tests when extending it.

### Worker → UI

| `type` | Payload / consumption |
| --- | --- |
| `snapshot` | Complete browser collection and health; first publication or preserved fallback. |
| `delta` | Changed sessions, removed IDs, optional projects and activity changes. |
| `status` | Connection Boolean and human-readable message, independent of data updates. |
| `detail` | One watched session's projected prompts/media/response/voice/activity. |
| `detailError` | Session ID and preview failure message. |
| `search` | Correlated full-text `SearchResponse`: passages with thread/turn/item IDs, coverage and truncation. |
| `conversation` | Correlated chronological local page with earlier cursor and incomplete/indexed flags. |
| `backup` / `restoreBackup` / `rebuildIndex` | Correlated maintenance result; restore includes only sanitised `navigator.*` UI preferences. |
| `diagnostics` | Correlated checks (`ok`/`warning`/`error`), indexed/total counts and connection state; never prompt text, auth values or source paths. |
| `maintenancePending` | A rebuild/restore waiting for the current read RPC; it is not a completion acknowledgement. |
| `ack` | Request ID and optional local undo command. |
| `error` | Optional request ID and message; goes to save completion or generic alert. |
| `openURL` | Desktop creation link; Swift accepts only the `codex` scheme here. |
| `open` | Thread ID; Swift has a handler, though current normal opening is direct UI `model.open`. |
| `composer` | Selected ComposerState, task summaries, task key and manager revision. |

### Codex RPC transport

Executable discovery order: explicit constructor binary, `NAVIGATOR_CODEX`, PATH `codex`, then known application bundle resources. `CODEX_HOME` is supplied to the subprocess. Handshake uses `initialize` with experimentalApi followed by `initialized`.

Requests use a monotonic serial, per-request queue, write lock and default 20-second timeout. EOF fails current pending requests. Readers ignore old processes and interactive events carry process identity. Browsing notifications are bounded to 100 wake-up events; interactive events are not bounded at transport ingress, so the bounded Composer viewport is not a guarantee of a globally bounded event queue.

## 13. Performance contracts

| Area | Current mechanism / boundary |
| --- | --- |
| SQLite ownership | One worker thread owns connection and mutations; blocking RPC lives elsewhere. |
| Decoded history | Version-keyed cache, max 512 histories and estimated 64 MiB; one oversized history can exceed the estimate while evicting others. |
| Summary reuse | Per-thread revision/status/projection caches avoid reparsing unchanged history; SQL triggers detect turn changes. |
| Publication | Full first snapshot, then changed/removed records. `lastChecked` alone does not republish a session. |
| Details | Watch union across windows; selected and visible expanded rows only. Unwatched details released; Swift retains up to 32 unused details while watched ones stay pinned. |
| Media checks | Selected detail checks at most about every two seconds unless revisions force refresh; no full-library preview probing. |
| Text | Background preparation; 8 MiB / 256-item cache. |
| Images | Downsampled ImageIO loading; 96 MiB / 32-image cache. |
| Thumbnails | Up to four cancellable Quick Look requests; 32 MiB / 128-item cache. |
| UI | Lazy rows/gallery, prompts in 50-item batches, debounced search/layout saves, cached chart/filter aggregates. |
| Composer | 150 ms state publication, approximately one-second active persistence, capped message viewport. |

The entire session/search-summary set remains in UI memory for local filtering, so memory still scales with library size. Do not claim all history memory is capped at 64 MiB. Avoid adding per-row timers, full transcript decoding to snapshots, synchronous thumbnail work or source-wide filesystem checks during rendering.

## 14. Build, tests and diagnostics

### Build and launch

From the project root:

```sh
bash scripts/build.sh
open 'dist/Codex Navigator.app'
```

The script sets module caches under `.build`, performs a release Swift build with no debug info, constructs the app in a temporary staging directory, copies all backend Python plus the reference demo image, writes Info.plist and ad-hoc signs. It moves the old bundle intact into staging before installing the new bundle and restores it if the final move fails. This avoids truncating a running signed executable. Old staging bundles can remain under `.build`.

There is no dependency manager for Python packages: the backend uses the standard library. There is also no SwiftPM test target; the Swift checks below are standalone executables.

### Environment overrides

| Variable / argument | Meaning |
| --- | --- |
| `NAVIGATOR_CODEX` | Override Codex executable path. |
| `CODEX_HOME` | Source local history/configuration home; default `~/.codex`. |
| `NAVIGATOR_CACHE` | Read by the Swift launcher and passed as worker `--cache`; not independently read by direct worker CLI. |
| Worker `--home`, `--cache` | Explicit paths for direct Python worker invocation. |
| Worker `--demo` | Isolated fixture seeding, no live Codex browsing. |
| Worker `--defer-media-access` | Delay preview-media probing. |

### Python tests

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s tests -v
```

| Test file | What it protects |
| --- | --- |
| `test_index.py` | Incremental pages, rollback, restart, runtime/stale semantics, media validation/deduplication, tail checkpoints, last-good snapshot. |
| `test_navigation.py` | Saved project/CWD/ID mapping, offline desktop metadata, overrides, cumulative tokens, desktop new link, logo replacement, local organisation. |
| `test_responsiveness.py` | Cached selection during RPC, cache invalidation/accounting, delta/detail deduplication, watch union, atomic undo/bulk edits, bounded rollout parsing. |
| `test_preview_access.py` | No media probes while deferred, permission-denial recovery, encoded aliases, projectless precedence, inferred-assignment label. |
| `test_transcript.py` | Voice envelope parsing, overlap handling, ordinary-text preservation and cached presentation upgrades. |
| `test_rpc_interactive.py` | Read-only versus interactive requests, connection tagging and stale-reader isolation. |
| `test_composer.py` | Explicit send, stream assembly, user decisions, stop, uncertain submission, ownership/recovery, concurrent task isolation, bounded output and organisation boundary. |
| `test_library_backend.py` | Full user/Codex search and conversation pages, legacy projection migration, safe snapshot/restore, rollback, logo rebasing, preference/Data filtering, projectless-file preservation, maintenance deferral and sanitised diagnostics. |
| `test_search_reader.py` | Stable cursors across older-page backfill, unique synthetic message IDs, Unicode snippets, missing match errors, migration backfill, user-only voice suggestions and summary-cache search pruning. |
| `test_launcher.py` | Literal paths/venvs, Godot/Unity mapping, loopback URLs, free-port static assets, process group stop isolation and exit propagation. |
| `test_verify.py` | Verification-runner command selection, restricted-environment classification and smoke opt-in boundaries. |

Some launcher tests create temporary child processes and loopback servers. They do not launch the user's project. A restricted execution environment may block binding sockets even when the code is correct; distinguish that failure from an assertion failure.

### Standalone Swift checks

These commands use temporary output and module cache paths and run from the project root:

```sh
swiftc -module-cache-path /tmp/navigator-doc-check-modules Sources/Navigator/ProjectOrder.swift tests/ProjectOrderCheck.swift -o /tmp/navigator-order-check
/tmp/navigator-order-check
swiftc -module-cache-path /tmp/navigator-doc-check-modules Sources/Navigator/GridNavigation.swift tests/GridNavigationCheck.swift -o /tmp/navigator-grid-check
/tmp/navigator-grid-check
swiftc -module-cache-path /tmp/navigator-doc-check-modules Sources/Navigator/SessionSelection.swift tests/SessionSelectionCheck.swift -o /tmp/navigator-selection-check
/tmp/navigator-selection-check
swiftc -module-cache-path /tmp/navigator-doc-check-modules Sources/Navigator/DesignReviewModel.swift tests/DesignReviewCheck.swift -o /tmp/navigator-review-check
/tmp/navigator-review-check
swiftc -module-cache-path /tmp/navigator-doc-check-modules Sources/Navigator/QuickPrompts.swift Sources/Navigator/DesignReviewModel.swift Sources/Navigator/ComposerLocalState.swift tests/ComposerLocalStateCheck.swift -o /tmp/navigator-composer-state-check
/tmp/navigator-composer-state-check
swiftc -module-cache-path /tmp/navigator-doc-check-modules Sources/Navigator/LaunchPlan.swift Sources/Navigator/ProjectLauncher.swift tests/ProjectLauncherCheck.swift -o /tmp/navigator-launch-check
/tmp/navigator-launch-check
```

`ProjectOrderCheck` covers ordering and preference round trips in a child process; GridNavigationCheck covers geometry and edges; DesignReviewCheck uses `tests/design_review_fixture.json` for schema/feedback validation; ProjectLauncherCheck uses temporary fixtures for launch discovery, literal paths and failure reporting. Its optional `--ui` opens a setup capture and `--actual-projects` reads real project folders from the colon-separated `NAVIGATOR_CHECK_PROJECTS` environment variable; neither belongs in portable default checks.

`SessionSelectionCheck` covers visible range/toggle semantics used by bulk local actions. `ComposerLocalStateCheck` covers per-task editor isolation, flush and reload-after-restore behaviour. The native interaction probe also invokes a real `ComposerStore` late-ack/task-switch/restore regression through its Quick Prompt check. `scripts/verify.py` runs the Python suite and standalone Swift checks by default, keeps native UI checks and app build opt-in, and never opts into a live model smoke unless `--live` is passed.

### Demo UI and native checks

```sh
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo --snapshot /tmp/navigator-overview.png
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo --list --snapshot /tmp/navigator-list.png
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo --interaction-check
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo --window-check
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo --interface-check
'dist/Codex Navigator.app/Contents/MacOS/CodexNavigator' --demo --drag-check
```

Additional presentation flags include `--small-window`, `--large-text`, `--text-scale <1...1.5>`, `--light`, `--overview`, `--narrow-chart`, `--group-preview`, `--voice-preview`, `--unassigned-preview`, `--access-preview`, `--access-denied-preview`, `--composer-preview`, `--composer-approval-preview`, `--review-preview <file>`, `--review-next`, `--library-preview`, `--diagnostics-preview`, `--search-preview`, `--bulk-preview` and `--activity-preview`. Use `--demo` for diagnostic runs; some appearance flags are not themselves demo-gated.

Snapshot captures the app's own content or attached sheet after a delay and terminates the app. Native interaction checks exercise real responder/mouse behaviour that pure logic checks do not cover. Interface-check includes fullscreen transitions and needs a compatible desktop session; window-check avoids that requirement. Run UI checks serially to avoid competing windows/focus.

### Live smoke tests and effect boundaries

```sh
PYTHONDONTWRITEBYTECODE=1 python3 scripts/smoke_live.py
PYTHONDONTWRITEBYTECODE=1 python3 scripts/smoke_worker.py
```

These use real Codex reads with an isolated temporary Navigator cache. By contrast, `python3 scripts/smoke_composer.py --live` submits one real ephemeral model prompt under read-only permissions using the current account. It is not an offline check and can consume usage. Do not run it as an incidental documentation or organisation test.

Existing audit logs record earlier checks only. Re-run tests appropriate to an implementation change and report actual results rather than treating an old passing log as current validation.

### Documentation verification on 14 September 2026

Both guides' contents anchors, local links, code fences and inventory coverage of every Swift source, backend module, script and test file were checked. The Python suite ran 96 tests: 95 passed in the restricted environment; the static-server test timed out because loopback binding was denied. All seven launcher tests then passed outside that restriction. The four standalone Swift checks passed; ProjectOrderCheck required execution outside the sandbox to persist its isolated temporary UserDefaults suite. The review check emitted an existing deprecated String initializer warning. No application source was changed, and no live model smoke, full app build or native UI check was run for this documentation pass.

## 15. Change recipes and maintenance limits

### Add a new session metric

Define its source and unknown/partial semantics first. Add extraction to `project_turn` or observation, aggregation to `projection`/`summarize`, the wire field to Swift `Session`, then cell/sort/inspector UI. If it belongs only in detail, keep it out of global snapshots. Add tests for absent data and repeat cumulative events where relevant. Do not relabel session span as runtime or rollout size as project size.

### Add a local organisation control

Choose whether it belongs in SQLite metadata or a view-only UserDefaults preference. For worker-backed changes, validate IDs before one local transaction, return prior state for undo and preserve errors in the editing dialog. Cover the action with source-file immutability and no-RPC/no-Composer regression checks. Do not introduce upstream synchronisation, directory moves or execution as a side effect.

### Add a Composer option or event

Update the backend state/defaults, capability reads/validation and Swift optional wire types together. Route the option only through explicit submission where appropriate. Maintain task and connection identity checks. Add fake-RPC tests for unsupported values, uncertain sends and event ordering; confirm current installed protocol rather than assuming an old schema is current. Provider inventory is dynamic; do not hard-code a marketing model list here.

### Add a media type

Update all path allowlists and extraction patterns, media kind mapping, detail availability/revision logic and native renderer selection. Cover deferred access, malformed/missing references and deduplication. Check keyboard navigation when new non-image cells appear. Adding a decoder alone does not add discoverability because the index suffix allowlists remain authoritative.

### Add a launcher kind

Separate pure discovery/classification from execution. Extend LaunchPlan classification, Swift plan UI and Python command/run logic consistently. Treat path arguments literally, define process ownership and stopping behaviour, and keep optional browser opening on loopback. Test temporary fixtures and process-group isolation. Do not run install/build commands during discovery.

### Known boundaries and documentation traps

- Older `ARCHITECTURE.md` text saying creation never uses `thread/start` describes desktop handoff only. Current Navigator Composer explicitly starts threads and turns on Send.
- Older notes saying preview arrows wrap are obsolete. Current GridNavigation stops at edges.
- Internal Chat/Work enum/icon support and older README wording do not mean those sources or creation commands exist in the current UI. Only Codex is offered.
- Archived is a source-history view; there is no archive/unarchive/delete mutation UI.
- Session aliases and project preferences are local. Backend `name` support is not a shipped project rename dialog.
- Concurrent Composer clients preserve task isolation for transport, approvals and persisted local editor state. Personal prompts are shared local metadata; they are not Codex task data.
- Browser/index code has no HTTP listener. Explicit static project launch does create a loopback server.
- Demo browser data/preferences are isolated, but ProjectLauncher directly uses standard preferences. Do not infer all manually invoked launch UI is automatically harmless in demo mode.
- Source history is reconciled after complete enumeration; the cache is neither a cloud sync adapter nor an immutable archive across accounts.
- There is no full Git integration, code-editing surface, plugin management UI, update service, general audio preview, live voice recorder or filesystem organiser.
- Codex protocol and desktop state keys are version-sensitive. This reference documents the implemented adapter, not a guarantee about future external schemas.

When maintaining these documents, update the user guide for visible behaviour and this reference for data/contracts/file routes. Keep generated artifacts, historical audit evidence and shipped features clearly distinguished.


### Composer session presentation and audio

Composer requests readable reasoning summaries (`summary: auto`) and renders summary sections, plans, command output, and diffs under each request's expandable work history. It preserves agent message phase so commentary stays in the work section and final answers remain visible. Work durations use server turn timestamps where available, with a local start-time fallback for live turns. Raw reasoning content is not rendered.

The Dictate control uses macOS Speech Recognition and microphone permission. Recognized text is appended to the captured task's draft, including when the user switches tasks; dictation does not submit a prompt. Voice chat uses the installed Codex app-server's experimental `thread/realtime/*` WebSocket transport and the existing Codex account. Audio is 24 kHz mono PCM16 input, with output sample rate supplied by Codex. No audio is saved in Navigator's recovery cache. Input/output carry both task and voice-session identities; old packets are ignored. Closing Composer, switching tasks, or losing the connection stops local capture and playback. Account/protocol errors appear beside the controls. Live microphone and spoken playback require device validation.

Regression coverage: `tests/test_composer_session.py` checks summary reconciliation, final phases, work timestamps, opt-in voice, packet/session routing, error cleanup, and audio cache exclusion. The native interaction probe checks exchange grouping and dictation draft routing. All organization gestures remain local metadata operations.


### September 14 interaction fixes

Voice-chat entry is hidden for now; macOS Dictate remains available. The experimental transport is retained but cannot be started from the Composer UI.

Media tiles select on native mouse-down, without waiting to distinguish a double click; the second click opens preview. Each gallery receives a reveal callback from its enclosing ScrollViewReader, and all selection changes—including preview navigation—scroll the matching tile into view. Cached thumbnails provide immediate preview content while full-resolution decoding completes. The native 80-item gallery regression checks upward/downward scrolling and selection visibility during and after preview. Activity height dividers span the panel width.
