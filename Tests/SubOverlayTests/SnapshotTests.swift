import AppKit
import SnapshotTesting
import SwiftUI
import Testing
@testable import SubOverlay
@testable import SubOverlayCore

/// Image snapshots of the real views, rendered in-process in light mode.
/// Re-record after an intended visual change with `SNAPSHOT_TESTING_RECORD=all swift test`.
@MainActor
@Suite(.serialized)
struct SnapshotTests {
    /// Apple's default caption settings as read on macOS 27 (spike S2).
    static let appleDefault = CaptionStyle(RawCaptionAppearance(
        fontName: ".AppleSystemUIFontMedium", relativeSize: 1,
        text: RGBA(r: 1, g: 1, b: 1, a: 1), textOpacity: 1,
        background: RGBA(r: 0, g: 0, b: 0, a: 1), backgroundOpacity: 0,
        window: RGBA(r: 0, g: 0, b: 0, a: 1), windowOpacity: 0.5, windowCornerRadius: 8,
        edgeStyle: 1))

    let library = SubtitleLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))

    func model() -> AppModel {
        AppModel(library: library, keychain: Keychain(service: "test.\(UUID())"), notify: { _, _ in })
    }

    func host(_ view: some View, width: CGFloat) -> NSView {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, .light))
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.frame = CGRect(origin: .zero, size: CGSize(width: width, height: hosting.fittingSize.height))
        return hosting
    }

    // Breaks if RTL text, italics, Apple's cue position, the window box or stacking render wrong.
    @Test func captionView() {
        let video = NSView(frame: CGRect(x: 0, y: 0, width: 1280, height: 720))
        video.wantsLayer = true
        video.layer?.backgroundColor = NSColor(white: 0.35, alpha: 1).cgColor
        let captions = CaptionView(frame: video.bounds)
        captions.style = Self.appleDefault
        captions.rightToLeft = true
        let apple = "align:middle line:85%,start position:50%,middle"
        captions.cues = [
            Cue(id: 1, start: 0, end: 2, text: "می‌خوایم به یه زندان دیگه منتقل بشی\nو با یه نفر دوست بشی.", settings: apple),
            Cue(id: 2, start: 0, end: 2, text: "یه چیزی تو این چشم‌های پرمعنات هست.", settings: apple, italic: true),
        ]
        video.addSubview(captions)
        assertSnapshot(of: video, as: .image)
    }

    // Breaks if the import form loses its buttons or what it tells about the file.
    @Test func importSubtitle() throws {
        try library.ingest(title: "Pilot", album: "Black Bird", tracks: ["ar": [], "en": []], sourcePackage: "Pilot.tmp")
        let model = model()
        model.update(PlaybackState(title: "Pilot", album: "Black Bird", elapsedAtAnchor: 0, rate: 1, playing: false, anchor: .now))
        model.cancelTranslation(key: model.queue.running?.key ?? "")
        assertSnapshot(of: host(ImportSubtitleView(model: model), width: 440), as: .image)
    }

    // Breaks if the General settings lose a language picker or a shortcut recorder.
    @Test func settingsGeneral() {
        assertSnapshot(of: host(SettingsView(model: model()), width: 480), as: .image)
    }

    // Breaks if right-to-left text is drawn italic; Persian and Arabic fonts have no true italic.
    @Test func noItalicInRightToLeft() {
        let view = CaptionView(frame: CGRect(x: 0, y: 0, width: 1000, height: 500))
        let cue = Cue(id: 1, start: 0, end: 1, text: "سلام", italic: true)
        func italic(_ rtl: Bool) -> Bool {
            view.rightToLeft = rtl
            let font = view.attributed(cue, fontSize: 30).attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            return font.fontDescriptor.symbolicTraits.contains(.italic)
        }
        #expect(italic(false))
        #expect(!italic(true))
    }
}
