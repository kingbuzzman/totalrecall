import AVFoundation
import AudioLab
import Foundation
import Testing

@testable import Transcribe

/// Who talks when, by the segmentation model in the repository, as the tests are not built with it inside.
struct SegmenterTests {
    private static let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appending(path: "Models/SpeakerSegmentation.mlpackage")
    private static let rate = VoicePrinter.sampleRate

    @Test func findsOnePersonTalkingInSpeechAndNobodyAroundIt() async throws {
        let speech = try await Self.speech("The quarterly numbers are in, and they look better than we expected.")
        let silence = [Float](repeating: 0, count: 32_000)
        let window = Self.window(silence + speech)

        let frames = try await segmenter().segment(window[...])

        let speaking = (32_000..<32_000 + speech.count)
        let during = frames.indices.filter { speaking.contains($0 * Segmenter.frameStep + Segmenter.frameCenter) }
        let before = frames.indices.filter { ($0 * Segmenter.frameStep + Segmenter.frameCenter) < 24_000 }
        #expect(frames.count == Segmenter.frameCount)
        #expect(Double(during.count(where: { frames[$0].count == 1 })) > Double(during.count) * 0.6)
        #expect(Set(during.compactMap { frames[$0].count == 1 ? frames[$0] : nil }).count == 1)
        #expect(before.allSatisfy { frames[$0].isEmpty })
    }

    @Test func findsNobodyTalkingInANotificationsPing() async throws {
        let pings = (0..<Segmenter.windowLength).map { index in
            let time = Double(index % 16_000) / 16_000
            let chime = [(2_100.0, 1.0), (4_200, 0.3), (5_800, 0.5)].map { sin(2 * Double.pi * $0 * time) * $1 }
            return Float(chime.reduce(0, +) * exp(-time) * 0.1)
        }

        let frames = try await segmenter().segment(pings[...])

        #expect(Double(frames.count(where: { !$0.isEmpty })) < Double(frames.count) * 0.05)
    }

    @Test func findsNobodyTalkingInAHum() async throws {
        let hum = (0..<Segmenter.windowLength).map { index in
            let time = Double(index) / 16_000
            return Float((sin(2 * Double.pi * 100 * time) + sin(2 * Double.pi * 200 * time) / 4) * 0.01)
        }

        let frames = try await segmenter().segment(hum[...])

        #expect(Double(frames.count(where: { !$0.isEmpty })) < Double(frames.count) * 0.05)
    }

    @Test func centersEachFrameWhereItHears() {
        #expect(Segmenter.time(ofFrame: 0) == 495 / Self.rate)
        #expect(abs(Segmenter.time(ofFrame: Segmenter.frameCount - 1) - 9.95) < 0.01)
    }

    private func segmenter() async throws -> Segmenter {
        try Segmenter(model: await SpeakerModel.load(package: Self.package))
    }

    /// `text` in the system voice, at `VoicePrinter.sampleRate`.
    private static func speech(_ text: String) async throws -> [Float] {
        try VoiceResampler(sampleRate: 48_000).resample(try await SystemVoice.samples(saying: text))
    }

    /// The audio, cut or padded with silence to a window.
    private static func window(_ audio: [Float]) -> [Float] {
        Array((audio + [Float](repeating: 0, count: Segmenter.windowLength)).prefix(Segmenter.windowLength))
    }
}
