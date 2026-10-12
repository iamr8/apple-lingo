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
}
