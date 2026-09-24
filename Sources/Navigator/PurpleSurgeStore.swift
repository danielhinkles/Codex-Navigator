import AppKit
import SwiftUI

struct SurgeTaskStatus: Equatable {
    let id, status: String
    let composer: Bool
    var running: Bool { ["Running", "running", "starting"].contains(status) }
    var needsInput: Bool { status == "approval" }
    var completed: Bool { ["Idle", "completed"].contains(status) }
    var failed: Bool { ["Failed", "failed", "interrupted", "Interrupted"].contains(status) }
}

final class PurpleSurgeStore: ObservableObject {
    @Published private(set) var archive = SurgeArchive()
    @Published private(set) var puzzle: SurgePuzzle?
    @Published private(set) var position: SurgePosition?
    @Published private(set) var open = false
    @Published private(set) var introduction = false
    @Published private(set) var peeking = false
    @Published var destination: SurgeDestination = CommandLine.arguments.contains("--demo") ? .offline : .puzzles
    @Published var armed = false
    @Published var boardAnimating = false
    @Published var showHint = false
    @Published private(set) var error: String?
    @Published private(set) var notices: [SurgeTaskStatus] = []
    @Published private(set) var runningCount = 0
    var allowComposerSheet = false
    private var engine: SurgeEngine?
    private let persistence: SurgePersistence
    private var damagedSave = false
    private var previousTasks: [SurgeTaskStatus] = []
    private var invitedThisWait = false
    private var invitation: DispatchWorkItem?
    private var retreat: DispatchWorkItem?
    private var activityMonitor: Any?
    private var lastActivity = Date()
    var notice: SurgeTaskStatus? { notices.first }
    var runtimeLoaded: Bool { engine != nil }
    var puzzleCount: Int { engine?.puzzles.count ?? 200 }

