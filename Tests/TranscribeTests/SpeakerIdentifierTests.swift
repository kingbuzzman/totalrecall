import Foundation
import Testing

@testable import Transcribe

/// The identifier's own work, with made-up voices and a stand-in for the speaker model: audio at a steady level is one
/// voice, `level(1)` one person and `level(2)` another, so what it does with them is the same every run.
struct SpeakerIdentifierTests {
    private static let rate = VoicePrinter.sampleRate

    @Test func namesPeopleInTheOrderTheyAreFirstHeard() throws {
        let identifier = try makeIdentifier()

        feed(voice(1, seconds: 12) + voice(2, seconds: 12) + voice(1, seconds: 6), to: identifier)

        #expect(identifier.speaker(from: 2, to: 10) == "Them 1")
        #expect(identifier.speaker(from: 15, to: 23) == "Them 2")
        #expect(identifier.speaker(from: 25.5, to: 29.5) == "Them 1")
    }

    @Test func goesByWhoeverSpokeLastUntilTheirWordsHaveBeenPrinted() throws {
        let identifier = try makeIdentifier()

        feed(voice(1, seconds: 6), to: identifier)

        #expect(identifier.speaker(from: 7, to: 8) == "Them 1")
    }

    @Test func tellsWhoSaidTheLastWordsOnceTheAudioEnds() throws {
        let identifier = try makeIdentifier()
        feed(voice(1, seconds: 12) + voice(2, seconds: 12) + voice(1, seconds: 2), to: identifier)
        #expect(identifier.speaker(from: 24.2, to: 26) == "Them 2")

        identifier.finish()

        #expect(identifier.speaker(from: 24.2, to: 26) == "Them 1")
    }

    @Test func namesNobodyBeforeAnyoneHasSpoken() throws {
        let identifier = try makeIdentifier()

        feed(voice(0, seconds: 10), to: identifier)

        #expect(identifier.speaker(from: 0, to: 10) == nil)
    }

    @Test func tellsWhoTheFirstWordsAreFromWithLittleSpeech() throws {
        let identifier = try makeIdentifier()

        feed(voice(0, seconds: 2) + voice(1, seconds: 1), to: identifier)

        #expect(identifier.speaker(from: 2, to: 3) == "Them 1")
    }

    @Test func resamplesAudioToTheRateItPrintsAt() throws {
        let identifier = try makeIdentifier(sampleRate: 48_000)

        feed(voice(1, seconds: 12, rate: 48_000) + voice(2, seconds: 12, rate: 48_000), to: identifier, rate: 48_000)

        #expect(identifier.speaker(from: 2, to: 10) == "Them 1")
        #expect(identifier.speaker(from: 15, to: 23) == "Them 2")
    }

    @Test func savesEveryoneTheMomentTheyAreToldApart() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(database: database)

        feed(voice(1, seconds: 6), to: identifier)
        let first = try database.speakers()
        feed(voice(1, seconds: 6) + voice(2, seconds: 12), to: identifier)

