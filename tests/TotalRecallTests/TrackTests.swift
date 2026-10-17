import Testing

@testable import TotalRecall

struct TrackTests {
    let clock = Clock()
    let track = Track()

    @Test func startsAtTheFirstBuffer() {
        #expect(track.startHostTime == nil)

        track.append(ramp(480), hostTime: clock.at(milliseconds: 0))

        #expect(track.startHostTime == clock.at(milliseconds: 0))
    }

    @Test func joinsBuffersThatFollowEachOther() {
        track.append(ramp(480), hostTime: clock.at(milliseconds: 0))
        track.append(ramp(480, from: 480), hostTime: clock.at(milliseconds: 10))

        #expect(track.takeAll() == ramp(960))
    }

    @Test func ignoresTimingJitter() {
        track.append(ramp(480), hostTime: clock.at(milliseconds: 0))
        track.append(ramp(480, from: 480), hostTime: clock.at(milliseconds: 90))

        #expect(track.takeAll() == ramp(960))
    }

    @Test func fillsLostAudioWithSilence() {
        track.append(ramp(480), hostTime: clock.at(milliseconds: 0))
        track.append(ramp(480, from: 480), hostTime: clock.at(milliseconds: 210))

        #expect(track.takeAll() == ramp(480) + silence(frameCount(milliseconds: 200)) + ramp(480, from: 480))
    }

    @Test func splicesANewSourceInAfterTheSilenceSinceTheOldOneEnded() {
        track.append(ramp(480), hostTime: clock.at(milliseconds: 0), source: 1)
        track.append(ramp(480, from: 480), hostTime: clock.at(milliseconds: 30), source: 2)

        #expect(track.takeAll() == ramp(480) + silence(frameCount(milliseconds: 20)) + ramp(480, from: 480))
    }

    @Test func keepsAudioBothSourcesCapturedOnlyOnce() {
        track.append(ramp(4_800), hostTime: clock.at(milliseconds: 0), source: 1)
        track.append(ramp(4_800, from: 2_400), hostTime: clock.at(milliseconds: 50), source: 2)

        #expect(track.takeAll() == ramp(7_200))
    }

    @Test func waitsForTheNewSourceToPassTheOldOnesEnd() {
        track.append(ramp(4_800), hostTime: clock.at(milliseconds: 0), source: 1)
        track.append(ramp(480), hostTime: clock.at(milliseconds: 20), source: 2)
        track.append(ramp(4_800, from: 4_800), hostTime: clock.at(milliseconds: 100), source: 2)

        #expect(track.takeAll() == ramp(9_600))
    }

    @Test func placesANewSourceThatOverlapsByMoreThanHalfASecondByItsHostTime() {
        track.append(ramp(48_000), hostTime: clock.at(milliseconds: 0), source: 1)
        track.append(ramp(480, from: 48_000), hostTime: clock.at(milliseconds: 200), source: 2)

        #expect(track.takeAll() == ramp(48_480))
    }

    @Test func takesFromTheFront() {
        track.append(ramp(100), hostTime: clock.at(milliseconds: 0))

        #expect(track.take(40) == ramp(40))
        #expect(track.count == 60)
        #expect(track.takeAll() == ramp(60, from: 40))
        #expect(track.count == 0)
    }

    @Test func padsAndTruncatesTheWaitingSamples() {
        track.append(ramp(10), hostTime: clock.at(milliseconds: 0))

        track.padWithSilence(toCount: 5)
        #expect(track.count == 10)
        track.padWithSilence(toCount: 15)
        #expect(track.count == 15)
        track.truncate(toCount: 12)
        #expect(track.takeAll() == ramp(10) + silence(2))
    }

    @Test func delaysTheWaitingSamplesWithoutMovingTheTimeline() {
        track.append(ramp(480), hostTime: clock.at(milliseconds: 0))
        track.delayStart(by: 100)
        track.append(ramp(480, from: 480), hostTime: clock.at(milliseconds: 10))

        #expect(track.takeAll() == silence(100) + ramp(960))
    }

    @Test func reportsThePeakSinceItWasLastTaken() {
        track.append([0.1, -0.7, 0.3], hostTime: clock.at(milliseconds: 0))

        #expect(track.takePeak() == 0.7)
        #expect(track.takePeak() == 0)
    }

    @Test func measuresTimeSinceTheLastBuffer() {
        track.append(ramp(10), hostTime: clock.at(milliseconds: 0))

        #expect(track.secondsSinceLastBuffer < 1)
    }
}
