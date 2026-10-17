import AVFoundation
import Testing

@testable import TotalRecall

struct ResamplerTests {
    @Test func convertsToTheRecordingRateAndKeepsThePitch() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let resampler = try Resampler(from: format)
        let input = sine(frequency: 1_000, count: 44_100, sampleRate: 44_100)

        let output = stride(from: 0, to: input.count, by: 441).flatMap { start in
            resampler.monoSamples(from: buffer(format: format, channels: [Array(input[start..<start + 441])]))
        }

        #expect(abs(output.count - 48_000) < 100)
        #expect(abs(risingZeroCrossings(output) - 1_000) <= 2)
    }

    @Test func mixesStereoDownToMono() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2))
        let resampler = try Resampler(from: format)
        let tone = sine(frequency: 500, count: 48_000)

        let output = stride(from: 0, to: tone.count, by: 480).flatMap { start in
            let chunk = Array(tone[start..<start + 480])
            return resampler.monoSamples(from: buffer(format: format, channels: [chunk, chunk]))
        }

        #expect(abs(output.count - 48_000) < 1_024)
        #expect(output.map(abs).max() ?? 0 > 0.3)
        #expect(abs(Double(risingZeroCrossings(output)) / Double(output.count) * sampleRate - 500) < 2)
    }

    private func buffer(format: AVAudioFormat, channels: [[Float]]) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(channels[0].count))!
        buffer.frameLength = buffer.frameCapacity
        for (index, samples) in channels.enumerated() {
            buffer.floatChannelData![index].update(from: samples, count: samples.count)
        }
        return buffer
    }

    private func risingZeroCrossings(_ samples: [Float]) -> Int {
        zip(samples, samples.dropFirst()).count { $0 < 0 && $1 >= 0 }
    }
}
