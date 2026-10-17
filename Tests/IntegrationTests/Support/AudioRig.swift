import AudioLab
import Foundation
import Testing

enum Pitch {
    static let micA = 1_000.0
    static let micB = 1_500.0
    static let system = 3_000.0
}

/// Fake audio hardware for one test: speakers playing system clicks and microphone A as the system input, both on
/// BlackHole loopback devices, so no real microphone or speakers are needed. Restores the system input and output
/// afterwards.
final class AudioRig: @unchecked Sendable {
    static let micALoopback = device("MIC_A_LOOPBACK", default: "BlackHole 2ch")
    static let micBLoopback = device("MIC_B_LOOPBACK", default: "BlackHole 16ch")
    static let speakersDevice = device("SPEAKERS", default: "BlackHole 64ch")
    static let systemOffsetMilliseconds = 50.0
    /// A device switch that cannot overlap (the old device is gone or restarting) may lose this much audio.
    static let restartGapMilliseconds = 500.0

    static var isInstalled: Bool {
        [micALoopback, micBLoopback, speakersDevice].allSatisfy(AudioDevices.exists)
    }

    @TaskLocal static var current: AudioRig?

    let micA: FakeMicrophone
    private let speakers: Speakers
    private let originalInput: String?
    private let originalOutput: String?
    private var microphones: [FakeMicrophone] = []

    private init(micA: FakeMicrophone, speakers: Speakers, originalInput: String?, originalOutput: String?) {
        self.micA = micA
        self.speakers = speakers
        self.originalInput = originalInput
        self.originalOutput = originalOutput
        microphones = [micA]
    }

    static func start() async throws -> AudioRig {
        guard isInstalled else {
            throw AudioLabError(
                "missing the test devices; install them with: brew install --cask blackhole-2ch blackhole-16ch blackhole-64ch"
            )
        }
        AudioDevices.removeFakeMicrophones()
        let (originalInput, originalOutput) = (AudioDevices.defaultInput, AudioDevices.defaultOutput)
        try AudioDevices.setDefaultOutput(speakersDevice)
        let speakers = try Speakers(
            deviceNamed: speakersDevice,
            track: ClickTrack(pitch: Pitch.system, offsetMilliseconds: systemOffsetMilliseconds)
        )
        do {
            let micA = try await FakeMicrophone(
                name: "audiolab A",
                loopback: micALoopback,
                tracks: [ClickTrack(pitch: Pitch.micA)]
            )
            try AudioDevices.setDefaultInput(micA.name)
            return AudioRig(
                micA: micA,
                speakers: speakers,
                originalInput: originalInput,
                originalOutput: originalOutput
            )
        } catch {
            speakers.stop()
            AudioDevices.removeFakeMicrophones()
            throw error
        }
    }

    /// Microphone B, on its own loopback device; removed with the rig if the test does not remove it.
    func addMicB(
        tracks: [ClickTrack] = [ClickTrack(pitch: Pitch.micB)],
        silentFor: Double = 0
    ) async throws -> FakeMicrophone {
        try await addMicrophone(name: "audiolab B", tracks: tracks, silentFor: silentFor)
    }

    func addMicrophone(name: String, tracks: [ClickTrack], silentFor: Double = 0) async throws -> FakeMicrophone {
        let microphone = try await FakeMicrophone(
            name: name,
            loopback: Self.micBLoopback,
            tracks: tracks,
            silentFor: silentFor
        )
        microphones.append(microphone)
        return microphone
    }

    func tearDown() async {
        for microphone in microphones { try? await microphone.remove() }
        speakers.stop()
        AudioDevices.removeFakeMicrophones()
        if let originalInput, AudioDevices.exists(originalInput) { try? AudioDevices.setDefaultInput(originalInput) }
        if let originalOutput, AudioDevices.exists(originalOutput) {
            try? AudioDevices.setDefaultOutput(originalOutput)
        }
    }

    private static func device(_ variable: String, default name: String) -> String {
        ProcessInfo.processInfo.environment[variable] ?? name
    }
}

/// Gives each test case its own `AudioRig.current`.
struct AudioRigTrait: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> AudioRigTrait? {
        testCase == nil ? nil : self
    }

    @concurrent func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        let rig = try await AudioRig.start()
        do {
            try await AudioRig.$current.withValue(rig) { try await function() }
        } catch {
            await rig.tearDown()
            throw error
        }
        await rig.tearDown()
    }
}

extension Trait where Self == AudioRigTrait {
    static var audioRig: Self { AudioRigTrait() }
}

extension Trait where Self == ConditionTrait {
    /// Skips the tests without the test devices, except on CI, where they fail instead.
    static var needsAudioRig: Self {
        .enabled(
            if: AudioRig.isInstalled || TestEnvironment.isCI,
            "needs the BlackHole test devices: brew install --cask blackhole-2ch blackhole-16ch blackhole-64ch"
        )
    }
}
