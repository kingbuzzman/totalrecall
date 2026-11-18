import AVFoundation
import Foundation
import Shared
import Testing

@testable import Transcribe

/// A live stream's audio, read as it comes, and read again from the recording of it for a transcript that starts over.
struct LiveAudioTests {
    /// A tenth of a second at 16 kHz, which the stream is read by, on two channels.
    private static let left: [Float] = (0..<1_600).map { Float($0 - 800) / 1_000 }
    private static let right: [Float] = left.reversed()

    /// A stream and a recording of the same audio, written as the recorder writes them, the recording first.
    private final class Recorder: @unchecked Sendable {
        let pipe = Pipe()
        let url = FileManager.default.temporaryDirectory.appending(path: "live-audio-\(UUID()).partial.caf")
        private var file: AVAudioFile?

        init() throws {
            file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try pipe.fileHandleForWriting.write(contentsOf: WAVStream.header(sampleRate: 16_000, channelCount: 2))
        }

        func write() throws {
            let buffer = AVAudioPCMBuffer(pcmFormat: file!.processingFormat, frameCapacity: 1_600)!
            buffer.frameLength = 1_600
            buffer.floatChannelData![0].update(from: LiveAudioTests.left, count: 1_600)
            buffer.floatChannelData![1].update(from: LiveAudioTests.right, count: 1_600)
            try file!.write(from: buffer)
            try pipe.fileHandleForWriting.write(
                contentsOf: WAVStream.samples([LiveAudioTests.left, LiveAudioTests.right], count: 1_600)
            )
        }

        /// Finishes the recording, then ends the stream, as the recorder does when it stops.
        func stop() throws {
            file = nil
            try pipe.fileHandleForWriting.close()
        }

        func live(withRecording: Bool = true) throws -> LiveAudio {
            LiveAudio(
                stream: try WAVStreamReader(handle: pipe.fileHandleForReading),
                recording: withRecording ? try FileHandle(forReadingFrom: url) : nil
            )
        }
    }

    private static func isTheAudio(_ chunk: [[Float]]?) -> Bool {
        guard let chunk, chunk.count == 2 else { return false }
        return zip(chunk[0] + chunk[1], left + right).allSatisfy { abs($0 - $1) < 1.0 / 8_192 }
    }

    @Test func readsTheStreamAsItComesAndWithoutARecordingNeverStops() throws {
        let recorder = try Recorder()
        defer { try? FileManager.default.removeItem(at: recorder.url) }
        try recorder.write()
        try recorder.stop()
        let audio = try recorder.live(withRecording: false)

        let reader = audio.streamReader { true }

        #expect(Self.isTheAudio(try reader.read(maxFrames: 1_600)))
        #expect(try reader.read(maxFrames: 1_600) == nil)
        #expect(!reader.wasStopped)
    }

    @Test func startsOverFromTheRecordingFollowingItUntilItEnds() throws {
        let recorder = try Recorder()
        let audio = try recorder.live()
        // As saving does, once the recording is stopped: open, it is still read.
        try FileManager.default.removeItem(at: recorder.url)
        let stops = Flag()
        try recorder.write()

        let stream = audio.streamReader { stops.isSet }
        #expect(Self.isTheAudio(try stream.read(maxFrames: 1_600)))
        stops.set()
        #expect(try stream.read(maxFrames: 1_600) == nil)
        #expect(stream.wasStopped)

        // The stream is drained meanwhile: the recorder goes on writing both, more than the pipe holds.
        for _ in 0..<40 { try recorder.write() }
        let recording = try audio.recordingReader { false }
        for _ in 0..<41 { #expect(Self.isTheAudio(try recording.read(maxFrames: 1_600))) }
        #expect(abs(audio.recordedSeconds - 4.1) < 0.001)
        try recorder.write()
        #expect(Self.isTheAudio(try recording.read(maxFrames: 1_600)))
        try recorder.stop()
        #expect(try recording.read(maxFrames: 1_600) == nil)
        #expect(!recording.wasStopped)
        #expect(abs(audio.recordedSeconds - 4.2) < 0.001)
        audio.close()
    }

    @Test func aRecordingReaderStopsWhenAskedRatherThanWaitForMore() throws {
        let recorder = try Recorder()
        defer { try? FileManager.default.removeItem(at: recorder.url) }
        let audio = try recorder.live()
        try recorder.write()
        let stops = Flag()
        let recording = try audio.recordingReader { stops.isSet }
        _ = try recording.read(maxFrames: 1_600)

        stops.set()

        #expect(try recording.read(maxFrames: 1_600) == nil)
        #expect(recording.wasStopped)
        try recorder.stop()
    }

    @Test func refusesARecordingThatIsNotA16BitPCMCAFFile() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "live-audio-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not audio".utf8).write(to: url)

        #expect(throws: (any Error).self) { try RecordingFile(handle: FileHandle(forReadingFrom: url)).layout() }
    }
}

/// A switch one task sets and another reads.
private final class Flag: Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
