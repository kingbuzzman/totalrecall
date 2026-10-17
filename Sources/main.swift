import AVFoundation
import CoreAudio
import Foundation

let sampleRate = 48_000.0
let monoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2)!
let startupGraceSeconds = 2.0
let maxLagFrames = Int(sampleRate * 1.0)
let maxStartOffsetFrames = Int(sampleRate * 5.0)
let gapFillThresholdFrames = Int(sampleRate * 0.1)
let echoTailSeconds = 0.12
let captureStallSeconds = 0.6
let switchTimeoutSeconds = 5.0
let restartRetrySeconds = 0.5
let silentSystemWarningSeconds = 10.0
let meterWidth = 10
let meterFloorDecibels: Float = -60

let usage = """
    usage: totalrecall [--mic NAME | --no-mic] [--no-speaker-isolation] [--no-echo-cancellation] [--force] <output-file>
           totalrecall --list-mics

    Records all system audio plus a microphone until Ctrl-C, then saves <output-file>.
    By default your microphone goes to the left channel and everyone else (system audio) to the right.
    The microphone follows the system input, so plugging in or removing AirPods switches it mid-recording.
    Format follows the extension: .m4a .wav .aiff .caf natively, anything else (.mp3, .flac, ...) via ffmpeg.

      --mic NAME                prefer this microphone whenever it is available (case-insensitive substring of a
                                --list-mics name); falls back to the system input when it is not
      --no-mic                  record system audio only
      --no-speaker-isolation    mix microphone and system audio into both channels instead of splitting them left/right
      --no-echo-cancellation    keep the raw microphone signal, including speaker audio it picks up
      --force                   overwrite <output-file> if it exists
    """

func fail(_ message: String) -> Never {
    fputs("totalrecall: \(message)\n", stderr)
    exit(1)
}

struct CaptureError: LocalizedError {
    let errorDescription: String?
}

func ensure(_ status: OSStatus, _ action: String) throws {
    if status != noErr { throw CaptureError(errorDescription: "\(action) failed (OSStatus \(status))") }
}

func uptimeSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

// MARK: - Core Audio devices

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func propertyAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func defaultInputDevice() -> AudioDeviceID {
    var address = propertyAddress(kAudioHardwarePropertyDefaultInputDevice)
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
    return deviceID
}

func allDevices() -> [AudioDeviceID] {
    var address = propertyAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &devices) == noErr else { return [] }
    return devices
}

func inputChannelCount(_ device: AudioDeviceID) -> Int {
    var address = propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
    let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
    defer { storage.deallocate() }
    guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return 0 }
    let buffers = UnsafeMutableAudioBufferListPointer(storage.assumingMemoryBound(to: AudioBufferList.self))
    return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
}

struct InputDevice {
    let id: AudioDeviceID
    let name: String
}

func inputDevices() -> [InputDevice] {
    allDevices()
        .filter { inputChannelCount($0) > 0 }
        .compactMap { device in stringProperty(device, kAudioObjectPropertyName).map { InputDevice(id: device, name: $0) } }
}

func normalizedDeviceName(_ name: String) -> String {
    name.replacingOccurrences(of: "\u{2019}", with: "'").lowercased()
}

func inputDevices(matching query: String) -> [InputDevice] {
    inputDevices().filter { normalizedDeviceName($0.name).contains(normalizedDeviceName(query)) }
}

func listMicrophones() {
    let defaultDevice = defaultInputDevice()
    for device in inputDevices() {
        print("\(device.id == defaultDevice ? "*" : " ") \(device.name)")
    }
}

func onSystemDeviceChange(queue: DispatchQueue, _ handler: @escaping () -> Void) {
    for selector in [kAudioHardwarePropertyDefaultInputDevice, kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDevices] {
        var address = propertyAddress(selector)
        AudioObjectAddPropertyListenerBlock(systemObject, &address, queue) { _, _ in handler() }
    }
}

// MARK: - Capture

final class Resampler {
    private let converter: AVAudioConverter
    var inputSampleRate: Double { converter.inputFormat.sampleRate }

