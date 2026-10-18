import AudioLab
import Foundation
import Shared
import Testing

/// totalrecall against fake microphones and speakers, checked by the click tracks it records.
@Suite(.serialized, .needsAudioRig, .audioRig)
struct RecordingTests {
    var rig: AudioRig { AudioRig.current! }

    @Test func recordsTheMicLeftAndSystemAudioRightInSync() async throws {
        let recording = try await TotalRecallProcess.record(
            to: TestEnvironment.result("baseline.wav"),
            "--no-echo-cancellation"
        )
        try await Task.sleep(for: .seconds(6))
        expectSaved(await recording.stop(), recording)

        let file = try Recording(contentsOf: recording.output)
        expectNoLostAudio(file.clicks(on: .left, pitches: [Pitch.micA], skipStart: 0.5, skipEnd: 0.3), atLeast: 45)
        expectNoLostAudio(file.clicks(on: .right, pitches: [Pitch.system], skipStart: 0.5, skipEnd: 0.3), atLeast: 45)
        let sync = try file.sync(leftPitches: [Pitch.micA], rightPitch: Pitch.system)
        #expect(sync.driftMilliseconds <= 10, "\(sync)")
    }

    @Test func switchesToANewSystemInputWithoutLosingAudio() async throws {
        let micB = try await rig.addMicB()
        let recording = try await TotalRecallProcess.record(
            to: TestEnvironment.result("switch.wav"),
            "--no-echo-cancellation"
        )
        try await Task.sleep(for: .seconds(2))
        try AudioDevices.setDefaultInput(micB.name)
        try await Task.sleep(for: .seconds(4))
        expectSaved(await recording.stop(), recording)

        let mic = try Recording(contentsOf: recording.output)
            .clicks(on: .left, pitches: [Pitch.micA, Pitch.micB], skipStart: 0.5, skipEnd: 0.3)
        #expect(mic.pitchOrder == [Pitch.micA, Pitch.micB], "\(mic)")
        expectNoLostAudio(mic)
    }

    /// AirPods deliver silence for about 2 s while Bluetooth switches to the call profile; the old mic covers it.
    @Test func keepsTheOldMicUntilTheNewOneDeliversSound() async throws {
        let micB = try await rig.addMicB(silentFor: 4)
        let recording = try await TotalRecallProcess.record(
            to: TestEnvironment.result("switch-slow.wav"),
            "--no-echo-cancellation"
        )
        try await Task.sleep(for: .seconds(1.5))
        try AudioDevices.setDefaultInput(micB.name)
        try await Task.sleep(for: .seconds(5))
        expectSaved(await recording.stop(), recording)

        let mic = try Recording(contentsOf: recording.output)
            .clicks(on: .left, pitches: [Pitch.micA, Pitch.micB], skipStart: 0.5, skipEnd: 0.3)
        #expect(mic.pitchOrder == [Pitch.micA, Pitch.micB], "\(mic)")
        expectNoLostAudio(mic)
    }

    @Test func keepsRecordingThroughSampleRateChanges() async throws {
        let recording = try await TotalRecallProcess.record(
            to: TestEnvironment.result("rate-change.wav"),
            "--no-echo-cancellation"
        )
        try await Task.sleep(for: .seconds(2))
        try await AudioDevices.setSampleRate(44_100, of: rig.micA.name)
        try await Task.sleep(for: .seconds(2))
        try await AudioDevices.setSampleRate(48_000, of: rig.micA.name)
        try await Task.sleep(for: .seconds(3))
        expectSaved(await recording.stop(), recording)

        let file = try Recording(contentsOf: recording.output)
        let whole = file.clicks(on: .left, pitches: [Pitch.micA], skipStart: 0.5, skipEnd: 0.3)
        #expect(whole.longestGapMilliseconds <= 2 * AudioRig.restartGapMilliseconds, "\(whole)")
        #expect(whole.count >= 50, "\(whole)")
        expectNoLostAudio(file.clicks(on: .left, pitches: [Pitch.micA], last: 2, skipEnd: 0.3))
    }

