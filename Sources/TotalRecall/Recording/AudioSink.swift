import AVFoundation
import Foundation

/// Where `Recorder` writes the recording: left and right channels, `count` frames at `sampleRate`.
protocol AudioSink: AnyObject {
    /// A channel shorter than `count` (no microphone) is written as silence after its end.
    func write(left: [Float], right: [Float], count: Int) throws
    func close()
}

/// A 16-bit PCM CAF file, which stays readable if the process dies.
final class AudioFileSink: AudioSink {
    private var file: AVAudioFile?

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
        let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(count))!
        buffer.frameLength = AVAudioFrameCount(count)
        for (channel, samples) in [left, right].enumerated() {
            let destination = buffer.floatChannelData![channel]
            destination.update(repeating: 0, count: count)
            destination.update(from: samples, count: min(samples.count, count))
        }
        try file.write(from: buffer)
    }

    func close() {
        file?.close()
        file = nil
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
