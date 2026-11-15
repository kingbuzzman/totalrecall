import Accelerate
import Foundation

/// Leaves out of the transcript what your microphone picked up from the speakers, as totalrecall's echo canceller
/// leaves enough of it to be recognized: a line of yours that mostly says what the system audio was saying at the same
/// time, or one heard far quieter than the system audio was talking then, as the speakers come through, however
/// garbled the words. So each line of yours is held until the system audio's recognizer has heard past it and settled on
/// what was said then, and comes a few seconds later than it would; theirs go straight on.
///
/// Nor is what already looks like an echo shown meanwhile: your words still being recognized, and your lines while they
/// are held, are only passed on, to be shown live, while they do not, and taken back as soon as they do. A line of yours
/// taken back only goes on to the transcript if, once settled, it turns out not to be an echo after all. Updates come
/// from both speakers' tasks, so everything is guarded by a lock.
final class EchoFilter: @unchecked Sendable {
    /// How far apart in time the two copies of a line can be, as each recognizer times it.
    static let reach = 2.0
    /// A line of yours is an echo if at least this share of its words were said on the system audio around it; only
    /// one of at least `fewestWords`, as a short answer can well repeat words they said.
    static let echoShare = 0.5
    static let fewestWords = 5
    /// How long the recognizer may take to report the first words it hears.
    static let firstWordsSeconds = 1.0
    /// A line of yours at least this much quieter than the system audio at the time, in dB, while it has sound, is
    /// the speakers: they come through 25 to 35 dB down, and someone talking into the microphone about as loud as it.
    static let leakBelow: Float = 25
    static let silence: Float = -60

    private let pass: (TranscriptUpdate) -> Void
    private let levels: ChannelLevels?
    private let lock = NSLock()
    /// What the system audio's recognizer has settled on: its lines, how far into the audio it has listened, where the
    /// words it is still recognizing start, and whether it has ended.
    private var theirLines: [(start: Double, end: Double, words: Set<String>)] = []
    private var heardThrough = 0.0
    private var theirWordsStart: Double?
    /// The words the system audio's recognizer is still recognizing.
    private var theirLiveWords: Set<String> = []
    private var theyHaveEnded = false
    /// Your lines waiting for theirs, in order, and whether each is shown meanwhile.
    private var held: [(line: TranscriptUpdate, isShown: Bool)] = []
    /// Your words still being recognized, and whether they are shown.
    private var yourLiveWords: TranscriptUpdate?
    private var areYourLiveWordsShown = false

    /// Hands the transcript on to `pass`, without the echoes; `levels` says how loud each channel was.
    init(levels: ChannelLevels? = nil, pass: @escaping (TranscriptUpdate) -> Void) {
        self.levels = levels
        self.pass = pass
    }

