import Foundation

/// Gemini model listing and key checks. Generation goes through `LanguageModelProvider`.
public enum GeminiProvider {
    public static let host = "generativelanguage.googleapis.com"
    /// Model ids with these words make speech, images or audio, or need special tools.
    static let nonText = ["tts", "image", "audio", "live", "customtools", "robotics", "computer-use"]
    static let base = URL(string: "https://\(host)/v1beta/")!

    /// Model ids that support `generateContent` and return text, sorted.
    public static func listModels(apiKey: String, transport: HTTPTransport) async throws -> [String] {
        var components = URLComponents(url: base.appending(path: "models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "pageSize", value: "1000")]
        var request = URLRequest(url: components.url!)
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        struct List: Decodable {
            struct Model: Decodable {
                var name: String
                var supportedGenerationMethods: [String]?
            }
            var models: [Model]?
        }
        let data = try await ProviderError.send(request, service: "Gemini", transport: transport)
        let list = try JSONDecoder().decode(List.self, from: data)
        return (list.models ?? [])
            .filter { $0.supportedGenerationMethods?.contains("generateContent") == true && $0.name.hasPrefix("models/gemini-") }
            .filter { model in !nonText.contains { model.name.contains($0) } }
            .map { String($0.name.dropFirst("models/".count)) }
            .sorted()
    }

    /// Stable `gemini-<version>-flash` ids, newest first.
    public static func flashCandidates(from models: [String]) -> [String] {
        models.compactMap { id -> (version: [Int], id: String)? in
            guard let m = id.wholeMatch(of: /gemini-(\d+(?:\.\d+)*)-flash/) else { return nil }
            return (m.1.split(separator: ".").compactMap { Int($0) }, id)
        }
        .sorted { $1.version.lexicographicallyPrecedes($0.version) }
        .map(\.id)
    }

    /// The newest stable flash this key may use. A key can list models it has no quota for,
    /// so each candidate gets one tiny request. Throws the last error when none answers.
    public static func firstUsableModel(from models: [String], apiKey: String,
                                        session: URLSession = HTTPClient.lockedSession()) async throws -> String {
        try await LanguageModelProvider.firstAnswering(flashCandidates(from: models), service: .gemini, apiKey: apiKey, session: session,
                                                       none: "No Gemini Flash model is available for this key.")
    }

    /// Checks a key against a model with one tiny request. An empty `model` means the newest
    /// stable flash the key may use. Returns the key's model list and the model that answered.
    public static func authenticate(apiKey: String, model: String, transport: HTTPTransport,
                                    session: URLSession = HTTPClient.lockedSession()) async throws -> (models: [String], model: String) {
        let models = try await listModels(apiKey: apiKey, transport: transport)
        if model.isEmpty { return (models, try await firstUsableModel(from: models, apiKey: apiKey, session: session)) }
        try await LanguageModelProvider(service: .gemini, apiKey: apiKey, model: model, session: session).ping()
        return (models, model)
    }
}
