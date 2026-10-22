import Foundation
import Testing

@testable import Transcribe

struct SpeakerDatabaseTests {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("transcribe-tests-\(UUID())/speakers.db")

    @Test func remembersSpeakersFromOneOpeningToTheNext() throws {
        let id = try SpeakerDatabase(url: url).add(voice: [1, 2, 3], prints: 4)
        try #require(try SpeakerDatabase(url: url).update(id, voice: [2, 3, 4], prints: 6))

        let speakers = try SpeakerDatabase(url: url).speakers()

        #expect(speakers.map(\.id) == [id])
        #expect(speakers[0].voice == [2, 3, 4])
        #expect(speakers[0].prints == 6)
        #expect(speakers[0].name == nil)
    }

    @Test func namesASpeakerAndTakesTheNameAway() throws {
        let database = try SpeakerDatabase(url: url)
        let id = try database.add(voice: [0], prints: 1)

        #expect(try database.rename(id, to: "Ada"))
        #expect(try database.speaker(id)?.name == "Ada")
        #expect(try database.rename(id, to: nil))
        #expect(try database.speaker(id)?.name == nil)
        #expect(try !database.rename(id + 1, to: "Nobody"))
    }

    @Test func mergesOnePersonTakenForTwo() throws {
        let database = try SpeakerDatabase(url: url)
        let first = try database.add(voice: [0, 0], prints: 1)
        let second = try database.add(voice: [4, 8], prints: 3)
        _ = try database.rename(first, to: "Ada")
        let firstHeard = try #require(try database.speaker(first)).createdAt

        #expect(try database.merge(first, into: second))

        let speakers = try database.speakers()
        #expect(speakers.map(\.id) == [second])
        #expect(speakers[0].voice == [3, 6])
        #expect(speakers[0].prints == 4)
        #expect(speakers[0].name == "Ada")
        #expect(speakers[0].createdAt == firstHeard)
        #expect(try !database.merge(second, into: second))
        #expect(try !database.merge(first, into: second))
    }

    @Test func marksYouAndKeepsYouThroughAMerge() throws {
        let database = try SpeakerDatabase(url: url)
        let you = try database.add(voice: [0], prints: 1)
        let other = try database.add(voice: [0], prints: 1)

        #expect(try database.markAsYou(you))
        #expect(try database.speaker(you)?.isYou == true)
        #expect(try database.speaker(other)?.isYou == false)
        #expect(try database.merge(you, into: other))
        #expect(try database.speaker(other)?.isYou == true)
    }

    @Test func keepsEachSpeakersLongestSamples() throws {
        let database = try SpeakerDatabase(url: url)
        let id = try database.add(voice: [0], prints: 1)

        for seconds in [3.0, 9, 2, 12, 5, 7] {
            try database.addSample(Data("\(seconds)".utf8), seconds: seconds, to: id)
        }

        #expect(try database.samples(of: id).map(\.seconds) == [12, 9, 7, 5])
        #expect(try database.samples(of: id).first?.audio == Data("12.0".utf8))
        #expect(try database.sampleCounts() == [id: 4])
    }

    @Test func movesSamplesToWhoeverTheirSpeakerTurnsOutToBe() throws {
        let database = try SpeakerDatabase(url: url)
        let (first, second, third) = (
            try database.add(voice: [0], prints: 1), try database.add(voice: [0], prints: 1),
            try database.add(voice: [0], prints: 1)
        )
        for seconds in [3.0, 4, 5] { try database.addSample(Data([1]), seconds: seconds, to: first) }
        for seconds in [6.0, 7] { try database.addSample(Data([2]), seconds: seconds, to: second) }
        try database.addSample(Data([3]), seconds: 8, to: third)

        try database.moveSamples(of: first, to: second)
        #expect(try database.samples(of: second).map(\.seconds) == [7, 6, 5, 4])
        #expect(try database.merge(third, into: second))
        #expect(try database.samples(of: second).map(\.seconds) == [8, 7, 6, 5])
        #expect(try database.samples(of: first).isEmpty)
    }

    @Test func forgetsASpeaker() throws {
        let database = try SpeakerDatabase(url: url)
        let id = try database.add(voice: [0], prints: 1)

        try database.addSample(Data([1]), seconds: 3, to: id)

        #expect(try database.forget(id))
        #expect(try database.speakers().isEmpty)
        #expect(try database.sampleCounts().isEmpty)
        #expect(try !database.forget(id))
        #expect(try !database.update(id, voice: [1], prints: 2))
    }
}
