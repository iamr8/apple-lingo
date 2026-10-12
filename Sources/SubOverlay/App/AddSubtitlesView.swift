import AppKit
import SubOverlayCore
import SwiftUI
import UniformTypeIdentifiers

/// Hosts the Add Subtitles form in one reusable window, so a notification click can open it.
@MainActor
final class AddSubtitlesWindow {
    private weak var model: AppModel?
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show(title: String?, album: String?) {
        guard let model else { return }
        let view = AddSubtitlesView(model: model, title: title, album: album).id("\(album ?? "")|\(title ?? "")")
        if let window {
            window.contentViewController = NSHostingController(rootView: view)
        } else {
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Add Subtitles"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        if let window { bringToFront(window) }
    }
}

struct AddSubtitlesView: View {
    let model: AppModel
    let title: String?
    let album: String?

    @State private var base = ""
    @State private var timing = ""
    @State private var target = ""
    @State private var importMessage: String?
    @State private var lowMatch: (percent: Int, cues: [Cue])?
    @State private var askingURL = false
    @State private var urlText = ""

    private var entry: SubtitleLibrary.Entry? {
        title.flatMap { model.entry(title: $0, album: album) }
    }

    var body: some View {
        Form {
            if let title {
                Section {
                    LabeledContent("Title", value: title)
                    if let album { LabeledContent("Show", value: album) }
                }
                if let entry {
                    form(entry)
                } else {
                    Section {
                        Text("No subtitles captured for this title. Press Download on it in the TV app.")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Text("Play a title in the TV app first.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .alert("Translation Failed", isPresented: errorShown, presenting: model.translation?.error) { _ in
            Button("OK") { model.dismissTranslationError() }
        } message: { Text($0) }
    }

    @ViewBuilder
    private func form(_ entry: SubtitleLibrary.Entry) -> some View {
        let apple = entry.meta.appleLanguages
        let appleBases = Set(apple.map(Languages.base))
        if let parts = entry.meta.parts, !parts.isEmpty {
            Section("Parts") { TitlePartsView(entry: entry, parts: parts) }
        }
        Section("Translation") {
            Picker("Translate from", selection: $base) {
                ForEach(apple, id: \.self) { Text(Languages.name($0)).tag($0) }
            }
            Picker("Timing from", selection: $timing) {
                let automatic = AddSubtitlesDefaults.timing("", apple: apple, base: base, target: target)
                Text("Automatic (\(Languages.name(automatic)))").tag("")
                ForEach(apple, id: \.self) { Text(Languages.name($0)).tag($0) }
            }
            Picker("Translate into", selection: $target) {
                ForEach(Languages.all.filter { !appleBases.contains($0) }, id: \.self) { Text(Languages.name($0)).tag($0) }
            }
            if let hint = AddSubtitlesDefaults.replaceHint(entry, target: target) {
                Text(hint).font(.callout).foregroundStyle(.secondary)
            }
        }
        .onChange(of: base) { if !base.isEmpty { model.saveChoices(entry, base: base, timing: timing) } }
        .onChange(of: timing) { if !base.isEmpty { model.saveChoices(entry, base: base, timing: timing) } }
        Section {
            if let t = model.translation, t.error == nil {
                HStack {
                    ProgressView(value: t.progress)
                    Button("Cancel", role: .cancel) { model.cancelTranslation() }
                }
            } else {
                HStack {
                    if let existing = entry.meta.targetLanguage {
                        Text("Current: \(Languages.name(existing))").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(AddSubtitlesDefaults.replaceHint(entry, target: target) == nil ? "Translate" : "Translate Again") {
                        model.translate(entry, base: base, timing: timing, target: target)
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(base.isEmpty || target.isEmpty)
                }
            }
        }
        Section {
            HStack {
                Button("Import File…") { importFile(entry) }
                Button("Import from URL…") { askingURL = true }
                Spacer()
            }
            Text(importMessage ?? "Use a \(Languages.name(target)) subtitle made by a person. It is timed to this title and saved as its \(Languages.name(target)) track.")
                .font(.callout).foregroundStyle(.secondary)
        } header: {
            Text("Human Translation")
        }
        .onAppear { setDefaults(entry) }
        .alert("Import from URL", isPresented: $askingURL) {
            TextField("https://", text: $urlText)
            Button("Import") { importURL(entry) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A link to an .srt, .vtt or .ass file.")
        }
        .confirmationDialog("This file may not fit this title.", isPresented: lowMatchShown) {
            Button("Save Anyway") { saveLowMatch(entry) }
            Button("Cancel", role: .cancel) { lowMatch = nil }
        } message: {
            Text("Only \(lowMatch?.percent ?? 0)% of its lines match this title's speech. It may be another episode or cut.")
        }
    }

    private var lowMatchShown: Binding<Bool> {
        Binding(get: { lowMatch != nil }, set: { if !$0 { lowMatch = nil } })
    }

    private func importFile(_ entry: SubtitleLibrary.Entry) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = ["srt", "vtt", "ass", "ssa"].compactMap { UTType(filenameExtension: $0) } + [.plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        importData(entry) { try Data(contentsOf: url) }
    }

    private func importURL(_ entry: SubtitleLibrary.Entry) {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else {
            importMessage = "That is not a valid link."
            return
        }
        importMessage = "Downloading…"
        Task { importData(entry, data: await Result { try await SubtitleDownload.fetch(url) }) }
    }

    private func importData(_ entry: SubtitleLibrary.Entry, read: () throws -> Data) {
        importData(entry, data: Result(catching: read))
    }

    private func importData(_ entry: SubtitleLibrary.Entry, data: Result<Data, Error>) {
        let track = AddSubtitlesDefaults.timing(timing, apple: entry.meta.appleLanguages, base: base, target: target)
        do {
            switch try model.importBacking(entry, data: data.get(), base: base, timingTrack: track, target: target) {
            case .saved(let lines): importMessage = "Saved \(lines) lines as the \(Languages.name(target)) track."
            case .lowMatch(let percent, let cues): importMessage = nil; lowMatch = (percent, cues)
            }
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private func saveLowMatch(_ entry: SubtitleLibrary.Entry) {
        guard let cues = lowMatch?.cues else { return }
        lowMatch = nil
        let track = AddSubtitlesDefaults.timing(timing, apple: entry.meta.appleLanguages, base: base, target: target)
        do {
            let lines = try model.saveBacking(entry, cues: cues, base: base, timingTrack: track, target: target)
            importMessage = "Saved \(lines) lines as the \(Languages.name(target)) track."
        } catch {
            importMessage = "Import failed: \(error.localizedDescription)"
        }
    }

    private var errorShown: Binding<Bool> {
        Binding(get: { model.translation?.error != nil }, set: { if !$0 { model.dismissTranslationError() } })
    }

    private func setDefaults(_ entry: SubtitleLibrary.Entry) {
        let d = AddSubtitlesDefaults(entry.meta, preferredTarget: Preferences.defaultTarget)
        base = d.base
        timing = d.timing
        target = d.target
    }
}

/// First choices in the form: the title's saved choices, else the film's original language
/// (or English), automatic timing and the user's preferred target.
struct AddSubtitlesDefaults: Equatable {
    /// Shown when the chosen target already has a saved translation.
    static func replaceHint(_ entry: SubtitleLibrary.Entry, target: String) -> String? {
        guard !entry.meta.appleLanguages.contains(target), entry.hasTrack(target) else { return nil }
        return "A \(Languages.name(target)) translation is saved. Translating again replaces it."
    }

    /// The Apple track whose cues the translation follows. Automatic (""): for a right-to-left
    /// target, a right-to-left track (Arabic first), whose cues split the dialogue the way the
    /// target reads; else the base track.
    static func timing(_ choice: String, apple: [String], base: String, target: String) -> String {
        guard choice.isEmpty else { return choice }
        guard Languages.isRightToLeft(target) else { return base }
        let rightToLeft = apple.filter(Languages.isRightToLeft)
        return rightToLeft.first { Languages.base($0) == "ar" } ?? rightToLeft.first ?? base
    }

    var base: String
    var timing: String
    var target: String

    init(_ meta: TitleMeta, preferredTarget: String) {
        let apple = meta.appleLanguages
        let appleBases = Set(apple.map(Languages.base))
        let original = meta.originalLanguage.flatMap { o in apple.first { $0 == o } ?? apple.first { Languages.base($0) == Languages.base(o) } }
        base = meta.baseLanguage ?? original ?? (apple.first { Languages.base($0) == "en" } ?? apple.first ?? "")
        timing = meta.timingLanguage ?? ""
        let wanted = meta.targetLanguage ?? preferredTarget
        target = appleBases.contains(Languages.base(wanted)) ? (Languages.all.first { !appleBases.contains($0) } ?? "") : wanted
    }
}
