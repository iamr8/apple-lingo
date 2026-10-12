import Foundation
import Testing
@testable import SubOverlayCore

struct LineSplitterTests {
    // Breaks if partial lines are emitted before their newline.
    @Test func joinsChunksAcrossReads() {
        var s = BoundedLineSplitter(maxLength: 100)
        #expect(s.feed(Data("ab".utf8)) == [])
        #expect(s.feed(Data("c\nde\nf".utf8)) == ["abc", "de"])
        #expect(s.feed(Data("\n".utf8)) == ["f"])
    }

    // Breaks if an over-long line is kept, or if the line after it is lost.
    @Test func dropsOverlongLineAndRecovers() {
        var s = BoundedLineSplitter(maxLength: 4)
        #expect(s.feed(Data("123456".utf8)) == [])
        #expect(s.feed(Data("78\nok\n".utf8)) == ["ok"])
    }
}

struct NowPlayingMergerTests {
    let anchor = ContinuousClock.now
    let epochNow: Int64 = 1_000_000_000_000_000

    func line(_ diff: Bool, _ payload: String) -> String {
        #"{"type":"data","diff":\#(diff),"payload":\#(payload)}"#
    }

    // Breaks if a diff replaces instead of merging, or if null does not delete.
    @Test func diffMergesAndNullDeletes() throws {
        var m = NowPlayingMerger()
        try m.apply(line: line(false, #"{"bundleIdentifier":"com.apple.TV","title":"Pilot","album":"Black Bird","playing":true}"#))
        try m.apply(line: line(true, #"{"title":"Hand to Mouth","album":null}"#))
        #expect(m.payload["title"] == .string("Hand to Mouth"))
        #expect(m.payload["album"] == nil)
        #expect(m.payload["bundleIdentifier"] == .string("com.apple.TV"))
    }

    // Breaks if a non-diff payload keeps keys from the old state.
    @Test func fullPayloadReplaces() throws {
        var m = NowPlayingMerger()
        try m.apply(line: line(false, #"{"bundleIdentifier":"com.apple.TV","title":"A","album":"X","playing":true}"#))
        try m.apply(line: line(false, #"{"bundleIdentifier":"com.apple.TV","title":"B","playing":true}"#))
        #expect(m.payload["album"] == nil)
    }

    // Breaks if the age between the sample and receipt is not added while playing.
    @Test func stateAddsSampleAgeWhilePlaying() throws {
        var m = NowPlayingMerger()
        let sampled = epochNow - 2_000_000
        try m.apply(line: line(false, #"{"bundleIdentifier":"com.apple.TV","title":"T","playing":true,"playbackRate":1,"elapsedTimeMicros":10000000,"timestampEpochMicros":\#(sampled)}"#))
        let s = try #require(m.state(receivedAt: anchor, epochMicrosNow: epochNow))
        #expect(abs(s.elapsedAtAnchor - 12) < 1e-9)
        #expect(s.playing)
    }

    // Breaks if a paused state still adds the sample age (TV reports rate 1 while paused).
    @Test func pausedStateIgnoresSampleAge() throws {
        var m = NowPlayingMerger()
        let sampled = epochNow - 2_000_000
        try m.apply(line: line(false, #"{"bundleIdentifier":"com.apple.TV","title":"T","playing":false,"playbackRate":1,"elapsedTimeMicros":10000000,"timestampEpochMicros":\#(sampled)}"#))
        let s = try #require(m.state(receivedAt: anchor, epochMicrosNow: epochNow))
        #expect(s.elapsedAtAnchor == 10)
    }

    func report(_ playing: Bool, _ elapsed: Int, _ sampled: Int64) -> String {
        line(true, #"{"bundleIdentifier":"com.apple.TV","title":"T","playing":\#(playing),"playbackRate":1,"elapsedTimeMicros":\#(elapsed * 1_000_000),"timestampEpochMicros":\#(sampled)}"#)
    }

    // Breaks if the clock moves at once after a seek, or a diff without a new report ends the
    // wait. The TV app reports the new position, buffers 1-2.7 s (measured), and reports nothing
    // more, so the clock waits 1.5 s.
    @Test func seekHoldsClock() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(true, 100, epochNow - 10_000_000))
        try m.apply(line: report(true, 1800, epochNow))
        let s = try #require(m.state(receivedAt: anchor, epochMicrosNow: epochNow))
        #expect(s.position(at: anchor + .seconds(1)) == 1800)
        #expect(abs(s.position(at: anchor + .seconds(2.5)) - 1801) < 1e-6)
        try m.apply(line: line(true, #"{"album":"X"}"#))
        let later = try #require(m.state(receivedAt: anchor + .seconds(0.5), epochMicrosNow: epochNow + 500_000))
        #expect(later.position(at: anchor + .seconds(1)) == 1800)
    }

    // Breaks if the TV app's own follow-up report during the wait (a play command 0.5 s after
    // the seek reports 1800.5, its projection) ends the wait or becomes the anchor; it already
    // holds 0.5 s of the stall. Trace from a real seek while playing.
    @Test func followUpReportKeepsHold() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(true, 100, epochNow - 10_000_000))
        try m.apply(line: report(true, 1800, epochNow))
        try m.apply(line: line(true, #"{"elapsedTimeMicros":1800500000,"timestampEpochMicros":\#(epochNow + 500_000)}"#))
        let s = try #require(m.state(receivedAt: anchor + .seconds(0.5), epochMicrosNow: epochNow + 500_000))
        #expect(s.position(at: anchor + .seconds(1)) == 1800)
        #expect(abs(s.position(at: anchor + .seconds(2.5)) - 1801) < 1e-6)
    }

    // Breaks if a resume from pause (no jump) waits too; the player starts in about 0.1 s.
    @Test func resumeDoesNotHold() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(false, 500, epochNow - 10_000_000))
        try m.apply(line: report(true, 500, epochNow))
        let s = try #require(m.state(receivedAt: anchor, epochMicrosNow: epochNow))
        #expect(abs(s.position(at: anchor + .seconds(1)) - 501) < 1e-6)
    }

    // Breaks if the "playing" diff sent alone on play counts the paused time from the old
    // report (moving the clock 154 s), or makes the next report look like a seek and hold the
    // clock, or if a plain pause counts as a seek made while paused. Real trace of a pause, then
    // a resume after 154 s.
    @Test func resumeAfterLongPauseDoesNotHold() throws {
        var m = NowPlayingMerger()
        try m.apply(line: line(false, #"{"bundleIdentifier":"com.apple.TV","title":"T","playing":true,"playbackRate":1,"elapsedTimeMicros":2510121827,"timestampEpochMicros":\#(epochNow - 158_690_027)}"#))
        try m.apply(line: line(true, #"{"playing":false}"#))
        try m.apply(line: line(true, #"{"timestampEpochMicros":\#(epochNow - 154_690_027),"elapsedTimeMicros":2514000243}"#))
        try m.apply(line: line(true, #"{"playing":true}"#))
        let first = try #require(m.state(receivedAt: anchor, epochMicrosNow: epochNow - 4_000))
        #expect(abs(first.position(at: anchor) - 2514) < 0.01)
        try m.apply(line: line(true, #"{"timestampEpochMicros":\#(epochNow),"elapsedTimeMicros":2514121827}"#))
        let s = try #require(m.state(receivedAt: anchor, epochMicrosNow: epochNow))
        #expect(abs(s.position(at: anchor + .seconds(1)) - 2515.121827) < 1e-6)
    }

    // Breaks if a seek made while paused is forgotten on play: the player buffers 2-2.9 s
    // (measured) after play, like a seek while playing.
    @Test func seekWhilePausedHoldsOnPlay() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(false, 500, epochNow - 10_000_000))
        try m.apply(line: report(false, 1800, epochNow - 5_000_000))
        try m.apply(line: line(true, #"{"playing":true}"#))
        try m.apply(line: report(true, 1800, epochNow))
        let s = try #require(m.state(receivedAt: anchor, epochMicrosNow: epochNow))
        #expect(s.position(at: anchor + .seconds(1)) == 1800)
        #expect(abs(s.position(at: anchor + .seconds(2.5)) - 1801) < 1e-6)
    }

    // Breaks if a pause after a seek counts as a seek while paused, so the resume waits too: the
    // pause report sits the stall behind the seek report's projection, so the wait must be
    // counted in. Real trace: seek while paused, play 30 s, pause; then a resume 5 s later.
    @Test func pauseAfterSeekDoesNotHoldResume() throws {
        var m = NowPlayingMerger()
        let t = epochNow - 35_000_000
        try m.apply(line: line(false, #"{"bundleIdentifier":"com.apple.TV","title":"T","playing":false,"playbackRate":1,"elapsedTimeMicros":2584000117,"timestampEpochMicros":\#(t - 6_082_415)}"#))
        try m.apply(line: line(true, #"{"timestampEpochMicros":\#(t - 2_516_594),"elapsedTimeMicros":1800000000}"#))
        try m.apply(line: line(true, #"{"playing":true}"#))
        try m.apply(line: line(true, #"{"timestampEpochMicros":\#(t),"elapsedTimeMicros":1800341800}"#))
        try m.apply(line: line(true, #"{"timestampEpochMicros":\#(t + 622_102),"elapsedTimeMicros":1800963900}"#))
        try m.apply(line: line(true, #"{"playing":false}"#))
        try m.apply(line: line(true, #"{"timestampEpochMicros":\#(t + 30_009_885),"elapsedTimeMicros":1829000106}"#))
        try m.apply(line: line(true, #"{"playing":true}"#))
        try m.apply(line: line(true, #"{"timestampEpochMicros":\#(epochNow),"elapsedTimeMicros":1829100000}"#))
        let s = try #require(m.state(receivedAt: anchor, epochMicrosNow: epochNow))
        #expect(abs(s.position(at: anchor + .seconds(1)) - 1830.1) < 1e-6)
    }

    func event(_ kind: PlayerEvent.Kind, _ micros: Int64) -> PlayerEvent {
        PlayerEvent(kind: kind, epochMicros: Double(micros))
    }

    // Breaks if the clock does not stand still from the seek report until the log says the
    // player moves, or moves then from the wrong point, or if the overlay hides during the wait.
    // Real trace: seek to 658.7 s, log Paused 0.33 s before the report, Playing 4.07 s after it.
    @Test func seekWaitEndsWithPlayerEvent() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(true, 100, epochNow - 10_000_000))
        m.apply(event: event(.stopped, epochNow - 332_000))
        try m.apply(line: report(true, 1800, epochNow))
        let waiting = try #require(m.state(receivedAt: anchor + .seconds(3), epochMicrosNow: epochNow + 3_000_000))
        #expect(waiting.playing)
        #expect(waiting.position(at: anchor + .seconds(4)) == 1800)
        m.apply(event: event(.playing, epochNow + 4_067_000))
        let moving = try #require(m.state(receivedAt: anchor + .seconds(4.067), epochMicrosNow: epochNow + 4_067_000))
        #expect(abs(moving.position(at: anchor + .seconds(5.067)) - 1801) < 1e-6)
    }

    // Breaks if a log line that lands after the seek report (the log is slower than the adapter)
    // is not counted from its own time.
    @Test func playerEventAfterReportCountsFromItsOwnTime() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(true, 100, epochNow - 10_000_000))
        try m.apply(line: report(true, 1800, epochNow))
        m.apply(event: event(.stopped, epochNow - 332_000))
        m.apply(event: event(.playing, epochNow + 4_067_000))
        let s = try #require(m.state(receivedAt: anchor + .seconds(4.5), epochMicrosNow: epochNow + 4_500_000))
        #expect(abs(s.position(at: anchor + .seconds(4.5)) - 1800.433) < 1e-6)
    }

    // Breaks if the first log event, a Playing after a seek held by the fallback, is read as the
    // end of a stall that no log line started: that seek keeps the 1.5 s hold.
    @Test func firstPlayingEventKeepsFallbackHold() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(true, 100, epochNow - 10_000_000))
        try m.apply(line: report(true, 1800, epochNow))
        m.apply(event: event(.playing, epochNow + 4_067_000))
        let s = try #require(m.state(receivedAt: anchor, epochMicrosNow: epochNow + 4_067_000))
        #expect(abs(s.position(at: anchor) - 1802.567) < 1e-6)
    }

    // Breaks if a seek report with the log alive starts a stall by itself: no log line would
    // end it, and the overlay would stand still until the next pause.
    @Test func jumpReportWithoutStopEventRunsClock() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(true, 100, epochNow - 10_000_000))
        m.apply(event: event(.stopped, epochNow - 8_000_000))
        m.apply(event: event(.playing, epochNow - 7_900_000))
        try m.apply(line: report(true, 1800, epochNow))
        let s = try #require(m.state(receivedAt: anchor + .seconds(1), epochMicrosNow: epochNow + 1_000_000))
        #expect(abs(s.position(at: anchor + .seconds(2)) - 1802) < 1e-6)
    }

    // Breaks if the fallback hold does not come back once the log has ended.
    @Test func logEndRestoresFallbackHold() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(true, 100, epochNow - 10_000_000))
        m.apply(event: event(.stopped, epochNow - 8_000_000))
        m.apply(event: event(.playing, epochNow - 7_900_000))
        m.logEnded()
        try m.apply(line: report(true, 1800, epochNow))
        let s = try #require(m.state(receivedAt: anchor, epochMicrosNow: epochNow))
        #expect(s.position(at: anchor + .seconds(1)) == 1800)
        #expect(abs(s.position(at: anchor + .seconds(2.5)) - 1801) < 1e-6)
    }

    // Breaks if a stall the log started outlives the log.
    @Test func logEndDropsOpenStall() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(true, 500, epochNow - 10_000_000))
        m.apply(event: event(.stopped, epochNow))
        m.logEnded()
        let s = try #require(m.state(receivedAt: anchor + .seconds(1), epochMicrosNow: epochNow + 1_000_000))
        #expect(abs(s.position(at: anchor + .seconds(1)) - 511) < 1e-6)
        #expect(s.effectiveRate == 1)
    }

    // Breaks if a stall while playing (no report at all) does not freeze the clock for its length.
    @Test func midPlayStallFreezesClock() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(true, 500, epochNow - 10_000_000))
        m.apply(event: event(.stopped, epochNow))
        let stalled = try #require(m.state(receivedAt: anchor + .seconds(1), epochMicrosNow: epochNow + 1_000_000))
        #expect(stalled.playing)
        #expect(stalled.position(at: anchor + .seconds(2)) == 510)
        m.apply(event: event(.playing, epochNow + 3_000_000))
        let s = try #require(m.state(receivedAt: anchor + .seconds(3), epochMicrosNow: epochNow + 3_000_000))
        #expect(abs(s.position(at: anchor + .seconds(4)) - 511) < 1e-6)
    }

    // Breaks if the short wait at a resume (Waiting 0.1 s before Playing, then the report) is
    // still taken off the clock after the report. Real trace: 18.724 Waiting, 18.823 Playing,
    // 18.828 report.
    @Test func resumeWithEventsDoesNotHold() throws {
        var m = NowPlayingMerger()
        try m.apply(line: report(false, 500, epochNow - 10_000_000))
        m.apply(event: event(.stopped, epochNow - 104_000))
        m.apply(event: event(.playing, epochNow - 5_000))
        try m.apply(line: line(true, #"{"playing":true}"#))
        try m.apply(line: line(true, #"{"timestampEpochMicros":\#(epochNow),"elapsedTimeMicros":500100000}"#))
        let s = try #require(m.state(receivedAt: anchor + .seconds(1), epochMicrosNow: epochNow + 1_000_000))
        #expect(abs(s.position(at: anchor + .seconds(1)) - 501.1) < 1e-6)
    }

    // Breaks if another app's playback drives the overlay.
    @Test func otherAppGivesNoState() throws {
        var m = NowPlayingMerger()
        try m.apply(line: line(false, #"{"bundleIdentifier":"com.apple.Music","title":"Song","playing":true,"elapsedTimeMicros":1}"#))
        #expect(m.state(receivedAt: anchor, epochMicrosNow: epochNow) == nil)
    }
}

struct NowPlayingMonitorTests {
    // Breaks if the monitor does not emit a snapshot per line, or emits for unparsable lines.
    @Test func emitsSnapshotsFromLines() async throws {
        let lines = AsyncStream<String> { c in
            c.yield(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.TV","title":"T","playing":false,"elapsedTimeMicros":5000000}}"#)
            c.yield("garbage")
            c.yield(#"{"type":"data","diff":true,"payload":{"bundleIdentifier":"com.apple.Music"}}"#)
            c.finish()
        }
        let monitor = NowPlayingMonitor()
        var seen: [PlaybackState?] = []
        for await s in await monitor.states(from: lines, buffering: .unbounded) { seen.append(s) }
        #expect(seen.count == 2)
        #expect(seen.first??.elapsedAtAnchor == 5)
        #expect(seen.last! == nil)
    }

    // Breaks if a player event does not give a snapshot of its own, with the clock stopped.
    @Test func emitsSnapshotPerPlayerEvent() async throws {
        let (lines, lineInput) = AsyncStream<String>.makeStream()
        let (events, eventInput) = AsyncStream<PlayerEvent>.makeStream()
        let monitor = NowPlayingMonitor()
        var states = await monitor.states(from: lines, events: events, buffering: .unbounded).makeAsyncIterator()
        let now = Int64(Date().timeIntervalSince1970 * 1e6)
        lineInput.yield(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.TV","title":"T","playing":true,"playbackRate":1,"elapsedTimeMicros":5000000,"timestampEpochMicros":\#(now)}}"#)
        let fromLine = try #require(await states.next())
        #expect(fromLine?.effectiveRate == 1)
        eventInput.yield(PlayerEvent(kind: .stopped, epochMicros: Double(now)))
        let fromEvent = try #require(await states.next())
        #expect(fromEvent?.effectiveRate == 0)
        #expect(fromEvent?.playing == true)
        lineInput.finish()
        #expect(await states.next() == nil)
    }

    // Breaks if the end of the event stream (the log failed for good) does not give the fallback
    // back: the stall it left open must end, and the next seek must hold 1.5 s.
    @Test func fallsBackWhenEventsEnd() async throws {
        let (lines, lineInput) = AsyncStream<String>.makeStream()
        let (events, eventInput) = AsyncStream<PlayerEvent>.makeStream()
        let monitor = NowPlayingMonitor()
        var states = await monitor.states(from: lines, events: events, buffering: .unbounded).makeAsyncIterator()
        let now = Int64(Date().timeIntervalSince1970 * 1e6)
        lineInput.yield(#"{"type":"data","diff":false,"payload":{"bundleIdentifier":"com.apple.TV","title":"T","playing":true,"playbackRate":1,"elapsedTimeMicros":100000000,"timestampEpochMicros":\#(now - 10_000_000)}}"#)
        _ = try #require(await states.next())
        eventInput.yield(PlayerEvent(kind: .stopped, epochMicros: Double(now)))
        let stalled = try #require(await states.next())
        #expect(stalled?.effectiveRate == 0)
        eventInput.finish()
        let ended = try #require(await states.next())
        #expect(ended?.effectiveRate == 1)
        lineInput.yield(#"{"type":"data","diff":true,"payload":{"elapsedTimeMicros":1800000000,"timestampEpochMicros":\#(now)}}"#)
        let seek = try #require(await states.next())
        // The hold puts the anchor 1.5 s ahead of the receipt, so one second on the clock
        // still shows the seek target.
        #expect(seek?.position(at: ContinuousClock.now + .seconds(1)) == 1800)
        lineInput.finish()
    }
}
