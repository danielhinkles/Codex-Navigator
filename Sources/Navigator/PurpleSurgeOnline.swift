import SwiftUI
import WebKit

/// A separate persistent website profile. No Codex cookies, message handlers,
/// file URLs, native objects or task data are supplied to the remote game.
struct PurpleSurgeOnline: NSViewRepresentable {
    @Binding var failure: String?
    @Binding var loading: Bool
    let reload: Int
    static let arena = URL(string: "https://purplesurge.co.uk/online")!
    static let profile = UUID(uuidString: "EA7F4598-D56D-4D8F-A846-940506CD1CEC")!
    static func allowed(_ url: URL) -> Bool {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return ["purplesurge.co.uk", "www.purplesurge.co.uk", "accounts.google.com", "login.microsoftonline.com", "login.live.com", "appleid.apple.com", "account.apple.com"].contains(host)
    }
    func makeCoordinator() -> Coordinator { Coordinator(failure: $failure, loading: $loading) }
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = CommandLine.arguments.contains("--demo") ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: Self.profile)
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator; view.uiDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.setAccessibilityLabel("Purple Surge online arena")
        // Never read or persist OAuth callback URLs. Only a game's own resumable
        // match route can replace the arena's initial address.
        let saved = NavigatorApp.preferences.string(forKey: "navigator.surge.onlineMatch").flatMap(URL.init(string:))
        view.load(URLRequest(url: saved.flatMap { Coordinator.isMatch($0) ? $0 : nil } ?? Self.arena))
        return view
    }
    func updateNSView(_ view: WKWebView, context: Context) {
        context.coordinator.failure = $failure
        context.coordinator.loading = $loading
        if context.coordinator.reload != reload { context.coordinator.reload = reload; view.load(URLRequest(url: view.url.flatMap { Self.allowed($0) ? $0 : nil } ?? Self.arena)) }
    }
    static func dismantleNSView(_ view: WKWebView, coordinator: Coordinator) {
        view.setAllMediaPlaybackSuspended(true)
        view.stopLoading(); view.navigationDelegate = nil; view.uiDelegate = nil
        // Destroy the document when tucked away: no hidden arena polls, audio,
        // animation or matchmaking timers. Server-side matches resume by URL.
        view.loadHTMLString("", baseURL: nil)
    }
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var failure: Binding<String?>
        var reload = 0
        var loading: Binding<Bool>
        init(failure: Binding<String?>, loading: Binding<Bool>) { self.failure = failure; self.loading = loading }
        static let gameHosts: Set<String> = ["purplesurge.co.uk", "www.purplesurge.co.uk"]
        static func isMatch(_ url: URL) -> Bool {
            guard url.scheme == "https", gameHosts.contains(url.host?.lowercased() ?? ""), ["/purple-surge", "/purple-surge/"].contains(url.path) else { return false }
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            return query.contains { $0.name == "online" && $0.value == "1" } && query.contains { $0.name == "matchId" && !($0.value ?? "").isEmpty }
        }
        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let mainFrame = action.targetFrame?.isMainFrame ?? true
            guard let url = action.request.url else { decisionHandler(.cancel); return }
            if !mainFrame {
                // Embedded helper frames (sign-in widgets, bot challenges) may load over HTTPS only;
                // they never replace the arena page and never trigger the banner.
                decisionHandler(url.scheme == "https" ? .allow : .cancel); return
            }
            guard PurpleSurgeOnline.allowed(url) else {
                decisionHandler(.cancel)
                DispatchQueue.main.async { self.loading.wrappedValue = false; self.failure.wrappedValue = "This link cannot open inside the game panel. Return to the arena to keep playing." }
                return
            }
            decisionHandler(.allow)
        }
        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { loading.wrappedValue = true }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loading.wrappedValue = false; failure.wrappedValue = nil
            if let url = webView.url, Self.isMatch(url) {
                // Keep only the route parameters required to resume a match.
                let query = URLComponents(url:url,resolvingAgainstBaseURL:false)?.queryItems ?? []
                var safe = URLComponents(url:PurpleSurgeOnline.arena,resolvingAgainstBaseURL:false)!
                safe.path = "/purple-surge/"; safe.queryItems = query.filter { ["online","matchId","twist"].contains($0.name) }
                NavigatorApp.preferences.set(safe.url?.absoluteString, forKey: "navigator.surge.onlineMatch")
            } else if Self.gameHosts.contains(webView.url?.host?.lowercased() ?? ""), webView.url?.path == "/online" {
                NavigatorApp.preferences.removeObject(forKey: "navigator.surge.onlineMatch")
            }
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { report(error) }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { report(error) }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) { loading.wrappedValue = false; failure.wrappedValue = "The arena stopped responding. Reload to reconnect; your offline puzzle is saved." }
        private func report(_ error: Error) {
            guard (error as NSError).code != NSURLErrorCancelled else { return }
            loading.wrappedValue = false
            failure.wrappedValue = "The arena could not connect. Retry, or play your saved offline puzzle." 
        }
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = action.request.url, PurpleSurgeOnline.allowed(url) { webView.load(action.request) }
            return nil
        }
        func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) { completionHandler(nil) }
        func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) { decisionHandler(.deny) }
    }
}
