import AVFoundation
import Accelerate
import CoreML
import Foundation
import Shared

/// What someone's voice sounds like, to tell people apart by: a speaker embedding, from a neural network trained to give
/// the same voice the same direction however it is spoken and whatever it says (WeSpeaker's ResNet34-LM; see
/// `SpeakerModel`). The network hears 80-band log-mel filterbank frames of 16 kHz audio, computed here as Kaldi computes
/// them, as it was trained on; which frames are whose is for `Segmenter` to say. A print is 256 numbers, of length 1, so
/// `voiceDistance` is how far apart their directions are.
final class VoicePrinter: VoicePrinting {
    static let sampleRate = 16_000.0
    static let printLength = 256
    /// The network hears from 1 s to 10 s of frames: fewer are repeated to make 1 s; more are printed in equal parts of
    /// up to 10 s, and the prints averaged. Core ML plans the model again for each length it has not had yet, which
    /// costs far more than a print, so each part is cut to whole seconds, evenly from both ends, where someone's
    /// talking starts and ends, the least sure of it: 10 lengths in all.
    static let fewestFrames = 100
    static let mostFrames = 1_000
    // Kaldi's filterbank, as WeSpeaker computes it: 25 ms frames every 10 ms, the DC offset removed, pre-emphasized,
    // Hamming-windowed, the power spectrum through 80 triangular mel bands from 20 Hz to 8 kHz, of samples at the scale
    // of 16-bit audio.
    static let frameLength = 400
    static let hopLength = 160
    private static let fftLength = 512
    private static let bandCount = 80
    private static let preemphasis: Float = 0.97
    private static let sampleScale: Float = 32_768

    private let model: MLModel
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    /// One triangular filter per mel band, over the FFT bins below the Nyquist frequency.
    private let filters: [[Float]]

