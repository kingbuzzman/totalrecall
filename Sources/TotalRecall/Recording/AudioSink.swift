import AVFoundation
import Foundation
import Shared

/// Where `Recorder` writes the recording: left and right channels, `count` frames at `sampleRate`.
protocol AudioSink: AnyObject {
    /// A channel shorter than `count` (no microphone) is written as silence after its end.
    func write(left: [Float], right: [Float], count: Int) throws
    func close()
}

/// A 16-bit PCM CAF file, which stays readable if the process dies.
final class AudioFileSink: AudioSink {
    private var file: AVAudioFile?
    /// Reused from one write to the next.
    private var buffer: AVAudioPCMBuffer?

    init(url: URL) throws {
        file = try AVAudioFile(
            forWriting: url,
            settings: pcmSettings(bigEndian: false),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func write(left: [Float], right: [Float], count: Int) throws {
        guard let file else { return }
        if buffer.map({ $0.frameCapacity < count }) ?? true {
            buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(count))
        }
        let buffer = buffer!
        buffer.frameLength = AVAudioFrameCount(count)
        copy(left, count: count, to: buffer.floatChannelData![0])
        copy(right, count: count, to: buffer.floatChannelData![1])
        try file.write(from: buffer)
    }

    func close() {
        file?.close()
        file = nil
        buffer = nil
    }

    private func copy(_ samples: [Float], count: Int, to destination: UnsafeMutablePointer<Float>) {
        let copied = min(samples.count, count)
        destination.update(from: samples, count: copied)
        (destination + copied).update(repeating: 0, count: count - copied)
    }
}

/// A file and a live stream at once (`--stream`). The file is what matters: once the program reading the stream has gone
/// away, the stream is dropped and `onStreamClosed` called, once, and the file keeps being written.
final class FileAndStreamSink: AudioSink {
    var onStreamClosed: (() -> Void)?
    private let file: any AudioSink
    private var stream: (any AudioSink)?

    init(file: any AudioSink, stream: any AudioSink) {
        self.file = file
        self.stream = stream
    }

    /// Throws only when writing the file fails.
    func write(left: [Float], right: [Float], count: Int) throws {
        try file.write(left: left, right: right, count: count)
        guard let stream else { return }
        do {
            try stream.write(left: left, right: right, count: count)
        } catch {
            stream.close()
            self.stream = nil
            onStreamClosed?()
        }
    }

    func close() {
        file.close()
        stream?.close()
    }
}

/// A live WAV stream (see `WAVStream`), such as stdout for `totalrecall - | transcribe -`.
final class WAVStreamSink: AudioSink {
    private let handle: FileHandle

    init(handle: FileHandle) throws {
        self.handle = handle
        try handle.write(contentsOf: WAVStream.header(sampleRate: Int(sampleRate), channelCount: 2))
    }

    /// Throws once the reader has gone away (a broken pipe).
    func write(left: [Float], right: [Float], count: Int) throws {
        try handle.write(contentsOf: WAVStream.samples([left, right], count: count))
    }

    func close() {}
}
