package import CoreAudio
import Foundation

// Thin helpers over the Core Audio object property API.

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func ensure(_ status: OSStatus, _ action: String) throws {
    if status != noErr { throw RecordingError("\(action) failed (OSStatus \(status))") }
}

func propertyAddress(
    _ selector: AudioObjectPropertySelector,
    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

/// Reads a fixed-size property; `action` describes the read in the error, such as "reading MacBook Mic format".
func readProperty<Value>(
    _ object: AudioObjectID,
    _ address: AudioObjectPropertyAddress,
    initialValue: Value,
    _ action: String = "reading audio property"
) throws -> Value {
    var address = address
    var value = initialValue
    var size = UInt32(MemoryLayout<Value>.size)
    let status = withUnsafeMutablePointer(to: &value) {
        AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
    }
    try ensure(status, action)
    return value
}

/// Reads a property that lists audio objects, such as a device's streams.
func readObjectIDs(
    _ object: AudioObjectID,
    _ address: AudioObjectPropertyAddress,
    _ action: String = "listing audio objects"
) throws -> [AudioObjectID] {
    var address = address
    var size: UInt32 = 0
    try ensure(AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size), action)
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard !objects.isEmpty else { return [] }
    try ensure(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &objects), action)
    return objects
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    let value = try? readProperty(object, propertyAddress(selector), initialValue: Unmanaged<CFString>?.none)
    return value?.takeRetainedValue() as String?
}

package func defaultInputDevice() -> AudioDeviceID {
    let address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    let unknown = AudioDeviceID(kAudioObjectUnknown)
    return (try? readProperty(systemObject, address, initialValue: unknown)) ?? unknown
}

func allDevices() -> [AudioDeviceID] {
    (try? readObjectIDs(systemObject, propertyAddress(kAudioHardwarePropertyDevices))) ?? []
}

/// Calls `handler` on `queue` whenever the system input, the system output, or the list of devices changes, until the
/// returned function is called.
func onSystemDeviceChange(queue: DispatchQueue, _ handler: @escaping () -> Void) -> () -> Void {
    let addresses = [
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioHardwarePropertyDevices,
    ].map { propertyAddress($0) }
    // Removing a listener takes the very block that was added.
    let listener: AudioObjectPropertyListenerBlock = { _, _ in handler() }
    for var address in addresses {
        AudioObjectAddPropertyListenerBlock(systemObject, &address, queue, listener)
    }
    return {
        for var address in addresses {
            AudioObjectRemovePropertyListenerBlock(systemObject, &address, queue, listener)
        }
    }
}
