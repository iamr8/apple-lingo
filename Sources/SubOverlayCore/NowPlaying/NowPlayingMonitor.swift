import Foundation

/// Merges the adapter's `stream` output (diff payloads) into one current payload.
public struct NowPlayingMerger: Sendable {
    public static let tvBundleID = "com.apple.TV"

    private struct Message: Decodable {
        var diff: Bool?
        var payload: [String: JSONValue]
    }

    public private(set) var payload: [String: JSONValue] = [:]

    /// After a seek the TV app reports the new position at once, waits for data (0 to 4 s
    /// measured) and reports nothing more. The player log says when the player moves again;
    /// without it, the clock waits this long from the report's sample time.
    static let seekSettle = 1.5
    private var report: Report?
    /// Epoch microseconds before which the clock does not move; 0 when not settling. Used only
    /// while no player event has arrived.
    private var settleUntil = 0.0
    /// A seek made while paused; the wait starts on play.
    private var pausedSeek = false
    /// True once the player log gave an event; from then on the log decides the waits.
    private var logAlive = false
    /// Epoch microseconds since which the player stands still; nil while it moves.
    private var stalledSince: Double?
    /// Microseconds of ended stalls since the report's sample time.
    private var stalledTotal = 0.0

    private struct Report: Equatable {
        var elapsed: Double, sampled: Double?, playing: Bool, rate: Double
    }

    public init() {}

    public mutating func apply(line: String) throws {
        let message = try JSONDecoder().decode(Message.self, from: Data(line.utf8))
        if message.diff != true { payload = [:] }
        for (key, value) in message.payload {
            if value == .null { payload[key] = nil } else { payload[key] = value }
        }
        // On play or pause the TV app first sends "playing" alone; only a line with a position or
        // sample time is a new report.
        if message.diff != true || message.payload["elapsedTimeMicros"] != nil
            || message.payload["timestampEpochMicros"] != nil { noteReport() }
    }

    /// A new report that jumps more than 1 s from where the last one predicted is a seek; a seek
    /// while paused waits from the play report. During
    /// the wait, a report that matches the seek (the TV app's own projection after a play
    /// command) is ignored: the seek report stays the anchor.
    private mutating func noteReport() {
        guard let elapsed = payload["elapsedTimeMicros"]?.number else { return }
        let new = Report(elapsed: elapsed / 1e6, sampled: payload["timestampEpochMicros"]?.number,
                         playing: payload["playing"]?.bool ?? false, rate: payload["playbackRate"]?.number ?? 1)
        guard new != report else { return }
        if let old = report, let oldSampled = old.sampled, let sampled = new.sampled {
            let predicted = old.elapsed + (old.playing ? playedMicros(from: oldSampled, to: sampled) / 1e6 * old.rate : 0)
            let jumped = abs(new.elapsed - predicted) > 1
            if new.playing {
                if jumped || pausedSeek {
                    // With the log alive, its Paused line marks the wait.
                    if !logAlive { settleUntil = sampled + Self.seekSettle * 1e6 }
                } else if old.playing, holding(at: sampled) {
                    return
                }
            }
            pausedSeek = !new.playing && (jumped || pausedSeek)
        }
        report = new
        // Stalls count from this report's sample time.
        stalledTotal = 0
        if let since = stalledSince, let sampled = new.sampled { stalledSince = max(since, sampled) }
    }

    /// A player state change from the log. From the first one on, the log decides the waits;
    /// only its lines start a stall and only its lines end one.
    public mutating func apply(event: PlayerEvent) {
        logAlive = true
        switch event.kind {
        case .stopped:
            if stalledSince == nil { stalledSince = max(event.epochMicros, report?.sampled ?? 0) }
            // The wait is known now; the fallback's guess for it is not needed.
            settleUntil = 0
        case .playing:
            if let since = stalledSince {
                stalledTotal += max(0, event.epochMicros - since)
                stalledSince = nil
            }
        }
    }

