import Testing

@testable import Transcribe

struct SpeakerDetectionTests {
    @Test func detectsTotalRecallsChannelSplitAsSoonAsTheChannelsDiffer() throws {
        let source = ChunkedSource(left: [0, 0.5, 0.5], right: [0, 0.5, -0.5], sampleRate: 10)

        let (separate, chunks) = try hasSeparateSpeakers(source)

        #expect(separate)
        #expect(chunks == [[[0], [0]], [[0.5], [0.5]], [[0.5], [-0.5]]])
    }

    @Test func decidesTheChannelsAreMixedAfterASecondOfIdenticalSound() throws {
        let sound = [Float](repeating: 0.25, count: 200)
        let source = ChunkedSource(left: sound, right: sound, sampleRate: 100)

        let (separate, chunks) = try hasSeparateSpeakers(source)

        #expect(!separate)
        #expect(chunks.count == 10)
    }

    @Test func givesUpListeningAfterTenSecondsOfSilence() throws {
        let silence = [Float](repeating: 0, count: 2_000)
        let source = ChunkedSource(left: silence, right: silence, sampleRate: 100)

        let (separate, chunks) = try hasSeparateSpeakers(source)

        #expect(!separate)
        #expect(chunks.count == 100)
    }

    @Test func returnsEverythingReadWhenTheAudioEndsFirst() throws {
        let source = ChunkedSource(left: [0.5, 0.5], right: [0.5, 0.5], sampleRate: 10)

        let (separate, chunks) = try hasSeparateSpeakers(source)

        #expect(!separate)
        #expect(chunks.count == 2)
    }
}

struct MixDownTests {
    @Test func averagesTheChannels() {
        #expect(mixDown([[1, 0.5], [0, -0.5]]) == [0.5, 0])
    }

    @Test func passesMonoThrough() {
        #expect(mixDown([[0.25, 0.75]]) == [0.25, 0.75])
    }

    @Test func mixesNothingIntoNothing() {
        #expect(mixDown([]).isEmpty)
    }
}

/// Delivers stereo audio in the chunk size it is asked for.
final class ChunkedSource: AudioSource {
    let sampleRate: Double
    let channelCount = 2
    private var left: ArraySlice<Float>
    private var right: ArraySlice<Float>

    init(left: [Float], right: [Float], sampleRate: Double) {
        self.left = left[...]
        self.right = right[...]
        self.sampleRate = sampleRate
    }

    func read(maxFrames: Int) throws -> [[Float]]? {
        guard !left.isEmpty else { return nil }
        defer {
            left = left.dropFirst(maxFrames)
            right = right.dropFirst(maxFrames)
        }
        return [Array(left.prefix(maxFrames)), Array(right.prefix(maxFrames))]
    }
}
