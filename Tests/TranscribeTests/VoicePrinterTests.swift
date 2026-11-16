import CoreML
import Foundation
import Shared
import Testing

@testable import Transcribe

/// The voice prints the speaker model makes, from the model in the repository, as the tests are not built with it
/// inside.
struct VoicePrinterTests {
    private static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Models/SpeakerEmbedding.mlpackage")

    /// WeSpeaker's own print of the middle 2 s of `madeUpVoice`, as `VoicePrinter` prints 3 s of audio, in whole
    /// seconds: from its Kaldi filterbank and its original ONNX model, rounded.
    private static let weSpeakersPrint: [Float] = [
        0.0494, 0.1177, -0.0196, -0.0081, -0.0025, 0.0089, 0.0364, 0.0487, 0.0224, 0.0052, 0.0708, 0.1711, -0.1419,
        -0.0014, 0.0260, 0.1064, 0.1156, -0.0212, 0.0664, 0.0747, -0.0209, -0.0907, -0.0042, 0.0603, 0.0120, 0.0087,
        -0.0909, -0.0973, 0.0334, 0.0582, 0.0108, 0.0346, 0.1115, 0.0096, 0.0202, 0.0878, -0.0237, 0.0525, -0.0399,
        0.0715, -0.0082, 0.0416, -0.0205, -0.0567, -0.0613, 0.0580, -0.0051, -0.0414, 0.0267, 0.0935, 0.0894, -0.0513,
        0.0495, 0.0167, 0.0182, 0.0323, 0.0952, 0.0489, 0.0072, -0.0128, 0.0108, -0.0515, 0.0614, -0.0444, -0.0653,
        -0.0616, -0.0834, -0.0095, 0.0618, -0.0738, -0.0156, -0.0984, 0.0599, -0.0034, 0.0855, -0.0303, -0.0281,
        -0.0728, -0.0164, 0.1144, 0.1134, -0.0112, -0.0318, -0.0097, 0.0546, -0.0336, -0.0729, -0.0096, -0.0075, 0.0646,
        -0.0758, 0.0092, -0.0017, 0.0400, 0.0152, 0.0009, -0.0204, 0.0869, 0.0163, 0.0401, 0.0505, -0.0731, -0.0431,
        -0.0182, -0.0449, 0.0730, -0.0019, -0.0364, -0.0852, -0.0477, 0.0300, -0.0601, 0.0426, 0.0201, -0.0304, -0.0556,
        -0.1393, 0.0810, -0.0046, 0.1522, 0.0054, 0.0272, 0.1415, -0.1038, -0.0718, 0.0090, -0.1602, 0.0227, -0.0072,
        -0.0251, -0.0859, 0.0261, 0.0451, -0.0745, 0.0342, 0.0733, 0.0867, 0.0234, 0.0535, -0.0547, 0.0180, -0.0342,
        0.0518, -0.0043, -0.0847, 0.0515, -0.0505, 0.0178, 0.0545, -0.0280, 0.0326, -0.0216, -0.0366, -0.0075, -0.0687,
        -0.0795, 0.1188, -0.0832, -0.0140, -0.0343, -0.0114, 0.0410, -0.0037, -0.0088, -0.0253, -0.0649, -0.0730,
        -0.0096, -0.0200, 0.0118, -0.0056, 0.0188, 0.0956, 0.0727, -0.0017, 0.0191, -0.0447, 0.0256, -0.1359, -0.0053,
        -0.1068, 0.0685, -0.0163, -0.0502, -0.1933, 0.0496, 0.0389, 0.0652, 0.0672, -0.0973, -0.0193, -0.1444, -0.0796,
        -0.0561, 0.0070, 0.0267, 0.0253, -0.0274, -0.1174, -0.0250, -0.0415, 0.1098, 0.0533, -0.0116, -0.0626, -0.0753,
        0.0261, -0.0668, 0.0593, -0.0021, 0.0421, 0.0797, 0.1161, 0.1213, -0.0848, -0.0377, 0.0477, 0.1223, -0.0498,
        -0.0594, -0.0848, 0.0031, 0.0283, 0.0449, -0.0686, -0.0802, 0.0022, -0.0469, 0.0767, -0.0382, -0.1002, 0.0196,
        -0.0659, 0.0467, 0.0619, 0.0054, -0.0810, -0.0304, -0.0476, 0.0938, -0.0236, 0.1315, 0.0158, -0.0178, -0.0005,
        -0.0393, -0.0777, 0.0181, 0.0345, 0.0038, 0.0213, -0.1055, 0.0542, 0.0890, 0.0958, 0.0183,
    ]

    @Test func printsAVoiceAsWeSpeakerItselfDoes() async throws {
        let printer = try await printer()

        let print = try printer.voicePrint(of: printer.frames(of: Self.madeUpVoice()[...]))

        #expect(print.count == VoicePrinter.printLength)
        #expect(voiceDistance(print, Self.weSpeakersPrint) < 0.001)
    }

    @Test func printsSpeechOfAnyLengthWithOneModel() async throws {
        let printer = try await printer()
        let frames = printer.frames(of: Self.madeUpVoice()[...])

        // A second's worth of frames at the least, and more than 10 s, in parts.
        for count in [1, 99, 100, 150, 298, 2_400] {
            let some = (0..<count).map { frames[$0 % frames.count] }
            #expect(try printer.voicePrint(of: some).count == VoicePrinter.printLength)
        }
    }

    @Test func makesAFrameEveryHopThatFitsWhole() async throws {
        let printer = try await printer()

        #expect(printer.frames(of: Self.madeUpVoice()[...]).count == 298)
        #expect(printer.frames(of: [Float](repeating: 0, count: 399)[...]).isEmpty)
        #expect(printer.frames(of: [Float](repeating: 0, count: 400)[...]).count == 1)
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
        #expect(throws: MessageError.self) { try VoiceResampler(sampleRate: 4_000) }
    }

    private func printer() async throws -> VoicePrinter {
        try VoicePrinter(model: await SpeakerModel.load(package: Self.package))
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
