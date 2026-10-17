import Foundation
@testable import SubOverlayCore
import Testing
@testable import SubOverlay

struct TranslationPlanTests {
    func settings(_ secondary: String = "", target: String = "fa") -> TranslationPlan.Settings {
        TranslationPlan.Settings(secondary: secondary, target: target)
    }

    // Breaks if the primary is not the original language's track (exact code, else the same
    // base), else English, else the first track; or a title with no track gets one.
    @Test func primaryTrack() {
        #expect(TranslationPlan.primary(apple: ["en", "fr-FR"], original: "fr-FR") == "fr-FR")
        #expect(TranslationPlan.primary(apple: ["en", "fr-FR"], original: "fr") == "fr-FR")
        #expect(TranslationPlan.primary(apple: ["en", "fr-FR"], original: "de") == "en")
        #expect(TranslationPlan.primary(apple: ["ar", "fr-FR"], original: nil) == "ar")
        #expect(TranslationPlan.primary(apple: [], original: "en") == nil)
    }

    // Breaks if a title that ships the target (exact code or the same base) gets a translation,
    // or a title with no track gets one.
    @Test func problemsStopThePlan() {
        #expect(TranslationPlan.make(apple: ["en", "fa"], original: "en", settings: settings()) == .failure(.shipsTarget("fa")))
        #expect(TranslationPlan.make(apple: ["en", "pt-BR"], original: "en", settings: settings(target: "pt")) == .failure(.shipsTarget("pt-BR")))
        #expect(TranslationPlan.make(apple: [], original: "en", settings: settings()) == .failure(.noPrimary))
    }

    // Breaks if automatic timing is not a right-to-left Apple track (Arabic first) for a
    // right-to-left target, or not the primary otherwise.
    @Test func automaticSecondaryFollowsTheTargetsDirection() {
        #expect(TranslationPlan.make(apple: ["en", "he", "ar", "de"], original: "en", settings: settings())
                == .success(TranslationPlan(base: "en", timing: "ar", target: "fa")))
        #expect(TranslationPlan.make(apple: ["en", "he"], original: "en", settings: settings())
                == .success(TranslationPlan(base: "en", timing: "he", target: "fa")))
        #expect(TranslationPlan.make(apple: ["en", "de"], original: "en", settings: settings())
                == .success(TranslationPlan(base: "en", timing: "en", target: "fa")))
        #expect(TranslationPlan.make(apple: ["en", "ar"], original: "en", settings: settings(target: "it"))
                == .success(TranslationPlan(base: "en", timing: "en", target: "it")))
    }

    // Breaks if "Same as main language" does not time by the primary, or a chosen secondary
    // is not matched by base (fr finds fr-FR), or a chosen secondary the title lacks runs anyway.
    @Test func chosenSecondary() {
        #expect(TranslationPlan.make(apple: ["en", "ar"], original: "en", settings: settings(TranslationPlan.Settings.sameAsMain))
                == .success(TranslationPlan(base: "en", timing: "en", target: "fa")))
        #expect(TranslationPlan.make(apple: ["en", "fr-FR"], original: "en", settings: settings("fr"))
                == .success(TranslationPlan(base: "en", timing: "fr-FR", target: "fa")))
        #expect(TranslationPlan.make(apple: ["en", "fr-FR"], original: "en", settings: settings("ar")) == .failure(.secondaryMissing("ar")))
    }

    // Breaks if a problem's notice does not name the title, the language and what to do.
    @Test func problemNotices() {
        #expect(TranslationPlan.Problem.shipsTarget("fa").notice(title: "Pilot") == "Pilot already has Persian subtitles in the TV app.")
        #expect(TranslationPlan.Problem.noPrimary.notice(title: "Pilot") == "No subtitle track of Pilot could be read. Press Download on it again.")
        #expect(TranslationPlan.Problem.secondaryMissing("ar").notice(title: "Pilot")
                == "Pilot has no Arabic track. Change the secondary language in Settings, then play it again.")
    }
}
