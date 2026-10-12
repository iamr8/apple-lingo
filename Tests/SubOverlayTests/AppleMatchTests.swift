import AppKit
import Testing
@testable import SubOverlay
@testable import SubOverlayCore

/// Compares our caption ink with Apple's own captions, measured from screenshots of Black Bird
/// "Pilot" in a 2056×1028 pt TV window (2× display, default caption settings, cue settings
/// `align:middle line:85%,start position:50%,middle`). Values are points from the video's top-left.
@MainActor
struct AppleMatchTests {
    struct Ink: Equatable {
        var minX, maxX: CGFloat
        var lines: [ClosedRange<CGFloat>]
    }

    static let video = CGSize(width: 2056, height: 1028)
    static let settings = "align:middle line:85%,start position:50%,middle"

    /// Renders cues at 2× on black and returns the bright-ink box and line bands, in points.
    func ink(_ cues: [Cue]) -> Ink {
        let view = CaptionView(frame: CGRect(origin: .zero, size: Self.video))
        view.style = SnapshotTests.appleDefault
        view.cues = cues
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(Self.video.width) * 2, pixelsHigh: Int(Self.video.height) * 2,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        rep.size = Self.video
        NSGraphicsContext.saveGraphicsState()
        let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
        // Flip so the view's top-left origin matches the image rows, and tell AppKit so text is upright.
        cg.translateBy(x: 0, y: Self.video.height)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        NSColor.black.setFill()
        CGRect(origin: .zero, size: Self.video).fill()
        view.draw(view.bounds)
        NSGraphicsContext.restoreGraphicsState()

        var minX = Int.max, maxX = -1
        var rows = Set<Int>()
        let data = rep.bitmapData!
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                let p = data + y * rep.bytesPerRow + x * 4
                if p[0] > 191 && p[1] > 191 && p[2] > 191 {
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    rows.insert(y)
                }
            }
        }
        var lines: [ClosedRange<CGFloat>] = []
        var start: Int?
        for y in 0...rep.pixelsHigh {
            let on = rows.contains(y)
            if on, start == nil { start = y }
            if !on, let s = start {
                lines.append(CGFloat(s) / 2...CGFloat(y - 1) / 2)
                start = nil
            }
        }
        return Ink(minX: CGFloat(minX) / 2, maxX: CGFloat(maxX) / 2, lines: lines)
    }

    func expectClose(_ a: CGFloat, _ b: CGFloat, _ what: String, tolerance: CGFloat = 1.5) {
        #expect(abs(a - b) <= tolerance, "\(what): ours \(a), Apple \(b)")
    }

    // Breaks if the font size, weight, italic, centering or line position differ from Apple's.
    @Test func singleLineMatchesApple() {
        let ink = ink([Cue(id: 1, start: 0, end: 1, text: "Like, for fucking ever.", settings: Self.settings, italic: true)])
        expectClose(ink.minX, 879.5, "1-line left")
        expectClose(ink.maxX, 1171, "1-line right")
        #expect(ink.lines.count == 1)
        expectClose(ink.lines[0].lowerBound, 883.5, "1-line top")
        expectClose(ink.lines[0].upperBound, 911, "1-line bottom")
    }

    // Breaks if a top cue (`line:0%`) ignores Apple's top margin. Apple's ink measured from a
    // screen image of Pilot at 2:25, scaled by our own ink width (1.86 px/pt): top 61.3, bottom 83.3.
    @Test func topLineMatchesApple() {
        let ink = ink([Cue(id: 1, start: 0, end: 1, text: "And this is the life I knew.",
                           settings: "align:middle line:0%,start position:50%,middle", italic: true)])
        #expect(ink.lines.count == 1)
        expectClose(ink.lines[0].lowerBound, 61.3, "top line top")
        expectClose(ink.lines[0].upperBound, 83.3, "top line bottom")
    }

    // Breaks if the line spacing of two-line cues differs from Apple's.
    @Test func twoLinesMatchApple() {
        let ink = ink([Cue(id: 1, start: 0, end: 1, text: "here's where it all started to go sideways\nfor me.",
                           settings: Self.settings, italic: true)])
        expectClose(ink.minX, 746, "2-line left")
        expectClose(ink.maxX, 1306.5, "2-line right")
        #expect(ink.lines.count == 2)
        expectClose(ink.lines[0].lowerBound, 883.5, "line 1 top")
        expectClose(ink.lines[1].lowerBound, 928.5, "line 2 top")
        expectClose(ink.lines[1].upperBound, 950, "line 2 bottom")
    }
}
