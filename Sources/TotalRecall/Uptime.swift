import Foundation

/// Seconds since the Mac started, not counting sleep: a clock that never jumps, for timing captures.
func uptimeSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}
