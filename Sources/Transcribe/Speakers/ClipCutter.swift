/// Where to cut a clip of someone from a stretch of their speech: its longest run of speech with no pause in it, only the
/// gaps between words, as a sentence of one voice, not words strung across silences, is what tells a voice apart.
enum ClipCutter {
    /// Gaps up to this long, in seconds, between words and the breaths between phrases, are part of a run of speech; a
    /// longer one is a pause, which ends it. Measured on a real meeting, 0.3 s left a 5 s run in 4 of 14 long stretches
    /// of one person, 0.5 s in 11.
    static let longestGap = 0.5

    /// The longest run of speech among `frames`, which say which frames of some audio at `VoicePrinter.sampleRate` are
    /// speech (as `VoicePrinting.speechFrames` gives them), as the range of the audio's samples it covers; nil when
    /// none of it is speech.
    static func longestRun(in frames: [Bool]) -> Range<Int>? {
        let hop = VoicePrinter.hopLength
        let gapFrames = Int(longestGap * VoicePrinter.sampleRate / Double(hop))
        var runs: [ClosedRange<Int>] = []
        for index in frames.indices where frames[index] {
            if let last = runs.last, index - last.upperBound - 1 <= gapFrames {
                runs[runs.count - 1] = last.lowerBound...index
            } else {
                runs.append(index...index)
            }
        }
        guard let longest = runs.max(by: { $0.count < $1.count }) else { return nil }
        return longest.lowerBound * hop..<longest.upperBound * hop + VoicePrinter.frameLength
    }
}
