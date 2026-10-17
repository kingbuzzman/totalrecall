import AVFoundation
import CoreAudio

/// Receives each captured buffer, resampled to mono, with the host time of its first frame.
typealias SystemAudioHandler = (_ samples: [Float], _ hostTime: UInt64) -> Void

/// Taps the mixed output of every process via a Core Audio process tap (macOS 14.2+), so no loopback driver is needed.
final class SystemAudioCapture {
    private let onSamples: SystemAudioHandler
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    /// `onSamples` is called on a Core Audio thread.
    init(onSamples: @escaping SystemAudioHandler) {
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
                [kAudioSubTapUIDKey: tapDescription.uuid.uuidString, kAudioSubTapDriftCompensationKey: true]
            ],
        ]
        try ensure(
            AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID),
            "creating system audio device"
        )

        var streamDescription = try readProperty(
            tapID,
            propertyAddress(kAudioTapPropertyFormat),
            initialValue: AudioStreamBasicDescription(),
            "reading system audio format"
        )
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw RecordingError("unsupported system audio format")
        }

        let resampler = try Resampler(from: format)
        let onSamples = onSamples
        let ioBlock: AudioDeviceIOBlock = { _, inputData, inputTime, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: inputData, deallocator: nil) else {
                return
            }
            onSamples(resampler.monoSamples(from: buffer), inputTime.pointee.mHostTime)
        }
        try ensure(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil, ioBlock),
            "registering system audio callback"
        )
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
