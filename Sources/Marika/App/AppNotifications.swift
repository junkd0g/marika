import AppKit
import MarikaCore
import UserNotifications

extension AppModel {
    func updateDockBadge() {
        let waiting = controllers.values.count { !$0.approvals.isEmpty }
        NSApp.dockTile.badgeLabel = waiting > 0 ? "\(waiting)" : nil
    }

    func notify(title: String, body: String, projectID: UUID, eventID: String) {
        guard !NSApp.isActive, workspace.preferences.taskNotifications ?? true, Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = ["projectID": projectID.uuidString, "eventID": eventID]
            UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
    }
}
