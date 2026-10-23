import AVFoundation
import Accelerate
import CoreML
import CryptoKit
import Foundation
import MachO
import Shared

/// What a few seconds of someone's voice sounds like, to tell people apart by: a speaker embedding, from a neural
/// network trained to give the same voice the same direction however it is spoken and whatever it says (WeSpeaker's
/// ResNet34-LM; see `SpeakerModel`). The network hears 80-band log-mel filterbank frames of 16 kHz audio, computed here
/// as Kaldi computes them, as it was trained on; only the frames with speech go in: near a voiced one, with a pitch,
/// which noise has not, however quiet, as someone across the room is on a headset's microphone, and with most of its
/// sound low, as a voice's is and a notification's ping not, but not all of it, as a hum's is. A print is 256 numbers, of length 1, so `voiceDistance` is
/// how far apart their directions are.
final class VoicePrinter: VoicePrinting {
    static let sampleRate = 16_000.0
    static let printLength = 256
    /// The audio has too little speech to go by unless at least this share of its frames have some, by default; and
    /// never less than the network takes.
    static let minimumSpeech = 0.5
    private static let minimumFrames = 100
    /// Frames this much quieter than the loudest one in the audio, or quieter than `silence`, are taken for pauses.
    private static let speechRange: Float = 30
    private static let silence: Float = -75
    /// A frame is voiced if, over `pitchFrameLength`, it matches itself this well a pitch period later, for a pitch in
    /// `pitches`; speech is the frames within `voicedReach` of a voiced one, which takes in the consonants around it.
    private static let voicing: Float = 0.5
    private static let pitches = 60.0...400.0
    private static let pitchFrameLength = 640
    private static let voicedReach = 10
    /// A voice has most of its sound, above the lowest pitch, below `lowSound` Hz: in voiced frames, mostly over 0.9 of
    /// it and hardly ever under 0.4; a ping, a chime or a beep is as steady as a voice but rings above it, all of it. A
    /// frame is voiced only with at least `lowSoundShare` of its sound that low.
    private static let lowSound = 1_000.0
    private static let lowSoundShare: Float = 0.25
    /// Nor is a voice all below `formants`, where what it says is: in voiced frames, mostly over 0.3 of its sound is
    /// in them, and hardly ever under 0.02; a hum, as of a fan or the mains, as steady as a voice, is all below them.
    private static let formants = 300.0...3_400.0
    private static let formantShare: Float = 0.02
    // Kaldi's filterbank, as WeSpeaker computes it: 25 ms frames every 10 ms, the DC offset removed, pre-emphasized,
    // Hamming-windowed, the power spectrum through 80 triangular mel bands from 20 Hz to 8 kHz, of samples at the scale
    // of 16-bit audio.
    private static let frameLength = 400
    private static let hopLength = 160
    private static let fftLength = 512
    private static let bandCount = 80
    private static let preemphasis: Float = 0.97
    private static let sampleScale: Float = 32_768

    private let model: MLModel
    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    /// One triangular filter per mel band, over the FFT bins below the Nyquist frequency.
    private let filters: [[Float]]
    /// How much of each FFT bin's power is sound: none below the lowest pitch, and, above, what the pre-emphasis did
    /// not add; and the bins below `lowSound`, and in `formants`.
    private let sound: [Float]
    private let lowBins: Int
    private let formantBins: Range<Int>

