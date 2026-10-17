import CoreAudio

/// The not-yet-written samples of one channel, laid out on a timeline derived from the captures' host times.
/// Not thread-safe; `Recorder` guards each track with its lock.
final class Track {
    /// Gaps shorter than this are timing jitter, not lost audio, and are not filled with silence.
    private static let gapFillThresholdFrames = Int(sampleRate * 0.1)
    /// A new source that overlaps the old one by more than this is placed by its host time instead of spliced.
    private static let maxSwitchOverlapFrames = Int(sampleRate * 0.5)

    /// Host time of the first buffer, or nil until one arrives.
    private(set) var startHostTime: UInt64?
    private(set) var hasHeardSound = false
    private var samples: [Float] = []
    private var peak: Float = 0
    private var lastBufferUptime = uptimeSeconds()
    private var timelineFrames = 0
    private var source: Int?
    private var endNanos: UInt64 = 0

    /// Samples waiting to be written.
    var count: Int { samples.count }

    var secondsSinceLastBuffer: Double { uptimeSeconds() - lastBufferUptime }

    /// Appends samples at the position their host time implies, filling any gap (such as a device switch) with silence.
    /// When a new source (capture session) takes over, its audio is spliced in exactly where the old source's ended:
    /// a gap becomes silence and audio both sources captured is kept only once, so nothing is repeated or shifted.
    func append(_ newSamples: [Float], hostTime: UInt64, source newSource: Int = 0) {
        let startNanos = AudioConvertHostTimeToNanos(hostTime)
        let spliceOffset = Int(frames(inNanoseconds: Double(startNanos) - Double(endNanos)).rounded())
        var kept = newSamples[...]
        if let source, newSource != source, spliceOffset > -Self.maxSwitchOverlapFrames {
            if spliceOffset > 0 { appendSilence(spliceOffset) }
            kept = kept.dropFirst(max(-spliceOffset, 0))
            // Entirely audio the old source already delivered; splice on the next buffer.
            guard !kept.isEmpty else { return }
        } else if let startHostTime {
            if hostTime > startHostTime {
                let elapsedNanos = startNanos - AudioConvertHostTimeToNanos(startHostTime)
                let gap = Int(frames(inNanoseconds: Double(elapsedNanos))) - timelineFrames
                if gap > Self.gapFillThresholdFrames { appendSilence(gap) }
            }
        } else {
            startHostTime = hostTime
        }
        source = newSource
        endNanos = startNanos + UInt64(nanoseconds(ofFrames: newSamples.count).rounded())
        samples.append(contentsOf: kept)
        timelineFrames += kept.count
        lastBufferUptime = uptimeSeconds()
        let newPeak = kept.reduce(0) { max($0, abs($1)) }
        peak = max(peak, newPeak)
        if newPeak > 0 { hasHeardSound = true }
    }

    func take(_ count: Int) -> [Float] {
        let taken = Array(samples.prefix(count))
        samples.removeFirst(count)
        return taken
    }

    func takeAll() -> [Float] {
        take(samples.count)
    }

    /// The loudest sample since the previous call.
    func takePeak() -> Float {
        defer { peak = 0 }
        return peak
    }

    /// Gives a freshly restarted capture the full stall window to deliver its first buffer.
    func resetStallTimer() {
        lastBufferUptime = uptimeSeconds()
    }

    func padWithSilence(toCount count: Int) {
        if samples.count < count { appendSilence(count - samples.count) }
    }

    /// Delays the waiting samples by `count` frames of silence. The timeline is measured from this track's own first
    /// buffer, so it does not move.
    func delayStart(by count: Int) {
        samples.insert(contentsOf: repeatElement(0, count: count), at: 0)
    }

    private func appendSilence(_ count: Int) {
        samples.append(contentsOf: repeatElement(0, count: count))
        timelineFrames += count
    }
}
