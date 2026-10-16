import Testing
@testable import SubOverlayCore

struct StreamLeadTests {
    // Breaks if the lead is not Now Playing's length minus the video's (measured on Hand to Mouth:
    // 3721.311 − 3692.23, captions 28.6 to 30.2 s early), or a bad pair moves the captions.
    @Test func leadIsExtraLength() {
        #expect(abs(StreamLead.seconds(nowPlaying: 3721.311, video: 3692.23) - 29.081) < 0.001)
        #expect(StreamLead.seconds(nowPlaying: nil, video: 3692.23) == 0)
        #expect(StreamLead.seconds(nowPlaying: 3721.3, video: nil) == 0)
        #expect(StreamLead.seconds(nowPlaying: 3692.4, video: 3692.23) == 0)
        #expect(StreamLead.seconds(nowPlaying: 3600, video: 3692.23) == 0)
        #expect(StreamLead.seconds(nowPlaying: 7400, video: 3692.23) == 0)
    }

    // Breaks if the lead does not come from the content start when the clock gave one (WhatsHerName:
    // the main player's clock began at 86.61, the download's content at 55.402; the lengths gave
    // 30.55, 0.66 s short), or if a content start before the download's part is taken.
    @Test func contentStartGivesTheExactLead() {
        #expect(abs(StreamLead.seconds(contentStart: 86.61, contentPart: 55.402, nowPlaying: 3819.248, video: 3788.70) - 31.208) < 0.001)
        #expect(abs(StreamLead.seconds(contentStart: nil, contentPart: 55.402, nowPlaying: 3819.248, video: 3788.70) - 30.548) < 0.001)
        #expect(abs(StreamLead.seconds(contentStart: 86.61, contentPart: nil, nowPlaying: 3819.248, video: 3788.70) - 30.548) < 0.001)
        #expect(abs(StreamLead.seconds(contentStart: 40, contentPart: 55.402, nowPlaying: 3819.248, video: 3788.70) - 30.548) < 0.001)
    }
}
