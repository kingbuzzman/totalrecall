import AVFoundation
import Foundation

/// Tells the people on one channel apart by their voices (`--identify-speakers`). Every `hopSeconds` it takes a print
/// of the last `windowSeconds`, and a line of the transcript goes to whoever most of its time was spoken by. With a
/// database, everyone heard is in it from the moment they are first told apart, and their voice is saved as it is
/// learned: someone heard on an earlier call is recognized as them and keeps their number ("Them 3"), or their name.
/// Without one, people are numbered in the order this call first hears them. On your microphone, the voice heard the
/// most is you, unless your voice from an earlier call is heard: others in the room are numbered like everyone else.
/// Once that is clear, your voice is saved as you, and known as "You" wherever else it is heard, such as on a
/// recording without totalrecall's channel split. Audio comes in through `append` and `finish` from one task while the transcribers ask `speaker(from:to:)` from theirs, so what it has worked out, and
/// the database, are guarded by a lock.
final class SpeakerIdentifier: @unchecked Sendable {
    static let windowSeconds = 3.0
    static let hopSeconds = 1.5
    /// Until anyone has been heard, a window with this little speech will do, and what has come in of the first one
    /// is tried every `firstTrySeconds`, so the first words have a speaker too.
    static let firstSpeech = 1.0 / 3
    static let firstTrySeconds = 0.5
    /// Someone heard before sounds this alike from one call to the next; this call's speaker needs `settledPrints` to
    /// be sure enough of, and a stricter `sameVoiceFromFewPrints` until then.
    static let sameVoice: Float = 0.45
    static let sameVoiceFromFewPrints: Float = 0.4
    static let settledPrints = 4
    /// The voice heard the most on your microphone is saved as you once it has this many prints, about 30 s of speech,
    /// and at least twice as many as anyone else there.
    static let settledYou = 20
    /// How many prints of someone's voice from earlier calls count against this call's, which may sound different.
    static let rememberedPrints = 100
    /// Samples of the speech of someone with no name yet, to tell who they are by, are kept from stretches at least this
    /// long where they were sure to be speaking, and at most this much of each.
    static let shortestSample = 2.0
    static let longestSample = 15.0
    /// Who spoke a stretch is taken as decided this many prints after it, as someone new is recognized in a few.
    static let sampleDelay = 4
    /// How much of the audio is kept, to take samples from.
    private static let historySeconds = 40.0
    /// How much further than a line the audio is heard before saying who spoke it: enough for someone new to be
    /// recognized, from the windows that follow their first words.
    static let settleSeconds = windowSeconds + hopSeconds

    private let name: String
    private let isYours: Bool
    private let resampler: VoiceResampler
    private let printer: any VoicePrinting
    private let windowFrames = Int(VoicePrinter.sampleRate * windowSeconds)
    private let hopFrames = Int(VoicePrinter.sampleRate * hopSeconds)
    /// The audio not yet printed, at `VoicePrinter.sampleRate`, and where in the audio it starts; only `append` and
    /// `finish` touch them.
    private var pending: [Float] = []
    private var pendingStart = 0
    /// Until anyone has been heard: where in `pending` the first words were last tried.
    private var hasHeardAnyone = false
    private var triedFirst = 0
    /// The last of the audio, from `historyStart` in it, for samples; only `append` and `finish` touch them.
    private var history: [Float] = []
    private var historyStart = 0
    /// How many prints have been looked at for samples, and the stretch of someone's speech going on at the last.
    private var decidedPrints = 0
    private var stretch: (speaker: Int, start: Double, end: Double)?
    private let lock = NSLock()
    private var voices: VoiceClusters
    /// The time each of `voices.labels` covers, in seconds from the start of the audio.
    private var spans: [(start: Double, end: Double)] = []
    private let database: SpeakerDatabase?
    /// When this channel had speech, and when the other one did: on your microphone, what it heard while the system
    /// audio had speech is left out, as it may be the speakers playing it.
    private let speechTimes: SpeechTimes?
    private let otherSpeechTimes: SpeechTimes?
    private let warn: (String) -> Void
    private var hasWarned = false
    private var hasWarnedAboutPrints = false
    /// How much of the audio has come in, in seconds, and whether it has ended.
    private var heardSeconds = 0.0
    private var hasEnded = false
    /// Who was in the database before this call, by number.
    private var heardBefore: [SpeakerDatabase.Speaker] = []
    /// Who in the database each of this call's speakers is, by their number in `voices`.
    private var people: [Int: Person] = [:]
    /// How many prints of each of this call's speakers have been saved.
    private var savedPrints: [Int: Int] = [:]

