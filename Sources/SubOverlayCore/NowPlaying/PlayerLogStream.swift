import Foundation

/// What the TV app's player did, from its unified log, with the log line's own time.
public struct PlayerEvent: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The player moves.
        case playing
        /// The player is paused or waits for data.
        case stopped
        /// Apple's intro, recap and bumper play in another player while the main player waits;
        /// Now Playing's clock runs through them on the same timeline as the subtitles.
        case interstitial
        /// The main player's own clock: at `time` seconds, moving at `rate`, when the line was written.
        case timebase(rate: Double, time: Double)
        /// The log process restarted: lines in between were lost.
        case logRestarted
    }

    public var kind: Kind
    /// Epoch microseconds of the log line.
    public var epochMicros: Double

    public init(kind: Kind, epochMicros: Double) {
        self.kind = kind
        self.epochMicros = epochMicros
    }
}

/// Reads the TV app's player state changes and its clock from the unified log with
/// `/usr/bin/log stream`. The TV app's Now Playing position is stale by up to half a second
/// (rounded down at a pause, behind after a seek) and is written when a wait starts, never when
/// it ends; these lines say when the player really moves and where its clock stands.
public struct PlayerLogStream: Sendable {
    static let log = URL(filePath: "/usr/bin/log")
    static let maxLineLength = 16 * 1024
    /// The main player's state only (the interstitial player logs the same lines for Apple's
    /// bumpers), and the interstitial coordinator's clock line, which carries the main player's
    /// timebase at every rate change: pause, resume, seek, stall.
    static let predicate = #"process == "TV" AND ((subsystem == "com.apple.AppleTV.playback" AND category == "TVPPlayer" AND eventMessage CONTAINS "main player timeControlStatus did change") OR (subsystem == "com.apple.coremedia" AND eventMessage CONTAINS "FigPlayerInterstitial" AND eventMessage CONTAINS "State logging - timebaseRate"))"#
    static let marker = "main player timeControlStatus did change to AVPlayerTimeControlStatus"
    static let clockMarker = "State logging - timebaseRate"

    public init() {}

    /// Events as the TV app logs them. Restarts `log` after an exit, at most 3 times.
    /// Cancelling the consumer terminates the process.
    public func events() -> AsyncStream<PlayerEvent> {
        Self.events(from: LineProcess(
            executable: Self.log,
            arguments: ["stream", "--style", "ndjson", "--process", "TV", "--predicate", Self.predicate],
            maxLineLength: Self.maxLineLength, name: "log stream"
        ).outputs())
    }

    static func events(from outputs: AsyncStream<LineProcess.Output>) -> AsyncStream<PlayerEvent> {
        AsyncStream { continuation in
            let task = Task {
                for await output in outputs {
                    switch output {
                    case .line(let line):
                        if let event = Self.parse(line: line) { continuation.yield(event) }
                    case .restarted:
                        continuation.yield(PlayerEvent(kind: .logRestarted, epochMicros: Date().timeIntervalSince1970 * 1e6))
                    }
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
              let micros = epochMicros(decoded.timestamp)
        else { return nil }
        let message = decoded.eventMessage
        if message.contains(Self.clockMarker) {
            // `<<<< FigPlayerInterstitial >>>> fpic_checkScheduledTransition_block_invoke: 0x... State
            // logging - timebaseRate 1.000000, timebaseTime 1994.528930, ...`: the main player's clock,
            // also while a bumper plays in the other player.
            guard message.contains("FigPlayerInterstitial"),
                  let match = message.firstMatch(of: /timebaseRate (\d+\.\d+), timebaseTime (\d+\.\d+)/),
                  let rate = Double(match.1), let time = Double(match.2)
            else { return nil }
            return PlayerEvent(kind: .timebase(rate: rate, time: time), epochMicros: micros)
        }
        guard let range = message.range(of: Self.marker) else { return nil }
        let rest = message[range.upperBound...]
        switch rest.prefix(while: \.isLetter) {
        case "Playing": return PlayerEvent(kind: .playing, epochMicros: micros)
        case "Paused": return PlayerEvent(kind: .stopped, epochMicros: micros)
        case "WaitingToPlayAtSpecifiedRate":
            return PlayerEvent(kind: rest.contains("DuringInterstitialEvent") ? .interstitial : .stopped, epochMicros: micros)
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
