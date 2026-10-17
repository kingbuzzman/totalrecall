import Foundation

/// Shows the transcript as it comes in: final text as timestamped lines ("[00:01:23] Them: ..."), and, when live on a
/// terminal, the text still being recognized on a last line that is redrawn in place. Updates arrive from one task per
/// speaker, so everything is guarded by a lock.
final class TranscriptPrinter: @unchecked Sendable {
    private let isLive: Bool
    private let printsLines: Bool
    private let lock = NSLock()
    private var volatileText: [String: String] = [:]
    private var finals: [TranscriptUpdate] = []

    /// `printsLines` prints final lines to stdout as they arrive; `isLive` also shows text still being recognized.
    init(printsLines: Bool, isLive: Bool) {
        self.printsLines = printsLines
        self.isLive = isLive && printsLines && isatty(STDOUT_FILENO) != 0
    }

    func update(_ update: TranscriptUpdate) {
        lock.withLock {
            let key = update.speaker?.rawValue ?? ""
            if update.isFinal {
                volatileText[key] = nil
                if !update.text.isEmpty {
                    finals.append(update)
                    if printsLines {
                        clearLiveLine()
                        print(Self.line(update))
                    }
                }
            } else {
                volatileText[key] = update.text
            }
            drawLiveLine()
            fflush(stdout)
        }
    }

    /// The whole transcript in time order.
    var transcript: String {
        lock.withLock { finals.sorted { $0.start < $1.start }.map(Self.line).joined(separator: "\n") + "\n" }
    }

    func finish() {
        lock.withLock {
            clearLiveLine()
            fflush(stdout)
        }
    }

    private static func line(_ update: TranscriptUpdate) -> String {
        let seconds = Int(update.start.isFinite ? update.start : 0)
        let time = String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
        return "[\(time)] " + (update.speaker.map { "\($0.rawValue): " } ?? "") + update.text
    }

    private func clearLiveLine() {
        if isLive { print("\r\u{1B}[K", terminator: "") }
    }

    private func drawLiveLine() {
        guard isLive else { return }
        let parts = volatileText.sorted { $0.key > $1.key }.filter { !$0.value.isEmpty }
            .map { $0.key.isEmpty ? $0.value : "\($0.key): \($0.value)" }
        clearLiveLine()
        guard !parts.isEmpty else { return }
        // Keep it to one line, showing the most recent words.
        let text = "… " + parts.joined(separator: "  |  ")
        print("\u{1B}[2m" + String(text.suffix(max(terminalWidth() - 1, 10))) + "\u{1B}[0m", terminator: "")
    }

    private func terminalWidth() -> Int {
        var size = winsize()
        return ioctl(STDOUT_FILENO, TIOCGWINSZ, &size) == 0 && size.ws_col > 0 ? Int(size.ws_col) : 80
    }
}
