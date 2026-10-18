import AVFoundation
import Foundation
import Shared

/// Audio to transcribe, read in chunks of float samples, one array per channel.
protocol AudioSource {
    var sampleRate: Double { get }
    var channelCount: Int { get }
    /// Up to `maxFrames` frames, or nil at the end.
    func read(maxFrames: Int) throws -> [[Float]]?
}

/// Any audio file macOS can read (.m4a, .mp3, .wav, .caf, ...). Read by one task at a time.
final class FileAudioSource: AudioSource, @unchecked Sendable {
    private let file: AVAudioFile
    /// Reused from one read to the next; each read copies what it read out of it.
    private var buffer: AVAudioPCMBuffer?

    var sampleRate: Double { file.processingFormat.sampleRate }
    var channelCount: Int { Int(file.processingFormat.channelCount) }

    init(url: URL) throws {
        file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func read(maxFrames: Int) throws -> [[Float]]? {
        guard file.framePosition < file.length else { return nil }
        if buffer?.frameCapacity != AVAudioFrameCount(maxFrames) {
            buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(maxFrames))
        }
        let buffer = buffer!
        try file.read(into: buffer)
        guard buffer.frameLength > 0 else { return nil }
        return (0..<channelCount).map { channel in
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
        }
    }
}

/// A live WAV stream, such as `totalrecall -` on stdin.
extension WAVStreamReader: AudioSource {}
