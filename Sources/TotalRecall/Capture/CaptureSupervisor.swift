/// A capture that delivers no audio for this long has stalled.
let captureStallSeconds = 0.6

/// Rebuilds a capture when its device changed or it stopped delivering audio. Used only on the writer queue.
final class CaptureSupervisor {
    /// Minimum time between two restarts of the same capture.
    private static let restartRetrySeconds = 0.5

    private let recorder: Recorder
    private let systemCapture: SystemAudioCapture
    private let microphoneCapture: MicrophoneCapture?
    private let announce: (String) -> Void
    private var microphoneNeedsRestart = false
    private var devicesChanged = false
    private var nextMicrophoneRestart = 0.0
    private var nextSystemRestart = 0.0

    init(
        recorder: Recorder,
        systemCapture: SystemAudioCapture,
        microphoneCapture: MicrophoneCapture?,
        announce: @escaping (String) -> Void
    ) {
        self.recorder = recorder
        self.systemCapture = systemCapture
        self.microphoneCapture = microphoneCapture
        self.announce = announce
    }

    /// The system input or the device list changed; checked on the next `supervise()`.
    func systemDevicesChanged() {
        devicesChanged = true
    }

    func supervise() {
        let now = uptimeSeconds()
        if let microphoneCapture { superviseMicrophone(microphoneCapture, now: now) }
        devicesChanged = false
        superviseSystemAudio(now: now)
    }

    private func superviseMicrophone(_ microphoneCapture: MicrophoneCapture, now: Double) {
        if let newDevice = microphoneCapture.finishSwitch() {
            announce("mic -> \(newDevice.name)")
        }
        if microphoneCapture.takeDeviceChange() {
            microphoneNeedsRestart = true
        }
        if devicesChanged, microphoneCapture.targetDevice()?.id != microphoneCapture.device?.id {
            microphoneNeedsRestart = true
        }
        let stalled =
            recorder.secondsSinceAudio(from: .microphone) > captureStallSeconds
            && !microphoneCapture.isSwitching
        guard (microphoneNeedsRestart || stalled) && now >= nextMicrophoneRestart else { return }
        microphoneNeedsRestart = false
        nextMicrophoneRestart = now + Self.restartRetrySeconds
        do {
            try microphoneCapture.start()
            recorder.resetStallTimer(for: .microphone)
        } catch {
            announce("mic unavailable, retrying: \(error.localizedDescription)")
        }
    }

    private func superviseSystemAudio(now: Double) {
        guard recorder.secondsSinceAudio(from: .system) > captureStallSeconds && now >= nextSystemRestart else {
            return
        }
        nextSystemRestart = now + Self.restartRetrySeconds
        systemCapture.stop()
        do {
            try systemCapture.start()
            recorder.resetStallTimer(for: .system)
            announce("system audio capture restarted")
        } catch {
            announce("system audio unavailable, retrying: \(error.localizedDescription)")
        }
    }
}
