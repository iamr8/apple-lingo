import Testing
@testable import SubOverlayCore

private func cue(_ id: Int, _ start: Double, _ end: Double) -> Cue {
    Cue(id: id, start: start, end: end, text: "c\(id)")
}

struct CueTimelineTests {
    // Breaks if activeCues ignores the half-open [start, end) rule.
    @Test func activeCuesUseHalfOpenRanges() {
        let t = CueTimeline([cue(1, 1, 2), cue(2, 2, 3)])
        #expect(t.activeCues(at: 0.99).map(\.id) == [])
        #expect(t.activeCues(at: 1).map(\.id) == [1])
        #expect(t.activeCues(at: 2).map(\.id) == [2])
        #expect(t.activeCues(at: 3).map(\.id) == [])
    }

    // Breaks if the backward scan stops at the first non-matching cue.
    @Test func overlappingCuesAreAllActive() {
        let t = CueTimeline([cue(1, 0, 10), cue(2, 4, 5), cue(3, 6, 7)])
        #expect(t.activeCues(at: 6.5).map(\.id) == [1, 3])
    }

    // Breaks if cues are not sorted on build.
    @Test func unsortedInputIsSorted() {
        let t = CueTimeline([cue(2, 5, 6), cue(1, 1, 2)])
        #expect(t.activeCues(at: 5.5).map(\.id) == [2])
        #expect(t.cues.map(\.id) == [1, 2])
    }

    // Breaks if nextBoundary returns a value equal to t, or skips cue ends.
    @Test func nextBoundaryIsStrictlyAfter() {
        let t = CueTimeline([cue(1, 1, 2), cue(2, 4, 5)])
        #expect(t.nextBoundary(after: 0) == 1)
        #expect(t.nextBoundary(after: 1) == 2)
        #expect(t.nextBoundary(after: 2.5) == 4)
        #expect(t.nextBoundary(after: 5) == nil)
    }
}

struct PlaybackStateTests {
    // Breaks if paused state still advances (TV reports playbackRate 1 while paused).
    @Test func pausedPositionDoesNotMove() {
        let now = ContinuousClock.now
        let s = PlaybackState(title: "t", album: "a", elapsedAtAnchor: 10, rate: 1, playing: false, anchor: now)
        #expect(s.position(at: now.advanced(by: .seconds(5))) == 10)
    }

    // Breaks if the extrapolation ignores the rate.
    @Test func playingPositionExtrapolatesWithRate() {
        let now = ContinuousClock.now
        let s = PlaybackState(title: "t", album: "a", elapsedAtAnchor: 10, rate: 2, playing: true, anchor: now)
        #expect(abs(s.position(at: now.advanced(by: .seconds(3))) - 16) < 1e-9)
    }
}
