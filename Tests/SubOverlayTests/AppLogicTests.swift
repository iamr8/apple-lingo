import Foundation
@testable import SubOverlayCore
import Synchronization
import Testing
@testable import SubOverlay

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
        #expect(MenuText.status(adapterFailed: true, translating: nil, playing: true, shown: nil, hasEntry: false) == "Cannot read Now Playing")
        #expect(MenuText.status(adapterFailed: false, translating: 0.42, playing: true, shown: nil, hasEntry: true) == "Translating… 42%")
        #expect(MenuText.status(adapterFailed: false, translating: nil, playing: false, shown: nil, hasEntry: false) == "Idle")
        #expect(MenuText.status(adapterFailed: false, translating: nil, playing: true, shown: nil, hasEntry: false) == "No subtitles captured")
        #expect(MenuText.status(adapterFailed: false, translating: nil, playing: true, shown: nil, hasEntry: true) == "No translation yet")
        #expect(MenuText.status(adapterFailed: false, translating: nil, playing: true, shown: "fa", hasEntry: true) == "Showing Persian")
        #expect(MenuText.status(adapterFailed: false, translating: nil, playing: true, shown: nil, hasEntry: true, failed: true) == "Translation failed")
    }
}

/// Settings languages a test can change while the model runs.
final class LanguageBox: @unchecked Sendable {
    var settings: TranslationPlan.Settings
    init(target: String, secondary: String = TranslationPlan.Settings.automatic) {
        settings = TranslationPlan.Settings(secondary: secondary, target: target)
    }
}

@MainActor
struct AppModelTests {
    let library = SubtitleLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    let posted = Recorder()

    func playing(_ title: String, album: String?) -> PlaybackState {
        PlaybackState(title: title, album: album, elapsedAtAnchor: 0, rate: 1, playing: false, anchor: .now)
    }

    func model(keychain: Keychain = Keychain(service: "test.\(UUID())"), provider: TranslationProvider? = nil) -> AppModel {
        model(languages: LanguageBox(target: "fa"), keychain: keychain, provider: provider)
    }

    func model(languages: LanguageBox, keychain: Keychain = Keychain(service: "test.\(UUID())"),
               provider: TranslationProvider? = nil) -> AppModel {
        AppModel(library: library, keychain: keychain, languages: { languages.settings },
                 notify: { heading, body in posted.add("\(heading): \(body)") },
                 makeProvider: { choice, key, model in
                     if let provider { return provider }
                     return try await choice.provider(key: key, model: model)
                 })
    }

    /// A keychain with a key for every provider.
    func keyed() throws -> Keychain {
        let keychain = Keychain(service: "test.\(UUID())")
        for choice in ProviderChoice.allCases { try keychain.set("key", for: choice.account) }
        return keychain
    }

    /// Waits up to 2 s for `condition`.
    func until(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<1000 where !condition() { try await Task.sleep(for: .milliseconds(2)) }
        #expect(condition())
    }

    func shownIDs(_ model: AppModel) -> [Int] { model.scheduler.timeline?.cues.map(\.id) ?? [] }

    // Breaks if a title without subtitles does not notify once, with what to do, or notifies on
    // every update.
    @Test func notifiesOncePerTitleWithoutSubtitles() {
        let model = model()
        model.update(playing("Pilot", album: "Black Bird"))
        model.update(nil)
        model.update(playing("Pilot", album: "Black Bird"))
        #expect(posted.all == ["No subtitles for Pilot: Press Download on it in the TV app, then cancel."])
    }

