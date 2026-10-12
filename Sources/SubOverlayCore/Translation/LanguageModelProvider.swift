import AnyLanguageModel
import Foundation

/// A model that returns JSON matching a schema.
public protocol TranslationProvider: Sendable {
    func complete(system: String, user: String, schema: GenerationSchema) async throws -> Data
}

/// Errors from a translation service, with the server's reason when it gave one.
public enum ProviderError: Error, LocalizedError {
    case badModelID
    case http(service: String, status: Int, message: String?)
    case emptyReply

    public var errorDescription: String? {
        switch self {
        case .badModelID: "The model name is not valid."
        case .http(let service, let status, let message): "\(service) returned HTTP \(status)." + (message.map { " \($0)" } ?? "")
        case .emptyReply: "The model returned no answer. It may have filtered the content."
        }
    }

    /// An HTTP error with the reason from an error body (`{"error":{"message":...}}`). A Gemini
    /// free-tier quota is named, because on a paid account it means the project has no billing.
    static func http(service: String, status: Int, body: Data) -> ProviderError {
        struct ErrorBody: Decodable {
            struct Inner: Decodable {
                var message: String?
                var details: [Detail]?
            }
            struct Detail: Decodable { var violations: [Violation]? }
            struct Violation: Decodable {
                var quotaId: String?
                var quotaValue: String?
            }
            var error: Inner?
        }
        let error = try? JSONDecoder().decode(ErrorBody.self, from: body).error
        if let free = error?.details?.lazy.compactMap(\.violations).joined().first(where: { $0.quotaId?.hasSuffix("FreeTier") == true }) {
            let per = free.quotaId?.contains("PerDay") == true ? "day" : "minute"
            return .http(service: service, status: status, message:
                "This key's Google Cloud project uses the Gemini API free tier (\(free.quotaValue ?? "a few") requests per \(per) per model). "
                + "Link a billing account to that project in Google AI Studio, or use a key from a project with billing.")
        }
        return .http(service: service, status: status, message: error?.message.map { String($0.prefix(300)) })
    }

    /// Sends a request through `transport` and returns the body of a 200 reply.
    static func send(_ request: URLRequest, service: String, transport: HTTPTransport) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else { throw http(service: service, status: response.statusCode, body: data) }
        return data
    }
}

/// Gemini or OpenAI through AnyLanguageModel. The library builds the requests and native
/// schemas; the session is ours (no cache, no cookies, no redirects).
public struct LanguageModelProvider: TranslationProvider {
    public enum Service: Sendable {
        case gemini
        case openAI

        var name: String { self == .gemini ? "Gemini" : "OpenAI" }
    }

    private let service: Service
    private let model: any LanguageModel

    public init(service: Service, apiKey: String, model: String, session: URLSession = HTTPClient.lockedSession()) throws {
        guard model.wholeMatch(of: /[A-Za-z0-9][A-Za-z0-9._:\-]{0,99}/) != nil else { throw ProviderError.badModelID }
        self.service = service
        switch service {
        case .gemini: self.model = GeminiLanguageModel(apiKey: apiKey, model: model, session: session)
        case .openAI: self.model = OpenAILanguageModel(apiKey: apiKey, model: model, session: session)
        }
    }

    public func complete(system: String, user: String, schema: GenerationSchema) async throws -> Data {
        let session = LanguageModelSession(model: model, instructions: system)
        // OpenAI reasoning models reject a temperature; Gemini keeps a low one for steady wording.
        let options = service == .gemini ? GenerationOptions(temperature: 0.2) : GenerationOptions()
        do {
            let response = try await session.respond(to: user, schema: schema, includeSchemaInPrompt: false, options: options)
            return Data(response.content.jsonString.utf8)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Self.mapped(error, service: service)
        }
    }

    /// One tiny request; throws when the key may not use the model.
    func ping() async throws {
        _ = try await complete(system: "Answer with the word ok.", user: "ok", schema: Pong.generationSchema)
    }

    /// The first model in `ids` that answers a ping. Throws the last error when none answers.
    static func firstAnswering(_ ids: [String], service: Service, apiKey: String, session: URLSession, none: String) async throws -> String {
        var lastError: Error = ProviderError.http(service: service.name, status: 404, message: none)
        for id in ids {
            do {
                try await LanguageModelProvider(service: service, apiKey: apiKey, model: id, session: session).ping()
                return id
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Log.translation.error("model \(id, privacy: .public) not usable")
                lastError = error
            }
        }
        throw lastError
    }

    /// The library reports HTTP failures as "HTTP error (Status N): <body>"; this keeps the
    /// status and the server's reason. A Gemini reply with no candidate (a content filter, or
    /// nothing to say) is the library's internal `GeminiError.noCandidate`, known by its text.
    static func mapped(_ error: Error, service: Service) -> Error {
        let text = String(describing: error)
        if text == "No candidate in response" { return ProviderError.emptyReply }
        guard let m = text.firstMatch(of: /HTTP error \(Status (\d{3})\): (.*)/.dotMatchesNewlines()), let status = Int(m.1) else {
            return error
        }
        return ProviderError.http(service: service.name, status: status, body: Data(m.2.utf8))
    }
}

@Generable
struct Pong {
    var reply: String
}
