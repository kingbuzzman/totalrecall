import Testing

@testable import TotalRecall

struct RecorderTests {
    let clock = Clock()
    let sink = CapturingSink()

    private func makeRecorder(
        microphone: Bool = true,
        isolation: Bool = true,
        echoCancellation: Bool = false,
        rawSink: AudioSink? = nil
    ) -> Recorder {
        Recorder(
            writingTo: sink,
            rawSink: rawSink,
            includesMicrophone: microphone,
            isolatesSpeakers: isolation,
            cancelsEcho: echoCancellation
        )
    }

    @Test func writesSystemAudioToBothChannelsWithoutAMicrophone() throws {
        let recorder = makeRecorder(microphone: false)
        recorder.appendSystem(ramp(4_800), hostTime: clock.at(milliseconds: 0))
        recorder.startRecording(at: clock.at(milliseconds: 0))
        recorder.stopRecording(at: clock.at(milliseconds: 100))

        try recorder.close()

        #expect(sink.left == ramp(4_800))
        #expect(sink.right == ramp(4_800))
        #expect(sink.isClosed)
    }

    @Test func putsTheMicrophoneLeftAndSystemAudioRight() throws {
        let recorder = makeRecorder()
        recorder.appendMicrophone(constant(0.25, count: 4_800), hostTime: clock.at(milliseconds: 0), session: 1)
        recorder.appendSystem(constant(-0.5, count: 4_800), hostTime: clock.at(milliseconds: 0))
        recorder.startRecording(at: clock.at(milliseconds: 0))
        recorder.stopRecording(at: clock.at(milliseconds: 100))

        try recorder.close()

        #expect(sink.left == constant(0.25, count: 4_800))
        #expect(sink.right == constant(-0.5, count: 4_800))
    }

    @Test func mixesBothIntoEachChannelWithoutIsolation() throws {
        let recorder = makeRecorder(isolation: false)
        recorder.appendMicrophone([0.25, 0.75, -0.75], hostTime: clock.at(milliseconds: 0), session: 1)
        recorder.appendSystem([0.5, 0.5, -0.5], hostTime: clock.at(milliseconds: 0))
        recorder.startRecording(at: clock.at(milliseconds: 0))
        recorder.stopRecording(at: clock.at(milliseconds: 1))

        try recorder.close()

        #expect(sink.left.prefix(3) == [0.75, 1, -1])
        #expect(sink.right == sink.left)
    }

    @Test func leavesOutWhatWasCapturedBeforeTheRecordingStarted() throws {
        let recorder = makeRecorder()
        recorder.appendMicrophone(ramp(9_600), hostTime: clock.at(milliseconds: 0), session: 1)
        recorder.appendSystem(ramp(9_600, scale: -1e-5), hostTime: clock.at(milliseconds: 0))
        recorder.startRecording(at: clock.at(milliseconds: 100))
        recorder.stopRecording(at: clock.at(milliseconds: 200))

        try recorder.close()

        #expect(sink.left == ramp(4_800, from: 4_800))
        #expect(sink.right == ramp(4_800, from: 4_800, scale: -1e-5))
    }

    @Test func delaysATrackThatStartedLate() throws {
        let recorder = makeRecorder()
        recorder.appendSystem(ramp(4_800), hostTime: clock.at(milliseconds: 0))
        recorder.appendMicrophone(ramp(2_400), hostTime: clock.at(milliseconds: 50), session: 1)
        recorder.startRecording(at: clock.at(milliseconds: 0))
        recorder.stopRecording(at: clock.at(milliseconds: 100))

        try recorder.close()

        #expect(sink.left == silence(2_400) + ramp(2_400))
        #expect(sink.right == ramp(4_800))
    }

    @Test func padsBothTracksWhenTheRecordingStartedBeforeEitherCapture() throws {
        let recorder = makeRecorder(microphone: false)
        recorder.startRecording(at: clock.at(milliseconds: 0))
        recorder.appendSystem(ramp(2_400), hostTime: clock.at(milliseconds: 50))
        recorder.stopRecording(at: clock.at(milliseconds: 100))

        try recorder.close()

        #expect(sink.right == silence(2_400) + ramp(2_400))
    }

