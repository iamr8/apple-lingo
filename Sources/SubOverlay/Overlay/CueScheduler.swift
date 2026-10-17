import AppKit
import SubOverlayCore

/// Shows the cues for the current playback position. Wakes only at cue edges while playing,
/// and polls the TV window frame at 1 Hz only while the overlay is visible.
@MainActor
final class CueScheduler {
    private let view = CaptionView()
    private lazy var panel = OverlayPanel(content: view)
    private var cueTimer: DispatchSourceTimer?
    private var frameTimer: DispatchSourceTimer?
    private var observers: [NSObjectProtocol] = []

    private var state: PlaybackState?
    private(set) var timeline: CueTimeline?
    var rightToLeft: Bool { view.rightToLeft }
    private var videoFrame: CGRect?
    var offset = 0.0 { didSet { render() } }
    var nudge: Double {
        get { view.nudge }
        set { view.nudge = newValue }
    }

    init() {
        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFrame() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFrame() }
        })
        CaptionStyleObserver.start { [weak self] in self?.view.style = CaptionStyle(RawCaptionAppearance.current()) }
    }

    func update(state: PlaybackState?) {
        self.state = state
        refreshFrame()
    }

    func setTimeline(_ timeline: CueTimeline?, rightToLeft: Bool) {
        self.timeline = timeline
        view.rightToLeft = rightToLeft
        render()
    }

    private func refreshFrame() {
        if let pid = state?.processID ?? tvProcessID() {
            videoFrame = WindowTracker.videoFrame(pid: pid)
        } else {
            videoFrame = nil
        }
        render()
    }

    private func render() {
        cueTimer?.cancel()
        cueTimer = nil
        guard let state, state.playing, let timeline, let videoFrame else {
            hide()
            return
        }
        let plan = CueSchedulePlan(timeline: timeline, state: state, offset: offset, now: .now)
        view.cues = plan.cues
        if plan.cues.isEmpty {
            hide()
        } else {
            if panel.frame != videoFrame { panel.setFrame(videoFrame, display: false) }
            if !panel.isVisible { panel.orderFrontRegardless() }
            startFrameTimer()
        }
        if let delay = plan.delay {
            let timer = DispatchSource.makeTimerSource(queue: .main)
            timer.schedule(deadline: .now() + delay, leeway: .milliseconds(10))
            timer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.render() } }
            timer.resume()
            cueTimer = timer
        }
    }

    private func hide() {
        if panel.isVisible { panel.orderOut(nil) }
        frameTimer?.cancel()
        frameTimer = nil
    }

    private func startFrameTimer() {
        guard frameTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(300))
        timer.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let pid = self.state?.processID ?? self.tvProcessID() else { return }
                let frame = WindowTracker.videoFrame(pid: pid)
                if frame != self.videoFrame {
                    self.videoFrame = frame
                    self.render()
                }
            }
        }
        timer.resume()
        frameTimer = timer
    }

    private func tvProcessID() -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: NowPlayingMerger.tvBundleID).first?.processIdentifier
    }
}

/// Re-reads caption settings when the user changes them in System Settings.
@MainActor
enum CaptionStyleObserver {
    private static var onChange: (@MainActor () -> Void)?

    static func start(_ handler: @escaping @MainActor () -> Void) {
        onChange = handler
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(), nil,
            { _, _, _, _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { CaptionStyleObserver.onChange?() } } },
            RawCaptionAppearance.changedNotification as CFString, nil, .deliverImmediately)
    }
}
