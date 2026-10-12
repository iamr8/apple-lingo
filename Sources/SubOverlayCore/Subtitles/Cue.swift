import Foundation

/// One subtitle cue. Times are media seconds.
public struct Cue: Sendable, Equatable {
    public var id: Int
    public var start: Double
    public var end: Double
    /// Plain text, lines joined by "\n", markup removed.
    public var text: String
    /// Raw WebVTT cue settings, copied unchanged to output files.
    public var settings: String
    public var italic: Bool

    public init(id: Int, start: Double, end: Double, text: String, settings: String = "", italic: Bool = false) {
        self.id = id
        self.start = start
        self.end = end
        self.text = text
        self.settings = settings
        self.italic = italic
    }

    public var layout: CueLayout { CueLayout(settings: settings) }
}

/// The subset of WebVTT cue settings Apple uses: `line`, `position`, `align`.
public struct CueLayout: Sendable, Equatable {
    public enum Anchor: Sendable, Equatable { case start, center, end }

    /// Line position in percent of the video height, with its anchor.
    public var line: Double?
    public var lineAnchor: Anchor = .start
    /// Horizontal position in percent of the video width, with its anchor.
    public var position: Double?
    public var positionAnchor: Anchor = .center
    public var align: Anchor = .center

    public init(settings: String) {
        for token in settings.split(separator: " ") {
            let pair = token.split(separator: ":", maxSplits: 1)
            guard pair.count == 2 else { continue }
            let value = pair[1].split(separator: ",", maxSplits: 1)
            let anchor = value.count == 2 ? Self.anchor(value[1]) : nil
            switch pair[0] {
            case "line":
                if value[0].hasSuffix("%"), let v = Double(value[0].dropLast()) { line = v }
                if let anchor { lineAnchor = anchor }
            case "position":
                if value[0].hasSuffix("%"), let v = Double(value[0].dropLast()) { position = v }
                if let anchor { positionAnchor = anchor }
            case "align":
                if let a = Self.anchor(value[0]) { align = a }
            default:
                continue
            }
        }
    }

    private static func anchor(_ s: Substring) -> Anchor? {
        switch s {
        case "start", "left", "line-left": .start
        case "middle", "center": .center
        case "end", "right", "line-right": .end
        default: nil
        }
    }
}
