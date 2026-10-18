import AppKit
import KeyboardShortcuts
import Observation
import AppleLingoCore

@MainActor
@Observable
final class AppModel {
    // MARK: State shown in the UI

    private(set) var nowPlaying: PlaybackState?
    private(set) var entry: SubtitleLibrary.Entry?
    private(set) var adapterFailed = false
    /// The language of the track on screen: the Settings target, saved or arriving in chunks.
    private(set) var shownLanguage: String?
    let queue: TranslationQueue
    /// Translations that failed, newest last, until they are queued again.
    private(set) var failures: [Failure] = []

    struct Failure: Identifiable {
        var key: String
        var title: String
        var target: String
        var reason: String
        var id: String { key }
    }

    /// Why the playing title's translation failed, if it did.
    var failure: String? {
        guard let entry else { return nil }
        let key = Self.key(entry, languages().target)
        return failures.first { $0.key == key }?.reason
    }

    /// Queues the playing title's failed translation again.
    func retryTranslation() {
        guard let entry else { return }
        startTranslation(entry)
    }

    /// Queues a failed translation again, from the Translations tab.
    func retry(key: String) {
        guard let failure = failures.first(where: { $0.key == key }),
              let entry = library.entries().first(where: { Self.key($0, failure.target) == key }) else { return }
        startTranslation(entry)
    }

    // MARK: Parts

    @ObservationIgnored let library: SubtitleLibrary
    @ObservationIgnored let keychain: Keychain
    @ObservationIgnored private let notify: (_ heading: String, _ body: String) -> Void
    @ObservationIgnored private let languages: () -> TranslationPlan.Settings
    @ObservationIgnored let scheduler = CueScheduler()
    @ObservationIgnored private var watcher: DownloadWatcher?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    /// Notices given this run, by title and reason.
    @ObservationIgnored private var noticed = Set<String>()
    /// Finished chunks of the running full translation, by cue id.
    @ObservationIgnored private var live: (key: String, cues: [Int: Cue])?
    @ObservationIgnored private lazy var importWindow = ImportSubtitleWindow(model: self)

    typealias MakeProvider = @Sendable (_ choice: ProviderChoice, _ key: String, _ model: String) async throws -> TranslationProvider

    init(library: SubtitleLibrary = SubtitleLibrary(), keychain: Keychain = Keychain(),
         languages: @escaping () -> TranslationPlan.Settings = { Preferences.languages },
         notify: @escaping (_ heading: String, _ body: String) -> Void = Notifier.post,
         makeProvider: @escaping MakeProvider = { try await $0.provider(key: $1, model: $2) }) {
        self.library = library
        self.keychain = keychain
        self.languages = languages
        self.notify = notify
        queue = TranslationQueue(translate: Self.translate(keychain: keychain, makeProvider: makeProvider))
    }

    /// A translation with the provider, model and key chosen in Settings when the job starts.
    private static func translate(keychain: Keychain, makeProvider: @escaping MakeProvider) -> TranslationQueue.Translate {
        { job, progress, chunk in
            let choice = ProviderChoice.selected
            guard let key = try keychain.get(choice.account), !key.isEmpty else {
                throw AppError("Add an API key for \(choice.title) in Settings.")
            }
            let provider = try await makeProvider(choice, key, choice.model)
            return try await TranslationPipeline(provider: provider).translate(job, progress: progress, chunk: chunk)
        }
    }

    func start() {
        Notifier.requestAuthorization()
        startHotkeys()
        let watcher = DownloadWatcher(onReady: { [weak self] in self?.ingest($0) })
        watcher.start()
        self.watcher = watcher

        monitorTask = Task { [weak self] in
            let adapter = AdapterProcess(paths: .inBundle())
            guard await adapter.selfTest() else {
                Log.adapter.error("adapter self-test failed")
                self?.adapterFailed = true
                return
            }
            let states = await NowPlayingMonitor().states(from: adapter.lines(), events: PlayerLogStream().events())
            for await state in states {
                self?.update(state)
            }
        }
    }

    func stop() {
        monitorTask?.cancel()
        watcher?.stop()
    }

    // MARK: Playback

    func update(_ state: PlaybackState?) {
        let changed = state?.title != nowPlaying?.title || state?.album != nowPlaying?.album
        nowPlaying = state
        if changed {
            reloadEntry()
            evaluate()
        }
        applyOffset()
        scheduler.update(state: state)
    }

