import Foundation

/// Re-times a subtitle track from another release to a reference track (Apple's) by one offset,
/// after a frame-rate change if one fits better. Uses timing only, so the two tracks can be in
/// different languages and split dialogue differently. Every pair of cue starts votes for a
/// shift; the strongest wins and is fine-tuned by speech overlap. A release that one offset does
/// not fit (another cut) gets a low confidence: the user tries another file.
public enum SubtitleAligner {
    public struct Result: Sendable {
        public var cues: [Cue]
        /// Share of cues that start within `startTolerance` of a reference cue, 0 to 1. Real
        /// files: the right episode 0.96-0.99, other episodes 0.24-0.30.
        public var confidence: Double
        /// The factor the backing's times were multiplied by before the shift: 1, or a frame-rate change.
        public var scale = 1.0
    }

    static let maxShift = 900.0
    static let bin = 0.1
    static let startTolerance = 0.5

    /// Frame-rate changes between releases: none first, so it wins a tie; 25 fps (PAL speed-up)
    /// both ways; 24 vs 23.976 fps both ways; 25 vs 24 fps both ways.
    static let scales = [1, 25 / (24000.0 / 1001), (24000.0 / 1001) / 25, 1000.0 / 1001, 1001.0 / 1000, 25.0 / 24, 24.0 / 25]

    public static func align(_ cues: [Cue], to reference: [Cue]) -> Result {
        guard !cues.isEmpty, !reference.isEmpty else { return Result(cues: cues, confidence: 0) }
        var best = Result(cues: cues, confidence: -1)
        for scale in scales {
            let scaled = cues.map { cue in
                var c = cue
                c.start *= scale
                c.end *= scale
                return c
            }
            var result = align(shifting: scaled, to: reference)
            result.scale = scale
            if result.confidence > best.confidence { best = result }
        }
        return best
    }

    /// Moves `cues` by the one shift that fits `reference` best.
    static func align(shifting cues: [Cue], to reference: [Cue]) -> Result {
        let (voted, _) = vote(cues.map(\.start), reference.map(\.start), around: 0, range: maxShift)
        let shift = refine(cues, shift: voted, reference: reference)
        let out = cues.map { cue in
            var c = cue
            c.start += shift
            c.end += shift
            return c
        }
        let starts = reference.map(\.start).sorted()
        let landed = out.filter { cue in
            var lo = 0, hi = starts.count
            while lo < hi { let mid = (lo + hi) / 2; if starts[mid] < cue.start - startTolerance { lo = mid + 1 } else { hi = mid } }
            return lo < starts.count && starts[lo] <= cue.start + startTolerance
        }.count
        return Result(cues: out, confidence: Double(landed) / Double(out.count))
    }

    /// The shift (reference minus backing start) most pairs agree on, within `range` of `around`,
    /// and how many pairs voted for it (with its neighbour bins).
    static func vote(_ backing: [Double], _ reference: [Double], around: Double, range: Double) -> (Double, Int) {
        let half = Int(range / bin)
        var bins = [Int](repeating: 0, count: 2 * half + 1)
        for b in backing {
            let low = b + around - range, high = b + around + range
            var lo = 0, hi = reference.count
            while lo < hi { let mid = (lo + hi) / 2; if reference[mid] < low { lo = mid + 1 } else { hi = mid } }
            var j = lo
            while j < reference.count, reference[j] <= high {
                let k = Int(((reference[j] - b - around) / bin).rounded()) + half
                if bins.indices.contains(k) { bins[k] += 1 }
                j += 1
            }
        }
        var bestK = half, bestVotes = -1
        for k in bins.indices {
            let votes = bins[k] + (k > 0 ? bins[k - 1] : 0) + (k + 1 < bins.count ? bins[k + 1] : 0)
            if votes > bestVotes { bestK = k; bestVotes = votes }
        }
        return (around + Double(bestK - half) * bin, bestVotes)
    }

    /// The shift within 0.3 s of `shift` that gives the most speech overlap, in steps of 10 ms.
    static func refine(_ cues: [Cue], shift: Double, reference: [Cue]) -> Double {
        var best = shift, bestScore = -1.0
        for step in -30...30 {
            let s = shift + Double(step) * 0.01
            let score = cues.reduce(0) { $0 + overlap($1, shift: s, reference: reference) }
            if score > bestScore + 1e-9 || (abs(score - bestScore) < 1e-9 && abs(s - shift) < abs(best - shift)) {
                best = s
                bestScore = score
            }
        }
        return best
    }

    /// Seconds of `cue`, moved, that overlap reference cues.
    static func overlap(_ cue: Cue, shift: Double, reference: [Cue]) -> Double {
        let start = cue.start + shift, end = cue.end + shift
        var lo = 0, hi = reference.count
        while lo < hi { let mid = (lo + hi) / 2; if reference[mid].end <= start - 30 { lo = mid + 1 } else { hi = mid } }
        var total = 0.0
        var j = lo
        while j < reference.count, reference[j].start < end {
            total += max(0, min(end, reference[j].end) - max(start, reference[j].start))
            j += 1
        }
        return total
    }
}
