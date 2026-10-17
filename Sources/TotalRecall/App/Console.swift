import Foundation

/// Progress on stderr: timestamped announcements and, on a terminal, a level meter redrawn in place.
struct StatusLine {
    private static let meterWidth = 10
    private static let meterFloorDecibels: Float = -60

    let recorder: Recorder
    private let showsMeter = isatty(STDERR_FILENO) != 0

    /// Length of the recording so far, as HH:MM:SS.
    var elapsed: String {
        let seconds = Int(recorder.secondsRecorded)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// Prints `message` on a line of its own, clearing the meter first.
    func announce(_ message: String) {
        fputs("\(showsMeter ? "\r\u{1B}[K" : "")[\(elapsed)] \(message)\n", stderr)
    }

    func reportWriteFailure(_ error: Error) {
        fputs("\ntotalrecall: write failed: \(error.localizedDescription)\n", stderr)
    }

    func showLevels(_ levels: LevelSnapshot) {
        guard showsMeter else { return }
        let microphoneMeter = recorder.includesMicrophone ? "  mic \(Self.meter(levels.microphonePeak))" : ""
        fputs("\r\u{1B}[K● \(elapsed)\(microphoneMeter)  system \(Self.meter(levels.systemPeak))", stderr)
    }

    private static func meter(_ peak: Float) -> String {
        let decibels = 20 * log10(max(peak, 1e-6))
        let level = ((decibels - meterFloorDecibels) / -meterFloorDecibels * Float(meterWidth)).rounded()
        let filled = min(max(Int(level), 0), meterWidth)
        return String(repeating: "█", count: filled) + String(repeating: "·", count: meterWidth - filled)
    }
}
