import Foundation

/// The subtitle tracks a TV app download package lists in `boot.xml`.
public struct PackageManifest: Sendable, Equatable {
    public struct Track: Sendable, Equatable {
        public var language: String
        /// Package-relative folder, one path component.
        public var path: String
        public var complete: Bool
    }

    public var title: String
    public var album: String
    public var tracks: [Track]
    /// Language of the audio Apple marks as the original (`public.original-content`), if any.
    public var originalLanguage: String?
    /// Seconds of the downloaded video, its intro included.
    public var videoDuration: Double?
    /// Package-relative folder of the video stream.
    public var videoPath: String?

    public var allComplete: Bool { !tracks.isEmpty && tracks.allSatisfy(\.complete) }
}

/// Reads subtitle tracks from a `download.movpkg`. The package is written by another app,
/// so it is untrusted: paths stay inside it, symlinks are refused, and all sizes are capped.
public enum MoviePackageReader {
    public enum ReadError: Error {
        case notRegularFile(String)
        case tooLarge(String)
        case tooManyFragments
        case badBootFile
    }

    public struct Names: Sendable, Equatable {
        public var title: String
        public var album: String
    }

    static let maxBootBytes = 2 * 1024 * 1024
    static let maxStreams = 1000
    public static let maxFragmentBytes = 256 * 1024
    static let maxTrackBytes = 8 * 1024 * 1024
    static let maxFragments = 2000
    static let maxPlaylistBytes = 1024 * 1024

    /// `<title> _ <album> _ <artist>.tmp` → title and album.
    public static func names(fromFolder folder: String) -> Names {
        var name = folder
        if name.hasSuffix(".tmp") { name.removeLast(4) }
        let parts = name.components(separatedBy: " _ ")
        return Names(title: parts[0], album: parts.count >= 3 ? parts[1] : "")
    }

    public static func manifest(package: URL) throws -> PackageManifest {
        let data = try readFile(package.appending(path: "boot.xml"), cap: maxBootBytes)
        let delegate = BootParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw ReadError.badBootFile }
        let master = MasterPlaylist.read(dataDirectory: package.appending(path: "Data"))

        // One track per language, in boot order; a plain track wins over an SDH one.
        var order: [String] = []
        var chosen: [String: (track: PackageManifest.Track, sdh: Bool)] = [:]
        for stream in delegate.streams.prefix(maxStreams) {
            guard let info = master.subtitles[stream.url], !info.forced, isSafeComponent(stream.path) else { continue }
            let track = PackageManifest.Track(language: info.language, path: stream.path, complete: stream.complete)
            if let current = chosen[info.language] {
                if current.sdh && !info.sdh { chosen[info.language] = (track, false) }
            } else {
                order.append(info.language)
                chosen[info.language] = (track, info.sdh)
            }
        }
        let tracks = order.compactMap { chosen[$0]?.track }
        let video = delegate.streams.prefix(maxStreams).first { master.videos.contains($0.url) && isSafeComponent($0.path) }
        let videoDuration = video.flatMap { playlistDuration(package.appending(path: $0.path)) }

