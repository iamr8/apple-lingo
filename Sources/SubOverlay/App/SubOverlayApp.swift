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

}
