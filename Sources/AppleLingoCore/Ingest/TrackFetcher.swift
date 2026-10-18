import Foundation

/// Fetches a subtitle track the download has not finished: the track's media playlist from the
/// URL in `boot.xml`, then each WebVTT segment it lists. Those URLs answer without a session for
/// at least a day (measured 2026-10-12). Hosts must be Apple's; counts and sizes are capped as
/// for files in the package.
public struct TrackFetcher: Sendable {
    public enum FetchError: Error {
        case refusedHost(String)
        case badStatus(Int)
        case tooManySegments
        case tooLarge
    }

    static let hosts = HTTPClient.HostRule.suffix(".apple.com")
    static let maxInFlight = 6
    static let timeout: TimeInterval = 20

    private let transport: HTTPTransport

    public init(transport: HTTPTransport) {
        self.transport = transport
    }

    /// Cues of the track whose media playlist is at `url`, in Now Playing time, as
    /// `MoviePackageReader.readTrack` maps them.
    public func cues(playlist url: URL) async throws -> [Cue] {
        let text = String(decoding: try await get(url, cap: MoviePackageReader.maxPlaylistBytes), as: UTF8.self)
        let preRoll = MoviePackageReader.preRoll(playlist: text)
        let periods = MoviePackageReader.periodStarts(playlist: text)
        let segments = Self.segments(playlist: text, base: url).filter { $0.start >= preRoll - 0.01 }
        guard segments.count <= MoviePackageReader.maxFragments else { throw FetchError.tooManySegments }
        for segment in segments { try Self.check(segment.url) }
        var texts = [String](repeating: "", count: segments.count)
        var total = 0
        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            func fetchNext() {
                let i = next
                next += 1
                group.addTask { (i, try await self.get(segments[i].url, cap: MoviePackageReader.maxFragmentBytes)) }
            }
            while next < min(Self.maxInFlight, segments.count) { fetchNext() }
            while let (i, data) = try await group.next() {
                total += data.count
                guard total <= MoviePackageReader.maxTrackBytes else { throw FetchError.tooLarge }
                texts[i] = String(decoding: data, as: UTF8.self)
                if next < segments.count { fetchNext() }
            }
        }
        return MoviePackageReader.merge(zip(segments, texts).map { (MoviePackageReader.periodStart(periods, at: $0.start), $1) })
    }

    /// Start and URL of each segment of a media playlist: the URI line after each `#EXTINF`,
    /// starting at the sum of the durations before it; relative URIs resolve against `base`.
    static func segments(playlist: String, base: URL) -> [(start: Double, url: URL)] {
        var result: [(start: Double, url: URL)] = []
        var total = 0.0
        var pending: Double?
        for line in playlist.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#EXTINF:") {
                pending = Double(trimmed.dropFirst(8).prefix { $0 != "," }).flatMap { $0 >= 0 ? $0 : nil }
            } else if !trimmed.isEmpty, !trimmed.hasPrefix("#"), let duration = pending {
                if let url = URL(string: trimmed, relativeTo: base)?.absoluteURL { result.append((total, url)) }
                total += duration
                pending = nil
            }
        }
        return result
    }

    static func check(_ url: URL) throws {
        guard url.scheme == "https", let host = url.host(), hosts.allows(host) else {
            throw FetchError.refusedHost(url.host() ?? "")
        }
    }

    /// A 200 body of at most `cap` bytes from an Apple host.
    private func get(_ url: URL, cap: Int) async throws -> Data {
        try Self.check(url)
        let (data, response) = try await transport.send(URLRequest(url: url, timeoutInterval: Self.timeout))
        guard response.statusCode == 200 else { throw FetchError.badStatus(response.statusCode) }
        guard data.count <= cap else { throw FetchError.tooLarge }
        return data
    }
}
