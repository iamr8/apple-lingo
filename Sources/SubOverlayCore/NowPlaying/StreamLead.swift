import Foundation

/// How far the Now Playing clock runs ahead of a downloaded title's timeline. A streamed title
/// can open with a longer Apple intro than its download. Exact: where the main player's clock
/// began the content (WhatsHerName 86.61) minus where the download's content part starts
/// (55.402). Until the clock says, the lengths: Now Playing counts the longer intro, so its
/// length grows by the same seconds (Hand to Mouth: 3721.311 − 3692.23 = 29.08 s, 0.3 s short
/// of the clock's; WhatsHerName 0.66 s short).
public enum StreamLead {
    public static func seconds(contentStart: Double? = nil, contentPart: Double? = nil,
                               nowPlaying: Double?, video: Double?) -> Double {
        if let contentStart, let contentPart, (0.5...600).contains(contentStart - contentPart) {
            return contentStart - contentPart
        }
        guard let nowPlaying, let video else { return 0 }
        let lead = nowPlaying - video
        // Below half a second is rounding; past 10 minutes the pair is not the same title.
        return (0.5...600).contains(lead) ? lead : 0
    }
}
