import Foundation
@testable import SubOverlayCore
import Testing
@testable import SubOverlay

private func meta(_ apple: [String], base: String? = nil, timing: String? = nil, target: String? = nil, original: String? = nil) -> TitleMeta {
    var m = TitleMeta(title: "Pilot", album: "Black Bird", appleLanguages: apple, sourcePackage: "Pilot.tmp")
    m.baseLanguage = base
    m.timingLanguage = timing
    m.targetLanguage = target
    m.originalLanguage = original
    return m
}

struct TitlePartsTextTests {
    // Breaks if times do not read like the player's scrubber (m:ss, h:mm:ss past an hour).
    @Test func clockReadsLikeThePlayer() {
        #expect(TitlePartsText.clock(8.126) == "0:08")
        #expect(TitlePartsText.clock(3568.106) == "59:28")
        #expect(TitlePartsText.clock(3725.9) == "1:02:05")
    }

    // Breaks if a part is named other than in the user's words.
    @Test func partNames() {
        #expect([TitlePart.Kind.intro, .recap, .content, .after].map(TitlePartsText.name) == ["Intro", "Recap", "Content", "After content"])
    }

    // Breaks if the span of the translation is not from its first line's start to its last line's end.
    @Test func translationSpan() {
        let cues = [Cue(id: 1, start: 9.126, end: 11, text: "a"), Cue(id: 2, start: 3500, end: 3514.2, text: "b")]
        #expect(TitlePartsText.span(cues) == "0:09 - 58:34")
        #expect(TitlePartsText.span([]) == nil)
    }
}

struct AddSubtitlesDefaultsTests {
    // Breaks if English is not the default base when Apple ships it and the original is unknown,
    // or timing is not automatic.
    @Test func englishIsDefaultBase() {
        let d = AddSubtitlesDefaults(meta(["ar", "en", "fr-FR"]), preferredTarget: "fa")
        #expect(d.base == "en")
        #expect(d.timing == "")
        #expect(d.target == "fa")
    }

    // Breaks if the film's original language ("fr" audio) does not win as base over English,
    // matched to Apple's "fr-FR" track.
    @Test func originalLanguageIsDefaultBase() {
        #expect(AddSubtitlesDefaults(meta(["en", "fr-FR"], original: "fr"), preferredTarget: "fa").base == "fr-FR")
    }

    // Breaks if a title without English gets no base.
    @Test func firstTrackIsBaseWithoutEnglish() {
        let d = AddSubtitlesDefaults(meta(["ar", "fr-FR"]), preferredTarget: "fa")
        #expect(d.base == "ar")
    }

    // Breaks if automatic timing is not a right-to-left Apple track (Arabic first) for a
    // right-to-left target, or not the base track otherwise.
    @Test func automaticTimingFollowsTargetDirection() {
        let apple = ["en", "he", "ar", "de"]
        #expect(AddSubtitlesDefaults.timing("", apple: apple, base: "en", target: "fa") == "ar")
        #expect(AddSubtitlesDefaults.timing("", apple: ["en", "he"], base: "en", target: "fa") == "he")
        #expect(AddSubtitlesDefaults.timing("", apple: ["en", "de"], base: "en", target: "fa") == "en")
        #expect(AddSubtitlesDefaults.timing("", apple: apple, base: "en", target: "it") == "en")
        #expect(AddSubtitlesDefaults.timing("de", apple: apple, base: "en", target: "fa") == "de")
    }

    // Breaks if a language Apple ships can be the default target.
    @Test func targetSkipsAppleLanguages() {
        let d = AddSubtitlesDefaults(meta(["en", "fa"]), preferredTarget: "fa")
        #expect(d.target != "fa")
        #expect(!d.target.isEmpty)
    }

    // Breaks if the choices saved for the title do not win over the defaults.
    @Test func savedChoicesWin() {
        let d = AddSubtitlesDefaults(meta(["ar", "en", "fr-FR"], base: "fr-FR", timing: "ar", target: "ku", original: "en"), preferredTarget: "fa")
        #expect(d.base == "fr-FR")
        #expect(d.timing == "ar")
        #expect(d.target == "ku")
    }
}

struct ReplaceHintTests {
    // Breaks if no hint shows for a saved translation, or one shows for an Apple track or a new language.
    @Test func hintOnlyForSavedTranslation() throws {
        let lib = SubtitleLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
        let entry = try lib.ingest(title: "T", album: "A", tracks: ["en": []], sourcePackage: "p")
        try entry.save([], language: "fa")
        #expect(AddSubtitlesDefaults.replaceHint(entry, target: "fa") == "A Persian translation is saved. Translating again replaces it.")
        #expect(AddSubtitlesDefaults.replaceHint(entry, target: "de") == nil)
        #expect(AddSubtitlesDefaults.replaceHint(entry, target: "en") == nil)
    }
}