        #expect(first.count == 1)
        let speakers = try database.speakers()
        #expect(speakers.count == 2, "\(speakers.map { ($0.id, $0.prints) })")
        #expect(speakers.first.map { $0.prints > first[0].prints } == true)
        #expect(identifier.speaker(from: 2, to: 10) == "Them \(first[0].id)")
    }

    @Test func recognizesSomeoneFromAnEarlierCall() throws {
        let url = temporaryDatabase()
        feed(
            voice(1, seconds: 12) + voice(2, seconds: 12),
            to: try makeIdentifier(database: try SpeakerDatabase(url: url))
        )
        let database = try SpeakerDatabase(url: url)
        let (first, second) = (try id(0, in: database), try id(1, in: database))

        let identifier = try makeIdentifier(database: database)
        feed(voice(2, seconds: 12) + voice(1, seconds: 12), to: identifier)

        #expect(identifier.speaker(from: 2, to: 10) == "Them \(second)")
        #expect(identifier.speaker(from: 14, to: 22) == "Them \(first)")
        #expect(try database.speakers().count == 2)
    }

    @Test func goesByANameGivenWhileTheCallGoesOn() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(database: database)
        feed(voice(1, seconds: 6), to: identifier)

        _ = try database.rename(try id(0, in: database), to: "Ada")

        #expect(identifier.speaker(from: 2, to: 5) == "Ada")
    }

    @Test func theVoiceHeardMostOnYourMicrophoneIsYou() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(isYours: true, database: database)

        feed(voice(1, seconds: 40) + voice(2, seconds: 12), to: identifier)

        let speakers = try database.speakers()
        #expect(identifier.speaker(from: 2, to: 10) == "You")
        #expect(identifier.speaker(from: 43, to: 50) == "Them \(speakers[1].id)")
        #expect(speakers.map(\.isYou) == [true, false])
    }

    @Test func savesYouOnlyOnceItIsClearWhoYouAre() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(isYours: true, database: database)

        feed(voice(2, seconds: 12) + voice(1, seconds: 20), to: identifier)

        #expect(identifier.speaker(from: 15, to: 30) == "You")
        #expect(identifier.speaker(from: 2, to: 10) == "Them \(try id(0, in: database))")
        #expect(try database.speakers().allSatisfy { !$0.isYou })
    }

    @Test func knowsYouOnYourMicrophoneEvenWhenSomeoneElseTalksMore() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        feed(voice(1, seconds: 40), to: try makeIdentifier(isYours: true, database: database))

        let identifier = try makeIdentifier(isYours: true, database: database)
        feed(voice(2, seconds: 40) + voice(1, seconds: 12), to: identifier)

        #expect(identifier.speaker(from: 2, to: 30) == "Them \(try id(1, in: database))")
        #expect(identifier.speaker(from: 43, to: 50) == "You")
    }

    @Test func takesNothingYourMicrophoneHearsWhileTheSystemAudioHasSpeechForAVoice() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let systemSpeech = SpeechTimes()
        let theirs = try makeIdentifier(database: database, speechTimes: systemSpeech)
        let yours = try makeIdentifier(isYours: true, database: database, otherSpeechTimes: systemSpeech)
        let theirAudio = voice(2, seconds: 20) + voice(0, seconds: 20)
        let yourAudio = voice(3, seconds: 20) + voice(1, seconds: 20)

        let chunk = Int(Self.rate * chunkSeconds)
        for start in stride(from: 0, to: theirAudio.count, by: chunk) {
            theirs.append(Array(theirAudio[start..<min(start + chunk, theirAudio.count)]))
            yours.append(Array(yourAudio[start..<min(start + chunk, yourAudio.count)]))
        }

        #expect(yours.speaker(from: 25, to: 35) == "You")
        #expect(try database.speakers().count == 2)
    }

    @Test func knowsYourVoiceWhereverElseItIsHeard() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        feed(voice(1, seconds: 40), to: try makeIdentifier(isYours: true, database: database))

        let mixed = try makeIdentifier(name: "Speaker", database: database)
        feed(voice(1, seconds: 12) + voice(2, seconds: 12), to: mixed)

        #expect(mixed.speaker(from: 2, to: 10) == "You")
        #expect(mixed.speaker(from: 15, to: 23) == "Speaker \(try id(1, in: database))")
    }

    @Test func keepsSamplesOfThoseWithNoNameToTellWhoTheyAre() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(database: database)

        feed(
            voice(1, seconds: 12) + voice(0, seconds: 3) + voice(2, seconds: 30) + voice(1, seconds: 6),
            to: identifier
        )
        identifier.finish()

        let speakers = try database.speakers()
        #expect(speakers.count == 2)
        for speaker in speakers {
            let samples = try database.samples(of: speaker.id)
            #expect(!samples.isEmpty)
            for sample in samples {
                #expect((SpeakerIdentifier.shortestSample...SpeakerIdentifier.longestSample).contains(sample.seconds))
                // An MPEG-4 file, which starts with its type.
                #expect(sample.audio.dropFirst(4).prefix(4) == Data("ftyp".utf8))
            }
        }
        #expect(try database.samples(of: speakers[1].id).first?.seconds == SpeakerIdentifier.longestSample)
    }

    @Test func savesNobodyHeardOnlyForAMoment() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(database: database)

        feed(voice(1, seconds: 1.5) + voice(0, seconds: 10), to: identifier)
        identifier.finish()

        #expect(try database.speakers().isEmpty)
        #expect(identifier.speaker(from: 0, to: 1.5) == "Them")
    }

    @Test func keepsNoSamplesOfSomeoneWithAName() throws {
        let database = try SpeakerDatabase(url: temporaryDatabase())
        let identifier = try makeIdentifier(database: database)
        feed(voice(1, seconds: 6), to: identifier)
        _ = try database.rename(try id(0, in: database), to: "Ada")

        feed(voice(1, seconds: 20), to: identifier)
        identifier.finish()

        #expect(try database.sampleCounts().isEmpty)
    }

    @Test func settlesWhoSpokeALineOnceTheAudioHasGoneFarEnoughPastIt() async throws {
        let identifier = try makeIdentifier()
        feed(voice(1, seconds: 3), to: identifier)
        let settled = Task {
            await identifier.settle(through: 2)
            return identifier.speaker(from: 0, to: 2)
        }

        feed(voice(1, seconds: SpeakerIdentifier.settleSeconds), to: identifier)

        #expect(await settled.value == "Them 1")
    }

    @Test func settlesEverythingOnceTheAudioEnds() async throws {
        let identifier = try makeIdentifier()
        feed(voice(1, seconds: 3), to: identifier)

        identifier.finish()

        await identifier.settle(through: 1_000)
    }

    @Test func warnsOnceAndGoesOnWhenVoicesCannotBePrinted() throws {
        let warnings = Output()
        let identifier = try SpeakerIdentifier(
            name: "Them",
            sampleRate: Self.rate,
            printer: StandInPrinter(fails: true)
        ) { warnings.append($0 + "\n") }

        feed(voice(1, seconds: 12), to: identifier)

        #expect(warnings.text == "cannot tell voices apart: the speaker model failed\n")
        #expect(identifier.speaker(from: 2, to: 10) == nil)
    }

    @Test func cannotTellVoicesApartInAudioThatIsNotAudio() {
        for sampleRate in [0, 100, .nan, .infinity] {
            #expect(throws: TranscribeError.self) { try makeIdentifier(sampleRate: sampleRate) }
        }
    }

    private func makeIdentifier(
        name: String = "Them",
        isYours: Bool = false,
        sampleRate: Double = rate,
        database: SpeakerDatabase? = nil,
        speechTimes: SpeechTimes? = nil,
        otherSpeechTimes: SpeechTimes? = nil
    ) throws -> SpeakerIdentifier {
        try SpeakerIdentifier(
            name: name,
            isYours: isYours,
            sampleRate: sampleRate,
            printer: StandInPrinter(),
            database: database,
            speechTimes: speechTimes,
            otherSpeechTimes: otherSpeechTimes
        )
    }

    /// Audio of made-up voice `number` at a steady level of its own; 0 is silence.
    private func voice(_ number: Int, seconds: Double, rate: Double = rate) -> [Float] {
        [Float](repeating: StandInPrinter.level(number), count: Int(seconds * rate))
    }

    /// In the chunks transcribe reads.
    private func feed(_ samples: [Float], to identifier: SpeakerIdentifier, rate: Double = rate) {
        let chunk = Int(rate * chunkSeconds)
        for start in stride(from: 0, to: samples.count, by: chunk) {
            identifier.append(Array(samples[start..<min(start + chunk, samples.count)]))
        }
    }

    /// The number of the speaker saved `index`th.
    private func id(_ index: Int, in database: SpeakerDatabase) throws -> Int {
        let speakers = try database.speakers()
        try #require(speakers.count > index, "\(speakers.map(\.id))")
        return speakers[index].id
    }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-tests-\(UUID())/speakers.db")
    }
}

