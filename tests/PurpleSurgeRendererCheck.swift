import AppKit
import WebKit
import SwiftUI
struct ComposerLocalState { static func defaultDirectory() -> URL { URL(fileURLWithPath:"/tmp/surge-render-check") } }
@main struct Check {
 static func main() {
  let app = NSApplication.shared
  let storage = URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
  defer { try? FileManager.default.removeItem(at: storage) }
  let game = PurpleSurgeStore(directory: storage)
  game.show()
  let coord=PurpleSurgeBoard.Coordinator(game)
  let config=WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
  config.setURLSchemeHandler(BoardFiles(), forURLScheme:"surge-board")
  config.userContentController.add(coord,name:"board")
  let web=WKWebView(frame:NSRect(x:0,y:0,width:324,height:605),configuration:config)
  coord.view=web; web.navigationDelegate=coord
  let window=NSWindow(contentRect:web.frame,styleMask:[.titled],backing:.buffered,defer:false)
  window.contentView=web; window.makeKeyAndOrderFront(nil)
  web.load(URLRequest(url:URL(string:"surge-board://bundle/board.html")!))
  Task { @MainActor in
   do {
    try await Task.sleep(for:.seconds(3))
    let count=try await web.evaluateJavaScript("document.querySelectorAll('.board-cell').length")
    precondition((count as? Int)==42,"Board must render 42 cells")
    for height in [425.0, 520.0, 700.0] {
        web.setFrameSize(NSSize(width:324,height:height))
        try await Task.sleep(for:.milliseconds(100))
        let ratio=try await web.evaluateJavaScript("(() => {const r=document.querySelector('.board-wrapper').getBoundingClientRect();return r.width/r.height})()")
        precondition(abs((ratio as? Double ?? 0) - 1355.0/1161.0)<0.01,"Puzzle board must preserve its aspect ratio at every drawer height")
    }
    let turn=try await web.evaluateJavaScript("document.body.dataset.turn")
    precondition(turn as? String == "1", "Red lighting on player turn")
    _ = try await web.evaluateJavaScript("document.getElementById('btn-use-purple').click()")
    try await Task.sleep(for:.milliseconds(100))
    _ = try await web.evaluateJavaScript("gameManager.handleColumnDrop(2)")
    try await Task.sleep(for:.milliseconds(900))
    let purple=try await web.evaluateJavaScript("document.body.dataset.surge")
    precondition(purple as? String == "purple", "Purple lighting during surge")
    let laser=try await web.evaluateJavaScript("document.getElementById('laser-beam').classList.contains('active')")
    precondition(laser as? Bool == true,"Original laser must animate")
    try await Task.sleep(for:.seconds(3))
    precondition(game.position?.status == "won" && !game.boardAnimating)
    let win=try await web.evaluateJavaScript("document.querySelectorAll('.winning-token').length")
    precondition((win as? Int ?? 0)>=4,"Winning tokens should highlight")
    _ = try await web.evaluateJavaScript("paintHUD(2,false,true)")
    let yellow=try await web.evaluateJavaScript("document.body.dataset.turn === '2' && document.getElementById('p2-card').classList.contains('active-turn') && document.getElementById('turn-announcer').classList.contains('is-p2')")
    precondition(yellow as? Bool == true, "Opponent turn lights board, card and banner yellow")
    _ = try await web.evaluateJavaScript("paintHUD(1,false,false)")
    let shot=try await web.takeSnapshot(configuration:nil)
    try shot.tiffRepresentation!.write(to:URL(fileURLWithPath:"/tmp/surge-board.tiff"))
    game.retry(); coord.reduced = true; coord.present()
    try await Task.sleep(for:.milliseconds(100))
    game.armed=true; coord.present()
    try await Task.sleep(for:.milliseconds(100))
    _ = try await web.evaluateJavaScript("gameManager.handleColumnDrop(2)")
    try await Task.sleep(for:.milliseconds(150))
    precondition(game.position?.status == "won" && !game.boardAnimating, "Reduced motion settles immediately")
    game.hide(); game.show(); coord.present()
    try await Task.sleep(for:.milliseconds(100))
    precondition(game.position?.status == "won", "Hiding preserves the settled move")
    print("Original board, bridge, surge laser, collapse, winning line, reduced motion and restore passed")
    app.terminate(nil)
   } catch { print(error); exit(1) }
  }
  app.run()
 }
}
