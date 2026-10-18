import Foundation

/// Minimal, bounded WebVTT reader and writer. Cue ids are renumbered from 1.
public enum WebVTT {
    public static func parse(_ text: String, maxCues: Int = 20_000) -> [Cue] {
        var cues: [Cue] = []
        // WebVTT line ends are CRLF, LF or a lone CR; Apple uses a lone CR in some titles.
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var i = 0
        while i < lines.count, cues.count < maxCues {
            // Find the timing line of the next block; header, NOTE, STYLE and REGION blocks have none.
            guard let arrow = lines[i].range(of: "-->") else {
                i += 1
                continue
            }
            let timing = lines[i]
            i += 1
            let startText = timing[..<arrow.lowerBound].trimmingCharacters(in: .whitespaces)
            let rest = timing[arrow.upperBound...].trimmingCharacters(in: .whitespaces)
            let endText = rest.prefix { !$0.isWhitespace }
            let settings = rest.dropFirst(endText.count).trimmingCharacters(in: .whitespaces)
            var body: [Substring] = []
            while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                body.append(lines[i])
                i += 1
            }
            guard let start = seconds(startText), let end = seconds(String(endText)), end > start else { continue }
            let raw = body.joined(separator: "\n")
            // Apple pads streams with cues that hold only a zero-width space.
            let text = plainText(raw)
            guard text.unicodeScalars.contains(where: { !$0.properties.isWhitespace && $0.properties.generalCategory != .format }) else { continue }
            cues.append(Cue(id: cues.count + 1, start: start, end: end, text: text,
                            settings: settings, italic: isItalic(raw)))
        }
        return cues
    }

    public static func write(_ cues: [Cue]) -> String {
        var out = "WEBVTT\n"
        for (n, cue) in cues.enumerated() {
            var text = cue.text
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            if cue.italic { text = "<i>\(text)</i>" }
            let settings = cue.settings.isEmpty ? "" : " " + cue.settings
            out += "\n\(n + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\(settings)\n\(text)\n"
        }
        return out
    }

    /// Parses `hh:mm:ss.ttt` or `mm:ss.ttt`.
    static func seconds(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secParts = parts.last!.split(separator: ".")
        guard secParts.count == 2, secParts[1].count == 3,
              let sec = Int(secParts[0]), let ms = Int(secParts[1]),
              let min = Int(parts[parts.count - 2]),
              sec < 60, min < 60
        else { return nil }
        let hours = parts.count == 3 ? Int(parts[0]) : 0
        guard let hours, hours >= 0 else { return nil }
        let total = ((hours * 60 + min) * 60 + sec) * 1000 + ms
        return Double(total) / 1000
    }

    static func timestamp(_ seconds: Double) -> String {
        let ms = Int((seconds * 1000).rounded())
        return String(format: "%02d:%02d:%02d.%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }

    private static func isItalic(_ raw: String) -> Bool {
        raw.contains("<i>") || raw.contains("italic")
    }

    private static func plainText(_ raw: String) -> String {
        var out = ""
        var inTag = false
        for ch in raw {
            if ch == "<" { inTag = true }
            else if ch == ">" { inTag = false }
            else if !inTag { out.append(ch) }
        }
        return out
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
            .replacingOccurrences(of: "&lrm;", with: "\u{200E}")
            .replacingOccurrences(of: "&rlm;", with: "\u{200F}")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