    /// The log ended: the fallback decides the waits until the log speaks again.
    public mutating func logEnded() {
        logAlive = false
        stalledSince = nil
        stalledTotal = 0
    }

    /// Whether the clock waits after a seek at `t` (epoch microseconds).
    private func holding(at t: Double) -> Bool {
        logAlive ? stalledSince != nil : t < settleUntil
    }

    /// Microseconds the player moved from the current report's sample time `sampled` to `t`.
    private func playedMicros(from sampled: Double, to t: Double) -> Double {
        let stalled = logAlive ? stalledTotal + (stalledSince.map { max(0, t - $0) } ?? 0) : 0
        return max(0, t - max(sampled, settleUntil) - stalled)
    }

    /// The TV app's playback, or nil when TV is not the now-playing app.
    public func state(receivedAt anchor: ContinuousClock.Instant, epochMicrosNow: Int64) -> PlaybackState? {
        guard payload["bundleIdentifier"]?.string == Self.tvBundleID,
              let title = payload["title"]?.string,
              payload["elapsedTimeMicros"]?.number != nil, let report
        else { return nil }
        let playing = payload["playing"]?.bool ?? false
        var rate = payload["playbackRate"]?.number ?? 1
        var elapsed = report.elapsed
        var start = anchor
        if playing, report.playing, let sampled = report.sampled {
            let now = Double(epochMicrosNow)
            let holdUntil = max(sampled, settleUntil)
            if now < holdUntil {
                start = anchor.advanced(by: .seconds((holdUntil - now) / 1e6))
            } else {
                elapsed += playedMicros(from: sampled, to: now) / 1e6 * rate
            }
            // Standing still, with the overlay kept on screen.
            if logAlive, stalledSince != nil { rate = 0 }
        }
        return PlaybackState(
            title: title,
            album: payload["album"]?.string,
            elapsedAtAnchor: elapsed,
            rate: rate,
            playing: playing,
            duration: payload["durationMicros"]?.number.map { $0 / 1e6 },
            processID: payload["processIdentifier"]?.number.map { Int32($0) },
            anchor: start
        )
    }
}

/// Turns adapter output lines, and player events from the log, into playback snapshots. Only
/// the newest snapshot is buffered.
public actor NowPlayingMonitor {
    private var merger = NowPlayingMerger()

    public init() {}

    /// Snapshots end when `lines` ends; `events` only adds snapshots while the TV app plays.
    public func states(
        from lines: AsyncStream<String>,
        events: AsyncStream<PlayerEvent>? = nil,
        buffering: AsyncStream<PlaybackState?>.Continuation.BufferingPolicy = .bufferingNewest(1)
    ) -> AsyncStream<PlaybackState?> {
        let (stream, continuation) = AsyncStream<PlaybackState?>.makeStream(bufferingPolicy: buffering)
        let eventTask = events.map { events in
            Task {
                for await event in events {
                    if let state = self.ingest(event).state { continuation.yield(state) }
                }
                // The log ended for good (3 restarts failed): the fallback takes over.
                if let state = self.logEnded().state { continuation.yield(state) }
            }
        }
        let task = Task {
            for await line in lines {
                // Lines that are not valid adapter output are skipped.
                guard let state = try? self.ingest(line) else { continue }
                continuation.yield(state.state)
            }
            eventTask?.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in
            task.cancel()
            eventTask?.cancel()
        }
        return stream
    }

    private func ingest(_ line: String) throws -> Snapshot {
        try merger.apply(line: line)
        return snapshot()
    }

    private func ingest(_ event: PlayerEvent) -> Snapshot {
        merger.apply(event: event)
        return snapshot()
    }

    private func logEnded() -> Snapshot {
        merger.logEnded()
        return snapshot()
    }

    private func snapshot() -> Snapshot {
        let micros = Int64(Date().timeIntervalSince1970 * 1e6)
        return Snapshot(state: merger.state(receivedAt: .now, epochMicrosNow: micros))
    }

    private struct Snapshot: Sendable { var state: PlaybackState? }
}
