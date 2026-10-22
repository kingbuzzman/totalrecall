import CoreML
import Foundation
import Testing

@testable import Transcribe

/// The voice prints the speaker model makes, from the model in the repository, as the tests are not built with it
/// inside.
struct VoicePrinterTests {
    /// Core ML models can predict from any thread.
    nonisolated(unsafe) private static let model = try! SpeakerModel.load(
        package: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Models/SpeakerEmbedding.mlpackage")
    )

    /// WeSpeaker's own print of `madeUpVoice`, from its Kaldi filterbank and its original ONNX model, rounded.
    private static let weSpeakersPrint: [Float] = [
        0.0515, 0.1081, -0.0269, -0.0479, 0.0027, -0.0089, 0.0363, 0.0505, 0.0147, 0.0143, 0.0665, 0.1878, -0.1293,
        -0.0075, 0.0297, 0.1008, 0.1084, -0.0126, 0.0679, 0.0807, -0.0136, -0.0959, 0.0210, 0.0452, 0.0225, 0.0415,
        -0.0912, -0.1078, 0.0306, 0.0566, 0.0266, 0.0327, 0.1011, 0.0021, 0.0233, 0.0908, -0.0183, 0.0342, -0.0562,
        0.0671, -0.0206, 0.0425, -0.0207, -0.0527, -0.0715, 0.0715, 0.0046, -0.0346, 0.0282, 0.1007, 0.0740, -0.0557,
        0.0781, 0.0197, 0.0014, 0.0355, 0.0814, 0.0445, -0.0060, -0.0087, 0.0173, -0.0231, 0.0526, -0.0441, -0.0576,
        -0.0385, -0.0738, -0.0131, 0.0625, -0.0486, -0.0181, -0.1020, 0.0738, -0.0094, 0.0829, -0.0163, -0.0132,
        -0.0828, -0.0097, 0.0985, 0.1087, -0.0062, -0.0285, -0.0313, 0.0566, -0.0597, -0.0792, -0.0007, -0.0172, 0.0501,
        -0.0751, 0.0111, 0.0017, 0.0485, 0.0140, 0.0036, -0.0168, 0.0930, 0.0086, 0.0236, 0.0449, -0.0968, -0.0219,
        -0.0277, -0.0381, 0.0581, -0.0113, -0.0342, -0.0899, -0.0261, 0.0173, -0.0628, 0.0544, 0.0272, -0.0426, -0.0421,
        -0.1280, 0.0673, -0.0119, 0.1416, 0.0164, 0.0282, 0.1191, -0.1209, -0.0646, 0.0243, -0.1569, 0.0354, -0.0201,
        -0.0321, -0.0941, 0.0258, 0.0398, -0.0856, 0.0340, 0.0678, 0.0588, 0.0208, 0.0142, -0.0588, 0.0140, -0.0515,
        0.0619, 0.0109, -0.1016, 0.0430, -0.0493, 0.0024, 0.0624, -0.0285, 0.0300, -0.0105, -0.0533, -0.0061, -0.0856,
        -0.0614, 0.1134, -0.0738, 0.0009, -0.0231, -0.0052, 0.0527, 0.0029, -0.0027, -0.0164, -0.0687, -0.0619, 0.0093,
        -0.0114, 0.0135, -0.0015, 0.0364, 0.0969, 0.0818, -0.0067, -0.0109, -0.0638, 0.0334, -0.1362, -0.0025, -0.1226,
        0.0526, -0.0423, -0.0613, -0.1881, 0.0356, 0.0453, 0.0679, 0.0383, -0.0928, -0.0263, -0.1458, -0.0574, -0.0771,
        0.0192, 0.0303, 0.0300, -0.0209, -0.0909, -0.0228, -0.0471, 0.1043, 0.0388, 0.0051, -0.0571, -0.0692, 0.0119,
        -0.0617, 0.0855, 0.0270, 0.0402, 0.0804, 0.1336, 0.1080, -0.0871, -0.0217, 0.0507, 0.1163, -0.0624, -0.0686,
        -0.0811, 0.0177, 0.0241, 0.0408, -0.0612, -0.0714, -0.0039, -0.0485, 0.0797, -0.0561, -0.0896, 0.0336, -0.0362,
        0.0416, 0.0965, 0.0041, -0.0870, -0.0378, -0.0526, 0.0751, -0.0483, 0.1458, 0.0249, -0.0146, -0.0097, -0.0219,
        -0.0700, 0.0366, 0.0272, -0.0038, 0.0091, -0.1302, 0.0572, 0.0971, 0.1212, 0.0155,
    ]

    @Test func printsAVoiceAsWeSpeakerItselfDoes() throws {
        let print = try #require(try VoicePrinter(model: Self.model).voicePrint(of: Self.madeUpVoice()[...]))

        #expect(print.count == VoicePrinter.printLength)
        #expect(voiceDistance(print, Self.weSpeakersPrint) < 0.001)
    }

    @Test func printsNothingOfAudioWithTooLittleSpeech() throws {
        let printer = try VoicePrinter(model: Self.model)
        let silence = [Float](repeating: 0, count: 48_000)
        let briefly = Array(Self.madeUpVoice().prefix(8_000)) + [Float](repeating: 0, count: 40_000)

        #expect(try printer.voicePrint(of: silence[...]) == nil)
        #expect(try printer.voicePrint(of: briefly[...]) == nil)
        #expect(try printer.voicePrint(of: [Float](repeating: 0.1, count: 100)[...]) == nil)
    }

    @Test func measuresHowFarApartTwoPrintsPoint() {
        var (first, second) = ([Float](repeating: 0, count: 256), [Float](repeating: 0, count: 256))
        first[0] = 1
        second[1] = 1

        #expect(voiceDistance(first, first) == 0)
        #expect(voiceDistance(first, second) == 1)
        #expect(voiceDistance(first, first.map { -$0 }) == 2)
        #expect(voiceDistance(first, first.map { $0 / 2 }) == 0)
        #expect(voiceDistance(first, [1, 0, 0]) == .infinity)
        #expect(voiceDistance(first, [Float](repeating: 0, count: 256)) == .infinity)
    }

    @Test func resamplesToTheRateItPrintsAt() throws {
        let second = [Float](repeating: 0.1, count: 48_000)

        let resampled = try VoiceResampler(sampleRate: 48_000).resample(second)

        #expect(abs(resampled.count - 16_000) < 200)
        #expect(try VoiceResampler(sampleRate: 16_000).resample(second) == second)
        #expect(throws: TranscribeError.self) { try VoiceResampler(sampleRate: 4_000) }
    }

    /// 3 s at 16 kHz of 8 harmonics of 150 Hz, rising and falling 3 times a second, as scripts made `weSpeakersPrint`
    /// from.
    private static func madeUpVoice() -> [Float] {
        (0..<48_000).map { index in
            let time = Double(index) / 16_000
            let buzz = (1...8).map { sin(2 * Double.pi * Double($0) * 150 * time + Double($0)) / Double($0) }
            return Float(buzz.reduce(0, +) * (0.6 + 0.4 * sin(2 * Double.pi * 3 * time)) * 0.1)
        }
    }
}
