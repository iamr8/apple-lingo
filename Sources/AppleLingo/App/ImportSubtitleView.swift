import AppKit
import AppleLingoCore
import SwiftUI
import UniformTypeIdentifiers

/// Hosts the Import Subtitle form in one reusable window.
@MainActor
final class ImportSubtitleWindow {
    private weak var model: AppModel?
    private var window: NSWindow?

    init(model: AppModel) {
        self.model = model
    }

    func show() {
        guard let model else { return }
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ImportSubtitleView(model: model)))
            window.title = "Import Subtitle"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        if let window { bringToFront(window) }
    }
}

/// A human translation for the playing title: a file or a link, timed to the title and saved
/// as its target track.
struct ImportSubtitleView: View {
    let model: AppModel

    @State private var message: String?
    @State private var lowMatch: (percent: Int, cues: [Cue])?
    @State private var askingURL = false
    @State private var urlText = ""

    var body: some View {
        Form {
            if let playing = model.nowPlaying {
                Section {
                    LabeledContent("Title", value: playing.title)
                    if let album = playing.album, !album.isEmpty { LabeledContent("Show", value: album) }
                }
                if let entry = model.entry {
                    form(entry)
                } else {
                    Section {
                        Text("No subtitles captured for this title. Press Download on it in the TV app, then cancel.")
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
    }

    @ViewBuilder
    private func form(_ entry: SubtitleLibrary.Entry) -> some View {
        let target = Languages.name(Preferences.languages.target)
        Section {
            HStack {
                Button("Import File…") { importFile(entry) }
                Button("Import from URL…") { askingURL = true }
                Spacer()
            }
            Text(message ?? "Use a \(target) subtitle made by a person. It is timed to this title and saved as its \(target) track. A translation of the title that runs is stopped.")
                .font(.callout).foregroundStyle(.secondary)
        }
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
        importData(entry, data: Result { try Data(contentsOf: url) })
    }

    private func importURL(_ entry: SubtitleLibrary.Entry) {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)) else {
            message = "That is not a valid link."
            return
        }
        message = "Downloading…"
        Task { importData(entry, data: await Result { try await SubtitleDownload.fetch(url) }) }
    }

    private func importData(_ entry: SubtitleLibrary.Entry, data: Result<Data, Error>) {
        do {
            switch try model.importBacking(entry, data: data.get()) {
            case .saved(let lines, let scale): message = saved(lines, scale: scale)
            case .lowMatch(let percent, let cues): message = nil; lowMatch = (percent, cues)
            }
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }

    private func saveLowMatch(_ entry: SubtitleLibrary.Entry) {
        guard let cues = lowMatch?.cues else { return }
        lowMatch = nil
        do {
            message = saved(try model.saveBacking(entry, cues: cues))
        } catch {
            message = "Import failed: \(error.localizedDescription)"
        }
    }

    private func saved(_ lines: Int, scale: Double = 1) -> String {
        let text = "Saved \(lines) lines as the \(Languages.name(Preferences.languages.target)) track."
        guard scale != 1 else { return text }
        let percent = abs(scale - 1) * 100
        return text + " The file was made for another frame rate, so its timing was \(scale > 1 ? "stretched" : "shrunk") by \(percent.formatted(.number.precision(.fractionLength(1))))%."
    }
}