    init(from format: AVAudioFormat) throws {
        guard let converter = AVAudioConverter(from: format, to: monoFormat) else {
            throw CaptureError(errorDescription: "cannot convert audio from \(format)")
        }
        converter.downmix = true
        self.converter = converter
    }

    func monoSamples(from buffer: AVAudioPCMBuffer) -> [Float] {
        let ratio = monoFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: capacity) else { return [] }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, inputStatus in
            if consumed {
                inputStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            inputStatus.pointee = .haveData
            return buffer
        }
        if error != nil { return [] }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }
}

/// Taps the mixed output of every process via a Core Audio process tap (macOS 14.2+), so no loopback driver is needed.
final class SystemAudioCapture {
    private let onSamples: ([Float], UInt64) -> Void
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    init(onSamples: @escaping ([Float], UInt64) -> Void) {
        self.onSamples = onSamples
    }

    func start() throws {
        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        tapDescription.uuid = UUID()
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted
        try ensure(AudioHardwareCreateProcessTap(tapDescription, &tapID), "creating system audio tap")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "totalrecall",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString, kAudioSubTapDriftCompensationKey: true],
            ],
        ]
        try ensure(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID), "creating system audio device")

        var address = propertyAddress(kAudioTapPropertyFormat)
        var streamDescription = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try ensure(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &streamDescription), "reading system audio format")
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw CaptureError(errorDescription: "unsupported system audio format")
        }

        let resampler = try Resampler(from: format)
        let onSamples = onSamples
        try ensure(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, inputData, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else { return }
            onSamples(resampler.monoSamples(from: buffer), inputTime.pointee.mHostTime)
        }, "registering system audio callback")
        try ensure(AudioDeviceStart(aggregateID, ioProcID), "starting system audio capture")
    }

    func stop() {
        if let ioProcID {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            self.ioProcID = nil
        }
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }
}

func inputStreamFormat(of device: InputDevice) throws -> AudioStreamBasicDescription {
    var streamsAddress = propertyAddress(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
    var size: UInt32 = 0
    try ensure(AudioObjectGetPropertyDataSize(device.id, &streamsAddress, 0, nil, &size), "listing \(device.name) streams")
    var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
    guard !streams.isEmpty else { throw CaptureError(errorDescription: "\(device.name) has no input") }
    try ensure(AudioObjectGetPropertyData(device.id, &streamsAddress, 0, nil, &size, &streams), "listing \(device.name) streams")
    var formatAddress = propertyAddress(kAudioStreamPropertyVirtualFormat)
    var format = AudioStreamBasicDescription()
    var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    try ensure(AudioObjectGetPropertyData(streams[0], &formatAddress, 0, nil, &formatSize, &format), "reading \(device.name) format")
    return format
}

/// One Core Audio capture of a single input device, read straight from the device so it always uses the device's
/// current format (AirPods change sample rate when their mic turns on).
final class MicrophoneSession {
    let device: InputDevice
    let id: Int
    let startedAt = uptimeSeconds()
    private var ioProcID: AudioDeviceIOProcID?
    private var deviceListener: AudioObjectPropertyListenerBlock?
    private static let deviceChangeAddresses = [
        propertyAddress(kAudioDevicePropertyNominalSampleRate),
        propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput),
        propertyAddress(kAudioDevicePropertyDeviceIsAlive),
    ]

    init(device: InputDevice, id: Int, onSamples: @escaping (Int, [Float], UInt64) -> Void, onDeviceChange: @escaping () -> Void) throws {
        self.device = device
        self.id = id
        let streamFormat = try inputStreamFormat(of: device)
        let isFloat32 = streamFormat.mFormatID == kAudioFormatLinearPCM
            && streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && streamFormat.mBitsPerChannel == 32
        guard isFloat32, let firstChannelFormat = AVAudioFormat(standardFormatWithSampleRate: streamFormat.mSampleRate, channels: 1) else {
            throw CaptureError(errorDescription: "unsupported \(device.name) format")
        }
        let resampler = try Resampler(from: firstChannelFormat)
        var procID: AudioDeviceIOProcID?
        try ensure(AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil) { _, inputData, inputTime, _, _ in
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let firstBuffer = buffers.first, let data = firstBuffer.mData, firstBuffer.mNumberChannels > 0 else { return }
            // Built-in mic arrays deliver several interleaved channels; channel 0 is a complete microphone signal.
            let channelCount = Int(firstBuffer.mNumberChannels)
            let frameCount = Int(firstBuffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
            guard frameCount > 0, let firstChannel = AVAudioPCMBuffer(pcmFormat: firstChannelFormat, frameCapacity: AVAudioFrameCount(frameCount)) else { return }
            firstChannel.frameLength = AVAudioFrameCount(frameCount)
            let interleaved = data.assumingMemoryBound(to: Float.self)
            let destination = firstChannel.floatChannelData![0]
            for frame in 0..<frameCount { destination[frame] = interleaved[frame * channelCount] }
            onSamples(id, resampler.monoSamples(from: firstChannel), inputTime.pointee.mHostTime)
        }, "listening to \(device.name)")
        guard let procID else { throw CaptureError(errorDescription: "listening to \(device.name) failed") }
        do {
            try ensure(AudioDeviceStart(device.id, procID), "starting \(device.name)")
        } catch {
            AudioDeviceDestroyIOProcID(device.id, procID)
            throw error
        }
        ioProcID = procID
        let deviceListener: AudioObjectPropertyListenerBlock = { _, _ in onDeviceChange() }
        for var address in Self.deviceChangeAddresses {
            AudioObjectAddPropertyListenerBlock(device.id, &address, nil, deviceListener)
        }
        self.deviceListener = deviceListener
    }

    func stop() {
        if let deviceListener {
            for var address in Self.deviceChangeAddresses {
                AudioObjectRemovePropertyListenerBlock(device.id, &address, nil, deviceListener)
            }
        }
        deviceListener = nil
        if let ioProcID {
            AudioDeviceStop(device.id, ioProcID)
            AudioDeviceDestroyIOProcID(device.id, ioProcID)
        }
        ioProcID = nil
    }
}

