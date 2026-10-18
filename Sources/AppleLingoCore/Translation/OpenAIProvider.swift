import Foundation

/// OpenAI model listing and key checks. Generation goes through `LanguageModelProvider`.
public enum OpenAIProvider {
    public static let host = "api.openai.com"
    static let base = URL(string: "https://\(host)/v1/")!
    /// Model ids with these words are not chat models.
    static let nonChat = ["audio", "realtime", "image", "tts", "transcribe", "search", "instruct"]

    /// Chat model ids, sorted.
    public static func listModels(apiKey: String, transport: HTTPTransport) async throws -> [String] {
        var request = URLRequest(url: base.appending(path: "models"))
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        struct List: Decodable {
            struct Model: Decodable { var id: String }
            var data: [Model]?
        }
        let data = try await ProviderError.send(request, service: "OpenAI", transport: transport)
        return (try JSONDecoder().decode(List.self, from: data).data ?? []).map(\.id)
            .filter { id in id.hasPrefix("gpt-") && !nonChat.contains { id.contains($0) } }
            .sorted()
    }

    /// `gpt-<version>-mini` ids, newest first.
    public static func miniCandidates(from models: [String]) -> [String] {
        models.compactMap { id -> (version: [Int], id: String)? in
            guard let m = id.wholeMatch(of: /gpt-(\d+(?:\.\d+)*)-mini/) else { return nil }
            return (m.1.split(separator: ".").compactMap { Int($0) }, id)
        }
        .sorted { $1.version.lexicographicallyPrecedes($0.version) }
        .map(\.id)
    }

    /// Checks a key against a model with one tiny request. An empty `model` means the newest
    /// `gpt-*-mini` the key may use. Returns the key's model list and the model that answered.
    public static func authenticate(apiKey: String, model: String, transport: HTTPTransport,
                                    session: URLSession = HTTPClient.lockedSession()) async throws -> (models: [String], model: String) {
        let models = try await listModels(apiKey: apiKey, transport: transport)
        if !model.isEmpty {
            try await LanguageModelProvider(service: .openAI, apiKey: apiKey, model: model, session: session).ping()
            return (models, model)
        }
        let id = try await LanguageModelProvider.firstAnswering(miniCandidates(from: models), service: .openAI, apiKey: apiKey,
                                                                session: session, none: "No GPT mini model is available for this key.")
        return (models, id)
    }
}
