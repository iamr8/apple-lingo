import Foundation
import Testing
@testable import SubOverlayCore

struct PlayerLogStreamTests {
    static func line(_ message: String, at timestamp: String = "2026-10-11 20:42:51.549335+0300",
                     subsystem: String = "com.apple.AppleTV.playback", category: String = "TVPPlayer") -> String {
        #"{"timestamp":"\#(timestamp)","machTimestamp":2764092759015,"processID":48004,"subsystem":"\#(subsystem)","category":"\#(category)","messageType":"Default","eventMessage":"\#(message)"}"#
    }

    static let waiting = "AVPlayer <private> main player timeControlStatus did change to AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate.  reasonForWaiting is AVPlayerWaitingToMinimizeStallsReason"
    static let playing = "AVPlayer <private> main player timeControlStatus did change to AVPlayerTimeControlStatusPlaying.  reasonForWaiting is (null)"
    static let paused = "AVPlayer <private> main player timeControlStatus did change to AVPlayerTimeControlStatusPaused.  reasonForWaiting is (null)"

    static let interstitial = "AVPlayer <private> main player timeControlStatus did change to AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate.  reasonForWaiting is AVPlayerWaitingDuringInterstitialEventReason"

    /// The coremedia line with the main player's clock, as the TV app logs it at every rate change.
    static func timebase(_ rate: String, _ time: String, clamped: String? = nil) -> String {
        line("<<<< FigPlayerInterstitial >>>> fpic_checkScheduledTransition_block_invoke: 0x7796d2cc00 State logging - timebaseRate \(rate), timebaseTime \(time), timebaseTimeClamped \(clamped ?? time), isClamped 0, ",
             subsystem: "com.apple.coremedia", category: "")
    }

    /// The stitched timeline's seek line; its target is in Now Playing's timeline.
    static func seek(_ target: String, from: String) -> String {
        line("<<<< FigItemIntegratedTimeline >>>> fiit_SeekToTimeWithOptions: 0x7a869adc00: dispatching seek to target time \(target) from \(from), source time 0.002, source segment [I] 2000-01-01 00:00:00.000",
             subsystem: "com.apple.coremedia", category: "")
    }