    @Test func endsExactlyWhereTheRecordingStopped() throws {
        let recorder = makeRecorder(microphone: false)
        recorder.appendSystem(ramp(9_600), hostTime: clock.at(milliseconds: 0))
        recorder.startRecording(at: clock.at(milliseconds: 0))
        recorder.stopRecording(at: clock.at(milliseconds: 100))
        recorder.appendSystem(ramp(4_800), hostTime: clock.at(milliseconds: 200))

        try recorder.close()

        #expect(sink.right == ramp(4_800))
    }

    @Test func fillsTheEndWithSilenceWhenTheCapturesFellBehind() throws {
        let recorder = makeRecorder(microphone: false)
        recorder.appendSystem(ramp(2_400), hostTime: clock.at(milliseconds: 0))
        recorder.startRecording(at: clock.at(milliseconds: 0))
        recorder.stopRecording(at: clock.at(milliseconds: 100))

        try recorder.close()

        #expect(sink.right == ramp(2_400) + silence(2_400))
    }

    @Test func writesNothingBeforeTheRecordingStarts() throws {
        let recorder = makeRecorder(microphone: false)
        recorder.appendSystem(ramp(4_800), hostTime: clock.at(milliseconds: 0))

        try recorder.writeAvailable()

        #expect(sink.right.isEmpty)
    }

    @Test func waitsForBothTracksAndWritesWholeEchoCancellerFrames() throws {
        let recorder = makeRecorder()
        recorder.appendSystem(ramp(4_800), hostTime: clock.at(milliseconds: 0))
        recorder.startRecording(at: clock.at(milliseconds: 0))

        try recorder.writeAvailable()
        #expect(sink.left.isEmpty)

        recorder.appendMicrophone(ramp(4_800), hostTime: clock.at(milliseconds: 0), session: 1)
        try recorder.writeAvailable()
        #expect(sink.left.count == 4 * EchoCanceller.frameSize)

        recorder.stopRecording(at: clock.at(milliseconds: 100))
        try recorder.close()
        #expect(sink.left == ramp(4_800))
    }

    @Test func padsATrackThatFellMoreThanASecondBehind() throws {
        let recorder = makeRecorder()
        recorder.appendSystem(ramp(96_000), hostTime: clock.at(milliseconds: 0))
        recorder.appendMicrophone(ramp(4_800), hostTime: clock.at(milliseconds: 0), session: 1)
        recorder.startRecording(at: clock.at(milliseconds: 0))

        try recorder.writeAvailable()

        let written = 96_000 / EchoCanceller.frameSize * EchoCanceller.frameSize
        #expect(sink.right == ramp(written))
        #expect(sink.left == ramp(4_800) + silence(written - 4_800))
    }

    @Test func savesTheUnprocessedAudioIncludingThePreRollToTheRawSink() throws {
        let raw = CapturingSink()
        let recorder = makeRecorder(isolation: false, rawSink: raw)
        recorder.appendMicrophone(ramp(9_600), hostTime: clock.at(milliseconds: 0), session: 1)
        recorder.appendSystem(ramp(9_600, scale: -1e-5), hostTime: clock.at(milliseconds: 0))
        recorder.startRecording(at: clock.at(milliseconds: 100))
        recorder.stopRecording(at: clock.at(milliseconds: 200))

        try recorder.close()

        #expect(raw.left == ramp(9_600))
        #expect(raw.right == ramp(9_600, scale: -1e-5))
        #expect(raw.isClosed)
        #expect(sink.left.count == 4_800)
    }