    @Test func prefersTheNamedMicWheneverItIsPresent() async throws {
        let micB = try await rig.addMicB()
        let recording = try await TotalRecallProcess.record(
            to: TestEnvironment.result("preferred.wav"),
            "--no-echo-cancellation",
            "--mic",
            micB.name
        )
        try await Task.sleep(for: .seconds(2))
        try await micB.remove()
        try await Task.sleep(for: .seconds(2))
        _ = try await rig.addMicB()
        try await Task.sleep(for: .seconds(3))
        expectSaved(await recording.stop(), recording)

        let mic = try Recording(contentsOf: recording.output)
            .clicks(on: .left, pitches: [Pitch.micA, Pitch.micB], skipStart: 0.5, skipEnd: 0.3)
        #expect(mic.pitchOrder == [Pitch.micB, Pitch.micA, Pitch.micB], "\(mic)")
        #expect(mic.longestGapMilliseconds <= AudioRig.restartGapMilliseconds, "\(mic)")
    }

    @Test func endsUpOnTheLastInputAfterRapidSwitching() async throws {
        let micB = try await rig.addMicB()
        let recording = try await TotalRecallProcess.record(
            to: TestEnvironment.result("flapping.wav"),
            "--no-echo-cancellation"
        )
        for _ in 1...10 {
            try AudioDevices.setDefaultInput(micB.name)
            try await Task.sleep(for: .seconds(0.15))
            try AudioDevices.setDefaultInput(rig.micA.name)
            try await Task.sleep(for: .seconds(0.15))
        }
        try AudioDevices.setDefaultInput(micB.name)
        try await Task.sleep(for: .seconds(3))
        expectSaved(await recording.stop(), recording)

        let end = try Recording(contentsOf: recording.output)
            .clicks(on: .left, pitches: [Pitch.micA, Pitch.micB], last: 1.5, skipEnd: 0.3)
        #expect(end.pitchOrder == [Pitch.micB], "\(end)")
        #expect(end.longestGapMilliseconds == 0, "\(end)")
    }

    /// The fake mic hears the system clicks 60 ms late at -12 dB, like a laptop mic hearing its speakers.
    @Test func cancelsTheSpeakersEchoOnTheMic() async throws {
        let echoTrack = ClickTrack(
            pitch: Pitch.system,
            offsetMilliseconds: AudioRig.systemOffsetMilliseconds + 60,
            gainDecibels: -12
        )
        let echoMic = try await rig.addMicrophone(
            name: "audiolab echo",
            tracks: [ClickTrack(pitch: Pitch.micB), echoTrack]
        )
        try AudioDevices.setDefaultInput(echoMic.name)

        let raw = try await TotalRecallProcess.record(
            to: TestEnvironment.result("echo-raw.wav"),
            "--no-echo-cancellation"
        )
        try await Task.sleep(for: .seconds(6))
        expectSaved(await raw.stop(), raw)
        let cancelled = try await TotalRecallProcess.record(to: TestEnvironment.result("echo-cancelled.wav"))
        try await Task.sleep(for: .seconds(6))
        expectSaved(await cancelled.stop(), cancelled)

        let rawEcho = try Recording(contentsOf: raw.output).level(on: .left, pitch: Pitch.system, skipStart: 2)
        let cancelledEcho = try Recording(contentsOf: cancelled.output).level(
            on: .left,
            pitch: Pitch.system,
            skipStart: 2
        )
        #expect(rawEcho - cancelledEcho >= 10, "echo on the mic: \(rawEcho) dB raw, \(cancelledEcho) dB cancelled")
    }

    @Test func mixesBothIntoEachChannelWithoutSpeakerIsolation() async throws {
        let recording = try await TotalRecallProcess.record(
            to: TestEnvironment.result("mixed.wav"),
            "--no-echo-cancellation",
            "--no-speaker-isolation"
        )
        try await Task.sleep(for: .seconds(4))
        expectSaved(await recording.stop(), recording)

        let file = try Recording(contentsOf: recording.output)
        for (channel, pitch) in [(Channel.left, Pitch.micA), (.left, Pitch.system), (.right, Pitch.micA)] {
            let clicks = file.clicks(on: channel, pitches: [pitch], skipStart: 0.5)
            #expect(clicks.count >= 30, "\(Int(pitch)) Hz: \(clicks)")
        }
    }

