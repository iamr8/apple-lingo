import Foundation
import UserNotifications

/// Posts user notifications. A click opens the Add Subtitles window for the title.
enum Notifier {
    static let titleKey = "title"
    static let albumKey = "album"

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    static func post(_ heading: String, _ body: String, _ title: String, _ album: String?) {
        let content = UNMutableNotificationContent()
        content.title = heading
        content.body = body
        content.userInfo = [titleKey: title, albumKey: album ?? ""]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
