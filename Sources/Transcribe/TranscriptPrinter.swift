import Foundation

/// Writes the transcript as it comes in: each line ("[00:01:23] Them: ...") the moment the recognizer settles on it, in
/// the order they settle, never reordered. Lines go to stdout, to a text file, or both; live, stdout also shows the text
/// still being recognized on a last line that is redrawn in place. Updates arrive from one task per speaker, so
/// everything is guarded by a lock.
final class TranscriptPrinter: @unchecked Sendable {
    private let printsLines: Bool
    private let isLive: Bool
    private let write: (String) -> Void
    private let save: ((String) -> Void)?
    private let terminalWidth: () -> Int
    private let lock = NSLock()
    private var volatileText: [String: String] = [:]

    /// `printsLines` prints each line to stdout, and `isLive` also shows the text still being recognized there, drawn
    /// with terminal control codes whether or not stdout is a terminal. `save` gets each line as well, for a text file.
    init(
        printsLines: Bool,
        isLive: Bool,
        terminalWidth: @escaping () -> Int = TranscriptPrinter.standardOutputWidth,
        write: @escaping (String) -> Void = {
            fputs($0, stdout)
            fflush(stdout)
        },
        save: ((String) -> Void)? = nil
    ) {
        self.printsLines = printsLines
        self.isLive = isLive && printsLines
        self.terminalWidth = terminalWidth
        self.write = write
        self.save = save
    }

    func update(_ update: TranscriptUpdate) {
        // The recognizer sometimes reports bare punctuation, such as "." for silence.
        let hasWords = update.text.contains { $0.isLetter || $0.isNumber }
        lock.withLock {
            let key = update.speakerName ?? update.speaker?.rawValue ?? ""
            if update.isFinal {
                volatileText[key] = nil
                if hasWords {
                    let line = Self.line(update) + "\n"
                    save?(line)
                    if printsLines {
                        clearLiveLine()
                        write(line)
                    }
                }
            } else {
                volatileText[key] = hasWords ? update.text : nil
            }
            drawLiveLine()
        }
    }

    func finish() {
        lock.withLock { clearLiveLine() }
    }

    private static func line(_ update: TranscriptUpdate) -> String {
        let seconds = Int(update.start.isFinite ? update.start : 0)
        let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        let speakerLabel = update.speakerName ?? update.speaker?.rawValue
        return "[\(time)] " + (speakerLabel.map { "\($0): " } ?? "") + update.text
    }

    private func clearLiveLine() {
        if isLive { write("\r\u{1B}[K") }
    }

    private func drawLiveLine() {
        guard isLive else { return }
        let parts = volatileText.sorted { $0.key > $1.key }.filter { !$0.value.isEmpty }
            .map { $0.key.isEmpty ? $0.value : "\($0.key): \($0.value)" }
        clearLiveLine()
        guard !parts.isEmpty else { return }
        // Keep it to one line, showing the most recent words.
        let text = "… " + parts.joined(separator: "  |  ")
        write("\u{1B}[2m" + String(text.suffix(max(terminalWidth() - 1, 10))) + "\u{1B}[0m")
    }

    static func standardOutputWidth() -> Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
    }
}
