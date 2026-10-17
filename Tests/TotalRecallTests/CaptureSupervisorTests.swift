import Testing

@testable import TotalRecall

struct CaptureSupervisorTests {
    let recorder = Recorder(
        writingTo: CapturingSink(),
        includesMicrophone: true,
        isolatesSpeakers: true,
        cancelsEcho: false
    )
    let system = FakeSystemCapture()
    let devices = FakeMicrophones(target: macMic)
    let microphone: MicrophoneCapture
    let supervisor: CaptureSupervisor
    let announcements = Announcements()

    init() throws {
        microphone = devices.capture(onSamples: recorder.appendMicrophone)
        supervisor = CaptureSupervisor(
            recorder: recorder,
            systemCapture: system,
            microphoneCapture: microphone,
            announce: announcements.append
        )
        try microphone.start()
    }

    @Test func leavesCapturesThatDeliverAudioAlone() {
        supervisor.supervise()

        #expect(devices.sessions.count == 1)
        #expect(system.starts == 0)
        #expect(announcements.messages.isEmpty)
    }

    @Test func announcesACompletedMicSwitch() throws {
        devices.target = airPods
        try microphone.start()
        devices.sessions[1].deliver([0.2])

        supervisor.supervise()

        #expect(announcements.messages == ["mic -> AirPods Pro"])
    }

    @Test func restartsTheMicWhenItsDeviceChanges() {
        devices.sessions[0].changeDevice()

        supervisor.supervise()

        #expect(devices.sessions.count == 2)
    }

    @Test func movesToANewSystemInput() {
        devices.target = airPods
        supervisor.systemDevicesChanged()

        supervisor.supervise()

        #expect(devices.sessions.map(\.device.id) == [macMic.id, airPods.id])
    }

    @Test func ignoresDeviceChangesThatKeepTheSameMic() {
        supervisor.systemDevicesChanged()

        supervisor.supervise()

        #expect(devices.sessions.count == 1)
    }

    @Test func waitsBeforeRestartingTheMicAgain() async throws {
        devices.sessions[0].changeDevice()
        supervisor.supervise()
        devices.sessions[1].changeDevice()
        supervisor.supervise()
        #expect(devices.sessions.count == 2)

        try await Task.sleep(for: .seconds(0.55))
        keepAudioFlowing()
        supervisor.supervise()

        #expect(devices.sessions.count == 3)
    }

    @Test func restartsAMicThatStoppedDeliveringAudio() async throws {
        try await Task.sleep(for: .seconds(captureStallSeconds + 0.1))
        recorder.resetStallTimer(for: .system)

        supervisor.supervise()

        #expect(devices.sessions.count == 2)
        #expect(recorder.secondsSinceAudio(from: .microphone) < captureStallSeconds)
    }

    @Test func givesASwitchingMicTimeToStart() async throws {
        devices.target = airPods
        try microphone.start()

        try await Task.sleep(for: .seconds(captureStallSeconds + 0.1))
        recorder.resetStallTimer(for: .system)
        supervisor.supervise()

        #expect(devices.sessions.count == 2)
    }

    @Test func retriesAMicThatCannotStart() {
        devices.sessions[0].changeDevice()
        devices.failure = RecordingError("device is gone")

        supervisor.supervise()

        #expect(announcements.messages == ["mic unavailable, retrying: device is gone"])
    }

    @Test func restartsSystemAudioThatStoppedDelivering() async throws {
        try await Task.sleep(for: .seconds(captureStallSeconds + 0.1))
        recorder.resetStallTimer(for: .microphone)

        supervisor.supervise()

        #expect((system.stops, system.starts) == (1, 1))
        #expect(announcements.messages == ["system audio capture restarted"])
        #expect(recorder.secondsSinceAudio(from: .system) < captureStallSeconds)
    }

    @Test func retriesSystemAudioThatCannotStart() async throws {
        system.failure = RecordingError("tap failed")
        try await Task.sleep(for: .seconds(captureStallSeconds + 0.1))
        recorder.resetStallTimer(for: .microphone)

        supervisor.supervise()

        #expect(announcements.messages == ["system audio unavailable, retrying: tap failed"])
    }

    @Test func supervisesSystemAudioAloneWithoutAMic() async throws {
        let systemOnly = CaptureSupervisor(
            recorder: recorder,
            systemCapture: system,
            microphoneCapture: nil,
            announce: announcements.append
        )
        try await Task.sleep(for: .seconds(captureStallSeconds + 0.1))

        systemOnly.supervise()

        #expect(system.starts == 1)
        #expect(devices.sessions.count == 1)
    }

    private func keepAudioFlowing() {
        recorder.resetStallTimer(for: .microphone)
        recorder.resetStallTimer(for: .system)
    }
}

final class Announcements {
    private(set) var messages: [String] = []

    func append(_ message: String) {
        messages.append(message)
    }
}
