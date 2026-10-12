import CoreGraphics

/// A window as `CGWindowListCopyWindowInfo` reports it. Bounds use CG coordinates (top-left origin).
public struct WindowInfo: Sendable, Equatable {
    public var pid: Int32
    public var layer: Int
    public var bounds: CGRect

    public init(pid: Int32, layer: Int, bounds: CGRect) {
        self.pid = pid
        self.layer = layer
        self.bounds = bounds
    }
}

public enum VideoGeometry {
    public static let aspect: CGFloat = 16.0 / 9.0

    public struct PickedWindow: Sendable, Equatable {
        public var bounds: CGRect
        public var fullScreen: Bool
    }

    /// The TV app's video window: a full-screen window if there is one, else the frontmost window
    /// (`windows` is front to back, as CG lists them). The player sits in front of the library
    /// window, which can be larger and on another screen. Layer 0 only, so the PiP window is
    /// ignored; strips and popovers below 320x180 are too. A full-screen window spans a screen's
    /// width down to its bottom; on a display with a notch it starts below the menu bar area.
    public static func pickVideoWindow(_ windows: [WindowInfo], pid: Int32, screens: [CGRect]) -> PickedWindow? {
        let candidates = windows.filter { $0.pid == pid && $0.layer == 0 && $0.bounds.width >= 320 && $0.bounds.height >= 180 }
        func isFullScreen(_ r: CGRect) -> Bool {
            screens.contains { s in r.minX == s.minX && r.width == s.width && r.maxY == s.maxY && r.height >= s.height - 80 }
        }
        if let full = candidates.first(where: { isFullScreen($0.bounds) }) { return PickedWindow(bounds: full.bounds, fullScreen: true) }
        return candidates.first.map { PickedWindow(bounds: $0.bounds, fullScreen: false) }
    }

    /// A windowed player has the video's own aspect, so the video is the window. In full screen
    /// the video is fit inside the window with the aspect last seen windowed.
    public static func videoRect(window: CGRect, fullScreen: Bool, lastAspect: CGFloat) -> CGRect {
        fullScreen ? videoRect(in: window, aspect: lastAspect) : window
    }

    /// The 16:9 video area, aspect-fit and centered inside `rect`.
    public static func videoRect(in rect: CGRect, aspect: CGFloat = aspect) -> CGRect {
        var size = CGSize(width: rect.width, height: rect.width / aspect)
        if size.height > rect.height { size = CGSize(width: rect.height * aspect, height: rect.height) }
        return CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                      width: size.width, height: size.height)
    }

    /// Converts a CG rect (top-left origin) to Cocoa (bottom-left origin of the primary screen).
    public static func cocoaRect(fromCG r: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
    }

    /// Frames for caption blocks in cue order. `nudge` shifts all of them by a percent of the
    /// video height; blocks that would overlap stack upward, `gap` apart.
    public static func stackFrames(_ blocks: [(CueLayout, CGSize)], video: CGSize, nudge: Double, gap: CGFloat) -> [CGRect] {
        var placed: [CGRect] = []
        for (layout, size) in blocks {
            var frame = cueFrame(layout, size: size, video: video)
            frame.origin.y = min(max(0, frame.origin.y + video.height * nudge / 100), max(0, video.height - size.height))
            while let hit = placed.first(where: { $0.intersects(frame) }) {
                frame.origin.y = hit.minY - frame.height - gap
            }
            placed.append(frame)
        }
        return placed
    }

    /// The frame of a caption block of `size` inside a video of size `video`, top-left origin.
    /// Without settings the block sits centered near the bottom.
    public static func cueFrame(_ layout: CueLayout, size: CGSize, video: CGSize) -> CGRect {
        let px = video.width * (layout.position ?? 50) / 100
        let x = switch layout.positionAnchor {
        case .start: px
        case .center: px - size.width / 2
        case .end: px - size.width
        }
        let y: CGFloat
        if let line = layout.line {
            let ly = video.height * line / 100
            y = switch layout.lineAnchor {
            case .start: ly
            case .center: ly - size.height / 2
            case .end: ly - size.height
            }
        } else {
            y = video.height * 0.9 - size.height
        }
        return CGRect(x: min(max(0, x), max(0, video.width - size.width)),
                      y: min(max(video.height * CaptionStyle.topMargin, y), max(0, video.height - size.height)),
                      width: size.width, height: size.height)
    }
}
