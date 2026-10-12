import AppKit
import SwiftUI
import UserNotifications

@main
struct SubOverlayApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("SubOverlay", systemImage: "captions.bubble") {
            MenuContent(model: delegate.model)
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(model: delegate.model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        UNUserNotificationCenter.current().delegate = self
        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo
        guard let title = info[Notifier.titleKey] as? String else { return }
        let album = info[Notifier.albumKey] as? String
        await MainActor.run { model.showAddSubtitles(title: title, album: album) }
    }
}