    @Test func recordsSystemAudioOnBothChannelsWithoutAMic() async throws {
        let recording = try await TotalRecallProcess.record(to: TestEnvironment.result("no-mic.wav"), "--no-mic")
        try await Task.sleep(for: .seconds(3))
        expectSaved(await recording.stop(), recording)

        let file = try Recording(contentsOf: recording.output)
        #expect(file.left == file.right)
        expectNoLostAudio(file.clicks(on: .right, pitches: [Pitch.system], skipStart: 0.5, skipEnd: 0.3), atLeast: 20)
    }

    @Test(arguments: [SIGINT, SIGTERM, SIGHUP])
    func savesOnEveryStopSignal(_ stopSignal: Int32) async throws {
        let output = TestEnvironment.result("signal-\(stopSignal).wav")
        let recording = try await TotalRecallProcess.record(to: output, "--no-echo-cancellation")
        try await Task.sleep(for: .seconds(2))
        expectSaved(await recording.stop(stopSignal), recording)

        #expect(try Recording(contentsOf: output).duration >= 1.5)
        #expect(!FileManager.default.fileExists(atPath: output.path + ".partial.caf"))
    }

    @Test func keepsTheRecordingSoFarWhenKilled() async throws {
        let output = TestEnvironment.result("killed.wav")
        let recording = try await TotalRecallProcess.record(to: output, "--no-echo-cancellation")
        try await Task.sleep(for: .seconds(2.5))
        #expect(await recording.stop(SIGKILL) == SIGKILL)

        let partial = try Recording(contentsOf: URL(fileURLWithPath: output.path + ".partial.caf"))
        #expect(partial.duration >= 1.5)
        let system = partial.clicks(on: .right, pitches: [Pitch.system])
        #expect(system.count >= 15, "\(system)")
    }

    @Test(arguments: [
        ("m4a", "aac"), ("wav", "lpcm"), ("aiff", "lpcm"), ("caf", "lpcm"), ("mp3", ".mp3"), ("flac", "flac"),
    ])
    func writesTheFormatOfTheExtension(fileExtension: String, codec: String) async throws {
        let recording = try await TotalRecallProcess.record(
            to: TestEnvironment.result("format.\(fileExtension)"),
            "--no-echo-cancellation"
        )
        try await Task.sleep(for: .seconds(2.5))
        expectSaved(await recording.stop(), recording)

        let file = try Recording(contentsOf: recording.output)
        #expect(file.fileFormat == Recording.FileFormat(codec: codec, channelCount: 2, sampleRate: 48_000))
        let system = file.clicks(on: .right, pitches: [Pitch.system])
        #expect(system.count >= 15, "\(system)")
    }

    @Test func streamsWAVToStandardOutput() async throws {
        let pipe = Pipe()
        let streaming = try await TotalRecallProcess.stream(
            to: pipe,
            logTo: TestEnvironment.result("stream.log"),
            "--no-echo-cancellation"
        )
        async let received = pipe.fileHandleForReading.readAll()
        try await Task.sleep(for: .seconds(4))
        expectSaved(await streaming.stop(), streaming)

        let stream = await received
        let reader = try WAVStreamReader(handle: .reading(stream))
        var (left, right) = ([Float](), [Float]())
        while let chunk = try reader.read(maxFrames: 4_800) {
            left += chunk[0]
            right += chunk[1]
        }
        let audio = Recording(left: left, right: right, sampleRate: reader.sampleRate)
        #expect(reader.sampleRate == 48_000)
        expectNoLostAudio(audio.clicks(on: .left, pitches: [Pitch.micA], skipStart: 0.5, skipEnd: 0.3), atLeast: 25)
        expectNoLostAudio(audio.clicks(on: .right, pitches: [Pitch.system], skipStart: 0.5, skipEnd: 0.3), atLeast: 25)
    }

