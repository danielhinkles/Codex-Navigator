# Session index and live updates

> For the current comprehensive implementation reference, use [Technical Reference & Agent Editing Map](docs/TECHNICAL-REFERENCE.md). This file retains earlier architecture notes: in particular, its desktop-only creation and wrapping preview-arrow descriptions are historical. Current Composer can execute explicitly submitted tasks, and image arrow navigation stops at grid edges. See the [User Guide](docs/USER-GUIDE.md) for current product behaviour.

## Ownership

```text
SwiftUI browser
  │ newline-delimited JSON over private pipes
  ▼
Single Python worker ───── Navigator SQLite (WAL)
  │                         metadata / turns / hydration
  │                         observations / overrides / preferences
  ├── local Codex App Server (JSON-RPC)
  │     thread/list, thread/turns/list, thread/read
  └── read-only rollout lifecycle tail + local media files
```

The UI never opens Codex storage and never owns indexing tasks. One worker serializes Navigator mutations, so drag assignment and background refresh cannot race SQLite writes. The transport has a dedicated reader, request correlation, deadlines, EOF propagation, and bounded notification signals. No approval request is answered by this browsing client.

## Enumeration and incremental history

1. Emit cached records immediately, with the current connection state.
2. Initialise an App Server client using the existing local Codex installation.
3. Enumerate active and archived interactive threads using cursor pagination and `useStateDbOnly`. Only a complete successful enumeration can remove records from the visible index.
4. Fingerprint metadata. Unchanged completed histories need no new hydration; changed, selected, and active histories are prioritised.
5. For paginated histories, request ten full turns per page. Persist each turn's projection under `(thread, turn ID)`, plus a durable continuation cursor. A restart resumes incomplete backfill. An updated thread is read newest-first until a previously cached completed boundary is reached. Legacy history uses a read-only `thread/read` fallback.
6. Project only user prompts, latest assistant responses, local media references, changed paths, timing, and message counts. Do not persist complete tool output or inline image data. Large media-containing strings are bounded before path matching.
7. Send session summaries plus indexed prompt text for keyword search and voice-project suggestions. Send media details only for selected or expanded sessions. The UI holds session IDs independently of refreshes, preserving selection and expansion.

Session enumeration occurs every five seconds; running turns are eligible for refresh every two seconds. Notifications can invalidate the list sooner, but a private server is not assumed to receive another desktop process's events. Blocking RPC waits run in a single background executor. The worker loop drains commands before applying completed RPC results; SQLite stays on its owner thread. Lifecycle scanning has a 6 ms global budget and a resumable per-file byte budget. Cached previews therefore do not wait for a list or hydration RPC to return. Failed histories retain their cache and retry after sixty seconds. Connection failures preserve all cached data and retry after fifteen seconds.

## Observed running state

The separate App Server can normalise a turn owned by the desktop to `interrupted` even while it is executing. Therefore the worker additionally tails complete JSONL records with durable inode, offset, and timestamp checkpoints. It handles file replacement, truncation, and partial trailing records. Each pass is byte-budgeted; a record is never checkpointed halfway through.

An unmatched `task_started` plus disk activity within thirty seconds is recent running evidence. Completion or abort closes it. Without fresh evidence, an open lifecycle becomes **Status stale**; the UI stops extending elapsed time. A genuinely `inProgress` API response is also accepted, provided its observation is recent. This is deliberately an observed status, not a guarantee that a separate desktop process is alive. A long silent tool call may temporarily show stale until new activity arrives.

## Assignment model

Projects resolve server IDs to saved desktop project IDs, then use explicit desktop assignments and saved root membership. Projectless IDs and unsaved working directories map to `unassigned` when desktop metadata is available. Legacy CLI-only environments without desktop metadata retain CWD grouping. The worker copies only whitelisted project-related desktop state to the Navigator cache for offline use. Old CWD preferences and assignment baselines canonicalize to saved IDs without discarding user overrides.

Dragging stores `{thread, desiredProject, baselineCodexProject}` in Navigator. Current source metadata is retained independently. If it later differs from the baseline, show **Conflict** while preserving the user's assignment. Removing the override follows the current source location. Organisation never performs upstream project synchronisation. Bulk assignment validates every destination before one local transaction. Correlated acknowledgements include prior Navigator metadata for a single Undo operation; undo and redo use that same local mutation path.

Custom names, favourites, folder colours, and copied project logos are Navigator-owned. Their persistence is independent of source refreshes. There is no cloud upload.

## Presentation contract

Overview and List share the exact same filtered/sorted session collection. Overview adds the timeline and inspector; List removes both. Expandable prompt lists are per-session, and their ordering is independent of table sorting. A session's preview includes its first request, last response, timing, media, and assignment provenance. Media thumbnail generation uses native Quick Look at a bounded size; preview does not open the whole transcript.

Runtime never falls back to session span under the same label. Missing timing is represented explicitly. Local file size has a precise tooltip because paginated history is not fully represented by the rollout's byte count. Unknown index values remain empty/loading rather than zero.

## Current limits and next integration work

