/// Removes the system audio that the microphone picks up from the speakers, using the captured system audio as the
/// echo reference (speexdsp acoustic echo canceller plus residual echo suppression).
final class EchoCanceller {
    // Speex needs a power-of-two frame: with 480 (10 ms) its filter diverges and resets every few seconds, cancelling
    // almost nothing; 1024 (21 ms) converges within about 3 s.
    static let frameSize = 1024
    private static let echoTailSeconds = 0.12
    private let echoState: OpaquePointer
    private let preprocessState: OpaquePointer
    private var microphoneFrame = [Int16](repeating: 0, count: frameSize)
    private var speakerFrame = [Int16](repeating: 0, count: frameSize)
    private var cleanedFrame = [Int16](repeating: 0, count: frameSize)

    init() {
        echoState = speex_echo_state_init(Int32(Self.frameSize), Int32(sampleRate * Self.echoTailSeconds))
        var rate = Int32(sampleRate)
        speex_echo_ctl(echoState, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        preprocessState = speex_preprocess_state_init(Int32(Self.frameSize), Int32(sampleRate))
        speex_preprocess_ctl(preprocessState, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echoState))
    }

    deinit {
        speex_preprocess_state_destroy(preprocessState)
        speex_echo_state_destroy(echoState)
    }

    /// Both inputs must be the same length, a multiple of `frameSize`, and aligned in time.
    func cancel(microphone: [Float], speaker: [Float]) -> [Float] {
        var cleaned = [Float]()
        cleaned.reserveCapacity(microphone.count)
        for frameStart in stride(from: 0, to: microphone.count, by: Self.frameSize) {
            for offset in 0..<Self.frameSize {
                microphoneFrame[offset] = pcm16(microphone[frameStart + offset])
                speakerFrame[offset] = pcm16(speaker[frameStart + offset])
            }
            speex_echo_cancellation(echoState, microphoneFrame, speakerFrame, &cleanedFrame)
            speex_preprocess_run(preprocessState, &cleanedFrame)
            cleaned.append(contentsOf: cleanedFrame.map { Float($0) / Float(Int16.max) })
        }
        return cleaned
    }

    private func pcm16(_ sample: Float) -> Int16 {
        Int16(min(max(sample, -1), 1) * Float(Int16.max))
    }
}