    init(model: MLModel) throws {
        guard let fft = vDSP.FFT(log2n: 9, radix: .radix2, ofType: DSPSplitComplex.self) else {
            throw TranscribeError("cannot set up the FFT for voice prints")
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
        let binWidth = Self.sampleRate / Double(Self.fftLength)
        sound = (0..<Self.fftLength / 2).map { bin in
            let frequency = binWidth * Double(bin)
            guard frequency >= Self.pitches.lowerBound else { return 0 }
            let phase = 2 * Double.pi * frequency / Self.sampleRate
            let preemphasis = Double(Self.preemphasis)
            return Float(1 / (1 - 2 * preemphasis * cos(phase) + preemphasis * preemphasis))
        }
        func bin(_ frequency: Double) -> Int { Int((frequency / binWidth).rounded(.up)) }
        lowBins = bin(Self.lowSound)
        formantBins = bin(Self.formants.lowerBound)..<bin(Self.formants.upperBound)
    }

    /// The print of this audio, at `sampleRate`, or nil if less than `minimumSpeech` of it is speech.
    func voicePrint(
        of samples: ArraySlice<Float>,
        minimumSpeech: Double = VoicePrinter.minimumSpeech
    ) throws
        -> [Float]?
    {
        var frames: [(loudness: Float, lowShare: Float, formantShare: Float, bands: [Float])] = []
        var start = samples.startIndex
        while start + Self.frameLength <= samples.endIndex {
            frames.append(analyze(samples[start..<start + Self.frameLength]))
            start += Self.hopLength
        }
        guard let loudest = frames.map(\.loudness).max() else { return nil }
        let isLoud = frames.map { $0.loudness > max(loudest - Self.speechRange, Self.silence) }
        let isVoiced = isLoud.indices.map {
            isLoud[$0] && frames[$0].lowShare >= Self.lowSoundShare && frames[$0].formantShare >= Self.formantShare
                && isPeriodic(samples, at: samples.startIndex + $0 * Self.hopLength)
        }
        var nearVoiced = [Bool](repeating: false, count: frames.count)
        for index in isVoiced.indices where isVoiced[index] {
            for near in max(0, index - Self.voicedReach)...min(frames.count - 1, index + Self.voicedReach) {
                nearVoiced[near] = true
            }
        }
        let speech = frames.indices.filter { isLoud[$0] && nearVoiced[$0] }.map { frames[$0].bands }
        guard speech.count >= max(Self.minimumFrames, Int(Double(frames.count) * minimumSpeech)) else { return nil }
        return try embed(speech)
    }

    /// Whether the audio from `start` has a pitch: it matches itself, a period later, as a voice does and noise not.
    private func isPeriodic(_ samples: ArraySlice<Float>, at start: Int) -> Bool {
        let shortest = Int(Self.sampleRate / Self.pitches.upperBound)
        let longest = Int(Self.sampleRate / Self.pitches.lowerBound)
        guard start + Self.pitchFrameLength <= samples.endIndex else { return false }
        let offset = start - samples.startIndex
        return samples.withContiguousStorageIfAvailable { samples in
            let frame = samples.baseAddress! + offset
            var best: Float = 0
            for lag in shortest...longest {
                let count = vDSP_Length(Self.pitchFrameLength - lag)
                var (product, head, tail): (Float, Float, Float) = (0, 0, 0)
                vDSP_dotpr(frame, 1, frame + lag, 1, &product, count)
                vDSP_svesq(frame, 1, &head, count)
                vDSP_svesq(frame + lag, 1, &tail, count)
                if head > 0, tail > 0 { best = max(best, product / (head * tail).squareRoot()) }
                if best >= Self.voicing { return true }
            }
            return false
        } ?? false
    }

    /// The network's print of these frames, less their mean, as it was trained on.
    private func embed(_ frames: [[Float]]) throws -> [Float] {
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
        else { throw TranscribeError("the speaker model gave no voice print") }
        let print = (0..<Self.printLength).map { embedding[$0].floatValue }
        let length = vDSP.sumOfSquares(print).squareRoot()
        guard length > 0, length.isFinite else { throw TranscribeError("the speaker model gave an empty voice print") }
        return vDSP.divide(print, length)
    }

    /// A frame's loudness, in dB below full scale, the shares of its sound below `lowSound` and in `formants`, and its
    /// log mel filterbank.
    private func analyze(_ frame: ArraySlice<Float>) -> (Float, Float, Float, [Float]) {
        let loudness = 10 * log10(vDSP.sumOfSquares(frame) / Float(frame.count) + 1e-12)
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
        let bands = filters.map { log(max(vDSP.dot($0, power), Float.ulpOfOne)) }
        let sound = vDSP.multiply(power, self.sound)
        let total = vDSP.sum(sound)
        guard total > 0 else { return (loudness, 0, 0, bands) }
        return (loudness, vDSP.sum(sound[..<lowBins]) / total, vDSP.sum(sound[formantBins]) / total, bands)
    }
}

/// Makes voice prints of audio at `VoicePrinter.sampleRate`: `VoicePrinter`, or a stand-in in the tests.
protocol VoicePrinting {
    /// The print of this audio, or nil if less than `minimumSpeech` of it is speech.
    func voicePrint(of samples: ArraySlice<Float>, minimumSpeech: Double) throws -> [Float]?
}

/// How different two voice prints sound: 1 less the cosine of the angle between them, from 0 for the same direction
/// to 2 for opposite ones: up to about 0.3 from one stretch of someone's speech to the average of theirs, 0.5 and up
/// from someone else's. An average of prints is shorter than a print, which does not change its direction. Prints that
/// are not this version's, such as ones saved by an earlier one, sound as different as can be.
func voiceDistance(_ a: [Float], _ b: [Float]) -> Float {
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
        else { throw TranscribeError("cannot tell voices apart in audio at \(sampleRate) Hz") }
        self.sourceFormat = sourceFormat
        self.format = format
        if sampleRate == VoicePrinter.sampleRate {
            converter = nil
        } else {
            guard let converter = AVAudioConverter(from: sourceFormat, to: format) else {
                throw TranscribeError("cannot tell voices apart in audio at \(sampleRate) Hz")
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
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

/// The speaker model: WeSpeaker's ResNet34-LM, trained on VoxCeleb, CC BY 4.0
/// (https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM), converted to Core ML into
/// Models/SpeakerEmbedding.mlpackage by scripts/convert-speaker-model.py. The Makefile builds the package's files into
/// transcribe, as sections of its binary, so it stays one file to install; the first time, they are written back out
/// and compiled for this Mac, into ~/Library/Caches/totalrecall, and loaded from there after.
enum SpeakerModel {
    /// The package's files and the sections they are built into, as the Makefile names them.
    static let files = [
        ("__voice_manifest", "Manifest.json"),
        ("__voice_model", "Data/com.apple.CoreML/model.mlmodel"),
        ("__voice_weights", "Data/com.apple.CoreML/weights/weight.bin"),
    ]

    /// The model built into transcribe.
    static func builtIn() throws -> MLModel {
        let contents = try files.map { section, path in (path, try self.section(section)) }
        var hash = SHA256()
        for (_, data) in contents { hash.update(data: data) }
        let name = hash.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
        let caches = try FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let compiled = caches.appending(path: "totalrecall/speaker-model-\(name).mlmodelc")
        if !FileManager.default.fileExists(atPath: compiled.path) {
            let package = FileManager.default.temporaryDirectory.appending(path: "speaker-model-\(UUID()).mlpackage")
            defer { try? FileManager.default.removeItem(at: package) }
            for (path, data) in contents {
                let url = package.appending(path: path)
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try data.write(to: url)
            }
            let temporary = try MLModel.compileModel(at: package)
            try FileManager.default.createDirectory(
                at: compiled.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // Another transcribe may have compiled it meanwhile; either one will do.
            try? FileManager.default.moveItem(at: temporary, to: compiled)
        }
        return try load(compiled: compiled)
    }

    /// A model package from a file, such as Models/SpeakerEmbedding.mlpackage for the tests.
    static func load(package: URL) throws -> MLModel {
        try load(compiled: MLModel.compileModel(at: package))
    }

    private static func load(compiled: URL) throws -> MLModel {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try MLModel(contentsOf: compiled, configuration: configuration)
    }

    private static func section(_ name: String) throws -> Data {
        var size: UInt = 0
        let header = #dsohandle.assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(header, "__TEXT", name, &size), size > 0 else {
            throw TranscribeError("this transcribe was built without its speaker model; build it with make")
        }
        return Data(bytes: bytes, count: Int(size))
    }
}
