import AppKit
import SwiftUI

/// AppKit retains one mouse-down origin for the whole drag, independent of
/// SwiftUI layout changes. Limits are frozen until mouse-up to prevent feedback.
struct ResizeHandle:NSViewRepresentable {
    @Binding var value:Double
    let limits:ClosedRange<Double>
    let vertical:Bool
    let direction:Double
    let label:String
    var onCommit:(()->Void)? = nil

    final class DragView:NSView {
        var currentValue=0.0
        var limits=0.0...1.0
        var vertical=false
        var direction=1.0
        var changed:((Double)->Void)?
        var committed:(()->Void)?
        private var origin:CGPoint?
        private var initial=0.0
        private var dragLimits=0.0...1.0
        override var mouseDownCanMoveWindow:Bool {false}
        override func acceptsFirstMouse(for event:NSEvent?)->Bool {true}
        override func resetCursorRects() {
            addCursorRect(bounds,cursor:vertical ? .resizeUpDown : .resizeLeftRight)
        }
        override func draw(_ dirtyRect:NSRect) {
            NSColor.secondaryLabelColor.withAlphaComponent(0.5).setFill()
            let mark = vertical ? NSRect(x:8,y:(bounds.height-2)/2,width:max(0,bounds.width-16),height:2)
                : NSRect(x:(bounds.width-1)/2,y:5,width:1,height:max(0,bounds.height-10))
            NSBezierPath(roundedRect:mark,xRadius:1,yRadius:1).fill()
        }
        override func mouseDown(with event:NSEvent) {
            origin=event.locationInWindow
            dragLimits=limits
            initial=min(limits.upperBound,max(limits.lowerBound,currentValue))
        }
        override func mouseDragged(with event:NSEvent) {
            guard let origin else {return}
            let delta=vertical ? origin.y-event.locationInWindow.y : event.locationInWindow.x-origin.x
            let next=min(dragLimits.upperBound,max(dragLimits.lowerBound,initial+delta*direction))
            guard next.isFinite,abs(next-currentValue)>=0.25 else {return}
            currentValue=next
            changed?(next)
        }
        override func mouseUp(with event:NSEvent) {
            mouseDragged(with:event)
            origin=nil;committed?()
        }
        override func viewWillMove(toWindow newWindow:NSWindow?) {
            if newWindow == nil {origin=nil}
            super.viewWillMove(toWindow:newWindow)
        }
    }
    func makeNSView(context:Context) -> DragView {DragView()}
    func updateNSView(_ view:DragView,context:Context) {
        view.currentValue=value
        view.limits=limits
        view.vertical=vertical
        view.direction=direction
        view.changed={next in if value != next {value=next}}
        view.committed=onCommit
        view.identifier=NSUserInterfaceItemIdentifier(label)
        view.toolTip="Drag to resize " + label
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel(label)
        view.setAccessibilityRole(.splitter)
        view.setAccessibilityValue(Int(value))
        view.needsDisplay=true
        view.window?.invalidateCursorRects(for:view)
    }
}
