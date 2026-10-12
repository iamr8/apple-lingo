import AppKit
import SwiftUI

/// Brings a window above other apps on the current desktop. `NSApp.activate()` alone is only a
/// request since macOS 14, and a window otherwise stays on the desktop (Space) it first opened on,
/// so it can open behind the active app or on another desktop, also when the TV app is full screen.
@MainActor
func bringToFront(_ window: NSWindow) {
    window.collectionBehavior.insert([.moveToActiveSpace, .fullScreenAuxiliary])
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
}

/// Brings the SwiftUI Settings window to the front. Called on every appearance, because the
/// window is reused when Settings opens again.
@MainActor
func bringSettingsToFront() {
    DispatchQueue.main.async {
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue == "com_apple_SwiftUI_Settings_window" }) {
            bringToFront(window)
        }
    }
}