    /// Languages, provider, model or key changed: the playing title is shown and looked at again.
    func settingsChanged() {
        reloadEntry()
        evaluate()
    }

    /// The user's offset minus the stream's lead: a streamed title's Now Playing time counts an
    /// intro the downloaded video does not have.
    private func applyOffset() {
        guard let entry else { return }
        let lead = StreamLead.seconds(contentStart: nowPlaying?.contentStart,
                                      contentPart: entry.meta.parts?.first { $0.kind == .content }?.start,
                                      nowPlaying: nowPlaying?.duration, video: entry.meta.videoDuration)
        let offset = entry.meta.offset - lead
        if scheduler.offset != offset { scheduler.offset = offset }
    }

    /// Shows the playing title's translation into the Settings target: the saved one, else the
    /// finished chunks of its running translation. A track Apple ships is the TV app's to show.
    private func reloadEntry() {
        shownLanguage = nil
        guard let state = nowPlaying else {
            entry = nil
            scheduler.setTimeline(nil, rightToLeft: false)
            return
        }
        entry = library.entry(album: state.album, title: state.title)
        let target = languages().target
        guard let entry else { return scheduler.setTimeline(nil, rightToLeft: false) }
        if !entry.meta.appleLanguages.contains(target), entry.hasTrack(target), let cues = try? entry.cues(language: target) {
            show(cues, language: target)
        } else if let live, live.key == Self.key(entry, target) {
            show(Array(live.cues.values), language: target)
        } else {
            scheduler.setTimeline(nil, rightToLeft: false)
        }
    }

    private func show(_ cues: [Cue], language: String) {
        shownLanguage = language
        applyOffset()
        scheduler.nudge = entry?.meta.nudge ?? 0
        scheduler.videoAspect = entry?.meta.videoAspect
        scheduler.setTimeline(CueTimeline(cues), rightToLeft: Languages.isRightToLeft(language))
    }

    /// The play trigger: a captured title with no track in the target gets its translation; a
    /// title that is not captured, or one the planner stops, gets one notice per reason.
    private func evaluate() {
        guard let state = nowPlaying else { return }
        guard let entry else {
            notice(state.title, reason: "capture", "No subtitles for \(state.title)", "Press Download on it in the TV app, then cancel.")
            return
        }
        guard shownLanguage == nil, let problem = startTranslation(entry) else { return }
        notice(entry.meta.title, reason: "\(problem)", "No translation for \(entry.meta.title)", problem.notice(title: entry.meta.title))
    }

    private func notice(_ title: String, reason: String, _ heading: String, _ body: String) {
        if noticed.insert("\(title)|\(reason)").inserted { notify(heading, body) }
    }

    // MARK: Ingest

    func ingest(_ package: URL) {
        let folder = package.deletingLastPathComponent().lastPathComponent
        guard !library.hasEntry(sourcePackage: folder) else { return }
        let library = library
        let fetcher = TrackFetcher(transport: HTTPClient(hosts: .suffix(".apple.com")))
        Task.detached {
            do {
                let manifest = try MoviePackageReader.manifest(package: package)
                var tracks: [String: [Cue]] = [:]
                // A track the download finished is read from the package; any other comes from
                // its URL. A track that fails is left out.
                for track in manifest.tracks {
                    do {
                        if track.complete {
                            tracks[track.language] = try MoviePackageReader.readTrack(track, package: package)
                        } else if let url = track.url {
                            tracks[track.language] = try await fetcher.cues(playlist: url)
                        }
                    } catch {
                        Log.ingest.error("track \(track.language, privacy: .public) skipped: \(String(describing: type(of: error)), privacy: .public)")
                    }
                }
                // Without the track the planner needs, nothing is saved: the next press tries again.
                let primary = TranslationPlan.primary(apple: manifest.tracks.map(\.language), original: manifest.originalLanguage)
                guard let primary, tracks[primary] != nil else {
                    let missing = primary.map { "No \(Languages.name($0)) track of \(manifest.title) could be read. Press Download on it again." }
                    await MainActor.run {
                        self.notify("Subtitles not captured", missing ?? TranslationPlan.Problem.noPrimary.notice(title: manifest.title))
                    }
                    return
                }
                // Any track tells where people speak; the original language's is the fullest.
                let dialogue = tracks[manifest.originalLanguage ?? ""] ?? tracks.values.max { $0.count < $1.count } ?? []
                let entry = try library.ingest(title: manifest.title, album: manifest.album, tracks: tracks, sourcePackage: folder,
                                               originalLanguage: manifest.originalLanguage, videoDuration: manifest.videoDuration,
                                               parts: MoviePackageReader.parts(manifest, package: package, dialogue: dialogue),
                                               videoAspect: manifest.videoAspect)
                await MainActor.run { self.captured(entry) }
            } catch {
                Log.ingest.error("ingest failed: \(String(describing: type(of: error)))")
            }
        }
    }

