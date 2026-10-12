import Foundation

/// A part of a downloaded title, in download time. The intro and recap are Apple interstitials:
/// at play time the TV app may show different ones, of another length.
public struct TitlePart: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case intro, recap, content, after
    }

    public var kind: Kind
    public var start: Double
    public var duration: Double

    public init(kind: Kind, start: Double, duration: Double) {
        self.kind = kind
        self.start = start
        self.duration = duration
    }
}
