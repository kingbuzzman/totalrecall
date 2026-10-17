import AVFoundation
import Shared
import Testing

@testable import TotalRecall

struct AudioFileSinkTests {
    @Test func writesStereoAndPadsAShortChannelWithSilence() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("sink.caf")
            let sink = try AudioFileSink(url: url)

            try sink.write(left: constant(0.5, count: 100), right: constant(-0.25, count: 40), count: 100)
            sink.close()

            let channels = try readChannels(url)
            #expect(channels[0].isClose(to: constant(0.5, count: 100)))
            #expect(channels[1].isClose(to: constant(-0.25, count: 40) + silence(60)))
        }
    }

    @Test func ignoresWritesAfterClosing() throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("sink.caf")
            let sink = try AudioFileSink(url: url)
            sink.close()

            try sink.write(left: constant(0.5, count: 100), right: constant(0.5, count: 100), count: 100)

            #expect(try AVAudioFile(forReading: url).length == 0)
        }
    }

    private func readChannels(_ url: URL) throws -> [[Float]] {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return (0..<2).map {
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![$0], count: Int(buffer.frameLength)))
        }
    }
}

struct WAVStreamSinkTests {
    @Test func streamsAWAVThatTheReaderUnderstands() throws {
        let pipe = Pipe()
        let sink = try WAVStreamSink(handle: pipe.fileHandleForWriting)

        try sink.write(left: constant(0.5, count: 10), right: constant(-0.5, count: 4), count: 10)
        sink.close()
        try pipe.fileHandleForWriting.close()

        let reader = try WAVStreamReader(handle: pipe.fileHandleForReading)
        let chunk = try #require(try reader.read(maxFrames: 100))
        #expect(reader.sampleRate == sampleRate)
        #expect(chunk[0].isClose(to: constant(0.5, count: 10)))
        #expect(chunk[1].isClose(to: constant(-0.5, count: 4) + silence(6)))
    }

    @Test func throwsOnceTheReaderHasGoneAway() throws {
        signal(SIGPIPE, SIG_IGN)
        let pipe = Pipe()
        let sink = try WAVStreamSink(handle: pipe.fileHandleForWriting)
        try pipe.fileHandleForReading.close()

        #expect(throws: (any Error).self) {
            try sink.write(left: constant(0.5, count: 10), right: constant(0.5, count: 10), count: 10)
        }
    }
}

struct FileAndStreamSinkTests {
    @Test func writesBoth() throws {
        let (file, stream) = (CapturingSink(), CapturingSink())
        let sink = FileAndStreamSink(file: file, stream: stream)

        try sink.write(left: constant(0.5, count: 10), right: constant(-0.5, count: 10), count: 10)
        sink.close()

        #expect(file.left == constant(0.5, count: 10) && stream.left == constant(0.5, count: 10))
        #expect(file.isClosed && stream.isClosed)
    }

    @Test func keepsWritingTheFileOnceTheStreamsReaderHasGoneAway() throws {
        let (file, stream) = (CapturingSink(), FailingSink())
        let sink = FileAndStreamSink(file: file, stream: stream)
        var closings = 0
        sink.onStreamClosed = { closings += 1 }

        try sink.write(left: constant(0.5, count: 10), right: constant(0.5, count: 10), count: 10)
        try sink.write(left: constant(0.25, count: 10), right: constant(0.25, count: 10), count: 10)

        #expect(file.left == constant(0.5, count: 10) + constant(0.25, count: 10))
        #expect(closings == 1)
        #expect(stream.writes == 1)
        #expect(stream.isClosed)
    }

    @Test func throwsWhenTheFileFails() {
        let sink = FileAndStreamSink(file: FailingSink(), stream: CapturingSink())

        #expect(throws: (any Error).self) {
            try sink.write(left: constant(0.5, count: 10), right: constant(0.5, count: 10), count: 10)
        }
    }
}

/// A sink whose every write fails, like a stream whose reader has gone away.
final class FailingSink: AudioSink {
    private(set) var writes = 0
    private(set) var isClosed = false

    func write(left: [Float], right: [Float], count: Int) throws {
        writes += 1
        throw RecordingError("broken pipe")
    }

    func close() {
        isClosed = true
    }
}

extension [Float] {
    func isClose(to other: [Float], tolerance: Float = 1e-4) -> Bool {
        count == other.count && zip(self, other).allSatisfy { abs($0 - $1) <= tolerance }
    }
}
