import AppKit
import SwiftUI

/// A pane owns a real window responder. Selection in another pane cannot intercept keys.
struct KeyboardSurface:NSViewRepresentable {
    @Binding var active:Bool
    let label:String
    let handle:(UInt16)->Bool
    final class KeyView:NSView {
        var requested=false
        var observer:NSObjectProtocol?
        var action:((UInt16)->Bool)?
        var changed:((Bool)->Void)?
        override var acceptsFirstResponder:Bool {true}
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func becomeFirstResponder()->Bool {changed?(true);return true}
        override func resignFirstResponder()->Bool {changed?(false);return true}
        override func keyDown(with event:NSEvent) {
            guard event.modifierFlags.intersection([.command,.control,.option]).isEmpty,
                  action?(event.keyCode) == true else {super.keyDown(with:event);return}
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {NotificationCenter.default.removeObserver(observer);self.observer=nil}
            if let window {observer=NotificationCenter.default.addObserver(forName:NSWindow.didBecomeKeyNotification,object:window,queue:.main) { [weak self] _ in if self?.requested == true {self?.requestFocus()}}}
            if requested {requestFocus()}
        }
        deinit {if let observer {NotificationCenter.default.removeObserver(observer)}}
        func requestFocus() {
            DispatchQueue.main.async { [weak self] in
                guard let self,self.requested,let window=self.window else {return}
                if window.firstResponder !== self {window.makeFirstResponder(self)}
            }
        }
    }
    func makeNSView(context:Context)->KeyView {KeyView()}
    func updateNSView(_ view:KeyView,context:Context) {
        let previous=view.requested
        view.requested=active;view.action=handle
        view.changed={ [weak view] value in DispatchQueue.main.asyncAfter(deadline:.now()+0.01) {
            guard let view else {return}
            // An obsolete resign callback must not clear a subsequently restored responder.
            if !value,view.window?.firstResponder === view {return}
            if value,view.window?.firstResponder !== view {return}
            if active != value {active=value}
        }}
        view.setAccessibilityLabel(label)
        if active && !previous {view.requestFocus()}
    }
}
