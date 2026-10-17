import AVFoundation

/// Converts captured buffers of any format and rate to mono at the recording sample rate.
final class Resampler {
    /// Room beyond the rate ratio for rounding and for frames the converter held back from the previous buffer.
    private static let capacitySlackFrames: AVAudioFrameCount = 64

    private let converter: AVAudioConverter

    init(from format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: format, to: monoFormat) else {
            throw RecordingError("cannot convert audio from \(format)")
        }
        converter.downmix = true
        self.converter = converter
    }

    func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = monoFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + Self.capacitySlackFrames
        guard let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if error != nil { return [] }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}
