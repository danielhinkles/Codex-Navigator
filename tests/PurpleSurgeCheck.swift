import Foundation
import AppKit

// The production default is deliberately not used by this isolated check.
enum NavigatorApp { static let preferences = UserDefaults(suiteName:"navigator.surge.policy-check")! }

enum ComposerLocalState { static func defaultDirectory() -> URL { fatalError("Test must inject storage") } }

@main struct PurpleSurgeCheck {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("navigator-surge-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let start = Date()
        let engine = try SurgeEngine()
        precondition(engine.puzzles.count == 200)
        let puzzle = engine.puzzles[0]
        let initial = try engine.replay(puzzle, moves: [])
        precondition(initial.status == "playing" && initial.surge)
        let moves = [SurgeMove(col: 2, kind: "surge")]
        let win = try engine.replay(puzzle, moves: moves)
        precondition(win.status == "won" && !win.surge && win.line.count == 4)
        for invalid in [[SurgeMove(col: -1, kind: "drop")], [SurgeMove(col: 8, kind: "drop")], [SurgeMove(col: 2, kind: "bogus")], moves + moves] {
            do { _ = try engine.replay(puzzle, moves: invalid); fatalError("Accepted invalid history") } catch {}
        }
        // Every supplied position starts playable and uses only the supported pack.
        for item in engine.puzzles {
            let position = try engine.replay(item, moves: [])
            precondition(position.board.count == 6 && position.board.allSatisfy { $0.count == 7 })
            precondition(position.status == "playing")
        }
        let game = PurpleSurgeStore(directory: root)
        precondition(!game.runtimeLoaded && !game.open)
        game.show(); precondition(game.runtimeLoaded && game.archive.discovered)
        game.armed = true; game.move(2)
        precondition(game.position?.status == "won" && game.archive.completed == [1])
        game.hide(); precondition(!game.runtimeLoaded && game.position == nil)
        game.show(); precondition(game.position?.status == "won" && game.archive.moves == moves)
        let restarted = PurpleSurgeStore(directory: root)
        restarted.show(); precondition(restarted.position?.status == "won" && restarted.archive.moves == moves)
        restarted.undo(); precondition(restarted.position?.status == "playing" && restarted.archive.moves.isEmpty)
        restarted.armed = true; restarted.move(2); restarted.nextPuzzle()
        precondition(restarted.archive.puzzleID == 2 && restarted.archive.moves.isEmpty)
        restarted.setInvitations(false); restarted.hide(); restarted.show()
        precondition(restarted.open && !restarted.archive.invitations)
        let persistence = SurgePersistence(directory: root)
        let saved = try persistence.load(); precondition(saved.puzzleID == 2)
        // Broken/future saves must never be silently overwritten by show/hide.
        try Data("{\"version\":999}".utf8).write(to: persistence.url)
        let damaged = PurpleSurgeStore(directory: root)
        damaged.show(); damaged.hide()
        let corrupted = try String(contentsOf: persistence.url, encoding: .utf8); precondition(corrupted == "{\"version\":999}")
        precondition(damaged.error != nil)
        damaged.recover(); precondition(damaged.error == nil && damaged.position != nil)
        for url in ["https://purplesurge.co.uk/online", "https://accounts.google.com/signin", "https://login.microsoftonline.com/common/oauth2"] {
            precondition(PurpleSurgeOnline.allowed(URL(string:url)!))
        }
        for url in ["file:///etc/passwd", "http://purplesurge.co.uk/online", "https://purplesurge.co.uk.evil.example/", "https://evil.example/", "https://user:password@purplesurge.co.uk/", "https://purplesurge.co.uk:8080/"] {
            precondition(!PurpleSurgeOnline.allowed(URL(string:url)!))
        }
        // Each menu destination opens its own hub; an arena resume must not hijack it.
        let match = URL(string: "https://purplesurge.co.uk/purple-surge/?online=1&matchId=test")!
        for (destination, screen) in [(SurgeDestination.puzzles, "puzzle"), (.tower, "tower"), (.speedRun, "speedrun"), (.progress, "me")] {
            let url = destination.initialURL(savedMatch: match)!
            precondition(PurpleSurgeOnline.allowed(url))
            precondition(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == [URLQueryItem(name: "screen", value: screen)])
        }
        precondition(SurgeDestination.arena.initialURL(savedMatch: match) == match)
        precondition(SurgeDestination.arena.initialURL(savedMatch: URL(string: "https://evil.example/")) == PurpleSurgeOnline.arena)
        precondition(SurgeDestination.offline.initialURL(savedMatch: match) == nil)
        let before = try Data(contentsOf: persistence.url)
        for destination in SurgeDestination.allCases { restarted.destination = destination }
        let after = try Data(contentsOf: persistence.url)
        precondition(after == before)
        precondition(PurpleSurgeOnline.Coordinator.isMatch(URL(string:"https://purplesurge.co.uk/purple-surge/?online=1&matchId=test")!))
        precondition(!PurpleSurgeOnline.Coordinator.isMatch(URL(string:"https://purplesurge.co.uk/api/auth/callback?code=secret")!))
        let now = Date()
        func eligible(discovered: Bool = true, enabled: Bool = true, last: Date? = nil, running: Bool = true, input: Bool = false, typing: Bool = false, active: Bool = true, invited: Bool = false) -> Bool {
            SurgeInvitationPolicy.eligible(discovered: discovered, enabled: enabled, last: last, now: now, running: running, needsInput: input, typing: typing, active: active, invitedThisWait: invited)
        }
        precondition(eligible() && eligible(discovered:false))
        precondition(!eligible(enabled:false) && !eligible(running:false) && !eligible(input:true) && !eligible(typing:true) && !eligible(active:false) && !eligible(invited:true))
        precondition(!eligible(last:now.addingTimeInterval(-86399)) && eligible(last:now.addingTimeInterval(-86401)))
        let attention = PurpleSurgeStore(directory:root.appendingPathComponent("attention"))
        attention.setInvitations(false)
        attention.updateTasks([SurgeTaskStatus(id:"one",status:"running",composer:true),SurgeTaskStatus(id:"two",status:"Running",composer:false)])
        attention.updateTasks([SurgeTaskStatus(id:"one",status:"completed",composer:true),SurgeTaskStatus(id:"two",status:"Status stale",composer:false)])
        precondition(attention.notices.count == 1 && attention.notice?.id == "one")
        attention.updateTasks([SurgeTaskStatus(id:"one",status:"completed",composer:true),SurgeTaskStatus(id:"two",status:"approval",composer:false)])
        precondition(attention.notice?.id == "two" && attention.notices.count == 2)
        attention.acknowledgeNotice(); precondition(attention.notice?.id == "one")
        print("Purple Surge passed: 200 offline boards; authentic Surge solve; invalid moves; atomic save/reopen/restart; undo; corrupt save preservation; hidden VM unload; invitations and attention priority.")
        print(String(format:"Engine + persistence checks: %.3f seconds",Date().timeIntervalSince(start)))
    }
}
