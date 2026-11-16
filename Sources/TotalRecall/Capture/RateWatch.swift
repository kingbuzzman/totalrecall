import CoreAudio

/// Measures the rate a device actually delivers at, from its buffers' timestamps, and reports when it no longer matches
/// the rate the session converts from. A device can switch rates under a running session (AirPods do when their mic
/// turns on, so does any device whose rate is changed); that session's audio, converted as if it were still at the old
/// rate, would come out stretched or squeezed in time and shift everything after it. Its audio is dropped instead;
/// `MicrophoneCapture` replaces the session, and the timeline fills the short gap with silence.
///
/// Used only on the session's audio thread.
final class RateWatch {
    /// Timestamps jitter by far less than this; a real switch, such as 44.1 to 48 kHz, is 9%.
    private static let tolerance = 0.03
    /// Off-rate buffers in a row before the session is given up on. One odd timestamp throws off two measurements, the
    /// one into it and the one out of it; after a real switch, every measurement is off.
    private static let mismatchesToGiveUp = 3

    private let expectedRate: Double
    private var previous: (sampleTime: Double, nanos: UInt64)?
    private var mismatches = 0

    init(expectedRate: Double) {
        self.expectedRate = expectedRate
    }

    /// Whether the device still delivers at the expected rate; once it has not, false for good.
    func isOnRate(at time: AudioTimeStamp) -> Bool {
        guard mismatches < Self.mismatchesToGiveUp else { return false }
        guard time.mFlags.contains([.sampleTimeValid, .hostTimeValid]) else { return true }
        let nanos = AudioConvertHostTimeToNanos(time.mHostTime)
        defer { previous = (time.mSampleTime, nanos) }
        guard let previous, nanos > previous.nanos, time.mSampleTime > previous.sampleTime else { return true }
        let rate = (time.mSampleTime - previous.sampleTime) / (Double(nanos - previous.nanos) / 1e9)
        mismatches = abs(rate / expectedRate - 1) > Self.tolerance ? mismatches + 1 : 0
        return mismatches < Self.mismatchesToGiveUp
    }
}
