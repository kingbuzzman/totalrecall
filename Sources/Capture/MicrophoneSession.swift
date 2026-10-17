import AVFoundation
import CoreAudio

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
        let ioBlock: AudioDeviceIOBlock = { _, inputData, inputTime, _, _ in
            guard let firstChannel = Self.firstChannel(of: inputData, format: firstChannelFormat) else { return }
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
