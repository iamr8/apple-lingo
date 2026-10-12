import AppKit
import KeyboardShortcuts
import Observation
import SubOverlayCore

@MainActor
@Observable
final class AppModel {
    // MARK: State shown in the UI

    private(set) var nowPlaying: PlaybackState?
    private(set) var entry: SubtitleLibrary.Entry?
    private(set) var adapterFailed = false
    private(set) var translation: TranslationStatus?

    struct TranslationStatus {
        var title: String
        var progress: Double
        var error: String?
    }

    // MARK: Parts

    @ObservationIgnored let library: SubtitleLibrary
    @ObservationIgnored let keychain: Keychain
    @ObservationIgnored private let notify: (_ heading: String, _ body: String, _ title: String, _ album: String?) -> Void
    @ObservationIgnored private let makeProvider: MakeProvider
    @ObservationIgnored let scheduler = CueScheduler()
    @ObservationIgnored private var watcher: DownloadWatcher?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var translationTask: Task<Void, Never>?
    @ObservationIgnored private var translationJob: UUID?
    @ObservationIgnored private var notifiedMissing = Set<String>()
    @ObservationIgnored private lazy var addWindow = AddSubtitlesWindow(model: self)

    init(library: SubtitleLibrary = SubtitleLibrary(), keychain: Keychain = Keychain(),
         notify: @escaping (_ heading: String, _ body: String, _ title: String, _ album: String?) -> Void = Notifier.post,
         makeProvider: @escaping MakeProvider = { try await $0.provider(key: $1, model: $2) }) {
        self.library = library
        self.keychain = keychain
        self.makeProvider = makeProvider
        self.notify = notify
    }

