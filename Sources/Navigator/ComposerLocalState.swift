import Foundation

struct ComposerAttachment:Codable,Equatable,Identifiable {
    var id=UUID().uuidString
    let path:String
    let name:String
    /// image = local image, file = any local file/directory, url = web reference.
    let kind:String
    var payload:[String:String] {["path":path,"name":name,"kind":kind]}
}


/// Local Composer editor state. This lives beside Navigator's cache so backups
/// include unsent work, but it is never sent through the execution transport.
struct ComposerEditorState: Codable, Equatable {
    var draft = ""
    var selectedModel = ""
    var selectedEffort = ""
    var selectedSkills: [String] = []
    var selectedPrompt: String? = nil
    var promptInstructions = ""
    var preparedFeedback = ""
    var attachments:[ComposerAttachment]? = nil
    var reviewFeedback: [String: ReviewFeedback] = [:]
}

struct ComposerSubmission: Equatable {
    let taskKey: String
    let text: String
    let draft: String
    let model: String
    let effort: String
    let skills: [String]
    let selectedPrompt: String?
    let promptInstructions: String
    let preparedFeedback: String
    var attachments:[ComposerAttachment] = []
}

private struct ComposerLocalArchive: Codable {
    var editors: [String: ComposerEditorState] = [:]
    var personalPrompts: [QuickPrompt] = []
}

/// A deliberately small local file, independent of Codex task recovery.
/// `storageDirectory` is injectable so the behaviour can be checked without a
/// running worker or any model calls.
final class ComposerLocalState {
    private let url: URL
    private var archive = ComposerLocalArchive()
    private let writeQueue = DispatchQueue(label: "navigator.composer.local-state", qos: .utility)
    private let generationLock = NSLock()
    private var generation = 0
    private let errorLock = NSLock()
    private var persistenceError: String?
    private var errorHandler: ((String?) -> Void)?

    init(storageDirectory: URL = ComposerLocalState.defaultDirectory()) {
        url = storageDirectory.appendingPathComponent("composer-editors.json")
        reload()
    }

    static func defaultDirectory() -> URL {
        let environment = ProcessInfo.processInfo.environment
        if let cache = environment["NAVIGATOR_CACHE"], !cache.isEmpty {
            return URL(fileURLWithPath: cache, isDirectory: true)
        }
        if CommandLine.arguments.contains("--demo") {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("navigator-demo-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Codex Navigator", isDirectory: true)
    }

    func setErrorHandler(_ handler: @escaping (String?) -> Void) { errorHandler = handler }
    var lastError: String? { errorLock.lock(); defer { errorLock.unlock() }; return persistenceError }
    func editor(for key: String) -> ComposerEditorState { archive.editors[key] ?? ComposerEditorState() }
    func hasEditor(for key: String) -> Bool { archive.editors[key] != nil }
    func save(_ editor: ComposerEditorState, for key: String) { archive.editors[key] = editor; schedulePersist() }
    var personalPrompts: [QuickPrompt] { archive.personalPrompts }
    func savePersonalPrompts(_ prompts: [QuickPrompt]) { archive.personalPrompts = prompts; schedulePersist() }

    func reload() {
        invalidatePendingWrites()
        // A restore can replace this file while Navigator is open. Drain any
        // old writer before reading so a stale editor can never overwrite it.
        writeQueue.sync {}
        guard let data = try? Data(contentsOf: url) else { archive = ComposerLocalArchive(); report(nil); return }
        guard let decoded = try? JSONDecoder().decode(ComposerLocalArchive.self, from: data) else {
            archive = ComposerLocalArchive(); report("Composer editor recovery could not be read."); return
        }
        archive = decoded; report(nil)
    }

    /// Synchronously makes the current small editor archive durable. Call this
    /// before a backup; callers receive a concrete error instead of silently
    /// producing a backup that missed unsent work.
    func flush() throws {
        let snapshot = archive
        invalidatePendingWrites()
        do {
            try writeQueue.sync { try self.persist(snapshot) }
            report(nil)
        } catch {
            let message="Composer editor could not be saved: \(error.localizedDescription)"
            report(message)
            throw error
        }
    }

    private func schedulePersist() {
        let snapshot=archive
        let ticket=nextGeneration()
        writeQueue.asyncAfter(deadline:.now()+0.35) { [weak self] in
            guard let self, self.isCurrent(ticket) else { return }
            do {
                try self.persist(snapshot)
                self.report(nil)
            } catch {
                self.report("Composer editor could not be saved: \(error.localizedDescription)")
            }
        }
    }

    private func persist(_ snapshot: ComposerLocalArchive) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(snapshot)
        let temporary = url.appendingPathExtension("tmp-\(UUID().uuidString)")
        do {
            try data.write(to: temporary, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    private func nextGeneration() -> Int { generationLock.lock(); defer { generationLock.unlock() }; generation += 1; return generation }
    private func invalidatePendingWrites() { _ = nextGeneration() }
    private func isCurrent(_ ticket:Int) -> Bool { generationLock.lock(); defer { generationLock.unlock() }; return generation == ticket }
    private func report(_ message:String?) {
        errorLock.lock();persistenceError=message;errorLock.unlock()
        let handler=errorHandler
        DispatchQueue.main.async { handler?(message) }
    }
}
