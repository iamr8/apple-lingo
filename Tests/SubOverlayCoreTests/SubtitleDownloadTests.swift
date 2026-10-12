import Foundation
import Testing
@testable import SubOverlayCore

struct SubtitleDownloadTests {
    static let body = "1\n00:00:01,000 --> 00:00:02,000\nسلام\n"

    // Breaks if a plain http link is fetched, so a network attacker could swap the file.
    @Test func refusesPlainHTTP() async {
        let (config, id) = StubURLProtocol.configuration { _ in .init(status: 200, body: Self.body) }
        await #expect(throws: SubtitleDownload.DownloadError.notHTTPS) {
            _ = try await SubtitleDownload.fetch(URL(string: "http://example.com/a.srt")!, configuration: config)
        }
        #expect(StubURLProtocol.recorded(id).isEmpty)
    }

    // Breaks if an https redirect (common on file hosts) is not followed, or one to http is.
    @Test func followsOnlyHTTPSRedirects() async throws {
        let (config, _) = StubURLProtocol.configuration { req in
            switch req.url!.path {
            case "/a": .init(status: 302, body: "", headers: ["Location": "https://files.example.com/b.srt"])
            case "/c": .init(status: 302, body: "", headers: ["Location": "http://files.example.com/b.srt"])
            default: .init(status: 200, body: Self.body)
            }
        }
        let data = try await SubtitleDownload.fetch(URL(string: "https://example.com/a")!, configuration: config)
        #expect(String(decoding: data, as: UTF8.self) == Self.body)
        await #expect(throws: (any Error).self) {
            _ = try await SubtitleDownload.fetch(URL(string: "https://example.com/c")!, configuration: config)
        }
    }

    // Breaks if a file over 2 MB is read into memory whole, or an error page passes as a file.
    @Test func refusesLargeOrFailed() async {
        let (big, _) = StubURLProtocol.configuration { _ in .init(status: 200, body: String(repeating: "x", count: SubtitleFile.maxBytes + 1)) }
        await #expect(throws: SubtitleDownload.DownloadError.tooLarge) {
            _ = try await SubtitleDownload.fetch(URL(string: "https://example.com/a.srt")!, configuration: big)
        }
        let (missing, _) = StubURLProtocol.configuration { _ in .init(status: 404, body: "not found") }
        await #expect(throws: SubtitleDownload.DownloadError.http(404)) {
            _ = try await SubtitleDownload.fetch(URL(string: "https://example.com/a.srt")!, configuration: missing)
        }
    }
}