- Read-only indexing is verified against the installed desktop's protocol. These APIs are version-sensitive; history errors are displayed and cached data remains usable.
- Local interactive histories are supported; subagents are excluded to avoid flooding the user's browser. Chat/Work and remote hosts need separate adapters.
- Refreshed history heads reconcile removed newer turns after rollback. Arbitrary rewrites deeper than an unchanged completed boundary may require deleting the Navigator cache and reindexing. Navigator itself has no destructive history actions.
- App launch links use the installed `codex` scheme. Chat/Work creation is unavailable; organisation remains local to Navigator by design.
- This first build uses periodic reconciliation plus lifecycle tailing. It can later attach to a supported shared desktop event stream without changing the database or UI contracts.

Protocol reference: [Codex App Server](https://learn.chatgpt.com/docs/app-server), checked against the installed CLI's generated schemas during implementation.

## Desktop presentation updates

Panel widths, column order/widths, preview text controls, and project sort persist in UserDefaults. Native resize handles retain a fixed window-coordinate origin and fixed limits for each drag, so layout changes cannot feed back into pointer displacement. Logo files use content-derived filenames so SwiftUI sees a changed URL on replacement. One application appearance controller coalesces rapid theme requests, clears window overrides, and updates SwiftUI's colour scheme. System reads the macOS preference independently of the app's override; system appearance notifications and full-screen transitions reapply the current selection. Native titlebar drag handling keeps controls interactive and forwards the original mouse-down event. Media galleries own their selection and preview sheet, including when nested inside a session preview. Image previews use magnifiable NSScrollView; other media uses QLPreviewView.

New session requests validate the folder and emit the installed desktop composer route with encoded path and project ID. No thread/start or model turn is issued. Voice suggestions use unique whole-name matches in available user prompts and require an explicit Apply action. Chat/Work history and cross-source colour/grouping cannot be populated until a supported history adapter exists.

## Responsiveness and cache invalidation

Turn revision triggers invalidate only changed history. Derived summaries and activity are reused per session, including after decoded turns have been evicted. The scheduler consults a small versioned latest-status cache, so exceeding the 512-history decode cache does not cause an idle reparse loop. The decode cache has an estimated 64 MiB budget; one oversized history can exceed it and displaces the others. Summary/search storage scales with indexed records because those documents are needed for local search.

The first publication is a full snapshot. Subsequent publications send changed/removed sessions, changed activity, and projects only when changed. Connection health travels independently; a check timestamp alone does not republish history. Watched details are compared before emission; local file availability/revisions are checked at most every two seconds. Each window owns a subscription and the backend watches their union. Hidden expanded rows release subscriptions. The frontend retains up to 32 unused details, while currently watched details stay pinned.

Swift decodes a lightweight envelope followed by the typed payload, and writes commands from a serial output queue. Filtered results and project aggregates are cached; search is debounced 120 ms. Only running duration cells have one-second clocks. Chart buckets are cached. Column widths stay typed in memory and save on drag completion; panel dimensions save after a 250 ms pause.

Attributed text and local link resolution prepare off the main thread (8 MiB/256-item cache). ImageIO downsampling handles logos/full images asynchronously (96 MiB/32 images); thumbnails use at most four concurrent cancellable Quick Look requests (32 MiB/128 items). Media keys include file revision and availability. Expanded prompts load in batches of 50 inside a lazy stack.

The table and each gallery own real AppKit first responders in their respective windows. Space follows the responder, and text entry keeps normal key handling. Preview dismissal restores the originating focus. No application-wide Space interception is installed.


## September 14 interaction and access updates

Asset preview navigation has explicit owner callbacks for closing and selection. A local key monitor is scoped to the preview sheet's exact NSWindow, so Space/arrow handling survives first-responder changes inside image or Quick Look controls. Arrow cycling applies to available images in the current session and wraps; other media retain their native arrow behavior.

Header drag-to-reorder and drop handling are confined to the label; the independent 14-point resize target has a thin visual separator. Width limits match rendered minimums. Manually resizing Name switches off automatic spare-width filling until Reset columns. InterfaceCheck now sends native mouse events, verifies real hit targets using parent coordinates, and asserts each requested width is actually reached.

Custom project order is a Navigator UserDefaults array of stable project IDs. Existing group memberships are preserved. Sorting/filtering never writes this array; explicit project reorder writes it and selects Custom. Unknown IDs are removed from the working order and new projects append deterministically. The isolated ProjectOrderCheck covers reorder semantics and preference round trips.

The app launches its worker with deferred media access until the user chooses preview access. Deferral covers canonical-media filesystem probes, migration, availability checks, attributed-text bare-path resolution, and logo loading. The mediaAccess IPC command enables checking and republishes selected details; actual file-open permission errors remain distinct from missing files. Six Info.plist usage descriptions explain local-only preview access. Full Disk Access is a user action in macOS settings; the app cannot grant it or combine macOS's individual-folder permission prompts. No permission or TCC database is modified by Navigator.

Explicit desktop projectless membership outranks stale project hints. Inferred working-folder membership is labelled From working folder rather than Codex project. Navigator-only organisation continues to override presentation locally without changing source metadata.
