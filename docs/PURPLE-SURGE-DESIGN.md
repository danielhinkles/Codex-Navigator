# Purple Surge inside Codex Navigator

**Date:** 14 September 2026  
**Status:** Original agreed product direction. Navigator implementation and verification are recorded in [PURPLE-SURGE-IMPLEMENTATION.md](PURPLE-SURGE-IMPLEMENTATION.md).

**Implementation clarification, 14 September 2026:** The project owner confirmed that online matches are central to bringing Navigator players into Purple Surge. The in-app integration must provide a prominent route into the existing online arena, alongside bundled offline puzzles. The standalone project remains untouched.  
**Source:** the project owner’s voice planning session.

## Purpose

Codex Navigator is a free workspace for Codex power users. The goal is for other people to benefit from it and to discover Purple Surge during task waits. The experience should make waiting enjoyable while keeping work visible and easy to return to.

Success means people play and complete puzzles, then return to play on later days. Invitation clicks alone are not the outcome. The game should feel like something already available inside Navigator, with no suggestion that the user must leave their work to visit an advertisement.

This document records the agreed experience. Runtime compatibility, technical architecture and performance targets still require source inspection and measurement.

## Firm decisions

- Bundle the actual playable Purple Surge game code, offline puzzle content and assets inside Navigator.
- Play takes place in a right-side in-app tab/retractable drawer. Never launch an external browser or a separate game window.
- Core play works offline, including during disconnects. Sign-in and synchronisation must not block local play.
- A small persistent side tab provides manual access. The drawer has a clear hide/close control, the puzzle, and minimal essential controls.
- Preserve the puzzle and moves when hiding/reopening the drawer and after restarting Navigator. Save meaningful actions.
- Keep task progress visible. Completion and required-input notices offer a way back to the task without abruptly ending the game.
- Never alter task execution or steal keyboard focus.
- The first introduction reveals the real built-in puzzle. Later invitations are brief, silent Sergio appearances that leave the drawer closed.
- Users can disable invitations while retaining manual game access. Respect reduced motion and keyboard accessibility.
- Keep the integration lightweight. Hidden play pauses rendering, audio, animations and unnecessary CPU/network activity.
- The game must not receive Codex prompts, conversations, credentials or repositories. Any host bridge is minimal and purpose-specific.

## Agreed user flow

### First suitable task wait: demonstrate the built-in game

At the first suitable task wait, the drawer slides open just enough to reveal **a real puzzle**, Sergio, and this copy:

> Purple Surge is built into Navigator. Play here while you wait, or tuck it away whenever you like.

Show clear **Play** and **Hide** controls. This first-use reveal is the explicit exception to the otherwise closed-drawer invitation behaviour. It must demonstrate actual in-app play, not a promotional illustration or a link away from Navigator.

The reveal does not take keyboard focus. Do not introduce it while the user is typing, responding to an approval, or answering a question. “Suitable wait” needs an implementation definition based on observed task/UI state; it must not rely on unsupported predictions of how long a task will take.

Choosing Play opens the playable drawer. Choosing Hide retracts it and leaves the small side tab visible. Persist discovery state so restarting Navigator does not replay the first-use demonstration.

### Subsequent waits: Sergio says hello and goodbye

After discovery, occasional invitations are extremely lightweight: Sergio briefly peeks out, waves, and retreats—“hello and bye-bye.” They are silent, leave no lingering message, and do not open the drawer unless the user clicks.

Never invite on every task or repeatedly within one wait. Avoid typing, approvals and questions. Primarily rely on the persistent side tab once the user knows it exists.

**Tunable suggestion, not a fixed approved requirement:** introduce the game at the first eligible wait and allow later invitations at most once per day. The precise frequency, eligibility rules and timing must be decided and evaluated before implementation is considered finished.

### Manual play and returning to work

Selecting the side tab opens or resumes the saved puzzle. Hiding the drawer preserves progress. Opening it again returns to the same puzzle and moves.

