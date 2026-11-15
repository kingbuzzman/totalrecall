import AVFoundation
import Testing

@testable import TotalRecall

struct LiveEncoderTests {
    @Test(arguments: [
        ("wav", kAudioFormatLinearPCM),
        ("aiff", kAudioFormatLinearPCM),
        ("m4a", kAudioFormatMPEG4AAC),
        ("flac", kAudioFormatFLAC),
    ])
    func encodesWhileRecordingSoSavingOnlyMovesTheFile(fileExtension: String, format: AudioFormatID) throws {
        try withTemporaryDirectory { directory in
            let output = OutputFile(path: directory.appending(path: "out.\(fileExtension)").path)
            let encoder = try #require(LiveEncoder.start(for: output))
            try writePartialRecording(for: output, encoder: encoder)

            try output.save(encoded: try encoder.finish())

            let saved = try AVAudioFile(forReading: output.url)
            #expect(saved.formatID == format)
            #expect(saved.fileFormat.channelCount == 2)
            #expect(saved.fileFormat.sampleRate == sampleRate)
            #expect(saved.length >= 9_600)
            #expect(!FileManager.default.fileExists(atPath: encoder.url.path))
            #expect(!FileManager.default.fileExists(atPath: output.partialURL.path))
        }
    }

    @Test(.enabled(if: FFmpeg.isInstalled, "needs ffmpeg"))
    func encodesWithFFmpegWhatMacOSCannot() throws {
        try withTemporaryDirectory { directory in
            let output = OutputFile(path: directory.appending(path: "out.mp3").path)
            let encoder = try #require(LiveEncoder.start(for: output))
            try writePartialRecording(for: output, encoder: encoder)

            try output.save(encoded: try encoder.finish())

            let saved = try AVAudioFile(forReading: output.url)
            #expect(saved.formatID == kAudioFormatMPEGLayer3)
            #expect(saved.fileFormat.channelCount == 2)
            #expect(saved.length >= 9_600)
        }
    }

    @Test func encodesNothingForCAFTheFormatItIsRecordedIn() {
        #expect(LiveEncoder.start(for: OutputFile(path: "/tmp/out.caf")) == nil)
        #expect(LiveEncoder.start(for: OutputFile(path: "/tmp/out")) == nil)
    }

    @Test func encodesNextToTheOutputFile() {
        #expect(OutputFile(path: "/tmp/rec.mp3").encodingURL?.path == "/tmp/rec.encoding.mp3")
        #expect(OutputFile(path: "/tmp/rec.CAF").encodingURL == nil)
    }

    @Test func reportsAnEncoderThatFailedAndDeletesItsFile() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appending(path: "out.encoding.m4a")
            try Data("half a file".utf8).write(to: url)
            let encoder = LiveEncoder(url: url, encoder: FakeEncoder(failsToWrite: true))

            encoder.append(left: [0.1], right: [0.1], count: 1)

            #expect(throws: FakeEncoder.Failure.self) { try encoder.finish() }
            #expect(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func givesUpOnAnEncoderThatFallsTooFarBehind() throws {
        try withTemporaryDirectory { directory in
            let stuck = FakeEncoder()
            stuck.writing.wait()  // every write waits until the test lets it go
            let encoder = LiveEncoder(url: directory.appending(path: "out.encoding.m4a"), encoder: stuck)

            encoder.append(left: [], right: [], count: LiveEncoder.maxBacklogFrames)
            encoder.append(left: [], right: [], count: 1)
            stuck.writing.signal()

            #expect {
                try encoder.finish()
            } throws: { error in
                error.localizedDescription == "encoding fell more than 120 s behind"
            }
        }
    }

    @Test func cancellingStopsTheEncoderAndDeletesItsFile() throws {
        try withTemporaryDirectory { directory in
            let output = OutputFile(path: directory.appending(path: "out.m4a").path)
            let encoder = try #require(LiveEncoder.start(for: output))
            encoder.append(left: sine(frequency: 440, count: 4_800), right: [], count: 4_800)

            encoder.cancel()

            #expect(!FileManager.default.fileExists(atPath: encoder.url.path))
            #expect(throws: CancellationError.self) { try encoder.finish() }
        }
    }

    @Test func findsFFmpegOnThePathOrWhereHomebrewPutsIt() throws {
        try withTemporaryDirectory { directory in
            let ffmpeg = directory.appending(path: "ffmpeg")
            try Data("#!/bin/sh\n".utf8).write(to: ffmpeg)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ffmpeg.path)

            #expect(findFFmpeg(environment: ["PATH": "/nowhere:\(directory.path)"]) == ffmpeg)
            let homebrew = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first {
                FileManager.default.isExecutableFile(atPath: $0)
            }
            #expect(findFFmpeg(environment: [:])?.path == homebrew)
        }
    }

    /// 0.2 s of a tone, in two writes, into the partial recording and the encoder, as `EncodingSink` writes them, with
    /// the right channel shorter than the left.
    private func writePartialRecording(for output: OutputFile, encoder: LiveEncoder) throws {
        let sink = EncodingSink(file: try AudioFileSink(url: output.partialURL), encoder: encoder)
        let tone = sine(frequency: 440, count: 4_800)
        try sink.write(left: tone, right: tone, count: tone.count)
        try sink.write(left: tone, right: Array(tone.prefix(1_000)), count: tone.count)
        sink.close()
    }
}

/// Encodes nothing; a write fails with `failsToWrite`, and waits while the test holds `writing`.
private final class FakeEncoder: Encoder, @unchecked Sendable {
    struct Failure: Error {}

    let writing = DispatchSemaphore(value: 1)
    private let failsToWrite: Bool

    init(failsToWrite: Bool = false) {
        self.failsToWrite = failsToWrite
    }

    func write(left: [Float], right: [Float], count: Int) throws {
        writing.wait()
        defer { writing.signal() }
        if failsToWrite { throw Failure() }
    }

    func finish() throws {}
    func cancel() {}
}