/// Records the preferred microphone when it is present, otherwise the system input. Switching is make-before-break:
/// the old microphone keeps recording until the new one delivers real audio, which hides the ~2 s AirPods take to
/// switch Bluetooth into their call profile.
final class MicrophoneCapture {
    private let preferredName: String?
    private let onSamples: ([Float], UInt64) -> Void
    private let onDeviceChange: () -> Void
    private let lock = NSLock()
    private var active: MicrophoneSession?
    private var pending: MicrophoneSession?
    private var replaced: [MicrophoneSession] = []
    private var switchedTo: InputDevice?
    private var lastActiveAudioUptime = 0.0
    private var nextSessionID = 0

    init(preferredName: String?, onSamples: @escaping ([Float], UInt64) -> Void, onDeviceChange: @escaping () -> Void) {
        self.preferredName = preferredName
        self.onSamples = onSamples
        self.onDeviceChange = onDeviceChange
    }

    /// The device being recorded, or the one being switched to.
    var device: InputDevice? {
        lock.withLock { (pending ?? active)?.device }
    }

    var isSwitching: Bool {
        lock.withLock { pending.map { uptimeSeconds() - $0.startedAt < switchTimeoutSeconds } ?? false }
    }

    func targetDevice() -> InputDevice? {
        if let preferredName, let preferred = inputDevices(matching: preferredName).first { return preferred }
        let defaultDevice = defaultInputDevice()
        guard defaultDevice != kAudioObjectUnknown else { return nil }
        return InputDevice(id: defaultDevice, name: stringProperty(defaultDevice, kAudioObjectPropertyName) ?? "system input")
    }

    /// Starts recording the target device. While another device is recording, the new one waits as pending.
    func start() throws {
        guard let target = targetDevice() else { throw CaptureError(errorDescription: "no microphone available") }
        let sessionID = lock.withLock {
            nextSessionID += 1
            return nextSessionID
        }
        let session = try MicrophoneSession(device: target, id: sessionID, onSamples: { [weak self] in self?.deliver(from: $0, $1, hostTime: $2) }, onDeviceChange: onDeviceChange)
        lock.withLock {
            if let pending { replaced.append(pending) }
            if active == nil {
                active = session
                lastActiveAudioUptime = uptimeSeconds()
            } else {
                pending = session
            }
        }
    }

