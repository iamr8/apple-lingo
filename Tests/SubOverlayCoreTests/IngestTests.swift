import Foundation
import Testing
@testable import SubOverlayCore

enum Fixture {
    static let downloads = Bundle.module.resourceURL!.appending(path: "Fixtures/Downloads-TV")
    static let folder = "Part One.tmp"
    static var package: URL { downloads.appending(path: folder).appending(path: "download.movpkg") }

    /// A writable copy of the fixture package.
    static func copy() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: folder)
        try FileManager.default.copyItem(at: downloads.appending(path: folder), to: target)
        // boot.xml names this stream folder; git keeps no empty folder, so a clone lacks it.
        let package = target.appending(path: "download.movpkg")
        try FileManager.default.createDirectory(at: package.appending(path: "0-VIDEO"), withIntermediateDirectories: true)
        return package
    }
}

struct WebVTTTests {
    // Breaks if a lone CR (Apple's line break in some titles, valid WebVTT) stays in cue text,
    // which the model copies and validation then rejects.
    @Test func loneCarriageReturnIsALineBreak() {
        let cues = WebVTT.parse("WEBVTT\n\n00:01.000 --> 00:02.000\nShe in any of your dreams?\rLook at the photo here.\n")
        #expect(cues.map(\.text) == ["She in any of your dreams?\nLook at the photo here."])
        let crOnly = WebVTT.parse("WEBVTT\r\r00:01.000 --> 00:02.000\rHi\rthere\r")
        #expect(crOnly.map(\.text) == ["Hi\nthere"])
    }

    // Breaks if cue settings are dropped or the header lines are read as cues.
    @Test func parsesAppleFragment() {
        let text = """
        WEBVTT
        X-TIMESTAMP-MAP=MPEGTS:900000,LOCAL:00:00:00.000

        1
        00:00:20.103 --> 00:00:22.022 align:middle line:85%,start position:50%,middle
        - First line
        second line

        NOTE a comment
        with two lines

        01:02.500 --> 01:03.000
        Short &amp; sweet
        """
        let cues = WebVTT.parse(text)
        #expect(cues.count == 2)
        #expect(cues[0].start == 20.103 && cues[0].end == 22.022)
        #expect(cues[0].settings == "align:middle line:85%,start position:50%,middle")
        #expect(cues[0].text == "- First line\nsecond line")
        #expect(cues[1].start == 62.5)
        #expect(cues[1].text == "Short & sweet")
    }

    // Breaks if Apple's italic class is not detected or its markup is left in the text.
    @Test func detectsItalicAndStripsMarkup() {
        let cues = WebVTT.parse("WEBVTT\n\n00:01.000 --> 00:02.000\n<c.styledotitalic>Hi</c> <b>there</b>\n")
        #expect(cues.first?.italic == true)
        #expect(cues.first?.text == "Hi there")
    }

    // Breaks if Apple's blank cues (only a zero-width space) are kept.
    @Test func dropsBlankCues() {
        let cues = WebVTT.parse("WEBVTT\n\n00:07.793 --> 00:08.126\n\u{200B}\n\n00:09.000 --> 00:10.000\nHi\n")
        #expect(cues.map(\.text) == ["Hi"])
        #expect(cues.map(\.id) == [1])
    }

    // Breaks if the cue cap is not enforced.
    @Test func capsCueCount() {
        let body = (0..<10).map { "00:0\($0).000 --> 00:0\($0).500\nx\($0)\n" }.joined(separator: "\n")
        #expect(WebVTT.parse("WEBVTT\n\n" + body, maxCues: 3).count == 3)
    }

    // Breaks if writing loses timings, settings, italic, or escapes text wrongly.
    @Test func roundTrips() {
        let cues = [
            Cue(id: 1, start: 3725.5, end: 3726.25, text: "a < b\nسلام", settings: "line:85%,start", italic: true),
            Cue(id: 2, start: 1, end: 2, text: "plain"),
        ]
        let back = WebVTT.parse(WebVTT.write(cues))
        #expect(back == cues)
    }
}

