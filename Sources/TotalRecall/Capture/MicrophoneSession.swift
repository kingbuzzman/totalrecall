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
        let rateWatch = RateWatch(expectedRate: streamFormat.mSampleRate)
        let ioBlock: AudioDeviceIOBlock = { _, inputData, inputTime, _, _ in
            guard
                rateWatch.isOnRate(at: inputTime.pointee),
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

/// Measures the rate a device actually delivers at, from its buffers' timestamps, and reports when it no longer matches
/// the rate the session converts from. A device can switch rates under a running session (AirPods do when their mic
/// turns on, so does any device whose rate is changed); that session's audio, converted as if it were still at the old
/// rate, would come out stretched or squeezed in time and shift everything after it. Its audio is dropped instead;
/// `MicrophoneCapture` replaces the session, and the timeline fills the short gap with silence.
///
/// Used only on the session's audio thread.
private final class RateWatch {
    /// Timestamps jitter by far less than this; a real switch, such as 44.1 to 48 kHz, is 9%.
    private static let tolerance = 0.03
    /// Off-rate buffers in a row before the session is given up on. One odd timestamp throws off two measurements, the
    /// one into it and the one out of it; after a real switch, every measurement is off.
    private static let mismatchesToGiveUp = 3

    private let expectedRate: Double
    private var previous: (sampleTime: Double, nanos: UInt64)?
    private var mismatches = 0

    init(expectedRate: Double) {
        self.expectedRate = expectedRate
    }

    /// Whether the device still delivers at the expected rate; once it has not, false for good.
    func isOnRate(at time: AudioTimeStamp) -> Bool {
        guard mismatches < Self.mismatchesToGiveUp else { return false }
        guard time.mFlags.contains([.sampleTimeValid, .hostTimeValid]) else { return true }
        let nanos = AudioConvertHostTimeToNanos(time.mHostTime)
        defer { previous = (time.mSampleTime, nanos) }
        guard let previous, nanos > previous.nanos, time.mSampleTime > previous.sampleTime else { return true }
        let rate = (time.mSampleTime - previous.sampleTime) / (Double(nanos - previous.nanos) / 1e9)
        mismatches = abs(rate / expectedRate - 1) > Self.tolerance ? mismatches + 1 : 0
        return mismatches < Self.mismatchesToGiveUp
    }
}
