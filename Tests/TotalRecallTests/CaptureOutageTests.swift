import Shared
import Testing

@testable import TotalRecall

struct CaptureOutageTests {
    let announcements = Announcements()
    let outage: CaptureOutage

    init() {
        outage = CaptureOutage(name: "system audio", announce: announcements.append)
    }

    @Test func backsOffWhileTheCaptureStaysDown() {
        #expect(restartTimes(count: 7, from: 0) == [0, 0.5, 1.5, 3.5, 7.5, 12.5, 17.5])
    }

    @Test func startsOverAtTheShortestDelayOnceAudioReturns() {
        _ = restartTimes(count: 6, from: 0)
        outage.update(deliveries: 1, now: 20)

        #expect(!outage.isOngoing)
        #expect(restartTimes(count: 3, from: 20) == [20, 20.5, 21.5])
    }

    @Test func startsOverAtTheShortestDelayAfterADeviceChange() {
        _ = restartTimes(count: 4, from: 0)
        outage.resetBackoff()

        #expect(restartTimes(count: 2, from: 7.5) == [7.5, 8])
    }

    @Test func staysQuietAboutABriefStall() {
        outage.restarting(now: 0)
        outage.update(deliveries: 0, now: 4.9)
        outage.update(deliveries: 1, now: 4.9)

        #expect(announcements.messages.isEmpty)
    }

    @Test func announcesALongOutageAndItsEnd() {
        outage.restarting(now: 0)
        outage.update(deliveries: 0, now: 5)
        outage.update(deliveries: 0, now: 6)
        outage.update(deliveries: 1, now: 8)

        #expect(
            announcements.messages == [
                "system audio stopped delivering audio; retrying",
                "system audio back after 8s",
            ]
        )
    }

    @Test func remindsWhileTheCaptureStaysDown() {
        outage.restarting(now: 0)
        for now in stride(from: 5.0, through: 600, by: 0.5) {
            outage.update(deliveries: 0, now: now)
        }

        #expect(
            announcements.messages == [
                "system audio stopped delivering audio; retrying",
                "still no system audio after 5m 0s; retrying",
                "still no system audio after 10m 0s; retrying",
            ]
        )
    }

    @Test func reportsEachReasonForFailingOncePerOutage() {
        outage.restarting(now: 0)
        outage.restartFailed(MessageError("tap failed"))
        outage.restartFailed(MessageError("tap failed"))
        outage.restartFailed(MessageError("no device"))
        outage.update(deliveries: 1, now: 1)
        outage.restarting(now: 2)
        outage.restartFailed(MessageError("no device"))

        #expect(
            announcements.messages == [
                "system audio unavailable, retrying: tap failed",
                "system audio unavailable, retrying: no device",
                "system audio unavailable, retrying: no device",
            ]
        )
    }

    /// Restarts `count` times, each as soon as allowed, and returns when.
    private func restartTimes(count: Int, from start: Double) -> [Double] {
        var times: [Double] = []
        var now = start
        while times.count < count {
            if outage.canRestart(now: now) {
                outage.restarting(now: now)
                times.append(now)
            }
            now += 0.5
        }
        return times
    }
}
