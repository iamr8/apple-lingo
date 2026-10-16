import Foundation

/// TV app playback at one moment, anchored to the monotonic clock.
public struct PlaybackState: Sendable, Equatable {
    public var title: String
    public var album: String?
    /// Media position in seconds at `anchor`.
    public var elapsedAtAnchor: Double
    public var rate: Double
    public var playing: Bool
    public var duration: Double?
    public var processID: Int32?
    /// Where the content began in Now Playing's timeline, from the main player's first moving
    /// clock line after Apple's intros; nil until then.
    public var contentStart: Double?
    public var anchor: ContinuousClock.Instant

    public init(title: String, album: String?, elapsedAtAnchor: Double, rate: Double, playing: Bool,
                duration: Double? = nil, processID: Int32? = nil, contentStart: Double? = nil,
                anchor: ContinuousClock.Instant) {
        self.title = title
        self.album = album
        self.elapsedAtAnchor = elapsedAtAnchor
        self.rate = rate
        self.playing = playing
        self.duration = duration
        self.processID = processID
        self.contentStart = contentStart
        self.anchor = anchor
    }

    /// The TV app reports rate 1 while paused, so `playing` decides.
    public var effectiveRate: Double { playing ? rate : 0 }

    /// The position at `now`; before `anchor` (a seek still buffering) it stays at the anchor's.
    public func position(at now: ContinuousClock.Instant) -> Double {
        let d = anchor.duration(to: now)
        let seconds = Double(d.components.seconds) + Double(d.components.attoseconds) * 1e-18
        return elapsedAtAnchor + max(0, seconds) * effectiveRate
    }
}