    // Breaks if the saved translation into the Settings target is not shown, or the track's
    // language does not decide the writing direction.
    @Test func playShowsTheSavedTargetTrack() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        try entry.save([Cue(id: 1, start: 0, end: 1, text: "x")], language: "fa")
        let model = model()
        model.update(playing("Pilot", album: "Black Bird"))
        #expect(model.shownLanguage == "fa")
        #expect(shownIDs(model) == [1])
        #expect(model.scheduler.rightToLeft)
        #expect(model.queue.running == nil)
        #expect(posted.all.isEmpty)
    }

    // Breaks if deleting the shown translation keeps it on screen, or queues a new one.
    @Test func deletingShownTranslationClearsItAndQueuesNothing() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        try entry.save([Cue(id: 1, start: 0, end: 1, text: "x")], language: "fa")
        let model = model()
        model.update(playing("Pilot", album: "Black Bird"))
        model.deleteTranslation(entry, language: "fa")
        #expect(model.shownLanguage == nil)
        #expect(model.scheduler.timeline == nil)
        #expect(model.queue.running == nil)
        #expect(library.entries().first?.translations == [])
    }

    // Breaks if playing a captured title without the target track does not queue its
    // translation, or the finished track is not saved and shown.
    @Test func playQueuesATranslationAndShowsItWhenDone() async throws {
        try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": Array(Self.appleTrack.prefix(5))], sourcePackage: "p")
        let provider = GatedProvider()
        let model = model(keychain: try keyed(), provider: provider)
        model.update(playing("Pilot", album: "Black Bird"))
        #expect(model.queue.running?.title == "Pilot")
        #expect(model.queue.running?.target == "fa")
        provider.open()
        try await until { model.shownLanguage == "fa" }
        #expect(shownIDs(model) == [1, 2, 3, 4, 5])
        #expect(try library.entry(album: "Black Bird", title: "Pilot")?.cues(language: "fa").first?.text == "T:line 0")
        #expect(model.queue.running == nil)
    }

    // Breaks if a finished chunk of the running translation is not shown while the title plays,
    // is lost when the user leaves and returns, or is shown for a title that is not playing.
    @Test func liveChunksShowWhileTheTitlePlays() async throws {
        try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": Self.appleTrack + Self.more(from: 61, count: 65)], sourcePackage: "p")
        let model = model(keychain: try keyed(), provider: HalfProvider(lastAnswered: 120))
        model.update(playing("Pilot", album: "Black Bird"))
        try await until { model.shownLanguage == "fa" }
        #expect(shownIDs(model).sorted() == Array(1...120))
        #expect(model.queue.running != nil)
        model.update(nil)
        #expect(model.scheduler.timeline == nil)
        model.update(playing("Pilot", album: "Black Bird"))
        #expect(shownIDs(model).sorted() == Array(1...120))
        model.update(playing("Other", album: "Black Bird"))
        #expect(model.scheduler.timeline == nil)
        model.cancelTranslation(key: model.queue.running!.key)
        #expect(model.queue.running == nil)
    }

    // Breaks if chunks that land out of order are not shown in time order, or a chunk of
    // another title's job is shown.
    @Test func chunksOutOfOrderAndOfOtherTitles() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        let model = model()
        model.update(playing("Pilot", album: "Black Bird"))
        let key = AppModel.key(entry, "fa")
        model.liveChunk(key: "other|fa", cues: [Cue(id: 9, start: 9, end: 10, text: "x")])
        #expect(model.scheduler.timeline == nil)
        model.liveChunk(key: key, cues: [Cue(id: 3, start: 3, end: 4, text: "c"), Cue(id: 4, start: 4, end: 5, text: "d")])
        model.liveChunk(key: key, cues: [Cue(id: 1, start: 1, end: 2, text: "a"), Cue(id: 2, start: 2, end: 3, text: "b")])
        #expect(shownIDs(model) == [1, 2, 3, 4])
        #expect(model.shownLanguage == "fa")
    }

    // Breaks if the live track ignores the title's offset, lead or nudge.
    @Test func liveTrackUsesTheTitlesTiming() throws {
        var entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p", videoDuration: 3692.23)
        entry.meta.offset = 0.5
        entry.meta.nudge = -3
        try entry.saveMeta()
        let model = model()
        var state = playing("Pilot", album: "Black Bird")
        state.duration = 3721.311
        model.update(state)
        model.liveChunk(key: AppModel.key(entry, "fa"), cues: [Cue(id: 1, start: 1, end: 2, text: "a")])
        #expect(abs(model.scheduler.offset + 28.581) < 0.001)
        #expect(model.scheduler.nudge == -3)
    }

    // Breaks if a Settings change does not show the new target or queue its translation.
    @Test func settingsChangeReevaluatesThePlayingTitle() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        try entry.save([Cue(id: 1, start: 0, end: 1, text: "x")], language: "fa")
        let languages = LanguageBox(target: "fa")
        let model = model(languages: languages)
        model.update(playing("Pilot", album: "Black Bird"))
        #expect(model.shownLanguage == "fa")
        languages.settings.target = "ku"
        model.settingsChanged()
        #expect(model.shownLanguage == nil)
        #expect(model.queue.running?.target == "ku")
        model.cancelTranslation(key: model.queue.running!.key)
    }

    // Breaks if a title the planner stops (it ships the target) is translated, or its notice
    // comes more than once per run.
    @Test func plannerProblemIsNoticedOnce() throws {
        try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": [], "fa": []], sourcePackage: "p")
        let model = model()
        model.update(playing("Pilot", album: "Black Bird"))
        model.update(nil)
        model.update(playing("Pilot", album: "Black Bird"))
        #expect(model.queue.running == nil)
        #expect(posted.all == ["No translation for Pilot: Pilot already has Persian subtitles in the TV app."])
    }

    /// A writable copy of the fixture package (Arabic and French tracks, no original language).
    func fixturePackage() throws -> URL {
        let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "SubOverlayCoreTests/Fixtures/Downloads-TV/Part One.tmp")
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures, to: dir.appending(path: "Part One.tmp"))
        return dir.appending(path: "Part One.tmp/download.movpkg")
    }

    // Breaks if a package whose primary track (Arabic: the first, with no original language
    // and no English) cannot be read is saved anyway, or the notice does not say to press
    // Download again.
    @Test func ingestSavesNothingWithoutThePrimaryTrack() async throws {
        let package = try fixturePackage()
        try FileManager.default.removeItem(at: package.appending(path: "2-AR"))
        let model = model()
        model.ingest(package)
        try await until { !posted.all.isEmpty }
        #expect(posted.all == ["Subtitles not captured: No Arabic track of Part One could be read. Press Download on it again."])
        #expect(library.entries().isEmpty)
    }

    // Breaks if a capture does not queue the translation and say so, or does not name the
    // problem that stops it.
    @Test func captureQueuesAndNotifies() throws {
        let pilot = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        let shipped = try library.ingest(title: "E2", album: "Black Bird", tracks: ["en": [], "fa": []], sourcePackage: "q")
        let model = model()
        model.captured(pilot)
        model.captured(shipped)
        #expect(model.queue.running?.title == "Pilot")
        #expect(posted.all == ["Subtitles captured: Pilot: you can cancel the download now. Translating into Persian.",
                               "Subtitles captured: E2 already has Persian subtitles in the TV app."])
        model.cancelTranslation(key: model.queue.running!.key)
    }

    // Breaks if translation ignores the provider chosen in Settings and uses the Gemini key,
    // or a failure is not told with its reason.
    @Test func translateUsesSelectedProvider() async throws {
        try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        let keychain = Keychain(service: "test.\(UUID())")
        try keychain.set("gemini-key", for: ProviderChoice.gemini.account)
        defer { try? keychain.delete(ProviderChoice.gemini.account) }
        let saved = UserDefaults.standard.string(forKey: ProviderChoice.selectedKey)
        UserDefaults.standard.set(ProviderChoice.openAI.rawValue, forKey: ProviderChoice.selectedKey)
        defer { UserDefaults.standard.set(saved, forKey: ProviderChoice.selectedKey) }
        let model = model(keychain: keychain)
        model.update(playing("Pilot", album: "Black Bird"))
        try await until { !posted.all.isEmpty }
        #expect(posted.all == ["Translation failed: Pilot: Add an API key for OpenAI in Settings."])
        #expect(model.queue.running == nil)
    }

    // Breaks if a failed translation is not kept with its reason for the playing title, cannot
    // be retried from the menu, or stays marked failed once it runs again.
    @Test func failedTranslationCanBeRetried() async throws {
        try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": Array(Self.appleTrack.prefix(5))], sourcePackage: "p")
        let provider = GatedProvider()
        let keychain = Keychain(service: "test.\(UUID())")
        let model = model(keychain: keychain, provider: provider)
        model.update(playing("Pilot", album: "Black Bird"))
        try await until { posted.all.count == 1 }
        #expect(model.failure?.hasPrefix("Add an API key") == true)
        #expect(model.failures.map(\.title) == ["Pilot"])
        model.retryTranslation()
        #expect(model.failure == nil)
        try await until { posted.all.count == 2 }
        #expect(model.failures.map(\.title) == ["Pilot"])
        for choice in ProviderChoice.allCases { try keychain.set("key", for: choice.account) }
        model.retryTranslation()
        #expect(model.queue.running?.title == "Pilot")
        provider.open()
        try await until { model.shownLanguage == "fa" }
        #expect(model.failures.isEmpty)
    }

    // Breaks if a translation that finishes writes over a setting changed while it ran (an offset).
    @Test func translationKeepsSettingsChangedMeanwhile() async throws {
        try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": Array(Self.appleTrack.prefix(5))], sourcePackage: "p")
        let provider = GatedProvider()
        let model = model(keychain: try keyed(), provider: provider)
        model.update(playing("Pilot", album: "Black Bird"))
        try await until { provider.calls.withLock { $0 } > 0 }
        model.adjust(offset: 1.5)
        provider.open()
        try await until { model.shownLanguage == "fa" }
        let meta = try #require(library.entry(album: "Black Bird", title: "Pilot")).meta
        #expect(meta.offset == 1.5)
    }

    // Breaks if a translation whose file cannot be written fails silently.
    @Test func failedWriteNotifies() async throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": Array(Self.appleTrack.prefix(5))], sourcePackage: "p")
        let provider = GatedProvider()
        let model = model(keychain: try keyed(), provider: provider)
        model.update(playing("Pilot", album: "Black Bird"))
        try await until { provider.calls.withLock { $0 } > 0 }
        try FileManager.default.removeItem(at: entry.directory)
        provider.open()
        try await until { !posted.all.isEmpty }
        #expect(posted.all.first?.hasPrefix("Translation failed: Pilot:") == true)
    }

    /// An irregular 60-line Apple track (speech does not repeat at a fixed rhythm, or several
    /// shifts would fit) and an SRT of it from another release, 10 s later.
    static let appleTrack: [Cue] = more(from: 1, count: 60)

    static func more(from first: Int, count: Int) -> [Cue] {
        var seed: UInt64 = 7
        func next() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(1 << 31)
        }
        var t = 20.0 + Double(first)
        return (0..<count).map { i in
            let length = 1 + next() * 3
            defer { t += length + 0.3 + next() * next() * 12 }
            return Cue(id: first + i, start: t, end: t + length, text: "line \(first + i - 1)")
        }
    }

    static func srt(_ cues: [Cue], shift: Double, text: (Int, Cue) -> String = { i, _ in "خط \(i)" }) -> Data {
        func time(_ t: Double) -> String {
            let ms = Int(((t + shift) * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return Data(cues.enumerated().map { "\($0 + 1)\n\(time($1.start)) --> \(time($1.end))\n\(text($0, $1))\n" }.joined(separator: "\n").utf8)
    }

    // Breaks if an imported backing is not moved onto the planner's timing track (Arabic for a
    // Persian target), not saved as the target, or not shown.
    @Test func importBackingAlignsAndShows() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["ar": Self.appleTrack, "en": Self.appleTrack], sourcePackage: "p")
        let model = model()
        model.update(playing("Pilot", album: "Black Bird"))
        model.cancelTranslation(key: AppModel.key(entry, "fa"))
        let result = try model.importBacking(entry, data: Self.srt(Self.appleTrack, shift: 10))
        #expect(result == .saved(lines: 60))
        let saved = try #require(library.entry(album: "Black Bird", title: "Pilot"))
        #expect(zip(try saved.cues(language: "fa").map(\.start), Self.appleTrack.map(\.start)).allSatisfy { abs($0 - $1) < 0.02 })
        #expect(model.shownLanguage == "fa")
    }

    // Breaks if an import runs for a title the planner stops.
    @Test func importNeedsAPlan() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": [], "fa": []], sourcePackage: "p")
        let model = model()
        #expect(throws: AppError.self) { try model.importBacking(entry, data: Self.srt(Self.appleTrack, shift: 10)) }
    }

    // Breaks if a release ad stays in the saved backing, the dialogue the backing lacks (5 lines
    // mid-episode) is not queued, or the backing goes when that job fails (no key here).
    @Test func importBackingDropsAdsAndFillsGaps() async throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["ar": Self.appleTrack, "en": Self.appleTrack], sourcePackage: "p")
        let model = model()
        let backing = Array(Self.appleTrack[..<30] + Self.appleTrack[35...])
        let data = Self.srt(backing, shift: 10) { i, _ in i == 20 ? "www.30nama.com" : "خط \(i)" }
        #expect(try model.importBacking(entry, data: data) == .saved(lines: 54))
        #expect(try entry.cues(language: "fa").allSatisfy { !$0.text.contains("30nama") })
        try await until { !posted.all.isEmpty }
        #expect(posted.all.first?.hasPrefix("Translation failed: Pilot: Add an API key") == true)
        #expect(try entry.cues(language: "fa").count == 54)
    }

    // Breaks if a translation still running when a backing is saved is not stopped; it would
    // later save over the backing.
    @Test func savingBackingStopsRunningTranslation() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["ar": Self.appleTrack, "en": Self.appleTrack], sourcePackage: "p")
        let model = model(keychain: try keyed(), provider: GatedProvider())
        model.update(playing("Pilot", album: "Black Bird"))
        #expect(model.queue.running != nil)
        _ = try model.importBacking(entry, data: Self.srt(Self.appleTrack, shift: 10))
        #expect(model.queue.running == nil)
        #expect(model.shownLanguage == "fa")
    }

    // Breaks if a backing that does not fit the title (another episode) is saved without asking.
    @Test func lowMatchBackingAsksFirst() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["ar": Self.appleTrack], sourcePackage: "p")
        let model = model()
        let other = (0..<60).map { i in Cue(id: i + 1, start: 20 + Double(i * i % 97) * 4.1, end: 21 + Double(i * i % 97) * 4.1, text: "x") }
            .sorted { $0.start < $1.start }
        let result = try model.importBacking(entry, data: Self.srt(other, shift: 0))
        guard case .lowMatch(_, let cues) = result else { Issue.record("saved without asking"); return }
        #expect(!entry.hasTrack("fa"))
        try model.saveBacking(entry, cues: cues)
        #expect(entry.hasTrack("fa"))
    }

    // Breaks if the offset is not rounded to 0.1 s and saved to the title's meta.
    @Test func offsetHotkeyPersists() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        try entry.save([], language: "fa")
        let model = model()
        model.update(playing("Pilot", album: "Black Bird"))
        model.adjust(offset: 0.1)
        model.adjust(offset: 0.1)
        model.adjust(offset: 0.1)
        #expect(model.offset == 0.3)
        #expect(library.entry(album: "Black Bird", title: "Pilot")?.meta.offset == 0.3)
    }

    // Breaks if the menu's reset leaves an offset on the playing title or in its meta.
    @Test func resetOffsetClearsTheTitle() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        try entry.save([], language: "fa")
        let model = model()
        model.update(playing("Pilot", album: "Black Bird"))
        model.adjust(offset: -2.5)
        model.resetOffset()
        #expect(model.offset == 0)
        #expect(library.entry(album: "Black Bird", title: "Pilot")?.meta.offset == 0)
    }

    // Breaks if captions ignore the stream lead (Now Playing 3721.311 s for a 3692.23 s video),
    // or the user's own offset is lost on top of it.
    @Test func streamLeadMovesCaptions() throws {
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p", videoDuration: 3692.23)
        try entry.save([], language: "fa")
        let model = model()
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
        let entry = try library.ingest(title: "WhatsHerName", album: "Black Bird", tracks: ["en": []], sourcePackage: "p",
                           videoDuration: 3788.70, parts: [TitlePart(kind: .content, start: 55.402, duration: 3593.16)])
        try entry.save([], language: "fa")
        let model = model()
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
        let entry = try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["en": []], sourcePackage: "p")
        try entry.save([], language: "fa")
        let model = model()
        model.update(playing("Pilot", album: "Black Bird"))
        for _ in 0..<50 { model.adjust(nudge: -1) }
        #expect(library.entry(album: "Black Bird", title: "Pilot")?.meta.nudge == -30)
    }
}
