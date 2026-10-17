import AVFoundation
import Shared
import Testing

@testable import Transcribe

struct FileAudioSourceTests {
    @Test func readsAnAudioFileInChunks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mono.caf")
        try writeFile(url, samples: (0..<250).map { Float($0) / 1_000 }, sampleRate: 16_000)

        let source = try FileAudioSource(url: url)
        var chunks: [[[Float]]] = []
        while let chunk = try source.read(maxFrames: 100) { chunks.append(chunk) }

        #expect(source.sampleRate == 16_000)
        #expect(source.channelCount == 1)
        #expect(chunks.map { $0[0].count } == [100, 100, 50])
        #expect(chunks.last?[0].last == 0.249)
    }

    @Test func refusesWhatIsNotAudio() throws {
        #expect(throws: (any Error).self) {
            try FileAudioSource(url: URL(fileURLWithPath: #filePath))
        }
    }

    private func writeFile(_ url: URL, samples: [Float], sampleRate: Double) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(samples.count)
        )!
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(from: samples, count: samples.count)
        try file.write(from: buffer)
    }
}

struct StreamAudioSourceTests {
    @Test func readsALiveWAVStream() throws {
        let pipe = Pipe()
        try pipe.fileHandleForWriting.write(
            contentsOf: WAVStream.header(sampleRate: 48_000, channelCount: 2)
                + WAVStream.samples([[0.5, 0.5], [-0.5, -0.5]], count: 2)
        )
        try pipe.fileHandleForWriting.close()

        let source = try StreamAudioSource(handle: pipe.fileHandleForReading)
        let chunk = try #require(try source.read(maxFrames: 10))

        #expect(source.sampleRate == 48_000)
        #expect(source.channelCount == 2)
        #expect(chunk.map(\.count) == [2, 2])
        #expect(try source.read(maxFrames: 10) == nil)
    }
}