        var names = names(fromFolder: package.deletingLastPathComponent().lastPathComponent)
        if let episode = master.episodeTitle, let show = master.title {
            names = Names(title: episode, album: show)
        } else if let title = master.title {
            names = Names(title: title, album: "")
        }
        return PackageManifest(title: names.title, album: names.album, tracks: tracks, originalLanguage: master.originalLanguage, videoDuration: videoDuration,
                               videoPath: video?.path)
    }

    /// Cues of one track, in time order, deduped across fragment overlaps, in Now Playing time.
    /// A fragment's cue times count from the start of its discontinuity period in the track's
    /// playlist (the preview, the episode after a promo slot, end cards), so each cue moves later
    /// by that start. Pre-roll fragments are skipped. `X-TIMESTAMP-MAP` is not applied.
    public static func readTrack(_ track: PackageManifest.Track, package: URL) throws -> [Cue] {
        let dir = package.appending(path: track.path)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let playlist = names.filter { $0.hasSuffix(".m3u8") && isSafeComponent($0) }.sorted().first
            .flatMap { try? readFile(dir.appending(path: $0), cap: maxPlaylistBytes) }
        let text = playlist.map { String(decoding: $0, as: UTF8.self) }
        let preRoll = text.map(preRoll(playlist:)) ?? 0
        let periods = text.map(periodStarts(playlist:)) ?? [0]
        let fragments = names.compactMap { name in fragmentStart(name).map { (start: $0, name: name) } }
            .filter { $0.start >= preRoll - 0.01 }
            .sorted { $0.start < $1.start }
        guard fragments.count <= maxFragments else { throw ReadError.tooManyFragments }
        var total = 0
        var seen = Set<String>()
        var cues: [Cue] = []
        for fragment in fragments {
            let data = try readFile(dir.appending(path: fragment.name), cap: maxFragmentBytes)
            total += data.count
            guard total <= maxTrackBytes else { throw ReadError.tooLarge(track.path) }
            let base = periods.last { $0 <= fragment.start + 0.01 } ?? 0
            for var cue in WebVTT.parse(String(decoding: data, as: UTF8.self))
            where seen.insert("\(base)|\(cue.start)|\(cue.end)|\(cue.text)").inserted {
                cue.start += base
                cue.end += base
                cues.append(cue)
            }
        }
        cues.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        for i in cues.indices { cues[i].id = i + 1 }
        return cues
    }

    /// The title's parts from its video playlist; empty without one. `dialogue` is any Apple track.
    public static func parts(_ manifest: PackageManifest, package: URL, dialogue: [Cue]) -> [TitlePart] {
        guard let path = manifest.videoPath, isSafeComponent(path) else { return [] }
        let dir = package.appending(path: path)
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter({ $0.hasSuffix(".m3u8") && isSafeComponent($0) }).sorted().first,
              let data = try? readFile(dir.appending(path: name), cap: maxPlaylistBytes)
        else { return [] }
        return parts(playlist: String(decoding: data, as: UTF8.self), dialogue: dialogue)
    }

    /// Apple's interstitials (`#EXT-X-DATERANGE` of class `com.apple.hls.interstitial`) before the
    /// longest discontinuity period are the intro, or the recap when a cue starts in one; without
    /// them, the span before that period is one part. The content runs from their end to the
    /// period's end; what follows is one part. Times are rounded to 1 ms, as in the playlist.
    static func parts(playlist: String, dialogue: [Cue]) -> [TitlePart] {
        func ms(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
        var origin: Date?
        var breaks: [(start: Date, duration: Double)] = []
        var starts = [0.0], total = 0.0
        for line in playlist.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-PROGRAM-DATE-TIME:"), origin == nil {
                origin = isoDate(line.dropFirst(25))
            } else if line.hasPrefix("#EXT-X-DATERANGE:"), line.contains(#"CLASS="com.apple.hls.interstitial""#),
                      let date = line.firstMatch(of: /START-DATE="([^"]+)"/).flatMap({ isoDate($0.1) }),
                      let duration = line.firstMatch(of: /DURATION=([0-9.]+)/).flatMap({ Double($0.1) }) {
                breaks.append((date, duration))
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY"), total > starts[starts.count - 1] {
                starts.append(total)
            } else if line.hasPrefix("#EXTINF:"), let d = Double(line.dropFirst(8).prefix { $0 != "," }), d >= 0 {
                total += d
            }
        }
        let periods = zip(starts, starts.dropFirst() + [total]).map { (start: ms($0), end: ms($1)) }
        guard let content = periods.max(by: { $0.end - $0.start < $1.end - $1.start }), content.end > content.start
        else { return [] }
        var spans = origin.map { origin in
            breaks.map { (start: ms($0.start.timeIntervalSince(origin)), duration: $0.duration) }
                .filter { $0.start < content.start + 1 }
        } ?? []
        if spans.isEmpty, content.start > 1 { spans = [(start: 0, duration: content.start)] }
        var parts = spans.map { span in
            let spoken = dialogue.contains { $0.start >= span.start && $0.start < span.start + span.duration }
            return TitlePart(kind: spoken ? .recap : .intro, start: span.start, duration: span.duration)
        }
        let start = max(content.start, ms(spans.map { $0.start + $0.duration }.max() ?? 0))
        parts.append(TitlePart(kind: .content, start: start, duration: ms(content.end - start)))
        if ms(total) - content.end > 1 {
            parts.append(TitlePart(kind: .after, start: content.end, duration: ms(ms(total) - content.end)))
        }
        return parts
    }

    /// An ISO 8601 date with or without fractional seconds.
    static func isoDate(_ text: Substring) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: String(text)) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: String(text))
    }

    /// Sum of `#EXTINF` in the first `.m3u8` of a stream folder, or nil without one.
    static func playlistDuration(_ dir: URL) -> Double? {
        guard let name = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
                .filter({ $0.hasSuffix(".m3u8") && isSafeComponent($0) }).sorted().first,
              let data = try? readFile(dir.appending(path: name), cap: maxPlaylistBytes)
        else { return nil }
        let total = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).reduce(0.0) { sum, line in
            guard line.hasPrefix("#EXTINF:"), let d = Double(line.dropFirst(8).prefix { $0 != "," }), d >= 0 else { return sum }
            return sum + d
        }
        return total > 0 ? total : nil
    }

    /// Seconds before the first `#EXT-X-DISCONTINUITY` of a track's media playlist: the Apple
    /// intro range, which the Now Playing clock counts. 0 without a discontinuity or when absurd.
    static func preRoll(playlist: String) -> Double {
        var total = 0.0
        for line in playlist.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-DISCONTINUITY") { return (0...600).contains(total) ? total : 0 }
            if line.hasPrefix("#EXTINF:"), let d = Double(line.dropFirst(8).prefix { $0 != "," }), d >= 0 { total += d }
        }
        return 0
    }

    /// Start of each discontinuity period of a media playlist: 0, then the `#EXTINF` sum at
    /// each `#EXT-X-DISCONTINUITY`.
    static func periodStarts(playlist: String) -> [Double] {
        var starts = [0.0], total = 0.0
        for line in playlist.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("#EXT-X-DISCONTINUITY"), total > starts[starts.count - 1] { starts.append(total) }
            if line.hasPrefix("#EXTINF:"), let d = Double(line.dropFirst(8).prefix { $0 != "," }), d >= 0 { total += d }
        }
        return starts
    }

    static func isSafeComponent(_ path: String) -> Bool {
        !path.isEmpty && path != "." && path != ".." && !path.contains("/") && !path.contains("\0")
    }

    /// `(start)_(n)_(dur).frag` → start seconds. Start and duration may have decimals.
    static func fragmentStart(_ name: String) -> Double? {
        guard let m = name.wholeMatch(of: /\((\d{1,7}(?:\.\d{1,9})?)\)_\(\d{1,7}\)_\(\d{1,7}(?:\.\d{1,9})?\)\.frag/) else { return nil }
        return Double(m.1)
    }

    /// Reads a regular file without following symlinks, refusing more than `cap` bytes.
    static func readFile(_ url: URL, cap: Int) throws -> Data {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ReadError.notRegularFile(url.lastPathComponent) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw ReadError.notRegularFile(url.lastPathComponent)
        }
        guard info.st_size <= cap, let data = try handle.read(upToCount: cap + 1), data.count <= cap else {
            throw ReadError.tooLarge(url.lastPathComponent)
        }
        return data
    }
}

private final class BootParser: NSObject, XMLParserDelegate {
    struct Stream {
        var url: String
        var path: String
        var complete = false
    }

    var streams: [Stream] = []
    private var current: Stream?
    private var text = ""

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String] = [:]) {
        text = ""
        if name == "Stream", let url = attributes["NetworkURL"], let path = attributes["Path"] {
            current = Stream(url: url, path: path)
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text.count < 16 { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if name == "Complete" { current?.complete = text.trimmingCharacters(in: .whitespacesAndNewlines) == "YES" }
        if name == "Stream", let s = current {
            streams.append(s)
            current = nil
        }
    }
}