struct MoviePackageReaderTests {
    // Breaks if the folder name split ignores the " _ " separator.
    @Test func namesFromFolder() {
        #expect(MoviePackageReader.names(fromFolder: "Some Title_ Part One _ Some Show _ Some Artist.tmp") == .init(title: "Some Title_ Part One", album: "Some Show"))
        #expect(MoviePackageReader.names(fromFolder: "Only.tmp") == .init(title: "Only", album: ""))
    }

    // Breaks if languages are not taken from the master playlist, forced tracks are kept,
    // or an SDH track wins over the plain track of the same language.
    @Test func manifestListsSubtitleTracks() throws {
        let m = try MoviePackageReader.manifest(package: Fixture.package)
        #expect(m.tracks.map(\.language) == ["ar", "fr-FR"])
        #expect(m.tracks.map(\.path) == ["2-AR", "2-FR"])
        #expect(m.allComplete)
        #expect(m.tracks[0].url == URL(string: "https://example.invalid/hls/stream/playlist.m3u8?id=ar&t=TOKEN%2B1"))
    }

    // Breaks if the show and episode names are not read from the master playlist.
    @Test func manifestNamesFromSessionData() throws {
        let m = try MoviePackageReader.manifest(package: Fixture.package)
        #expect(m.title == "Part One")
        #expect(m.album == "Some Show")
    }

    // Breaks if a movie (no episode title) does not use the title as the title.
    @Test func movieNamesFromSessionData() throws {
        let pkg = try Fixture.copy()
        let master = pkg.appending(path: "Data/Playlist-AAAA-master.m3u8")
        let text = try String(contentsOf: master, encoding: .utf8)
        try text.split(separator: "\n").filter { !$0.contains("episode-title") }.joined(separator: "\n")
            .write(to: master, atomically: true, encoding: .utf8)
        let m = try MoviePackageReader.manifest(package: pkg)
        #expect(m.title == "Some Show")
        #expect(m.album == "")
    }

    // Breaks if the original language is not the audio marked public.original-content, or a
    // package without the mark gets a guessed language. Lines in Apple's format.
    @Test func originalLanguageFromAudio() throws {
        #expect(try MoviePackageReader.manifest(package: Fixture.package).originalLanguage == nil)
        let pkg = try Fixture.copy()
        let master = pkg.appending(path: "Data/Playlist-AAAA-master.m3u8")
        let text = try String(contentsOf: master, encoding: .utf8)
        let audio = """
        #EXT-X-MEDIA:TYPE=AUDIO,NAME="Deutsch",GROUP-ID="aud",LANGUAGE="de",DEFAULT=NO,AUTOSELECT=YES,CHANNELS="2",URI="a/de.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,NAME="Français",GROUP-ID="aud",LANGUAGE="fr",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",CHARACTERISTICS="com.apple.amp.tv.is-default,public.original-content",URI="a/fr.m3u8"
        """
        try (text + "\n" + audio + "\n").write(to: master, atomically: true, encoding: .utf8)
        #expect(try MoviePackageReader.manifest(package: pkg).originalLanguage == "fr")
    }

    // Breaks if the video length is not the video stream's playlist (its intro included), so the
    // stream lead cannot be measured, or another stream's playlist is used.
    @Test func videoDurationFromVideoPlaylist() throws {
        #expect(try MoviePackageReader.manifest(package: Fixture.package).videoDuration == nil)
        let pkg = try Fixture.copy()
        let master = pkg.appending(path: "Data/Playlist-AAAA-master.m3u8")
        let text = try String(contentsOf: master, encoding: .utf8)
        try (text + "\n#EXT-X-STREAM-INF:BANDWIDTH=3778224,CODECS=\"avc1.64001f\"\nstream/playlist.m3u8?g=750&t=TOKEN\n")
            .write(to: master, atomically: true, encoding: .utf8)
        try "#EXTM3U\n#EXTINF:8.0,\na.frag\n#EXT-X-DISCONTINUITY\n#EXTINF:100.5,\nb.frag\n#EXTINF:20.25,\nc.frag\n"
            .write(to: pkg.appending(path: "0-VIDEO/0-V.m3u8"), atomically: true, encoding: .utf8)
        try "#EXTM3U\n#EXTINF:999.0,\nx.frag\n".write(to: pkg.appending(path: "2-AR/2-A.m3u8"), atomically: true, encoding: .utf8)
        #expect(try MoviePackageReader.manifest(package: pkg).videoDuration == 128.75)
    }

