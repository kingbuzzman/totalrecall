import Testing

@testable import Transcribe

struct ClipCutterTests {
    /// Frames of `seconds` of speech, or of silence with `isSpeech` false.
    private func frames(_ seconds: Double, _ isSpeech: Bool = true) -> [Bool] {
        Array(repeating: isSpeech, count: Int(seconds * VoicePrinter.sampleRate / Double(VoicePrinter.hopLength)))
    }

    private func seconds(_ run: Range<Int>?) -> Double {
        Double(run?.count ?? 0) / VoicePrinter.sampleRate
    }

    @Test func keepsTheGapsBetweenWordsAndBreathsInARun() {
        let sentence = frames(2) + frames(0.2, false) + frames(2) + frames(0.45, false) + frames(2)

        #expect(abs(seconds(ClipCutter.longestRun(in: sentence)) - 6.65) < 0.05)
    }

    @Test func endsARunAtAPause() {
        let twoSentences = frames(3) + frames(0.8, false) + frames(4)

        let run = ClipCutter.longestRun(in: twoSentences)

        #expect(abs(seconds(run) - 4) < 0.05)
        #expect(run.map { Double($0.lowerBound) / VoicePrinter.sampleRate }.map { abs($0 - 3.8) < 0.05 } == true)
    }

    @Test func findsNoRunInSilence() {
        #expect(ClipCutter.longestRun(in: frames(5, false)) == nil)
        #expect(ClipCutter.longestRun(in: []) == nil)
    }
}
