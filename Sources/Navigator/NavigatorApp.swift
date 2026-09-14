import SwiftUI
import AppKit

@main
struct NavigatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var model = NavigatorModel()
    static let preferences = CommandLine.arguments.contains("--demo") ? UserDefaults(suiteName:"navigator.demo.\(ProcessInfo.processInfo.processIdentifier)")! : UserDefaults.standard
    var body: some Scene {
        WindowGroup("Codex Navigator") {
            NavigatorView().environmentObject(model)
                .defaultAppStorage(Self.preferences)
                .frame(minWidth: 1080, minHeight: 680)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.stop() }
        }
        .defaultSize(width: 1460, height: 900)
        .windowStyle(.hiddenTitleBar)
        .commands { CommandGroup(replacing: .newItem) {};NavigatorCommands() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    static var maintenanceInProgress=false
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if Self.maintenanceInProgress {NSSound.beep();return .terminateCancel}
        return .terminateNow
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        ProjectLauncher.usePreferences(NavigatorApp.preferences)
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if CommandLine.arguments.contains("--demo") {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.3) {
                if let window=NSApp.windows.first(where:{$0.contentView != nil && !$0.isSheet}) {
                    window.isRestorable=false;window.setFrameAutosaveName("")
                    window.setContentSize(NSSize(width:1460,height:900))
                }
            }
        }
        if CommandLine.arguments.contains("--demo") && (CommandLine.arguments.contains("--interface-check") || CommandLine.arguments.contains("--window-check")) {
            DispatchQueue.main.asyncAfter(deadline:.now()+2) {InterfaceCheck.run()}
        }
        if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--drag-check") {DispatchQueue.main.asyncAfter(deadline:.now()+3) {ProjectDragCheck.run()}}
        if InteractionProbe.enabled {DispatchQueue.main.asyncAfter(deadline:.now()+3) {InteractionProbe.run()}}
        if CommandLine.arguments.contains("--demo") && CommandLine.arguments.contains("--small-window") {
            DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                NSApp.windows.first(where:{$0.contentView != nil && !$0.isSheet})?.setContentSize(NSSize(width:1080,height:740))
            }
        }
        // Deterministic rendering hook for verifying this app's own UI, with demo data.
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > i+1 {
            let path = CommandLine.arguments[i+1]
            DispatchQueue.main.asyncAfter(deadline: .now()+4) {
                guard let window = NSApp.windows.first, let view = (window.attachedSheet ?? window).contentView,
                      let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                NotificationCenter.default.post(name:Notification.Name("NavigatorSnapshotFinished"),object:nil)
                DispatchQueue.main.asyncAfter(deadline:.now()+0.5) {
                    for parent in NSApp.windows where parent.attachedSheet != nil {if let sheet=parent.attachedSheet {parent.endSheet(sheet)}}
                    NSApp.terminate(nil)
                }
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
