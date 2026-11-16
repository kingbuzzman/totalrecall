import AVFoundation
import AudioToolbox
import CoreAudio
import Shared

/// A capture of one input device through macOS voice processing (the VoiceProcessingIO unit), for a microphone that
/// another app's voice processing silences: while a call in Firefox runs voice processing on the MacBook mic, every
/// other app reading that mic gets a near-silent signal, except another voice-processing client.
///
/// It records only, its output turned off, and asks macOS to turn other apps' audio down as little as it can (about
/// 8 dB) while it runs. Voice processing cancels only this app's own output, which is none, so the meeting it hears
/// through the speakers is left to the echo canceller as usual.
final class VoiceProcessingSession: MicrophoneCaptureSession {
    /// The most frames the unit renders at once; it renders far fewer, about 10 ms at a time.
    private static let maximumFrames: AVAudioFrameCount = 4096

    let device: InputDevice
    let id: Int
    let startedAt = uptimeSeconds()
    let usesVoiceProcessing = true
    private let unit: AudioUnit
    private let renderer: Renderer

    /// `onSamples` runs on a Core Audio thread. Voice processing follows the device's format changes itself, so
    /// `onDeviceChange` is not called; a device that disappears stops delivering, which restarts the capture.
    init(
        device: InputDevice,
        id: Int,
        onSamples: @escaping MicrophoneAudioHandler,
        onDeviceChange _: @escaping () -> Void
    ) throws {
        self.device = device
        self.id = id
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_Output,
            componentSubType: kAudioUnitSubType_VoiceProcessingIO,
            componentManufacturer: kAudioUnitManufacturer_Apple,
            componentFlags: 0,
            componentFlagsMask: 0
        )
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw MessageError("voice processing is unavailable")
        }
        var instance: AudioUnit?
        try ensure(AudioComponentInstanceNew(component, &instance), "opening voice processing")
        guard let unit = instance else { throw MessageError("opening voice processing failed") }
        do {
            renderer = try Self.configure(unit, device: device, onSamples: onSamples, id: id)
        } catch {
            AudioComponentInstanceDispose(unit)
            throw error
        }
        self.unit = unit
        do {
            try ensure(AudioOutputUnitStart(unit), "starting voice processing on \(device.name)")
        } catch {
            AudioUnitUninitialize(unit)
            AudioComponentInstanceDispose(unit)
            throw error
        }
    }

    func stop() {
        AudioOutputUnitStop(unit)
        AudioUnitUninitialize(unit)
        AudioComponentInstanceDispose(unit)
    }

    /// Sets the unit up to record `device`, initializes it, and returns the renderer its input callback uses.
    private static func configure(
        _ unit: AudioUnit,
        device: InputDevice,
        onSamples: @escaping MicrophoneAudioHandler,
        id: Int
    ) throws -> Renderer {
        try setProperty(unit, kAudioOutputUnitProperty_EnableIO, .input, UInt32(1), "turning input on")
        try setProperty(unit, kAudioOutputUnitProperty_EnableIO, .output, UInt32(0), "turning output off")
        try setProperty(unit, kAudioOutputUnitProperty_CurrentDevice, .global(1), device.id, "choosing \(device.name)")
        try setProperty(unit, kAudioUnitProperty_MaximumFramesPerSlice, .global(0), maximumFrames, "sizing buffers")
        let format = try recordingFormat(unit)
        let renderer = try Renderer(
            unit: unit,
            format: format,
            maximumFrames: maximumFrames,
            id: id,
            onSamples: onSamples
        )
        let callback = AURenderCallbackStruct(
            inputProc: { refCon, flags, timeStamp, _, frames, _ in
                Unmanaged<Renderer>.fromOpaque(refCon).takeUnretainedValue().render(flags, timeStamp, frames)
            },
            inputProcRefCon: Unmanaged.passUnretained(renderer).toOpaque()
        )
        try setProperty(unit, kAudioOutputUnitProperty_SetInputCallback, .global(1), callback, "listening to it")
        try ensure(AudioUnitInitialize(unit), "initializing voice processing on \(device.name)")
        // Taken into account only once initialized: set before, macOS ducks other audio by about 30 dB instead.
        let ducking = AUVoiceIOOtherAudioDuckingConfiguration(mEnableAdvancedDucking: false, mDuckingLevel: .min)
        try setProperty(
            unit,
            kAUVoiceIOProperty_OtherAudioDuckingConfiguration,
            .global(0),
            ducking,
            "lowering ducking"
        )
        return renderer
    }

    /// Sets the microphone signal to mono float at whatever rate the unit runs; the resampler takes it to the
    /// recording rate.
    private static func recordingFormat(_ unit: AudioUnit) throws -> AVAudioFormat {
        var unitFormat = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let place = Place.microphone
        try ensure(
            AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, place.scope, place.element, &unitFormat, &size),
            "reading the voice processing format"
        )
        guard let format = AVAudioFormat(standardFormatWithSampleRate: unitFormat.mSampleRate, channels: 1) else {
            throw MessageError("unsupported voice processing rate \(unitFormat.mSampleRate)")
        }
        try setProperty(
            unit,
            kAudioUnitProperty_StreamFormat,
            place,
            format.streamDescription.pointee,
            "setting format"
        )
        return format
    }

    /// Where on the unit a property is set: element 1 is the microphone side, element 0 the speaker side.
    private struct Place {
        static let input = Place(scope: kAudioUnitScope_Input, element: 1)
        static let output = Place(scope: kAudioUnitScope_Output, element: 0)
        /// The microphone signal as the unit hands it over.
        static let microphone = Place(scope: kAudioUnitScope_Output, element: 1)

        let scope: AudioUnitScope
        let element: AudioUnitElement

        static func global(_ element: AudioUnitElement) -> Place {
            Place(scope: kAudioUnitScope_Global, element: element)
        }
    }

    /// `action` describes the change in the error, as "<action> failed".
    private static func setProperty<Value>(
        _ unit: AudioUnit,
        _ property: AudioUnitPropertyID,
        _ place: Place,
        _ value: Value,
        _ action: String
    ) throws {
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioUnitSetProperty(unit, property, place.scope, place.element, $0, UInt32(MemoryLayout<Value>.size))
        }
        try ensure(status, "voice processing: \(action)")
    }
}

