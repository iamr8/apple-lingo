import Foundation
import Testing
@testable import AppleLingoCore

struct OpenAIProviderTests {
    // Breaks if non-chat models are offered, or the automatic choice is not the newest mini first.
    @Test func modelListAndCandidates() async throws {
        let body = #"{"data":[{"id":"gpt-4o"},{"id":"gpt-4.1-mini"},{"id":"gpt-5-mini"},{"id":"gpt-5.1-mini"},{"id":"gpt-4o-audio-preview"},{"id":"dall-e-3"},{"id":"gpt-5.1"},{"id":"gpt-image-1"}]}"#
        let models = try await OpenAIProvider.listModels(apiKey: "k", transport: StubTransport { _ in (200, body) })
        #expect(models == ["gpt-4.1-mini", "gpt-4o", "gpt-5-mini", "gpt-5.1", "gpt-5.1-mini"])
        #expect(OpenAIProvider.miniCandidates(from: models) == ["gpt-5.1-mini", "gpt-5-mini", "gpt-4.1-mini"])
    }

    // Breaks if Authenticate with the automatic model does not ping and pick the first mini that answers.
    @Test func authenticatePicksUsableModel() async throws {
        let list = #"{"data":[{"id":"gpt-5-mini"},{"id":"gpt-5.1-mini"}]}"#
        let (session, _) = StubURLProtocol.session { req in
            let body = String(decoding: req.httpBody ?? Data(), as: UTF8.self)
            return body.contains("gpt-5.1-mini") ? .init(status: 404, body: #"{"error":{"message":"model not found"}}"#)
                : LanguageModelProviderTests.openAI(#"{"reply":"ok"}"#)
        }
        let result = try await OpenAIProvider.authenticate(apiKey: "k", model: "", transport: StubTransport { _ in (200, list) }, session: session)
        #expect(result.model == "gpt-5-mini")
        #expect(result.models == ["gpt-5-mini", "gpt-5.1-mini"])
    }
}