    // Breaks if Apple's interstitials are not split into an intro (no dialogue) and a recap (with
    // dialogue), the content does not start where the last one ends (its video segment starts
    // 0.26 s earlier), the clips after it are not one part, or a plain playlist gets parts other
    // than the content, or another kind of date range counts. Lines in Apple's format, times from Hand to Mouth.
    @Test func partsFromVideoPlaylist() {
        let playlist = """
        #EXTM3U
        #EXT-X-PROGRAM-DATE-TIME:2000-01-01T00:00:00Z
        #EXT-X-DATERANGE:ID="inter1",START-DATE="2000-01-01T00:00:00Z",DURATION=8.126,CLASS="com.apple.hls.interstitial",X-RESUME-OFFSET=8.126,X-TIMELINE-OCCUPIES="RANGE"
        #EXT-X-DATERANGE:ID="inter2",START-DATE="2000-01-01T00:00:08.126Z",DURATION=33.762,CLASS="com.apple.hls.interstitial",X-RESUME-OFFSET=33.762,X-TIMELINE-OCCUPIES="RANGE"
        #EXT-X-DATERANGE:ID="chapter",START-DATE="2000-01-01T00:00:20Z",DURATION=5.0,CLASS="com.example.other"
        #EXTINF:8.008,
        a.mp4
        #EXT-X-DISCONTINUITY
        #EXTINF:33.617,
        b.mp4
        #EXT-X-DISCONTINUITY
        #EXTINF:3000.0,
        c.mp4
        #EXTINF:526.481,
        d.mp4
        #EXT-X-DISCONTINUITY
        #EXTINF:8.008,
        e.mp4
        #EXT-X-DISCONTINUITY
        #EXTINF:12.012,
        f.mp4
        """
        let dialogue = [Cue(id: 1, start: 9.126, end: 11.6, text: "a"), Cue(id: 2, start: 120, end: 122, text: "b")]
        let parts = MoviePackageReader.parts(playlist: playlist, dialogue: dialogue)
        #expect(parts.map(\.kind) == [.intro, .recap, .content, .after])
        #expect(parts.map(\.start) == [0, 8.126, 41.888, 3568.106])
        let lengths = [8.126, 33.762, 3526.218, 20.02]
        #expect(zip(parts.map(\.duration), lengths).allSatisfy { abs($0 - $1) < 1e-6 })
        let plain = MoviePackageReader.parts(playlist: "#EXTM3U\n#EXTINF:100.5,\na.mp4\n#EXTINF:20.0,\nb.mp4\n", dialogue: dialogue)
        #expect(plain == [TitlePart(kind: .content, start: 0, duration: 120.5)])
    }

    // Breaks if the parts are not read from the video stream's playlist.
    @Test func partsFromPackage() throws {
        #expect(try MoviePackageReader.parts(MoviePackageReader.manifest(package: Fixture.package), package: Fixture.package, dialogue: []) == [])
        let pkg = try Fixture.copy()
        let master = pkg.appending(path: "Data/Playlist-AAAA-master.m3u8")
        let text = try String(contentsOf: master, encoding: .utf8)
        try (text + "\n#EXT-X-STREAM-INF:BANDWIDTH=3778224,CODECS=\"avc1.64001f\"\nstream/playlist.m3u8?g=750&t=TOKEN\n")
            .write(to: master, atomically: true, encoding: .utf8)
        try "#EXTM3U\n#EXTINF:8.0,\na.frag\n#EXT-X-DISCONTINUITY\n#EXTINF:100.5,\nb.frag\n"
            .write(to: pkg.appending(path: "0-VIDEO/0-V.m3u8"), atomically: true, encoding: .utf8)
        let parts = try MoviePackageReader.parts(MoviePackageReader.manifest(package: pkg), package: pkg, dialogue: [])
        #expect(parts == [TitlePart(kind: .intro, start: 0, duration: 8), TitlePart(kind: .content, start: 8, duration: 100.5)])
    }

