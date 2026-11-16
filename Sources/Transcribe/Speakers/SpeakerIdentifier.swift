import AVFoundation
import Accelerate
import Foundation
import Shared

/// Tells the people on one channel apart by their voices (`--identify-speakers`), as `SpeakerTurns` does, from audio
/// that comes in as it is recorded. Each line of the transcript is split where who speaks changes, by when its words
/// were said, and each part goes to whoever talked the most while it was said: as the call goes on, as the speakers
/// heard so far sound, then again once it is over (`conclude`), all its voices heard, to write the transcript again.
///
/// With a database, someone heard on an earlier call is recognized as them, by their name or number ("Them 3"), and
/// once the call is over, everyone else who said words, and has a clip of them alone, is remembered (see
/// `SpeakerIdentifier+Remembering`). Until then they go by a letter ("Them A"); without a database, by their number in
/// this call. On your microphone, whoever is not recognized as someone else is you. Audio comes in through `append` and
/// `finish` from one task while the transcribers ask who said what from theirs, so what it has worked out, and the
/// database, are guarded by a lock.
final class SpeakerIdentifier: @unchecked Sendable {
    /// A window's person is printed from the frames they talk alone in, if at least `aloneSeconds` of them; with
    /// less, but at least `shortestTalk` of their talking, the print is short (see `SpeakerTurns.Print`).
    static let aloneSeconds = 1.0
    static let shortestTalk = 0.3
    /// A line is said to be someone's once the windows go this far past it, so it is not at the very end of one.
    static let settleSeconds = 2.5
    /// How much of the call one print stands for, in the database.
    static let secondsPerPrint = Double(SpeakerTurns.windowStep) / VoicePrinter.sampleRate
    /// How much of the audio is kept, to cut clips from.
    static let historySeconds = 40.0
    /// A window whose loudest `blockSeconds` are quieter than `silence`, in dB below full scale, has nobody talking in
    /// it, without asking the models: well below the quietest microphone seen, at about -50 dB.
    private static let silence: Float = -60
    private static let blockSeconds = 0.1

    let name: String
    let isYours: Bool
    private let resampler: VoiceResampler
    let segmenter: any SpeakerSegmenting
    let printer: any VoicePrinting
    let database: SpeakerDatabase?
    /// When this channel had speech, and when the other one did: on your microphone, what it heard while the system
    /// audio had speech is left out, as it may be the speakers playing it.
    private let speechTimes: SpeechTimes?
    private let otherSpeechTimes: SpeechTimes?
    let warn: (String) -> Void
    let lock = NSLock()
    /// The last of the audio, at `VoicePrinter.sampleRate`, from `historyStart` in it, and where the next window
    /// starts; only `append` and `finish` touch them.
    var history: [Float] = []
    var historyStart = 0
    private var nextWindow = 0
    var hasWarnedAboutPrints = false
    var hasWarned = false
    /// Who talks when, and how far it has been worked out, in seconds; whether the audio has ended.
    var turns = SpeakerTurns()
    private var segmentedThrough = 0.0
    private var hasEnded = false
    /// The lines asked about, by when they were said: only someone who says words is remembered.
    var lines: [(start: Double, end: Double)] = []
    /// What is known of each speaker from the database: who they were recognized as during the call, the voices in it
    /// before the call, and, once the call is over, what each is called.
    var recognized: [Int: SpeakerDatabase.Voice] = [:]
    var heardBefore: [SpeakerDatabase.Voice] = []
    var finalNames: [Int: String] = [:]
    /// Clips of someone alone speaking, kept as they are heard, for those they turn out to be once the call is over.
    var clips = ClipCollector()

