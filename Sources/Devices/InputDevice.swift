import CoreAudio

struct InputDevice {
    let id: AudioDeviceID
    let name: String

    /// Every device that has at least one input channel.
    static func all() -> [InputDevice] {
        allDevices()
            .filter { inputChannelCount($0) > 0 }
            .compactMap { device in
                stringProperty(device, kAudioObjectPropertyName).map { InputDevice(id: device, name: $0) }
            }
    }

    /// Input devices whose name contains `query`, ignoring case and curly apostrophes.
    static func matching(_ query: String) -> [InputDevice] {
        all().filter { normalizedName($0.name).contains(normalizedName(query)) }
    }

    /// The macOS system input, or nil when there is none.
    static func systemInput() -> InputDevice? {
        let deviceID = defaultInputDevice()
        guard deviceID != kAudioObjectUnknown else { return nil }
        return InputDevice(id: deviceID, name: stringProperty(deviceID, kAudioObjectPropertyName) ?? "system input")
    }

    /// The current format of the device's first input stream.
    func streamFormat() throws -> AudioStreamBasicDescription {
        let streamsAddress = propertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        let streams = try readObjectIDs(id, streamsAddress, "listing \(name) streams")
        guard let firstStream = streams.first else { throw RecordingError("\(name) has no input") }
        return try readProperty(
            firstStream,
            propertyAddress(kAudioStreamPropertyVirtualFormat),
            initialValue: AudioStreamBasicDescription(),
            "reading \(name) format"
        )
    }

    private static func normalizedName(_ name: String) -> String {
        name.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
    }
}

/// Channels across all input streams; the stream configuration is a variable-length buffer list.
private func inputChannelCount(_ device: AudioDeviceID) -> Int {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let storage = UnsafeMutableRawPointer.allocate(
        byteCount: Int(size),
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return 0 }
    let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}