    typealias MakeProvider = @Sendable (_ choice: ProviderChoice, _ key: String, _ model: String) async throws -> TranslationProvider

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
        translationTask?.cancel()
        watcher?.stop()
    }

    // MARK: Playback

    func update(_ state: PlaybackState?) {
        let changed = state?.title != nowPlaying?.title || state?.album != nowPlaying?.album
        nowPlaying = state
        if changed { reloadEntry() }
        applyOffset()
        scheduler.update(state: state)
    }

    /// The user's offset minus the stream's lead: a streamed title's Now Playing time counts an
    /// intro the downloaded video does not have.
    private func applyOffset() {
        guard let entry else { return }
        let lead = StreamLead.seconds(nowPlaying: nowPlaying?.duration, video: entry.meta.videoDuration)
        let offset = entry.meta.offset - lead
        if scheduler.offset != offset { scheduler.offset = offset }
    }

    private func reloadEntry() {
        guard let state = nowPlaying else {
            entry = nil
            scheduler.setTimeline(nil, rightToLeft: false)
            return
        }
        entry = library.entry(album: state.album, title: state.title)
        guard let entry, let target = entry.meta.targetLanguage, entry.hasTrack(target),
              let cues = try? entry.cues(language: target)
        else {
            scheduler.setTimeline(nil, rightToLeft: false)
            let key = "\(state.album ?? "")|\(state.title)"
            if notifiedMissing.insert(key).inserted {
                notify("No subtitles for \(state.title)", "Click to add subtitles.", state.title, state.album)
            }
            return
        }
        applyOffset()
        scheduler.nudge = entry.meta.nudge
        scheduler.setTimeline(CueTimeline(cues), rightToLeft: Languages.isRightToLeft(target))
    }

    // MARK: Ingest

    private func ingest(_ package: URL) {
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
                guard !tracks.isEmpty else {
                    await MainActor.run {
                        self.notify("Subtitles not captured", "No subtitle track of \(manifest.title) could be read. Press Download again.",
                                    manifest.title, manifest.album)
                    }
                    return
                }
                // Any track tells where people speak; the original language's is the fullest.
                let dialogue = tracks[manifest.originalLanguage ?? ""] ?? tracks.values.max { $0.count < $1.count } ?? []
                try library.ingest(title: manifest.title, album: manifest.album, tracks: tracks, sourcePackage: folder,
                                   originalLanguage: manifest.originalLanguage, videoDuration: manifest.videoDuration,
                                   parts: MoviePackageReader.parts(manifest, package: package, dialogue: dialogue))
                await MainActor.run {
                    self.notify("Subtitles captured", "\(manifest.title): you can cancel the download now.",
                                manifest.title, manifest.album)
                    self.reloadEntry()
                }
            } catch {
                Log.ingest.error("ingest failed: \(String(describing: type(of: error)))")
            }
        }
    }

    // MARK: Add Subtitles

    func showAddSubtitles(title: String? = nil, album: String? = nil) {
        let title = title ?? nowPlaying?.title
        let album = title == nil ? nil : (album ?? nowPlaying?.album)
        addWindow.show(title: title, album: album?.isEmpty == true ? nil : album)
    }

    func entry(title: String, album: String?) -> SubtitleLibrary.Entry? {
        library.entry(album: album, title: title)
    }

    /// `timing` is the picker's value; "" is automatic.
    func translate(_ entry: SubtitleLibrary.Entry, base: String, timing: String, target: String) {
        let timingTrack = AddSubtitlesDefaults.timing(timing, apple: entry.meta.appleLanguages, base: base, target: target)
        run(entry, target: target) {
            TranslationJob(
                source: try entry.cues(language: base), sourceLanguage: base,
                timing: try entry.cues(language: timingTrack), timingLanguage: timingTrack, targetLanguage: target)
        } finish: { cues, meta in
            meta.baseLanguage = base
            meta.timingLanguage = timing
            return cues
        }
    }

    /// Runs a translation with the provider chosen in Settings, with progress and errors in
    /// `translation`, then saves `finish`'s cues as the `target` track and shows them.
    private func run(_ entry: SubtitleLibrary.Entry, target: String, job makeJob: @escaping () throws -> TranslationJob,
                     finish: @escaping ([Cue], inout TitleMeta) -> [Cue]) {
        cancelTranslation()
        let jobID = UUID()
        translationJob = jobID
        translation = TranslationStatus(title: entry.meta.title, progress: 0)
        let keychain = keychain
        let choice = ProviderChoice.selected
        let model = choice.model
        translationTask = Task {
            do {
                guard let key = try keychain.get(choice.account), !key.isEmpty else {
                    throw AppError("Add an API key for \(choice.title) in Settings.")
                }
                let provider = try await makeProvider(choice, key, model)
                let job = try makeJob()
                let cues = try await TranslationPipeline(provider: provider).translate(job) { progress in
                    Task { @MainActor in
                        if self.translationJob == jobID { self.translation?.progress = progress }
                    }
                }
                guard translationJob == jobID else { return }
                // Settings may have changed while it ran (an offset); change only what it owns.
                var updated = library.entry(album: entry.meta.album, title: entry.meta.title) ?? entry
                let output = finish(cues, &updated.meta)
                try entry.save(output, language: target)
                updated.meta.targetLanguage = target
                try updated.saveMeta()
                translation = nil
                translationJob = nil
                reloadEntry()
            } catch is CancellationError {
                return
            } catch {
                guard translationJob == jobID else { return }
                translation?.error = error.localizedDescription
            }
        }
    }

    enum BackingImport: Equatable {
        case saved(lines: Int)
        /// Few lines land on the title's speech; `percent` of them do. Save only if the user agrees.
        case lowMatch(percent: Int, cues: [Cue])
    }

    /// Reads a human translation and moves it onto `timingTrack`'s clock.
    /// Below this share of lines on the title's speech, the file is likely another episode or cut.
    static let backingMinMatch = 0.8

    /// Reads a human translation and moves it onto `timingTrack`'s clock.
    func importBacking(_ entry: SubtitleLibrary.Entry, data: Data, base: String, timingTrack: String, target: String) throws -> BackingImport {
        let cues = try SubtitleFile.parse(data, language: target)
        let aligned = SubtitleAligner.align(cues, to: try entry.cues(language: timingTrack))
        guard aligned.confidence >= Self.backingMinMatch else {
            return .lowMatch(percent: Int((aligned.confidence * 100).rounded()), cues: aligned.cues)
        }
        return .saved(lines: try saveBacking(entry, cues: aligned.cues, base: base, timingTrack: timingTrack, target: target))
    }

    /// Saves aligned backing cues, without release ads, as the title's `target` track and shows
    /// them. Then translates the timing track's dialogue the backing lacks and adds it.
    @discardableResult
    func saveBacking(_ entry: SubtitleLibrary.Entry, cues: [Cue], base: String, timingTrack: String, target: String) throws -> Int {
        cancelTranslation()
        let timing = try entry.cues(language: timingTrack)
        let backing = SubtitleBacking.clean(cues, timing: timing)
        try entry.save(backing, language: target)
        var updated = library.entry(album: entry.meta.album, title: entry.meta.title) ?? entry
        updated.meta.targetLanguage = target
        try updated.saveMeta()
        reloadEntry()
        if let job = SubtitleBacking.gapJob(backing: backing, source: try entry.cues(language: base), sourceLanguage: base,
                                            timing: timing, timingLanguage: timingTrack, targetLanguage: target) {
            run(updated, target: target) { job } finish: { fill, _ in SubtitleBacking.merge(backing, fill) }
        }
        return backing.count
    }

    /// Keeps the form's languages for the title before any translation succeeds. "" is automatic timing.
    func saveChoices(_ entry: SubtitleLibrary.Entry, base: String, timing: String) {
        guard var fresh = library.entry(album: entry.meta.album, title: entry.meta.title) else { return }
        fresh.meta.baseLanguage = base
        fresh.meta.timingLanguage = timing
        do { try fresh.saveMeta() } catch { Log.translation.error("save choices failed") }
    }

    /// Every title with at least one saved translation.
    func translatedEntries() -> [SubtitleLibrary.Entry] {
        library.entries().filter { !$0.translations.isEmpty }
    }

    func deleteTranslation(_ entry: SubtitleLibrary.Entry, language: String) {
        guard var fresh = library.entry(album: entry.meta.album, title: entry.meta.title) else { return }
        do { try fresh.deleteTranslation(language) } catch { Log.translation.error("delete translation failed") }
        reloadEntry()
    }

    func cancelTranslation() {
        translationTask?.cancel()
        translationTask = nil
        translationJob = nil
        translation = nil
    }

    func dismissTranslationError() {
        translation = nil
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

struct AppError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