    /// The transcript on its way to `pass`.
    func update(_ update: TranscriptUpdate) {
        lock.withLock {
            guard update.speaker == .you, !update.isHeld else { return pass(update) }
            if update.isFinal {
                let isShown = !looksLikeEcho(update.text, from: update.start, to: update.end)
                if isShown {
                    var notice = update
                    notice.isHeld = true
                    pass(notice)
                } else if areYourLiveWordsShown,
                    !(yourLiveWords.map { $0.start >= update.end ?? update.start } ?? false)
                {
                    // The words that became the line are not shown either.
                    passNoLiveWords(from: update.start)
                }
                if !(yourLiveWords.map { $0.start >= update.end ?? update.start } ?? false) { yourLiveWords = nil }
                held.append((update, isShown))
                passSettledLines()
            } else {
                yourLiveWords = update
                areYourLiveWordsShown = !looksLikeEcho(update.text, from: update.start, to: nil)
                if areYourLiveWordsShown { pass(update) } else { passNoLiveWords(from: update.start) }
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
                theirLiveWords = []
                heardThrough = max(heardThrough, end)
            } else {
                theirWordsStart = hasWords ? update.start : nil
                theirLiveWords = Self.words(update.text)
            }
            takeBackWhatNowLooksLikeAnEcho()
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
        while let (line, _) = held.first {
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

    /// Stops showing your words still being recognized, and your held lines, that look like an echo now that more of
    /// theirs has been heard.
    private func takeBackWhatNowLooksLikeAnEcho() {
        if areYourLiveWordsShown, let live = yourLiveWords, looksLikeEcho(live.text, from: live.start, to: nil) {
            areYourLiveWordsShown = false
            passNoLiveWords(from: live.start)
        }
        for index in held.indices where held[index].isShown {
            let line = held[index].line
            guard looksLikeEcho(line.text, from: line.start, to: line.end) else { continue }
            held[index].isShown = false
            // As for an echo: it never comes, for now, so its words stop showing.
            pass(TranscriptUpdate(speaker: .you, start: line.start, text: "", isFinal: true, end: line.end))
        }
    }

    /// Clears your words still being recognized from what is shown.
    private func passNoLiveWords(from start: Double) {
        pass(TranscriptUpdate(speaker: .you, start: start, text: "", isFinal: false))
    }

    /// Whether what your microphone heard from `start` to `end` (nil for up to now) looks like an echo from what has
    /// been heard so far: far quieter than them, or mostly words they have just said or are saying. Only for what is
    /// shown live: hiding a line of yours that is not an echo only shows it later, once it is settled.
    private func looksLikeEcho(_ text: String, from start: Double, to end: Double?) -> Bool {
        if isFarQuieterThanThem(from: start, to: end) { return true }
        let words = Self.words(text)
        guard !words.isEmpty else { return false }
        var theirWords = theirLines.filter {
            $0.end >= start - Self.reach && $0.start <= (end ?? .infinity) + Self.reach
        }
        .reduce(into: Set()) { $0.formUnion($1.words) }
        if let theirWordsStart, theirWordsStart <= (end ?? .infinity) + Self.reach {
            theirWords.formUnion(theirLiveWords)
        }
        return Double(words.filter(theirWords.contains).count) >= Double(words.count) * Self.echoShare
    }

    /// Whether your microphone was far quieter than the system audio, which had sound, from `start` to `end`, or up to
    /// now: the speakers coming through.
    private func isFarQuieterThanThem(from start: Double, to end: Double?) -> Bool {
        guard let levels, let theirs = levels.loudness(of: .them, from: start, to: end), theirs > Self.silence,
            let yours = levels.loudness(of: .you, from: start, to: end)
        else { return false }
        return yours <= theirs - Self.leakBelow
    }

    private func isEcho(_ line: TranscriptUpdate) -> Bool {
        if isFarQuieterThanThem(from: line.start, to: line.end ?? line.start) { return true }
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

/// How loud your microphone and the system audio were, every `frameSeconds`, over the last `memorySeconds`, as they
/// come in, from the reading task, and are asked about from the transcribers'.
final class ChannelLevels: @unchecked Sendable {
    static let frameSeconds = 0.05
    private static let memorySeconds = 120.0
    /// How loud a channel is over a line: as loud as half its frames at least, so a knock or a cough does not count.
    private static let loudShare = 0.5

    private let frameLength: Int
    private let lock = NSLock()
    /// Each channel's loudness in dB, frame by frame from `firstFrame`, and what came in after the last whole frame.
    private var levels: [[Float]] = [[], []]
    private var firstFrame = 0
    private var rest: [[Float]] = [[], []]

    init(sampleRate: Double) {
        frameLength = max(Int(sampleRate * Self.frameSeconds), 1)
    }

    /// A chunk of the recording: your microphone, then the system audio.
    func add(_ chunk: [[Float]]) {
        guard chunk.count >= 2 else { return }
        lock.withLock {
            for channel in 0..<2 {
                rest[channel] += chunk[channel]
                let whole = rest[channel].count / frameLength * frameLength
                for start in stride(from: 0, to: whole, by: frameLength) {
                    let power = vDSP.meanSquare(rest[channel][start..<start + frameLength])
                    levels[channel].append(10 * log10(power + 1e-12))
                }
                rest[channel].removeFirst(whole)
            }
            let kept = Int(Self.memorySeconds / Self.frameSeconds)
            let extra = min(levels[0].count, levels[1].count) - kept
            if extra > kept / 2 {
                levels = levels.map { Array($0.dropFirst(extra)) }
                firstFrame += extra
            }
        }
    }

    /// How loud `speaker`'s channel was from `start` to `end`, or up to the latest audio with `end` nil, in seconds from
    /// the start: nil for a time it has none of.
    func loudness(of speaker: Speaker, from start: Double, to end: Double?) -> Float? {
        lock.withLock {
            let channel = levels[speaker == .you ? 0 : 1]
            let first = max(Int(start / Self.frameSeconds) - firstFrame, 0)
            let last =
                end.map { min(Int(($0 / Self.frameSeconds).rounded(.up)) - firstFrame, channel.count) } ?? channel.count
            guard first < last else { return nil }
            let sorted = channel[first..<last].sorted(by: >)
            return sorted[min(Int(Double(sorted.count) * Self.loudShare), sorted.count - 1)]
        }
    }
}