    /// Stops sessions that were switched away from and returns the new device if a switch completed.
    /// Runs on the writer queue, never inside an audio callback.
    func finishSwitch() -> InputDevice? {
        let (finished, newDevice) = lock.withLock {
            defer {
                replaced.removeAll()
                switchedTo = nil
            }
            return (replaced, switchedTo)
        }
        finished.forEach { $0.stop() }
        return newDevice
    }

    func stop() {
        let sessions = lock.withLock {
            let sessions = [active, pending].compactMap { $0 } + replaced
            active = nil
            pending = nil
            replaced.removeAll()
            return sessions
        }
        sessions.forEach { $0.stop() }
    }

    private func deliver(from sessionID: Int, _ samples: [Float], hostTime: UInt64) {
        let shouldRecord: Bool = lock.withLock {
            let now = uptimeSeconds()
            if sessionID == active?.id {
                lastActiveAudioUptime = now
                return true
            }
            guard let pending, sessionID == pending.id else { return false }
            let activeWentQuiet = now - lastActiveAudioUptime > captureStallSeconds
            guard samples.contains(where: { $0 != 0 }) || activeWentQuiet else { return false }
            if let active { replaced.append(active) }
            active = pending
            self.pending = nil
            switchedTo = pending.device
            lastActiveAudioUptime = now
            return true
        }
        if shouldRecord { onSamples(samples, hostTime) }
    }
}

func requestMicrophoneAccess() {
    switch AVCaptureDevice.authorizationStatus(for: .audio) {
    case .authorized:
        return
    case .notDetermined:
        let answered = DispatchSemaphore(value: 0)
        var granted = false
        AVCaptureDevice.requestAccess(for: .audio) { granted = $0; answered.signal() }
        answered.wait()
        if granted { return }
    default:
        break
    }
    fail("microphone access denied; allow your terminal in System Settings > Privacy & Security > Microphone, or use --no-mic")
}

// MARK: - Recording

final class Track {
    var samples: [Float] = []
    var startHostTime: UInt64?
    var peak: Float = 0
    var hasHeardSound = false
    var lastBufferUptime = uptimeSeconds()
    private var timelineFrames = 0

    /// Appends samples at the position their host time implies, filling any gap (such as a device switch) with silence.
    func append(_ newSamples: [Float], hostTime: UInt64) {
        if let startHostTime {
            if hostTime > startHostTime {
                let elapsedNanos = AudioConvertHostTimeToNanos(hostTime) - AudioConvertHostTimeToNanos(startHostTime)
                let gap = Int(Double(elapsedNanos) / 1e9 * sampleRate) - timelineFrames
                if gap > gapFillThresholdFrames { appendSilence(gap) }
            }
        } else {
            startHostTime = hostTime
        }
        samples.append(contentsOf: newSamples)
        timelineFrames += newSamples.count
        lastBufferUptime = uptimeSeconds()
        let newPeak = newSamples.reduce(0) { max($0, abs($1)) }
        peak = max(peak, newPeak)
        if newPeak > 0 { hasHeardSound = true }
    }

    func take(_ count: Int) -> [Float] {
        let taken = Array(samples.prefix(count))
        samples.removeFirst(count)
        return taken
    }

    func padWithSilence(toCount count: Int) {
        if samples.count < count { appendSilence(count - samples.count) }
    }

    private func appendSilence(_ count: Int) {
        samples.append(contentsOf: repeatElement(0, count: count))
        timelineFrames += count
    }
}

/// Removes the system audio that the microphone picks up from the speakers, using the captured system audio as the
/// echo reference (speexdsp acoustic echo canceller plus residual echo suppression).
final class EchoCanceller {
    static let frameSize = Int(sampleRate / 100)
    private let echoState: OpaquePointer
    private let preprocessState: OpaquePointer
    private var microphoneFrame = [Int16](repeating: 0, count: frameSize)
    private var speakerFrame = [Int16](repeating: 0, count: frameSize)
    private var cleanedFrame = [Int16](repeating: 0, count: frameSize)

