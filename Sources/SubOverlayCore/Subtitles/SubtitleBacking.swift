import Foundation

/// Fits a human translation from another release (a "backing") to the title once it is aligned
/// to the timing track: drops the release group's ads, and finds the dialogue it lacks (a recap
/// another release cut) so only those lines are translated.
public enum SubtitleBacking {
    /// Drops a cue with a link or an @handle (release ads), or a cue in the first or last
    /// `creditsSpan` with no timing-track speech under it at all (credits). Mid-film, a line
    /// without speech stays: an "Oh" that Apple does not caption. The result is in time order,
    /// which alignment does not keep.
    public static func clean(_ backing: [Cue], timing: [Cue]) -> [Cue] {
        let end = timing.last?.end ?? 0
        return backing.filter { cue in
            let edge = cue.start < creditsSpan || cue.start > end - creditsSpan
            return !isAd(cue.text) && !(edge && overlap(cue, timing) == 0)
        }.sorted { $0.start < $1.start }
    }

    static let creditsSpan = 300.0

    /// A job for the timing cues between the backing's first and last lines that no backing cue
    /// overlaps, with the source lines spoken during them; nil when there are none. Before is the
    /// preview of earlier episodes, which other releases cut; after are the end credits, where a
    /// translated Apple track names its own translator. Both stay without subtitles.
    public static func gapJob(backing: [Cue], source: [Cue], sourceLanguage: String,
                              timing: [Cue], timingLanguage: String, targetLanguage: String) -> TranslationJob? {
        guard let first = backing.map(\.start).min(), let last = backing.map(\.end).max() else { return nil }
        let gaps = timing.filter { $0.start >= first && $0.start < last && overlap($0, backing) == 0 }
        guard !gaps.isEmpty else { return nil }
        return TranslationJob(source: source.filter { overlap($0, gaps) > 0 }, sourceLanguage: sourceLanguage,
                              timing: gaps, timingLanguage: timingLanguage, targetLanguage: targetLanguage)
    }

    /// The backing and the translated gap cues in time order, numbered from 1.
    public static func merge(_ backing: [Cue], _ fill: [Cue]) -> [Cue] {
        (backing + fill).sorted { $0.start < $1.start }.enumerated().map { i, cue in
            var out = cue
            out.id = i + 1
            return out
        }
    }

    /// A link, an @handle, or a translator credit ("ترجمه …:"). The credit words are Persian,
    /// the one backing language in use; dialogue with them has no colon.
    static func isAd(_ text: String) -> Bool {
        let lower = text.lowercased()
        if ["www.", "http", ".com"].contains(where: { lower.contains($0) }) { return true }
        if lower.contains(/@[a-z0-9_]{2,}/) { return true }
        return lower.contains(":") && ["ترجمه", "مترجم", "زیرنویس"].contains { lower.contains($0) }
    }

    /// Seconds of `cue` that overlap cues of `track` (sorted by start).
    static func overlap(_ cue: Cue, _ track: [Cue]) -> Double {
        SubtitleAligner.overlap(cue, shift: 0, reference: track)
    }
}
