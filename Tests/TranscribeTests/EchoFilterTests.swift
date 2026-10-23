import Foundation
import Testing

@testable import Transcribe

struct EchoFilterTests {
    let passed = Lines()

    private func makeFilter() -> EchoFilter {
        let passed = passed
        return EchoFilter(pass: { passed.append($0) })
    }

    @Test func leavesOutWhatYourMicrophonePickedUpOfThem() {
        let filter = makeFilter()
        let theirs = line(.them, 13, 17, "This was a result of deliberate design choices built to maximize engagement.")
        filter.theirs(theirs)
        filter.update(theirs)

        let yours = "This was a result of deliberate design choices built to maximize engagement."
        filter.update(line(.you, 12, 16, yours))
        filter.update(line(.you, 17, 20, "For example, a 2015 meta email includedir users conitutional"))
        filter.theirs(line(.them, 17, 27, "For example, a 2016 meta email concluded that parents of teenage users"))
        filter.theyHaveBeenHeard(through: 40)

        #expect(passed.texts == [theirs.text])
    }

    @Test func keepsWhatYouSaidWhileTheyTalked() {
        let filter = makeFilter()
        filter.theirs(line(.them, 0, 5, "Start by heating some olive oil in a large pan."))

        filter.update(line(.you, 1, 3, "Sorry, I have to step out for a minute."))
        filter.update(line(.you, 4, 5, "Sure, I will get a pan."))
        filter.theyHaveBeenHeard(through: 10)

        #expect(passed.texts == ["Sorry, I have to step out for a minute.", "Sure, I will get a pan."])
    }

    @Test func holdsYourLineUntilTheyHaveBeenHeardPastIt() {
        let filter = makeFilter()
        filter.update(line(.you, 0, 3, "Welcome back to the channel."))
        filter.theyHaveBeenHeard(through: 5)
        #expect(passed.texts.isEmpty)

        filter.theyHaveBeenHeard(through: 6)

        #expect(passed.texts == ["Welcome back to the channel."])
    }

    @Test func waitsForTheWordsTheyAreStillSaying() {
        let filter = makeFilter()
        filter.theirs(TranscriptUpdate(speaker: .them, start: 2, text: "Hi everyone", isFinal: false))
        filter.update(line(.you, 2, 4, "Welcome back to the channel."))
        filter.theyHaveBeenHeard(through: 20)
        #expect(passed.texts.isEmpty)

        filter.theirs(line(.them, 2, 4, "Hi everyone, and thanks for watching."))

        #expect(passed.texts == ["Welcome back to the channel."])
    }

    @Test func showsYourLineWhileItIsHeldAndStopsIfItIsAnEcho() {
        let filter = makeFilter()
        filter.theirs(line(.them, 0, 4, "Welcome back to the channel, everyone."))

        filter.update(line(.you, 0, 4, "Welcome back to the channel."))
        #expect(passed.updates.map(\.isHeld) == [true])
        filter.theyHaveBeenHeard(through: 10)

        #expect(passed.updates.map(\.text) == ["Welcome back to the channel.", ""])
        #expect(passed.updates.last?.end == 4)
    }

    @Test func leavesOutWhatYourMicrophoneHeardFarQuieterThanThemHoweverGarbled() {
        let levels = ChannelLevels(sampleRate: 1_000)
        // 10 s: you quiet, 30 dB below them, then 10 s of you about as loud as them.
        levels.add([[Float](repeating: 0.0005, count: 10_000), [Float](repeating: 0.015, count: 10_000)])
        levels.add([[Float](repeating: 0.01, count: 10_000), [Float](repeating: 0.015, count: 10_000)])
        let passed = passed
        let filter = EchoFilter(levels: levels, pass: { passed.append($0) })

        filter.update(line(.you, 2, 4, "Love you."))
        filter.update(line(.you, 12, 14, "Sorry, I have to step out."))
        filter.theyHaveFinished()

        #expect(passed.texts == ["Sorry, I have to step out."])
    }

    @Test func keepsYourQuietLinesWhileTheSystemAudioIsSilent() {
        let levels = ChannelLevels(sampleRate: 1_000)
        levels.add([[Float](repeating: 0.0005, count: 10_000), [Float](repeating: 0, count: 10_000)])
        let passed = passed
        let filter = EchoFilter(levels: levels, pass: { passed.append($0) })

        filter.update(line(.you, 2, 4, "Love you."))
        filter.theyHaveFinished()

        #expect(passed.texts == ["Love you."])
    }

    @Test func passesEverythingOnceTheyHaveFinished() {
        let filter = makeFilter()
        filter.update(line(.you, 0, 3, "Welcome back to the channel."))
        filter.update(TranscriptUpdate(speaker: .you, start: 4, text: "Next", isFinal: false))

        filter.theyHaveFinished()
        filter.update(line(.you, 5, 8, "Next, think about lighting."))

        #expect(passed.texts == ["Next", "Welcome back to the channel.", "Next, think about lighting."])
    }

    private func line(_ speaker: Speaker, _ start: Double, _ end: Double, _ text: String) -> TranscriptUpdate {
        TranscriptUpdate(speaker: speaker, start: start, text: text, isFinal: true, end: end)
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [TranscriptUpdate] = []

    var updates: [TranscriptUpdate] { lock.withLock { storage } }
    /// What is shown, not what is held back to be.
    var texts: [String] { updates.filter { !$0.isHeld && !$0.text.isEmpty }.map(\.text) }

    func append(_ update: TranscriptUpdate) {
        lock.withLock { storage.append(update) }
    }
}
