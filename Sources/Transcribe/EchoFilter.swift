import Foundation

/// Leaves out of the transcript what your microphone picked up from the speakers, as totalrecall's echo canceller
/// leaves enough of it to be recognized: a line of yours that mostly says what the system audio was saying at the same
/// time. So each line of yours is held until the system audio's recognizer has heard past it and settled on what was
/// said then, and comes a few seconds later than it would; theirs go straight on, as do the words still being
/// recognized. Updates come from both speakers' tasks, so everything is guarded by a lock.
final class EchoFilter: @unchecked Sendable {
    /// How far apart in time the two copies of a line can be, as each recognizer times it.
    static let reach = 2.0
    /// A line of yours is an echo if at least this share of its words were said on the system audio around it; only
    /// one of at least `fewestWords`, as a short answer can well repeat words they said.
    static let echoShare = 0.5
    static let fewestWords = 5
    /// How long the recognizer may take to report the first words it hears.
    static let firstWordsSeconds = 1.0

    private let pass: (TranscriptUpdate) -> Void
    private let lock = NSLock()
    /// What the system audio's recognizer has settled on: its lines, how far into the audio it has listened, where the
    /// words it is still recognizing start, and whether it has ended.
    private var theirLines: [(start: Double, end: Double, words: Set<String>)] = []
    private var heardThrough = 0.0
    private var theirWordsStart: Double?
    private var theyHaveEnded = false
    /// Your lines waiting for theirs, in order.
    private var held: [TranscriptUpdate] = []

    /// Hands the transcript on to `pass`, without the echoes.
    init(pass: @escaping (TranscriptUpdate) -> Void) {
        self.pass = pass
    }

    /// The transcript on its way to `pass`.
    func update(_ update: TranscriptUpdate) {
        lock.withLock {
            if update.speaker == .you, update.isFinal, !update.isHeld {
                var notice = update
                notice.isHeld = true
                pass(notice)
                held.append(update)
                passSettledLines()
            } else {
                pass(update)
            }
        }
    }

    /// What the system audio's recognizer has heard, the moment it does, before its lines wait to say who spoke them.
    func theirs(_ update: TranscriptUpdate) {
        lock.withLock {
            let hasWords = !Self.words(update.text).isEmpty
            if update.isFinal {
                let end = update.end ?? update.start
                theirLines.append((update.start, end, Self.words(update.text)))
                theirLines.removeAll { $0.end < end - 60 }
                theirWordsStart = nil
                heardThrough = max(heardThrough, end)
            } else {
                theirWordsStart = hasWords ? update.start : nil
            }
            passSettledLines()
        }
    }

    /// The system audio's recognizer has listened up to `time`.
    func theyHaveBeenHeard(through time: Double) {
        guard time.isFinite else { return }
        lock.withLock {
            heardThrough = max(heardThrough, time)
            passSettledLines()
        }
    }

    /// The system audio has ended, so there is nothing more of theirs to wait for.
    func theyHaveFinished() {
        lock.withLock {
            theyHaveEnded = true
            passSettledLines()
        }
    }

    private func passSettledLines() {
        while let line = held.first {
            let end = (line.end ?? line.start) + Self.reach
            let isSettled = heardThrough >= end + Self.firstWordsSeconds && (theirWordsStart.map { $0 > end } ?? true)
            guard theyHaveEnded || isSettled else { return }
            held.removeFirst()
            if isEcho(line) {
                // It never comes, so its words stop showing.
                pass(TranscriptUpdate(speaker: .you, start: line.start, text: "", isFinal: true, end: line.end))
            } else {
                pass(line)
            }
        }
    }

    private func isEcho(_ line: TranscriptUpdate) -> Bool {
        let words = Self.words(line.text)
        guard words.count >= Self.fewestWords else { return false }
        let (start, end) = (line.start - Self.reach, (line.end ?? line.start) + Self.reach)
        let theirWords = theirLines.filter { $0.start <= end && $0.end >= start }.reduce(into: Set()) {
            $0.formUnion($1.words)
        }
        return Double(words.filter(theirWords.contains).count) >= Double(words.count) * Self.echoShare
    }

    /// The words of a line, lowercased, without punctuation.
    private static func words(_ text: String) -> Set<String> {
        Set(text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }
}