    // Breaks if an SDH track is dropped when it is the only track of its language.
    @Test func sdhUsedWhenNoPlainTrack() throws {
        let pkg = try Fixture.copy()
        let master = pkg.appending(path: "Data/Playlist-AAAA-master.m3u8")
        let text = try String(contentsOf: master, encoding: .utf8)
        try text.split(separator: "\n").filter { !$0.contains("id=fr&") }.joined(separator: "\n")
            .write(to: master, atomically: true, encoding: .utf8)
        #expect(try MoviePackageReader.manifest(package: pkg).tracks.map(\.path) == ["2-AR", "2-FRSDH"])
    }

    // Breaks if fragments are read in name order, deduped wrongly, or shifted by X-TIMESTAMP-MAP.
    @Test func readsTrackInTimeOrderWithoutShift() throws {
        let m = try MoviePackageReader.manifest(package: Fixture.package)
        let cues = try MoviePackageReader.readTrack(m.tracks[0], package: Fixture.package)
        #expect(cues.count == 33)
        #expect(cues.first?.start == 20.103)
        #expect(cues.last?.start == 1071.029)
        #expect(cues.map(\.id) == Array(1...33))
        #expect(zip(cues, cues.dropFirst()).allSatisfy { $0.start <= $1.start })
        #expect(cues[0].settings == "align:middle line:85%,start position:50%,middle")
    }

    // Breaks if decimal fragment names (Apple TV+ packages) are skipped or sorted as text.
    @Test func decimalFragmentNames() {
        #expect(MoviePackageReader.fragmentStart("(1028.13)_(0)_(60).frag") == 1028.13)
        #expect(MoviePackageReader.fragmentStart("(0)_(0)_(8.12601).frag") == 0)
        #expect(MoviePackageReader.fragmentStart("(12)_(0)_(60).frag") == 12)
        #expect(MoviePackageReader.fragmentStart("(1e9)_(0)_(60).frag") == nil)
        #expect(MoviePackageReader.fragmentStart("x.frag") == nil)
    }

    // Breaks if the pre-roll is not read as the segment time before the first discontinuity.
    @Test func preRollFromMediaPlaylist() {
        let playlist = "#EXTM3U\n#EXTINF:5.0,\nhttps://a/1\n#EXTINF:3.126,\nhttps://a/2\n#EXT-X-DISCONTINUITY\n#EXTINF:60.0,\nhttps://a/3\n"
        #expect(abs(MoviePackageReader.preRoll(playlist: playlist) - 8.126) < 1e-9)
        #expect(MoviePackageReader.preRoll(playlist: "#EXTM3U\n#EXTINF:60.0,\nhttps://a/1\n") == 0)
        #expect(MoviePackageReader.preRoll(playlist: "#EXTINF:900,\nx\n#EXT-X-DISCONTINUITY\n") == 0)
    }

