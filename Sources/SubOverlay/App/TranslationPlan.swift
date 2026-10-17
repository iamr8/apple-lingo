import Foundation
import SubOverlayCore

/// The languages of a title's translation, from its Apple tracks and the Settings languages:
/// the primary (the title's main language) gives the meaning, the secondary gives the timing
/// and a guide, the target is the user's. Or the problem that stops it.
struct TranslationPlan: Equatable {
    struct Settings: Equatable {
        static let automatic = ""
        static let sameAsMain = "same"
        /// Automatic, the main language, or a language code.
        var secondary = automatic
        var target: String
    }

    enum Problem: Equatable, Error {
        /// The title ships the target language; the value is Apple's track.
        case shipsTarget(String)
        case noPrimary
        case secondaryMissing(String)

        func notice(title: String) -> String {
            switch self {
            case .shipsTarget(let track): "\(title) already has \(Languages.name(track)) subtitles in the TV app."
            case .noPrimary: "No subtitle track of \(title) could be read. Press Download on it again."
            case .secondaryMissing(let code):
                "\(title) has no \(Languages.name(code)) track. Change the secondary language in Settings, then play it again."
            }
        }
    }

    var base: String
    var timing: String
    var target: String

    /// The track of the title's original language (exact code, else the same base), else
    /// English, else the first track.
    static func primary(apple: [String], original: String?) -> String? {
        original.flatMap { track($0, in: apple) } ?? track("en", in: apple) ?? apple.first
    }

    static func make(apple: [String], original: String?, settings: Settings) -> Result<TranslationPlan, Problem> {
        if let shipped = track(settings.target, in: apple) { return .failure(.shipsTarget(shipped)) }
        guard let base = primary(apple: apple, original: original) else { return .failure(.noPrimary) }
        let timing: String
        switch settings.secondary {
        case Settings.automatic: timing = automaticTiming(apple: apple, base: base, target: settings.target)
        case Settings.sameAsMain: timing = base
        default:
            guard let chosen = track(settings.secondary, in: apple) else { return .failure(.secondaryMissing(settings.secondary)) }
            timing = chosen
        }
        return .success(TranslationPlan(base: base, timing: timing, target: settings.target))
    }

    /// For a right-to-left target, a right-to-left track (Arabic first), whose cues split the
    /// dialogue the way the target reads; else the primary.
    static func automaticTiming(apple: [String], base: String, target: String) -> String {
        guard Languages.isRightToLeft(target) else { return base }
        let rightToLeft = apple.filter(Languages.isRightToLeft)
        return rightToLeft.first { Languages.base($0) == "ar" } ?? rightToLeft.first ?? base
    }

    /// The track with `code`, else one with the same base (`fr` finds `fr-FR`).
    private static func track(_ code: String, in apple: [String]) -> String? {
        apple.first { $0 == code } ?? apple.first { Languages.base($0) == Languages.base(code) }
    }
}
