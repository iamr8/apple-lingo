import Foundation

/// How far the Now Playing clock runs ahead of a downloaded title's timeline. A streamed title
/// can open with a longer Apple intro than its download. The lengths say roughly: Now Playing
/// counts the longer intro, so its length grows by the same seconds (Hand to Mouth: 3721.311 −
/// 3692.23 = 29.08 s). The clock says exactly: where the main player began the content
/// (WhatsHerName 86.61) minus where the download's content part starts (55.402), 0.3 to 0.7 s
/// over the lengths on two titles and 2.55 s over on The Place I Lie (its promo is shorter than
/// the length says). The clock's number counts only when it is near the lengths' number.
public enum StreamLead {
    public static func seconds(contentStart: Double? = nil, contentPart: Double? = nil,
                               nowPlaying: Double?, video: Double?) -> Double {
        guard let nowPlaying, let video else { return 0 }
        let lead = nowPlaying - video
        // Below half a second is rounding; past 10 minutes the pair is not the same title.
        guard (0.5...600).contains(lead) else { return 0 }
        if let contentStart, let contentPart, (-0.5...3.5).contains(contentStart - contentPart - lead) {
            return contentStart - contentPart
        }
        return lead
    }
}
