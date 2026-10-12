import Foundation
import Testing
@testable import SubOverlayCore

struct PlayerLogStreamTests {
    static func line(_ message: String, at timestamp: String = "2026-10-11 20:42:51.549335+0300") -> String {
        #"{"timestamp":"\#(timestamp)","machTimestamp":2764092759015,"processID":48004,"subsystem":"com.apple.AppleTV.playback","category":"TVPPlayer","messageType":"Default","eventMessage":"\#(message)"}"#
    }

    static let waiting = "AVPlayer <private> main player timeControlStatus did change to AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate.  reasonForWaiting is AVPlayerWaitingToMinimizeStallsReason"
    static let playing = "AVPlayer <private> main player timeControlStatus did change to AVPlayerTimeControlStatusPlaying.  reasonForWaiting is (null)"
    static let paused = "AVPlayer <private> main player timeControlStatus did change to AVPlayerTimeControlStatusPaused.  reasonForWaiting is (null)"

    static let interstitial = "AVPlayer <private> main player timeControlStatus did change to AVPlayerTimeControlStatusWaitingToPlayAtSpecifiedRate.  reasonForWaiting is AVPlayerWaitingDuringInterstitialEventReason"

    // Breaks if a wait or a pause is not a stop, if playing is not playing, or if the line's own
    // time (with its zone and microseconds) is not the event time. 20:42:51.549335+0300 is
    // 17:42:51.549335 UTC.
    @Test func parsesPlayerStateLines() {
        #expect(PlayerLogStream.parse(line: Self.line(Self.waiting)) == PlayerEvent(kind: .stopped, epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.line(Self.paused)) == PlayerEvent(kind: .stopped, epochMicros: 1_791_740_571_549_335))
        #expect(PlayerLogStream.parse(line: Self.line(Self.playing, at: "2026-10-11 21:57:25.752000+0300"))
                == PlayerEvent(kind: .playing, epochMicros: 1_791_745_045_752_000))
    }

    // Breaks if the wait for Apple's intro or recap counts as a stall: the main player waits
    // 70 s while Now Playing's clock runs through the interstitial (trace of a title start).
    @Test func interstitialWaitIsPlaying() {
        #expect(PlayerLogStream.parse(line: Self.line(Self.interstitial)) == PlayerEvent(kind: .playing, epochMicros: 1_791_740_571_549_335))
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