    init() {
        echoState = speex_echo_state_init(Int32(Self.frameSize), Int32(sampleRate * echoTailSeconds))
        var rate = Int32(sampleRate)
        speex_echo_ctl(echoState, SPEEX_ECHO_SET_SAMPLING_RATE, &rate)
        preprocessState = speex_preprocess_state_init(Int32(Self.frameSize), Int32(sampleRate))
        speex_preprocess_ctl(preprocessState, SPEEX_PREPROCESS_SET_ECHO_STATE, UnsafeMutableRawPointer(echoState))
    }

    deinit {
        speex_preprocess_state_destroy(preprocessState)
        speex_echo_state_destroy(echoState)
    }

    /// Both inputs must be the same length, a multiple of `frameSize`, and aligned in time.
    func cancel(microphone: [Float], speaker: [Float]) -> [Float] {
        var cleaned = [Float]()
        cleaned.reserveCapacity(microphone.count)
        for frameStart in stride(from: 0, to: microphone.count, by: Self.frameSize) {
            for offset in 0..<Self.frameSize {
                microphoneFrame[offset] = pcm16(microphone[frameStart + offset])
                speakerFrame[offset] = pcm16(speaker[frameStart + offset])
            }
            speex_echo_cancellation(echoState, microphoneFrame, speakerFrame, &cleanedFrame)
            speex_preprocess_run(preprocessState, &cleanedFrame)
            cleaned.append(contentsOf: cleanedFrame.map { Float($0) / Float(Int16.max) })
        }
        return cleaned
    }

    private func pcm16(_ sample: Float) -> Int16 {
        Int16(min(max(sample, -1), 1) * Float(Int16.max))
    }
}

struct LevelSnapshot {
    let microphonePeak: Float
    let systemPeak: Float
    let systemHasHeardSound: Bool
}

/// Writes the microphone (left) and system audio (right), or their mix on both channels, to a 16-bit PCM CAF,
/// which stays readable if the process dies.
final class Recorder {
    let includesMicrophone: Bool
    let isolatesSpeakers: Bool
    private let echoCanceller: EchoCanceller?
    private let lock = NSLock()
    private let microphone = Track()
    private let system = Track()
    private let startedAt = Date()
    private var isAligned = false
    private var file: AVAudioFile?
    private(set) var framesWritten: AVAudioFramePosition = 0

