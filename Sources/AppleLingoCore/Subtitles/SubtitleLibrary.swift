import Foundation

public enum Slug {
    /// Lowercase letters and digits joined by "-". Path characters never survive.
    public static func make(_ s: String) -> String {
        let words = s.lowercased().split { !($0.isLetter || $0.isNumber) }
        let slug = words.joined(separator: "-")
        return slug.isEmpty ? "untitled" : String(slug.prefix(80))
    }
}

public struct TitleMeta: Codable, Sendable, Equatable {
    public var assetID = UUID()
    public var title: String
    public var album: String
    public var appleLanguages: [String]
    /// The film's original audio language, from the package.
    public var originalLanguage: String?
    /// Seconds of the downloaded video, its intro included; measures a stream's lead.
    public var videoDuration: Double?
    /// Intro, recap, content and what follows, in download time.
    public var parts: [TitlePart]?
    public var sourcePackage: String
    public var created = Date()
    /// Seconds added to the playback position.
    public var offset = 0.0
    /// Vertical shift in percent of the video height.
    public var nudge = 0.0
}

/// `<root>/<show>/<title>/{<lang>.vtt..., meta.json}`.
public struct SubtitleLibrary: Sendable {
    public enum LibraryError: Error {
        case badLanguage(String)
        case notTranslation(String)
    }

    public struct Entry: Sendable {
        public let directory: URL
        public var meta: TitleMeta

        public func cues(language: String) throws -> [Cue] {
            let data = try Data(contentsOf: try file(language))
            return WebVTT.parse(String(decoding: data, as: UTF8.self))
        }

        public func hasTrack(_ language: String) -> Bool {
            (try? file(language)).map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        }

        public func save(_ cues: [Cue], language: String) throws {
            try Data(WebVTT.write(cues).utf8).write(to: try file(language), options: .atomic)
        }

        /// Languages of saved translations: tracks on disk that Apple did not ship.
        public var translations: [String] {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            let apple = Set(meta.appleLanguages)
            return names.filter { $0.hasSuffix(".vtt") }.map { String($0.dropLast(4)) }
                .filter { !apple.contains($0) && $0.wholeMatch(of: /[A-Za-z0-9-]{1,16}/) != nil }
                .sorted()
        }

        /// When a track was saved.
        public func saved(_ language: String) -> Date? {
            (try? file(language)).flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        }

        /// Removes a saved translation. Apple tracks cannot be removed.
        public func deleteTranslation(_ language: String) throws {
            guard !meta.appleLanguages.contains(language) else { throw LibraryError.notTranslation(language) }
            let url = try file(language)
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        }

        public func saveMeta() throws {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(meta).write(to: directory.appending(path: "meta.json"), options: .atomic)
        }

        private func file(_ language: String) throws -> URL {
            guard language.wholeMatch(of: /[A-Za-z0-9-]{1,16}/) != nil else { throw LibraryError.badLanguage(language) }
            return directory.appending(path: "\(language).vtt")
        }
    }

    public static var defaultRoot: URL {
        URL.applicationSupportDirectory.appending(path: "AppleLingo")
    }

    public let root: URL

    public init(root: URL = SubtitleLibrary.defaultRoot) {
        self.root = root
    }

    /// Every title in the library, by show then title.
    public func entries() -> [Entry] {
        let fm = FileManager.default
        let shows = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return shows.flatMap { show in
            ((try? fm.contentsOfDirectory(at: show, includingPropertiesForKeys: nil)) ?? []).compactMap { dir in
                (try? readMeta(dir)).map { Entry(directory: dir, meta: $0) }
            }
        }
        .sorted { ($0.meta.album, $0.meta.title) < ($1.meta.album, $1.meta.title) }
    }

    /// Stores every Apple track of a title and creates or updates its meta.
    @discardableResult
    public func ingest(title: String, album: String, tracks: [String: [Cue]], sourcePackage: String,
                       originalLanguage: String? = nil, videoDuration: Double? = nil,
                       parts: [TitlePart]? = nil) throws -> Entry {
        let dir = directory(album: album, title: title)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var entry = Entry(directory: dir, meta: (try? readMeta(dir)) ?? TitleMeta(
            title: title, album: album, appleLanguages: [], sourcePackage: sourcePackage))
        for (language, cues) in tracks { try entry.save(cues, language: language) }
        entry.meta.appleLanguages = tracks.keys.sorted()
        entry.meta.sourcePackage = sourcePackage
        entry.meta.originalLanguage = originalLanguage
        entry.meta.videoDuration = videoDuration
        entry.meta.parts = parts
        try entry.saveMeta()
        return entry
    }

    /// Looks up by album and title; without a match, by title alone when exactly one show has it.
    public func entry(album: String?, title: String) -> Entry? {
        if let album, let meta = try? readMeta(directory(album: album, title: title)) {
            return Entry(directory: directory(album: album, title: title), meta: meta)
        }
        let shows = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        let matches = shows.map { $0.appending(path: Slug.make(title)) }.filter {
            FileManager.default.fileExists(atPath: $0.appending(path: "meta.json").path)
        }
        guard matches.count == 1, let meta = try? readMeta(matches[0]) else { return nil }
        return Entry(directory: matches[0], meta: meta)
    }

    public func hasEntry(sourcePackage: String) -> Bool {
        let shows = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for show in shows {
            let titles = (try? FileManager.default.contentsOfDirectory(at: show, includingPropertiesForKeys: nil)) ?? []
            if titles.contains(where: { (try? readMeta($0))?.sourcePackage == sourcePackage }) { return true }
        }
        return false
    }

    private func directory(album: String, title: String) -> URL {
        root.appending(path: Slug.make(album)).appending(path: Slug.make(title))
    }

    private func readMeta(_ dir: URL) throws -> TitleMeta {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TitleMeta.self, from: Data(contentsOf: dir.appending(path: "meta.json")))
    }
}
