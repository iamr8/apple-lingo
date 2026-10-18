import CoreFoundation
import Foundation

/// Reads a subtitle file someone gives us: SubRip (`.srt`), WebVTT or Advanced SubStation (some
/// downloads name ASS files `.srt`), in UTF-8, UTF-16 or the old Windows code page of
/// `language`. The file is untrusted, so its size is capped.
public enum SubtitleFile {
    public enum ReadError: Error, Equatable, LocalizedError {
        case tooLarge
        case noCues

        public var errorDescription: String? {
            switch self {
            case .tooLarge: "The file is larger than 2 MB."
            case .noCues: "No subtitle lines were found. Use an .srt, .vtt or .ass file, not a .zip or a web page."
            }
        }
    }

    public static let maxBytes = 2 * 1024 * 1024

    public static func parse(_ data: Data, language: String) throws -> [Cue] {
        guard data.count <= maxBytes else { throw ReadError.tooLarge }
        var text = decode(data, language: language)
        if text.range(of: "[Events]", options: .caseInsensitive) != nil {
            text = WebVTT.write(advancedSubStation(text))
        }
        // SubRip writes "00:00:01,000"; WebVTT needs a dot. Lines without an arrow keep their commas.
        text = text.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            line.contains("-->") ? line.replacingOccurrences(of: ",", with: ".") : String(line)
        }.joined(separator: "\n")
        var cues = WebVTT.parse(text)
        for i in cues.indices {
            // ASS position tags such as {\an8}; the overlay places cues itself.
            var t = cues[i].text.replacing(/\{\\[^}]*\}/, with: "")
            // Windows-1256 has no Persian yeh or keheh, so Persian files use the Arabic letters.
            if Locale(identifier: language).language.languageCode?.identifier == "fa" {
                t = t.replacingOccurrences(of: "\u{064A}", with: "\u{06CC}").replacingOccurrences(of: "\u{0643}", with: "\u{06A9}")
            }
            cues[i].text = t
        }
        guard !cues.isEmpty else { throw ReadError.noCues }
        return cues
    }

    /// `Dialogue:` lines of an ASS file. Fields follow its `Format:` line; the text is the last
    /// field and may hold commas. `\N` is a line break; `{\i1}` marks italics.
    static func advancedSubStation(_ text: String) -> [Cue] {
        var fields = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"]
        var cues: [Cue] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if line.hasPrefix("Format:") {
                fields = line.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard line.hasPrefix("Dialogue:"), cues.count < 20_000,
                  let start = fields.firstIndex(of: "start"), let end = fields.firstIndex(of: "end"),
                  fields.last == "text" else { continue }
            let parts = line.dropFirst(9).split(separator: ",", maxSplits: fields.count - 1, omittingEmptySubsequences: false)
            guard parts.count == fields.count, let from = assSeconds(parts[start]), let to = assSeconds(parts[end]), to > from else { continue }
            let raw = String(parts[parts.count - 1])
            let body = raw.replacing(/\{[^}]*\}/, with: "")
                .replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\h", with: "\u{00A0}")
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            cues.append(Cue(id: cues.count + 1, start: from, end: to, text: body, italic: raw.contains("\\i1")))
        }
        return cues
    }

    /// `h:mm:ss.cc` → seconds.
    static func assSeconds(_ s: Substring) -> Double? {
        guard let m = s.trimmingCharacters(in: .whitespaces).wholeMatch(of: /(\d{1,2}):(\d{2}):(\d{2})\.(\d{2})/),
              let h = Int(m.1), let min = Int(m.2), let sec = Int(m.3), let cs = Int(m.4), min < 60, sec < 60 else { return nil }
        return Double(((h * 60 + min) * 60 + sec) * 100 + cs) / 100
    }

    /// UTF-8 or UTF-16 by byte order mark, else UTF-8 when valid, else the language's Windows code page.
    static func decode(_ data: Data, language: String) -> String {
        let bytes = [UInt8](data.prefix(3))
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: data.dropFirst(3), as: UTF8.self) }
        if bytes.starts(with: [0xFF, 0xFE]) { return String(data: data.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if bytes.starts(with: [0xFE, 0xFF]) { return String(data: data.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        let page = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(codePage(language)))
        return String(data: data, encoding: page) ?? String(decoding: data, as: UTF8.self)
    }

    static func codePage(_ language: String) -> CFStringEncoding {
        let code = Locale(identifier: language).language.languageCode?.identifier ?? language
        let page: CFStringEncodings? = switch code {
        case "ar", "fa", "ur", "ps", "ku": .windowsArabic
        case "he", "yi": .windowsHebrew
        case "ru", "uk", "bg", "sr", "mk", "be": .windowsCyrillic
        case "el": .windowsGreek
        case "tr", "az": .windowsLatin5
        case "pl", "cs", "sk", "hu", "ro", "hr", "sl": .windowsLatin2
        case "vi": .windowsVietnamese
        default: nil
        }
        return page.map { CFStringEncoding($0.rawValue) } ?? CFStringBuiltInEncodings.windowsLatin1.rawValue
    }
}