    init(writingTo url: URL, includesMicrophone: Bool, isolatesSpeakers: Bool, cancelsEcho: Bool) throws {
        self.includesMicrophone = includesMicrophone
        self.isolatesSpeakers = isolatesSpeakers
        echoCanceller = includesMicrophone && cancelsEcho ? EchoCanceller() : nil
        file = try AVAudioFile(forWriting: url, settings: pcmSettings(bigEndian: false), commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    func appendMicrophone(_ samples: [Float], hostTime: UInt64) {
        lock.withLock { microphone.append(samples, hostTime: hostTime) }
    }

    func appendSystem(_ samples: [Float], hostTime: UInt64) {
        lock.withLock { system.append(samples, hostTime: hostTime) }
    }

    /// Gives a freshly restarted capture the full stall window to deliver its first buffer.
    func resetMicrophoneStallTimer() {
        lock.withLock { microphone.lastBufferUptime = uptimeSeconds() }
    }

    func resetSystemStallTimer() {
        lock.withLock { system.lastBufferUptime = uptimeSeconds() }
    }

    func secondsSinceMicrophoneAudio() -> Double {
        lock.withLock { uptimeSeconds() - microphone.lastBufferUptime }
    }

    func secondsSinceSystemAudio() -> Double {
        lock.withLock { uptimeSeconds() - system.lastBufferUptime }
    }

    func levels() -> LevelSnapshot {
        lock.withLock {
            let snapshot = LevelSnapshot(microphonePeak: microphone.peak, systemPeak: system.peak, systemHasHeardSound: system.hasHeardSound)
            microphone.peak = 0
            system.peak = 0
            return snapshot
        }
    }

    func writeAvailable(final: Bool = false) {
        let (microphoneSamples, systemSamples) = lock.withLock { takeTracks(final: final) }
        guard !systemSamples.isEmpty, let file else { return }
        let (left, right) = channels(microphone: microphoneSamples, system: systemSamples)
        let buffer = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: AVAudioFrameCount(left.count))!
        buffer.frameLength = AVAudioFrameCount(left.count)
        buffer.floatChannelData![0].update(from: left, count: left.count)
        buffer.floatChannelData![1].update(from: right, count: right.count)
        do {
            try file.write(from: buffer)
            framesWritten += AVAudioFramePosition(left.count)
        } catch {
            fputs("\ntotalrecall: write failed: \(error.localizedDescription)\n", stderr)
        }
    }

    func close() {
        writeAvailable(final: true)
        file?.close()
        file = nil
    }

    private func channels(microphone microphoneSamples: [Float], system systemSamples: [Float]) -> ([Float], [Float]) {
        guard includesMicrophone else { return (systemSamples, systemSamples) }
        let cleanedMicrophone = echoCanceller?.cancel(microphone: microphoneSamples, speaker: systemSamples) ?? microphoneSamples
        guard isolatesSpeakers else {
            let mixed = zip(cleanedMicrophone, systemSamples).map { min(max($0 + $1, -1), 1) }
            return (mixed, mixed)
        }
        return (cleanedMicrophone, systemSamples)
    }

    /// Takes equal-length, time-aligned microphone and system samples; whole echo-canceller frames while recording.
    private func takeTracks(final: Bool) -> ([Float], [Float]) {
        guard includesMicrophone else { return ([], system.take(system.samples.count)) }
        if !isAligned {
            let bothStarted = microphone.startHostTime != nil && system.startHostTime != nil
            guard bothStarted || final || Date().timeIntervalSince(startedAt) > startupGraceSeconds else { return ([], []) }
            alignStarts()
            isAligned = true
        }
        if final || abs(microphone.samples.count - system.samples.count) > maxLagFrames {
            let longest = max(microphone.samples.count, system.samples.count)
            let paddedLength = final ? (longest + EchoCanceller.frameSize - 1) / EchoCanceller.frameSize * EchoCanceller.frameSize : longest
            microphone.padWithSilence(toCount: paddedLength)
            system.padWithSilence(toCount: paddedLength)
        }
        let available = min(microphone.samples.count, system.samples.count)
        let count = available - available % EchoCanceller.frameSize
        return (microphone.take(count), system.take(count))
    }

    private func alignStarts() {
        guard let microphoneStart = microphone.startHostTime, let systemStart = system.startHostTime else { return }
        let offsetNanos = AudioConvertHostTimeToNanos(max(microphoneStart, systemStart)) - AudioConvertHostTimeToNanos(min(microphoneStart, systemStart))
        let offsetFrames = min(Int(Double(offsetNanos) / 1e9 * sampleRate), maxStartOffsetFrames)
        let laterTrack = microphoneStart > systemStart ? microphone : system
        laterTrack.samples.insert(contentsOf: repeatElement(0, count: offsetFrames), at: 0)
    }
}

// MARK: - Export

func pcmSettings(bigEndian: Bool) -> [String: Any] {
    [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: 2,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: bigEndian,
    ]
}

let aacSettings: [String: Any] = [
    AVFormatIDKey: kAudioFormatMPEG4AAC,
    AVSampleRateKey: sampleRate,
    AVNumberOfChannelsKey: 2,
    AVEncoderBitRateKey: 128_000,
]

func transcode(_ source: URL, to destination: URL, settings: [String: Any]) throws {
    let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
    let output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536)!
    while input.framePosition < input.length {
        try input.read(into: chunk)
        try output.write(from: chunk)
    }
    output.close()
}

func transcodeWithFFmpeg(_ source: URL, to destination: URL) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path, destination.path]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw CaptureError(errorDescription: "ffmpeg exited with status \(process.terminationStatus)")
    }
}

