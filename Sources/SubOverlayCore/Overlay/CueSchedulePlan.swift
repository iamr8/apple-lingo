import Foundation

/// What to show now and when to wake next. `delay` is nil when no timer is needed.
public struct CueSchedulePlan: Sendable, Equatable {
    public var cues: [Cue]
    /// Seconds of wall time until the next cue edge.
    public var delay: Double?

    public init(timeline: CueTimeline, state: PlaybackState, offset: Double, now: ContinuousClock.Instant) {
        let position = state.position(at: now) + offset
        cues = timeline.activeCues(at: position)
        let rate = state.effectiveRate
        if rate > 0, let next = timeline.nextBoundary(after: position) {
            delay = (next - position) / rate
        } else {
            delay = nil
        }
    }
}