    // Breaks if cues are not moved later by the pre-roll the Now Playing clock counts, or if
    // cues of the pre-roll fragment (its own timeline) are kept.
    @Test func cueTimesAddPreRoll() throws {
        let pkg = try Fixture.copy()
        let m = try MoviePackageReader.manifest(package: pkg)
        let dir = pkg.appending(path: m.tracks[0].path)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir.appending(path: name))
        }
        try "#EXTM3U\n#EXTINF:8.126,\nhttps://a/0\n#EXT-X-DISCONTINUITY\n#EXTINF:60.0,\nhttps://a/1\n"
            .write(to: dir.appending(path: "2-X-1.m3u8"), atomically: true, encoding: .utf8)
        try "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nIntro\n"
            .write(to: dir.appending(path: "(0)_(0)_(8.126).frag"), atomically: true, encoding: .utf8)
        try "WEBVTT\n\n00:00:05.000 --> 00:00:06.500\nHello\n"
            .write(to: dir.appending(path: "(8.126)_(0)_(60).frag"), atomically: true, encoding: .utf8)
        let cues = try MoviePackageReader.readTrack(m.tracks[0], package: pkg)
        #expect(cues.map(\.text) == ["Hello"])
        #expect(abs(cues[0].start - 13.126) < 1e-9)
        #expect(abs(cues[0].end - 14.626) < 1e-9)
    }

    // Breaks if a fragment's cue times do not count from the start of its discontinuity period.
    // Layout and times from Hand to Mouth's Arabic track: the preview restarts at 8.126 s, the
    // episode at 41.888 s after the 33.762 s promo slot; adding 8.126 to both put every episode
    // line 33.762 s early.
    @Test func cueTimesCountFromTheirPeriod() throws {
        let pkg = try Fixture.copy()
        let m = try MoviePackageReader.manifest(package: pkg)
        let dir = pkg.appending(path: m.tracks[0].path)
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            try FileManager.default.removeItem(at: dir.appending(path: name))
        }
        try "#EXTM3U\n#EXTINF:8.126,\na\n#EXT-X-DISCONTINUITY\n#EXTINF:33.762,\nb\n#EXT-X-DISCONTINUITY\n#EXTINF:3526.6,\nc\n"
            .write(to: dir.appending(path: "2-X-1.m3u8"), atomically: true, encoding: .utf8)
        try "WEBVTT\n\n00:00:01.000 --> 00:00:03.545\nPreview\n"
            .write(to: dir.appending(path: "(8.126)_(0)_(33.762).frag"), atomically: true, encoding: .utf8)
        try "WEBVTT\n\n00:00:53.053 --> 00:00:54.388\nEpisode\n"
            .write(to: dir.appending(path: "(41.888)_(0)_(3526.6).frag"), atomically: true, encoding: .utf8)
        let cues = try MoviePackageReader.readTrack(m.tracks[0], package: pkg)
        #expect(cues.map(\.text) == ["Preview", "Episode"])
        #expect(abs(cues[0].start - 9.126) < 1e-6)
        #expect(abs(cues[1].start - 94.941) < 1e-6)
        #expect(abs(cues[1].end - 96.276) < 1e-6)
    }

    // Breaks if a track without a media playlist is shifted.
    @Test func noPlaylistMeansNoShift() throws {
        let m = try MoviePackageReader.manifest(package: Fixture.package)
        let cues = try MoviePackageReader.readTrack(m.tracks[0], package: Fixture.package)
        #expect(abs(cues[0].start - 20.103) < 1e-9)
        #expect(cues.count == 33)
    }

    // Breaks if an incomplete subtitle stream still counts as complete.
    @Test func incompleteStreamIsReported() throws {
        let pkg = try Fixture.copy()
        let boot = pkg.appending(path: "boot.xml")
        let xml = try String(contentsOf: boot, encoding: .utf8)
        try xml.replacingOccurrences(of: "Path=\"2-FR\">\n      <Complete>YES",
                                     with: "Path=\"2-FR\">\n      <Complete>NO")
            .write(to: boot, atomically: true, encoding: .utf8)
        #expect(try !MoviePackageReader.manifest(package: pkg).allComplete)
    }

    // Breaks if a stream path can leave the package.
    @Test func rejectsEscapingPath() throws {
        let pkg = try Fixture.copy()
        let boot = pkg.appending(path: "boot.xml")
        let xml = try String(contentsOf: boot, encoding: .utf8)
        try xml.replacingOccurrences(of: "Path=\"2-AR\"", with: "Path=\"../2-AR\"").write(to: boot, atomically: true, encoding: .utf8)
        #expect(try MoviePackageReader.manifest(package: pkg).tracks.map(\.language) == ["fr-FR"])
    }

    // Breaks if a symlinked fragment is followed.
    @Test func rejectsSymlinkedFragment() throws {
        let pkg = try Fixture.copy()
        let frag = pkg.appending(path: "2-FR/(0)_(0)_(60).frag")
        try FileManager.default.removeItem(at: frag)
        try FileManager.default.createSymbolicLink(at: frag, withDestinationURL: Fixture.package.appending(path: "2-FR/(0)_(0)_(60).frag"))
        let m = try MoviePackageReader.manifest(package: pkg)
        #expect(throws: MoviePackageReader.ReadError.self) { try MoviePackageReader.readTrack(m.tracks[1], package: pkg) }
    }

    // Breaks if the per-file size cap is not enforced.
    @Test func rejectsOversizeFragment() throws {
        let pkg = try Fixture.copy()
        let frag = pkg.appending(path: "2-FR/(0)_(0)_(60).frag")
        try Data(count: MoviePackageReader.maxFragmentBytes + 1).write(to: frag)
        let m = try MoviePackageReader.manifest(package: pkg)
        #expect(throws: MoviePackageReader.ReadError.self) { try MoviePackageReader.readTrack(m.tracks[1], package: pkg) }
    }
}