    /// `name` is what the speakers are called, before their number; `isYours` is for your microphone. `segmenter` and
    /// `printer` work at `VoicePrinter.sampleRate`. `speechTimes` is told when there was speech; the audio from when
    /// `otherSpeechTimes` had some is left out, so it has to have heard it first. `warn` is told, once each, if the
    /// database cannot be read or written, and if voices cannot be told apart. Throws for audio it cannot tell voices
    /// apart in.
    init(
        name: String,
        isYours: Bool = false,
        sampleRate: Double,
        segmenter: any SpeakerSegmenting,
        printer: any VoicePrinting,
        database: SpeakerDatabase? = nil,
        speechTimes: SpeechTimes? = nil,
        otherSpeechTimes: SpeechTimes? = nil,
        warn: @escaping (String) -> Void = { _ in }
    ) throws {
        resampler = try VoiceResampler(sampleRate: sampleRate)
        self.name = name
        self.isYours = isYours
        self.segmenter = segmenter
        self.printer = printer
        self.database = database
        self.speechTimes = speechTimes
        self.otherSpeechTimes = otherSpeechTimes
        self.warn = warn
        remember { heardBefore = try database?.voices() ?? [] }
    }

    func append(_ samples: [Float]) {
        history += resampler.resample(samples)
        while nextWindow + Segmenter.windowLength <= historyStart + history.count {
            identify(at: nextWindow)
            nextWindow += SpeakerTurns.windowStep
        }
        let kept = max(Int(VoicePrinter.sampleRate * Self.historySeconds), Segmenter.windowLength)
        if history.count > kept * 3 / 2 {
            historyStart += history.count - kept
            history.removeFirst(history.count - kept)
        }
    }

    /// Ends the audio: the last of it is told apart too, in a window that ends with it, so the last words have a
    /// speaker.
    func finish() {
        let end = historyStart + history.count
        let lastEnd = nextWindow - SpeakerTurns.windowStep + Segmenter.windowLength
        if end > 0, nextWindow == 0 || lastEnd < end {
            if end < Segmenter.windowLength {
                history += [Float](repeating: 0, count: Segmenter.windowLength - end)
            }
            identify(at: max(end - Segmenter.windowLength, 0))
        }
        collectClips(through: Double(end) / VoicePrinter.sampleRate, atTheEnd: true)
        lock.withLock { hasEnded = true }
    }