struct MenuTextTests {
    // Breaks if the show name is dropped or shown for a movie with no album.
    @Test func titleLine() {
        let now = ContinuousClock.now
        #expect(MenuText.title(nil) == "Nothing playing in TV")
        #expect(MenuText.title(PlaybackState(title: "Pilot", album: "Black Bird", elapsedAtAnchor: 0, rate: 1, playing: true, anchor: now))
            == "Black Bird – Pilot")
        #expect(MenuText.title(PlaybackState(title: "Furiosa", album: "", elapsedAtAnchor: 0, rate: 1, playing: true, anchor: now))
            == "Furiosa")
    }

    // Breaks if the status does not follow the most important state first.
    @Test func statusLine() {
        #expect(MenuText.status(adapterFailed: true, translation: nil, playing: true, meta: nil, hasEntry: false) == "Cannot read Now Playing")
        #expect(MenuText.status(adapterFailed: false, translation: .init(title: "t", progress: 0.42), playing: true, meta: nil, hasEntry: true)
            == "Translating… 42%")
        #expect(MenuText.status(adapterFailed: false, translation: nil, playing: false, meta: nil, hasEntry: false) == "Idle")
        #expect(MenuText.status(adapterFailed: false, translation: nil, playing: true, meta: nil, hasEntry: false) == "No subtitles captured")
        #expect(MenuText.status(adapterFailed: false, translation: nil, playing: true, meta: meta(["en"]), hasEntry: true) == "No translation yet")
    }
}

