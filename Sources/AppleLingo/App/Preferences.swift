import Foundation
import KeyboardShortcuts
import AppleLingoCore

/// Non-secret settings in UserDefaults. The API key lives in the Keychain only.
enum Preferences {
    static let defaultTargetKey = "defaultTargetLanguage"
    static let secondaryLanguageKey = "secondaryLanguage"
    static let geminiModelKey = "geminiModel"

    static var defaultTarget: String { UserDefaults.standard.string(forKey: defaultTargetKey) ?? "fa" }

    /// The languages every title is translated with.
    static var languages: TranslationPlan.Settings {
        TranslationPlan.Settings(secondary: UserDefaults.standard.string(forKey: secondaryLanguageKey) ?? TranslationPlan.Settings.automatic,
                                 target: defaultTarget)
    }
}

@MainActor
extension KeyboardShortcuts.Name {
    static let offsetMinusSmall = Self("offsetMinus100")
    static let offsetPlusSmall = Self("offsetPlus100")
    static let offsetMinusLarge = Self("offsetMinus500")
    static let offsetPlusLarge = Self("offsetPlus500")
    static let nudgeUp = Self("nudgeUp")
    static let nudgeDown = Self("nudgeDown")
}

/// Language codes and names for pickers.
enum Languages {
    /// Every language the system can name, sorted by display name.
    static let all: [String] = {
        let codes = Set(Locale.availableIdentifiers.compactMap { Locale(identifier: $0).language.languageCode?.identifier })
        return codes.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }()

    static func name(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    /// `fr-FR` → `fr`.
    static func base(_ code: String) -> String {
        Locale(identifier: code).language.languageCode?.identifier ?? code
    }

    static func isRightToLeft(_ code: String) -> Bool {
        Locale.Language(identifier: code).characterDirection == .rightToLeft
    }
}
