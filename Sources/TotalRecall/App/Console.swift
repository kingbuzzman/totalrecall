import Foundation

/// Progress on stderr: timestamped announcements and, on a terminal, a level meter redrawn in place.
///
/// On a terminal every message starts by clearing the current line, which may hold the meter or, when the recording
/// streams to `transcribe -`, its text still being recognized: either is redrawn on its next update, below the message.
struct StatusLine {
    private static let meterWidth = 10
    private static let meterFloorDecibels: Float = -60

    let recorder: Recorder
    private let isTerminal = isatty(STDERR_FILENO) != 0
    private let showsMeter: Bool

    /// The meter is only shown on a terminal, and not when `allowsMeter` is false: when the recording streams to
    /// another program that writes to the same terminal, a line redrawn in place would garble its output.
    init(recorder: Recorder, allowsMeter: Bool) {
        self.recorder = recorder
        showsMeter = allowsMeter && isTerminal
    }

    /// Returns to the start of the line and clears it, on a terminal.
    private var clearLine: String { isTerminal ? "\r\u{1B}[K" : "" }

    /// Length of the recording so far, as HH:MM:SS.
    var elapsed: String {
        let seconds = Int(recorder.secondsRecorded)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// Prints `message` on a line of its own, stamped with the recording time.
    func announce(_ message: String) {
        say("[\(elapsed)] \(message)")
    }

    /// Prints a warning on a line of its own, without a timestamp.
    func warn(_ message: String) {
        say("totalrecall: \(message)")
    }

    func reportWriteFailure(_ error: Error) {
        warn("write failed: \(error.localizedDescription)")
    }

    /// Prints `text` on a line of its own.
    func say(_ text: String) {
        fputs("\(clearLine)\(text)\n", stderr)
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