    /// Returns once who spoke up to `time` is settled: the windows have gone `settleSeconds` past it, or the audio has
    /// ended.
    func settle(through time: Double) async {
        while !Task.isCancelled, !lock.withLock({ hasEnded || segmentedThrough >= time + Self.settleSeconds }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Tells who talks in the window from `start`, and prints each of them.
    private func identify(at start: Int) {
        let window = history[(start - historyStart)..<(start - historyStart + Segmenter.windowLength)]
        let seconds = Double(start) / VoicePrinter.sampleRate
        defer {
            lock.withLock { segmentedThrough = seconds + Double(Segmenter.windowLength) / VoicePrinter.sampleRate }
        }
        var frames: [Talkers]
        var prints: [SpeakerTurns.Print?]
        do {
            frames =
                Self.isSilent(window)
                ? Array(repeating: [], count: Segmenter.frameCount) : try segmenter.segment(window)
            frames = leavingOutTheOtherChannel(frames, from: seconds)
            let printFrames = frames.contains { !$0.isEmpty } ? printer.frames(of: window) : []
            prints = try (0..<Segmenter.people).map { try print(person: $0, from: printFrames, frames: frames) }
        } catch {
            if !hasWarnedAboutPrints {
                hasWarnedAboutPrints = true
                warn("cannot tell voices apart: \(error.localizedDescription)")
            }
            return
        }
        recordSpeech(frames, from: seconds)
        lock.withLock {
            turns.add(SpeakerTurns.Window(start: start, frames: frames), prints: prints)
            recognize()
        }
        collectClips(through: Double(start + SpeakerTurns.windowStep) / VoicePrinter.sampleRate)
    }

    /// The print of a window's person, of the window's `printFrames`, from those they talk alone in, or, if those are
    /// too few, from all they say.
    private func print(person: Int, from printFrames: [[Float]], frames: [Talkers]) throws -> SpeakerTurns.Print? {
        let frameSeconds = Double(Segmenter.frameStep) / VoicePrinter.sampleRate
        let alone = frames.map { $0 == .person(person) }
        let talking = frames.map { $0.contains(.person(person)) }
        let (aloneSeconds, talkingSeconds) = (
            Double(alone.count(where: { $0 })) * frameSeconds, Double(talking.count(where: { $0 })) * frameSeconds
        )
        let isShort = aloneSeconds < Self.aloneSeconds
        guard talkingSeconds >= Self.shortestTalk else { return nil }
        let chosen = !isShort || aloneSeconds >= Self.shortestTalk ? alone : talking
        let kept = printFrames.indices.filter { chosen[Self.segmentationFrame(ofPrintFrame: $0)] }.map {
            printFrames[$0]
        }
        guard !kept.isEmpty else { return nil }
        return SpeakerTurns.Print(print: try printer.voicePrint(of: kept), isShort: isShort)
    }

    private static func isSilent(_ window: ArraySlice<Float>) -> Bool {
        let block = Int(blockSeconds * VoicePrinter.sampleRate)
        let threshold = pow(10, silence / 10) * Float(block)
        return stride(from: window.startIndex, to: window.endIndex, by: block).allSatisfy { start in
            vDSP.sumOfSquares(window[start..<min(start + block, window.endIndex)]) < threshold
        }
    }

    /// The window's segmentation frame a print frame is in the middle of.
    static func segmentationFrame(ofPrintFrame index: Int) -> Int {
        let center = index * VoicePrinter.hopLength + VoicePrinter.frameLength / 2
        let frame = Int((Double(center - Segmenter.frameCenter) / Double(Segmenter.frameStep)).rounded())
        return min(max(frame, 0), Segmenter.frameCount - 1)
    }

    /// On your microphone, nobody talks while the system audio has speech: it may be the speakers playing it.
    private func leavingOutTheOtherChannel(_ frames: [Talkers], from start: Double) -> [Talkers] {
        guard let otherSpeechTimes else { return frames }
        let end = start + Double(Segmenter.windowLength) / VoicePrinter.sampleRate
        let spans = otherSpeechTimes.spans(from: start, to: end)
        guard !spans.isEmpty else { return frames }
        return frames.indices.map { index in
            let time = start + Segmenter.time(ofFrame: index)
            return spans.contains { $0.start <= time && time < $0.end } ? [] : frames[index]
        }
    }

    /// Tells `speechTimes` when anyone talked in the window.
    private func recordSpeech(_ frames: [Talkers], from start: Double) {
        guard let speechTimes else { return }
        let half = Double(Segmenter.frameStep) / VoicePrinter.sampleRate / 2
        var run: (start: Double, end: Double)?
        for (index, talkers) in frames.enumerated() {
            let time = start + Segmenter.time(ofFrame: index)
            if talkers.isEmpty {
                if let current = run { speechTimes.add(from: current.start, to: current.end) }
                run = nil
            } else {
                run = (run?.start ?? time - half, time + half)
            }
        }
        if let run { speechTimes.add(from: run.start, to: run.end) }
    }

    /// Runs a database change, warning the first time one fails.
    func remember(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            guard !hasWarned else { return }
            hasWarned = true
            warn("speakers are not being remembered: \(error.localizedDescription)")
        }
    }
}

extension [Int: Double] {
    /// Whoever talks the longest; of those who talk as long, the first heard.
    var loudest: Int? { self.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key }
}

/// When a channel had speech, as its identifier heard it, for the one on another channel to leave that time out.
final class SpeechTimes: @unchecked Sendable {
    /// How long it is remembered.
    private static let memorySeconds = 60.0
    private let lock = NSLock()
    private var spans: [(start: Double, end: Double)] = []

    func add(from start: Double, to end: Double) {
        lock.withLock {
            spans.append((start, end))
            spans.removeAll { $0.end < end - Self.memorySeconds }
        }
    }

    /// When there was speech between `start` and `end`.
    func spans(from start: Double, to end: Double) -> [(start: Double, end: Double)] {
        lock.withLock { spans.filter { $0.end > start && $0.start < end } }
    }
}