    /// After a capture: the title's translation is queued, and the notice says so or names
    /// the problem that stops it.
    func captured(_ entry: SubtitleLibrary.Entry) {
        let title = entry.meta.title
        let body = startTranslation(entry)?.notice(title: title)
            ?? "\(title): you can cancel the download now. Translating into \(Languages.name(languages().target))."
        notify("Subtitles captured", body)
        reloadEntry()
    }

    // MARK: Translation

    /// Plans the title's translation from the Settings languages and queues it. Returns the
    /// problem that stops it, if any.
    @discardableResult
    func startTranslation(_ entry: SubtitleLibrary.Entry) -> TranslationPlan.Problem? {
        switch plan(entry) {
        case .failure(let problem): return problem
        case .success(let plan):
            enqueue(entry, target: plan.target, live: true, make: { try entry.job(plan) }) { $0 }
            return nil
        }
    }

    private func plan(_ entry: SubtitleLibrary.Entry) -> Result<TranslationPlan, TranslationPlan.Problem> {
        TranslationPlan.make(apple: entry.meta.appleLanguages, original: entry.meta.originalLanguage, settings: languages())
    }

    /// The queue key of a title's translation into `target`.
    static func key(_ entry: SubtitleLibrary.Entry, _ target: String) -> String {
        entry.directory.path + "|" + target
    }

    /// Queues a translation of the title into `target`. A live one shows its chunks while the
    /// title plays; `finish` makes the track to save from the translated cues.
    private func enqueue(_ entry: SubtitleLibrary.Entry, target: String, live: Bool,
                         make: @escaping @MainActor () throws -> TranslationJob, finish: @escaping ([Cue]) -> [Cue]) {
        let key = Self.key(entry, target)
        failures.removeAll { $0.key == key }
        queue.enqueue(TranslationQueue.Job(key: key, title: entry.meta.title, target: target, make: make, chunk: { [weak self] cues in
            if live { self?.liveChunk(key: key, cues: cues) }
        }, done: { [weak self] result in
            self?.finished(key: key, entry: entry, target: target, result: result.map(finish))
        }))
    }

    /// Keeps a finished chunk of the running translation and shows it when its title plays.
    func liveChunk(key: String, cues: [Cue]) {
        if live?.key != key { live = (key, [:]) }
        for cue in cues { live?.cues[cue.id] = cue }
        guard let entry, Self.key(entry, languages().target) == key else { return }
        reloadEntry()
    }

    private func finished(key: String, entry: SubtitleLibrary.Entry, target: String, result: Result<[Cue], Error>) {
        if live?.key == key { live = nil }
        do {
            try entry.save(try result.get(), language: target)
        } catch {
            failures.removeAll { $0.key == key }
            failures.append(Failure(key: key, title: entry.meta.title, target: target, reason: error.localizedDescription))
            notify("Translation failed", "\(entry.meta.title): \(error.localizedDescription)")
        }
        reloadEntry()
    }

    func cancelTranslation(key: String) {
        queue.cancel(key: key)
        if live?.key == key { live = nil }
        reloadEntry()
    }

    /// Every title with at least one saved translation.
    func translatedEntries() -> [SubtitleLibrary.Entry] {
        library.entries().filter { !$0.translations.isEmpty }
    }

    /// Removes the saved track. Nothing is queued; the next play of the title is.
    func deleteTranslation(_ entry: SubtitleLibrary.Entry, language: String) {
        do { try entry.deleteTranslation(language) } catch { Log.translation.error("delete translation failed") }
        reloadEntry()
    }

