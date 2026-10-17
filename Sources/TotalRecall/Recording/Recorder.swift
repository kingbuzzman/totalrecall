import AVFoundation
import Accelerate
import Foundation

struct LevelSnapshot {
    let microphonePeak: Float
    let systemPeak: Float
}

/// Writes the microphone (left) and system audio (right), or their mix on both channels, to its sink: a crash-safe
/// file or a live stream.
///
/// The recording covers exactly the span from `startRecording()` to `stopRecording()`, the moments the user is told
/// it started and asks it to stop. The captures start earlier: the ambient sound they deliver before the recording
/// starts is the echo canceller's baseline, and is not written.
///
/// With a `rawSink`, the unprocessed microphone (left) and system audio (right), pre-roll included, are also written
/// there, for tuning the processing against real recordings.
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
    /// Most silence inserted at the start of a track to align it with the other one or with the recording's start.
    private static let maxStartOffsetFrames = Int(sampleRate * 5.0)

    let includesMicrophone: Bool
    let isolatesSpeakers: Bool
    private let echoCanceller: EchoCanceller?
    private let lock = UnfairLock()
    private let microphone = Track()
    private let system = Track()
    private let startedAt = Date()
    private var recordingStart: UInt64?
    private var recordingEnd: UInt64?
    private var systemHasDelivered = false
    /// Host time of the microphone's first buffer with sound in it.
    private var microphoneSoundStart: UInt64?
    /// Frames taken from the tracks for the file so far, which is the file's timeline position.
    private var framesTaken = 0
    private var isAligned = false
    private let sink: any AudioSink
    private let rawSink: (any AudioSink)?
    private var isClosed = false
    /// Raw audio taken off the tracks under the lock, written by `writeAvailable()` outside it.
    private var pendingRaw: [(microphone: [Float], system: [Float])] = []
    /// The pre-roll taken off the tracks under the lock, which `writeAvailable()` warms the echo canceller up on
    /// outside it: that runs the canceller over seconds of audio, which the audio callbacks must not wait for.
    private var pendingWarmUp: (microphone: [Float], speaker: [Float])?

    init(
        writingTo sink: any AudioSink,
        rawSink: (any AudioSink)? = nil,
        includesMicrophone: Bool,
        isolatesSpeakers: Bool,
        cancelsEcho: Bool
    ) {
        self.sink = sink
        self.rawSink = rawSink
        self.includesMicrophone = includesMicrophone
        self.isolatesSpeakers = isolatesSpeakers
        echoCanceller = includesMicrophone && cancelsEcho ? EchoCanceller() : nil
    }

    /// Whether the recording can start: the captures deliver audio (the microphone actual sound, which it may not for
    /// a while after it starts: AirPods deliver silence for a second or two while they switch Bluetooth into their call
    /// profile), and the microphone has delivered the echo canceller's baseline of ambient sound.
    var isReadyToRecord: Bool {
        lock.withLock {
            guard systemHasDelivered else { return false }
            guard includesMicrophone else { return true }
            guard let microphoneSoundStart else { return false }
            guard echoCanceller != nil else { return true }
            let soundNanos =
                AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
                - AudioConvertHostTimeToNanos(microphoneSoundStart)
            return Double(soundNanos) / 1e9 >= EchoCanceller.baselineSeconds
        }
    }

    /// Starts the recording at the moment the user is told it started.
    func startRecording(at hostTime: UInt64 = AudioGetCurrentHostTime()) {
        lock.withLock {
            recordingStart = hostTime
            // The level meter starts with the recording.
            _ = microphone.takePeak()
            _ = system.takePeak()
        }
    }

    /// Ends the recording at the moment the user asks it to stop; `close()` then ends the file exactly there.
    func stopRecording(at hostTime: UInt64 = AudioGetCurrentHostTime()) {
        lock.withLock { recordingEnd = max(hostTime, recordingStart ?? hostTime) }
    }

    /// Seconds from `startRecording()` to now, or to `stopRecording()`: the length of the file.
    var secondsRecorded: Double {
        lock.withLock {
            guard let recordingStart else { return 0 }
            let end = max(recordingEnd ?? AudioGetCurrentHostTime(), recordingStart)
            return Double(AudioConvertHostTimeToNanos(end) - AudioConvertHostTimeToNanos(recordingStart)) / 1e9
        }
    }

    func appendMicrophone(_ samples: [Float], hostTime: UInt64, session: Int) {
        lock.withLock {
            if microphoneSoundStart == nil, samples.contains(where: { $0 != 0 }) { microphoneSoundStart = hostTime }
            guard let kept = beforeRecordingEnd(samples, hostTime: hostTime, track: microphone) else { return }
            microphone.append(kept, hostTime: hostTime, source: session)
        }
    }

    func appendSystem(_ samples: [Float], hostTime: UInt64) {
        lock.withLock {
            systemHasDelivered = true
            guard let kept = beforeRecordingEnd(samples, hostTime: hostTime, track: system) else { return }
            system.append(kept, hostTime: hostTime)
        }
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
                systemPeak: system.takePeak()
            )
        }
    }

    /// Writes the audio that both tracks have; with `final`, writes everything up to the end of the recording.
    func writeAvailable(final: Bool = false) throws {
        guard !isClosed else { return }
        let (microphoneSamples, systemSamples, frameCount, raw, warmUp) = lock.withLock {
            let taken = takeTracks(final: final)
            if rawSink != nil, taken.frameCount > 0 {
                pendingRaw.append(
                    (Array(taken.microphone.prefix(taken.frameCount)), Array(taken.system.prefix(taken.frameCount)))
                )
            }
            defer {
                pendingRaw.removeAll()
                pendingWarmUp = nil
            }
            return (taken.microphone, taken.system, taken.frameCount, pendingRaw, pendingWarmUp)
        }
        if let warmUp { echoCanceller?.warmUp(microphone: warmUp.microphone, speaker: warmUp.speaker) }
        if let rawSink {
            for (microphone, system) in raw {
                try rawSink.write(left: microphone, right: system, count: system.count)
            }
        }
        guard frameCount > 0 else { return }
        let (left, right) = channels(microphone: microphoneSamples, system: systemSamples)
        try sink.write(left: left, right: right, count: frameCount)
    }

    /// Writes the remaining audio up to `stopRecording()` and closes the sinks, even when that last write fails.
    func close() throws {
        defer {
            isClosed = true
            sink.close()
            rawSink?.close()
        }
        try writeAvailable(final: true)
    }

    /// The part of a buffer before `stopRecording()`, or nil when none of it is.
    private func beforeRecordingEnd(_ samples: [Float], hostTime: UInt64, track: Track) -> [Float]? {
        guard let recordingEnd else { return samples }
        let endOffset = frames(
            inNanoseconds: Double(AudioConvertHostTimeToNanos(recordingEnd))
                - Double(AudioConvertHostTimeToNanos(hostTime))
        )
        let end = min(samples.count, Int(endOffset.rounded(.down)))
        guard end > 0 else {
            // The capture is alive, even though its audio is from after the recording.
            track.resetStallTimer()
            return nil
        }
        return end == samples.count ? samples : Array(samples[..<end])
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
            let mixed = vDSP.clip(vDSP.add(cleanedMicrophone, systemSamples), to: -1...1)
            return (mixed, mixed)
        }
        return (cleanedMicrophone, systemSamples)
    }

    /// The tracks that go into the file.
    private var recordedTracks: [Track] {
        includesMicrophone ? [microphone, system] : [system]
    }

    /// Takes equal-length, time-aligned microphone and system samples (whole echo-canceller frames, possibly padded
    /// past the end on the final call) and how many of those frames to write.
    private func takeTracks(final: Bool) -> (microphone: [Float], system: [Float], frameCount: Int) {
        guard recordingStart != nil else { return ([], [], 0) }
        if !isAligned {
            let allStarted = recordedTracks.allSatisfy { $0.startHostTime != nil }
            let gaveUpWaiting = Date().timeIntervalSince(startedAt) > Self.startupGraceSeconds
            guard allStarted || final || gaveUpWaiting else { return ([], [], 0) }
            alignTracks()
            isAligned = true
        }
        if final { endAtRecordingEnd() }
        guard includesMicrophone else {
            let systemSamples = system.takeAll()
            framesTaken += systemSamples.count
            return ([], systemSamples, systemSamples.count)
        }
        var frameCount: Int?
        if final {
            frameCount = system.count
            let frameSize = EchoCanceller.frameSize
            let paddedLength = (system.count + frameSize - 1) / frameSize * frameSize
            microphone.padWithSilence(toCount: paddedLength)
            system.padWithSilence(toCount: paddedLength)
        } else if abs(microphone.count - system.count) > Self.maxLagFrames {
            let longest = max(microphone.count, system.count)
            microphone.padWithSilence(toCount: longest)
            system.padWithSilence(toCount: longest)
        }
        let available = min(microphone.count, system.count)
        let count = available - available % EchoCanceller.frameSize
        let written = frameCount ?? count
        framesTaken += written
        return (microphone.take(count), system.take(count), written)
    }

    /// Lines the tracks up from the first one's first buffer, then makes them start at `startRecording()`: audio from
    /// before it (the pre-roll) warms the echo canceller up and is taken off; a track that started after it gets leading
    /// silence.
    private func alignTracks() {
        guard let recordingStart else { return }
        let starts = recordedTracks.compactMap(\.startHostTime).map(AudioConvertHostTimeToNanos)
        guard let firstStart = starts.min() else { return }
        for track in recordedTracks {
            guard let trackStart = track.startHostTime else { continue }
            let offsetNanos = AudioConvertHostTimeToNanos(trackStart) - firstStart
            track.delayStart(by: min(Int(frames(inNanoseconds: Double(offsetNanos))), Self.maxStartOffsetFrames))
        }
        let recordingStartNanos = AudioConvertHostTimeToNanos(recordingStart)
        guard recordingStartNanos >= firstStart else {
            let lateFrames = Int(frames(inNanoseconds: Double(firstStart - recordingStartNanos)))
            recordedTracks.forEach { $0.delayStart(by: min(lateFrames, Self.maxStartOffsetFrames)) }
            return
        }
        let preRollFrames = Int(frames(inNanoseconds: Double(recordingStartNanos - firstStart)))
        let preRoll = recordedTracks.map { track in
            track.padWithSilence(toCount: preRollFrames)
            return track.take(preRollFrames)
        }
        if rawSink != nil {
            pendingRaw.append(includesMicrophone ? (preRoll[0], preRoll[1]) : ([], preRoll[0]))
        }
        if includesMicrophone, echoCanceller != nil { pendingWarmUp = (preRoll[0], preRoll[1]) }
    }

    /// Pads or cuts the tracks so the file ends exactly at `stopRecording()`.
    private func endAtRecordingEnd() {
        guard let recordingStart, let recordingEnd else { return }
        let nanos = AudioConvertHostTimeToNanos(recordingEnd) - AudioConvertHostTimeToNanos(recordingStart)
        let remaining = max(Int(frames(inNanoseconds: Double(nanos))) - framesTaken, 0)
        for track in recordedTracks {
            track.padWithSilence(toCount: remaining)
            track.truncate(toCount: remaining)
        }
    }
}
