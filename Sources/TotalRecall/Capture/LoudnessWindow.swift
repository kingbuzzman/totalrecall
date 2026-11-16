import Accelerate

/// A microphone's level over whole seconds: the RMS, in dBFS, of the mono samples it delivers at the recording rate.
struct LoudnessWindow {
    static let length = Int(sampleRate)
    /// The level of digital silence, which has no logarithm.
    static let silence = -200.0

    private var sumOfSquares = 0.0
    private var count = 0

    /// Adds samples; returns the level of the window they complete, the last one if they complete several.
    mutating func add(_ samples: [Float]) -> Double? {
        var level: Double?
        var start = 0
        while start < samples.count {
            let taken = min(Self.length - count, samples.count - start)
            sumOfSquares += Double(vDSP.sumOfSquares(samples[start..<(start + taken)]))
            count += taken
            start += taken
            if count == Self.length {
                let meanSquare = sumOfSquares / Double(count)
                level = meanSquare > 0 ? max(10 * log10(meanSquare), Self.silence) : Self.silence
                sumOfSquares = 0
                count = 0
            }
        }
        return level
    }
}