    private struct Person {
        let id: Int
        /// Added on this call, rather than heard before.
        let isNew: Bool
        /// Their voice as it was before this call.
        let voice: [Float]
        let prints: Int
        /// Saved as you.
        var isYou: Bool
    }

    /// `name` is what the speakers are called, before their number; `isYours` is for your microphone; `printer` makes
    /// the voice prints, at `VoicePrinter.sampleRate`. `speechTimes` is told when there was speech; the audio from when
    /// `otherSpeechTimes` had some is left out, so it has to have heard it first. `warn` is told, once each, if the
    /// database cannot be read or written, and if voices cannot be printed: people are then not remembered, or not
    /// told apart. Throws for audio it cannot tell voices apart in.
    init(
        name: String,
        isYours: Bool = false,
        sampleRate: Double,
        printer: any VoicePrinting,
        database: SpeakerDatabase? = nil,
        speechTimes: SpeechTimes? = nil,
        otherSpeechTimes: SpeechTimes? = nil,
        warn: @escaping (String) -> Void = { _ in }
    ) throws {
        resampler = try VoiceResampler(sampleRate: sampleRate)
        self.printer = printer
        self.name = name
        self.isYours = isYours
        voices = VoiceClusters()
        self.database = database
        self.speechTimes = speechTimes
        self.otherSpeechTimes = otherSpeechTimes
        self.warn = warn
        remember { heardBefore = try database?.speakers() ?? [] }
    }

    func append(_ samples: [Float]) {
        let resampled = resampler.resample(samples)
        pending += resampled
        history += resampled
        let kept = Int(VoicePrinter.sampleRate * Self.historySeconds)
        if history.count > kept * 3 / 2 {
            historyStart += history.count - kept
            history.removeFirst(history.count - kept)
        }
        if !hasHeardAnyone, pending.count < windowFrames,
            pending.count - triedFirst >= Int(VoicePrinter.sampleRate * Self.firstTrySeconds)
        {
            triedFirst = pending.count
            identify(pending[...])
        }
        while pending.count >= windowFrames {
            identify(pending[..<windowFrames])
            pending.removeFirst(hopFrames)
            pendingStart += hopFrames
            triedFirst = max(0, triedFirst - hopFrames)
        }
        let heard = Double(pendingStart + pending.count) / VoicePrinter.sampleRate
        lock.withLock { heardSeconds = heard }
    }

    /// Ends the audio: what came after the last window is told apart too, so the last words have a speaker.
    func finish() {
        if pending.count > windowFrames - hopFrames { identify(pending[...]) }
        pending = []
        takeSamples(atTheEnd: true)
        lock.withLock { hasEnded = true }
    }

