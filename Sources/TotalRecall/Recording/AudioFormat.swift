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

var aacSettings: [String: Any] {
    [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitRateKey: 128_000,
    ]
}

/// Lossless, about half the size of 16-bit PCM.
var flacSettings: [String: Any] {
    [
        AVFormatIDKey: kAudioFormatFLAC,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVEncoderBitDepthHintKey: 16,
    ]
}

/// How macOS itself encodes the format a file extension names, or nil when it cannot and ffmpeg has to (.mp3, .ogg,
/// ...). A .caf is the partial recording's own format, so it needs no encoding at all.
func nativeSettings(forExtension fileExtension: String) -> [String: Any]? {
    switch fileExtension.lowercased() {
    case "wav", "wave": pcmSettings(bigEndian: false)
    case "aif", "aiff": pcmSettings(bigEndian: true)
    case "m4a", "mp4", "aac": aacSettings
    case "flac": flacSettings
    default: nil
    }
}
