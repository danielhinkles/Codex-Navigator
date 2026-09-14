import Foundation
import JavaScriptCore

struct SurgePuzzle: Codable, Identifiable {
    let id: Int
    let title, tier, hint, solution: String
    let targetMoves: Int
    let grid: [[Int]]
    let playerSurge, opponentSurge: Bool
}
struct SurgeMove: Codable, Equatable { let col: Int; let kind: String }
struct SurgePosition: Codable {
    struct Cell: Codable { let row, col: Int }
    let board: [[Int]]
    let surge, opponentSurge: Bool
    let status: String
    let reply: Int?
    let line: [Cell]
}
enum SurgeResources {
    static var directory: URL {
        let packaged = Bundle.main.resourceURL!.appendingPathComponent("PurpleSurge")
        if FileManager.default.fileExists(atPath: packaged.path) { return packaged }
        #if SWIFT_PACKAGE
        return Bundle.module.url(forResource: "PurpleSurge", withExtension: nil)!
        #else
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Sources/Navigator/Resources/PurpleSurge")
        #endif
    }
}
/// No host objects, callbacks, network, DOM, timers or filesystem bindings are
/// installed. Only the rule book and a puzzle/move JSON value enter this VM.
final class SurgeEngine {
    let puzzles: [SurgePuzzle]
    private let context: JSContext
    init(directory: URL = SurgeResources.directory) throws {
        struct Catalogue: Decodable { let puzzles: [SurgePuzzle] }
        puzzles = try JSONDecoder().decode(Catalogue.self, from: Data(contentsOf: directory.appendingPathComponent("puzzles.json"))).puzzles
        guard let vm = JSContext() else { throw SurgeError.runtime }
        context = vm
        context.evaluateScript("var window = globalThis;")
        for name in ["rules.js", "puzzle-defence.js", "navigator-engine.js"] {
            context.evaluateScript(try String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8))
            if context.exception != nil { throw SurgeError.runtime }
        }
    }
    func replay(_ puzzle: SurgePuzzle, moves: [SurgeMove]) throws -> SurgePosition {
        guard moves.count <= puzzle.targetMoves else { throw SurgeError.save }
        let encoded = try JSONEncoder().encode(puzzle)
        let value = try JSONSerialization.jsonObject(with: encoded)
        let actions = try JSONSerialization.jsonObject(with: JSONEncoder().encode(moves))
        context.exception = nil
        guard let result = context.objectForKeyedSubscript("navigatorReplay").call(withArguments: [value, actions]),
              context.exception == nil, let text = result.toString(), let data = text.data(using: .utf8) else { throw SurgeError.save }
        return try JSONDecoder().decode(SurgePosition.self, from: data)
    }
}
enum SurgeError: Error { case runtime, save }

struct SurgeArchive: Codable {
    var version = 1
    var puzzleID = 1
    var moves: [SurgeMove] = []
    var completed: Set<Int> = []
    var discovered = false
    var invitations = true
    var lastInvitation: Date? = nil
}
/// Only Navigator's own game file is writable. A failed save never reports success.
final class SurgePersistence {
    let url: URL
    init(directory: URL) { url = directory.appendingPathComponent("purple-surge.json") }
    func load() throws -> SurgeArchive {
        guard FileManager.default.fileExists(atPath: url.path) else { return SurgeArchive() }
        let result = try JSONDecoder().decode(SurgeArchive.self, from: Data(contentsOf: url))
        guard result.version == 1 else { throw SurgeError.save }
        return result
    }
    func save(_ archive: SurgeArchive) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(archive).write(to: url, options: .atomic)
    }
}

struct SurgeInvitationPolicy {
    static func eligible(discovered: Bool, enabled: Bool, last: Date?, now: Date,
                         running: Bool, needsInput: Bool, typing: Bool, active: Bool, invitedThisWait: Bool) -> Bool {
        guard enabled, running, !needsInput, !typing, active, !invitedThisWait else { return false }
        return !discovered || last.map { now.timeIntervalSince($0) >= 86400 } ?? true
    }
}
