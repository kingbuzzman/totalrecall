import AVFoundation
import Foundation

struct LevelSnapshot {
    let microphonePeak: Float
    let systemPeak: Float
    let systemHasHeardSound: Bool
}

/// Writes the microphone (left) and system audio (right), or their mix on both channels, to a 16-bit PCM CAF,
/// which stays readable if the process dies.
///
/// The append methods are called from audio callbacks; everything else runs on the writer queue.
final class Recorder {
    enum Input {
        case microphone
        case system
    }

    /// How long to wait for both tracks to start before writing anyway.
    private static let startupGraceSeconds = 2.0
    /// When one track is this far ahead of the other, the other is padded with silence so writing continues.
    private static let maxLagFrames = Int(sampleRate * 1.0)
    /// Most silence inserted at the start of the later track to align the two.
    private static let maxStartOffsetFrames = Int(sampleRate * 5.0)

    let includesMicrophone: Bool
    let isolatesSpeakers: Bool
    private(set) var framesWritten: AVAudioFramePosition = 0
    private let echoCanceller: EchoCanceller?
    private let lock = NSLock()
    private let microphone = Track()
    private let system = Track()
    private let startedAt = Date()
    private var isAligned = false
    private var file: AVAudioFile?

    init(writingTo url: URL, includesMicrophone: Bool, isolatesSpeakers: Bool, cancelsEcho: Bool) throws {
        self.includesMicrophone = includesMicrophone
        self.isolatesSpeakers = isolatesSpeakers
        echoCanceller = includesMicrophone && cancelsEcho ? EchoCanceller() : nil
        file = try AVAudioFile(
            forWriting: url,
            settings: pcmSettings(bigEndian: false),
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
    }

    func appendMicrophone(_ samples: [Float], hostTime: UInt64, session: Int) {
        lock.withLock { microphone.append(samples, hostTime: hostTime, source: session) }
    }

    func appendSystem(_ samples: [Float], hostTime: UInt64) {
        lock.withLock { system.append(samples, hostTime: hostTime) }
    }

    /// Gives a freshly restarted capture the full stall window to deliver its first buffer.
    func resetStallTimer(for input: Input) {
        lock.withLock { track(input).resetStallTimer() }
    }

    func secondsSinceAudio(from input: Input) -> Double {
        lock.withLock { track(input).secondsSinceLastBuffer }
    }

    /// Peaks since the previous call.
    func levels() -> LevelSnapshot {
        lock.withLock {
            LevelSnapshot(
                microphonePeak: microphone.takePeak(),
                systemPeak: system.takePeak(),
                systemHasHeardSound: system.hasHeardSound
            )
        }
    }

    /// Writes the audio that both tracks have; with `final`, writes everything, padding the shorter track.
    func writeAvailable(final: Bool = false) throws {
        let (microphoneSamples, systemSamples) = lock.withLock { takeTracks(final: final) }
        guard !systemSamples.isEmpty, let file else { return }
        let (left, right) = channels(microphone: microphoneSamples, system: systemSamples)
        let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(left.count))!
        buffer.frameLength = AVAudioFrameCount(left.count)
        buffer.floatChannelData![0].update(from: left, count: left.count)
        buffer.floatChannelData![1].update(from: right, count: right.count)
        try file.write(from: buffer)
        framesWritten += AVAudioFramePosition(left.count)
    }

    /// Writes the remaining audio and closes the file, even when that last write fails.
    func close() throws {
        defer {
            file?.close()
            file = nil
        }
        try writeAvailable(final: true)
    }

    private func track(_ input: Input) -> Track {
        switch input {
        case .microphone: microphone
        case .system: system
        }
    }

    private func channels(microphone microphoneSamples: [Float], system systemSamples: [Float]) -> ([Float], [Float]) {
        guard includesMicrophone else { return (systemSamples, systemSamples) }
        let cleanedMicrophone =
            echoCanceller?.cancel(microphone: microphoneSamples, speaker: systemSamples)
            ?? microphoneSamples
        guard isolatesSpeakers else {
            let mixed = zip(cleanedMicrophone, systemSamples).map { min(max($0 + $1, -1), 1) }
            return (mixed, mixed)
        }
        return (cleanedMicrophone, systemSamples)
    }

    /// Takes equal-length, time-aligned microphone and system samples; whole echo-canceller frames while recording.
    private func takeTracks(final: Bool) -> ([Float], [Float]) {
        guard includesMicrophone else { return ([], system.takeAll()) }
        if !isAligned {
            let bothStarted = microphone.startHostTime != nil && system.startHostTime != nil
            let gaveUpWaiting = Date().timeIntervalSince(startedAt) > Self.startupGraceSeconds
            guard bothStarted || final || gaveUpWaiting else { return ([], []) }
            alignStarts()
            isAligned = true
        }
        if final || abs(microphone.count - system.count) > Self.maxLagFrames {
            let longest = max(microphone.count, system.count)
            let frameSize = EchoCanceller.frameSize
            let paddedLength = final ? (longest + frameSize - 1) / frameSize * frameSize : longest
            microphone.padWithSilence(toCount: paddedLength)
            system.padWithSilence(toCount: paddedLength)
        }
        let available = min(microphone.count, system.count)
        let count = available - available % EchoCanceller.frameSize
        return (microphone.take(count), system.take(count))
    }

    private func alignStarts() {
        guard let microphoneStart = microphone.startHostTime, let systemStart = system.startHostTime else { return }
        let offsetNanos =
            AudioConvertHostTimeToNanos(max(microphoneStart, systemStart))
            - AudioConvertHostTimeToNanos(min(microphoneStart, systemStart))
        let offsetFrames = min(Int(frames(inNanoseconds: Double(offsetNanos))), Self.maxStartOffsetFrames)
        let laterTrack = microphoneStart > systemStart ? microphone : system
        laterTrack.delayStart(by: offsetFrames)
    }
}
