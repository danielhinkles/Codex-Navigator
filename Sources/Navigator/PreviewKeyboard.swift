import AppKit
import SwiftUI

/// Preview-only routing: image/Quick Look controls can take first responder, but
/// Space and browsing arrows still belong to this sheet, never another window.
struct PreviewKeyboard:NSViewRepresentable {
    let action:(UInt16)->Bool
    final class KeyView:NSView {
        var action:((UInt16)->Bool)?
        var monitor:Any?
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {NSEvent.removeMonitor(monitor);self.monitor=nil}
            guard window != nil else {return}
            monitor=NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
                guard let self,let window=self.window,event.window === window,window.attachedSheet == nil,
                      event.modifierFlags.intersection([.command,.control,.option]).isEmpty else {return event}
                return self.action?(event.keyCode) == true ? nil : event
            }
        }
        deinit {if let monitor {NSEvent.removeMonitor(monitor)}}
    }
    func makeNSView(context:Context)->KeyView {KeyView()}
    func updateNSView(_ view:KeyView,context:Context) {view.action=action}
}
