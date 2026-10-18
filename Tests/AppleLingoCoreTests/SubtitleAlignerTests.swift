import Foundation
import Testing
@testable import AppleLingoCore

struct SubtitleAlignerTests {
    /// A 50-minute reference track with uneven speech and pauses, from a fixed seed.
    static let reference: [Cue] = {
        var seed: UInt64 = 42
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        var cues: [Cue] = []
        var t = 20.0
        while t < 3000 {
            let length = 1 + next() * 3
            cues.append(Cue(id: cues.count + 1, start: t, end: t + length, text: "line \(cues.count + 1)"))
            t += length + 0.3 + next() * next() * 12
        }
        return cues
    }()

    /// The reference as another release would time it.
    static func backing(_ transform: (Double) -> Double, from cues: [Cue] = reference) -> [Cue] {
        cues.map { var c = $0; c.start = transform($0.start); c.end = transform($0.end); return c }
    }

    static func maxError(_ result: SubtitleAligner.Result, against cues: [Cue] = reference) -> Double {
        zip(result.cues, cues).map { max(abs($0.start - $1.start), abs($0.end - $1.end)) }.max() ?? .infinity
    }

    // Breaks if a plain shift is not found.
    @Test func findsShift() {
        let result = SubtitleAligner.align(Self.backing { $0 + 12.4 }, to: Self.reference)
        #expect(Self.maxError(result) < 0.05)
        #expect(result.confidence > 0.9)
    }

    // Breaks if a backing from another cut (a 45 s scene added halfway) is bent to fit in parts
    // instead of moved by one offset; it must look untrustworthy so the user tries another file.
    @Test func cutBackingIsNotBent() {
        let jump = Self.reference[Self.reference.count / 2].start - 0.1
        let backing = Self.backing { $0 >= jump ? $0 + 45 : $0 }
        let result = SubtitleAligner.align(backing, to: Self.reference)
        let shifts = Set(zip(result.cues, backing).map { (($0.start - $1.start) * 100).rounded() })
        #expect(shifts.count == 1)
        #expect(result.confidence < 0.8, "\(result.confidence)")
    }

    // Breaks if a backing that splits dialogue differently (two reference cues as one) is not aligned.
    @Test func alignsDifferentCueBreaks() {
        let merged = stride(from: 0, to: Self.reference.count - 1, by: 2).map { i in
            Cue(id: i, start: Self.reference[i].start + 8, end: Self.reference[i + 1].end + 8, text: "x")
        }
        let result = SubtitleAligner.align(merged, to: Self.reference)
        let wanted = stride(from: 0, to: Self.reference.count - 1, by: 2).map { Self.reference[$0].start }
        #expect(zip(result.cues.map(\.start), wanted).allSatisfy { abs($0 - $1) < 0.1 })
        #expect(result.confidence > 0.9)
    }

    // Breaks if a backing for another film looks trustworthy.
    @Test func unrelatedBackingHasLowConfidence() {
        let other = Self.backing({ $0 }, from: Array(Self.reference.reversed()).enumerated().map { i, c in
            Cue(id: i, start: 3020 - c.end, end: 3020 - c.start, text: "y")
        })
        #expect(SubtitleAligner.align(other, to: Self.reference).confidence < 0.6)
    }
}
