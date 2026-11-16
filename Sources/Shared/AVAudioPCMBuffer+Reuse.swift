package import AVFAudio

extension AVAudioPCMBuffer {
    /// `buffer` while it holds `frameCapacity` frames, otherwise a new one: one buffer reused from call to call, grown
    /// as needed, rather than one allocated per call.
    package static func reusing(
        _ buffer: AVAudioPCMBuffer?,
        format: AVAudioFormat,
        frameCapacity: AVAudioFrameCount
    ) -> AVAudioPCMBuffer? {
        if let buffer, buffer.frameCapacity >= frameCapacity { return buffer }
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCapacity)
    }

    /// A copy of the samples of one channel of a deinterleaved float buffer.
    package func samples(channel: Int = 0) -> [Float] {
        Array(UnsafeBufferPointer(start: floatChannelData![channel], count: Int(frameLength)))
    }
}
