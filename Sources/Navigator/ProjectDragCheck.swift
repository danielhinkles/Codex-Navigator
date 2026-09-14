import AppKit
import CoreGraphics

@MainActor enum ProjectDragCheck {
    static func run() {
        Task { @MainActor in
            func verify(_ yes:Bool,_ text:String) {
                FileHandle.standardError.write(Data((text+(yes ? " PASS\n" : " FAIL\n")).utf8))
                if !yes {exit(1)}
            }
            @MainActor func rows(_ view:NSView)->[ProjectDragSurface.DragView] {
                if let row=view as? ProjectDragSurface.DragView {return [row]}
                return view.subviews.flatMap{rows($0)}
            }
            guard let window=NSApp.windows.first(where:{$0.isVisible && !$0.isSheet}),let content=window.contentView else {exit(1)}
            window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            let views=rows(content).sorted{$0.convert(.zero,to:nil).y > $1.convert(.zero,to:nil).y}
            verify(views.count>=3,"Native project drag rows exist")
            let source=views.last!,target=views.first!,id=source.projectID
            let from=source.convert(NSPoint(x:source.bounds.midX,y:source.bounds.midY),to:nil)
            let to=target.convert(NSPoint(x:target.bounds.midX,y:target.bounds.midY),to:nil)
            verify(content.hitTest(content.superview?.convert(from,from:nil) ?? from) === source,"Project source owns actual hit target")
            @MainActor func post(_ type:NSEvent.EventType,_ point:NSPoint) {
                let event=NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                NSApp.sendEvent(event)
            }
            post(.leftMouseDown,from)
            try? await Task.sleep(nanoseconds:200_000_000)
            for step in 1...20 {
                let f=Double(step)/20
                post(.leftMouseDragged,NSPoint(x:from.x+(to.x-from.x)*f,y:from.y+(to.y-from.y)*f))
                try? await Task.sleep(nanoseconds:50_000_000)
            }
            post(.leftMouseUp,to)
            try? await Task.sleep(nanoseconds:700_000_000)
            verify(ProjectDragSurface.DragView.starts>0,"Real mouse sequence began NSDraggingSession")
            // Synthetic in-process events do not make WindowServer deliver a drop.
            // Exercise AppKit's destination methods with the real source pasteboard.
            guard let board=ProjectDragSurface.DragView.lastPasteboard else {exit(1)}
            let info=DragTestInfo(window:window,source:source,pasteboard:board)
            verify(target.draggingEntered(info) == .move,"Native destination accepts source pasteboard")
            verify(target.prepareForDragOperation(info) && target.performDragOperation(info),"Native destination performs source drop")
            try? await Task.sleep(nanoseconds:500_000_000)
            verify(ProjectDragSurface.DragView.drops>0,"Native destination received drop")
            let order=ProjectOrder.decode(NavigatorApp.preferences.string(forKey:"navigator.customProjectOrder") ?? "[]")
            verify(NavigatorApp.preferences.string(forKey:"navigator.projectSort")=="Custom" && order.first==id,"Native drag persisted requested Custom order")
            print("Project drag check passed native source mouse dispatch and destination pasteboard checks.")
            NSApp.terminate(nil)
        }
    }
}
