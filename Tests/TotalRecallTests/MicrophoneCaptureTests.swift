import Foundation
import Shared
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
        devices.failure = MessageError("device is busy")
        let capture = makeCapture()

        #expect(throws: MessageError.self) { try capture.start() }
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

    // MARK: A microphone silenced by another app's voice processing

    /// One second at a steady level: -86 dB is silenced, -40 dB speech.
    private let silencedSecond = [Float](repeating: 0.00005, count: LoudnessWindow.length)
    private let speechSecond = [Float](repeating: 0.01, count: LoudnessWindow.length)

    /// Starts a capture whose mic stayed silenced long enough to try voice processing, and starts the trial.
    private func captureTryingVoiceProcessing() throws -> MicrophoneCapture {
        let capture = makeCapture()
        try capture.start()
        for _ in 0..<MicrophoneCapture.deadSecondsBeforeTrial { devices.sessions[0].deliver(silencedSecond) }
        try capture.tryVoiceProcessing()
        return capture
    }

    @Test func triesVoiceProcessingOnASilencedMic() throws {
        _ = try captureTryingVoiceProcessing()

        #expect(devices.sessions.map(\.usesVoiceProcessing) == [false, true])
    }

    @Test func leavesAMicThatHearsAQuietRoomAlone() throws {
        let capture = makeCapture()
        try capture.start()
        let quietRoomSecond = [Float](repeating: 0.0006, count: LoudnessWindow.length)  // -65 dB
        for _ in 0..<10 { devices.sessions[0].deliver(quietRoomSecond) }

        try capture.tryVoiceProcessing()

        #expect(devices.sessions.count == 1)
    }

    @Test func triesVoiceProcessingOnlyWhereItCanBeUsed() throws {
        devices.canUseVoiceProcessing = false
        let capture = makeCapture()
        try capture.start()
        for _ in 0..<10 { devices.sessions[0].deliver(silencedSecond) }

        try capture.tryVoiceProcessing()

        #expect(devices.sessions.count == 1)
    }

    @Test func switchesToVoiceProcessingOnceItHearsMore() throws {
        let capture = try captureTryingVoiceProcessing()
        let (plain, voiceProcessing) = (devices.sessions[0], devices.sessions[1])
        let recordedBefore = received.buffers.count

        voiceProcessing.deliver(speechSecond)
        plain.deliver(silencedSecond)

        #expect(received.sessions.dropFirst(recordedBefore) == [2])
        #expect(capture.takeVoiceProcessingTakeover()?.id == macMic.id)
        #expect(capture.takeVoiceProcessingTakeover() == nil)
        #expect(capture.finishSwitch() == nil)
        #expect(plain.isStopped)
    }

    @Test func givesUpVoiceProcessingWhenTheMicComesBack() throws {
        let capture = try captureTryingVoiceProcessing()
        let (plain, voiceProcessing) = (devices.sessions[0], devices.sessions[1])

        plain.deliver(speechSecond)
        voiceProcessing.deliver(speechSecond)
        _ = capture.finishSwitch()

        #expect(voiceProcessing.isStopped)
        #expect(!plain.isStopped)
        #expect(capture.takeVoiceProcessingTakeover() == nil)
        #expect(received.sessions.allSatisfy { $0 == 1 })
    }

    @Test func givesUpVoiceProcessingThatHearsNothingMore() throws {
        let capture = try captureTryingVoiceProcessing()
        let voiceProcessing = devices.sessions[1]

        for _ in 0..<MicrophoneCapture.trialSeconds { voiceProcessing.deliver(silencedSecond) }
        _ = capture.finishSwitch()

        #expect(voiceProcessing.isStopped)
        #expect(capture.takeVoiceProcessingTakeover() == nil)
    }

    @Test func waitsBeforeTryingVoiceProcessingAgain() throws {
        let capture = try captureTryingVoiceProcessing()
        for _ in 0..<MicrophoneCapture.trialSeconds { devices.sessions[1].deliver(silencedSecond) }

        for _ in 0..<MicrophoneCapture.deadSecondsBeforeTrial { devices.sessions[0].deliver(silencedSecond) }
        try capture.tryVoiceProcessing()

        #expect(devices.sessions.count == 2)
    }

    @Test func restartsAMicOnVoiceProcessingThroughIt() throws {
        let capture = try captureTryingVoiceProcessing()
        devices.sessions[1].deliver(speechSecond)

        try capture.start()

        #expect(devices.sessions.map(\.usesVoiceProcessing) == [false, true, true])
    }

    @Test func movesToAnotherMicWithoutVoiceProcessing() throws {
        let capture = try captureTryingVoiceProcessing()
        devices.sessions[1].deliver(speechSecond)
        devices.target = airPods

        try capture.start()

        #expect(devices.sessions.last?.usesVoiceProcessing == false)
        #expect(devices.sessions.last?.device.id == airPods.id)
    }

    @Test func dropsAVoiceProcessingTrialWhenMovingToAnotherMic() throws {
        let capture = try captureTryingVoiceProcessing()
        devices.target = airPods

        try capture.start()
        _ = capture.finishSwitch()

        #expect(devices.sessions[1].isStopped)
    }

    @Test func passesOnVoiceProcessingThatFailsToStart() throws {
        devices.voiceProcessingFailure = MessageError("voice processing is unavailable")
        let capture = makeCapture()
        try capture.start()
        for _ in 0..<MicrophoneCapture.deadSecondsBeforeTrial { devices.sessions[0].deliver(silencedSecond) }

        #expect(throws: MessageError.self) { try capture.tryVoiceProcessing() }
        #expect(devices.sessions.count == 1)
    }

    @Test func turnsVoiceProcessingOnWhenAsked() throws {
        let capture = makeCapture()
        try capture.start()

        try capture.useVoiceProcessing(true)
        devices.sessions[1].deliver([0.2])
        _ = capture.finishSwitch()

        #expect(capture.usesVoiceProcessing)
        #expect(devices.sessions.map(\.usesVoiceProcessing) == [false, true])
        #expect(devices.sessions[0].isStopped)
        #expect(received.sessions == [2])
    }

    @Test func turnsVoiceProcessingOffWhenAsked() throws {
        let capture = makeCapture()
        try capture.start()
        try capture.useVoiceProcessing(true)
        devices.sessions[1].deliver([0.2])

        try capture.useVoiceProcessing(false)
        devices.sessions[2].deliver([0.3])

        #expect(!capture.usesVoiceProcessing)
        #expect(devices.sessions.map(\.usesVoiceProcessing) == [false, true, false])
    }

    @Test func doesNotTryVoiceProcessingRightAfterItWasTurnedOff() throws {
        let capture = makeCapture()
        try capture.start()
        try capture.useVoiceProcessing(true)
        devices.sessions[1].deliver([0.2])
        try capture.useVoiceProcessing(false)
        devices.sessions[2].deliver([0.3])

        for _ in 0..<10 { devices.sessions[2].deliver(silencedSecond) }
        try capture.tryVoiceProcessing()

        #expect(devices.sessions.count == 3)
    }

    @Test func turningVoiceProcessingOnEndsATrial() throws {
        let capture = try captureTryingVoiceProcessing()

        try capture.useVoiceProcessing(true)
        _ = capture.finishSwitch()

        #expect(devices.sessions[1].isStopped)
        #expect(devices.sessions.map(\.usesVoiceProcessing) == [false, true, true])
        #expect(capture.usesVoiceProcessing)
    }

    @Test func leavesTheMicAloneWhenAlreadyAsAsked() throws {
        let capture = makeCapture()
        try capture.start()

        try capture.useVoiceProcessing(false)

        #expect(devices.sessions.count == 1)
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
