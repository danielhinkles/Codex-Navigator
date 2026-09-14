import SwiftUI
import WebKit

/// The offline renderer receives game snapshots only, never task or account data.
struct PurpleSurgeBoard: NSViewRepresentable {
    @ObservedObject var game: PurpleSurgeStore
    let reduced: Bool
    func makeCoordinator() -> Coordinator { Coordinator(game) }
    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(BoardFiles(), forURLScheme: "surge-board")
        configuration.userContentController.add(context.coordinator, name: "board")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.underPageBackgroundColor = .clear
        view.navigationDelegate = context.coordinator
        context.coordinator.view = view
        view.load(URLRequest(url: URL(string: "surge-board://bundle/board.html")!))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.reduced = reduced
        context.coordinator.present()
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        coordinator.ready = false
        view.configuration.userContentController.removeScriptMessageHandler(forName: "board")
        view.stopLoading(); view.navigationDelegate = nil
        view.loadHTMLString("", baseURL: nil)
        DispatchQueue.main.async { coordinator.game.boardAnimating = false }
    }
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        let game: PurpleSurgeStore
        weak var view: WKWebView?
        var ready = false, reduced = false
        var lastPayload: Data?
        init(_ game: PurpleSurgeStore) { self.game = game }
        var key: String { "\(game.archive.puzzleID):" + game.archive.moves.map { "\($0.kind)\($0.col)" }.joined(separator: ",") }
        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.frameInfo.isMainFrame, message.frameInfo.securityOrigin.protocol == "surge-board",
                  message.frameInfo.securityOrigin.host == "bundle", let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready" { ready = true; present(); return }
            guard body["key"] as? String == key else {
                // A move against a stale key gets the current board back so the page's busy latch clears.
                if type == "move" { lastPayload = nil; present() }
                return
            }
            if type == "done", game.boardAnimating { game.boardAnimating = false }
            if !game.boardAnimating {
                switch type {
                case "arm": if game.position?.surge == true && game.position?.status == "playing" { game.armed.toggle() }
                case "undo": game.undo()
                case "restart": game.retry()
                case "next": if game.position?.status == "won" { game.nextPuzzle() }
                default: break
                }
                present()
            }
            if type == "move", !game.boardAnimating, let col = body["col"] as? Int, (0..<7).contains(col) {
                let old = key
                game.move(col)
                game.boardAnimating = key != old
                if key == old { lastPayload = nil }  // rejected move: resend the unchanged board to release the page
                present()
            }
        }
        func present() {
            guard ready, let view, let puzzle = game.puzzle, let position = game.position else { return }
            struct Snapshot: Encodable {
                let key: String; let puzzle: SurgePuzzle; let position: SurgePosition
                let moves: [SurgeMove]; let armed, enabled, reduced: Bool
            }
            let snapshot = Snapshot(key: key, puzzle: puzzle, position: position, moves: game.archive.moves,
                armed: game.armed, enabled: !game.introduction && position.status == "playing", reduced: reduced)
            let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
            guard let data = try? encoder.encode(snapshot), data != lastPayload,
                  let value = try? JSONSerialization.jsonObject(with: data) else { return }
            lastPayload = data
            Task { @MainActor [weak self] in
                do { _ = try await view.callAsyncJavaScript("await window.presentBoard(snapshot)", arguments: ["snapshot": value], in: nil, contentWorld: .page) }
                catch { self?.game.boardAnimating = false; self?.lastPayload = nil }
            }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            decisionHandler(action.request.url?.absoluteString == "surge-board://bundle/board.html" ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false; lastPayload = nil; game.boardAnimating = false
            webView.reload()
        }
    }
}

/// Fixed allowlist; no general filesystem or network access is exposed to WebKit.
final class BoardFiles: NSObject, WKURLSchemeHandler {
    static let paths: Set<String> = ["board.html", "rules.js", "puzzle-defence.js", "board-renderer.js", "navigator-board.js",
        "css/accessible.css", "css/main.css", "css/shell.css", "css/theme.css", "css/board.css", "css/animations.css", "css/navigator.css",
        "img/board-frame-clean.webp", "img/board-neon.webp", "img/token-red.webp", "img/token-yellow.webp", "img/token-purple.webp", "img/token-green.webp"]
    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url, url.scheme == "surge-board", url.host == "bundle",
              Self.paths.contains(String(url.path.dropFirst())),
              let data = try? Data(contentsOf: SurgeResources.directory.appendingPathComponent(String(url.path.dropFirst()))) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }
        let mime = ["html":"text/html", "js":"text/javascript", "css":"text/css", "webp":"image/webp"][url.pathExtension]!
        task.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count, textEncodingName: "utf-8"))
        task.didReceive(data); task.didFinish()
    }
    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
}
