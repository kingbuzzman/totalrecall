import Accelerate
import Foundation

/// Who this call's speakers are in the database: recognized as someone heard before, as the call goes on and once it
/// is over, and, once it is over, remembered if they are new.
extension SpeakerIdentifier {
    /// Someone heard before sounds this alike from one call to the next; this call's speaker needs `settledPrints` to
    /// be sure enough of, and a stricter `sameVoiceFromFewPrints` until then.
    static let sameVoice: Float = 0.45
    static let sameVoiceFromFewPrints: Float = 0.4
    static let settledPrints = 4
    /// The voice heard the most on your microphone is remembered as you once it has this many prints, about 50 s of
    /// speech, and at least twice as many as anyone else there.
    static let settledYou = Int(50 / secondsPerPrint)
    /// How many prints of someone's voice from earlier calls count against this call's, which may sound different.
    static let rememberedPrints = 100
    /// Someone is remembered only if at least this share of their talking was in lines of the transcript: most of
    /// someone talking is, and little of music, or a sound, that a word was said over now and then.
    static let spokenShare = 1.0 / 3
    /// Saved voices this alike may well be one person, heard as two: `transcribe speakers` says so.
    static let soundAlike: Float = 0.5
    /// A clip is kept for someone only if its print is clearly theirs: within `clipLimit` of their voice, and
    /// `clipMargin` further from everyone else's. Benchmarked on real meetings, one person's 5 s prints, as a clip is
    /// at least, are within 0.32 of their voice 95% of the time, and different people at least 0.73 apart.
    static let clipLimit: Float = 0.40
    static let clipMargin: Float = 0.20

    /// On your microphone, which speaker is you: whoever is recognized as you; if you have never been remembered,
    /// whoever has been heard the most.
    var you: Int? {
        guard isYours else { return nil }
        if let known = recognized.first(where: { $0.value.isYou })?.key { return known }
        guard !heardBefore.contains(where: \.isYou) else { return nil }
        return turns.printCounts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
    }

    /// Who of those heard before each speaker is, as they sound so far: whoever they are nearest, within `sameVoice`,
    /// the closest first, each person one speaker at most. Called under the lock.
    func recognize() {
        let counts = turns.printCounts
        var pairs: [(speaker: Int, voice: SpeakerDatabase.Voice, distance: Float)] = []
        for (speaker, center) in turns.centers {
            let limit = counts[speaker, default: 0] >= Self.settledPrints ? Self.sameVoice : Self.sameVoiceFromFewPrints
            for voice in heardBefore {
                let distance = voiceDistance(voice.print, center)
                if distance < limit { pairs.append((speaker, voice, distance)) }
            }
        }
        recognized = [:]
        var people: Set<Int> = []
        for pair in pairs.sorted(by: { $0.distance < $1.distance })
        where recognized[pair.speaker] == nil && !people.contains(pair.voice.person) {
            recognized[pair.speaker] = pair.voice
            people.insert(pair.voice.person)
        }
    }

    /// Once the call is over, and every line has said who spoke it: sorts every print again (`SpeakerTurns.conclude`),
    /// recognizes each speaker as someone heard before, or, if they said words and a clip of them was kept, remembers
    /// them as someone new; keeps their clips, and you as you once that is clear. From then on, `parts(of:)` goes by it.
    func conclude() {
        lock.withLock {
            turns.conclude()
            recognize()
            guard database != nil else { return }
            let saidWords = speakersWhoSaidWords()
            let centers = turns.centers
            let counts = turns.printCounts
            let clipsOf = Dictionary(grouping: clips.clips) { owner(of: $0.print, among: centers) }
            var saved: [Int: SpeakerDatabase.Voice] = [:]
            for (speaker, center) in centers.sorted(by: { $0.key < $1.key }) {
                remember {
                    saved[speaker] = try save(
                        speaker,
                        center: center,
                        prints: counts[speaker] ?? 0,
                        clips: clipsOf[speaker] ?? [],
                        saidWords: saidWords.contains(speaker)
                    )
                }
            }
            rememberYou(among: &saved, counts: counts)
            let you = self.you
            for speaker in centers.keys {
                let voice = saved[speaker]
                finalNames[speaker] =
                    if let given = voice?.name {
                        given
                    } else if speaker == you || voice?.isYou == true || isYours && voice == nil {
                        Speaker.you.rawValue
                    } else {
                        "\(name) \(voice.map { String($0.person) } ?? Self.letter(speaker))"
                    }
            }
        }
    }

    /// Brings a speaker's voice in the database up to date with this call's prints, if they were recognized; else
    /// remembers them as someone new, if they `saidWords` and have `clips`. Keeps their clips, and returns their voice.
    private func save(
        _ speaker: Int,
        center: [Float],
        prints: Int,
        clips: [ClipCollector.Clip],
        saidWords: Bool
    ) throws -> SpeakerDatabase.Voice? {
        guard let database else { return nil }
        var voice = recognized[speaker]
        if let known = voice {
            let weight = Float(min(known.prints, Self.rememberedPrints))
            let average = zip(known.print, center).map { ($0 * weight + $1 * Float(prints)) / (weight + Float(prints)) }
            // Merged or forgotten with `transcribe speakers` meanwhile: they are new again.
            if try !database.update(known.id, print: average, prints: known.prints + prints) { voice = nil }
        }
        if voice == nil {
            guard !clips.isEmpty, saidWords else { return nil }
            voice = try database.addPerson(print: center, prints: prints)
        }
        guard let id = voice?.id else { return nil }
        for clip in clips { try database.addClip(clip.audio, seconds: clip.seconds, print: clip.print, to: id) }
        return try database.voice(id)
    }

    /// The speakers of whose talking at least `spokenShare` was in lines of the transcript.
    private func speakersWhoSaidWords() -> Set<Int> {
        let end = Double(turns.windows.last.map { $0.start + Segmenter.windowLength } ?? 0) / VoicePrinter.sampleRate
        let talking = turns.talkTime(from: 0, to: end)
        var spoken: [Int: Double] = [:]
        for line in lines {
            for (speaker, time) in turns.talkTime(from: line.start, to: line.end) {
                spoken[speaker, default: 0] += time
            }
        }
        return Set(spoken.filter { $0.value > 0 && $0.value >= (talking[$0.key] ?? 0) * Self.spokenShare }.keys)
    }

    /// Whose a clip is, by its print: someone's whose voice it is clearly, if anyone's.
    private func owner(of print: [Float], among centers: [Int: [Float]]) -> Int? {
        let distances = centers.map { ($0.key, voiceDistance(print, $0.value)) }.sorted { $0.1 < $1.1 }
        guard let nearest = distances.first, nearest.1 <= Self.clipLimit,
            (distances.dropFirst().first?.1 ?? .infinity) - nearest.1 >= Self.clipMargin
        else { return nil }
        return nearest.0
    }

    /// On your microphone, remembers you as you once it is clear who you are, so someone else who happens to speak
    /// first is not.
    private func rememberYou(among saved: inout [Int: SpeakerDatabase.Voice], counts: [Int: Int]) {
        guard let you, let voice = saved[you], !voice.isYou, let yours = counts[you], yours >= Self.settledYou,
            counts.allSatisfy({ $0.key == you || 2 * $0.value <= yours })
        else { return }
        remember {
            _ = try database?.markAsYou(voice.id)
            saved[you] = try database?.voice(voice.id) ?? voice
        }
    }
}
