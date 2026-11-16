import CoreMedia
import Foundation
import Speech
import Testing

@testable import Transcribe

struct SpeakerTranscriberTests {
    @Test func readsWhenEachWordWasSaidWithWhatFollowsIt() {
        var text = AttributedString()
        for (piece, time) in [(" ", nil), ("Good", 1.0), (" ", nil), ("morning", 1.4), (".", nil)]
            as [(String, Double?)]
        {
            var run = AttributedString(piece)
            if let time {
                run.audioTimeRange = CMTimeRange(
                    start: CMTime(seconds: time, preferredTimescale: 1_000),
                    duration: CMTime(seconds: 0.3, preferredTimescale: 1_000)
                )
            }
            text += run
        }

        let words = SpeakerTranscriber.words(of: text)

        #expect(words.map(\.text) == [" Good ", "morning."])
        #expect(words.map(\.start) == [1.0, 1.4])
        #expect(words.map(\.end) == [1.3, 1.7])
        #expect(SpeakerTranscriber.words(of: AttributedString("No times.")).isEmpty)
    }
}