@MainActor
struct AppModelTests {
    let library = SubtitleLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))

    func playing(_ title: String, album: String?) -> PlaybackState {
        PlaybackState(title: title, album: album, elapsedAtAnchor: 0, rate: 1, playing: false, anchor: .now)
    }

    // Breaks if a title without subtitles does not notify once, or notifies on every update.
    @Test func notifiesOncePerTitleWithoutSubtitles() {
        var posted: [String] = []
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { heading, _, _, _ in posted.append(heading) }
        model.update(playing("Pilot", album: "Black Bird"))
        model.update(nil)
        model.update(playing("Pilot", album: "Black Bird"))
        #expect(posted == ["No subtitles for Pilot"])
    }

    // Breaks if the offset is not rounded to 0.1 s and saved to the title's meta.
    @Test func offsetHotkeyPersists() throws {
        var entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        entry.meta.targetLanguage = "en"
        try entry.saveMeta()
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { _, _, _, _ in }
        model.update(playing("Pilot", album: "Black Bird"))
        model.adjust(offset: 0.1)
        model.adjust(offset: 0.1)
        model.adjust(offset: 0.1)
        #expect(model.offset == 0.3)
        #expect(library.entry(album: "Black Bird", title: "Pilot")?.meta.offset == 0.3)
    }

    // Breaks if the menu's reset leaves an offset on the playing title or in its meta.
    @Test func resetOffsetClearsTheTitle() throws {
        var entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        entry.meta.targetLanguage = "en"
        try entry.saveMeta()
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { _, _, _, _ in }
        model.update(playing("Pilot", album: "Black Bird"))
        model.adjust(offset: -2.5)
        model.resetOffset()
        #expect(model.offset == 0)
        #expect(library.entry(album: "Black Bird", title: "Pilot")?.meta.offset == 0)
    }

    // Breaks if translation ignores the provider chosen in Settings and uses the Gemini key.
    @Test func translateUsesSelectedProvider() async throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        let keychain = Keychain(service: "test.\(UUID())")
        try keychain.set("gemini-key", for: ProviderChoice.gemini.account)
        defer { try? keychain.delete(ProviderChoice.gemini.account) }
        let saved = UserDefaults.standard.string(forKey: ProviderChoice.selectedKey)
        UserDefaults.standard.set(ProviderChoice.openAI.rawValue, forKey: ProviderChoice.selectedKey)
        defer { UserDefaults.standard.set(saved, forKey: ProviderChoice.selectedKey) }
        let model = AppModel(library: library, keychain: keychain) { _, _, _, _ in }
        model.translate(entry, base: "en", timing: "", target: "fa")
        for _ in 0..<200 where model.translation?.error == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.translation?.error == "Add an API key for OpenAI in Settings.")
    }

    // Breaks if a finished translation saves the title's settings as they were when it started,
    // so an offset changed while it ran is lost.
    @Test func translationKeepsSettingsChangedMeanwhile() async throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": Array(Self.appleTrack.prefix(5))], sourcePackage: "p")
        let keychain = Keychain(service: "test.\(UUID())")
        for choice in [ProviderChoice.gemini, .openAI] { try keychain.set("key", for: choice.account) }
        defer { for choice in [ProviderChoice.gemini, .openAI] { try? keychain.delete(choice.account) } }
        let provider = GatedProvider()
        let model = AppModel(library: library, keychain: keychain, notify: { _, _, _, _ in }, makeProvider: { _, _, _ in provider })
        model.update(playing("Pilot", album: "Black Bird"))
        model.translate(entry, base: "en", timing: "", target: "fa")
        for _ in 0..<400 where provider.calls.withLock({ $0 }) == 0 { try await Task.sleep(for: .milliseconds(5)) }
        model.adjust(offset: 1.5)
        provider.open()
        for _ in 0..<400 where model.translation != nil { try await Task.sleep(for: .milliseconds(5)) }
        let meta = try #require(library.entry(album: "Black Bird", title: "Pilot")).meta
        #expect(meta.targetLanguage == "fa")
        #expect(meta.offset == 1.5)
    }

    // Breaks if form choices are lost before a translation succeeds, or "Automatic" turns into a fixed track.
    @Test func formChoicesPersist() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": [], "ar": [], "fr-FR": []], sourcePackage: "p")
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { _, _, _, _ in }
        model.saveChoices(entry, base: "fr-FR", timing: "ar")
        var meta = try #require(library.entry(album: "Black Bird", title: "Pilot")).meta
        #expect(AddSubtitlesDefaults(meta, preferredTarget: "fa").base == "fr-FR")
        #expect(AddSubtitlesDefaults(meta, preferredTarget: "fa").timing == "ar")
        model.saveChoices(entry, base: "en", timing: "")
        meta = try #require(library.entry(album: "Black Bird", title: "Pilot")).meta
        #expect(AddSubtitlesDefaults(meta, preferredTarget: "fa").timing == "")
    }

    // Breaks if deleting the shown translation keeps it on screen.
    @Test func deletingShownTranslationClearsIt() throws {
        var entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        try entry.save([Cue(id: 1, start: 0, end: 1, text: "x")], language: "fa")
        entry.meta.targetLanguage = "fa"
        try entry.saveMeta()
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { _, _, _, _ in }
        model.update(playing("Pilot", album: "Black Bird"))
        #expect(model.entry?.meta.targetLanguage == "fa")
        model.deleteTranslation(entry, language: "fa")
        #expect(model.entry?.meta.targetLanguage == nil)
        #expect(library.entries().first?.translations == [])
    }

    /// An irregular 60-line Apple track (speech does not repeat at a fixed rhythm, or several
    /// shifts would fit) and an SRT of it from another release, 10 s later.
    static let appleTrack: [Cue] = {
        var seed: UInt64 = 7
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        var t = 20.0
        return (0..<60).map { i in
            let length = 1 + next() * 3
            defer { t += length + 0.3 + next() * next() * 12 }
            return Cue(id: i + 1, start: t, end: t + length, text: "line \(i)")
        }
    }()

    static func srt(_ cues: [Cue], shift: Double, text: (Int, Cue) -> String = { i, _ in "خط \(i)" }) -> Data {
        func time(_ t: Double) -> String {
            let ms = Int(((t + shift) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return Data(cues.enumerated().map { "\($0 + 1)\n\(time($1.start)) --> \(time($1.end))\n\(text($0, $1))\n" }.joined(separator: "\n").utf8)
    }

    // Breaks if an imported backing is not moved onto the timing track's clock, not saved as
    // the target, or not shown.
    @Test func importBackingAlignsAndShows() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["ar": Self.appleTrack, "en": Self.appleTrack], sourcePackage: "p")
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { _, _, _, _ in }
        model.update(playing("Pilot", album: "Black Bird"))
        let result = try model.importBacking(entry, data: Self.srt(Self.appleTrack, shift: 10), base: "en", timingTrack: "ar", target: "fa")
        #expect(result == .saved(lines: 60))
        let saved = try #require(library.entry(album: "Black Bird", title: "Pilot"))
        #expect(zip(try saved.cues(language: "fa").map(\.start), Self.appleTrack.map(\.start)).allSatisfy { abs($0 - $1) < 0.02 })
        #expect(saved.meta.targetLanguage == "fa")
        #expect(model.entry?.meta.targetLanguage == "fa")
    }

    // Breaks if a release ad stays in the saved backing, or the dialogue the backing lacks (5
    // lines mid-episode) is not sent to translation. Without a key, the translation stops at the
    // key check, which shows that it started.
    @Test func importBackingDropsAdsAndFillsGaps() async throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["ar": Self.appleTrack, "en": Self.appleTrack], sourcePackage: "p")
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { _, _, _, _ in }
        let backing = Array(Self.appleTrack[..<30] + Self.appleTrack[35...])
        let data = Self.srt(backing, shift: 10) { i, _ in i == 20 ? "www.30nama.com" : "خط \(i)" }
        #expect(try model.importBacking(entry, data: data, base: "en", timingTrack: "ar", target: "fa") == .saved(lines: 54))
        #expect(try entry.cues(language: "fa").allSatisfy { !$0.text.contains("30nama") })
        for _ in 0..<200 where model.translation?.error == nil { try await Task.sleep(for: .milliseconds(5)) }
        #expect(model.translation?.error?.hasPrefix("Add an API key") == true)
    }

    // Breaks if a translation still running when a backing is saved is not stopped; it would
    // later save over the backing.
    @Test func savingBackingStopsRunningTranslation() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["ar": Self.appleTrack, "en": Self.appleTrack], sourcePackage: "p")
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { _, _, _, _ in }
        model.translate(entry, base: "en", timing: "", target: "fa")
        #expect(model.translation != nil)
        _ = try model.importBacking(entry, data: Self.srt(Self.appleTrack, shift: 10), base: "en", timingTrack: "ar", target: "fa")
        #expect(model.translation == nil)
    }

    // Breaks if a backing that does not fit the title (another episode) is saved without asking.
    @Test func lowMatchBackingAsksFirst() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["ar": Self.appleTrack], sourcePackage: "p")
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { _, _, _, _ in }
        let other = (0..<60).map { i in Cue(id: i + 1, start: 20 + Double(i * i % 97) * 4.1, end: 21 + Double(i * i % 97) * 4.1, text: "x") }
            .sorted { $0.start < $1.start }
        let result = try model.importBacking(entry, data: Self.srt(other, shift: 0), base: "ar", timingTrack: "ar", target: "fa")
        guard case .lowMatch(_, let cues) = result else { Issue.record("saved without asking"); return }
        #expect(!entry.hasTrack("fa"))
        try model.saveBacking(entry, cues: cues, base: "ar", timingTrack: "ar", target: "fa")
        #expect(entry.hasTrack("fa"))
    }

    // Breaks if captions ignore the stream lead (Now Playing 3721.311 s for a 3692.23 s video),
    // or the user's own offset is lost on top of it.
    @Test func streamLeadMovesCaptions() throws {
        var entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p", videoDuration: 3692.23)
        entry.meta.targetLanguage = "en"
        try entry.saveMeta()
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { _, _, _, _ in }
        var state = playing("Pilot", album: "Black Bird")
        state.duration = 3721.311
        model.update(state)
        #expect(abs(model.scheduler.offset + 29.081) < 0.001)
        model.adjust(offset: 0.5)
        #expect(abs(model.scheduler.offset + 28.581) < 0.001)
    }

    // Breaks if the clock's content start does not set the lead over the lengths (WhatsHerName:
    // 86.61 against the download's content at 55.402 gives 31.208; the lengths give 30.548).
    @Test func contentStartSetsTheLead() throws {
        var entry = try library.ingest(title: "WhatsHerName", album: "Black Bird", tracks: ["en": []], sourcePackage: "p",
                                       videoDuration: 3788.70, parts: [TitlePart(kind: .content, start: 55.402, duration: 3593.16)])
        entry.meta.targetLanguage = "en"
        try entry.saveMeta()
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { _, _, _, _ in }
        var state = playing("WhatsHerName", album: "Black Bird")
        state.duration = 3819.248
        model.update(state)
        #expect(abs(model.scheduler.offset + 30.548) < 0.001)
        state.contentStart = 86.61
        model.update(state)
        #expect(abs(model.scheduler.offset + 31.208) < 0.001)
    }

    // Breaks if the nudge can move captions off the video.
    @Test func nudgeIsClamped() throws {
        var entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        entry.meta.targetLanguage = "en"
        try entry.saveMeta()
        let model = AppModel(library: library, keychain: Keychain(service: "test.\(UUID())")) { _, _, _, _ in }
        model.update(playing("Pilot", album: "Black Bird"))
        for _ in 0..<50 { model.adjust(nudge: -1) }
        #expect(library.entry(album: "Black Bird", title: "Pilot")?.meta.nudge == -30)
    }
}