/// Pulls each rendered buffer out of the unit and hands it on, resampled. Used only on the unit's audio thread, so it
/// reuses one buffer.
private final class Renderer {
    private let unit: AudioUnit
    private let buffer: AVAudioPCMBuffer
    private let resampler: Resampler
    private let id: Int
    private let onSamples: MicrophoneAudioHandler

    init(
        unit: AudioUnit,
        format: AVAudioFormat,
        maximumFrames: AVAudioFrameCount,
        id: Int,
        onSamples: @escaping MicrophoneAudioHandler
    ) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: maximumFrames) else {
            throw MessageError("allocating the voice processing buffer failed")
        }
        self.unit = unit
        self.buffer = buffer
        resampler = try Resampler(from: format)
        self.id = id
        self.onSamples = onSamples
    }

    func render(
        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
        _ timeStamp: UnsafePointer<AudioTimeStamp>,
        _ frames: UInt32
    ) -> OSStatus {
        guard frames <= buffer.frameCapacity else { return kAudioUnitErr_TooManyFramesToProcess }
        buffer.frameLength = frames
        let buffers = buffer.mutableAudioBufferList
        buffers.pointee.mBuffers.mDataByteSize = frames * UInt32(MemoryLayout<Float>.size)
        let status = AudioUnitRender(unit, flags, timeStamp, 1, frames, buffers)
        guard status == noErr else { return status }
        onSamples(resampler.monoSamples(from: buffer), timeStamp.pointee.mHostTime, id)
        return noErr
    }
}
