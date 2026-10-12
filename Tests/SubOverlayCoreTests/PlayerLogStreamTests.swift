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
    static func timebase(_ rate: String, _ time: String) -> String {
        line("<<<< FigPlayerInterstitial >>>> fpic_checkScheduledTransition_block_invoke: 0x7796d2cc00 State logging - timebaseRate \(rate), timebaseTime \(time), timebaseTimeClamped \(time), isClamped 0, ",
             subsystem: "com.apple.coremedia", category: "")
    }

    // Breaks if the player's own clock line is not an event with its rate, time and line time, or
    // if a rate of 0 (pause, seek landing) is lost. Trace of a resume and of a seek landing.
    @Test func parsesTimebaseLines() {
        #expect(PlayerLogStream.parse(line: Self.timebase("1.000000", "1994.528930"))
                == PlayerEvent(kind: .timebase(rate: 1, time: 1994.52893), epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.timebase("0.000000", "1700.613272"))
                == PlayerEvent(kind: .timebase(rate: 0, time: 1700.613272), epochMicros: 1_791_740_571_549_335))
    }

    // Breaks if a clock line with a broken rate or time becomes an anchor.
    @Test func rejectsBrokenTimebaseLines() {
        #expect(PlayerLogStream.parse(line: Self.timebase("nan", "1994.528930")) == nil)
        #expect(PlayerLogStream.parse(line: Self.timebase("1.000000", "inf")) == nil)
        #expect(PlayerLogStream.parse(line: Self.timebase("1.000000", "-5.000000")) == nil)
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

    // Breaks if the wait for Apple's bumper counts as playing: the main player holds its clock
    // through it (71.5 s for 60 s in a trace of a title start) and its clock line at the end
    // re-anchors, so cues must not run on meanwhile.
    @Test func interstitialWaitIsAStop() {
        #expect(PlayerLogStream.parse(line: Self.line(Self.interstitial)) == PlayerEvent(kind: .stopped, epochMicros: 1_791_740_571_549_335))
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
        #expect(kinds == [.timebase(rate: 1, time: 5), .logRestarted, .playing])
    }

    // Breaks if the stream header, the interstitial player's changes, or a broken line become events.
    @Test func ignoresOtherLines() {
        #expect(PlayerLogStream.parse(line: #"Filtering the log data using "process == "TV" AND eventMessage CONTAINS "main player timeControlStatus did change""#) == nil)
        #expect(PlayerLogStream.parse(line: Self.line("AVPlayer <private> interstitial player timeControlStatus did change to AVPlayerTimeControlStatusPlaying.  reasonForWaiting is (null)")) == nil)
        #expect(PlayerLogStream.parse(line: Self.line("AVPlayer rate did change to 1.000000")) == nil)
        #expect(PlayerLogStream.parse(line: Self.line(Self.playing, at: "yesterday")) == nil)
        #expect(PlayerLogStream.parse(line: "{") == nil)
    }
}
