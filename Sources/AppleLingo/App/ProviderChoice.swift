import Foundation
import AppleLingoCore

/// The translation services the user can pick. Keys live in the Keychain, models in UserDefaults.
enum ProviderChoice: String, CaseIterable, Identifiable {
    case gemini
    case openAI = "openai"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .gemini: "Gemini"
        case .openAI: "OpenAI"
        }
    }

    /// Label for the automatic model choice.
    var automaticModel: String {
        switch self {
        case .gemini: "Newest Flash"
        case .openAI: "Newest GPT mini"
        }
    }

    /// Keychain account for the API key. Gemini keeps its original account name.
    var account: String { rawValue }
    var modelKey: String { self == .gemini ? Preferences.geminiModelKey : "\(rawValue)Model" }
    var model: String { UserDefaults.standard.string(forKey: modelKey) ?? "" }

    static let selectedKey = "translationProvider"
    static var selected: ProviderChoice {
        UserDefaults.standard.string(forKey: selectedKey).flatMap(ProviderChoice.init(rawValue:)) ?? .gemini
    }

    func transport() -> HTTPClient {
        HTTPClient(allowedHost: self == .gemini ? GeminiProvider.host : OpenAIProvider.host)
    }

    func listModels(key: String) async throws -> [String] {
        switch self {
        case .gemini: try await GeminiProvider.listModels(apiKey: key, transport: transport())
        case .openAI: try await OpenAIProvider.listModels(apiKey: key, transport: transport())
        }
    }

    /// One tiny request to `model` (empty: the automatic choice). Returns the key's models and the model that answered.
    func authenticate(key: String, model: String) async throws -> (models: [String], model: String) {
        switch self {
        case .gemini: try await GeminiProvider.authenticate(apiKey: key, model: model, transport: transport())
        case .openAI: try await OpenAIProvider.authenticate(apiKey: key, model: model, transport: transport())
        }
    }

    /// A provider for translation; an empty `model` is resolved to the automatic choice first.
    func provider(key: String, model: String) async throws -> TranslationProvider {
        var id = model
        if id.isEmpty { id = try await authenticate(key: key, model: "").model }
        return try LanguageModelProvider(service: self == .gemini ? .gemini : .openAI, apiKey: key, model: id)
    }
}
