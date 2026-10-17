import CoreAudio
import Foundation

/// A microphone that hears a known click track. It plays the clicks into a loopback device (whatever is played into
/// BlackHole comes back out of its input) and publishes an aggregate device wrapping it: a real input device that can
/// become the system input, change sample rate, and appear and disappear, the way AirPods do.
package final class FakeMicrophone: @unchecked Sendable {
    package let name: String
    private let player: ClickPlayer
    private var aggregate: AudioObjectID

    /// With `silentFor`, it delivers silence at first, like AirPods while they switch to their call profile.
    package init(name: String, loopback: String, tracks: [ClickTrack], silentFor: Double = 0) async throws {
        let loopbackDevice = try AudioDevices.requireDevice(named: loopback)
        guard let loopbackUID = AudioDevices.stringProperty(loopbackDevice, kAudioDevicePropertyDeviceUID) else {
            throw AudioLabError("cannot read the UID of \(loopback)")
        }
        let silentUntil = hostSeconds(AudioGetCurrentHostTime()) + silentFor
        player = try ClickPlayer(deviceNamed: loopback, tracks: tracks, silentUntil: silentUntil)

        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: name,
            kAudioAggregateDeviceUIDKey: AudioDevices.fakeDeviceUIDPrefix + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: loopbackUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: loopbackUID]],
        ]
        var aggregate = AudioObjectID(kAudioObjectUnknown)
        do {
            try AudioDevices.check(
                AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate),
                "creating fake microphone \(name)"
            )
        } catch {
            player.stop()
            throw error
        }
        self.name = name
        self.aggregate = aggregate
        try await AudioDevices.waitUntilPresent(name)
    }

    package func remove() async throws {
        guard aggregate != kAudioObjectUnknown else { return }
        AudioHardwareDestroyAggregateDevice(aggregate)
        aggregate = AudioObjectID(kAudioObjectUnknown)
        player.stop()
        try await AudioDevices.waitUntilGone(name)
    }
}

/// Plays a click track on an output device, the "system audio" every recording should capture.
package final class Speakers: @unchecked Sendable {
    private let player: ClickPlayer

    package init(deviceNamed name: String, track: ClickTrack) throws {
        player = try ClickPlayer(deviceNamed: name, tracks: [track])
    }

    package func stop() {
        player.stop()
    }
}
