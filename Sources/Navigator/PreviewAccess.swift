import AppKit
import SwiftUI

enum PreviewAccess {
    static var enabled:Bool {
        if CommandLine.arguments.contains("--demo") {return !CommandLine.arguments.contains("--access-denied-preview")}
        return ["folders","broad"].contains(NavigatorApp.preferences.string(forKey:"navigator.previewAccess") ?? "")
    }
    static func openSettings() {
        NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
    }
}
struct PreviewAccessSetup:View {
    @EnvironmentObject var model:NavigatorModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage("navigator.previewAccess") private var access=""
    @StoredState private var settingsOpened=false
    private func choose(_ choice:String) {access=choice;model.setPreviewAccess(choice != "denied");dismiss()}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("File access for previews").font(.title2.bold())
            Text("Navigator needs permission to read local files so it can show images and other previews. Opening previews stays on this Mac. Tasks you explicitly submit in Composer are processed through Codex.")
            Text("To avoid separate prompts for protected folders, enable Codex Navigator in System Settings → Privacy & Security → Full Disk Access. macOS requires you to grant this there; an app cannot combine those permissions into one Allow popup.").foregroundStyle(.secondary)
            Button("Open Full Disk Access settings…") {PreviewAccess.openSettings();settingsOpened=true}
            if settingsOpened {
                Text("Add or enable this copy of Codex Navigator. macOS may ask you to quit and reopen it.").font(.callout)
                Button("Reveal Navigator to add it") {NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])}
                Button("I’ve enabled access — try previews") {choose("broad")}
            }
            Divider()
            Text("You can instead let macOS ask for individual folders as previews need them.").foregroundStyle(.secondary)
            HStack {
                Button("Not now") {choose("denied")}.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Use folder-by-folder access") {choose("folders")}
            }
        }.padding(24).frame(width:540).background(Color(nsColor:.windowBackgroundColor))
    }
}
struct PreviewAccessNotice:View {
    @EnvironmentObject var model:NavigatorModel
    @AppStorage("navigator.previewAccess") private var access=""
    let denied:Bool
    @StoredState private var setup=false
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            Text(denied ? (PreviewAccess.enabled ? "macOS denied preview access. Navigator needs permission to read these files. Previews stay on this Mac and are not transmitted to us or anyone else." : "File previews are off. Enable file access to view them. Preview files stay on this Mac and are not transmitted to us or anyone else.") : "Enable file access to preview local images and documents. Preview files stay on this Mac.")
                .foregroundStyle(denied ? Color.red : Color.secondary)
            HStack {
                Button("File access…") {setup=true}
                if PreviewAccess.enabled {Button("Retry") {model.setPreviewAccess(true)}}
            }
        }.font(.callout)
        .sheet(isPresented:$setup) {PreviewAccessSetup().environmentObject(model)}
    }
}