    // Breaks if a seek line is not an event with its target. A Skip press is such a seek, and the
    // TV app wrote no Now Playing position after two of four skips (WhatsHerName, 2026-10-13).
    @Test func parsesSeekLines() {
        #expect(PlayerLogStream.parse(line: Self.seek("39.081", from: "12.575"))
                == PlayerEvent(kind: .seek(target: 39.081), epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.seek("0", from: "125.65"))
                == PlayerEvent(kind: .seek(target: 0), epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.seek("nan", from: "12.575")) == nil)
    }

    // Breaks if the player's own clock line is not an event with its rate, time, clamped time and
    // line time, or if a rate of 0 (pause, seek landing) is lost. Trace of a resume, of a seek
    // landing, and of a content start (the clock 0.23 s before the item's first frame).
    @Test func parsesTimebaseLines() {
        #expect(PlayerLogStream.parse(line: Self.timebase("1.000000", "1994.528930"))
                == PlayerEvent(kind: .timebase(rate: 1, time: 1994.52893, clamped: 1994.52893), epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.timebase("0.000000", "1700.613272"))
                == PlayerEvent(kind: .timebase(rate: 0, time: 1700.613272, clamped: 1700.613272), epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.timebase("1.000000", "86.376823", clamped: "86.610000"))
                == PlayerEvent(kind: .timebase(rate: 1, time: 86.376823, clamped: 86.61), epochMicros: 1_791_740_571_549_335))
    }

    // Breaks if a clock line with a broken rate or time becomes an anchor.
    @Test func rejectsBrokenTimebaseLines() {
        #expect(PlayerLogStream.parse(line: Self.timebase("nan", "1994.528930")) == nil)
        #expect(PlayerLogStream.parse(line: Self.timebase("1.000000", "inf")) == nil)
        #expect(PlayerLogStream.parse(line: Self.timebase("1.000000", "-5.000000")) == nil)
        #expect(PlayerLogStream.parse(line: Self.timebase("1.000000", "5.000000", clamped: "nan")) == nil)
        #expect(PlayerLogStream.parse(line: Self.line("State logging - timebaseRate 1.000000, timebaseTime 5.000000, ", subsystem: "com.apple.coremedia", category: "")) == nil)
    }

    // Breaks if a wait or a pause is not a stop, if playing is not playing, or if the line's own
    // time (with its zone and microseconds) is not the event time. 20:42:51.549335+0300 is
    // 17:42:51.549335 UTC.
    @Test func parsesPlayerStateLines() {
        #expect(PlayerLogStream.parse(line: Self.line(Self.waiting)) == PlayerEvent(kind: .stopped, epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.line(Self.paused)) == PlayerEvent(kind: .stopped, epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.line(Self.playing, at: "2026-10-11 21:57:25.752000+0300"))
                == PlayerEvent(kind: .playing, epochMicros: 1_791_745_045_752_000))
    }

    // Breaks if the wait for Apple's intro, recap or bumper is a plain stop or a play: the main
    // player parks (at 55.4 s for 55 s in a trace of a title start) while Now Playing's clock
    // runs through the recap on the subtitles' timeline, so the merger must know which wait it is.
    @Test func interstitialWaitIsItsOwnEvent() {
        #expect(PlayerLogStream.parse(line: Self.line(Self.interstitial)) == PlayerEvent(kind: .interstitial, epochMicros: 1_791_740_571_549_335))
    }

    // Breaks if a restart of `log stream` does not reach the merger as an event between the
    // lines before and after it.
    @Test func restartBecomesAnEvent() async {
        let outputs = AsyncStream<LineProcess.Output> { c in
            c.yield(.line(Self.timebase("1.000000", "5.000000")))
            c.yield(.restarted)
            c.yield(.line(Self.line(Self.playing)))
            c.finish()
        }
        var kinds: [PlayerEvent.Kind] = []
        for await event in PlayerLogStream.events(from: outputs) { kinds.append(event.kind) }
        #expect(kinds == [.timebase(rate: 1, time: 5, clamped: 5), .logRestarted, .playing])
    }

    static let otherPlaying = "AVPlayer <private> interstitial player timeControlStatus did change to AVPlayerTimeControlStatusPlaying.  reasonForWaiting is (null)"
    static let otherWaiting = "AVPlayer <private> interstitial player timeControlStatus did change to AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate.  reasonForWaiting is AVPlayerWaitingWhileEvaluatingBufferingRateReason"
    static let otherPaused = "AVPlayer <private> interstitial player timeControlStatus did change to AVPlayerTimeControlStatusPaused.  reasonForWaiting is (null)"

    // Breaks if the other player's state lines are not events of their own: after a Skip press
    // its next item buffers 0.1 to 0.65 s before its Playing line (4 skips, WhatsHerName,
    // 2026-10-13), and the main player's lines say nothing about it.
    @Test func otherPlayerLinesAreTheirOwnEvents() {
        #expect(PlayerLogStream.parse(line: Self.line(Self.otherPlaying)) == PlayerEvent(kind: .otherPlaying, epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.line(Self.otherWaiting)) == PlayerEvent(kind: .otherStopped, epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.line(Self.otherPaused)) == PlayerEvent(kind: .otherStopped, epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.line(Self.playing)) == PlayerEvent(kind: .playing, epochMicros: 1_791_740_571_549_335))
    }

    // Breaks if the stream header, another player line, or a broken line become events.
    @Test func ignoresOtherLines() {
        #expect(PlayerLogStream.parse(line: #"Filtering the log data using "process == "TV" AND eventMessage CONTAINS "main player timeControlStatus did change""#) == nil)
        #expect(PlayerLogStream.parse(line: Self.line("After becoming ready to play, main player timeControlStatus is AVPlayerTimeControlStatusPaused")) == nil)
        #expect(PlayerLogStream.parse(line: Self.line("AVPlayer rate did change to 1.000000")) == nil)
        #expect(PlayerLogStream.parse(line: Self.line(Self.playing, at: "yesterday")) == nil)
        #expect(PlayerLogStream.parse(line: "{") == nil)
    }
}