    @Test func stopsWhenTheProgramReadingTheStreamExits() async throws {
        let pipe = Pipe()
        let streaming = try await TotalRecallProcess.stream(
            to: pipe,
            logTo: TestEnvironment.result("stream-closed.log")
        )
        try await Task.sleep(for: .seconds(1))
        try pipe.fileHandleForReading.close()

        expectSaved(await streaming.waitForExit(), streaming)
        #expect(streaming.logText.contains("(the program reading it exited)"))
    }

    @Test func streamsWhileSavingTheFile() async throws {
        let pipe = Pipe()
        let recording = try await TotalRecallProcess.recordAndStream(
            to: TestEnvironment.result("stream-and-file.wav"),
            pipe: pipe,
            "--no-echo-cancellation"
        )
        async let received = pipe.fileHandleForReading.readAll()
        try await Task.sleep(for: .seconds(4))
        expectSaved(await recording.stop(), recording)

        let reader = try WAVStreamReader(handle: .reading(await received))
        var streamed = [Float]()
        while let chunk = try reader.read(maxFrames: 4_800) { streamed += chunk[0] }
        let stream = Recording(left: streamed, right: streamed, sampleRate: reader.sampleRate)
        expectNoLostAudio(stream.clicks(on: .left, pitches: [Pitch.micA], skipStart: 0.5, skipEnd: 0.3), atLeast: 25)
        let file = try Recording(contentsOf: recording.output)
        expectNoLostAudio(file.clicks(on: .left, pitches: [Pitch.micA], skipStart: 0.5, skipEnd: 0.3), atLeast: 25)
        expectNoLostAudio(file.clicks(on: .right, pitches: [Pitch.system], skipStart: 0.5, skipEnd: 0.3), atLeast: 25)
    }

    /// The file is what matters: when the program reading the stream exits, totalrecall keeps recording it.
    @Test func keepsSavingTheFileWhenTheProgramReadingTheStreamExits() async throws {
        let pipe = Pipe()
        let recording = try await TotalRecallProcess.recordAndStream(
            to: TestEnvironment.result("stream-closed-file.wav"),
            pipe: pipe,
            "--no-echo-cancellation"
        )
        try await Task.sleep(for: .seconds(1))
        try pipe.fileHandleForReading.close()
        try await Task.sleep(for: .seconds(4))
        expectSaved(await recording.stop(), recording)

        #expect(recording.logText.contains("the program reading the stream exited; still recording to"))
        let file = try Recording(contentsOf: recording.output)
        #expect(file.duration >= 4.5, "\(file.duration) s")
        expectNoLostAudio(file.clicks(on: .left, pitches: [Pitch.micA], skipStart: 0.5, skipEnd: 0.3), atLeast: 35)
    }

    /// EXPERIMENT (speaker-dropouts.yml): the speakers' own loopback recorded as the mic (left) next to the tap (right).
    /// Clicks missing on both mean the player stalled; missing only on the right mean the tap dropped a player that kept
    /// playing.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["SPEAKER_DROPOUTS"] == "1", "set SPEAKER_DROPOUTS=1 to run"))
    func witnessesTheSpeakers() async throws {
        let recording = try await TotalRecallProcess.record(
            to: TestEnvironment.result("witness.wav"),
            "--no-echo-cancellation",
            "--mic",
            AudioRig.speakersDevice
        )
        try await Task.sleep(for: .seconds(30))
        expectSaved(await recording.stop(), recording)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["LONG"] == "1", "set LONG=1 to run"))
    func staysInSyncOverTwoMinutes() async throws {
        let recording = try await TotalRecallProcess.record(
            to: TestEnvironment.result("long.wav"),
            "--no-echo-cancellation"
        )
        try await Task.sleep(for: .seconds(120))
        expectSaved(await recording.stop(), recording)

        let file = try Recording(contentsOf: recording.output)
        expectNoLostAudio(file.clicks(on: .left, pitches: [Pitch.micA], skipStart: 0.5, skipEnd: 0.3))
        let sync = try file.sync(leftPitches: [Pitch.micA], rightPitch: Pitch.system)
        #expect(sync.driftMilliseconds <= 20, "\(sync)")
        #expect(file.duration >= 119)
    }
}