struct SubtitleLibraryTests {
    func library() -> SubtitleLibrary {
        SubtitleLibrary(root: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString))
    }

    // Breaks if slugs differ between the folder name ("_") and Now Playing (":").
    @Test func slugMatchesFolderAndNowPlaying() {
        #expect(Slug.make("Furiosa_ A Mad Max Saga") == Slug.make("Furiosa: A Mad Max Saga"))
        #expect(Slug.make("../../etc") == "etc")
        #expect(Slug.make("///") == "untitled")
    }

    // Breaks if ingest does not store every track, or lookup by Now Playing names fails.
    @Test func ingestThenLookup() throws {
        let lib = library()
        let cues = [Cue(id: 1, start: 1, end: 2, text: "x", settings: "line:85%,start")]
        try lib.ingest(title: "Some Title_ Part One", album: "Some Show", tracks: ["ar": cues, "en": cues], sourcePackage: "p.tmp")
        let entry = try #require(lib.entry(album: "Some Show", title: "Some Title: Part One"))
        #expect(entry.meta.appleLanguages == ["ar", "en"])
        #expect(try entry.cues(language: "en") == cues)
    }

    // Breaks if the original language is not kept with the title, so the form cannot default to it.
    @Test func ingestKeepsOriginalLanguage() throws {
        let lib = library()
        try lib.ingest(title: "T", album: "A", tracks: ["en": [], "fr-FR": []], sourcePackage: "p.tmp", originalLanguage: "fr")
        #expect(lib.entry(album: "A", title: "T")?.meta.originalLanguage == "fr")
    }

    // Breaks if the parts are not kept with the title, so the form cannot show them.
    @Test func ingestKeepsParts() throws {
        let lib = library()
        let parts = [TitlePart(kind: .intro, start: 0, duration: 8), TitlePart(kind: .content, start: 8, duration: 100)]
        try lib.ingest(title: "T", album: "A", tracks: ["en": []], sourcePackage: "p.tmp", parts: parts)
        #expect(lib.entry(album: "A", title: "T")?.meta.parts == parts)
    }

    // Breaks if a movie with no Now Playing album cannot be found by title.
    @Test func lookupFallsBackToUniqueTitle() throws {
        let lib = library()
        try lib.ingest(title: "Movie", album: "Some Collection", tracks: ["en": []], sourcePackage: "p.tmp")
        #expect(lib.entry(album: nil, title: "Movie") != nil)
        try lib.ingest(title: "Movie", album: "Other Collection", tracks: ["en": []], sourcePackage: "q.tmp")
        #expect(lib.entry(album: nil, title: "Movie") == nil)
    }

    // Breaks if meta changes are not persisted.
    @Test func metaPersists() throws {
        let lib = library()
        try lib.ingest(title: "T", album: "A", tracks: ["en": []], sourcePackage: "p.tmp")
        var entry = try #require(lib.entry(album: "A", title: "T"))
        entry.meta.offset = 0.3
        entry.meta.nudge = -4
        try entry.saveMeta()
        let again = try #require(lib.entry(album: "A", title: "T"))
        #expect(again.meta.offset == 0.3)
        #expect(again.meta.nudge == -4)
    }

    // Breaks if saved translations are not listed per title, or Apple tracks are listed as translations.
    @Test func listsTranslations() throws {
        let lib = library()
        let a = try lib.ingest(title: "T2", album: "B", tracks: ["en": [], "ar": []], sourcePackage: "q.tmp")
        try lib.ingest(title: "T1", album: "A", tracks: ["en": []], sourcePackage: "p.tmp")
        try a.save([], language: "fa")
        let entries = lib.entries()
        #expect(entries.map(\.meta.title) == ["T1", "T2"])
        #expect(entries[0].translations == [])
        #expect(entries[1].translations == ["fa"])
    }

    // Breaks if deleting a translation leaves its file, or can delete an Apple track.
    @Test func deletesTranslationOnly() throws {
        let lib = library()
        let entry = try lib.ingest(title: "T", album: "A", tracks: ["en": []], sourcePackage: "p.tmp")
        try entry.save([], language: "fa")
        #expect(throws: SubtitleLibrary.LibraryError.self) { try entry.deleteTranslation("en") }
        try entry.deleteTranslation("fa")
        let again = try #require(lib.entry(album: "A", title: "T"))
        #expect(!again.hasTrack("fa"))
        #expect(again.hasTrack("en"))
    }

    // Breaks if a language code can name a path outside the entry.
    @Test func rejectsBadLanguageCode() throws {
        let lib = library()
        try lib.ingest(title: "T", album: "A", tracks: ["en": []], sourcePackage: "p.tmp")
        let entry = try #require(lib.entry(album: "A", title: "T"))
        #expect(throws: SubtitleLibrary.LibraryError.self) { try entry.save([], language: "../x") }
    }
}