    // MARK: Import

    func showImport() {
        importWindow.show()
    }

    enum BackingImport: Equatable {
        /// `scale` is the frame-rate change the file's times needed; 1 for none.
        case saved(lines: Int, scale: Double = 1)
        /// Few lines land on the title's speech; `percent` of them do. Save only if the user agrees.
        case lowMatch(percent: Int, cues: [Cue])
    }

    /// Below this share of lines on the title's speech, the file is likely another episode or cut.
    static let backingMinMatch = 0.8

    /// Reads a human translation and moves it onto the planner's timing track.
    func importBacking(_ entry: SubtitleLibrary.Entry, data: Data) throws -> BackingImport {
        let plan = try importPlan(entry)
        let cues = try SubtitleFile.parse(data, language: plan.target)
        let aligned = SubtitleAligner.align(cues, to: try entry.cues(language: plan.timing))
        guard aligned.confidence >= Self.backingMinMatch else {
            return .lowMatch(percent: Int((aligned.confidence * 100).rounded()), cues: aligned.cues)
        }
        return .saved(lines: try saveBacking(entry, cues: aligned.cues), scale: aligned.scale)
    }

    /// Saves aligned backing cues, without release ads, as the title's target track and shows
    /// them. A translation of the title is cancelled; the dialogue the backing lacks is queued.
    @discardableResult
    func saveBacking(_ entry: SubtitleLibrary.Entry, cues: [Cue]) throws -> Int {
        let plan = try importPlan(entry)
        cancelTranslation(key: Self.key(entry, plan.target))
        let timing = try entry.cues(language: plan.timing)
        let backing = SubtitleBacking.clean(cues, timing: timing)
        try entry.save(backing, language: plan.target)
        reloadEntry()
        if let job = SubtitleBacking.gapJob(backing: backing, source: try entry.cues(language: plan.base), sourceLanguage: plan.base,
                                            timing: timing, timingLanguage: plan.timing, targetLanguage: plan.target) {
            enqueue(entry, target: plan.target, live: false, make: { job }) { SubtitleBacking.merge(backing, $0) }
        }
        return backing.count
    }

    private func importPlan(_ entry: SubtitleLibrary.Entry) throws -> TranslationPlan {
        switch plan(entry) {
        case .success(let plan): plan
        case .failure(let problem): throw AppError(problem.notice(title: entry.meta.title))
        }
    }

    // MARK: Hotkeys

    var offset: Double { entry?.meta.offset ?? 0 }

    private func startHotkeys() {
        KeyboardShortcuts.onKeyUp(for: .offsetMinusSmall) { [weak self] in self?.adjust(offset: -0.1) }
        KeyboardShortcuts.onKeyUp(for: .offsetPlusSmall) { [weak self] in self?.adjust(offset: 0.1) }
        KeyboardShortcuts.onKeyUp(for: .offsetMinusLarge) { [weak self] in self?.adjust(offset: -0.5) }
        KeyboardShortcuts.onKeyUp(for: .offsetPlusLarge) { [weak self] in self?.adjust(offset: 0.5) }
        KeyboardShortcuts.onKeyUp(for: .nudgeUp) { [weak self] in self?.adjust(nudge: -1) }
        KeyboardShortcuts.onKeyUp(for: .nudgeDown) { [weak self] in self?.adjust(nudge: 1) }
    }

    func resetOffset() {
        adjust(offset: -offset)
    }

    func adjust(offset delta: Double = 0, nudge nudgeDelta: Double = 0) {
        guard var entry else { return }
        entry.meta.offset = ((entry.meta.offset + delta) * 10).rounded() / 10
        entry.meta.nudge = min(10, max(-30, entry.meta.nudge + nudgeDelta))
        try? entry.saveMeta()
        self.entry = entry
        applyOffset()
        scheduler.nudge = entry.meta.nudge
    }
}

extension SubtitleLibrary.Entry {
    /// The title's tracks in the plan's languages.
    func job(_ plan: TranslationPlan) throws -> TranslationJob {
        TranslationJob(source: try cues(language: plan.base), sourceLanguage: plan.base,
                       timing: try cues(language: plan.timing), timingLanguage: plan.timing, targetLanguage: plan.target)
    }
}

struct AppError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
