import AppKit
import SwiftUI

/// Opt-in integration check against the real demo window; never uses live data.
enum InterfaceCheck {
    static func run() {
        Task { @MainActor in
            guard let window=NSApp.windows.first(where: {$0.contentView != nil}) else {return}
            window.title="Navigator interface verification"
            func pause() async {try? await Task.sleep(nanoseconds:80_000_000)}
            @MainActor func handles(_ view:NSView)->[ResizeHandle.DragView] {
                if let handle=view as? ResizeHandle.DragView {return [handle]}
                return view.subviews.flatMap {handles($0)}
            }
            @MainActor func verify(_ passed:Bool,_ message:String="Divider did not return to its initial width") {
                if !passed {FileHandle.standardError.write(Data(("Interface check failed: "+message+"\n").utf8));exit(1)}
            }
            var drags=0
            for handle in handles(window.contentView!) {
                // A committed divider write can trigger one SwiftUI update
                // before the next native handle is queried. Let that update
                // settle so the following drag starts from its real width.
                await pause()
                let initial=handle.currentValue, bounds=handle.limits
                FileHandle.standardError.write(Data(("Checking "+(handle.identifier?.rawValue ?? "divider")+"\n").utf8))
                let start=handle.convert(NSPoint(x:handle.bounds.midX,y:handle.bounds.midY),to:nil)
                @MainActor func event(_ type:NSEvent.EventType,_ delta:Double)->NSEvent {
                    let point=NSPoint(x:start.x+(handle.vertical ? 0 : delta),y:start.y+(handle.vertical ? -delta : 0))
                    return NSEvent.mouseEvent(with:type,location:point,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,eventNumber:0,clickCount:1,pressure:1)!
                }
                let content=window.contentView!
                let hit=content.hitTest(content.superview?.convert(start,from:nil) ?? start)
                verify(hit === handle,"Resize handle is covered by another view: " + (handle.identifier?.rawValue ?? "divider"))
                NSApp.sendEvent(event(.leftMouseDown,0))
                for delta in [10000.0,-10000,9000,-9000,5000,-5000,0] {
                    NSApp.sendEvent(event(.leftMouseDragged,delta))
                    await pause()
                    verify(handle.currentValue.isFinite && bounds.contains(handle.currentValue),"Divider escaped limits")
                    let expected=min(bounds.upperBound,max(bounds.lowerBound,min(bounds.upperBound,max(bounds.lowerBound,initial))+delta*handle.direction))
                    verify(abs(handle.currentValue-expected)<1,"Native mouse drag did not reach the requested width for " + (handle.identifier?.rawValue ?? "divider"))
                    drags += 1
                }
                NSApp.sendEvent(event(.leftMouseUp,0))
                await pause()
                verify(abs(handle.currentValue-min(bounds.upperBound,max(bounds.lowerBound,initial)))<1)
            }
            @MainActor func checkThemes() async {
                for value in ["Light","Dark","System","Dark","Light","System"] {
                    NavigatorApp.preferences.set("Dark",forKey:"navigator.theme")
                    NavigatorApp.preferences.set("Light",forKey:"navigator.theme")
                    NavigatorApp.preferences.set(value,forKey:"navigator.theme")
                    await pause()
                    let dark=value == "Dark" || (value == "System" && AppAppearance.systemIsDark)
                    verify(AppAppearance.shared.scheme == (dark ? .dark : .light),"SwiftUI theme mismatch")
                    verify(NSApp.appearance?.name == (value == "System" ? nil : value == "Dark" ? .darkAqua : .aqua),"AppKit theme mismatch")
                    verify(window.appearance == nil,"Window overrides application theme")
                    verify(window.effectiveAppearance.bestMatch(from:[.aqua,.darkAqua]) == (dark ? .darkAqua : .aqua),"Visible window appearance mismatch")
                }
            }
            await checkThemes()
            if CommandLine.arguments.contains("--window-check") {
                print("Window check passed: \(drags) extreme divider moves and rapid theme changes. Fullscreen was not requested.")
                NSApp.terminate(nil);return
            }
            window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
            await pause()
            FileHandle.standardError.write(Data(("Full-screen request: style=\(window.styleMask.rawValue) behavior=\(window.collectionBehavior.rawValue) frame=\(window.frame) min=\(window.minSize) max=\(window.maxSize)\n").utf8))
            window.toggleFullScreen(nil)
            for _ in 0..<75 {
                await pause()
                if window.styleMask.contains(.fullScreen) {break}
            }
            verify(window.styleMask.contains(.fullScreen),"Did not enter full screen")
            try? await Task.sleep(nanoseconds:1_000_000_000)
            await checkThemes()
            window.toggleFullScreen(nil)
            for _ in 0..<75 {
                await pause()
                if !window.styleMask.contains(.fullScreen) {break}
            }
            verify(!window.styleMask.contains(.fullScreen),"Did not exit full screen")
            try? await Task.sleep(nanoseconds:1_000_000_000)
            await checkThemes()
            print("Interface check passed: \(drags) extreme divider moves; rapid theme changes before, during and after full screen.")
            NSApp.terminate(nil)
        }
    }
}
