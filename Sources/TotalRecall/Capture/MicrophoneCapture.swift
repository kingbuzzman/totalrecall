import CoreAudio
import Foundation

/// Records the preferred microphone when it is present, otherwise the system input. Switching is make-before-break:
/// the old microphone keeps recording until the new one delivers real audio, which hides the ~2 s AirPods take to
/// switch Bluetooth into their call profile.
///
/// Thread-safe: audio callbacks, device listeners and the writer queue share the state below under `lock`.
final class MicrophoneCapture {
    /// Starts capturing a device: `(device, sessionID, onSamples, onDeviceChange)`.
    typealias SessionFactory = (
        InputDevice, Int, @escaping MicrophoneAudioHandler, @escaping () -> Void
    ) throws -> MicrophoneCaptureSession

    /// How long a pending switch keeps the capture from counting as stalled while the new device starts up.
    private static let switchTimeoutSeconds = 5.0

    private let preferredName: String?
    private let onSamples: MicrophoneAudioHandler
    private let findTarget: (String?) -> InputDevice?
    private let makeSession: SessionFactory
    private let lock = UnfairLock()
    /// The session being recorded.
    private var active: MicrophoneCaptureSession?
    /// A newly started session that takes over as soon as it delivers real audio.
    private var pending: MicrophoneCaptureSession?
    /// Sessions switched away from; `finishSwitch()` stops them outside the audio callbacks.
    private var replaced: [MicrophoneCaptureSession] = []
    /// The device a switch to another device completed to, until `finishSwitch()` reports it.
    private var switchedTo: InputDevice?
    private var lastActiveAudioUptime = 0.0
    private var nextSessionID = 0
    private var deviceChanged = false

    /// `onSamples` is called on a Core Audio thread, only for the session being recorded. `findTarget` and
    /// `makeSession` default to the real devices.
    init(
        preferredName: String?,
        onSamples: @escaping MicrophoneAudioHandler,
        findTarget: @escaping (String?) -> InputDevice? = MicrophoneCapture.systemTarget,
        makeSession: @escaping SessionFactory = MicrophoneSession.init
    ) {
        self.preferredName = preferredName
        self.onSamples = onSamples
        self.findTarget = findTarget
        self.makeSession = makeSession
    }

    /// The device being recorded, or the one being switched to.
    var device: InputDevice? {
        lock.withLock { (pending ?? active)?.device }
    }

    var isSwitching: Bool {
        lock.withLock { pending.map { uptimeSeconds() - $0.startedAt < Self.switchTimeoutSeconds } ?? false }
    }

    func targetDevice() -> InputDevice? {
        findTarget(preferredName)
    }

    /// The preferred microphone when it is present, otherwise the system input.
    static func systemTarget(preferredName: String?) -> InputDevice? {
        if let preferredName, let preferred = InputDevice.matching(preferredName).first { return preferred }
        return InputDevice.systemInput()
    }

    /// Starts recording the target device. While another device is recording, the new one waits as pending.
    func start() throws {
        guard let target = targetDevice() else { throw RecordingError("no microphone available") }
        let sessionID = lock.withLock {
            nextSessionID += 1
            return nextSessionID
        }
        let session = try makeSession(
            target,
            sessionID,
            { [weak self] in self?.deliver($0, hostTime: $1, from: $2) },
            { [weak self] in self?.noteDeviceChange() }
        )
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

    /// Whether a recorded device changed format or disappeared since the last call.
    func takeDeviceChange() -> Bool {
        lock.withLock {
            defer { deviceChanged = false }
            return deviceChanged
        }
    }

    /// Stops sessions that were switched away from and returns the new device if a switch to another device completed.
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

    private func noteDeviceChange() {
        lock.withLock { deviceChanged = true }
    }

    /// Forwards audio from the active session. The pending session's first non-silent buffer, or any buffer once the
    /// active session has gone quiet, completes the switch.
    private func deliver(_ samples: [Float], hostTime: UInt64, from sessionID: Int) {
        let shouldRecord: Bool = lock.withLock {
            let now = uptimeSeconds()
            if sessionID == active?.id {
                lastActiveAudioUptime = now
                return true
            }
            guard let pending, sessionID == pending.id else { return false }
            let activeWentQuiet = now - lastActiveAudioUptime > captureStallSeconds
            guard samples.contains(where: { $0 != 0 }) || activeWentQuiet else { return false }
            // A restart of the same device (after a stall or a device change) is not a switch to announce.
            if active?.device.id != pending.device.id { switchedTo = pending.device }
            if let active { replaced.append(active) }
            active = pending
            self.pending = nil
            lastActiveAudioUptime = now
            return true
        }
        if shouldRecord { onSamples(samples, hostTime, sessionID) }
    }
}