    /// Returns once who spoke up to `time` is settled: the audio has gone `settleSeconds` past it, or it has ended.
    func settle(through time: Double) async {
        while !Task.isCancelled, !lock.withLock({ hasEnded || heardSeconds >= time + Self.settleSeconds }) {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func identify(_ window: ArraySlice<Float>) {
        let rate = VoicePrinter.sampleRate
        let span = (start: Double(pendingStart) / rate, end: Double(pendingStart + window.count) / rate)
        if otherSpeechTimes?.hadSpeech(from: span.start, to: span.end) ?? false { return }
        let minimumSpeech = lock.withLock { voices.speakers.isEmpty } ? Self.firstSpeech : VoicePrinter.minimumSpeech
        let print: [Float]?
        do {
            print = try printer.voicePrint(of: window, minimumSpeech: minimumSpeech)
        } catch {
            if !hasWarnedAboutPrints {
                hasWarnedAboutPrints = true
                warn("cannot tell voices apart: \(error.localizedDescription)")
            }
            return
        }
        guard let print else { return }
        speechTimes?.add(from: span.start, to: span.end)
        hasHeardAnyone = true
        lock.withLock {
            voices.add(print)
            spans.append((span.start, span.end))
            save()
        }
        takeSamples(atTheEnd: false)
    }

    /// Keeps a sample of each stretch of someone's speech, once who spoke it is decided: prints one after the other,
    /// each sure to be theirs. Only for someone with no name, and only with a database to keep them in.
    private func takeSamples(atTheEnd: Bool) {
        guard database != nil else { return }
        var finished: [(speaker: Int, start: Double, end: Double)] = []
        lock.withLock {
            let decided = atTheEnd ? voices.labels.count : voices.labels.count - Self.sampleDelay
            while decidedPrints < decided {
                let (speaker, isSure, span) = (
                    voices.labels[decidedPrints], voices.isSure[decidedPrints], spans[decidedPrints]
                )
                decidedPrints += 1
                if let current = stretch, current.speaker == speaker, isSure, span.start <= current.end {
                    stretch?.end = max(current.end, span.end)
                    continue
                }
                if let current = stretch { finished.append(current) }
                stretch = isSure ? (speaker, span.start, span.end) : nil
            }
            if atTheEnd, let current = stretch {
                finished.append(current)
                stretch = nil
            }
        }
        for stretch in finished { keepSample(of: stretch) }
    }

    private func keepSample(of stretch: (speaker: Int, start: Double, end: Double)) {
        let seconds = min(stretch.end - stretch.start, Self.longestSample)
        let start = Int(stretch.start * VoicePrinter.sampleRate) - historyStart
        let end = start + Int(seconds * VoicePrinter.sampleRate)
        guard seconds >= Self.shortestSample, start >= 0, end <= history.count, let database else { return }
        lock.withLock {
            guard let id = people[stretch.speaker]?.id else { return }
            remember {
                guard try database.speaker(id)?.name == nil else { return }
                try database.addSample(try m4a(history[start..<end]), seconds: seconds, to: id)
            }
        }
    }

    /// Who spoke the most between `start` and `end`, in seconds from the start of the audio: their name if they have
    /// one, else their number, or just "Them" while they have spoken too little to be saved. Whoever spoke last if
    /// nobody has been heard in that time yet, which happens when the transcriber settles on words before the window
    /// they are in has been printed; nil if nobody has been heard.
    func speaker(from start: Double, to end: Double) -> String? {
        lock.withLock {
            var time: [Int: Double] = [:]
            for (span, speaker) in zip(spans, voices.labels).reversed() {
                if span.end <= start { break }
                let overlap = min(end, span.end) - max(start, span.start)
                if overlap > 0 { time[speaker, default: 0] += overlap }
            }
            // The first heard of any that spoke equally long.
            guard let speaker = time.max(by: { ($0.value, $1.key) < ($1.value, $0.key) })?.key ?? voices.labels.last
            else { return nil }
            // Looked up each time, so a name given while the call goes on is used from then on.
            var saved: SpeakerDatabase.Speaker?
            if let person = people[speaker] { remember { saved = try database?.speaker(person.id) } }
            if let name = saved?.name { return name }
            if speaker == you || saved?.isYou == true { return Speaker.you.rawValue }
            if let person = people[speaker] { return "\(name) \(person.id)" }
            // Not saved yet, as they have hardly spoken: no number to go by from one call to the next, but not you,
            // which on your microphone is what a line with no speaker would say.
            return database == nil ? "\(name) \(speaker)" : name
        }
    }

    /// Brings the database up to date with this call's speakers: someone is added, or recognized as someone heard
    /// before, the moment they are first told apart, and their voice is saved with every print of it.
    private func save() {
        guard let database else { return }
        let speakers = Set(voices.speakers.map(\.number))
        // Folded into someone else, as one person heard two ways at first: someone added for them is taken back out.
        for (number, person) in people where !speakers.contains(number) {
            if person.isNew { remember { _ = try database.forget(person.id) } }
            people[number] = nil
            savedPrints[number] = nil
        }
        for speaker in voices.speakers where savedPrints[speaker.number] != speaker.count {
            remember {
                // Someone new only once they have been heard as long as it takes to tell someone new apart, so a
                // cough or a moment of noise does not stay behind as a speaker.
                let isHeardEnough = speaker.count >= VoiceClusters.newSpeakerPrints
                guard
                    var person = try people[speaker.number] ?? recognize(speaker)
                        ?? (isHeardEnough ? add(speaker, to: database) : nil)
                else { return }
                // Someone taken for new from their first prints may turn out to be someone heard before.
                if person.isNew, speaker.count >= Self.settledPrints, let earlier = try recognize(speaker) {
                    try database.moveSamples(of: person.id, to: earlier.id)
                    _ = try database.forget(person.id)
                    person = earlier
                }
                people[speaker.number] = person
                let weight = Float(min(person.prints, Self.rememberedPrints))
                let total = weight + Float(speaker.count)
                let voice = zip(person.voice, speaker.center).map { ($0 * weight + $1 * Float(speaker.count)) / total }
                // They may have been merged or forgotten with `transcribe speakers` meanwhile: they are new again.
                if try !database.update(person.id, voice: voice, prints: person.prints + speaker.count) {
                    people[speaker.number] = try add(speaker, to: database)
                }
                savedPrints[speaker.number] = speaker.count
            }
        }
        // Not before it is clear who you are, so someone else who happens to speak first is not saved as you.
        guard let you, let person = people[you], !person.isYou,
            let yours = voices.speakers.first(where: { $0.number == you })?.count, yours >= Self.settledYou,
            voices.speakers.allSatisfy({ $0.number == you || 2 * $0.count <= yours })
        else { return }
        remember {
            try database.markAsYou(person.id)
            people[you]?.isYou = true
        }
    }

    /// On your microphone, which of this call's speakers is you: whoever is recognized as you from an earlier call;
    /// if you have never been saved, whoever has been heard the most.
    private var you: Int? {
        guard isYours else { return nil }
        let speakers = Set(voices.speakers.map(\.number))
        if let known = people.first(where: { $0.value.isYou && speakers.contains($0.key) })?.key { return known }
        // Your voice is known, and none of these is it: someone else is talking, and you have not yet.
        guard !heardBefore.contains(where: \.isYou) else { return nil }
        return voices.speakers.max { $0.count < $1.count }?.number
    }

    /// Who of those heard before, and not yet found on this call, this speaker is, if anyone.
    private func recognize(_ speaker: VoiceClusters.Speaker) throws -> Person? {
        let found = Set(people.values.map(\.id))
        let limit = speaker.count >= Self.settledPrints ? Self.sameVoice : Self.sameVoiceFromFewPrints
        let match = heardBefore.filter { !found.contains($0.id) }
            .map { ($0, voiceDistance($0.voice, speaker.center)) }
            .filter { $0.1 < limit }
            .min { $0.1 < $1.1 }?.0
        return match.map { Person(id: $0.id, isNew: false, voice: $0.voice, prints: $0.prints, isYou: $0.isYou) }
    }

    private func add(_ speaker: VoiceClusters.Speaker, to database: SpeakerDatabase) throws -> Person {
        let id = try database.add(voice: speaker.center, prints: speaker.count)
        return Person(id: id, isNew: true, voice: speaker.center, prints: 0, isYou: false)
    }

    /// Runs a database change, warning the first time one fails.
    private func remember(_ change: () throws -> Void) {
        do {
            try change()
        } catch {
            guard !hasWarned else { return }
            hasWarned = true
            warn("speakers are not being remembered: \(error.localizedDescription)")
        }
    }
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

    /// Whether there was speech for at least half of this time.
    func hadSpeech(from start: Double, to end: Double) -> Bool {
        lock.withLock {
            spans.contains { min($0.end, end) - max($0.start, start) >= (end - start) / 2 }
        }
    }
}

/// Sorts voice prints into speakers as they come in. Built for calls, where it is the same few people from start to
/// end: it is slow to decide that someone new is talking. A print that sounds like nobody heard yet still goes to
/// whoever it sounds most like, and is set aside; only once `newSpeakerPrints` of those sound alike, and unlike
/// everyone so far, do they become someone new.
struct VoiceClusters {
    struct Speaker {
        /// From 1, in the order they were first heard.
        let number: Int
        /// The average of their prints, and how far their prints usually are from it.
        var center: [Float]
        var spread: Float
        var count: Int
    }

    /// A print is someone's if it is within `spreadsPerRadius` of their spreads from their center, but always within
    /// `minimumRadius` and never beyond `maximumRadius`: someone heard over a noisy mic would otherwise take in
    /// everyone else too.
    static let spreadsPerRadius: Float = 2
    static let minimumRadius: Float = 0.3
    static let maximumRadius: Float = 0.45
    /// What a new speaker's spread is taken to be until their prints say otherwise.
    static let initialSpread: Float = 0.2
    /// How many prints back a speaker's center and spread follow: their voice drifts a little through a call.
    static let memory = 30
    /// Someone keeps speaking unless another speaker sounds this much closer.
    static let stickiness: Float = 0.05
    /// How many prints back those that sound like nobody are kept, to find someone new among: about 30 s.
    static let unexplainedPrints = 20
    /// How many alike prints, within `alike` of each other, make someone new: a few seconds of their speech.
    static let newSpeakerPrints = 3
    static let alike: Float = 0.45
    /// How far someone new must sound from everyone so far: at least `minimumGap`, and `spreadsPerGap` of the spread
    /// of their own prints, so a person whose voice varies is not mistaken for several people.
    static let minimumGap: Float = 0.45
    static let spreadsPerGap: Float = 1.6
    /// Two speakers who come to sound this alike are one person heard two ways at first; they become the one heard first.
    static let sameSpeaker: Float = 0.3

    /// The speaker number of each print, in the order they were added. A print set aside as sounding like nobody yet
    /// changes to someone new once they are recognized.
    private(set) var labels: [Int] = []
    /// For each print, whether it is sure to be its speaker's: within their reach, or one of those that made someone
    /// new; else it only sounds more like them than anyone.
    private(set) var isSure: [Bool] = []
    private(set) var speakers: [Speaker] = []
    /// The prints that sounded like nobody, with their index in `labels`.
    private var unexplained: [(index: Int, print: [Float])] = []
    /// The index in `speakers` of whoever was heard last.
    private var current: Int?

    mutating func add(_ print: [Float]) {
        guard !speakers.isEmpty else {
            speakers.append(Speaker(number: 1, center: print, spread: Self.initialSpread, count: 1))
            labels.append(1)
            isSure.append(true)
            current = 0
            return
        }
        let distances = speakers.map { voiceDistance(print, $0.center) }
        var nearest = distances.indices.min { distances[$0] < distances[$1] }!
        if let current, distances[current] <= distances[nearest] + Self.stickiness { nearest = current }
        labels.append(speakers[nearest].number)
        isSure.append(false)
        current = nearest
        let speaker = speakers[nearest]
        // A center from few prints is still rough, so prints may be further from it.
        let radius =
            min(max(Self.spreadsPerRadius * speaker.spread, Self.minimumRadius), Self.maximumRadius)
            * (1 + 1 / Float(speaker.count)).squareRoot()
        if distances[nearest] <= radius {
            isSure[isSure.count - 1] = true
            learn(print, distance: distances[nearest], for: nearest)
        } else {
            unexplained.append((labels.count - 1, print))
            // Only the recent ones: someone new is heard over a few seconds, not pieced together from odd moments
            // of different people spread over the call.
            unexplained.removeAll { labels.count - $0.index > Self.unexplainedPrints }
            recognizeNewSpeaker()
        }
    }

    /// Moves the speaker's center and spread toward a print of theirs, and folds them into anyone they now sound
    /// the same as.
    private mutating func learn(_ print: [Float], distance: Float, for index: Int) {
        let weight = 1 / Float(min(speakers[index].count + 1, Self.memory))
        speakers[index].spread += (distance - speakers[index].spread) * weight
        for element in print.indices {
            speakers[index].center[element] += (print[element] - speakers[index].center[element]) * weight
        }
        speakers[index].count += 1
        guard
            let other = speakers.indices.first(where: {
                $0 != index && voiceDistance(speakers[$0].center, speakers[index].center) < Self.sameSpeaker
            })
        else { return }
        let (keep, drop) = (min(index, other), max(index, other))
        let (kept, dropped) = (speakers[keep], speakers[drop])
        let total = Float(kept.count + dropped.count)
        speakers[keep].center = zip(kept.center, dropped.center).map {
            ($0 * Float(kept.count) + $1 * Float(dropped.count)) / total
        }
        speakers[keep].count = kept.count + dropped.count
        speakers.remove(at: drop)
        labels = labels.map { $0 == dropped.number ? kept.number : $0 }
        current = keep
    }

    /// Makes someone new of the largest group of alike prints that sound like nobody, if it is large enough and
    /// sounds unlike everyone so far.
    private mutating func recognizeNewSpeaker() {
        let groups = unexplained.map { member in
            unexplained.filter { voiceDistance($0.print, member.print) <= Self.alike }
        }
        guard let group = groups.max(by: { $0.count < $1.count }), group.count >= Self.newSpeakerPrints else { return }
        var center = [Float](repeating: 0, count: group[0].print.count)
        for member in group {
            for element in center.indices { center[element] += member.print[element] / Float(group.count) }
        }
        let spread = group.map { voiceDistance($0.print, center) }.reduce(0, +) / Float(group.count)
        let gap = max(Self.minimumGap, Self.spreadsPerGap * spread)
        guard speakers.allSatisfy({ voiceDistance(center, $0.center) > gap }) else { return }
        let number = (speakers.map(\.number).max() ?? 0) + 1
        speakers.append(Speaker(number: number, center: center, spread: Self.initialSpread, count: group.count))
        let members = Set(group.map(\.index))
        for index in members {
            labels[index] = number
            isSure[index] = true
        }
        unexplained.removeAll { members.contains($0.index) }
        current = speakers.count - 1
    }
}

/// Audio at `VoicePrinter.sampleRate` as the bytes of a .m4a file: AAC, which macOS plays anywhere.
func m4a(_ samples: ArraySlice<Float>) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appending(path: "speaker-sample-\(UUID()).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: VoicePrinter.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
    else { throw TranscribeError("cannot make a sample of \(samples.count) frames") }
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
    try file.write(from: buffer)
    file.close()
    return try Data(contentsOf: url)
}
