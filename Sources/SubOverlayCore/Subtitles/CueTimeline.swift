import Foundation

/// Immutable cues sorted by start, with fast lookup by time.
public struct CueTimeline: Sendable {
    public let cues: [Cue]
    private let boundaries: [Double]
    private let maxDuration: Double

    public init(_ cues: [Cue]) {
        self.cues = cues.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        boundaries = Array(Set(cues.flatMap { [$0.start, $0.end] })).sorted()
        maxDuration = cues.map { $0.end - $0.start }.max() ?? 0
    }

    /// Cues with `start <= t < end`, in start order.
    public func activeCues(at t: Double) -> [Cue] {
        // Index of the first cue with start > t.
        var lo = 0, hi = cues.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if cues[mid].start <= t { lo = mid + 1 } else { hi = mid }
        }
        var result: [Cue] = []
        var i = lo - 1
        while i >= 0, cues[i].start >= t - maxDuration {
            if t < cues[i].end { result.append(cues[i]) }
            i -= 1
        }
        return result.reversed()
    }

    /// The first cue start or end strictly after `t`.
    public func nextBoundary(after t: Double) -> Double? {
        var lo = 0, hi = boundaries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if boundaries[mid] <= t { lo = mid + 1 } else { hi = mid }
        }
        return lo < boundaries.count ? boundaries[lo] : nil
    }
}
