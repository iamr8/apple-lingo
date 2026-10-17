import SubOverlayCore
import SwiftUI

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(titleLine)
        Text(statusLine)
        Divider()
        Button("Import Subtitle…") { model.showImport() }
        if model.shownLanguage != nil {
            Text("Offset: \(model.offset, format: .number.precision(.fractionLength(1)).sign(strategy: .always())) s")
            if model.offset != 0 {
                Button("Reset Offset") { model.resetOffset() }
            }
        }
        Divider()
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Button("Quit SubOverlay") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    private var titleLine: String { MenuText.title(model.nowPlaying) }

    private var statusLine: String {
        MenuText.status(adapterFailed: model.adapterFailed, translating: model.queue.running?.progress, playing: model.nowPlaying != nil,
                        shown: model.shownLanguage, hasEntry: model.entry != nil)
    }
}

enum MenuText {
    static func title(_ playing: PlaybackState?) -> String {
        guard let playing else { return "Nothing playing in TV" }
        if let album = playing.album, !album.isEmpty { return "\(album) – \(playing.title)" }
        return playing.title
    }

    static func status(adapterFailed: Bool, translating: Double?, playing: Bool, shown: String?, hasEntry: Bool) -> String {
        if adapterFailed { return "Cannot read Now Playing" }
        if let translating { return "Translating… \(Int((translating * 100).rounded()))%" }
        guard playing else { return "Idle" }
        if let shown { return "Showing \(Languages.name(shown))" }
        return hasEntry ? "No translation yet" : "No subtitles captured"
    }
}
