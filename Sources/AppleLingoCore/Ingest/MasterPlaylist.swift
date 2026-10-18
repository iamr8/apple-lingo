import Foundation

/// The HLS master playlists the TV app stores in a package's `Data` folder. They name each
/// subtitle rendition's language and the title, which stream URLs and folder names may lack.
struct MasterPlaylist {
    struct Subtitle: Equatable {
        var language: String
        var forced: Bool
        /// Subtitles for the deaf and hard of hearing (describe music and sound).
        var sdh: Bool
    }

    static let maxMasters = 16
    static let maxMasterBytes = 4 * 1024 * 1024
    static let maxDescriptorBytes = 64 * 1024

    var title: String?
    var episodeTitle: String?
    /// Language of the audio marked `public.original-content`.
    var originalLanguage: String?
    /// Absolute rendition URL → subtitle info.
    var subtitles: [String: Subtitle] = [:]
    /// Absolute URLs of the video variants (`#EXT-X-STREAM-INF`).
    var videos: Set<String> = []
    /// Width over height of the largest video variant's `RESOLUTION`.
    var videoAspect: Double?
    private var largestVariant = 0

    /// Reads every `Playlist-<id>-master.m3u8` with its `Playlist-master.m3u8-<id>.descriptor`,
    /// which holds the URL that relative rendition URIs resolve against.
    static func read(dataDirectory dir: URL) -> MasterPlaylist {
        var result = MasterPlaylist()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let masters = names.compactMap { name in
            name.wholeMatch(of: /Playlist-([A-Za-z0-9-]{1,64})-master\.m3u8/).map { (name, String($0.1)) }
        }
        for (name, id) in masters.sorted(by: { $0.0 < $1.0 }).prefix(maxMasters) {
            guard let base = descriptorURL(dir.appending(path: "Playlist-master.m3u8-\(id).descriptor")),
                  let data = try? MoviePackageReader.readFile(dir.appending(path: name), cap: maxMasterBytes)
            else { continue }
            result.parse(String(decoding: data, as: UTF8.self), base: base)
        }
        return result
    }

    mutating func parse(_ text: String, base: URL) {
        var variantNext = false
        for line in text.split(whereSeparator: \.isNewline) {
            if variantNext, !line.hasPrefix("#") {
                variantNext = false
                if let url = URL(string: String(line), relativeTo: base)?.absoluteString { videos.insert(url) }
                continue
            }
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                variantNext = true
                if let size = Self.attributes(line.dropFirst("#EXT-X-STREAM-INF:".count))["RESOLUTION"]?
                       .wholeMatch(of: /(\d{1,5})x(\d{1,5})/),
                   let w = Int(size.1), let h = Int(size.2), h > 0, w * h > largestVariant {
                    largestVariant = w * h
                    videoAspect = Double(w) / Double(h)
                }
            } else if line.hasPrefix("#EXT-X-SESSION-DATA:") {
                let a = Self.attributes(line.dropFirst("#EXT-X-SESSION-DATA:".count))
                switch a["DATA-ID"] {
                case "com.apple.hls.title": title = title ?? a["VALUE"]
                case "com.apple.hls.episode-title": episodeTitle = episodeTitle ?? a["VALUE"]
                default: continue
                }
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let a = Self.attributes(line.dropFirst("#EXT-X-MEDIA:".count))
                if a["TYPE"] == "AUDIO", a["CHARACTERISTICS"]?.contains("public.original-content") == true {
                    originalLanguage = originalLanguage ?? a["LANGUAGE"]
                }
                guard a["TYPE"] == "SUBTITLES", let language = a["LANGUAGE"], let uri = a["URI"],
                      let url = URL(string: uri, relativeTo: base)?.absoluteString
                else { continue }
                subtitles[url] = Subtitle(
                    language: language,
                    forced: a["FORCED"] == "YES",
                    sdh: a["CHARACTERISTICS"]?.contains("describes-music-and-sound") == true)
            }
        }
    }

    /// `KEY=value,KEY="quoted, value"` → dictionary.
    static func attributes(_ s: Substring) -> [String: String] {
        var result: [String: String] = [:]
        for m in s.matches(of: /([A-Z0-9-]+)=("[^"]*"|[^,]*)/) {
            var value = Substring(m.2)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = value.dropFirst().dropLast() }
            result[String(m.1)] = String(value)
        }
        return result
    }

    private static func descriptorURL(_ file: URL) -> URL? {
        guard let data = try? MoviePackageReader.readFile(file, cap: maxDescriptorBytes),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let string = plist["URL"] as? String
        else { return nil }
        return URL(string: string)
    }
}
