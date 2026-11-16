import Foundation
import Shared
import Synchronization
import Testing

@testable import Transcribe

/// The identifier's own work, with made-up voices and stand-ins for the speaker models: audio at a steady level is one
/// voice, `level(1)` one person and `level(2)` another, so what it does with them is the same every run.
struct SpeakerIdentifierTests {
    private static let rate = VoicePrinter.sampleRate

    @Test func namesPeopleInTheOrderTheyAreFirstHeard() throws {
        let identifier = try makeIdentifier()

        feed(voice(1, seconds: 12) + voice(2, seconds: 12) + voice(1, seconds: 8), to: identifier)
        identifier.finish()

        #expect(label(from: 2, to: 10, by: identifier) == ["Them 1"])
        #expect(label(from: 14, to: 22, by: identifier) == ["Them 2"])
        #expect(label(from: 26, to: 31, by: identifier) == ["Them 1"])
    }

    @Test func splitsALineWhereWhoSpeaksChanges() throws {
        let identifier = try makeIdentifier()
        feed(voice(1, seconds: 12) + voice(2, seconds: 12), to: identifier)
        identifier.finish()

        let parts = identifier.parts(of: line(from: 8, to: 16))

        #expect(parts.map(\.voice) == ["Them 1", "Them 2"])
        // The first keeps the line's start, which a line held back to say who spoke it goes by.
        #expect(parts.map(\.start) == [8, 12])
        #expect(parts.map(\.lineStart) == [8, 8])
        #expect(
            parts.map(\.text) == [
                "w8.0 w8.5 w9.0 w9.5 w10.0 w10.5 w11.0 w11.5", "w12.0 w12.5 w13.0 w13.5 w14.0 w14.5 w15.0 w15.5",
            ]
        )
    }

    @Test func takesATurnTooShortToBeSureOfForTheSpeakerAroundIt() throws {
        let identifier = try makeIdentifier()
        feed(voice(1, seconds: 12) + voice(2, seconds: 12) + voice(1, seconds: 12), to: identifier)
        identifier.finish()

        // Its last word, in the second person's time, is too little of them to split the line for.
        #expect(label(from: 9, to: 12.5, by: identifier) == ["Them 1"])
    }

    @Test func goesByWhoeverTalksAroundALineNobodyIsHeardSaying() throws {
        let identifier = try makeIdentifier()
        feed(voice(1, seconds: 12) + voice(0, seconds: 1) + voice(2, seconds: 12), to: identifier)
        identifier.finish()

        #expect(label(from: 12.1, to: 12.4, by: identifier, words: 1) == ["Them 1"])
    }

    @Test func namesNobodyWhenNobodyIsHeard() throws {
        let identifier = try makeIdentifier()
        feed(voice(0, seconds: 15), to: identifier)
        identifier.finish()

        #expect(label(from: 2, to: 6, by: identifier) == [nil])
    }

    @Test func tellsWhoSpokeInACallShorterThanAWindow() throws {
        let identifier = try makeIdentifier()

        feed(voice(1, seconds: 4), to: identifier)
        identifier.finish()

        #expect(label(from: 0.5, to: 3.5, by: identifier) == ["Them 1"])
    }

    @Test func resamplesAudioToTheRateItHearsAt() throws {
        let identifier = try makeIdentifier(sampleRate: 48_000)

        feed(voice(1, seconds: 12, rate: 48_000) + voice(2, seconds: 12, rate: 48_000), to: identifier, rate: 48_000)
        identifier.finish()

        #expect(label(from: 2, to: 10, by: identifier) == ["Them 1"])
        #expect(label(from: 14, to: 22, by: identifier) == ["Them 2"])
    }

    @Test func asksTheModelsNothingOfSilence() throws {
        let segmenter = StandInSegmenter()
        let identifier = try makeIdentifier(segmenter: segmenter)

        feed(voice(0, seconds: 30), to: identifier)
        #expect(segmenter.calls.withLock { $0 } == 0)

        feed(voice(1, seconds: 10), to: identifier)
        #expect(segmenter.calls.withLock { $0 } > 0)
    }

    @Test func settlesWhoSpokeALineOnceTheWindowsGoFarEnoughPastIt() async throws {
        let identifier = try makeIdentifier()
        feed(voice(1, seconds: 12), to: identifier)
        let settled = Mutex(false)

        await identifier.settle(through: 4)
        let waiting = Task {
            await identifier.settle(through: 9)
            settled.withLock { $0 = true }
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(!settled.withLock { $0 })

        feed(voice(1, seconds: 4), to: identifier)
        await waiting.value
        #expect(settled.withLock { $0 })
    }

    @Test func settlesEverythingOnceTheAudioEnds() async throws {
        let identifier = try makeIdentifier()
        feed(voice(1, seconds: 3), to: identifier)

        identifier.finish()

        await identifier.settle(through: 1_000)
    }

    @Test func remembersSomeoneNewOnceTheCallIsOverWithAClipOfThem() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(database: database)
        feed(voice(1, seconds: 24), to: identifier)
        say(from: 0, to: 24, to: identifier)
        identifier.finish()
        #expect(try database.people().isEmpty)
        #expect(label(from: 2, to: 10, by: identifier) == ["Them A"])

        identifier.conclude()

        let person = try #require(try database.people().first)
        #expect(try database.people().count == 1)
        #expect(try !database.clips(of: person.id).isEmpty)
        #expect(label(from: 2, to: 10, by: identifier) == ["Them \(person.id)"])
    }

    @Test func remembersNobodyWithoutAClipOfThemAlone() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(database: database)
        // Taking turns every 3 s: never 5 s of one of them alone.
        feed((0..<10).flatMap { voice($0 % 2 + 1, seconds: 3) }, to: identifier)
        say(from: 0, to: 30, to: identifier)
        identifier.finish()

        identifier.conclude()

        #expect(try database.people().isEmpty)
        #expect(label(from: 0.5, to: 2.5, by: identifier) == ["Them A"])
        #expect(label(from: 3.5, to: 5.5, by: identifier) == ["Them B"])
    }

    @Test func remembersOnlyThoseWhoSaidWords() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(database: database)
        feed(voice(1, seconds: 24), to: identifier)
        identifier.finish()

        identifier.conclude()

        #expect(try database.people().isEmpty)
    }

    @Test func recognizesSomeoneFromAnEarlierCallAsTheCallGoesOn() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let known = try database.addPerson(print: StandInPrinter.print(of: 2), prints: 10)
        let identifier = try makeIdentifier(database: database)

        feed(voice(2, seconds: 12), to: identifier)

        #expect(label(from: 2, to: 6, by: identifier) == ["Them \(known.person)"])
        identifier.finish()
        identifier.conclude()
        #expect(label(from: 2, to: 6, by: identifier) == ["Them \(known.person)"])
        #expect(try database.voice(known.id)?.prints ?? 0 > 10)
    }

    @Test func goesByANameGivenWhileTheCallGoesOn() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let known = try database.addPerson(print: StandInPrinter.print(of: 2), prints: 10)
        let identifier = try makeIdentifier(database: database)
        feed(voice(2, seconds: 12), to: identifier)

        _ = try database.rename(known.person, to: "Ada")

        #expect(label(from: 2, to: 6, by: identifier) == ["Ada"])
    }

    @Test func theVoiceHeardMostOnYourMicrophoneIsYou() throws {
        let identifier = try makeIdentifier(isYours: true)

        feed(voice(1, seconds: 24) + voice(2, seconds: 12), to: identifier)
        identifier.finish()

        #expect(label(from: 2, to: 10, by: identifier) == ["You"])
        #expect(label(from: 26, to: 34, by: identifier) == ["Them 2"])
    }

    @Test func takesAVoiceOnYourMicrophoneNotRecognizedForYours() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        _ = try database.markAsYou(try database.addPerson(print: StandInPrinter.print(of: 3), prints: 10).id)
        let identifier = try makeIdentifier(isYours: true, database: database)

        feed(voice(1, seconds: 12), to: identifier)

        #expect(label(from: 2, to: 6, by: identifier) == ["You"])
    }

    @Test func remembersYouOnceItIsClearWhoYouAre() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(isYours: true, database: database)
        let seconds = Double(SpeakerIdentifier.settledYou + 2) * SpeakerIdentifier.secondsPerPrint
        feed(voice(1, seconds: seconds), to: identifier)
        say(from: 0, to: seconds, to: identifier)
        identifier.finish()

        identifier.conclude()

        #expect(try database.voices().map(\.isYou) == [true])
        #expect(label(from: 2, to: 6, by: identifier) == ["You"])
    }

    @Test func remembersNobodyAsYouWhileItIsNotClearWhoYouAre() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(isYours: true, database: database)
        feed(voice(1, seconds: 24), to: identifier)
        say(from: 0, to: 24, to: identifier)
        identifier.finish()

        identifier.conclude()

        #expect(try database.voices().map(\.isYou) == [false])
        #expect(label(from: 2, to: 6, by: identifier) == ["You"])
    }

    @Test func hearsNobodyOnYourMicrophoneWhileTheSystemAudioHasSpeech() throws {
        let systemSpeech = SpeechTimes()
        let theirs = try makeIdentifier(speechTimes: systemSpeech)
        let yours = try makeIdentifier(isYours: true, otherSpeechTimes: systemSpeech)
        let audio = voice(1, seconds: 15)

        // In the order transcribe feeds them: the system audio first.
        let chunk = Int(Self.rate * chunkSeconds)
        for start in stride(from: 0, to: audio.count, by: chunk) {
            let piece = Array(audio[start..<min(start + chunk, audio.count)])
            theirs.append(piece)
            yours.append(piece)
        }
        theirs.finish()
        yours.finish()

        #expect(label(from: 2, to: 8, by: theirs) == ["Them 1"])
        #expect(label(from: 2, to: 8, by: yours) == [nil])
    }

    @Test func warnsOnceAndGoesOnWhenVoicesCannotBePrinted() async throws {
        let warnings = Mutex<[String]>([])
        let identifier = try SpeakerIdentifier(
            name: "Them",
            sampleRate: Self.rate,
            segmenter: StandInSegmenter(),
            printer: StandInPrinter(fails: true),
            warn: { message in warnings.withLock { $0.append(message) } }
        )

        feed(voice(1, seconds: 30), to: identifier)
        identifier.finish()

        await identifier.settle(through: 10)
        #expect(label(from: 2, to: 6, by: identifier) == [nil])
        #expect(warnings.withLock { $0 }.count == 1)
    }

    @Test func cannotTellVoicesApartInAudioThatIsNotAudio() {
        #expect(throws: MessageError.self) { try makeIdentifier(sampleRate: .nan) }
        #expect(throws: MessageError.self) { try makeIdentifier(sampleRate: 1_000) }
    }

    @Test(arguments: [(1, "A"), (26, "Z"), (27, "AA"), (28, "AB"), (702, "ZZ"), (703, "AAA")])
    func lettersSomeoneNotRemembered(number: Int, letters: String) {
        #expect(SpeakerIdentifier.letter(number) == letters)
    }

    private func makeIdentifier(
        isYours: Bool = false,
        sampleRate: Double = rate,
        segmenter: any SpeakerSegmenting = StandInSegmenter(),
        database: SpeakerDatabase? = nil,
        speechTimes: SpeechTimes? = nil,
        otherSpeechTimes: SpeechTimes? = nil
    ) throws -> SpeakerIdentifier {
        try SpeakerIdentifier(
            name: "Them",
            isYours: isYours,
            sampleRate: sampleRate,
            segmenter: segmenter,
            printer: StandInPrinter(),
            database: database,
            speechTimes: speechTimes,
            otherSpeechTimes: otherSpeechTimes
        )
    }

    /// Audio of made-up voice `number` at a steady level of its own; 0 is silence.
    private func voice(_ number: Int, seconds: Double, rate: Double = rate) -> [Float] {
        [Float](repeating: StandInSegmenter.level(number), count: Int(seconds * rate))
    }

    /// In the chunks transcribe reads.
    private func feed(_ samples: [Float], to identifier: SpeakerIdentifier, rate: Double = rate) {
        let chunk = Int(rate * chunkSeconds)
        for start in stride(from: 0, to: samples.count, by: chunk) {
            identifier.append(Array(samples[start..<min(start + chunk, samples.count)]))
        }
    }

    /// Says lines from `start` to `end`, as the transcriber does, a few seconds each: only someone who says words is
    /// remembered.
    private func say(from start: Double, to end: Double, to identifier: SpeakerIdentifier) {
        for lineStart in stride(from: start, to: end, by: 4) {
            _ = identifier.parts(of: line(from: lineStart, to: min(lineStart + 4, end)))
        }
    }

    /// Who said each part of a line from `start` to `end`.
    private func label(
        from start: Double,
        to end: Double,
        by identifier: SpeakerIdentifier,
        words: Int? = nil
    ) -> [String?] {
        identifier.parts(of: line(from: start, to: end, words: words)).map(\.voice)
    }

    /// A line of their words, one every half second, or `words` of them, each saying when it starts.
    private func line(from start: Double, to end: Double, words: Int? = nil) -> TranscriptUpdate {
        let step = words.map { (end - start) / Double($0) } ?? 0.5
        let timed = stride(from: start, to: end - 0.01, by: step).map { time in
            TimedWord(text: "w\(Double((time * 10).rounded()) / 10) ", start: time, end: min(time + step * 0.8, end))
        }
        var update = TranscriptUpdate(speaker: .them, start: start, text: timed.map(\.text).joined(), isFinal: true)
        update.end = end
        update.words = timed
        return update
    }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-tests-\(UUID())/speakers.db")
    }
}

