import Foundation

/// Progress on stderr: messages ("totalrecall: ...", never timestamped, which would look like a line of a transcript)
/// and, on a terminal, a level meter redrawn in place.
///
/// On a terminal every message starts by clearing the current line, which may hold the meter or, when the recording
/// streams to `transcribe -`, its text still being recognized: either is redrawn on its next update, below the message.
struct StatusLine {
    private static let meterWidth = 10
    private static let meterFloorDecibels: Float = -60

    let recorder: Recorder
    private let isTerminal: Bool
    private let showsMeter: Bool
    private let write: (String) -> Void

    /// The meter is only shown on a terminal, and not while streaming: the other program writes to the same terminal,
    /// and a line redrawn in place would garble its output.
    init(
        recorder: Recorder,
        isStreaming: Bool,
        isTerminal: Bool = isatty(STDERR_FILENO) != 0,
        write: @escaping (String) -> Void = { fputs($0, stderr) }
    ) {
        self.recorder = recorder
        self.isTerminal = isTerminal
        self.write = write
        showsMeter = !isStreaming && isTerminal
    }

    /// Returns to the start of the line and clears it, on a terminal.
    private var clearLine: String { isTerminal ? "\r\u{1B}[K" : "" }

    /// Length of the recording so far, as HH:MM:SS.
    var elapsed: String {
        let seconds = Int(recorder.secondsRecorded)
        return String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// Prints "totalrecall: `message`" on a line of its own.
    func announce(_ message: String) {
        say("totalrecall: \(message)")
    }

    func reportWriteFailure(_ error: any Error) {
        announce("write failed: \(error.localizedDescription)")
    }

    /// Prints `text` on a line of its own.
    func say(_ text: String) {
        write("\(clearLine)\(text)\n")
    }

    func showLevels(_ levels: LevelSnapshot) {
        guard showsMeter else { return }
        let microphoneMeter = recorder.includesMicrophone ? "  mic \(Self.meter(levels.microphonePeak))" : ""
        write("\r\u{1B}[K● \(elapsed)\(microphoneMeter)  system \(Self.meter(levels.systemPeak))")
    }

    static func meter(_ peak: Float) -> String {
        let decibels = 20 * log10(max(peak, 1e-6))
        let level = ((decibels - meterFloorDecibels) / -meterFloorDecibels * Float(meterWidth)).rounded()
        let filled = min(max(Int(level), 0), meterWidth)
        return String(repeating: "█", count: filled) + String(repeating: "·", count: meterWidth - filled)
    }
}
