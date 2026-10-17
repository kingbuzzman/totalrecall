import Foundation
import Shared
import Testing

struct WAVStreamTests {
    @Test func headerDescribesStreamedPCMOfUnknownLength() {
        let header = WAVStream.header(sampleRate: 48_000, channelCount: 2)

        #expect(header.count == 44)
        #expect(header.ascii(0..<4) == "RIFF")
        #expect(header.uint32(at: 4) == WAVStream.unknownSize)
        #expect(header.ascii(8..<16) == "WAVEfmt ")
        #expect(header.uint32(at: 16) == 16)
        #expect(header.uint16(at: 20) == 1)
        #expect(header.uint16(at: 22) == 2)
        #expect(header.uint32(at: 24) == 48_000)
        #expect(header.uint32(at: 28) == 192_000)
        #expect(header.uint16(at: 32) == 4)
        #expect(header.uint16(at: 34) == 16)
        #expect(header.ascii(36..<40) == "data")
        #expect(header.uint32(at: 40) == WAVStream.unknownSize)
    }

    @Test func samplesInterleaveChannelsAndClipToFullScale() {
        let data = WAVStream.samples([[0.5, 2], [-0.5, -2]], count: 2)

        #expect(data.int16Samples == [16383, -16383, .max, -.max])
    }

    @Test func samplesPadAShortChannelWithSilence() {
        let data = WAVStream.samples([[0.25, 0.25, 0.25], [1]], count: 3)

        #expect(data.int16Samples == [8191, .max, 8191, 0, 8191, 0])
    }
}

struct WAVStreamReaderTests {
    @Test func readsWhatWAVStreamWrites() throws {
        let left = (0..<1_000).map { sin(Float($0) / 10) / 2 }
        let right = left.map { -$0 }
        let stream =
            WAVStream.header(sampleRate: 16_000, channelCount: 2) + WAVStream.samples([left, right], count: 1_000)

        let reader = try WAVStreamReader(handle: .reading(stream))
        let channels = try reader.readAll()

        #expect(reader.sampleRate == 16_000)
        #expect(reader.channelCount == 2)
        #expect(channels.map(\.count) == [1_000, 1_000])
        #expect(channels[0].isClose(to: left, tolerance: 1e-4))
        #expect(channels[1].isClose(to: right, tolerance: 1e-4))
    }

    @Test func readsAtMostMaxFramesAtATime() throws {
        let stream = WAVStream.header(sampleRate: 8_000, channelCount: 1) + WAVStream.samples([[0.5]], count: 250)
        let reader = try WAVStreamReader(handle: .reading(stream))

        var chunkSizes: [Int] = []
        while let chunk = try reader.read(maxFrames: 100) { chunkSizes.append(chunk[0].count) }

        #expect(chunkSizes == [100, 100, 50])
    }

    @Test func readsFloatSamples() throws {
        let stream = WAVBytes.riff(
            WAVBytes.format(tag: 3, channels: 1, bits: 32),
            WAVBytes.data(WAVBytes.float32Samples([0.25, -1, 0.5]))
        )

        let channels = try WAVStreamReader(handle: .reading(stream)).readAll()

        #expect(channels == [[0.25, -1, 0.5]])
    }

    @Test func readsTheSampleFormatOfWaveFormatExtensible() throws {
        let stream = WAVBytes.riff(
            WAVBytes.extensibleFormat(subformat: 3, channels: 1),
            WAVBytes.data(WAVBytes.float32Samples([0.75]))
        )

        let channels = try WAVStreamReader(handle: .reading(stream)).readAll()

        #expect(channels == [[0.75]])
    }

    @Test func skipsUnknownChunksAndTheirPadByte() throws {
        let stream = WAVBytes.riff(
            WAVBytes.chunk("LIST", Data("odd".utf8)),
            WAVBytes.format(channels: 1),
            WAVBytes.chunk("fact", Data(count: 4)),
            WAVBytes.data(WAVBytes.int16Samples([.max]))
        )

        let channels = try WAVStreamReader(handle: .reading(stream)).readAll()

        #expect(channels == [[1]])
    }

    @Test func stopsAtTheEndOfADataChunkOfKnownSize() throws {
        let stream = WAVBytes.riff(
            WAVBytes.format(channels: 1),
            WAVBytes.data(WAVBytes.int16Samples([.max, .max, 1, 1]), size: 4)
        )

        let channels = try WAVStreamReader(handle: .reading(stream)).readAll()

        #expect(channels == [[1, 1]])
    }

    @Test func readsADataChunkOfSizeZeroUntilTheStreamEnds() throws {
        let stream = WAVBytes.riff(
            WAVBytes.format(channels: 1),
            WAVBytes.data(WAVBytes.int16Samples([.max, .max, .max]), size: 0)
        )

        let channels = try WAVStreamReader(handle: .reading(stream)).readAll()

        #expect(channels == [[1, 1, 1]])
    }

    @Test func dropsATrailingPartialFrame() throws {
        let stream =
            WAVStream.header(sampleRate: 48_000, channelCount: 2) + WAVBytes.int16Samples([.max, .max]) + Data([1])

        let channels = try WAVStreamReader(handle: .reading(stream)).readAll()

        #expect(channels == [[1], [1]])
    }

    @Test(arguments: InvalidStream.all)
    func rejectsInvalidStreams(_ invalid: InvalidStream) {
        #expect {
            try WAVStreamReader(handle: .reading(invalid.data))
        } throws: { error in
            error.localizedDescription == invalid.message
        }
    }
}

struct InvalidStream: CustomTestStringConvertible, Sendable {
    let data: Data
    let message: String
    let testDescription: String

    static let all = [
        InvalidStream(data: Data(), message: "not a WAV stream", testDescription: "empty"),
        InvalidStream(data: Data("RIFX0000WAVE".utf8), message: "not a WAV stream", testDescription: "not RIFF"),
        InvalidStream(data: WAVBytes.riff(), message: "WAV stream has no audio", testDescription: "no chunks"),
        InvalidStream(
            data: WAVBytes.riff(WAVBytes.data(Data())),
            message: "WAV stream has no format",
            testDescription: "data before format"
        ),
        InvalidStream(
            data: WAVBytes.riff(WAVBytes.chunk("fmt ", Data(count: 12)), WAVBytes.data(Data())),
            message: "WAV format chunk is too short",
            testDescription: "short format"
        ),
        InvalidStream(
            data: WAVBytes.riff(WAVBytes.format(bits: 24), WAVBytes.data(Data())),
            message: "unsupported WAV format 1 with 24-bit samples",
            testDescription: "24-bit"
        ),
        InvalidStream(
            data: WAVBytes.riff(WAVBytes.format(channels: 0), WAVBytes.data(Data())),
            message: "WAV stream has no channels",
            testDescription: "no channels"
        ),
        InvalidStream(
            data: WAVBytes.riff(WAVBytes.format()).prefix(20),
            message: "WAV stream ended in its header",
            testDescription: "truncated header"
        ),
    ]
}

extension WAVStreamReader {
    func readAll() throws -> [[Float]] {
        var channels = [[Float]](repeating: [], count: channelCount)
        while let chunk = try read(maxFrames: 64) {
            for (index, samples) in chunk.enumerated() { channels[index] += samples }
        }
        return channels
    }
}

extension [Float] {
    func isClose(to other: [Float], tolerance: Float) -> Bool {
        count == other.count && zip(self, other).allSatisfy { abs($0 - $1) <= tolerance }
    }
}
