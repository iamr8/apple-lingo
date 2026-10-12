import AnyLanguageModel
import Foundation
import Testing
@testable import SubOverlayCore

/// AnyLanguageModel also has a `JSONValue`; tests mean ours.
typealias JSONValue = SubOverlayCore.JSONValue

struct LanguageModelProviderTests {
    @Generable struct Reply {
        var tone: String
    }

    static func gemini(_ text: String) -> StubURLProtocol.Reply {
        let body: JSONValue = .object(["candidates": .array([.object(["content": .object([
            "role": .string("model"), "parts": .array([.object(["text": .string(text)])]),
        ])])])])
        return .init(status: 200, body: String(decoding: try! JSONEncoder().encode(body), as: UTF8.self))
    }

    static func openAI(_ text: String) -> StubURLProtocol.Reply {
        let body: JSONValue = .object(["id": .string("x"), "object": .string("chat.completion"), "created": .number(0),
                                       "model": .string("gpt-9-mini"), "choices": .array([.object([
            "index": .number(0), "finish_reason": .string("stop"),
            "message": .object(["role": .string("assistant"), "content": .string(text)]),
        ])])])
        return .init(status: 200, body: String(decoding: try! JSONEncoder().encode(body), as: UTF8.self))
    }

    static func body(_ request: URLRequest) throws -> [String: JSONValue] {
        guard case .object(let o) = try JSONDecoder().decode(JSONValue.self, from: try #require(request.httpBody)) else { return [:] }
        return o
    }

    // Breaks if the key leaves its header, the system prompt is not sent as instructions, the schema
    // is not native, or the JSON reply is changed.
    @Test func geminiRequest() async throws {
        let (session, id) = StubURLProtocol.session { _ in Self.gemini(#"{"tone":"dry"}"#) }
        let provider = try LanguageModelProvider(service: .gemini, apiKey: "SECRET", model: "gemini-9.0-flash", session: session)
        let out = try await provider.complete(system: "sys prompt", user: "usr", schema: Reply.generationSchema)
        #expect(try JSONDecoder().decode(JSONValue.self, from: out) == .object(["tone": .string("dry")]))

        let req = try #require(StubURLProtocol.recorded(id).first)
        #expect(req.url?.absoluteString == "https://generativelanguage.googleapis.com/v1beta/models/gemini-9.0-flash:generateContent")
        #expect(req.value(forHTTPHeaderField: "x-goog-api-key") == "SECRET")
        #expect(req.url?.query == nil)
        let body = try Self.body(req)
        // The library sends instructions as the first user turn; the provider moves them into
        // systemInstruction, where Gemini's prohibited-content filter lets a subtitle chunk pass.
        guard case .object(let instruction)? = body["systemInstruction"], case .array(let parts)? = instruction["parts"],
              case .object(let part)? = parts.first
        else { Issue.record("no systemInstruction"); return }
        #expect(part["text"] == .string("sys prompt"))
        guard case .array(let contents)? = body["contents"] else { Issue.record("no contents"); return }
        #expect(contents.count == 1)
        #expect(String(describing: contents).contains("usr") && !String(describing: contents).contains("sys prompt"))
        guard case .object(let config)? = body["generationConfig"] else { Issue.record("no config"); return }
        #expect(config["responseMimeType"] == .string("application/json"))
        #expect(config["responseSchema"] != nil)
        #expect(!String(describing: body["contents"]).contains("tone"), "schema must not be pasted into the prompt")
    }

    // Breaks if the first user turn is not moved into systemInstruction, or a body with one turn,
    // with an instruction already, or without JSON is changed.
    @Test func rewriteMovesFirstUserTurn() throws {
        func json(_ s: String) -> Data { Data(s.utf8) }
        let two = json(#"{"contents":[{"role":"user","parts":[{"text":"sys"}]},{"role":"user","parts":[{"text":"usr"}]}],"generationConfig":{"temperature":0.2}}"#)
        let out = try JSONDecoder().decode(JSONValue.self, from: GeminiInstructionsProtocol.rewritten(two))
        #expect(out == .object([
            "systemInstruction": .object(["parts": .array([.object(["text": .string("sys")])])]),
            "contents": .array([.object(["role": .string("user"), "parts": .array([.object(["text": .string("usr")])])])]),
            "generationConfig": .object(["temperature": .number(0.2)]),
        ]))
        let one = json(#"{"contents":[{"role":"user","parts":[{"text":"usr"}]}]}"#)
        #expect(GeminiInstructionsProtocol.rewritten(one) == one)
        let set = json(#"{"systemInstruction":{"parts":[]},"contents":[{"role":"user","parts":[]},{"role":"user","parts":[]}]}"#)
        #expect(GeminiInstructionsProtocol.rewritten(set) == set)
        #expect(GeminiInstructionsProtocol.rewritten(json("nope")) == json("nope"))
    }

    // Breaks if OpenAI is not asked for a strict JSON schema, or the key is not a bearer header.
    @Test func openAIRequest() async throws {
        let (session, id) = StubURLProtocol.session { _ in Self.openAI(#"{"tone":"dry"}"#) }
        let provider = try LanguageModelProvider(service: .openAI, apiKey: "SECRET", model: "gpt-9-mini", session: session)
        let out = try await provider.complete(system: "sys prompt", user: "usr", schema: Reply.generationSchema)
        #expect(try JSONDecoder().decode(JSONValue.self, from: out) == .object(["tone": .string("dry")]))

        let req = try #require(StubURLProtocol.recorded(id).first)
        #expect(req.url?.absoluteString == "https://api.openai.com/v1/chat/completions")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer SECRET")
        let body = try Self.body(req)
        guard case .object(let format)? = body["response_format"], case .object(let spec)? = format["json_schema"] else {
            Issue.record("no json_schema")
            return
        }
        #expect(spec["strict"] == .bool(true))
        #expect(body["temperature"] == nil, "reasoning models reject temperature")
        #expect(String(describing: body["messages"]).contains("sys prompt"))
    }

    // Breaks if a free-tier quota error does not say so, which hides why a paid account fails.
    @Test func freeTierErrorIsExplained() async throws {
        let body = """
        {"error":{"code":429,"message":"You exceeded your current quota.",
          "details":[{"@type":"type.googleapis.com/google.rpc.QuotaFailure","violations":[{
            "quotaId":"GenerateRequestsPerDayPerProjectPerModel-FreeTier","quotaValue":"20"}]}]}}
        """
        let (session, _) = StubURLProtocol.session { _ in .init(status: 429, body: body) }
        let provider = try LanguageModelProvider(service: .gemini, apiKey: "k", model: "gemini-9.0-flash", session: session)
        do {
            _ = try await provider.complete(system: "s", user: "u", schema: Reply.generationSchema)
            Issue.record("no error")
        } catch {
            #expect(error is ProviderError)
            #expect(error.localizedDescription.contains("free tier"))
            #expect(error.localizedDescription.contains("20 requests per day"))
        }
    }

    // Breaks if OpenAI's error message (quota, unknown model) is lost.
    @Test func openAIErrorKeepsMessage() async throws {
        let (session, _) = StubURLProtocol.session { _ in
            .init(status: 404, body: #"{"error":{"message":"The model gpt-9-mini does not exist.","code":"model_not_found"}}"#)
        }
        let provider = try LanguageModelProvider(service: .openAI, apiKey: "k", model: "gpt-9-mini", session: session)
        do {
            _ = try await provider.complete(system: "s", user: "u", schema: Reply.generationSchema)
            Issue.record("no error")
        } catch {
            #expect(error.localizedDescription == "OpenAI returned HTTP 404. The model gpt-9-mini does not exist.")
        }
    }

    // Breaks if a Gemini reply with no candidate (a content filter, or nothing to say) reaches
    // the user as "GeminiError error 0".
    @Test func geminiNoCandidateIsPlain() async throws {
        let (session, _) = StubURLProtocol.session { _ in .init(status: 200, body: #"{"candidates":[]}"#) }
        let provider = try LanguageModelProvider(service: .gemini, apiKey: "k", model: "gemini-9.0-flash", session: session)
        do {
            _ = try await provider.complete(system: "s", user: "u", schema: Reply.generationSchema)
            Issue.record("no error")
        } catch {
            #expect(error is ProviderError)
            #expect(error.localizedDescription == "The model returned no answer. It may have filtered the content.")
        }
    }

    // Breaks if a model id can change the URL path.
    @Test func rejectsBadModelID() {
        #expect(throws: ProviderError.self) {
            _ = try LanguageModelProvider(service: .gemini, apiKey: "k", model: "../x")
        }
        #expect(throws: ProviderError.self) {
            _ = try LanguageModelProvider(service: .openAI, apiKey: "k", model: "gpt 5\n")
        }
    }
}
