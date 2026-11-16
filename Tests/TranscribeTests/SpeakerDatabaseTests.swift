import Foundation
import Testing

@testable import Transcribe

struct SpeakerDatabaseTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-tests-\(UUID())/speakers.db")

    @Test func remembersVoicesFromOneOpeningToTheNext() throws {
        let added = try SpeakerDatabase(url: url).addPerson(print: [1, 2, 3], prints: 4)
        try #require(try SpeakerDatabase(url: url).update(added.id, print: [2, 3, 4], prints: 6))

        let voices = try SpeakerDatabase(url: url).voices()

        #expect(voices.map(\.id) == [added.id])
        #expect(voices[0].person == added.person)
        #expect(voices[0].print == [2, 3, 4])
        #expect(voices[0].prints == 6)
        #expect(voices[0].name == nil)
        #expect(try SpeakerDatabase(url: url).people().map(\.id) == [added.person])
    }

    @Test func keepsEachModelsPrintsApart() throws {
        let added = try SpeakerDatabase(url: url, model: "one").addPerson(print: [1, 2], prints: 4)

        #expect(try SpeakerDatabase(url: url, model: "other").voices().isEmpty)
        #expect(try SpeakerDatabase(url: url, model: "other").people().map(\.id) == [added.person])
        #expect(try SpeakerDatabase(url: url, model: "one").voices().map(\.print) == [[1, 2]])
    }

    @Test func namesSomeoneAndTakesTheNameAway() throws {
        let database = try SpeakerDatabase(url: url)
        let person = try database.addPerson(print: [0], prints: 1).person

        #expect(try database.rename(person, to: "Ada"))
        #expect(try database.person(person)?.name == "Ada")
        #expect(try database.voices().first?.name == "Ada")
        #expect(try database.rename(person, to: nil))
        #expect(try database.person(person)?.name == nil)
        #expect(try !database.rename(person + 1, to: "Nobody"))
    }

    @Test func mergesOnePersonTakenForTwoIntoOneVoiceWithAllTheirClips() throws {
        let database = try SpeakerDatabase(url: url)
        let first = try database.addPerson(print: [0, 0], prints: 1)
        let second = try database.addPerson(print: [4, 8], prints: 3)
        try database.addClip(Data([1]), seconds: 5, print: [0, 0], to: first.id)
        try database.addClip(Data([2]), seconds: 6, print: [4, 8], to: second.id)
        _ = try database.rename(first.person, to: "Ada")
        let firstHeard = try #require(try database.person(first.person)).createdAt

        #expect(try database.merge(first.person, into: second.person))

        #expect(try database.people().map(\.id) == [second.person])
        let person = try #require(try database.person(second.person))
        #expect(person.name == "Ada")
        #expect(person.createdAt == firstHeard)
        // One voice, the older, sounding as both did, each as long as it was heard.
        let voices = try database.voices(of: second.person)
        #expect(voices.map(\.id) == [first.id])
        #expect(voices.map(\.print) == [[3, 6]])
        #expect(voices.map(\.prints) == [4])
        #expect(try database.clips(of: second.person).map(\.seconds) == [6, 5])
        #expect(try database.clips(of: second.person).allSatisfy { $0.voice == first.id })
        #expect(try !database.merge(second.person, into: second.person))
        #expect(try !database.merge(first.person, into: second.person))
    }

    @Test func forgetsAClipOfSomeoneElseMergedInByMistake() throws {
        let database = try SpeakerDatabase(url: url)
        let ada = try database.addPerson(print: [1, 0], prints: 10)
        let grace = try database.addPerson(print: [0, 1], prints: 10)
        try database.addClip(Data([1]), seconds: 5, print: [1, 0], to: ada.id)
        try database.addClip(Data([2]), seconds: 6, print: [0, 1], to: grace.id)
        #expect(try database.merge(grace.person, into: ada.person))
        let graces = try #require(try database.clips(of: ada.person).first { $0.audio == Data([2]) })

        #expect(try database.forgetClip(graces.id))

        #expect(try database.clips(of: ada.person).map(\.audio) == [Data([1])])
        #expect(try database.clipPrints().map(\.print) == [[1, 0]])
        #expect(try !database.forgetClip(graces.id))
    }

    @Test func tellsHowAlikeTwoPeopleSound() throws {
        let database = try SpeakerDatabase(url: url)
        let ada = try database.addPerson(print: direction(0), prints: 10)
        let alsoAda = try database.addPerson(print: direction(0, 0.3), prints: 10)

        let near = try #require(try database.distance(between: alsoAda.person, and: ada.person))

        #expect(abs(near - (1 - cos(0.3))) < 1e-5)
        #expect(try database.distance(between: ada.person, and: ada.person + 100) == nil)
    }

    @Test func flagsAClipThatSoundsUnlikeTheRestOfItsPersons() throws {
        let database = try SpeakerDatabase(url: url)
        let person = try database.addPerson(print: direction(0), prints: 40)
        // Someone's clips, one of someone else's among them; and another's, all alike.
        for print in [direction(0), direction(0, 0.3), direction(0, 0.2)] {
            try database.addClip(Data([1]), seconds: 8, print: print, to: person.id)
        }
        try database.addClip(Data([2]), seconds: 6, print: direction(4), to: person.id)
        let other = try database.addPerson(print: direction(8), prints: 10)
        for turn: Float in [0, 0.3] {
            try database.addClip(Data([3]), seconds: 7, print: direction(8, turn), to: other.id)
        }
        let stranger = try #require(try database.clips(of: person.person).first { $0.audio == Data([2]) })

        let odd = SpeakerDatabase.oddClips(try database.clipPrints())

        #expect(Set(odd.keys) == [stranger.id])
        #expect(odd[stranger.id].map { $0 < 0.1 } == true)
    }

    @Test func flagsOneOfTwoClipsThatSoundUnlike() throws {
        let database = try SpeakerDatabase(url: url)
        let person = try database.addPerson(print: direction(0), prints: 5)
        try database.addClip(Data([1]), seconds: 9, print: direction(0), to: person.id)
        try database.addClip(Data([2]), seconds: 6, print: direction(4), to: person.id)

        #expect(SpeakerDatabase.oddClips(try database.clipPrints()).count == 1)
    }

    @Test func unifiesThoseSurelyOnePerson() throws {
        let database = try SpeakerDatabase(url: url)
        let ada = try database.addPerson(print: direction(0), prints: 20).person
        let alsoAda = try database.addPerson(print: direction(0, 0.2), prints: 5).person
        let notSure = try database.addPerson(print: direction(0, 1.2), prints: 30).person
        let heardBriefly = try database.addPerson(print: direction(0, 0.1), prints: 3).person
        let grace = try database.addPerson(print: direction(10), prints: 20).person
        let graceAgain = try database.addPerson(print: direction(10, 0.5), prints: 8).person
        let notGrace = try database.addPerson(print: direction(10, 0.1), prints: 10).person
        _ = try database.rename(ada, to: "Ada")
        _ = try database.rename(grace, to: "Grace")
        _ = try database.rename(graceAgain, to: "Grace")
        _ = try database.rename(notGrace, to: "Linus")

        let unified = try database.unify()

        #expect(unified.map { [$0.merged.id, $0.into.id] } == [[alsoAda, ada], [graceAgain, grace]])
        #expect(try database.people().map(\.id) == [ada, notSure, heardBriefly, grace, notGrace])
        #expect(try database.voices(of: ada).count == 1)
        #expect(try database.unify().isEmpty)
    }

    @Test func marksYouAndKeepsYouThroughAMerge() throws {
        let database = try SpeakerDatabase(url: url)
        let you = try database.addPerson(print: [0], prints: 1)
        let other = try database.addPerson(print: [0], prints: 1)

        #expect(try database.markAsYou(you.id))
        #expect(try database.person(you.person)?.isYou == true)
        #expect(try database.person(other.person)?.isYou == false)
        #expect(try database.merge(you.person, into: other.person))
        #expect(try database.person(other.person)?.isYou == true)
    }

    @Test func keepsEachPersonsLongestClipsNamedOrNot() throws {
        let database = try SpeakerDatabase(url: url)
        let added = try database.addPerson(print: [0], prints: 1)
        _ = try database.rename(added.person, to: "Ada")

        for seconds in (1...25).map(Double.init) {
            try database.addClip(Data("\(seconds)".utf8), seconds: seconds, print: [0], to: added.id)
        }

        let clips = try database.clips(of: added.person)
        #expect(clips.map(\.seconds) == (6...25).reversed().map(Double.init))
        #expect(clips.first?.audio == Data("25.0".utf8))
        #expect(try database.clipCounts() == [added.person: SpeakerDatabase.clipsPerPerson])
    }

    @Test func forgetsSomeoneWithTheirVoicesAndClips() throws {
        let database = try SpeakerDatabase(url: url)
        let added = try database.addPerson(print: [0], prints: 1)
        try database.addClip(Data([1]), seconds: 3, print: [0], to: added.id)

        #expect(try database.forget(added.person))

        #expect(try database.people().isEmpty)
        #expect(try database.voices().isEmpty)
        #expect(try database.clipCounts().isEmpty)
        #expect(try !database.forget(added.person))
        #expect(try !database.update(added.id, print: [1], prints: 2))
    }

    /// A made-up voice print: direction `axis`, turned `turn` toward the next one.
    private func direction(_ axis: Int, _ turn: Float = 0) -> [Float] {
        var voice = [Float](repeating: 0, count: VoicePrinter.printLength)
        voice[axis] = cos(turn)
        voice[axis + 1] = sin(turn)
        return voice
    }
}