func export(_ partial: URL, to destination: URL) throws {
    try? FileManager.default.removeItem(at: destination)
    switch destination.pathExtension.lowercased() {
    case "caf":
        try FileManager.default.moveItem(at: partial, to: destination)
        return
    case "wav", "wave":
        try transcode(partial, to: destination, settings: pcmSettings(bigEndian: false))
    case "aif", "aiff":
        try transcode(partial, to: destination, settings: pcmSettings(bigEndian: true))
    case "m4a", "mp4", "aac":
        try transcode(partial, to: destination, settings: aacSettings)
    default:
        try transcodeWithFFmpeg(partial, to: destination)
    }
    try FileManager.default.removeItem(at: partial)
}

// MARK: - Main

func meter(_ peak: Float) -> String {
    let decibels = 20 * log10(max(peak, 1e-6))
    let filled = min(max(Int(((decibels - meterFloorDecibels) / -meterFloorDecibels * Float(meterWidth)).rounded()), 0), meterWidth)
    return String(repeating: "█", count: filled) + String(repeating: "·", count: meterWidth - filled)
}

func formatDuration(_ seconds: Int) -> String {
    String(format: "%02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
}

var microphoneQuery: String?
var includesMicrophone = true
var isolatesSpeakers = true
var cancelsEcho = true
var overwrite = false
var outputPath: String?
var arguments = CommandLine.arguments.dropFirst()
while let argument = arguments.popFirst() {
    switch argument {
    case "--list-mics":
        listMicrophones()
        exit(0)
    case "--mic":
        guard let query = arguments.popFirst() else { fail("--mic needs a name\n\(usage)") }
        microphoneQuery = query
    case "--no-mic":
        includesMicrophone = false
    case "--no-speaker-isolation":
        isolatesSpeakers = false
    case "--no-echo-cancellation":
        cancelsEcho = false
    case "-f", "--force":
        overwrite = true
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        guard !argument.hasPrefix("-"), outputPath == nil else { fail("unexpected argument \(argument)\n\(usage)") }
        outputPath = argument
    }
}
guard let outputPath else { fail("missing output file\n\(usage)") }
if let microphoneQuery, inputDevices(matching: microphoneQuery).isEmpty {
    let available = inputDevices().map { "  \($0.name)" }.joined(separator: "\n")
    fail("no microphone matches \"\(microphoneQuery)\"; available:\n\(available)")
}

let outputURL = URL(fileURLWithPath: (outputPath as NSString).expandingTildeInPath).standardizedFileURL
let partialURL = outputURL.appendingPathExtension("partial.caf")
var isDirectory: ObjCBool = false
guard FileManager.default.fileExists(atPath: outputURL.deletingLastPathComponent().path, isDirectory: &isDirectory), isDirectory.boolValue else {
    fail("directory \(outputURL.deletingLastPathComponent().path) does not exist")
}
for existing in [outputURL, partialURL] where FileManager.default.fileExists(atPath: existing.path) && !overwrite {
    fail("\(existing.path) already exists (use --force to overwrite)")
}
if includesMicrophone { requestMicrophoneAccess() }

let recorder: Recorder
do {
    recorder = try Recorder(writingTo: partialURL, includesMicrophone: includesMicrophone, isolatesSpeakers: isolatesSpeakers, cancelsEcho: cancelsEcho)
} catch {
    fail("cannot create \(partialURL.path): \(error.localizedDescription)")
}

func failStartup(_ message: String) -> Never {
    try? FileManager.default.removeItem(at: partialURL)
    fail(message)
}

let writerQueue = DispatchQueue(label: "totalrecall.writer")
var microphoneNeedsRestart = false
var devicesChanged = false

let systemCapture = SystemAudioCapture(onSamples: recorder.appendSystem)
let microphoneCapture: MicrophoneCapture? = includesMicrophone ? MicrophoneCapture(
    preferredName: microphoneQuery,
    onSamples: recorder.appendMicrophone,
    onDeviceChange: { writerQueue.async { microphoneNeedsRestart = true } }
) : nil
do {
    try systemCapture.start()
    try microphoneCapture?.start()
} catch {
    failStartup(error.localizedDescription)
}
onSystemDeviceChange(queue: writerQueue) { devicesChanged = true }

let channelLayout = isolatesSpeakers ? " (mic left, system right)" : " (mixed)"
let source = microphoneCapture?.device.map { "system audio + mic \"\($0.name)\"\(channelLayout)" } ?? "system audio"
fputs("Recording \(source) -> \(outputURL.path)\nPress Ctrl-C to stop and save.\n", stderr)

let showsMeter = isatty(STDERR_FILENO) != 0

func announce(_ message: String) {
    let elapsed = formatDuration(Int(recorder.framesWritten / AVAudioFramePosition(sampleRate)))
    fputs("\(showsMeter ? "\r\u{1B}[K" : "")[\(elapsed)] \(message)\n", stderr)
}

var nextMicrophoneRestart = 0.0
var nextSystemRestart = 0.0

/// Rebuilds a capture when its device changed or it stopped delivering audio. Runs on the writer queue.
func superviseCaptures() {
    let now = uptimeSeconds()
    if let microphoneCapture {
        if let newDevice = microphoneCapture.finishSwitch() {
            announce("mic -> \(newDevice.name)")
        }
        if devicesChanged, microphoneCapture.targetDevice()?.id != microphoneCapture.device?.id {
            microphoneNeedsRestart = true
        }
        let stalled = recorder.secondsSinceMicrophoneAudio() > captureStallSeconds && !microphoneCapture.isSwitching
        if (microphoneNeedsRestart || stalled) && now >= nextMicrophoneRestart {
            microphoneNeedsRestart = false
            nextMicrophoneRestart = now + restartRetrySeconds
            do {
                try microphoneCapture.start()
                recorder.resetMicrophoneStallTimer()
            } catch {
                announce("mic unavailable, retrying: \(error.localizedDescription)")
            }
        }
    }
    devicesChanged = false
    if recorder.secondsSinceSystemAudio() > captureStallSeconds && now >= nextSystemRestart {
        nextSystemRestart = now + restartRetrySeconds
        systemCapture.stop()
        do {
            try systemCapture.start()
            recorder.resetSystemStallTimer()
            announce("system audio capture restarted")
        } catch {
            announce("system audio unavailable, retrying: \(error.localizedDescription)")
        }
    }
}

let writerTimer = DispatchSource.makeTimerSource(queue: writerQueue)
var ticks = 0
var hasWarnedAboutSilence = false
writerTimer.schedule(deadline: .now() + 0.25, repeating: 0.25)
writerTimer.setEventHandler {
    superviseCaptures()
    recorder.writeAvailable()
    ticks += 1
    guard ticks % 4 == 0 else { return }
    let levels = recorder.levels()
    let elapsedSeconds = Double(ticks) / 4
    if !levels.systemHasHeardSound && elapsedSeconds >= silentSystemWarningSeconds && !hasWarnedAboutSilence {
        hasWarnedAboutSilence = true
        announce("No system audio captured yet. If something is playing, allow your terminal in System Settings > Privacy & Security > Screen & System Audio Recording (System Audio Recording Only), then restart totalrecall.")
    }
    guard showsMeter else { return }
    let duration = formatDuration(Int(recorder.framesWritten / AVAudioFramePosition(sampleRate)))
    let microphoneMeter = includesMicrophone ? "  mic \(meter(levels.microphonePeak))" : ""
    fputs("\r\u{1B}[K● \(duration)\(microphoneMeter)  system \(meter(levels.systemPeak))", stderr)
}
writerTimer.resume()

func stopAndSave() {
    writerQueue.sync {
        writerTimer.cancel()
        microphoneCapture?.stop()
        systemCapture.stop()
        recorder.close()
    }
    let duration = formatDuration(Int(recorder.framesWritten / AVAudioFramePosition(sampleRate)))
    fputs("\nSaving \(duration) of audio...\n", stderr)
    do {
        try export(partialURL, to: outputURL)
    } catch {
        fail("could not save \(outputURL.path): \(error.localizedDescription); the raw recording is kept at \(partialURL.path)")
    }
    fputs("Saved \(outputURL.path)\n", stderr)
    exit(0)
}

signal(SIGPIPE, SIG_IGN)
let signalSources = [SIGINT, SIGTERM, SIGHUP].map { signalNumber in
    signal(signalNumber, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
    source.setEventHandler(handler: stopAndSave)
    source.resume()
    return source
}
dispatchMain()
