import AppKit
import SwiftUI

/// Own the mouse sequence, instead of competing with a SwiftUI Button for a drag.
struct ProjectDragSurface:NSViewRepresentable {
    let id:String
    let name:String
    let payload:()->String
    let click:()->Void
    let dragging:(Bool)->Void
    let targeted:(Bool)->Void
    let drop:(String)->Bool
    final class DragView:NSView,NSDraggingSource {
        static var starts=0,drops=0
        static var lastPasteboard:NSPasteboard?
        var payload:(()->String)?;var click:(()->Void)?;var dragging:((Bool)->Void)?
        var targeted:((Bool)->Void)?;var drop:((String)->Bool)?
        var down:NSEvent?;var inDrag=false
        var projectID=""
        override var acceptsFirstResponder:Bool {true}
        override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
        override func hitTest(_ point:NSPoint)->NSView? {
            if NSApp.currentEvent?.type == .rightMouseDown {return nil}
            return super.hitTest(point)
        }
        override func mouseDown(with event:NSEvent) {down=event;inDrag=false}
        override func mouseDragged(with event:NSEvent) {
            guard let down,!inDrag,hypot(event.locationInWindow.x-down.locationInWindow.x,event.locationInWindow.y-down.locationInWindow.y)>4,let value=payload?() else {return}
            inDrag=true;dragging?(true)
            let item=NSDraggingItem(pasteboardWriter:value as NSString)
            let image=NSImage(size:bounds.size)
            image.lockFocus();NSColor.controlAccentColor.withAlphaComponent(0.3).setFill();NSBezierPath(roundedRect:bounds,xRadius:7,yRadius:7).fill()
            (accessibilityLabel() ?? "Project").draw(at:NSPoint(x:12,y:10),withAttributes:[.font:NSFont.systemFont(ofSize:14),.foregroundColor:NSColor.labelColor]);image.unlockFocus()
            item.setDraggingFrame(bounds,contents:image)
            Self.starts+=1
            let session=beginDraggingSession(with:[item],event:event,source:self)
            if CommandLine.arguments.contains("--drag-check") {Self.lastPasteboard=session.draggingPasteboard}
        }
        override func mouseUp(with event:NSEvent) {if down != nil && !inDrag {click?()};down=nil}
        func draggingSession(_ session:NSDraggingSession,sourceOperationMaskFor context:NSDraggingContext)->NSDragOperation {context == .withinApplication ? .move : []}
        func draggingSession(_ session:NSDraggingSession,endedAt screenPoint:NSPoint,operation:NSDragOperation) {down=nil;inDrag=false;dragging?(false)}
        private func accepts(_ sender:NSDraggingInfo)->Bool {
            guard let value=sender.draggingPasteboard.string(forType:.string) else {return false}
            return value.hasPrefix("navigator-projects:") || value.hasPrefix("navigator-session:")
        }
        override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {let yes=accepts(sender);targeted?(yes);return yes ? .move : []}
        override func draggingUpdated(_ sender:NSDraggingInfo)->NSDragOperation {accepts(sender) ? .move : []}
        override func draggingExited(_ sender:NSDraggingInfo?) {targeted?(false)}
        override func prepareForDragOperation(_ sender:NSDraggingInfo)->Bool {accepts(sender)}
        override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
            targeted?(false)
            guard let value=sender.draggingPasteboard.string(forType:.string) else {return false}
            let accepted=drop?(value) ?? false
            if accepted {Self.drops+=1}
            return accepted
        }
        override func accessibilityPerformPress()->Bool {click?();return true}
    }
    func makeNSView(context:Context)->DragView {let view=DragView();view.registerForDraggedTypes([.string]);view.setAccessibilityRole(.button);return view}
    func updateNSView(_ view:DragView,context:Context) {
        view.projectID=id;view.setAccessibilityLabel(name);view.payload=payload;view.click=click
        view.dragging=dragging;view.targeted=targeted;view.drop=drop
    }
}
