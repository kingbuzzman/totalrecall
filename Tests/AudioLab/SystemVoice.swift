import AVFoundation
import os

/// Speech in the system voice, made in-process by AVSpeechSynthesizer, for the tests that transcribe.
package enum SystemVoice {
    /// `text` in the system voice, as mono samples at 48 kHz.
    package static func samples(saying text: String) async throws -> [Float] {
        // Read only by the converter below, which the macOS 26 SDK marks @Sendable; the macOS 27 SDK does not.
        nonisolated(unsafe) let voice = try await synthesize(text)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let ratio = format.sampleRate / voice.format.sampleRate
        let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(Double(voice.frameLength) * ratio) + 1
        )!
        nonisolated(unsafe) var fed = false  // only touched by the converter, which calls this block in turn
        var error: NSError?
        AVAudioConverter(from: voice.format, to: format)!.convert(to: output, error: &error) { _, status in
            status.pointee = fed ? .endOfStream : .haveData
            defer { fed = true }
            return fed ? nil : voice
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// The speech in the voice's own format, made in-process by AVSpeechSynthesizer. Speech still unfinished after 30 s
    /// is hung: the test fails, rather than the whole run stalling until CI gives up.
    private static func synthesize(_ text: String) async throws -> AVAudioPCMBuffer {
        let synthesizer = AVSpeechSynthesizer()
        defer { synthesizer.stopSpeaking(at: .immediate) }
        let pending = OSAllocatedUnfairLock<CheckedContinuation<AVAudioPCMBuffer, any Error>?>(initialState: nil)
        nonisolated(unsafe) var samples: [Float] = []  // only touched by the synthesizer's callback
        return try await withCheckedThrowingContinuation { continuation in
            pending.withLock { $0 = continuation }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                pending.withLock { $0.take() }?.resume(throwing: SpeechError(description: "speech synthesis hung"))
            }
            synthesizer.write(AVSpeechUtterance(string: text)) { buffer in
                guard let buffer = buffer as? AVAudioPCMBuffer, let channel = buffer.floatChannelData?[0] else {
                    return
                }
                // Copied as they come, as the synthesizer may reuse its buffers; an empty one ends the speech.
                guard buffer.frameLength == 0 else {
                    return samples += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
                }
                let speech = AVAudioPCMBuffer(
                    pcmFormat: buffer.format,
                    frameCapacity: AVAudioFrameCount(samples.count)
                )!
                speech.frameLength = speech.frameCapacity
                speech.floatChannelData![0].update(from: samples, count: samples.count)
                pending.withLock { $0.take() }?.resume(returning: speech)
            }
        }
    }
}

package struct SpeechError: Error, CustomStringConvertible {
    package let description: String
}