struct DownloadWatcherTests {
    // Breaks if an old incomplete package is polled at launch, or a complete one is skipped.
    @Test func launchActionRules() {
        #expect(DownloadWatcher.launchAction(complete: true, age: 3600) == .ingest)
        #expect(DownloadWatcher.launchAction(complete: false, age: 30) == .poll)
        #expect(DownloadWatcher.launchAction(complete: false, age: 3600) == .skip)
    }

    // Breaks if start() opens the folder on the main thread: macOS asks for media library access
    // inside that open(), and the app froze until the prompt was answered. A FIFO blocks open()
    // the same way until a writer comes.
    @MainActor @Test func startDoesNotWaitForFolderAccess() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fifo = dir.appending(path: "f")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { close(open(fifo.path, O_WRONLY)) }
        let watcher = DownloadWatcher(directory: fifo, onReady: { _ in })
        let start = ContinuousClock.now
        watcher.start()
        #expect(ContinuousClock.now - start < .milliseconds(500))
        watcher.stop()
    }

    static func makeFolder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A copy of the fixture package at `url`, with every stream complete or not.
    static func copyPackage(to url: URL, complete: Bool, bootDate: Date) throws {
        try FileManager.default.copyItem(at: Fixture.package, to: url)
        let boot = url.appending(path: "boot.xml")
        if !complete {
            let text = try String(contentsOf: boot, encoding: .utf8).replacingOccurrences(of: "<Complete>YES", with: "<Complete>NO")
            try text.write(to: boot, atomically: true, encoding: .utf8)
        }
        try FileManager.default.setAttributes([.modificationDate: bootDate], ofItemAtPath: boot.path)
    }

    // Breaks if a second Download press, which the TV app writes to `download 1.movpkg` next to
    // the first attempt, is not the package read; or if a folder with no package yet is not
    // read at the usual place.
    @Test func newestPackageIsTheLatestAttempt() throws {
        let folder = try Self.makeFolder()
        #expect(DownloadWatcher.newestPackage(in: folder) == folder.appending(path: "download.movpkg"))
        try Self.copyPackage(to: folder.appending(path: "download.movpkg"), complete: false, bootDate: Date(timeIntervalSinceNow: -3600))
        try Self.copyPackage(to: folder.appending(path: "download 1.movpkg"), complete: true, bootDate: Date(timeIntervalSinceNow: -60))
        #expect(DownloadWatcher.newestPackage(in: folder) == folder.appending(path: "download 1.movpkg"))
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: folder.appending(path: "download.movpkg/boot.xml").path)
        #expect(DownloadWatcher.newestPackage(in: folder) == folder.appending(path: "download.movpkg"))
    }

    // Breaks if a new package in a folder the watcher already knows (a second Download press
    // after a cancelled first one) is not noticed: the folder event names only the `.tmp`
    // folder, which is not new.
    @MainActor @Test func redownloadInKnownFolderIsCaptured() async throws {
        let downloads = try Self.makeFolder()
        let folder = downloads.appending(path: "Title.tmp")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Self.copyPackage(to: folder.appending(path: "download.movpkg"), complete: false, bootDate: Date(timeIntervalSinceNow: -3600))
        let ready = AsyncStream<URL>.makeStream()
        let watcher = DownloadWatcher(directory: downloads, onReady: { ready.continuation.yield($0) })
        watcher.start()
        await watcher.opening?.value
        // The TV app writes the new attempt as a whole; a move puts it there in one step.
        let staging = try Self.makeFolder().appending(path: "download 1.movpkg")
        try Self.copyPackage(to: staging, complete: true, bootDate: Date())
        try FileManager.default.moveItem(at: staging, to: folder.appending(path: "download 1.movpkg"))
        let captured = await Self.firstReady(ready.stream)
        watcher.stop()
        #expect(captured == folder.appending(path: "download 1.movpkg"))
    }

    static func firstReady(_ stream: AsyncStream<URL>) async -> URL? {
        await withTaskGroup(of: URL?.self) { group in
            group.addTask { await stream.first { _ in true } }
            group.addTask { try? await Task.sleep(for: .seconds(8)); return nil }
            let first = await group.next()!
            group.cancelAll()
            return first
        }
    }

    // Breaks if a package whose tracks are still incomplete (the user cancelled the download
    // after a moment) is not ready once its boot.xml has stopped changing.
    @MainActor @Test func incompletePackageIsReadyOnceBootSettles() async throws {
        let downloads = try Self.makeFolder()
        let ready = AsyncStream<URL>.makeStream()
        let watcher = DownloadWatcher(directory: downloads, onReady: { ready.continuation.yield($0) })
        watcher.start()
        await watcher.opening?.value
        let folder = downloads.appending(path: "Title.tmp")
        let staging = try Self.makeFolder().appending(path: "download.movpkg")
        try Self.copyPackage(to: staging, complete: false, bootDate: Date())
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: staging, to: folder.appending(path: "download.movpkg"))
        let captured = await Self.firstReady(ready.stream)
        watcher.stop()
        #expect(captured == folder.appending(path: "download.movpkg"))
    }
}

/// Runs only on a machine with the real Black Bird download.
struct RealPackageSmokeTests {
    static let pilot = URL.moviesDirectory.appending(path: "TV/Media.localized/TV Shows/Black Bird/Season 1/Pilot.movpkg")
    static let present = FileManager.default.fileExists(atPath: pilot.appending(path: "boot.xml").path)

    // Breaks if Apple TV+ packages (no language in stream URLs) yield no tracks or wrong names.
    @Test(.enabled(if: present)) func appleTVPlusPackage() throws {
        let m = try MoviePackageReader.manifest(package: Self.pilot)
        #expect(m.title == "Pilot")
        #expect(m.album == "Black Bird")
        #expect(m.tracks.contains { $0.language == "en" })
        let en = try #require(m.tracks.first { $0.language == "en" })
        let cues = try MoviePackageReader.readTrack(en, package: Self.pilot)
        #expect(cues.count > 100)
        // Measured on screen: Apple shows this cue at Now Playing 331.4-332.5 s.
        let cue = try #require(cues.first { $0.text == "Touches me in a deep place." })
        #expect(abs(cue.start - 332.45) < 0.01)
    }
}
