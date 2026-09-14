import AppKit
import SwiftUI

/// One appearance owner for the application and SwiftUI, including full-screen
/// windows and sheets. Rapid requests coalesce instead of applying stale values.
final class AppAppearance:ObservableObject {
    static let shared=AppAppearance()
    @Published private(set) var scheme:ColorScheme = systemIsDark ? .dark : .light
    private(set) var theme="System"
    private var pending:DispatchWorkItem?
    private var observers:[NSObjectProtocol]=[]
    static var systemIsDark:Bool {
        (UserDefaults.standard.persistentDomain(forName:UserDefaults.globalDomain)?["AppleInterfaceStyle"] as? String) == "Dark"
    }
    private init() {
        observers.append(DistributedNotificationCenter.default().addObserver(forName:NSNotification.Name("AppleInterfaceThemeChangedNotification"),object:nil,queue:.main) { [weak self] _ in self?.schedule() })
        for name in [NSWindow.didEnterFullScreenNotification,NSWindow.didExitFullScreenNotification,NSWindow.didBecomeKeyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in self?.schedule() })
        }
    }
    func setTheme(_ value:String) {
        theme=["System","Light","Dark"].contains(value) ? value : "System"
        schedule()
    }
    private func schedule() {
        pending?.cancel()
        let work=DispatchWorkItem { [weak self] in self?.apply() }
        pending=work
        DispatchQueue.main.async(execute:work)
    }
    private func apply() {
        let name:NSAppearance.Name? = theme == "System" ? nil : theme == "Dark" ? .darkAqua : .aqua
        if NSApp.appearance?.name != name {NSApp.appearance=name.flatMap {NSAppearance(named:$0)}}
        for window in NSApp.windows where window.appearance != nil {window.appearance=nil}
        let next:ColorScheme = theme == "Dark" || (theme == "System" && Self.systemIsDark) ? .dark : .light
        if scheme != next {scheme=next}
    }
}
