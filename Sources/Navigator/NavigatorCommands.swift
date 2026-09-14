import AppKit
import SwiftUI

/// Native responders can sit outside SwiftUI's focus graph. Keep Find attached
/// to its actual window, including after focus moves into a thumbnail gallery.
private enum WindowSearch {
    final class Entry {
        weak var window:NSWindow?
        let action:()->Void
        init(_ window:NSWindow,_ action:@escaping ()->Void) {self.window=window;self.action=action}
    }
    static var entries:[ObjectIdentifier:Entry]=[:]
    static func find() {
        entries=entries.filter {$0.value.window != nil}
        if let window=NSApp.keyWindow ?? NSApp.mainWindow {
            entries[ObjectIdentifier(window)]?.action()
        } else if entries.count == 1 {
            // Also supports the menu action while a single-window app activates.
            entries.values.first?.action()
        }
    }
}
struct SearchRegistration:NSViewRepresentable {
    let action:()->Void
    final class RegistrationView:NSView {
        var action:(()->Void)?
        var registered:ObjectIdentifier?
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();register()}
        func register() {
            if let registered {WindowSearch.entries.removeValue(forKey:registered);self.registered=nil}
            if let window,let action {
                let key=ObjectIdentifier(window);registered=key
                WindowSearch.entries[key]=WindowSearch.Entry(window,action)
            }
        }
        func unregister() {if let registered {WindowSearch.entries.removeValue(forKey:registered);self.registered=nil}}
    }
    func makeNSView(context:Context)->RegistrationView {RegistrationView()}
    func updateNSView(_ view:RegistrationView,context:Context) {view.action=action;view.register()}
    static func dismantleNSView(_ view:RegistrationView,coordinator:()) {view.unregister()}
}
struct NavigatorCommands:Commands {
    var body:some Commands {
        CommandGroup(after:.textEditing) {
            Button("Find sessions") {WindowSearch.find()}.keyboardShortcut("f",modifiers:.command)
        }
    }
}
