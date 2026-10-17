import CoreAudio
import Foundation

package struct AudioLabError: Error, CustomStringConvertible {
    package let description: String

    package init(_ description: String) {
        self.description = description
    }
}

/// The system's audio devices, by name.
package enum AudioDevices {
    static let fakeDeviceUIDPrefix = "audiolab-"

    package static func exists(_ name: String) -> Bool {
        device(named: name) != nil
    }

    package static var defaultInput: String? {
        stringProperty(defaultDevice(kAudioHardwarePropertyDefaultInputDevice), kAudioObjectPropertyName)
    }

    package static var defaultOutput: String? {
        stringProperty(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice), kAudioObjectPropertyName)
    }

    package static func setDefaultInput(_ name: String) throws {
        try setDefault(kAudioHardwarePropertyDefaultInputDevice, to: name)
    }

    /// Sets both the output and the system output (alerts), so nothing plays anywhere else.
    package static func setDefaultOutput(_ name: String) throws {
        try setDefault(kAudioHardwarePropertyDefaultOutputDevice, to: name)
        try setDefault(kAudioHardwarePropertyDefaultSystemOutputDevice, to: name)
    }

    package static func setSampleRate(_ rate: Double, of name: String) async throws {
        let device = try requireDevice(named: name)
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var value = rate
        try check(
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value),
            "setting \(name) to \(Int(rate)) Hz"
        )
        try await waitUntil("\(name) to run at \(Int(rate)) Hz") { nominalSampleRate(device) == rate }
    }

    package static func waitUntilPresent(_ name: String) async throws {
        try await waitUntil("\(name) to appear") { exists(name) }
    }

    package static func waitUntilGone(_ name: String) async throws {
        try await waitUntil("\(name) to disappear") { !exists(name) }
    }

    /// Destroys fake microphones left behind by a test that crashed.
    package static func removeFakeMicrophones() {
        for device in allDevices()
        where stringProperty(device, kAudioDevicePropertyDeviceUID)?.hasPrefix(fakeDeviceUIDPrefix) == true {
            AudioHardwareDestroyAggregateDevice(device)
        }
    }

    static func requireDevice(named name: String) throws -> AudioDeviceID {
        guard let device = device(named: name) else { throw AudioLabError("no audio device named \"\(name)\"") }
        return device
    }

    static func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = propertyAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else {
            return nil
        }
        return value.takeRetainedValue() as String
    }

    static func nominalSampleRate(_ device: AudioDeviceID) -> Double {
        var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        var rate = 0.0
        var size = UInt32(MemoryLayout<Double>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate)
        return rate
    }

    static func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func check(_ status: OSStatus, _ action: String) throws {
        if status != noErr { throw AudioLabError("\(action) failed (OSStatus \(status))") }
    }

    private static let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private static func device(named name: String) -> AudioDeviceID? {
        allDevices().first { stringProperty($0, kAudioObjectPropertyName) == name }
    }

    private static func allDevices() -> [AudioDeviceID] {
        var address = propertyAddress(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &devices) == noErr else { return [] }
        return devices
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
        var address = propertyAddress(selector)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &device)
        return device
    }

    private static func setDefault(_ selector: AudioObjectPropertySelector, to name: String) throws {
        var address = propertyAddress(selector)
        var device = try requireDevice(named: name)
        try check(
            AudioObjectSetPropertyData(
                systemObject,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<AudioDeviceID>.size),
                &device
            ),
            "selecting \(name)"
        )
        guard defaultDevice(selector) == device else { throw AudioLabError("macOS refused \(name) as the default") }
    }

    private static func waitUntil(_ description: String, condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw AudioLabError("timed out waiting for \(description)") }
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
