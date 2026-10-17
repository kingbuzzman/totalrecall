import AVFoundation
import CoreAudio
import Synchronization

/// Receives each captured buffer, resampled to mono, with the host time of its first frame and the ID of the
/// `MicrophoneSession` that captured it.
typealias MicrophoneAudioHandler = (_ samples: [Float], _ hostTime: UInt64, _ sessionID: Int) -> Void

/// One Core Audio capture of a single input device, read straight from the device so it always uses the device's
/// current format (AirPods change sample rate when their mic turns on).
final class MicrophoneSession {
    private static let deviceChangeAddresses = [
        propertyAddress(kAudioDevicePropertyNominalSampleRate),
        propertyAddress(kAudioDevicePropertyStreamConfiguration, scope: kAudioObjectPropertyScopeInput),
        propertyAddress(kAudioDevicePropertyDeviceIsAlive),
    ]

    let device: InputDevice
    let id: Int
    let startedAt = uptimeSeconds()
    /// Set once the device no longer runs at the sample rate this session converts from, or has gone away. From then
    /// on its audio is dropped: converted as if it were still at the old rate, it would come out stretched or squeezed
    /// in time and shift everything after it. `MicrophoneCapture` replaces the session, and the timeline fills the
    /// short gap with silence.
    private let isStale = StaleFlag()
    private var ioProcID: AudioDeviceIOProcID?
    private var deviceListener: AudioObjectPropertyListenerBlock?

    /// Both callbacks run on Core Audio threads. `onDeviceChange` is called when the device changes sample rate or
    /// channels, or disappears.
    init(
        device: InputDevice,
        id: Int,
        onSamples: @escaping MicrophoneAudioHandler,
        onDeviceChange: @escaping () -> Void
    ) throws {
        self.device = device
        self.id = id
        let streamFormat = try device.streamFormat()
        let isFloat32 =
            streamFormat.mFormatID == kAudioFormatLinearPCM
            && streamFormat.mFormatFlags & kAudioFormatFlagIsFloat != 0
            && streamFormat.mBitsPerChannel == 32
        guard
            isFloat32,
            let firstChannelFormat = AVAudioFormat(standardFormatWithSampleRate: streamFormat.mSampleRate, channels: 1)
        else {
            throw RecordingError("unsupported \(device.name) format")
        }
        let resampler = try Resampler(from: firstChannelFormat)
        let isStale = isStale
        let ioBlock: AudioDeviceIOBlock = { _, inputData, inputTime, _, _ in
            guard
                !isStale.isSet,
                let firstChannel = Self.firstChannel(of: inputData, format: firstChannelFormat)
            else { return }
            onSamples(resampler.monoSamples(from: firstChannel), inputTime.pointee.mHostTime, id)
        }
        var procID: AudioDeviceIOProcID?
        try ensure(AudioDeviceCreateIOProcIDWithBlock(&procID, device.id, nil, ioBlock), "listening to \(device.name)")
        guard let procID else { throw RecordingError("listening to \(device.name) failed") }
        do {
            try ensure(AudioDeviceStart(device.id, procID), "starting \(device.name)")
        } catch {
            AudioDeviceDestroyIOProcID(device.id, procID)
            throw error
        }
        ioProcID = procID
        let sampleRate = streamFormat.mSampleRate
        let deviceListener: AudioObjectPropertyListenerBlock = { _, _ in
            if !Self.isRunning(device.id, at: sampleRate) { isStale.set() }
            onDeviceChange()
        }
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

    /// Whether the device is still there and running at `sampleRate`.
    private static func isRunning(_ deviceID: AudioDeviceID, at sampleRate: Double) -> Bool {
        let rate = try? readProperty(
            deviceID,
            propertyAddress(kAudioDevicePropertyNominalSampleRate),
            initialValue: 0.0
        )
        let isAlive = try? readProperty(
            deviceID,
            propertyAddress(kAudioDevicePropertyDeviceIsAlive),
            initialValue: 0 as UInt32
        )
        return rate == sampleRate && isAlive == 1
    }

    /// Copies channel 0 out of the device's interleaved buffer. Built-in mic arrays deliver several interleaved
    /// channels; channel 0 is a complete microphone signal.
    private static func firstChannel(
        of inputData: UnsafePointer<AudioBufferList>,
        format: AVAudioFormat
    ) -> AVAudioPCMBuffer? {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
        guard let firstBuffer = buffers.first, let data = firstBuffer.mData, firstBuffer.mNumberChannels > 0 else {
            return nil
        }
        let channelCount = Int(firstBuffer.mNumberChannels)
        let frameCount = Int(firstBuffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
        guard
            frameCount > 0,
            let firstChannel = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))
        else {
            return nil
        }
        firstChannel.frameLength = AVAudioFrameCount(frameCount)
        let interleaved = data.assumingMemoryBound(to: Float.self)
        let destination = firstChannel.floatChannelData![0]
        for frame in 0..<frameCount { destination[frame] = interleaved[frame * channelCount] }
        return firstChannel
    }
}

/// A flag set from a Core Audio notification thread and read on the audio thread, without locking.
private final class StaleFlag: Sendable {
    private let value = Atomic<Bool>(false)

    var isSet: Bool { value.load(ordering: .relaxed) }

    func set() {
        value.store(true, ordering: .relaxed)
    }
}
