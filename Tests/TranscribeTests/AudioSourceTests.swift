import AudioLab
import Foundation
import Testing

@testable import Transcribe

struct FileAudioSourceTests {
    @Test func readsAnAudioFileInChunks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mono.caf")
        try writeAudioFile([(0..<250).map { Float($0) / 1_000 }], sampleRate: 16_000, to: url)

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
}
