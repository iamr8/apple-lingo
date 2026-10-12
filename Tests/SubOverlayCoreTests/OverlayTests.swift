import CoreGraphics
import Testing
@testable import SubOverlayCore

struct CaptionStyleTests {
    let raw = RawCaptionAppearance(
        fontName: "Helvetica", relativeSize: 1.5,
        text: RGBA(r: 1, g: 1, b: 1, a: 1), textOpacity: 0.8,
        background: RGBA(r: 0, g: 0, b: 0, a: 0.5), backgroundOpacity: 0.5,
        window: RGBA(r: 0, g: 0, b: 0, a: 1), windowOpacity: 0.5, windowCornerRadius: 8,
        edgeStyle: 5)

    // Breaks if opacity is not multiplied into the color alpha.
    @Test func opacityIsFoldedIntoAlpha() {
        let s = CaptionStyle(raw)
        #expect(s.text.a == 0.8)
        #expect(s.background.a == 0.25)
        #expect(s.window.a == 0.5)
    }

    // Breaks if the edge raw values are mapped to the wrong cases.
    @Test func edgeStyleMapping() {
        var r = raw
        #expect(CaptionStyle(r).edge == .dropShadow)
        r.edgeStyle = 0
        #expect(CaptionStyle(r).edge == .none)
        r.edgeStyle = 4
        #expect(CaptionStyle(r).edge == .uniform)
    }

    // Breaks if the relative size is ignored in the font size.
    @Test func fontSizeScalesWithVideoAndRelativeSize() {
        #expect(abs(CaptionStyle(raw).fontSize(videoHeight: 1000) - 45.225) < 1e-9)
    }
}

struct VideoGeometryTests {
    let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    // Breaks if another app's window, a non-zero layer (PiP) or a small strip or popover is picked.
    @Test func picksFrontLayerZeroWindowOfPid() {
        let windows = [
            WindowInfo(pid: 9, layer: 0, bounds: screen),
            WindowInfo(pid: 7, layer: 3, bounds: CGRect(x: 0, y: 0, width: 1900, height: 1000)),
            WindowInfo(pid: 7, layer: 0, bounds: CGRect(x: 0, y: 0, width: 1920, height: 39)),
            WindowInfo(pid: 7, layer: 0, bounds: CGRect(x: 10, y: 10, width: 300, height: 300)),
            WindowInfo(pid: 7, layer: 0, bounds: CGRect(x: 100, y: 100, width: 1200, height: 700)),
            WindowInfo(pid: 7, layer: 0, bounds: CGRect(x: 10, y: 10, width: 400, height: 300)),
        ]
        #expect(VideoGeometry.pickVideoWindow(windows, pid: 7, screens: [screen])?.bounds == CGRect(x: 100, y: 100, width: 1200, height: 700))
    }

    // Breaks if the larger library window wins over the player in front of it, so captions stay
    // on the built-in screen while the player is on an external one. Values from a real setup.
    @Test func playerInFrontWinsOverLargerLibrary() {
        let builtIn = CGRect(x: 0, y: 0, width: 2056, height: 1329)
        let external = CGRect(x: 89, y: -1080, width: 1920, height: 1080)
        let player = CGRect(x: 289, y: -900, width: 1200, height: 600)
        let windows = [
            WindowInfo(pid: 7, layer: 0, bounds: player),
            WindowInfo(pid: 7, layer: 0, bounds: CGRect(x: 68, y: 159, width: 1920, height: 1050)),
        ]
        #expect(VideoGeometry.pickVideoWindow(windows, pid: 7, screens: [builtIn, external]) == .init(bounds: player, fullScreen: false))
    }

    // Breaks if a full-screen window does not win over a larger area rule.
    @Test func fullScreenWindowWins() {
        let other = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        let windows = [
            WindowInfo(pid: 7, layer: 0, bounds: CGRect(x: 1920, y: 30, width: 2500, height: 1400)),
            WindowInfo(pid: 7, layer: 0, bounds: screen),
        ]
        #expect(VideoGeometry.pickVideoWindow(windows, pid: 7, screens: [screen, other]) == .init(bounds: screen, fullScreen: true))
    }

    // Breaks if the aspect fit letterboxes on the wrong axis.
    @Test func videoRectAspectFits() {
        let pillar = VideoGeometry.videoRect(in: CGRect(x: 0, y: 0, width: 2000, height: 900))
        #expect(pillar == CGRect(x: 200, y: 0, width: 1600, height: 900))
        let letter = VideoGeometry.videoRect(in: CGRect(x: 0, y: 0, width: 1600, height: 1000))
        #expect(letter == CGRect(x: 0, y: 50, width: 1600, height: 900))
    }

    // Breaks if the y axis flip uses the window height instead of the primary screen height.
    @Test func cgToCocoaFlip() {
        let r = VideoGeometry.cocoaRect(fromCG: CGRect(x: 10, y: 100, width: 50, height: 200), primaryHeight: 1080)
        #expect(r == CGRect(x: 10, y: 780, width: 50, height: 200))
    }

    // Breaks if `line:85%,start position:50%,middle` is not honored (top at 85%, centered).
    @Test func cueFrameFollowsAppleSettings() {
        let layout = CueLayout(settings: "align:middle line:85%,start position:50%,middle")
        let f = VideoGeometry.cueFrame(layout, size: CGSize(width: 200, height: 40), video: CGSize(width: 1000, height: 500))
        #expect(f == CGRect(x: 400, y: 425, width: 200, height: 40))
    }

