import Foundation

/// How far the Now Playing clock runs ahead of a downloaded title's timeline. A streamed title
/// can open with a longer Apple intro than its download; Now Playing counts it, so its length
/// grows by the same seconds. Measured on Hand to Mouth: 3721.311 − 3692.23 = 29.08 s, and
/// Apple's captions were 28.6 to 30.2 s behind Now Playing.
public enum StreamLead {
    public static func seconds(nowPlaying: Double?, video: Double?) -> Double {
        guard let nowPlaying, let video else { return 0 }
        let lead = nowPlaying - video
        // Below half a second is rounding; past 10 minutes the pair is not the same title.
        return (0.5...600).contains(lead) ? lead : 0
    }
}