/// Stands in for the speaker model: each made-up voice's level of audio gets a direction of its own, and a stretch
/// with several of them the mix of theirs, as a real print of two people would be.
private struct StandInPrinter: VoicePrinting {
    var fails = false

    static func level(_ voice: Int) -> Float { Float(voice) / 10 }

    func voicePrint(of samples: ArraySlice<Float>, minimumSpeech: Double) throws -> [Float]? {
        if fails { throw TranscribeError("the speaker model failed") }
        var print = [Float](repeating: 0, count: VoicePrinter.printLength)
        // Resampled audio wobbles a little around its level, and a little more at the edges of each voice.
        for sample in samples where abs(sample) > 0.05 {
            print[Int((abs(sample) * 10).rounded())] += 1
        }
        let speech = print.reduce(0, +)
        guard speech > 0, Double(speech) >= Double(samples.count) * minimumSpeech - 1 else { return nil }
        return print.map { $0 / speech }
    }
}

struct VoiceClustersTests {
    @Test func keepsOnePersonOneSpeakerThroughACall() {
        var voices = VoiceClusters()

        for print in prints(around: 0, count: 50) { voices.add(print) }

        #expect(voices.speakers.count == 1)
        #expect(Set(voices.labels) == [1])
    }

    @Test func recognizesSomeoneNewOnceTheyHaveSpokenForAFewPrints() {
        var voices = VoiceClusters()
        for print in prints(around: 0, count: 10) { voices.add(print) }
        let enough = VoiceClusters.newSpeakerPrints
        let newcomer = prints(around: 5, count: enough)

        for print in newcomer.dropLast() { voices.add(print) }
        #expect(voices.labels.suffix(enough - 1) == Array(repeating: 1, count: enough - 1))

        voices.add(newcomer[enough - 1])
        #expect(voices.labels.suffix(enough) == Array(repeating: 2, count: enough))

        voices.add(prints(around: 0, count: 1)[0])
        #expect(voices.labels.last == 1)
    }

    @Test func aFewOddPrintsDoNotMakeSomeoneNew() {
        var voices = VoiceClusters()

        for _ in 0..<3 {
            for print in prints(around: 0, count: 10) + prints(around: 5, count: 1) { voices.add(print) }
        }

        #expect(voices.speakers.count == 1)
    }

    /// Prints of one made-up voice, each a little different, the same every run: around a direction of its own, one
    /// for each `value`.
    private func prints(around value: Float, count: Int) -> [[Float]] {
        var random = SeededRandom(seed: UInt64(value.bitPattern) + UInt64(count))
        return (0..<count).map { _ in
            (0..<VoicePrinter.printLength).map { element in
                (element == Int(value) ? 1 : 0) + Float.random(in: -0.02...0.02, using: &random)
            }
        }
    }
}

/// A random number generator that gives the same numbers for the same seed (SplitMix64).
private struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
