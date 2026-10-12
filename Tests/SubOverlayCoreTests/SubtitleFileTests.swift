import Foundation
import Testing
@testable import SubOverlayCore

struct SubtitleFileTests {
    // Breaks if SRT comma times, index lines, CRLF, italics or ASS position tags are not handled.
    @Test func readsSubRip() throws {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,500\r\n{\\an8}<i>Hello</i>\r\n\r\n2\r\n00:01:01,000 --> 00:01:02,000\r\na\r\nb\r\n"
        let cues = try SubtitleFile.parse(Data(srt.utf8), language: "en")
        #expect(cues.map(\.start) == [1, 61])
        #expect(cues.map(\.end) == [2.5, 62])
        #expect(cues.map(\.text) == ["Hello", "a\nb"])
        #expect(cues.map(\.italic) == [true, false])
    }

    // Breaks if a Windows-1256 Persian file is not decoded, or its Arabic yeh and kaf are kept.
    @Test func readsWindows1256Persian() throws {
        var data = Data("1\n00:00:01,000 --> 00:00:02,000\n".utf8)
        data += Data([0xD3, 0xE1, 0xC7, 0xE3, 0x20, 0xED, 0xDF, 0x0A]) // "سلام يك"
        #expect(try SubtitleFile.parse(data, language: "fa").map(\.text) == ["سلام یک"])
    }

    // Breaks if a UTF-16 file with a byte order mark, or a WebVTT file, is not read.
    @Test func readsUTF16AndWebVTT() throws {
        let srt = "1\n00:00:01,000 --> 00:00:02,000\nسلام\n"
        var utf16 = Data([0xFF, 0xFE])
        for unit in srt.utf16 { utf16 += Data([UInt8(unit & 0xFF), UInt8(unit >> 8)]) }
        #expect(try SubtitleFile.parse(utf16, language: "fa").map(\.text) == ["سلام"])
        let vtt = "\u{FEFF}WEBVTT\n\n00:00:03.000 --> 00:00:04.000\nHi\n"
        #expect(try SubtitleFile.parse(Data(vtt.utf8), language: "en").map(\.start) == [3])
    }

    // Breaks if an ASS file (some downloads name them .srt) is not read: centisecond times, \N
    // line breaks, commas in the text, italic and override tags. Lines in the real files' format.
    @Test func readsAdvancedSubStation() throws {
        let ass = """
        \u{FEFF}[Script Info]\r
        ScriptType: v4.00+\r
        \r
        [Events]\r
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\r
        Dialogue: 0,0:03:09.43,0:03:10.89,Default,,0,0,0,,{\\i1}از زنان خوشت میاد{\\i0}\\Nجیمی؟\r
        Comment: 0,0:03:11.00,0:03:12.00,Default,,0,0,0,,note\r
        Dialogue: 0,1:03:13.90,1:03:15.11,Default,,0,0,0,,بله، قربان.\r
        """
        let cues = try SubtitleFile.parse(Data(ass.utf8), language: "fa")
        #expect(cues.map(\.start) == [189.43, 3793.9])
        #expect(cues.map(\.end) == [190.89, 3795.11])
        #expect(cues.map(\.text) == ["از زنان خوشت میاد\nجیمی؟", "بله، قربان."])
        #expect(cues.map(\.italic) == [true, false])
    }

    // Breaks if a huge file is read, or a file without cues passes as a subtitle.
    @Test func refusesLargeOrEmpty() {
        #expect(throws: SubtitleFile.ReadError.tooLarge) {
            try SubtitleFile.parse(Data(count: SubtitleFile.maxBytes + 1), language: "en")
        }
        #expect(throws: SubtitleFile.ReadError.noCues) {
            try SubtitleFile.parse(Data("<html>not found</html>".utf8), language: "en")
        }
    }
}
