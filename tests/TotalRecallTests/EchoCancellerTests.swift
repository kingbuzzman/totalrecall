import Testing

@testable import TotalRecall

struct EchoCancellerTests {
    private static let length = Int(sampleRate * 8) / EchoCanceller.frameSize * EchoCanceller.frameSize
    private static let echoDelay = frameCount(milliseconds: 60)

    @Test func removesTheSpeakersFromTheMicrophone() {
        var noise = Noise(seed: 1)
        let speaker = noise.samples(Self.length, amplitude: 0.3)
        let microphone = silence(Self.echoDelay) + speaker.dropLast(Self.echoDelay).map { $0 / 4 }

        let cleaned = EchoCanceller().cancel(microphone: microphone, speaker: speaker)

        let settled = Self.length / 2
        #expect(cleaned.count == microphone.count)
        #expect(rmsDecibels(microphone[settled...]) - rmsDecibels(cleaned[settled...]) > 20)
    }

    @Test func outputsSilenceUntilTheMicrophoneFirstMakesASound() {
        let frame = EchoCanceller.frameSize
        var noise = Noise(seed: 2)
        let microphone = silence(2 * frame) + noise.samples(2 * frame, amplitude: 0.1)

        let cleaned = EchoCanceller().cancel(microphone: microphone, speaker: silence(4 * frame))

        #expect(cleaned.prefix(2 * frame).allSatisfy { $0 == 0 })
        #expect(cleaned.suffix(2 * frame).contains { $0 != 0 })
    }

    @Test func warmsUpOnThePreRoll() {
        var noise = Noise(seed: 3)
        let speaker = noise.samples(Self.length, amplitude: 0.3)
        let microphone = silence(Self.echoDelay) + speaker.dropLast(Self.echoDelay).map { $0 / 4 }
        let half = Self.length / 2 / EchoCanceller.frameSize * EchoCanceller.frameSize

        let warmed = EchoCanceller()
        warmed.warmUp(microphone: Array(microphone[..<half]), speaker: Array(speaker[..<half]))
        let cleaned = warmed.cancel(microphone: Array(microphone[half...]), speaker: Array(speaker[half...]))

        let firstSecond = Int(sampleRate)
        #expect(rmsDecibels(microphone[half...].prefix(firstSecond)) - rmsDecibels(cleaned.prefix(firstSecond)) > 20)
    }

    @Test func warmingUpOnSilenceChangesNothing() {
        let frame = EchoCanceller.frameSize
        let canceller = EchoCanceller()

        canceller.warmUp(microphone: silence(4 * frame), speaker: silence(4 * frame))

        #expect(canceller.cancel(microphone: silence(frame), speaker: silence(frame)) == silence(frame))
    }
}
