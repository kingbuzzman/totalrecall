import AVFoundation

/// Every capture is resampled to this rate, and every file is written at it.
let sampleRate = 48_000.0
let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!

/// Frames at `sampleRate` in a span of nanoseconds; fractional, so callers choose the rounding.
func frames(inNanoseconds nanoseconds: Double) -> Double {
    nanoseconds / 1e9 * sampleRate
}

/// How long `frameCount` frames at `sampleRate` last.
func nanoseconds(ofFrames frameCount: Int) -> Double {
    Double(frameCount) / sampleRate * 1e9
}

/// 16-bit stereo PCM: the partial recording, .wav (little-endian) and .aiff (big-endian).
func pcmSettings(bigEndian: Bool) -> [String: Any] {
    [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: bigEndian,
    ]
}

let aacSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 2,
    AVEncoderBitRateKey: 128_000,
]
