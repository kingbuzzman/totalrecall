import Foundation
import Shared

/// Writes the transcript as it comes in: each line ("[00:01:23] Them: ...") the moment the recognizer settles on it, in
/// the order they settle, never reordered. Lines go to stdout, to a text file, or both; live, stdout also shows the text
/// still being recognized on a last line that is redrawn in place. Once it is over, it can be written again, each line
/// said by whoever turned out to say it (`rewritten`). Updates arrive from one task per speaker, so everything is
/// guarded by a lock.
final class TranscriptPrinter: @unchecked Sendable {
    private let printsLines: Bool
    private let isLive: Bool
    private let write: (String) -> Void
    private let save: ((String) -> Void)?
    private let showLive: ((String) -> Void)?
    private let showLine: ((_ line: String, _ isYours: Bool) -> Void)?
    private let showAll: (([(line: String, isYours: Bool)]) -> Void)?
    private let terminalWidth: () -> Int
    private let lock = NSLock()
    /// Each speaker's words still being recognized, and when they start, after their lines held back, by when those
    /// start.
    private var volatileText: [String: (start: Double, text: String)] = [:]
    private var heldLines: [String: [(start: Double, text: String)]] = [:]
    /// The lines written, as they came.
    private var written: [TranscriptUpdate] = []

    /// `printsLines` prints each line to stdout, and `isLive` also shows the text still being recognized there, drawn
    /// with terminal control codes whether or not stdout is a terminal. `save` gets each line as well, for a text file;
    /// for an app, `showLine` gets it too, without its newline, and whether it was heard on your microphone, and
    /// `showLive` the text still being recognized, as plain text, whenever it changes ("" once there is none); and,
    /// written again, `showAll` gets all of them.
    init(
        printsLines: Bool,
        isLive: Bool,
        terminalWidth: @escaping () -> Int = TranscriptPrinter.standardOutputWidth,
        write: @escaping (String) -> Void = {
            fputs($0, stdout)
            fflush(stdout)
        },
        save: ((String) -> Void)? = nil,
        showLine: ((_ line: String, _ isYours: Bool) -> Void)? = nil,
        showLive: ((String) -> Void)? = nil,
        showAll: (([(line: String, isYours: Bool)]) -> Void)? = nil
    ) {
        self.printsLines = printsLines
        self.isLive = isLive && printsLines
        self.terminalWidth = terminalWidth
        self.write = write
        self.save = save
        self.showLive = showLive
        self.showLine = showLine
        self.showAll = showAll
    }

    func update(_ update: TranscriptUpdate) {
        let hasWords = update.text.hasWords
        lock.withLock {
            let key = update.speaker?.rawValue ?? ""
            // A line held back comes while the words after it are being recognized.
            let followsIt = update.end.flatMap { end in volatileText[key].map { $0.start >= end } } ?? false
            if update.isHeld {
                if !followsIt { volatileText[key] = nil }
                if hasWords, !(heldLines[key] ?? []).contains(where: { $0.start == update.start }) {
                    heldLines[key, default: []].append((update.start, update.text))
                }
            } else if update.isFinal {
                heldLines[key]?.removeAll { $0.start == update.start }
                if !followsIt { volatileText[key] = nil }
                if hasWords {
                    written.append(update)
                    let line = Self.line(update) + "\n"
                    save?(line)
                    showLine?(Self.line(update), update.speaker == .you)
                    if printsLines {
                        clearLiveLine()
                        write(line)
                    }
                }
            } else {
                volatileText[key] = hasWords ? (update.start, update.text) : nil
            }
            drawLiveLine()
        }
    }

    func finish() {
        lock.withLock {
            clearLiveLine()
            showLive?("")
        }
    }

    /// The transcript written again, in the same order, each line as `relabel` splits it where who speaks changes and
    /// says who spoke each part now; an app is shown it too. The parts of a line split as it was written are one line
    /// again first.
    func rewritten(relabel: (TranscriptUpdate) -> [TranscriptUpdate]) -> String {
        lock.withLock {
            var lines: [TranscriptUpdate] = []
            var lineOf: [String: Int] = [:]
            for part in written {
                let key = "\(part.speaker?.rawValue ?? "") \(part.lineStart ?? part.start)"
                guard let index = lineOf[key] else {
                    lineOf[key] = lines.count
                    var line = part
                    line.start = part.lineStart ?? part.start
                    lines.append(line)
                    continue
                }
                lines[index].words += part.words
                lines[index].text += " " + part.text
                lines[index].end = part.end ?? lines[index].end
            }
            let parts = lines.flatMap(relabel).filter(\.text.hasWords)
            showAll?(parts.map { (Self.line($0), $0.speaker == .you) })
            return parts.map { Self.line($0) + "\n" }.joined()
        }
    }

    private static func line(_ update: TranscriptUpdate) -> String {
        let time = clockTime(Int(update.start.isFinite ? update.start : 0))
        let label = update.voice ?? update.speaker?.rawValue
        return "[\(time)] " + (label.map { "\($0): " } ?? "") + update.text
    }

    private func clearLiveLine() {
        if isLive { write(Terminal.clearLine) }
    }

    private func drawLiveLine() {
        guard isLive || showLive != nil else { return }
        let keys = Set(volatileText.keys).union(heldLines.keys).sorted(by: >)
        let parts = keys.compactMap { key -> String? in
            let texts = (heldLines[key] ?? []).map(\.text) + [volatileText[key]?.text].compactMap { $0 }
            let text = texts.filter { !$0.isEmpty }.joined(separator: " ")
            return text.isEmpty ? nil : key.isEmpty ? text : "\(key): \(text)"
        }
        showLive?(parts.joined(separator: "  |  "))
        guard isLive else { return }
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
