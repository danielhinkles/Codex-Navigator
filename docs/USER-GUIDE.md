# Codex Navigator — User Guide & Product Overview

Find the work you remember. Understand where you left off. Continue from one place.

This guide describes the implementation in this workspace as reviewed on **14 September 2026**. The build script labels the app **0.4.0**. Features described here exist in the source; availability of live Codex features also depends on your installed Codex version and sign-in. This is a native macOS companion application developed in this project, with its own interface and local library.

## Contents

1. [What Navigator is for](#1-what-navigator-is-for)
2. [Getting started](#2-getting-started)
3. [A tour of the window](#3-a-tour-of-the-window)
4. [Finding sessions](#4-finding-sessions)
5. [Reading sessions and understanding measurements](#5-reading-sessions-and-understanding-measurements)
6. [Organising your library](#6-organising-your-library)
7. [Previewing images, documents and voice conversations](#7-previewing-images-documents-and-voice-conversations)
8. [Working with Codex in Composer](#8-working-with-codex-in-composer)
9. [Quick Prompts and interactive design reviews](#9-quick-prompts-and-interactive-design-reviews)
10. [Launching your projects](#10-launching-your-projects)
11. [Personalising the interface](#11-personalising-the-interface)
12. [Keyboard and mouse reference](#12-keyboard-and-mouse-reference)
13. [Local data, privacy and recovery](#13-local-data-privacy-and-recovery)
14. [Troubleshooting and current limits](#14-troubleshooting-and-current-limits)
15. [Example workflows](#15-example-workflows)

## 1. What Navigator is for

Codex Navigator brings your locally available Codex work into a browsable library. Instead of opening conversations one by one to remember what happened, you can search user prompts, recognise a project by its logo, scan its activity, inspect the latest request and response, and preview the files referenced in its history.

It serves four related purposes:

| Purpose | What you can do |
| --- | --- |
| Rediscover work | Search sessions, filter by recency or activity, expand earlier prompts and recognise project activity over time. |
| Organise your view | Favourite or rename sessions, assign them to projects within Navigator, pin projects, create named groups and arrange the sidebar. |
| Continue work | Open the original task in Codex or write and run a follow-up through Navigator's Composer. |
| Try the result | Launch an existing app, local website, script or supported game project from its project menu. |

A **session** is a conversation or task from local Codex history. A **project** normally corresponds to a saved Codex project and its working folder. A **group** is a name you give a collection of projects in Navigator. **Unassigned** contains sessions that are not currently presented under a project.

Navigator's organisation is independent of Codex's organisation. Moving a session in this interface changes where you see it in Navigator. It does not relocate the working folder, move files, or change the task's project assignment in Codex. This makes it possible to organise your history around how you think about your work.

History browsing needs no separate API key or model call. Composer uses the installed Codex account and provider configuration when you explicitly submit a prompt. Project launching runs the selected project's existing code or application.

## 2. Getting started

### Requirements

You need macOS 14 or later, a local Codex installation supplying the Codex executable, and `/usr/bin/python3`. Building the application also requires Swift and Apple's developer tools. The packaged app does not bundle its own Python runtime.

Open `dist/Codex Navigator.app` in this project. If it has not been built, a developer can run:

```sh
bash scripts/build.sh
open 'dist/Codex Navigator.app'
```

The current build is locally ad-hoc signed. It is not a notarised public installer, and this project does not provide an automatic update service.

### Your first launch

Navigator starts its local index and connects to Codex. Sessions appear progressively as available history is read. Selected, recently changed and running sessions receive priority. Counts and previews can initially show **Indexing…** or **Loading…**.

The status bar explains the connection and indexing progress. Later launches can show cached records immediately while Navigator checks for updates. You do not need to wait for every old conversation to finish indexing before browsing available results.

### Choose file-preview access

The initial **File access for previews** dialog offers three paths:

- **Use folder-by-folder access:** let macOS request access to protected folders as needed.
- **Open Full Disk Access settings…:** grant broader access yourself in System Settings. The dialog can reveal the correct copy of Navigator, then offers **I've enabled access — try previews**. macOS may require a restart.
- **Not now:** keep file previews off and continue browsing history.

Navigator waits for this choice before probing referenced preview media. Choosing a mode does not grant macOS permission by itself. Reopen the setup through **View Options → File access for previews…** whenever needed.

## 3. A tour of the window

### Toolbar

The top bar contains the **Codex Navigator** home button, **System / Light / Dark** appearance selector, **View Options**, **Overview / List** selector, search field, Composer button and index refresh button. Drag an unused part of this bar to move the window.

Clicking **Codex Navigator** returns to All Sessions in Overview, clears the selection and expanded rows, and resets search and filters. It does not erase preferences or local organisation.

### Sidebar

The sidebar provides these destinations:

| Destination | Contents |
| --- | --- |
| All Sessions | All indexed non-archived sessions, subject to your current filters. |
| Recent | Non-archived sessions modified within the past seven days. |
| Favourites | Non-archived sessions you have favourited; Codex-pinned tasks can supply the initial favourite state. |
| Archived | Sessions reported as archived by Codex. This is a browsing destination; Navigator has no archive or delete command. |
| Projects | Saved or resolved projects, optionally arranged into expandable named groups. |
| Unassigned | Non-archived sessions without a project in Navigator's current presentation. Expand it to choose individual sessions directly. |

Choosing an individual Unassigned session clears table filters so the selected item is visible. A green dot beside a project indicates at least one session with recent running evidence. Hover over a project to reveal a button for starting a new task there.

### Overview

Overview has three main areas: the project sidebar, the session browser with activity chart, and an inspector for the selected session. The heading shows the current scope, its session count and indexed active time. A project heading also displays its working-folder link and project menu.

The activity chart helps you recognise when you worked. It distributes recorded turn runtime across the relevant days, up to the last fourteen days. Hovering a bar reveals its date and duration; click one to filter the current scope to sessions active on that day, then use the clear control beside the filter to return. Narrowing the area hides older days on the left while retaining recent days and a consistent scale based on the fourteen-day data. The chart follows the current filtered session collection.

Collapse **Activity · recognise when you worked** when you need more room for sessions. The collapse setting is remembered.

### List

List retains the sidebar, search, filters, table and new-session menu. It removes the activity area and inspector to give the table more space. Expand prompts or use Space to preview a selected session. Switching view does not use a different history collection.

### Status bar

The bottom bar shows connection health, an indexing or offline message, the number of currently visible sessions and reminders for previewing and opening. A green connection indicator means the index is connected; orange indicates an unavailable or reconnecting connection. Cached browsing can remain useful while disconnected.

## 4. Finding sessions

### Search

Click **Search sessions** or press **Command-F**. Navigator first filters by session title and project, then searches every indexed user request and Codex response without case sensitivity. Results show a short matching passage; choose it to open the full local conversation at that message. It is plain text search, not semantic search or an AI question-answering system. Tool output and file contents are not searched.

Search applies within the selected sidebar destination. The first 200 matching passages are shown, and Navigator says when older history is still indexing. The conversation reader starts with the latest relevant page and can load older cached messages; opening it prioritises read-only history backfill. If a session disappears after a filter change, Navigator clears its inspector rather than leaving an unrelated preview on screen.

### Filters

Filters combine: a result must satisfy every active filter and the search query.

| Filter | Choices and meaning |
| --- | --- |
| Modified | Any date; last 1, 3, 6 or 12 hours; 1 day; 3 days; 1 week; 1 month. The month option is a rolling 30-day window. |
| Duration | Any duration, Over 1 hour, Over 8 hours. These compare recorded active time, including current running elapsed time when available. The implementation includes the threshold itself. |
| Type | All types or Codex. Other history sources are not currently integrated. |
| Has assets | Sessions with at least one recoverable local media reference, which may include an unavailable file. |
| Running | Sessions currently classified as Running; stale status does not qualify. |

At narrower widths, controls move into a **Filters** menu. An empty-results view offers **Clear filters**, which also clears search. The toolbar's home button provides a broader reset back to All Sessions.

### Table columns

Name is always present. The default additional columns are **Modified**, **Active time**, **Size** and **Media**. View Options can also show **Prompts**, **Created** and **Token usage**, or hide any optional column.

Click a column heading to sort; click it again to reverse direction. View Options also provides Sort by and Descending controls. Drag an optional column's label onto another optional label to reorder it. Name stays first. Drag the right edge to change a column's width. A wide table scrolls horizontally.

Name initially uses spare table width. Resizing it manually switches to a fixed width until you choose **Reset columns**. That reset restores the default optional columns, order and widths.

## 5. Reading sessions and understanding measurements

### Expand the user prompts

Click the disclosure chevron on a session row to see its indexed user prompts as dated bullet points. The **User prompts (n)** menu switches between **First to Last** and **Last to First**, independently of the table sort. Long histories reveal prompts in batches through **Show next 50 prompts**.

This compact list remains a prompt history view. To read the complete indexed user/Codex conversation, choose a search passage and open its conversation reader. Generic tool output remains outside the reader.

### Inspector

Select a session in Overview to see its title and favourite star, current project, status, latest request and latest response. **Original request** expands the first prompt. The media gallery appears below the conversation summary.

Expand **Session details** for status, active time, session span, modified and created dates, prompt count, tokens, message count, files changed, source and assignment information. Working-folder links can be opened, revealed in Finder or copied. The bottom actions are **Continue in Navigator** and **Open in Codex**.

### What the numbers actually mean

| Measurement | Meaning |
| --- | --- |
| Active time | Accumulated recorded turn durations, with live elapsed time for a currently observed running turn. It is not the time between the first and last message. |
| `≥` before time | Available timing is incomplete, so the value is a lower bound. Scope totals also flag incomplete coverage. |
| `—` / Unavailable | The necessary measurement was not recorded or cannot be recovered. This does not mean zero. |
| Session span | Time from the session's recorded creation to its last modification, including gaps between work. |
| Size | Size of the local rollout history file on disk. It excludes external media and is not the size of the project. |
| Media | Unique supported local media references recovered from available history, including references to files that are now missing. |
| Prompts | User messages recovered from indexed turns. Attachment-only messages can appear as an attachment placeholder. |
| Messages | Indexed user and assistant messages, excluding tool-call counts. |
| Files changed | Unique paths reported by file-change items in indexed history. It is not a current Git diff. |
| Token usage | The latest recorded cumulative token total from local rollout events. Repeated cumulative reports are not added together. |

### Running and stale status

A green running indicator and live time mean Navigator has recent evidence of an active turn. It uses available Codex status and local history activity. A long-running but silent tool can temporarily become **Status stale**. Stale means the app cannot confidently extend the live timer; it does not prove failure or completion.

Other history labels include **Idle**, **Interrupted**, **Failed** and **Not indexed**. Connection failures retain cached data and stop presenting old activity as confidently running.

## 6. Organising your library

### Select, favourite and rename sessions

Right-click a session to choose **Favourite / Remove favourite** or **Rename…**. The inspector star also toggles favourites. Rename opens **Rename in Navigator**: the alias affects Navigator's display and search while preserving Codex's original title. Saving an empty alias allows the source or fallback title to show again.

Command-click sessions to add or remove them from a selection; Shift-click selects a visible range. The selection bar can favourite, remove favourites from, or assign all selected sessions in one local action. Each bulk action validates every selected session before changing anything and can be undone with the brief **in Navigator** toast or Edit → Undo.

### Assign a session

Drag a session onto a project or Unassigned, or use **Assign in Navigator** in its context menu. The table and project scopes then reflect your local choice.

Assignment provenance explains why a session appears where it does:

| Label | Explanation |
| --- | --- |
| Codex project | An explicit source project association is available. |
| From working folder | Navigator inferred membership from the source working folder. |
| Navigator only | You have a local assignment that differs from the source location. |
| Conflict | The source location changed after your local override was made. Your Navigator choice is retained. |
| Unassigned | No project is currently resolved from the source and no different local choice is applied. |

**Use Codex location**, when offered, removes the local override and follows the current source location. Continuing a locally reassigned task still uses that task's real Codex working folder. Reorganising history never silently changes where a task executes.

### Pin and sort projects

Right-click a project to pin or unpin it in Navigator. Projects pinned in Codex are reflected in the sidebar; Navigator disables unpinning those source pins and labels them **Pinned in Codex**.

The Projects selector offers **Alphabetical**, **Last updated**, **Largest history** and **Custom**. Largest history compares accumulated local rollout sizes. In non-Custom modes, pins are considered first within the ordering before the display is assembled into groups. Named groups remain together, so pinning does not guarantee a project becomes the first row of the entire sidebar.

Drag a project onto another to place it before that project. Drop it on **Drop to move to end** to append it. This selects Custom and remembers the arrangement. Switching sort modes or filtering sessions preserves the saved Custom order. Existing groups stay intact, which can constrain the final visible placement.

### Group projects

Command-click project rows to select several, then right-click and choose **Group projects…**. You can also begin with one project and select more in the dialog. Enter a group name or select an existing group, search the project checklist if needed, then click **Group**.

Groups are expandable sections, not filesystem folders. A project has one group name at a time. Dropping projects on a group header opens the grouping dialog for review. **Remove from group** removes the selected projects' group membership without deleting anything. Names can contain up to 120 characters.

### Organise voice chats

Open **View Options → Organise voice chats…** to review non-archived Unassigned sessions whose titles identify realtime voice conversations. Navigator looks for whole project names in indexed prompts and suggests a project only when there is one unique match. Short names under five normalised characters are excluded from suggestions.

Read the prompts, use individual suggestions, choose projects manually or select **Use all unique suggestions**. Nothing changes until **Apply assignments**. Keeping a row Unassigned leaves it untouched. This is a local text-matching helper, not an AI classifier or automatic background organiser.

### Undo, redo and saving

Worker-backed local assignments, favourites (including bulk changes), aliases, pins, grouping and appearance metadata use the local Undo/Redo path. A short confirmation toast includes Undo after a successful change. Use the standard Edit commands for those changes. Custom sidebar order, column layout, theme and launcher settings are preferences outside that undo transaction system.

If saving a rename, logo or group fails, the dialog retains your edits and displays the error. An unconfirmed save after disconnection should be checked before retrying. No organisation action writes back to Codex or rearranges files on disk.

## 7. Previewing images, documents and voice conversations

### Session preview

Select a session and press **Space**, or choose **Quick Look** from its context menu. A larger sheet shows its project, active time, date, first request, latest response and media. Recognised voice sessions instead show a readable voice conversation and latest assistant notes.

The sheet has its own text-size slider from 12 to 28, combined with the app-wide scale, and a **Higher contrast** option. These settings are remembered. Use **Done** or Escape to close the session sheet.

### Media gallery

Navigator recovers explicit local references to PNG, JPEG, GIF, WebP and HEIC images; MP4, MOV and M4V videos; and PDFs. Actual preview support depends on macOS being able to decode the file. Referenced remote assets and embedded base64 images are not downloaded. There is no general audio gallery or arbitrary-document index.

Click an available asset to select it. Press Space or double-click it to open its preview. Right-click for opening in the default application, revealing in Finder or copying the path. Images use Navigator's zoom view; video and PDF previews use native Quick Look.

Image previews provide pinch zoom, a slider from 0.25× to 6×, **Fit**, previous/next image buttons and an image counter. Arrow keys follow the gallery layout: Left/Right stay on the row, Up/Down move between rows, and movement stops at edges. An incomplete last row uses its nearest remaining item. Image navigation skips non-image cells while respecting the grid. The previous/next buttons follow image order and also stop at the ends.

Space, Escape or **Done** closes an asset preview. The gallery restores focus after dismissal. Video and PDF controls retain their native arrow-key behaviour.

### Unavailable media and links

Missing references remain visible instead of disappearing from history. Navigator distinguishes previews being off, access denial, a missing temporary file, a file no longer at its path and other read failures. Use **File access…** or **Retry** where offered. Navigator cannot recover a deleted temporary asset merely by refreshing.

Markdown and web links are coloured and underlined. Existing bare absolute local paths can also become links when preview access allows local checks. Text context menus expose link actions. A preview itself stays local; clicking an external web link deliberately opens that destination in your browser.

### Voice readability

For recognised voice wrappers, Navigator separates **You** and **Assistant**, combines transcript fragments and removes repeated handoff context from the display. Ordinary non-voice text is preserved. This transforms the presentation of cached history; it does not rewrite the original session or provide voice recording, speech input or a new live voice call interface.

## 8. Working with Codex in Composer

### Start or continue

Select a project, open the new-session menu and choose **New task in Navigator**. The project context menu's **New Task** and hover button do the same. With no project selected, a new task receives its own local working folder when first sent.

To continue an existing task, select **Continue in Navigator** in the inspector or row menu. Composer opens recent conversation and the real working folder. Simply opening it can connect or recover task state, but does not submit a new model prompt.

The alternative **Open new task in Codex** opens Codex's desktop composer. Double-clicking a session or pressing Return on its row opens it in Navigator’s Composer. Choose **Open in Codex** to open that existing task in the Codex desktop app.

### Send a prompt

Write the request in the prompt field, optionally select a model, effort and skills, then click **Send to Codex** or press **Command-Return**. New tasks use workspace-write access with on-request approvals. Existing tasks keep their permission settings. A submitted task can read or edit its working files according to those settings and your request.

The input limit is 200,000 characters. You cannot send another turn while the selected task is active, awaiting reconnection or owned by another Codex window. The current input surface is text plus optional skill selection; it has no attachment-upload interface.

### Read progress

Responses stream into **Recent conversation**. User messages, Codex output, plans and activity have readable role labels. Commands and file changes have expandable details, including available command output and file diffs. **Follow response** keeps the latest output in view; turn it off to inspect earlier text while work continues.

Composer shows a bounded recent conversation, not an unlimited copy of the durable Codex transcript. On recovery it retrieves recent turns. Use Read conversation from its library row for the full indexed conversation, or open the task in Codex.

### Models, effort, skills, plugins and usage

| Control | Behaviour |
| --- | --- |
| Model | Use task / Codex default, or a model reported by the installed server. |
| Effort | Available reasoning efforts for the selected model. Choose a model first; changing models resets effort to Default. |
| Skills & plugins | Select enabled skills to include with your next message. Plugin entries show enabled/disabled inventory; install and connect plugins in Codex, then refresh. |
| Refresh options | Reload models, skills, installed plugins and account usage. Individual unavailable inventories show an explanation. |
| Tokens | Reported cumulative task token usage. |
| Context | Last reported token count divided by the reported context window, when available. |
| 5-hour usage | Percentage consumed from the reported five-hour account window; hover for its reset time when available. This is not percentage remaining or a per-task quota. |

Navigator has no separate sign-in form, plugin installer, usage-credit reset or billing interface. It uses what Codex exposes and displays unavailable values explicitly.

### Approvals and questions

An orange card appears when Codex needs a command, file-change or permission decision. Read the details, then choose **Allow once** or **Decline**. Allow once is disabled if that decision is not supported. Permission grants are limited to the requested permissions for that turn.

For input questions, select a suggested answer or type your own. Secret answers use a secure field. Complete each question and click **Send answers**. If several requests are pending, the interface presents the first, then progresses through the queue.

Unsupported interactive requests produce a visible error and an Open in Codex route. Navigator does not silently approve them.

### Multiple tasks and stopping

Close Composer to continue browsing while its task stays connected. Reopen it with the toolbar button. Open a new task for another project, or another task in the same project, to run work concurrently. The **Composer** menu switches between retained tasks and shows their status. An orange toolbar icon also flags a background task needing input.

Each task retains its own execution connection, conversation and approval queue. Its unsent draft, model/effort/skill choices, Quick Prompt instructions, prepared design feedback and ratings are also kept separately in Navigator's local library. They survive restarting Navigator and are included in a Navigator backup. Switching tasks restores only that task's editor; an acknowledgement from an earlier task cannot clear a newer draft. Personal Quick Prompts are local, shared across those task editors, and are backed up too.

Remove a completed or idle item with **Remove from Composer** to hide it and release its idle connection. This only changes Navigator's local task list: its Codex history, recovery record and projectless working folder remain available for recovery. Active tasks, pending approvals and connecting tasks cannot be removed.

Use **Stop** to interrupt the selected Navigator-owned turn. If it is still starting, the stop is sent when the turn ID becomes available. A task being followed from another Codex window must be stopped in that window. Closing the sheet is not Stop, and quitting Navigator disconnects its clients rather than guaranteeing that every task has finished.

### Disconnections

Recovery state and recent conversation are saved locally. After a lost transport, Navigator can make up to three automatic reconnection checks. **Reconnect and check task** is the manual route. A prompt whose submission is uncertain is never automatically resent, because the original may already be running. It can appear as **Unconfirmed prompt** after recovery.

When another Codex window owns a task, Navigator follows its saved progress until ownership can be acquired. It does not steal the writer or send a duplicate prompt. Cached tasks recovered after restarting Navigator need reconnection before continuing.

## 9. Quick Prompts and interactive design reviews

Quick Prompts provide editable starting instructions. Your context stays in the main text field. Switching presets replaces the preset instructions, and **Clear** removes the preset without deleting your context. Selecting a preset alone does not run anything.

| Preset | Intended request |
| --- | --- |
| Where Was I? — Short | A summary of the last completed work, unfinished work and immediate next step, within 280 characters. Report only, with no invented progress. |
| Repo Check — Short | A brief READY, ATTENTION or UNKNOWN report covering Git state, conflicts, stashes, worktrees, branches and available remote-tracking information. Report only. |
| Evaluate Design — Medium | Five positive and five negative findings, evidence, importance ranking, impact-per-effort estimates and five prioritised recommendations. No implementation during the review. |
| Bug Hunt — Medium | A diagnostic project review with severity, QA category, evidence, reproduction information and proposed fixes, ending with three choices about which fixes to undertake. It waits for your choice. |

Several preset instructions explicitly target game development. You can edit **Prompt instructions** before submission. Presets request behaviour from Codex; they are not independent scanners or a guarantee that the model can inspect every part of a project.

### Evaluate Design, step by step

1. Choose Evaluate Design, add context about your goals and send it.
2. Navigator asks for a structured response. A valid result becomes interactive cards; a response that does not match remains ordinary readable conversation.
3. Read the summary and **Review scope**, then **What's working** and **What needs attention**. Findings show Love/Like or Dislike/Hate, priority 1–10 and Impact per Effort 1–5. The latter estimates user value relative to effort, not an objective measurement.
4. Choose Strongly Agree, Mildly Agree, Mildly Disagree or Strongly Disagree for any finding. Expand **Evidence & your explanation** to read the evidence and add an optional note.
5. Use **Recommendations** to jump to **Next pass**. Select the recommendations you want implemented and add optional clarifications.
6. Click **Prepare feedback** or **Prepare n selected recommendations**. This creates an editable follow-up in the input area. It does not send anything.
7. Review that draft and click Send to Codex. With no recommendations selected, the draft requests discussion only. With selections, it authorises only those recommendations and asks about unresolved design decisions before affected work.

Ratings and unsubmitted feedback are saved with the selected task's local editor, so they survive closing Composer and restarting Navigator. Choosing another Quick Prompt clears prepared review feedback, so finish or copy it first if you want to keep it.

## 10. Launching your projects

Right-click a project and choose **Launch Project** to run an existing result. Navigator detects likely targets. A single discovered target is saved and launched; multiple or missing choices open setup. **Launch setup…** changes the choice, and **Choose launch target…** lets you select a file manually. The setup's confirmation is **Save & Launch**, so accepting it runs the choice immediately.

| Project or target | What happens |
| --- | --- |
| Mac `.app` | Opens the existing application. Nested builds can be discovered, with newer app bundles listed first. |
| Web package | Detects `dev`, `start` and `serve` scripts, choosing npm, pnpm, Yarn or Bun from project metadata or lockfiles. Runs the selected script and opens a localhost URL when ready. |
| Static HTML | Serves the selected page's directory on a free localhost port and opens that page. |
| Unity/Godot web export | Static serving supports WebAssembly types, gzip/Brotli headers and cross-origin isolation headers used by engine exports. |
| Unity project | Reads the required editor version and opens that exact installed Unity Hub editor with the project. Press Play inside Unity. |
| Godot project | Runs `project.godot` using an installed Godot executable. |
| Python script | Runs from the script's folder using its `.venv` or `venv` Python when available, otherwise `/usr/bin/python3`. Automatic discovery looks for `main.py`. |
| Shell script | Runs with its shebang interpreter, or Bash when no shebang is provided. |
| Native executable | Runs the selected executable from its folder. |
| Custom command | Runs the Terminal command and working folder you enter, with an optional localhost HTTP/HTTPS browser address. |

Detection inspects at most three subfolder levels with a bounded directory count, skipping common dependencies and engine caches. Choose a manual target for deeper or unusual layouts. Discovery itself does not run scripts or change the project.

Launching uses existing tools and dependencies. It does not install packages, build a new app, install Unity, upgrade an engine project or provide a Windows runtime. Package commands can run their normal lifecycle hooks. A launched program may change its own project files as part of its ordinary behaviour.

**Show launch log** opens available process output and errors. A project menu also shows Navigator's current launch state and offers **Copy launch command** when a saved plan has one. **Stop launched process** stops the process owned by Navigator for that project. Repeated launch clicks do not create duplicate managed processes while one is already running, and different projects can run concurrently. Static and command-based servers stop when Navigator exits. Mac applications and opened Unity editors run independently; do not assume quitting Navigator stops every other launch kind.

Launch choices are saved locally. They do not change Codex's saved projects or create project launch configuration files.

## 11. Personalising the interface

Choose System, Light or Dark in the toolbar. System follows macOS appearance. **View Options** provides app-wide text scaling from 100% to 150% in 5% steps and Comfortable or Compact session rows.

Drag the vertical dividers to resize Projects and Preview. Drag the divider beneath the activity area to adjust its height. The app constrains sizes to leave usable content space and remembers panel dimensions. The main window has a minimum size of 1080 × 680 and a default size of 1460 × 900.

For project identity, right-click and choose **Folder colour**: blue, green, purple, orange, red or grey. **Logo & appearance…** offers a larger visual preview and an image picker supporting PNG, JPEG, HEIC and TIFF up to the worker's 10 MB limit. Choose **As is**, **Button trim** or **Folder background**, and independently enable the logo in Overview and Project Folder presentation.

Click **Save** to apply changes. **Reset to default** prepares removal of the custom logo but also needs Save. A selected logo is copied into Navigator's own cache, so using it does not move or rename the original image. Updated logos refresh in the interface.

As is shows the image fitted within its icon area. Button trim adds a rounded tinted background and coloured border. Folder background places the image over a coloured folder. Turning a logo placement off uses the standard coloured folder there.

Theme, view mode, text scale, density, panel dimensions, optional columns, preview reading controls, activity visibility, project sort, Custom order and Unassigned expansion are remembered. Search, selected session, expanded prompt rows and current table sort are view state rather than a promise of a restored workspace on the next launch.

## 12. Keyboard and mouse reference

| Action | Gesture or key |
| --- | --- |
| Find sessions | Command-F. |
| Select next/previous session | Down/Up with the session table focused. |
| Select first/last session | Home/End with the session table focused. |
| Continue selected session in Navigator | Return, or double-click its row. |
| Preview selected session | Space with the table focused, or Quick Look in its context menu. |
| Expand prompts | Click the row chevron. |
| Preview selected asset | Space with its gallery focused, or double-click the asset. |
| Navigate gallery / image preview | Arrow keys; grid-based movement stops at edges. |
| Close asset preview | Space, Escape or Done. |
| Close session preview / Composer | Escape or its Done/Close control. |
| Send a Composer message | Command-Return or Send to Codex. |
| Select several projects | Command-click project rows. |
| Reorder projects | Drag before another project or onto the end drop area. |
| Assign a session | Drag onto a project or Unassigned; equivalent context menu available. |
| Reorder optional columns | Drag column labels. |
| Resize a column / panel | Drag its resize edge / divider. |
| Undo/redo supported local edits | Standard Edit → Undo / Redo, normally Command-Z / Shift-Command-Z. |

Keyboard handling follows the focused table, gallery or preview window. Space in a text editor remains a space. There is no global Space shortcut that takes over typing throughout the app.

## 13. Local data, privacy and recovery

The default library is in `~/Library/Application Support/Codex Navigator/`. It contains a local SQLite index, organisation preferences, copied logos, Composer recovery data and per-task editors. UI preferences and launch choices also live in macOS application preferences. Projectless Composer tasks receive their own folders within Navigator's cache hierarchy. Launch logs use temporary files.

One local library can retain work across Codex sign-ins within the same macOS profile. This does not download other accounts' cloud histories, synchronise machines or make remote-host work available. Records are reconciled against complete successful local enumerations, so the cache is not an archival backup guarantee.

Browsing and previewing do not submit model prompts. Navigator reads source history and local media without rewriting them. Composer submissions use Codex's configured provider, and selected project commands execute locally. Local previews do not upload their files, although an explicit task can use files as task context according to its permissions.

Treat the cache as personal data: it includes prompt text and recent conversation. It is not just disposable thumbnails. Deleting it can lose Navigator-only assignments, aliases, favourites, groups, logos, drafts, review feedback and locally created task working folders.

Open **View Options → Library & diagnostics…** to create a portable Navigator backup, restore one, rebuild only the replaceable history index, or inspect a sanitised health report. A backup uses a consistent SQLite snapshot and copies Navigator-owned regular files without following symlinks. It includes Navigator preferences except preview-access permission choices, local logos, Composer recovery, drafts, personal prompts, review feedback and projectless task folders. Restore validates the archive and database before atomically replacing the library. It retains existing projectless task files rather than overwriting or deleting newer working files, and never changes Codex folders, source history or external project files. Finish active Composer work before maintenance.

## 14. Troubleshooting and current limits

| Symptom | What to check |
| --- | --- |
| Empty history on first launch | Read the status bar, allow indexing to progress, check the selected scope and clear filters. Confirm a local Codex installation and history exist. |
| Offline / reconnecting | Cached history is retained. Use Refresh and check Codex availability. A developer can configure the executable or history location through environment overrides. |
| A phrase does not match search | Search covers indexed user and Codex text. Wait for backfill; tool output and file contents are outside search. |
| File previews are off | Reopen File access for previews and choose an access mode. |
| Red access-denied message | Grant the relevant macOS permission, restart if macOS requests it, then Retry. |
| Missing temporary image | The original file may have been removed. Navigator preserves its reference but has no remote retrieval copy. |
| Running task shows stale | Recent evidence is missing. Check the task in Codex; silent work can appear stale temporarily. |
| Task appears under the wrong project | Inspect provenance and the real working folder. Assign locally or use Codex location as appropriate. |
| Composer cannot send | Wait for its current operation/options loading, resolve questions, reconnect a disconnected task or check ownership in another Codex window. |
| Backup, restore or rebuild is unavailable | Finish active Composer work, then retry from Library & diagnostics. A restore that fails validation leaves the current library in place. |
| Composer lacks models or skills | Refresh its options. Inventory support is version-sensitive; sign-in and folder availability can also matter. |
| Review appears as text | Codex did not return the exact supported structure. The response remains readable; you can ask for the requested format. |
| Launch target is unavailable | Update Launch setup or choose a target. Check installed dependencies, executable paths and the launch log. |
| Link does not open Codex | Confirm the desktop application is installed and handles the `codex` URL scheme. |

Current scope is local interactive Codex history. There is no integrated ChatGPT Chat/Work history, remote-host browser, subagent library, cloud sync, archive/delete action, general file manager, full code editor or live voice-call interface. The backend uses version-sensitive Codex App Server APIs; a future Codex change may require an adapter update.

## 15. Example workflows

### Return to a project after a break

Select its logo, scan activity, search a remembered phrase and inspect the latest request and response. Expand Original request if you need the original goal. Choose Continue in Navigator and send Where Was I? with any extra context. Once you understand the state, send the next concrete request.

### Tidy a large history library

Favourite frequently revisited sessions and give ambiguous titles clear local aliases. Group related projects, choose Custom order and drag them into a useful sequence. Review Unassigned and use voice suggestions where appropriate. These changes affect your Navigator library only.

### Review and improve a design

Continue the relevant project task, choose Evaluate Design and ask Codex to inspect the available UI. Read the evidence, rate the findings and select only the recommendations you want. Prepare the follow-up, edit it and send it. When work is ready, use Launch Project to try the existing runnable result.

### Keep several projects moving

Start a task in one project, close Composer and start another elsewhere. Use the Composer menu to switch tasks. Watch for the orange input indicator, resolve each task's requests, and use the sidebar's running markers to see where activity is occurring. Recheck the selected task and folder before submitting its saved draft.

For implementation details and editing routes, see the separate [Technical Reference & Agent Editing Map](TECHNICAL-REFERENCE.md).
