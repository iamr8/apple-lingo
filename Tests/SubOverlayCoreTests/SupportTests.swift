import Foundation
import Testing
@testable import SubOverlayCore

struct KeychainTests {
    let keychain = Keychain(service: "local.SubOverlay.tests.\(UUID().uuidString)")

    // Breaks if set does not replace an existing value, or delete leaves it behind.
    @Test func setReplaceGetDelete() throws {
        defer { try? keychain.delete("k") }
        #expect(try keychain.get("k") == nil)
        try keychain.set("one", for: "k")
        try keychain.set("two", for: "k")
        #expect(try keychain.get("k") == "two")
        try keychain.delete("k")
        #expect(try keychain.get("k") == nil)
    }
}

struct HTTPClientTests {
    // Breaks if a request to another origin is sent.
    @Test func refusesOtherOrigin() async {
        let client = HTTPClient(allowedHost: "generativelanguage.googleapis.com")
        let req = URLRequest(url: URL(string: "https://example.com/x")!)
        await #expect(throws: HTTPClient.HTTPError.self) { try await client.send(req) }
    }

    // Breaks if the session the AI library uses follows a redirect, which could send the key elsewhere.
    @Test func lockedSessionRefusesRedirects() async throws {
        let (session, _) = StubURLProtocol.session { req in
            req.url?.host() == "api.openai.com"
                ? .init(status: 302, body: "", headers: ["Location": "https://example.com/steal"])
                : .init(status: 200, body: "followed")
        }
        let (data, response) = try await session.data(for: URLRequest(url: URL(string: "https://api.openai.com/v1/x")!))
        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(String(decoding: data, as: UTF8.self) != "followed")
    }

    // Breaks if the AI library's session caches responses or stores cookies.
    @Test func lockedSessionKeepsNothing() {
        let config = HTTPClient.lockedConfiguration()
        #expect(config.urlCache == nil)
        #expect(config.httpCookieStorage == nil)
        #expect(config.urlCredentialStorage == nil)
    }

    // Breaks if plain http is allowed.
    @Test func refusesPlainHTTP() async {
        let client = HTTPClient(allowedHost: "generativelanguage.googleapis.com")
        let req = URLRequest(url: URL(string: "http://generativelanguage.googleapis.com/x")!)
        await #expect(throws: HTTPClient.HTTPError.self) { try await client.send(req) }
    }
}

struct HostRuleTests {
    // Breaks if a domain rule lets a look-alike host through, or refuses a host under the domain.
    @Test func suffixRule() {
        let apple = HTTPClient.HostRule.suffix(".apple.com")
        #expect(apple.allows("download-ap-aoc.tv.apple.com"))
        #expect(apple.allows("play-edge.itunes.apple.com"))
        #expect(!apple.allows("apple.com.evil.example"))
        #expect(!apple.allows("evil-apple.com"))
        #expect(!apple.allows("apple.com"))
        #expect(HTTPClient.HostRule.exact("a.example").allows("a.example"))
        #expect(!HTTPClient.HostRule.exact("a.example").allows("b.a.example"))
    }
}
