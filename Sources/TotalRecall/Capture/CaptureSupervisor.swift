import Foundation

/// A capture that delivers no audio for this long has stalled.
let captureStallSeconds = 0.6

/// Rebuilds a capture when its device changed or it stopped delivering audio, retrying a capture that stays down
/// less and less often (see `CaptureOutage`). Used only on the writer queue.
final class CaptureSupervisor {
    private let recorder: Recorder
    private let systemCapture: any RestartableCapture
    private let microphoneCapture: MicrophoneCapture?
    private let announce: (String) -> Void
    private let systemOutage: CaptureOutage
    private let microphoneOutage: CaptureOutage
    private var microphoneNeedsRestart = false
    private var devicesChanged = false

    init(
        recorder: Recorder,
        systemCapture: any RestartableCapture,
        microphoneCapture: MicrophoneCapture?,
        announce: @escaping (String) -> Void
    ) {
        self.recorder = recorder
        self.systemCapture = systemCapture
        self.microphoneCapture = microphoneCapture
        self.announce = announce
        systemOutage = CaptureOutage(name: "system audio", announce: announce)
        microphoneOutage = CaptureOutage(name: "mic", announce: announce)
    }

    /// The system input or the device list changed; checked on the next `supervise()`.
    func systemDevicesChanged() {
        devicesChanged = true
    }

    func supervise() {
        let now = uptimeSeconds()
        if devicesChanged { systemOutage.resetBackoff() }
        if let microphoneCapture { superviseMicrophone(microphoneCapture, now: now) }
        devicesChanged = false
        superviseSystemAudio(now: now)
    }

    private func superviseMicrophone(_ microphoneCapture: MicrophoneCapture, now: Double) {
        if let newDevice = microphoneCapture.finishSwitch() {
            announce("mic -> \(newDevice.name)")
        }
        if let silenced = microphoneCapture.takeVoiceProcessingTakeover() {
            announce("mic \"\(silenced.name)\" silenced by another app; recording it through voice processing")
        }
        do {
            try microphoneCapture.tryVoiceProcessing()
        } catch {
            announce("mic silenced, and voice processing is unavailable: \(error.localizedDescription)")
        }
        if microphoneCapture.takeDeviceChange() {
            microphoneNeedsRestart = true
        }
        if devicesChanged, microphoneCapture.targetDevice()?.id != microphoneCapture.device?.id {
            microphoneNeedsRestart = true
        }
        if microphoneNeedsRestart { microphoneOutage.resetBackoff() }
        microphoneOutage.update(deliveries: recorder.deliveries(from: .microphone), now: now)
        let stalled =
            recorder.secondsSinceAudio(from: .microphone) > captureStallSeconds
            && !microphoneCapture.isSwitching
        guard (microphoneNeedsRestart || stalled) && microphoneOutage.canRestart(now: now) else { return }
        microphoneNeedsRestart = false
        microphoneOutage.restarting(now: now)
        do {
            try microphoneCapture.start()
            recorder.resetStallTimer(for: .microphone)
        } catch {
            microphoneOutage.restartFailed(error)
        }
    }

    private func superviseSystemAudio(now: Double) {
        systemOutage.update(deliveries: recorder.deliveries(from: .system), now: now)
        guard recorder.secondsSinceAudio(from: .system) > captureStallSeconds && systemOutage.canRestart(now: now)
        else {
            return
        }
        systemOutage.restarting(now: now)
        systemCapture.stop()
        do {
            try systemCapture.start()
            recorder.resetStallTimer(for: .system)
        } catch {
            systemOutage.restartFailed(error)
        }
    }
}
