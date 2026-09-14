import AppKit
import UserNotifications

/// State changes only: streaming output and index refreshes never repeat alerts.
final class AttentionNotifications:NSObject,UNUserNotificationCenterDelegate {
    static let shared=AttentionNotifications()
    private var waiting:Set<String>=[]
    private var requested=false
    func update(tasks:[ComposerTask]) {
        guard !CommandLine.arguments.contains("--demo") else {return}
        let current=Set(tasks.filter {$0.needsInput || $0.status == "failed"}.map(\.id))
        let arrivals=current.subtracting(waiting)
        waiting=current
        guard !arrivals.isEmpty else {return}
        let center=UNUserNotificationCenter.current()
        center.delegate=self
        let notices=tasks.filter {arrivals.contains($0.id)}
        let deliver = {
            for task in notices {
                let content=UNMutableNotificationContent()
                content.title=task.status == "failed" ? "Task failed" : "Codex needs your attention"
                content.body=task.title
                content.sound = .default
                center.add(UNNotificationRequest(identifier:"navigator-attention-"+task.id,content:content,trigger:nil))
            }
        }
        NSApp.requestUserAttention(.informationalRequest)
        if !requested {
            requested=true
            center.requestAuthorization(options:[.alert,.sound,.badge]) {granted,_ in if granted {deliver()} }
        } else {deliver()}
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,willPresent notification:UNNotification,withCompletionHandler completionHandler:@escaping (UNNotificationPresentationOptions)->Void) {
        completionHandler([.banner,.sound])
    }
    func userNotificationCenter(_ center:UNUserNotificationCenter,didReceive response:UNNotificationResponse,withCompletionHandler completionHandler:@escaping ()->Void) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps:true)
            NotificationCenter.default.post(name:Notification.Name("NavigatorAttentionSelected"),object:String(response.notification.request.identifier.dropFirst("navigator-attention-".count)))
        }
        completionHandler()
    }
}