At wide window sizes, the task stays readable beside the puzzle. A narrow-window arrangement is still unresolved and must preserve usable puzzle dimensions and access to task status. Do not solve narrow layouts by opening another window.

When a task completes or requires input, present a visible notice with **Return to task**. Do not end, reset or dismiss the puzzle automatically. Returning to the task preserves play state; keyboard focus changes only in response to the user’s action.

## State behaviour

| State or event | Drawer and invitation behaviour | Persistence and attention |
|---|---|---|
| Undiscovered; no suitable wait | Side tab remains available; no unsolicited reveal | Task workflow remains primary |
| First suitable wait | Partial drawer reveal with real puzzle, Sergio, explanatory copy, Play and Hide | No focus theft; remember discovery |
| Play selected | Open the playable in-app drawer | Restore saved puzzle or start available local content |
| Hide/close selected | Retract drawer; retain side tab | Save progress; suspend hidden activity |
| Later eligible invitation | Sergio briefly appears and retreats; drawer stays closed | Silent; no repeated invitation within the same wait |
| Manual side-tab selection | Open/resume game | Works even with invitations disabled |
| Task completes or needs input | Keep puzzle intact; offer Return to task | Task status remains visible |
| Navigator restarts | Restore puzzle and moves when play resumes | Do not repeat first-use discovery |
| Offline/disconnected | Local puzzle remains playable | Account/sync cannot block play |
| Reduced motion enabled | Use a subtle static presentation instead of sliding/waving animation | Keep equivalent discovery and controls |

Exact timing, partial-reveal size and drawer dimensions are tunable details, not approved numerical requirements.

## Proposed microcopy

The first-use sentence above is the agreed introductory copy. Other concise labels below are proposed wording consistent with the agreed flow:

| Location | Copy |
|---|---|
| Persistent tab | Purple Surge |
| First-use actions | Play · Hide |
| Drawer hide control | Hide Purple Surge |
| Task completion notice | Your task is complete. · Return to task |
| Required-input notice | Your task needs your input. · Return to task |
| Invitation preference | Show occasional Purple Surge invitations |

Later Sergio invitations carry no lingering message. Do not add countdowns or claims about predicted task completion time.

## Bundling and connectivity

Ship playable game code, offline puzzle content, Sergio and other required assets with Navigator. Network access may support Purple Surge’s existing online features, but the core puzzle must launch and remain playable without it. Authentication and sync are optional to that local experience.

An embedded web view may be suitable, but that is **an unverified implementation option**. The existing game’s framework, build outputs, embedded-runtime compatibility and offline dependencies have not been established by this planning session. Inspect the real game source before selecting a runtime or promising compatibility.

Packaging must keep the game inside Navigator rather than redirecting to a hosted game. Inspect asset availability, dependencies and any remote assumptions as part of implementation.

## Persistence and performance

Save meaningful puzzle actions so closing the drawer or restarting Navigator retains the current puzzle and moves. The exact storage format, migration scheme and action-save boundaries require source inspection. Reopening must resume play without relying on an online account.

When hidden, stop rendering, animations, audio and unnecessary CPU/network activity. The host may unload the embedded runtime if it can restore saved state correctly. Avoid continuous polling; prefer existing state/event mechanisms where compatible with the source.

Keep task streaming, typing, approvals and navigation responsive while play is open. Startup, memory, CPU and resume budgets need measurement on the actual integration; no numerical targets were agreed in the voice session.

Online account linking, cross-device synchronisation and conflicting saves need explicit decisions after reviewing Purple Surge’s existing behaviour. Do not silently replace local progress with an online save.

## Accessibility and attention

Provide keyboard access to the side tab, puzzle, essential controls, Hide and Return to task. Use clear accessible names and visible focus, with a predictable route back to the task. Opening a drawer automatically must not move keyboard focus into it.

Reduced motion replaces animated reveals and waves with a subtle static presentation. Invitations remain silent. Task completion and requests for input must be perceivable while playing, without forcing a game interruption.

