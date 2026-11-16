import Accelerate
import Testing

@testable import Transcribe

/// Sorting prints into people, with made-up prints: each person's around a direction of their own.
struct VoiceGroupsTests {
    @Test func groupsEachPersonsPrintsTogetherInTheOrderTheyAreFirstHeard() {
        var random = SeededRandom(seed: 1)
        let people = [2, 0, 2, 1, 0, 1, 2, 0]
        let prints = people.map { voice($0, &random) }

        let groups = VoiceGroups.group(prints, within: SpeakerTurns.sameSpeaker)

        #expect(groups == [0, 1, 0, 2, 1, 2, 0, 1])
    }

    @Test func keepsEveryPrintApartWhenNoneAreAlike() {
        let prints = (0..<5).map { direction($0) }

        #expect(VoiceGroups.group(prints, within: SpeakerTurns.sameSpeaker) == [0, 1, 2, 3, 4])
        #expect(VoiceGroups.group([], within: SpeakerTurns.sameSpeaker).isEmpty)
        #expect(VoiceGroups.group([direction(0)], within: SpeakerTurns.sameSpeaker) == [0])
    }

    @Test func foldsGroupsOfTooFewPrintsIntoTheNearestLargerOne() {
        var random = SeededRandom(seed: 2)
        // Someone heard oddly for a moment: between the first person and a direction of their own, nearer the first.
        var odd = vDSP.add(vDSP.multiply(0.8, direction(0)), vDSP.multiply(0.6, direction(5)))
        odd = vDSP.divide(odd, vDSP.sumOfSquares(odd).squareRoot())
        let prints = [odd] + (0..<4).map { _ in voice(0, &random) } + (0..<4).map { _ in voice(1, &random) }

        let folded = VoiceGroups.fold([0, 1, 1, 1, 1, 2, 2, 2, 2], of: prints, fewest: 3)

        #expect(folded == [0, 0, 0, 0, 0, 1, 1, 1, 1])
    }

    @Test func keepsTheLargestGroupWhenNoneHaveEnoughPrints() {
        let prints = [direction(0), direction(1), direction(1)]

        #expect(VoiceGroups.fold([0, 1, 1], of: prints, fewest: 5) == [0, 0, 0])
    }
}

/// Who talks when, put together from made-up windows and prints.
struct SpeakerTurnsTests {
    private static let step = Double(SpeakerTurns.windowStep) / VoicePrinter.sampleRate

    @Test func tellsPeopleApartByTheirPrintsAsTheyAreHeard() {
        var random = SeededRandom(seed: 3)
        var turns = SpeakerTurns()

        turns.add(window(0, [.person(0)]), prints: [print(voice(0, &random))])
        turns.add(window(1, [.person(0)]), prints: [print(voice(1, &random))])
        turns.add(window(2, [.person(1)]), prints: [nil, print(voice(0, &random))])

        #expect(turns.speakers.map { $0.compactMap { $0 } } == [[1], [2], [1]])
    }

    @Test func takesTwoPeopleInOneWindowForTwoSpeakersHoweverAlikeTheySound() {
        var random = SeededRandom(seed: 4)
        var turns = SpeakerTurns()
        turns.add(window(0, [.person(0)]), prints: [print(voice(0, &random))])

        turns.add(window(1, [.person(0), .person(1)]), prints: [print(voice(0, &random)), print(voice(0, &random))])

        #expect(turns.speakers[1] == [1, 2])
    }

    @Test func letsAShortPrintJoinSomeoneButNeverMakeSomeoneNew() {
        var random = SeededRandom(seed: 5)
        var turns = SpeakerTurns()
        turns.add(window(0, [.person(0)]), prints: [print(voice(0, &random))])

        turns.add(
            window(1, [.person(0), .person(1)]),
            prints: [print(voice(0, &random), isShort: true), print(voice(1, &random), isShort: true)]
        )

        #expect(turns.speakers[1] == [1, nil])
        #expect(turns.printCounts == [1: 1])
    }

    @Test func saysWhoTalksWhenAsTheWindowsThatHearItMostlySay() {
        var random = SeededRandom(seed: 6)
        let (first, second) = (voice(0, &random), voice(1, &random))
        var turns = SpeakerTurns()
        // The first talks throughout; the second, in each window's second half, which the next window hears first.
        for index in 0..<4 {
            let frames = (0..<Segmenter.frameCount).map { frame -> Talkers in
                frame < Segmenter.frameCount / 2 ? .person(0) : [.person(0), .person(1)]
            }
            turns.add(
                SpeakerTurns.Window(start: index * SpeakerTurns.windowStep, frames: frames),
                prints: [print(first), print(second)]
            )
        }

        let early = turns.talkTime(from: 0, to: 4)
        let late = turns.talkTime(from: 6, to: 7)

        #expect(abs((early[1] ?? 0) - 4) < 0.05)
        #expect(early[2] == nil)
        #expect(abs((late[1] ?? 0) - 1) < 0.05)
        #expect(abs((late[2] ?? 0) - 1) < 0.05)
        #expect(turns.talkTime(from: 40, to: 50).isEmpty)
    }

    @Test func sortsEveryPrintAgainOnceTheCallIsOver() {
        var random = SeededRandom(seed: 7)
        var turns = SpeakerTurns()
        // The second person, heard first on an odd moment that sounds a little like the first, is taken for them as
        // the call goes on, and the rest of them with it; once it is over, each print goes with those it is nearest.
        var odd = vDSP.add(vDSP.multiply(0.6, direction(0)), vDSP.multiply(0.8, direction(1)))
        odd = vDSP.divide(odd, vDSP.sumOfSquares(odd).squareRoot())
        turns.add(window(0, [.person(0)]), prints: [print(voice(0, &random))])
        turns.add(window(1, [.person(0)]), prints: [print(odd)])
        for index in 2..<2 + SpeakerTurns.fewestPrints {
            turns.add(window(index, [.person(0)]), prints: [print(voice(1, &random))])
            turns.add(window(index, [.person(0)]), prints: [print(voice(0, &random))])
        }
        #expect(Set(turns.speakers.map { $0[0] }) == [1])

        turns.conclude()

        #expect(turns.isConcluded)
        #expect(turns.speakers[0] == [1])
        #expect(turns.speakers[1] == [2])
        #expect(turns.speakers[2] == [2])
        #expect(turns.speakers[3] == [1])
    }

    private func window(_ index: Int, _ talkers: Talkers) -> SpeakerTurns.Window {
        SpeakerTurns.Window(
            start: index * SpeakerTurns.windowStep,
            frames: [Talkers](repeating: talkers, count: Segmenter.frameCount)
        )
    }

    private func print(_ vector: [Float], isShort: Bool = false) -> SpeakerTurns.Print {
        SpeakerTurns.Print(print: vector, isShort: isShort)
    }
}

/// A print of made-up person `number`: their own direction, a little off it.
func voice(_ number: Int, _ random: inout SeededRandom) -> [Float] {
    var print = direction(number)
    for index in print.indices { print[index] += Float.random(in: -0.02...0.02, using: &random) }
    return vDSP.divide(print, vDSP.sumOfSquares(print).squareRoot())
}

/// A print pointing along dimension `index`.
func direction(_ index: Int) -> [Float] {
    var print = [Float](repeating: 0, count: VoicePrinter.printLength)
    print[index] = 1
    return print
}

/// The same numbers every run.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
