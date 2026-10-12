import Foundation

/// What the TV app's player did, from its unified log, with the log line's own time.
public struct PlayerEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The player moves.
        case playing
        /// The player is paused or waits for data.
        case stopped
    }

    public var kind: Kind
    /// Epoch microseconds of the log line.
    public var epochMicros: Double

    public init(kind: Kind, epochMicros: Double) {
        self.kind = kind
        self.epochMicros = epochMicros
    }
}

/// Reads the TV app's player state changes from the unified log with `/usr/bin/log stream`.
/// The TV app writes Now Playing when a wait for data starts and never when it ends; these
/// lines say when the player really moves.
public struct PlayerLogStream: Sendable {
    static let log = URL(filePath: "/usr/bin/log")
    static let maxLineLength = 16 * 1024
    /// The main player only: the interstitial player logs the same lines for Apple's intros.
    static let predicate = #"process == "TV" AND subsystem == "com.apple.AppleTV.playback" AND category == "TVPPlayer" AND eventMessage CONTAINS "main player timeControlStatus did change""#
    static let marker = "main player timeControlStatus did change to AVPlayerTimeControlStatus"

    public init() {}

    /// Events as the TV app logs them. Restarts `log` after an exit, at most 3 times.
    /// Cancelling the consumer terminates the process.
    public func events() -> AsyncStream<PlayerEvent> {
        let lines = LineProcess(
            executable: Self.log,
            arguments: ["stream", "--style", "ndjson", "--process", "TV", "--predicate", Self.predicate],
            maxLineLength: Self.maxLineLength, name: "log stream"
        ).lines()
        return AsyncStream { continuation in
            let task = Task {
                for await line in lines {
                    if let event = Self.parse(line: line) { continuation.yield(event) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private struct Line: Decodable {
        var timestamp: String
        var eventMessage: String
    }

    /// One ndjson line of `log stream` as an event, or nil for any other line.
    public static func parse(line: String) -> PlayerEvent? {
        guard let decoded = try? JSONDecoder().decode(Line.self, from: Data(line.utf8)),
              let range = decoded.eventMessage.range(of: Self.marker),
              let micros = epochMicros(decoded.timestamp)
        else { return nil }
        let rest = decoded.eventMessage[range.upperBound...]
        switch rest.prefix(while: \.isLetter) {
        case "Playing": return PlayerEvent(kind: .playing, epochMicros: micros)
        case "Paused": return PlayerEvent(kind: .stopped, epochMicros: micros)
        case "WaitingToPlayAtSpecifiedRate":
            // Apple's intro or recap plays in another player; Now Playing counts that time.
            return PlayerEvent(kind: rest.contains("DuringInterstitialEvent") ? .playing : .stopped, epochMicros: micros)
        default: return nil
        }
    }

    /// `2026-10-11 20:42:51.549335+0300` as epoch microseconds.
    static func epochMicros(_ text: String) -> Double? {
        guard let match = text.wholeMatch(of: /(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\.(\d{1,6})([+-]\d{4})/) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ssZ"
        guard let date = formatter.date(from: "\(match.1)\(match.3)"),
              let fraction = Int(String(match.2).padding(toLength: 6, withPad: "0", startingAt: 0))
        else { return nil }
        return (date.timeIntervalSince1970 * 1e6).rounded() + Double(fraction)
    }
}
