import Testing

@testable import TotalRecall

struct MicrophoneCaptureTests {
    let devices = FakeMicrophones(target: macMic)
    let received = ReceivedAudio()

    private func makeCapture(preferredName: String? = nil) -> MicrophoneCapture {
        devices.capture(preferredName: preferredName, onSamples: received.append)
    }

    @Test func recordsTheTargetDevice() throws {
        let capture = makeCapture()

        try capture.start()
        devices.sessions[0].deliver([0.5])

        #expect(capture.device?.id == macMic.id)
        #expect(received.sessions == [1])
    }

    @Test func asksForThePreferredMicrophone() throws {
        let capture = makeCapture(preferredName: "AirPods")

        try capture.start()

        #expect(devices.preferredNames == ["AirPods"])
    }

    @Test func failsWithoutAMicrophone() {
        devices.target = nil
        let capture = makeCapture()

        #expect {
            try capture.start()
        } throws: { error in
            error.localizedDescription == "no microphone available"
        }
        #expect(capture.device == nil)
    }

    @Test func passesOnASessionThatFailsToStart() {
        devices.failure = RecordingError("device is busy")
        let capture = makeCapture()

        #expect(throws: RecordingError.self) { try capture.start() }
        #expect(capture.device == nil)
    }

    @Test func keepsTheOldMicUntilTheNewOneDeliversSound() throws {
        let capture = makeCapture()
        try capture.start()
        devices.target = airPods
        try capture.start()
        let (old, new) = (devices.sessions[0], devices.sessions[1])

        #expect(capture.device?.id == airPods.id)
        #expect(capture.isSwitching)
        new.deliver([0, 0])
        old.deliver([0.1])
        new.deliver([0.2])
        old.deliver([0.3])

        #expect(received.buffers.map(\.sample) == [0.1, 0.2])
        #expect(received.sessions == [1, 2])
        #expect(!capture.isSwitching)
    }

    @Test func reportsACompletedSwitchOnceAndStopsTheOldMic() throws {
        let capture = makeCapture()
        try capture.start()
        devices.target = airPods
        try capture.start()
        devices.sessions[1].deliver([0.2])

        #expect(capture.finishSwitch()?.id == airPods.id)
        #expect(devices.sessions[0].isStopped)
        #expect(capture.finishSwitch() == nil)
    }

    @Test func switchesOnSilenceOnceTheOldMicWentQuiet() async throws {
        let capture = makeCapture()
        try capture.start()
        devices.target = airPods
        try capture.start()

        try await Task.sleep(for: .seconds(captureStallSeconds + 0.1))
        devices.sessions[1].deliver([0, 0])

        #expect(received.sessions == [2])
    }

    @Test func doesNotAnnounceARestartOfTheSameMic() throws {
        let capture = makeCapture()
        try capture.start()
        try capture.start()
        devices.sessions[1].deliver([0.2])

        #expect(capture.finishSwitch() == nil)
        #expect(devices.sessions[0].isStopped)
    }

    @Test func replacesAPendingMicWithANewerOne() throws {
        let capture = makeCapture()
        try capture.start()
        devices.target = airPods
        try capture.start()
        devices.target = usbMic
        try capture.start()

        #expect(capture.device?.id == usbMic.id)
        #expect(capture.finishSwitch() == nil)
        #expect(devices.sessions[1].isStopped)
        #expect(!devices.sessions[0].isStopped)
    }

    @Test func stopsCountingAsSwitchingWhenTheNewMicTakesTooLong() throws {
        let capture = makeCapture()
        try capture.start()
        devices.target = airPods
        try capture.start()

        devices.sessions[1].startedAt -= 6

        #expect(!capture.isSwitching)
    }

    @Test func reportsADeviceChangeOnce() throws {
        let capture = makeCapture()
        try capture.start()

        devices.sessions[0].changeDevice()

        #expect(capture.takeDeviceChange())
        #expect(!capture.takeDeviceChange())
    }

    @Test func stopsEverySession() throws {
        let capture = makeCapture()
        try capture.start()
        devices.target = airPods
        try capture.start()

        capture.stop()
        devices.sessions[0].deliver([0.1])

        #expect(devices.sessions.allSatisfy { $0.isStopped })
        #expect(capture.device == nil)
        #expect(received.buffers.isEmpty)
    }
}