Invitations can be turned off independently of manual play. Avoid inviting during typing, approval decisions or questions. Exact event coordination remains an implementation question.

## Isolation and measurement

The embedded game has no access to Codex task text, conversations, credentials or repositories. Restrict any host bridge to the minimal game-state, presentation and attention functions needed for this experience. Task notices do not require disclosing task contents to the game.

Measurement must align with Purple Surge’s existing measurement contract rather than introducing an unreviewed parallel scheme. The desired funnel and retention signals are:

- Invitation shown → game opened.
- Puzzle started → puzzle completed.
- A player returns on a later day.
- Invitations disabled.

Completed puzzles and returning players are the primary outcomes; opens are supporting context. Collect no task content. Event definitions, consent requirements, local/offline buffering and deduplication must follow the existing contract after source inspection.

## MVP scope

The MVP includes a bundled playable puzzle and its offline content/assets; the in-app right drawer and persistent tab; the first-use demonstration; the later Sergio peek; local puzzle persistence; task attention notices; invitation preferences; and accessible/reduced-motion behaviour.

Existing online features may be supported where compatible, but account and sync conflict behaviour is unresolved. It must not delay or block local play. This design does not authorise unrelated Navigator changes or a broader product audit.

## Open technical questions

1. Where is the current Purple Surge source, and what framework/build outputs and dependencies does it use?
2. Which embedded runtime supports that game reliably within Navigator? Can existing code run unchanged, or does it need adaptation?
3. Which puzzles/assets must ship for offline play, and which current features assume network access?
4. How does the game represent puzzle state and moves, and which persistence hooks support durable save/resume and safe runtime unloading?
5. What minimum puzzle dimensions remain usable, and how should the drawer adapt to narrow Navigator windows?
6. Which task/UI events identify a suitable invitation moment and suppress invitations during typing, approvals and questions?
7. How should simultaneous completion/input notices be presented without displacing play or obscuring a required action?
8. What invitation frequency and animation/reveal timing should be adopted after testing? The once-per-day suggestion remains tunable.
9. What performance budgets are realistic after measuring the actual runtime and bundled content?
10. What does Purple Surge’s existing account, sync and measurement contract require, particularly for offline play and conflicting saves?
11. What minimal host bridge and runtime permissions enforce separation from Codex data and the filesystem?

These are implementation questions, not missing approval for documenting the agreed direction. No runtime choice or source compatibility is asserted here.

## Acceptance criteria

An implementation is ready for review when all of the following can be demonstrated:

- A newly installed Navigator can play a real bundled puzzle offline without sign-in, an external browser or a separate game window.
- First-use discovery reveals the real puzzle and Sergio with the agreed copy and Play/Hide controls, only at a suitable wait, without moving keyboard focus.
- Hide leaves the side tab available; discovery state survives restart.
- Later invitations are brief, silent and non-lingering. They leave the drawer closed and obey the chosen, documented frequency and suppression rules.
- Disabling invitations retains manual play; reduced-motion and keyboard paths work.
- Puzzle and moves survive drawer hide/reopen, runtime unload if used, and Navigator restart. Disconnects do not block play.
- Task progress remains visible, and completion/input notices offer Return to task while preserving the game.
- Task execution is unchanged. Typing, approvals and task navigation remain responsive.
- Wide and narrow layouts have been reviewed using real playable puzzle dimensions; neither opens another window.
- Hidden rendering/audio/animations and unnecessary CPU/network activity stop, with measured results recorded against agreed budgets.
- Embedded-game permissions and the host bridge prevent access to Codex prompts, conversations, credentials and repositories.
- Measurement matches the existing Purple Surge contract, supports completion and later-day return analysis, and includes no task content.
- Any supported online synchronisation has explicit, tested conflict rules and cannot silently erase or block local progress.

This section is the original saved design brief. Current implementation details, the online-match clarification and outstanding live verification are recorded in [PURPLE-SURGE-IMPLEMENTATION.md](PURPLE-SURGE-IMPLEMENTATION.md).
