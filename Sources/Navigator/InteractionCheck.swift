import AppKit
import SwiftUI

/// Opt-in native responder regression, using demo data and this app's own window only.
@MainActor enum InteractionProbe {
    static var enabled:Bool {CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--interaction-check")}
    static var actions:[String:()->Void]=[:]
    static var values:[String:()->Bool]=[:]
    static let undoManager=UndoManager()
    static var preview=""
    static var previewID:UUID?
    static func run() {
        Task { @MainActor in
            guard let mainWindow=NSApp.windows.first(where:{$0.contentView != nil && !$0.isSheet && $0.isVisible}) else {preconditionFailure("Missing main window")}
            @MainActor func eventually(_ condition:()->Bool) async ->Bool {
                for _ in 0..<40 {if condition() {return true};try? await Task.sleep(nanoseconds:50_000_000)}
                return condition()
            }
            @MainActor func pause() async {try? await Task.sleep(nanoseconds:550_000_000)}
            func verify(_ passed:Bool,_ message:String) {
                FileHandle.standardError.write(Data((message + (passed ? " PASS\n" : " FAIL\n")).utf8))
                if !passed {exit(1)}
            }
            @MainActor func check(_ key:String) {let passed=values[key]?() == true;verify(passed,key)}
            @MainActor func key(_ text:String,_ code:UInt16,_ flags:NSEvent.ModifierFlags=[]) {
                var window=mainWindow
                while let sheet=window.attachedSheet {window=sheet}
                window.makeKeyAndOrderFront(nil)
                for type in [NSEvent.EventType.keyDown,.keyUp] {
                    let event=NSEvent.keyEvent(with:type,location:.zero,modifierFlags:flags,timestamp:ProcessInfo.processInfo.systemUptime,windowNumber:window.windowNumber,context:nil,characters:text,charactersIgnoringModifiers:text,isARepeat:false,keyCode:code)!
                    if type == .keyDown,flags.contains(.command),NSApp.mainMenu?.performKeyEquivalent(with:event) == true {continue}
                    NSApp.sendEvent(event)
                }
            }
            NSApp.activate(ignoringOtherApps:true)
            mainWindow.makeKeyAndOrderFront(nil)
            await pause()
            if CommandLine.arguments.contains("--media-check") {await MediaGalleryCheck.run();NSApp.terminate(nil);return}
            actions["table"]?();await pause()
            key(" ",49);await pause();check("sessionOpen")
            actions["nestedAsset"]?();await pause();key(" ",49);await pause()
            verify(preview=="asset","Nested image preview");check("sessionOpen")
            key("\u{1b}",53);await pause();check("sessionOpen")
            key("\u{1b}",53);await pause();check("sessionClosed")
            actions["asset"]?();await pause();check("assetFocused")
            key(" ",49);await pause()
            check("assetPreviewRequested")
            verify(preview=="asset","Space targets image")
            check("sessionClosed")
            key("\u{f703}",124);await pause();check("previewAdvanced")
            key("\u{f702}",123);await pause();check("previewAtStart")
            key("\u{f700}",126);await pause();check("previewAtStart")
            key("\u{f701}",125);await pause();check("previewAdvanced")
            key("\u{f700}",126);await pause();check("previewAtStart")
            key(" ",49);await pause()
            let closed=await eventually {mainWindow.attachedSheet == nil && values["assetPreviewRequested"]?() == false}
            verify(closed,"Space closes image")
            key(" ",49);await pause()
            verify(preview=="asset","Image focus restored")
            key("\u{1b}",53);await pause()
            actions["table"]?();await pause();actions["assetHover"]?();await pause()
            key(" ",49);await pause();verify(preview == "asset","Hovered asset takes Space from sessions")
            key(" ",49);await pause();check("sessionClosed")
            actions["table"]?();await pause();key("f",3,.command);await pause()
            key(" ",49);await pause();check("searchSpace");check("sessionClosed")
            actions["table"]?();await pause();key("\u{f701}",125);await pause();check("movedSelection")
            actions["filter"]?();await pause();check("selectionCleared")
            actions["table"]?();await pause()
            actions["favourite"]?();await pause();check("favourited")
            undoManager.undo();await pause();check("unfavourited")
            undoManager.redo();await pause();check("favourited")
            actions["bulkSelectRange"]?();await pause();check("bulkRangeSelected")
            actions["bulkFavourite"]?();await pause();check("bulkFavourited")
            undoManager.undo();await pause();check("bulkUnfavourited")
            actions["bulkAssign"]?();await pause();check("bulkAssigned")
            undoManager.undo();await pause();check("bulkUnassigned")
            actions["openAssistantSearch"]?()
            verify(await eventually {values["assistantSearchHit"]?() == true},"Assistant conversation search")
            actions["openSearchReader"]?();await pause();check("conversationReaderOpen")
            actions["closeSearchReader"]?();await pause()
            actions["filterActivityDay"]?();await pause();check("activityDayFiltered")
            actions["clearActivityDay"]?();await pause()
            actions["unassigned"]?();await pause();check("unassignedSelected")
            actions["reorderProjects"]?();await pause();check("customOrderSaved")
            actions["alphabeticalProjects"]?();await pause();check("customOrderRetained")
            actions["customProjects"]?();await pause();check("customOrderRestored")
            actions["hideInspector"]?();await pause();check("inspectorHidden")
            actions["showInspector"]?();await pause();check("inspectorShown")
            actions["openComposer"]?();await pause();check("inlineComposer")
            verify(mainWindow.attachedSheet == nil,"Composer is embedded in main window")
            check("composerAttachments");check("composerTimeline")
            check("quickPromptReplacement");check("quickPromptEdits");check("reviewDraftScope")
            actions["composerSend"]?();await pause();await pause();check("composerApproval")
            actions["composerAccept"]?();await pause();check("composerComplete")
            actions["composerSend"]?();await pause();actions["composerStop"]?();await pause();check("composerStopped")
            actions["composerClose"]?();await pause();check("sessionsRestored")
            await MediaGalleryCheck.run()
            mainWindow.makeKeyAndOrderFront(nil)
            actions["newProject"]?();await pause();actions["createProject"]?()
            verify(await eventually {values["newProjectSelected"]?() == true},"New Project registers and selects project")
            actions["newSession"]?();await pause();actions["createSession"]?()
            verify(await eventually {values["newSessionProject"]?() == true},"New Session uses created project and folder")
            print("Interaction check passed: session Space; image Space; Escape and focus restoration; spatial image arrows and Space close; range selection; local bulk favourite/assignment undo; assistant passage search and reader; activity-day filtering; Unassigned sidebar selection; Composer approval, completion and Stop; Custom project order; Command-F and search typing; arrow navigation; filtered selection; acknowledged save and undo/redo.")
            NSApp.terminate(nil)
        }
    }
}
