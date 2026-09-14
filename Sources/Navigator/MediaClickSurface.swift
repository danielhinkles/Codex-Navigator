import AppKit
import SwiftUI

/// Select on the first mouse-down instead of waiting for double-click timeout.
/// Right-clicks pass through to the tile's existing context menu.
struct MediaClickSurface:NSViewRepresentable {
    var probeKey=""
    let onSelect:()->Void
    let onPreview:()->Void
    final class ClickView:NSView {
        var select:(()->Void)?
        var preview:(()->Void)?
        override var mouseDownCanMoveWindow:Bool {false}
        override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
        override func hitTest(_ point:NSPoint)->NSView? {
            if let event=NSApp.currentEvent,event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control)) {return nil}
            return super.hitTest(point)
        }
        override func mouseDown(with event:NSEvent) {
            select?()
            if event.clickCount==2 {preview?()}
        }
    }
    func makeNSView(context:Context)->ClickView {ClickView()}
    func updateNSView(_ view:ClickView,context:Context) {
        view.select=onSelect;view.preview=onPreview
        if InteractionProbe.enabled {
            view.identifier=NSUserInterfaceItemIdentifier(probeKey)
            InteractionProbe.values["visible-"+probeKey] = { [weak view] in
                guard let view,view.window != nil,view.identifier?.rawValue==probeKey else {return false}
                return view.visibleRect.height>=view.bounds.height-1 && view.visibleRect.width>0
            }
            InteractionProbe.actions["click-"+probeKey] = { [weak view] in
                guard let event=NSEvent.mouseEvent(with:.leftMouseDown,location:.zero,modifierFlags:[],timestamp:0,windowNumber:view?.window?.windowNumber ?? 0,context:nil,eventNumber:0,clickCount:1,pressure:1) else {return}
                view?.mouseDown(with:event)
            }
        }
    }
}
