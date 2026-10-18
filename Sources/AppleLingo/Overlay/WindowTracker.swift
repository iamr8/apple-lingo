import AppKit
import AppleLingoCore

/// Finds the TV app's video area on screen. Uses window bounds only, so no permission is needed.
@MainActor
enum WindowTracker {
    /// The video aspect seen while windowed, used in full screen. 16:9 until a window is seen.
    private static var lastAspect: CGFloat = VideoGeometry.aspect

    /// The video rect in Cocoa screen coordinates, or nil when no TV window is on screen.
    static func videoFrame(pid: Int32) -> CGRect? {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let windows: [WindowInfo] = list.compactMap { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? Int32, owner == pid,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict)
            else { return nil }
            return WindowInfo(pid: owner, layer: layer, bounds: bounds, number: info[kCGWindowNumber as String] as? Int ?? 0)
        }
        let height = primary.frame.height
        let screens = NSScreen.screens.map { s in
            CGRect(x: s.frame.minX, y: height - s.frame.maxY, width: s.frame.width, height: s.frame.height)
        }
        guard let picked = VideoGeometry.pickVideoWindow(windows, pid: pid, screens: screens) else { return nil }
        if !picked.fullScreen, picked.bounds.height > 0 { lastAspect = picked.bounds.width / picked.bounds.height }
        let video = VideoGeometry.videoRect(window: picked.bounds, fullScreen: picked.fullScreen, lastAspect: lastAspect)
        return VideoGeometry.cocoaRect(fromCG: video, primaryHeight: height)
    }
}