    init(directory: URL = ComposerLocalState.defaultDirectory()) {
        persistence = SurgePersistence(directory: directory)
        do { archive = try persistence.load() }
        catch { damagedSave = true; self.error = "Your saved puzzle could not be read. It has been kept safe." }
    }
    deinit {
        invitation?.cancel(); retreat?.cancel()
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor) }
    }
    func show(intro: Bool = false) {
        introduction = intro; open = true; peeking = false
        invitation?.cancel(); retreat?.cancel(); stopMonitoring()
        if !intro { archive.discovered = true; save() }
        loadGame()
    }
    func play() { introduction = false; archive.discovered = true; save() }
    func hide() {
        boardAnimating = false; save(); open = false; introduction = false; peeking = false
        // Drop the isolated VM. There is no render loop, sound engine or timer.
        engine = nil; position = nil; puzzle = nil
        invitation?.cancel(); retreat?.cancel(); stopMonitoring()
        scheduleInvitation()
    }
    func setInvitations(_ value: Bool) {
        archive.invitations = value; save()
        if !value { invitation?.cancel(); retreat?.cancel(); peeking = false; stopMonitoring() }
        else { scheduleInvitation() }
    }
    func move(_ col: Int) {
        guard !introduction, let engine, let puzzle, position?.status == "playing" else { return }
        let moves = archive.moves + [SurgeMove(col: col, kind: armed ? "surge" : "drop")]
        guard let next = try? engine.replay(puzzle, moves: moves) else { return }
        archive.moves = moves; position = next; armed = false
        if next.status == "won" { archive.completed.insert(puzzle.id) }
        save()
    }
    func undo() {
        guard !archive.moves.isEmpty else { return }
        archive.moves.removeLast(); armed = false; refresh(); save()
    }
    func retry() { archive.moves = []; armed = false; showHint = false; refresh(); save() }
    func nextPuzzle() {
        guard let engine else { return }
        let next = engine.puzzles.first { $0.id > archive.puzzleID && !archive.completed.contains($0.id) }
            ?? engine.puzzles.first { !archive.completed.contains($0.id) } ?? engine.puzzles.first!
        archive.puzzleID = next.id; archive.moves = []; showHint = false; armed = false; refresh(); save()
    }
    func recover() {
        // User explicitly chooses a fresh puzzle; preserve the unreadable archive.
        do {
            if FileManager.default.fileExists(atPath:persistence.url.path) {
                try FileManager.default.copyItem(at:persistence.url,to:persistence.url.appendingPathExtension("recovery-\(UUID().uuidString)"))
            }
            archive = SurgeArchive(); damagedSave = false; error = nil; loadGame(); save()
        } catch { self.error = "The saved puzzle could not be backed up. Please try again." }
    }
    private func loadGame() {
        guard !damagedSave else { return }
        do { if engine == nil { engine = try SurgeEngine() }; try restorePosition() }
        catch { self.error = "Purple Surge could not restore this puzzle. Your save has been kept safe."; damagedSave = true }
    }
    private func restorePosition() throws {
        guard let engine, let found = engine.puzzles.first(where: { $0.id == archive.puzzleID }) else { throw SurgeError.save }
        puzzle = found; position = try engine.replay(found, moves: archive.moves)
    }
    private func refresh() { do { try restorePosition() } catch { self.error = "This puzzle could not be loaded." } }
    private func save() {
        guard !damagedSave else { return }
        do { try persistence.save(archive); error = nil }
        catch { self.error = "Progress is in memory, but could not be saved. Try again before closing Navigator." }
    }
    func retrySave() { save() }
    func acknowledgeNotice() { if !notices.isEmpty { notices.removeFirst() } }
    func updateTasks(_ tasks: [SurgeTaskStatus]) {
        guard tasks != previousTasks else { return }
        let old = Dictionary(previousTasks.map { ($0.id, $0) }, uniquingKeysWith: { a,_ in a })
        for task in tasks {
            if task.needsInput || (old[task.id]?.running == true && (task.completed || task.failed)) {
                if !notices.contains(where: { $0.id == task.id && $0.status == task.status }) {
                    notices.removeAll { $0.id == task.id }; notices.append(task)
                }
            }
        }
        notices.removeAll { notice in tasks.contains { $0.id == notice.id && $0.running } }
        notices.sort { $0.needsInput && !$1.needsInput }
        previousTasks = tasks; runningCount = tasks.filter(\.running).count
        if runningCount == 0 { invitedThisWait = false }
        scheduleInvitation()
    }
    private func stopMonitoring() {
        if let activityMonitor { NSEvent.removeMonitor(activityMonitor); self.activityMonitor = nil }
    }
    private func scheduleInvitation() {
        invitation?.cancel()
        if archive.discovered, let last = archive.lastInvitation, Date().timeIntervalSince(last) < 86400 { stopMonitoring(); return }
        guard !open, archive.invitations, runningCount > 0, !previousTasks.contains(where: \.needsInput), !invitedThisWait else { stopMonitoring(); return }
        if activityMonitor == nil {
            activityMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                self?.lastActivity = Date(); self?.scheduleInvitation(); return event
            }
        }
        let item = DispatchWorkItem { [weak self] in self?.inviteIfSuitable() }
        invitation = item; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: item)
    }
    private func inviteIfSuitable() {
        let window = NSApp.keyWindow
        let typing = window?.firstResponder is NSTextView || Date().timeIntervalSince(lastActivity) < 15
        let active = NSApp.isActive && window != nil && window?.attachedSheet == nil && (window?.isSheet != true || allowComposerSheet)
        guard SurgeInvitationPolicy.eligible(discovered: archive.discovered, enabled: archive.invitations,
             last: archive.lastInvitation, now: Date(), running: runningCount > 0,
             needsInput: previousTasks.contains(where: \.needsInput), typing: typing, active: active, invitedThisWait: invitedThisWait) else { return }
        invitedThisWait = true; archive.lastInvitation = Date()
        let first = !archive.discovered; archive.discovered = true; save(); stopMonitoring()
        if first { show(intro: true) }
        else {
            peeking = true
            let item = DispatchWorkItem { [weak self] in self?.peeking = false }
            retreat = item; DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: item)
        }
    }
}
