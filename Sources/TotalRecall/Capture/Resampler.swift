import AVFoundation
import Shared

/// Converts captured buffers of any format and rate to mono at the recording sample rate. Used from one audio thread
/// at a time, so it reuses its output buffer rather than allocating one per callback.
final class Resampler {
    /// Room beyond the rate ratio for rounding and for frames the converter held back from the previous buffer.
    private static let capacitySlackFrames: AVAudioFrameCount = 64

    /// Nil when the input already is mono at the recording rate, which needs no conversion.
    private let converter: AVAudioConverter?
    private var output: AVAudioPCMBuffer?
    private let input = ConverterInput()

    init(from format: AVAudioFormat) throws {
        guard format != monoFormat else {
            converter = nil
            return
        }
        guard let converter = AVAudioConverter(from: format, to: monoFormat) else {
            throw MessageError("cannot convert audio from \(format)")
        }
        converter.downmix = true
        self.converter = converter
    }

    func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        guard let converter else { return buffer.samples() }
        let ratio = monoFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + Self.capacitySlackFrames
        output = .reusing(output, format: monoFormat, frameCapacity: capacity)
        guard let output, input.convert(buffer, with: converter, into: output) == nil else { return [] }
        return output.samples()
    }
}