    // Breaks if a `line:0%` cue sits at the video's top edge; Apple keeps a 5% margin there.
    @Test func topCueKeepsAppleMargin() {
        let layout = CueLayout(settings: "align:middle line:0%,start position:50%,middle")
        let f = VideoGeometry.cueFrame(layout, size: CGSize(width: 200, height: 40), video: CGSize(width: 1000, height: 500))
        #expect(f == CGRect(x: 400, y: 25, width: 200, height: 40))
    }

    // Breaks if a cue that would leave the video is not pulled back inside.
    @Test func cueFrameStaysInsideVideo() {
        let layout = CueLayout(settings: "line:95%,start position:50%,middle")
        let f = VideoGeometry.cueFrame(layout, size: CGSize(width: 200, height: 60), video: CGSize(width: 1000, height: 500))
        #expect(f.maxY == 500)
    }
}

struct CueSchedulePlanTests {
    let timeline = CueTimeline([Cue(id: 1, start: 10, end: 12, text: "a"), Cue(id: 2, start: 20, end: 22, text: "b")])

    func state(_ elapsed: Double, playing: Bool, rate: Double = 1, at now: ContinuousClock.Instant) -> PlaybackState {
        PlaybackState(title: "t", album: nil, elapsedAtAnchor: elapsed, rate: rate, playing: playing, anchor: now)
    }

    // Breaks if the offset is not added, or the delay ignores the rate.
    @Test func playingArmsTimerAtNextBoundary() {
        let now = ContinuousClock.now
        let plan = CueSchedulePlan(timeline: timeline, state: state(9, playing: true, rate: 2, at: now), offset: 2, now: now)
        #expect(plan.cues.map(\.id) == [1])
        #expect(plan.delay == 0.5)
    }

    // Breaks if a paused state still arms a timer.
    @Test func pausedArmsNoTimer() {
        let now = ContinuousClock.now
        let plan = CueSchedulePlan(timeline: timeline, state: state(11, playing: false, at: now), offset: 0, now: now)
        #expect(plan.cues.map(\.id) == [1])
        #expect(plan.delay == nil)
    }

    // Breaks if a timer is armed after the last cue.
    @Test func noBoundaryAheadArmsNoTimer() {
        let now = ContinuousClock.now
        let plan = CueSchedulePlan(timeline: timeline, state: state(30, playing: true, at: now), offset: 0, now: now)
        #expect(plan.cues.isEmpty)
        #expect(plan.delay == nil)
    }
}

struct CueStackTests {
    let video = CGSize(width: 1000, height: 500)
    let apple = CueLayout(settings: "align:middle line:85%,start position:50%,middle")

    // Breaks if two cues on the same line overlap instead of stacking upward.
    @Test func overlappingCuesStackUpward() {
        let frames = VideoGeometry.stackFrames([(apple, CGSize(width: 200, height: 40)), (apple, CGSize(width: 300, height: 40))],
                                               video: video, nudge: 0, gap: 5)
        #expect(frames[0] == CGRect(x: 400, y: 425, width: 200, height: 40))
        #expect(frames[1] == CGRect(x: 350, y: 380, width: 300, height: 40))
    }

    // Breaks if the nudge is ignored or pushes captions out of the video.
    @Test func nudgeShiftsAndStaysInside() {
        let up = VideoGeometry.stackFrames([(apple, CGSize(width: 200, height: 40))], video: video, nudge: -10, gap: 5)
        #expect(up[0].minY == 375)
        let down = VideoGeometry.stackFrames([(apple, CGSize(width: 200, height: 40))], video: video, nudge: 20, gap: 5)
        #expect(down[0].maxY == 500)
    }
}

struct VideoFrameTests {
    let screen = CGRect(x: 0, y: 0, width: 2056, height: 1329)

    // Breaks if a full-screen window below a notch or menu bar is not seen as full screen.
    @Test func fullScreenBelowNotch() {
        let w = [WindowInfo(pid: 7, layer: 0, bounds: CGRect(x: 0, y: 39, width: 2056, height: 1290))]
        let picked = VideoGeometry.pickVideoWindow(w, pid: 7, screens: [screen])
        #expect(picked?.fullScreen == true)
    }

    // Breaks if a large normal window is taken for full screen.
    @Test func windowedIsNotFullScreen() {
        let w = [WindowInfo(pid: 7, layer: 0, bounds: CGRect(x: 0, y: 168, width: 2056, height: 1028))]
        #expect(VideoGeometry.pickVideoWindow(w, pid: 7, screens: [screen])?.fullScreen == false)
    }

    // Breaks if a windowed player is letterboxed: the TV window has the video's own aspect.
    @Test func windowedVideoIsTheWindow() {
        let window = CGRect(x: 0, y: 168, width: 2056, height: 1028)
        #expect(VideoGeometry.videoRect(window: window, fullScreen: false, lastAspect: 16.0 / 9.0) == window)
    }

    // Breaks if full screen does not fit the last windowed aspect inside the window.
    @Test func fullScreenUsesLastAspect() {
        let window = CGRect(x: 0, y: 39, width: 2056, height: 1290)
        #expect(VideoGeometry.videoRect(window: window, fullScreen: true, lastAspect: 2) == CGRect(x: 0, y: 170, width: 2056, height: 1028))
    }
}