    init(model: MLModel) throws {
        guard let fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self) else {
            throw MessageError("cannot set up the FFT for voice prints")
        }
        self.model = model
        self.fft = fft
        window = (0..<Self.frameLength).map {
            Float(0.54 - 0.46 * cos(2 * Double.pi * Double($0) / Double(Self.frameLength - 1)))
        }
        func mel(_ hertz: Double) -> Double { 1127 * log(1 + hertz / 700) }
        let (low, high) = (mel(20), mel(Self.sampleRate / 2))
        let step = (high - low) / Double(Self.bandCount + 1)
        filters = (0..<Self.bandCount).map { band in
            let left = low + Double(band) * step
            let (center, right) = (left + step, left + 2 * step)
            return (0..<Self.fftLength / 2).map { bin in
                let frequency = mel(Self.sampleRate / Double(Self.fftLength) * Double(bin))
                return Float(max(0, min((frequency - left) / (center - left), (right - frequency) / (right - center))))
            }
        }
    }

    /// The filterbank frames of this audio, at `sampleRate`: one every `hopLength` samples, for as many as fit whole.
    func frames(of samples: ArraySlice<Float>) -> [[Float]] {
        stride(from: samples.startIndex, through: samples.endIndex - Self.frameLength, by: Self.hopLength).map {
            bands(of: samples[$0..<$0 + Self.frameLength])
        }
    }

    /// The print of these frames, which must be some.
    func voicePrint(of frames: [[Float]]) throws -> [Float] {
        precondition(!frames.isEmpty, "a voice print of no audio")
        var frames = frames
        while frames.count < Self.fewestFrames { frames += frames.prefix(Self.fewestFrames - frames.count) }
        let parts = (frames.count + Self.mostFrames - 1) / Self.mostFrames
        let length = frames.count / parts / Self.fewestFrames * Self.fewestFrames
        let first = (frames.count - parts * length) / 2
        var sum = [Float](repeating: 0, count: Self.printLength)
        for part in 0..<parts {
            let start = first + part * length
            vDSP.add(sum, try embed(frames[start..<start + length]), result: &sum)
        }
        return vDSP.divide(sum, vDSP.sumOfSquares(sum).squareRoot())
    }

    /// The network's print of these frames, less their mean, as it was trained on.
    private func embed(_ frames: ArraySlice<[Float]>) throws -> [Float] {
        var mean = [Float](repeating: 0, count: Self.bandCount)
        for frame in frames { vDSP.add(mean, frame, result: &mean) }
        mean = vDSP.divide(mean, Float(frames.count))
        let shape = [1, frames.count, Self.bandCount].map { NSNumber(value: $0) }
        let input = try MLMultiArray(shape: shape, dataType: .float32)
        let values = input.dataPointer.bindMemory(to: Float.self, capacity: frames.count * Self.bandCount)
        for (index, frame) in frames.enumerated() {
            for band in 0..<Self.bandCount { values[index * Self.bandCount + band] = frame[band] - mean[band] }
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": input]))
        guard let embedding = output.featureValue(for: "embedding")?.multiArrayValue,
            embedding.count == Self.printLength
        else { throw MessageError("the speaker model gave no voice print") }
        let print = (0..<Self.printLength).map { embedding[$0].floatValue }
        let length = vDSP.sumOfSquares(print).squareRoot()
        guard length > 0, length.isFinite else { throw MessageError("the speaker model gave an empty voice print") }
        return vDSP.divide(print, length)
    }

    /// A frame's log mel filterbank.
    private func bands(of frame: ArraySlice<Float>) -> [Float] {
        var samples = vDSP.multiply(Self.sampleScale, frame)
        samples = vDSP.add(-vDSP.mean(samples), samples)
        for index in stride(from: samples.count - 1, to: 0, by: -1) {
            samples[index] -= Self.preemphasis * samples[index - 1]
        }
        samples[0] -= Self.preemphasis * samples[0]
        let windowed = vDSP.multiply(samples, window) + [Float](repeating: 0, count: Self.fftLength - Self.frameLength)
        let binCount = Self.fftLength / 2
        var real = [Float](repeating: 0, count: binCount)
        var imaginary = real
        var power = real
        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                var split = DSPSplitComplex(realp: real.baseAddress!, imagp: imaginary.baseAddress!)
                windowed.withUnsafeBufferPointer { windowed in
                    windowed.withMemoryRebound(to: DSPComplex.self) { pairs in
                        vDSP_ctoz(pairs.baseAddress!, 2, &split, 1, vDSP_Length(binCount))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        // vDSP's FFT gives twice the DFT, and packs the Nyquist bin, which is in no band, in with the DC one.
        power = vDSP.multiply(0.25, power)
        power[0] = real[0] * real[0] / 4
        return filters.map { log(max(vDSP.dot($0, power), Float.ulpOfOne)) }
    }
}

/// Makes voice prints of audio at `VoicePrinter.sampleRate`: `VoicePrinter`, or a stand-in in the tests.
protocol VoicePrinting {
    /// The audio's frames, `VoicePrinter.frameLength` long and `VoicePrinter.hopLength` apart, as prints are made of.
    func frames(of samples: ArraySlice<Float>) -> [[Float]]
    /// The print of some of those frames, at least one.
    func voicePrint(of frames: [[Float]]) throws -> [Float]
}

/// How different two voice prints sound: 1 less the cosine of the angle between them, from 0 for the same direction
/// to 2 for opposite ones: up to about 0.3 from one stretch of someone's speech to the average of theirs, 0.5 and up
/// from someone else's. An average of prints is shorter than a print, which does not change its direction. Prints that
/// are not this version's, such as ones saved by an earlier one, sound as different as can be.
package func voiceDistance(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == VoicePrinter.printLength, b.count == VoicePrinter.printLength else { return .infinity }
    let lengths = (vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)).squareRoot()
    return lengths > 0 ? 1 - vDSP.dot(a, b) / lengths : .infinity
}

/// Turns audio at one sample rate into audio at `VoicePrinter.sampleRate`, as it comes in.
final class VoiceResampler {
    private let sourceFormat: AVAudioFormat
    private let format: AVAudioFormat
    private let converter: AVAudioConverter?
    private let converterInput = ConverterInput()

    /// Throws for a sample rate too low to hear a voice in, or one that is not a sample rate at all.
    init(sampleRate: Double) throws {
        guard sampleRate.isFinite, (8_000...768_000).contains(sampleRate),
            let sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
            let format = AVAudioFormat(standardFormatWithSampleRate: VoicePrinter.sampleRate, channels: 1)
        else { throw MessageError("cannot tell voices apart in audio at \(sampleRate) Hz") }
        self.sourceFormat = sourceFormat
        self.format = format
        if sampleRate == VoicePrinter.sampleRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
                throw MessageError("cannot tell voices apart in audio at \(sampleRate) Hz")
            }
            self.converter = converter
        }
    }

    func resample(_ samples: [Float]) -> [Float] {
        guard let converter, !samples.isEmpty else { return samples }
        guard let input = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return [] }
        input.frameLength = input.frameCapacity
        input.floatChannelData![0].update(from: samples, count: samples.count)
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / sourceFormat.sampleRate) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity),
            converterInput.convert(input, with: converter, into: output) == nil
        else { return [] }
        return output.samples()
    }
}