/// Stands in for the segmentation model: each frame's people are the made-up voices in what it hears, by their level,
/// numbered in the order the window first has them.
final class StandInSegmenter: SpeakerSegmenting, Sendable {
    let calls = Mutex(0)

    static func level(_ voice: Int) -> Float { Float(voice) / 10 }

    /// The made-up voice a sample is of; 0 for none. Resampled audio wobbles a little around its level.
    static func voice(of sample: Float) -> Int { abs(sample) > 0.05 ? Int((abs(sample) * 10).rounded()) : 0 }

    func segment(_ window: ArraySlice<Float>) throws -> [Talkers] {
        calls.withLock { $0 += 1 }
        var people: [Int] = []
        return (0..<Segmenter.frameCount).map { frame in
            let start = window.startIndex + frame * Segmenter.frameStep
            let heard = stride(from: start, to: min(start + 2 * Segmenter.frameCenter, window.endIndex), by: 10)
                .map { Self.voice(of: window[$0]) }
            var talkers: Talkers = []
            for voice in Set(heard) where voice != 0 {
                if !people.contains(voice) { people.append(voice) }
                if let person = people.firstIndex(of: voice), person < Segmenter.people {
                    talkers.insert(.person(person))
                }
            }
            return talkers
        }
    }
}

/// Stands in for the voice print model: each made-up voice's frames print along a direction of their own.
struct StandInPrinter: VoicePrinting {
    var fails = false

    static func print(of voice: Int) -> [Float] { direction(voice) }

    func frames(of samples: ArraySlice<Float>) -> [[Float]] {
        stride(
            from: samples.startIndex,
            through: samples.endIndex - VoicePrinter.frameLength,
            by: VoicePrinter.hopLength
        )
        .map { [samples[$0 + VoicePrinter.frameLength / 2]] }
    }

    func voicePrint(of frames: [[Float]]) throws -> [Float] {
        if fails { throw MessageError("the speaker model failed") }
        var counts = [Int: Int]()
        for frame in frames { counts[StandInSegmenter.voice(of: frame[0]), default: 0] += 1 }
        let most = counts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key ?? 0
        return Self.print(of: most)
    }
}
