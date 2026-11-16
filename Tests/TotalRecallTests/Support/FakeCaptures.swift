import Foundation

@testable import TotalRecall

/// Microphone sessions without Core Audio: the test plays the devices, delivering audio and device changes.
final class FakeMicrophones {
    final class Session: MicrophoneCaptureSession {
        let device: InputDevice
        let id: Int
        var startedAt = uptimeSeconds()
        let usesVoiceProcessing: Bool
        private(set) var isStopped = false
        private let onSamples: MicrophoneAudioHandler
        private let onDeviceChange: () -> Void

        init(
            device: InputDevice,
            id: Int,
            usesVoiceProcessing: Bool = false,
            onSamples: @escaping MicrophoneAudioHandler,
            onDeviceChange: @escaping () -> Void
        ) {
            self.device = device
            self.id = id
            self.usesVoiceProcessing = usesVoiceProcessing
            self.onSamples = onSamples
            self.onDeviceChange = onDeviceChange
        }

        func deliver(_ samples: [Float], hostTime: UInt64 = 0) {
            onSamples(samples, hostTime, id)
        }

        func changeDevice() {
            onDeviceChange()
        }

        func stop() {
            isStopped = true
        }
    }

    /// The device `MicrophoneCapture` should record, nil for none.
    var target: InputDevice?
    /// Thrown by the next sessions that start.
    var failure: (any Error)?
    /// Thrown by the next voice-processing sessions that start.
    var voiceProcessingFailure: (any Error)?
    /// Whether the devices can be recorded through voice processing.
    var canUseVoiceProcessing = true
    private(set) var sessions: [Session] = []
    private(set) var preferredNames: [String?] = []

    init(target: InputDevice?) {
        self.target = target
    }

    func capture(preferredName: String? = nil, onSamples: @escaping MicrophoneAudioHandler) -> MicrophoneCapture {
        MicrophoneCapture(
            preferredName: preferredName,
            onSamples: onSamples,
            findTarget: { [weak self] name in
                self?.preferredNames.append(name)
                return self?.target
            },
            makeSession: { [weak self] device, id, onSamples, onDeviceChange in
                if let failure = self?.failure { throw failure }
                let session = Session(device: device, id: id, onSamples: onSamples, onDeviceChange: onDeviceChange)
                self?.sessions.append(session)
                return session
            },
            makeVoiceProcessingSession: { [weak self] device, id, onSamples, onDeviceChange in
                if let failure = self?.voiceProcessingFailure { throw failure }
                let session = Session(
                    device: device,
                    id: id,
                    usesVoiceProcessing: true,
                    onSamples: onSamples,
                    onDeviceChange: onDeviceChange
                )
                self?.sessions.append(session)
                return session
            },
            canUseVoiceProcessing: { [weak self] _ in self?.canUseVoiceProcessing ?? false }
        )
    }
}

final class FakeSystemCapture: RestartableCapture {
    var failure: (any Error)?
    private(set) var starts = 0
    private(set) var stops = 0

    func start() throws {
        if let failure { throw failure }
        starts += 1
    }

    func stop() {
        stops += 1
    }
}

/// What a capture handed on, as (first sample, session ID).
final class ReceivedAudio {
    private(set) var buffers: [(sample: Float, session: Int)] = []

    func append(_ samples: [Float], hostTime: UInt64, session: Int) {
        buffers.append((samples.first ?? 0, session))
    }

    var sessions: [Int] { buffers.map(\.session) }
}

let macMic = InputDevice(id: 101, name: "MacBook Pro Microphone")
let airPods = InputDevice(id: 102, name: "AirPods Pro")
let usbMic = InputDevice(id: 103, name: "USB Microphone")
