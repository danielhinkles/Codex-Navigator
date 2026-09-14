import AppKit
import SwiftUI

@MainActor enum MediaGalleryCheck {
    static func run() async {
        let path=Bundle.main.path(forResource:"demo-preview",ofType:"png") ?? ""
        let assets=(0..<80).map {MediaAsset(id:"stress-\($0)",path:path,name:"Media \($0).png",kind:"image",available:true)}
        let view=ScrollViewReader {proxy in
            ScrollView {
                VStack {
                    Text("Media navigation regression").frame(height:100)
                    MediaGallery(assets:assets,indexed:true,probeKey:"stress",reveal:{proxy.scrollTo($0)})
                }.padding(12)
            }
        }
        let window=NSWindow(contentRect:NSRect(x:100,y:100,width:300,height:380),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        window.isReleasedWhenClosed=false;window.contentView=NSHostingView(rootView:view)
        window.makeKeyAndOrderFront(nil)
        func pause() async {try? await Task.sleep(nanoseconds:150_000_000)}
        func key(_ code:UInt16) {
            var target=window
            while let sheet=target.attachedSheet {target=sheet}
            target.makeKeyAndOrderFront(nil)
            let text=code==49 ? " " : code==53 ? "\u{1b}" : code==125 ? "\u{f701}" : "\u{f700}"
            for type in [NSEvent.EventType.keyDown,.keyUp] {
                guard let event=NSEvent.keyEvent(with:type,location:.zero,modifierFlags:[],timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:target.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code) else {return}
                NSApp.sendEvent(event)
            }
        }
        func check(_ label:String) {
            let pass=InteractionProbe.values["stressSelectedVisible"]?() == true
            FileHandle.standardError.write(Data((label + (pass ? " PASS\n" : " FAIL\n")).utf8))
            if !pass {exit(1)}
        }
        await pause();await pause()
        InteractionProbe.actions["click-stress-0"]?()
        // Selection must have changed synchronously, without a double-click timeout.
        guard InteractionProbe.values["stressSelected"]?() == true else {exit(1)}
        await pause()
        for _ in 0..<25 {key(125);await pause()}
        guard InteractionProbe.values["stressMoved"]?() == true else {exit(1)}
        check("Media arrows scroll down to selected tile")
        for _ in 0..<25 {key(126);await pause()}
        guard InteractionProbe.values["stressMoved"]?() == false else {exit(1)}
        check("Media arrows scroll up to selected tile")
        key(49);await pause();await pause()
        let opened=InteractionProbe.values["stressPreviewRequested"]?() == true
        FileHandle.standardError.write(Data(("Stress preview opened: \(opened), sheet: \(window.attachedSheet != nil)\n").utf8))
        guard opened else {exit(1)}
        for _ in 0..<20 {key(125);await pause()}
        guard InteractionProbe.values["stressMoved"]?() == true else {FileHandle.standardError.write(Data("Preview did not advance FAIL\n".utf8));exit(1)}
        check("Preview navigation scrolls underlying media")
        key(53);await pause()
        check("Closing preview retains visible selection")
        window.close()
    }
}