    @Test func cancelsEchoWithoutChangingTheLength() throws {
        let recorder = makeRecorder(echoCancellation: true)
        var noise = Noise(seed: 7)
        recorder.appendMicrophone(
            noise.samples(96_000, amplitude: 0.1),
            hostTime: clock.at(milliseconds: 0),
            session: 1
        )
        recorder.appendSystem(noise.samples(96_000, amplitude: 0.1), hostTime: clock.at(milliseconds: 0))
        recorder.startRecording(at: clock.at(milliseconds: 1_000))
        recorder.stopRecording(at: clock.at(milliseconds: 1_990))

        try recorder.close()

        #expect(sink.left.count == frameCount(milliseconds: 990))
        #expect(sink.right.count == frameCount(milliseconds: 990))
    }

    @Test func isReadyOnceSystemAudioArrivesWithoutAMicrophone() {
        let recorder = makeRecorder(microphone: false)
        #expect(!recorder.isReadyToRecord)

        recorder.appendSystem(silence(480), hostTime: clock.at(milliseconds: 0))

        #expect(recorder.isReadyToRecord)
    }

    @Test func isReadyOnceTheMicrophoneMakesASound() {
        let recorder = makeRecorder()
        recorder.appendSystem(silence(480), hostTime: clock.at(milliseconds: 0))
        recorder.appendMicrophone(silence(480), hostTime: clock.at(milliseconds: 0), session: 1)
        #expect(!recorder.isReadyToRecord)

        recorder.appendMicrophone(constant(0.1, count: 480), hostTime: clock.at(milliseconds: 10), session: 1)

        #expect(recorder.isReadyToRecord)
    }

    @Test func waitsForTheEchoCancellersBaselineOfAmbientSound() {
        let early = makeRecorder(echoCancellation: true)
        early.appendSystem(silence(480), hostTime: clock.origin)
        early.appendMicrophone(constant(0.1, count: 480), hostTime: clock.origin, session: 1)
        #expect(!early.isReadyToRecord)

        let settled = makeRecorder(echoCancellation: true)
        settled.appendSystem(silence(480), hostTime: clock.origin)
        settled.appendMicrophone(constant(0.1, count: 480), hostTime: clock.before(milliseconds: 1_500), session: 1)
        #expect(settled.isReadyToRecord)
    }

    @Test func measuresTheRecordingFromStartToStop() {
        let recorder = makeRecorder(microphone: false)
        #expect(recorder.secondsRecorded == 0)

        recorder.startRecording(at: clock.at(milliseconds: 0))
        recorder.stopRecording(at: clock.at(milliseconds: 1_500))

        #expect(abs(recorder.secondsRecorded - 1.5) < 1e-6)
    }

    @Test func reportsPeaksSinceTheLastCall() {
        let recorder = makeRecorder()
        recorder.appendMicrophone([0.9], hostTime: clock.at(milliseconds: 0), session: 1)
        recorder.startRecording(at: clock.at(milliseconds: 0))
        recorder.appendMicrophone([0.2, -0.4], hostTime: clock.at(milliseconds: 1), session: 1)
        recorder.appendSystem([0.3], hostTime: clock.at(milliseconds: 1))

        let levels = recorder.levels()

        #expect(levels.microphonePeak == 0.4)
        #expect(levels.systemPeak == 0.3)
        #expect(recorder.levels().microphonePeak == 0)
    }

    @Test func tracksTimeSinceEachInputLastDeliveredAudio() {
        let recorder = makeRecorder()
        recorder.appendSystem(silence(480), hostTime: clock.at(milliseconds: 0))
        recorder.resetStallTimer(for: .microphone)

        #expect(recorder.secondsSinceAudio(from: .system) < 1)
        #expect(recorder.secondsSinceAudio(from: .microphone) < 1)
    }

    @Test func writesNothingOnceClosed() throws {
        let recorder = makeRecorder(microphone: false)
        recorder.startRecording(at: clock.at(milliseconds: 0))
        recorder.stopRecording(at: clock.at(milliseconds: 0))
        try recorder.close()

        recorder.appendSystem(ramp(4_800), hostTime: clock.at(milliseconds: 0))
        try recorder.writeAvailable(final: true)

        #expect(sink.right.isEmpty)
    }
}
