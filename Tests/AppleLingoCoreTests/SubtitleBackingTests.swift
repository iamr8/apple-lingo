import Foundation
import Testing
@testable import AppleLingoCore

struct SubtitleBackingTests {
    static func cue(_ id: Int, _ start: Double, _ end: Double, _ text: String) -> Cue {
        Cue(id: id, start: start, end: end, text: text)
    }

    /// Timing track speech: a recap at 9-15 s, then dialogue from 113 s.
    static let timing = [
        cue(1, 9, 11, "a1"), cue(2, 11.5, 13, "a2"), cue(3, 13.5, 15, "a3"),
        cue(4, 86, 88, "sign"), cue(5, 113, 114.5, "a4"), cue(6, 115.8, 117.5, "a5"),
    ]

    // Breaks if a line with a link or an @handle stays, or a credit over speech ("translation:"
    // or "::" frames) stays while dialogue with the same word goes, or a line over no speech in the first or
    // last 5 minutes (a credit) stays, or a real line, a sign over speech, or a short line over no
    // speech mid-film ("Oh", which Apple does not caption) is dropped. Texts are from real files.
    @Test func cleanDropsAds() {
        let backing = [
            Self.cue(1, 9.5, 12, "سی‌نما تقدیم میکند\nwww.30nama.com"),
            Self.cue(2, 12.5, 14, "« کانال رسمی تیم ترجمه‌ی 30نما‌ »\n:. @CinamaSub .:"),
            Self.cue(3, 78, 81, ":ترجمه و تنظیم\nمریم"),
            Self.cue(4, 86.3, 88.6, "«الهام گرفته از داستان واقعی»"),
            Self.cue(5, 113, 114.5, "هفته‌ی اوّل چطور گذشت؟"),
            Self.cue(6, 1497.2, 1497.8, "اوه"),
            Self.cue(7, 3406.1, 3409, "مترجمان: «حسین هیدن و کیارش نعمت گرگانی»"),
            Self.cue(8, 2000, 2001, "ارائه شده توسط وبسایت دیجی موویز\n.:: DigiMoviez.Com ::."),
            Self.cue(9, 2001, 2002, "https://t.me/sub"),
            Self.cue(10, 115.9, 117.4, "خیلی خب"),
            Self.cue(11, 2000.2, 2000.8, ":ترجمه و تنظیم\nمریم"),
            Self.cue(12, 2001, 2002, "اینو برام ترجمه کن"),
            Self.cue(13, 2001.2, 2001.8, ".:: ارائه ای از تیم ترجمه رسانه اینترنتی نایت مووی ::."),
        ]
        let timing = Self.timing + [Self.cue(7, 2000, 2002, "a6"), Self.cue(8, 3690, 3692, "a7")]
        // Alignment can move a cue before its neighbour; the result is in time order.
        #expect(SubtitleBacking.clean(backing, timing: timing).map(\.id) == [4, 5, 10, 6, 12])
    }

    // Breaks if the job translates the preview before the backing's first line (the user wants
    // subtitles from the content on), or the end credits after its last line (a translated Apple
    // track ends with its own translator's credit), or timing cues the backing covers (also a cue the backing
    // times 0.2 s apart), misses an uncovered one in the content, or sends source lines not
    // spoken during the gaps.
    @Test func gapJobCoversOnlyUncoveredDialogue() throws {
        let timing = Self.timing + [Self.cue(7, 130, 132, "a6"), Self.cue(8, 145, 146, "a7"), Self.cue(9, 3514.8, 3517, "ترجمة \"عنان خضر\"")]
        let backing = [Self.cue(1, 86.3, 88.6, "s"), Self.cue(2, 113, 114.5, "b1"), Self.cue(3, 117.3, 118.5, "b2"),
                       Self.cue(4, 140, 141, "b3")]
        let source = [
            Self.cue(1, 9, 11.4, "e1"), Self.cue(2, 113, 117.5, "e2"), Self.cue(3, 129.5, 131, "e3"), Self.cue(4, 140, 141, "e4"),
        ]
        let job = try #require(SubtitleBacking.gapJob(backing: backing, source: source, sourceLanguage: "en",
                                                      timing: timing, timingLanguage: "ar", targetLanguage: "fa"))
        #expect(job.timing.map(\.id) == [7])
        #expect(job.source.map(\.id) == [3])
        #expect([job.sourceLanguage, job.timingLanguage, job.targetLanguage] == ["en", "ar", "fa"])
        #expect(SubtitleBacking.gapJob(backing: backing, source: source, sourceLanguage: "en",
                                       timing: Self.timing, timingLanguage: "ar", targetLanguage: "fa") == nil)
    }

    // Breaks if filled lines are not put in time order with the backing, or ids repeat.
    @Test func mergeOrdersByTime() {
        let backing = [Self.cue(1, 86, 88, "s"), Self.cue(2, 113, 114, "b")]
        let fill = [Self.cue(1, 9, 11, "f1"), Self.cue(2, 100, 101, "f2")]
        let merged = SubtitleBacking.merge(backing, fill)
        #expect(merged.map(\.text) == ["f1", "s", "f2", "b"])
        #expect(merged.map(\.id) == [1, 2, 3, 4])
        #expect(merged.map(\.start) == [9, 86, 100, 113])
    }
}
