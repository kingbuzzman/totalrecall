import Accelerate
import CSpeexDSP

/// Removes the system audio that the microphone picks up from the speakers, using the captured system audio as the
/// echo reference (speexdsp acoustic echo canceller plus residual echo and noise suppression).
final class EchoCanceller {
    // Speex needs a power-of-two frame: with 480 (10 ms) its filter diverges and resets every few seconds, cancelling
    // almost nothing; 1024 (21 ms) converges within about 3 s.
    static let frameSize = 1024
    private static let echoTailSeconds = 0.12
    /// Ambient sound captured before the recording starts, which the noise suppressor learns the background from.
    static let baselineSeconds = 1.0
    private static let baselineFrames = Int(sampleRate * baselineSeconds) / frameSize * frameSize
    /// Speex's noise suppressor needs about 2 s of a microphone's background hiss to learn it, and lets the hiss through
    /// until then; without a warm-up, every recording starts with hiss that fades out over those seconds.
    private static let warmUpFrames = Int(sampleRate * 2.0) / frameSize

    private let echoState: OpaquePointer
    private let preprocessState: OpaquePointer
    private var microphoneFrame = [Int16](repeating: 0, count: frameSize)
    private var speakerFrame = [Int16](repeating: 0, count: frameSize)
    private var cleanedFrame = [Int16](repeating: 0, count: frameSize)
    /// Scratch space for converting a frame to 16-bit.
    private var scaledFrame = [Float](repeating: 0, count: frameSize)
    private var hasHeardMicrophone = false

    init() {
        echoState = Self.makeEchoState()
        preprocessState = speex_preprocess_state_init(Int32(Self.frameSize), Int32(sampleRate))
        attachEchoState(echoState)
    }

    deinit {
        speex_preprocess_state_destroy(preprocessState)
        speex_echo_state_destroy(echoState)
    }

    /// Adapts to the audio captured before the recording starts (the pre-roll), discarding the output, so the recording
    /// starts with both stages settled:
    ///
    /// 1. The noise suppressor learns the background from the last `baselineSeconds`, ambient sound captured while the
    ///    user waits to be told the recording started (so it should hold no speech). It processes their audible frames,
    ///    repeated as needed, through a throwaway echo canceller: the real one must see every frame exactly once and in
    ///    order, as repeated or skipped frames can lock its filter onto the wrong delay.
    /// 2. Both stages then process the whole pre-roll once, in order, so the real echo canceller has been adapting
    ///    since the captures started and the pre-roll flows straight into the recording.
    ///
    /// Both inputs must be the same length and aligned in time, and end where the recording starts.
    func warmUp(microphone: [Float], speaker: [Float]) {
        let wholeFrames = microphone.count / Self.frameSize * Self.frameSize
        let microphone = Array(microphone.suffix(wholeFrames))
        let speaker = Array(speaker.suffix(wholeFrames))
        warmUpNoiseSuppressor(
            microphone: Array(microphone.suffix(Self.baselineFrames)),
            speaker: Array(speaker.suffix(Self.baselineFrames))
        )
        _ = cancel(microphone: microphone, speaker: speaker)
    }

    private func warmUpNoiseSuppressor(microphone: [Float], speaker: [Float]) {
        let frameStarts = stride(from: 0, to: microphone.count - Self.frameSize + 1, by: Self.frameSize)
            .filter { !isSilent(microphone, frameAt: $0) }
        guard !frameStarts.isEmpty else { return }
        let warmUpEchoState = Self.makeEchoState()
        attachEchoState(warmUpEchoState)
        defer {
            attachEchoState(echoState)
            speex_echo_state_destroy(warmUpEchoState)
        }
        for index in 0..<Self.warmUpFrames {
            cancelEcho(microphone, speaker, frameAt: frameStarts[index % frameStarts.count], using: warmUpEchoState)
            speex_preprocess_run(preprocessState, &cleanedFrame)
        }
    }

    /// Both inputs must be the same length, a multiple of `frameSize`, and aligned in time.
    func cancel(microphone: [Float], speaker: [Float]) -> [Float] {
        var cleaned = [Float](repeating: 0, count: microphone.count)
        for frameStart in stride(from: 0, to: microphone.count, by: Self.frameSize) {
            cancelEcho(microphone, speaker, frameAt: frameStart, using: echoState)
            // Silence before the microphone's first sound (a microphone that started after the recording) skips the
            // noise suppressor, which would learn that the background is silent and undo the warm-up. That frame of
            // `cleaned` stays silent.
            if !hasHeardMicrophone && isSilent(microphone, frameAt: frameStart) { continue }
            hasHeardMicrophone = true
            speex_preprocess_run(preprocessState, &cleanedFrame)
            // A plain loop rather than vDSP_vsdiv, which is not correctly rounded; the compiler vectorizes it.
            cleaned.withUnsafeMutableBufferPointer { cleaned in
                for offset in 0..<Self.frameSize {
                    cleaned[frameStart + offset] = Float(cleanedFrame[offset]) / Float(Int16.max)
                }
            }
        }
        return cleaned
    }

    /// Removes the speaker signal's echo from one microphone frame, leaving the result in `cleanedFrame`.
    private func cancelEcho(
        _ microphone: [Float],
        _ speaker: [Float],
        frameAt frameStart: Int,
        using state: OpaquePointer
    ) {
        pcm16(microphone, frameAt: frameStart, into: &microphoneFrame)
        pcm16(speaker, frameAt: frameStart, into: &speakerFrame)
        speex_echo_cancellation(state, microphoneFrame, speakerFrame, &cleanedFrame)
    }

    /// The noise suppressor also removes the residual echo that this echo canceller reports.
    private func attachEchoState(_ state: OpaquePointer) {
        speex_preprocess_ctl(preprocessState, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(state))
    }

    private static func makeEchoState() -> OpaquePointer {
        let state: OpaquePointer = speex_echo_state_init(Int32(frameSize), Int32(sampleRate * echoTailSeconds))
        var rate = Int32(sampleRate)
        speex_echo_ctl(state, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        return state
    }

    private func isSilent(_ microphone: [Float], frameAt frameStart: Int) -> Bool {
        vDSP.maximumMagnitude(microphone[frameStart..<(frameStart + Self.frameSize)]) == 0
    }

    /// One frame of `samples`, clipped and scaled to 16-bit, truncating toward zero.
    private func pcm16(_ samples: [Float], frameAt frameStart: Int, into frame: inout [Int16]) {
        precondition(frameStart + Self.frameSize <= samples.count)
        var (low, high, fullScale): (Float, Float, Float) = (-1, 1, Float(Int16.max))
        let count = vDSP_Length(Self.frameSize)
        samples.withUnsafeBufferPointer { samples in
            vDSP_vclip(samples.baseAddress! + frameStart, 1, &low, &high, &scaledFrame, 1, count)
        }
        vDSP_vsmul(scaledFrame, 1, &fullScale, &scaledFrame, 1, count)
        vDSP_vfix16(scaledFrame, 1, &frame, 1, count)
    }
}
