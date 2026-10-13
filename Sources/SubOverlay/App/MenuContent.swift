import SubOverlayCore
import SwiftUI

struct MenuContent: View {
    let model: AppModel

    var body: some View {
        Text(titleLine)
        Text(statusLine)
        Divider()
        Button("Add Subtitles…") { model.showAddSubtitles() }
        if model.entry?.meta.targetLanguage != nil {
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
        MenuText.status(adapterFailed: model.adapterFailed, translation: model.translation, playing: model.nowPlaying != nil,
                        meta: model.entry?.meta, hasEntry: model.entry != nil)
    }
}

enum MenuText {
    static func title(_ playing: PlaybackState?) -> String {
        guard let playing else { return "Nothing playing in TV" }
        if let album = playing.album, !album.isEmpty { return "\(album) – \(playing.title)" }
        return playing.title
    }

    static func status(adapterFailed: Bool, translation: AppModel.TranslationStatus?, playing: Bool,
                       meta: TitleMeta?, hasEntry: Bool) -> String {
        if adapterFailed { return "Cannot read Now Playing" }
        if let t = translation {
            return t.error == nil ? "Translating… \(Int((t.progress * 100).rounded()))%" : "Translation failed"
        }
        guard playing else { return "Idle" }
        if let target = meta?.targetLanguage { return "Showing \(Languages.name(target))" }
        return hasEntry ? "No translation yet" : "No subtitles captured"
    }
}
