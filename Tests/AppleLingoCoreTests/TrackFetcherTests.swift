import Foundation
import Testing
@testable import AppleLingoCore

struct TrackFetcherTests {
    static let playlistURL = URL(string: "https://play-edge.itunes.apple.com/hls/subscription/stream/playlist.m3u8?id=ar&t=TOKEN")!
    static let segmentHost = "https://download-ap-aoc.tv.apple.com/assets/"

    /// Answers the URLs in `bodies` with 200 and anything else with 404.
    static func transport(_ bodies: [String: String]) -> StubTransport {
        StubTransport { request in
            guard let body = bodies[request.url!.absoluteString] else { return (404, "") }
            return (200, body)
        }
    }

    static func frag(_ name: String) throws -> String {
        try String(contentsOf: Fixture.package.appending(path: "2-AR").appending(path: name), encoding: .utf8)
    }

    // Breaks if a track fetched from its URLs differs from the same track read from the package,
    // or a relative segment URI does not resolve against the playlist's URL.
    @Test func fetchedTrackMatchesPackageTrack() async throws {
        let playlist = """
        #EXTM3U
        #EXT-X-TARGETDURATION:60
        #EXTINF:60,
        \(Self.segmentHost)0.webvtt
        #EXTINF:60,
        1.webvtt
        #EXTINF:60,
        \(Self.segmentHost)2.webvtt
        #EXTINF:900,
        \(Self.segmentHost)3.webvtt
        """
        let bodies: [String: String] = [
            Self.playlistURL.absoluteString: playlist,
            Self.segmentHost + "0.webvtt": try Self.frag("(0)_(0)_(60).frag"),
            "https://play-edge.itunes.apple.com/hls/subscription/stream/1.webvtt": try Self.frag("(60)_(0)_(60).frag"),
            Self.segmentHost + "2.webvtt": try Self.frag("(120)_(0)_(60).frag"),
            Self.segmentHost + "3.webvtt": try Self.frag("(1020)_(0)_(60).frag"),
        ]
        let fetched = try await TrackFetcher(transport: Self.transport(bodies)).cues(playlist: Self.playlistURL)
        let m = try MoviePackageReader.manifest(package: Fixture.package)
        let read = try MoviePackageReader.readTrack(try #require(m.tracks.first { $0.language == "ar" }), package: Fixture.package)
        #expect(!fetched.isEmpty)
        #expect(fetched == read)
    }

    // Breaks if a playlist or segment on a host outside Apple's is fetched.
    @Test func refusesForeignHosts() async throws {
        let playlist = "#EXTM3U\n#EXTINF:60,\nhttps://evil.example/0.webvtt\n"
        let transport = Self.transport([Self.playlistURL.absoluteString: playlist,
                                        "https://evil.example/0.webvtt": "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nx\n"])
        await #expect(throws: TrackFetcher.FetchError.self) {
            _ = try await TrackFetcher(transport: transport).cues(playlist: Self.playlistURL)
        }
        await #expect(throws: TrackFetcher.FetchError.self) {
            _ = try await TrackFetcher(transport: transport).cues(playlist: URL(string: "https://evil.example/playlist.m3u8")!)
        }
        #expect(transport.requests.withLock { $0 }.map { $0.url!.host() } == ["play-edge.itunes.apple.com"])
    }

    // Breaks if the pre-roll segment's cues are kept, or cues after a discontinuity do not move
    // by their period's start, as the package reader moves them.
    @Test func skipsPreRollAndShiftsPeriods() async throws {
        let playlist = "#EXTM3U\n#EXTINF:8.126,\n\(Self.segmentHost)intro.webvtt\n#EXT-X-DISCONTINUITY\n#EXTINF:60.0,\n\(Self.segmentHost)1.webvtt\n"
        let transport = Self.transport([
            Self.playlistURL.absoluteString: playlist,
            Self.segmentHost + "intro.webvtt": "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nIntro\n",
            Self.segmentHost + "1.webvtt": "WEBVTT\n\n00:00:05.000 --> 00:00:06.500\nHello\n",
        ])
        let cues = try await TrackFetcher(transport: transport).cues(playlist: Self.playlistURL)
        #expect(cues.map(\.text) == ["Hello"])
        #expect(abs(cues[0].start - 13.126) < 1e-9)
        #expect(abs(cues[0].end - 14.626) < 1e-9)
        #expect(!transport.requests.withLock { $0 }.contains { $0.url!.lastPathComponent == "intro.webvtt" })
    }

    // Breaks if an oversize segment, a failed segment, or too many segments are not refused.
    @Test func capsAndStatuses() async throws {
        let playlist = "#EXTM3U\n#EXTINF:60,\n\(Self.segmentHost)0.webvtt\n"
        let big = "WEBVTT\n\n" + String(repeating: "00:00:01.000 --> 00:00:02.000\nx\n\n", count: 12_000)
        #expect(big.utf8.count > MoviePackageReader.maxFragmentBytes)
        await #expect(throws: TrackFetcher.FetchError.self) {
            _ = try await TrackFetcher(transport: Self.transport([Self.playlistURL.absoluteString: playlist, Self.segmentHost + "0.webvtt": big]))
                .cues(playlist: Self.playlistURL)
        }
        await #expect(throws: TrackFetcher.FetchError.self) {
            _ = try await TrackFetcher(transport: Self.transport([Self.playlistURL.absoluteString: playlist])).cues(playlist: Self.playlistURL)
        }
        let many = "#EXTM3U\n" + String(repeating: "#EXTINF:1,\n\(Self.segmentHost)s.webvtt\n", count: MoviePackageReader.maxFragments + 1)
        let transport = Self.transport([Self.playlistURL.absoluteString: many, Self.segmentHost + "s.webvtt": "WEBVTT\n"])
        await #expect(throws: TrackFetcher.FetchError.self) {
            _ = try await TrackFetcher(transport: transport).cues(playlist: Self.playlistURL)
        }
        #expect(transport.requests.withLock { $0.count } == 1)
    }
}
