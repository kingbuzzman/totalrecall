import CoreAudio
import Foundation
import Shared

/// Records the preferred microphone when it is present, otherwise the system input. Switching is make-before-break:
/// the old microphone keeps recording until the new one delivers real audio, which hides the ~2 s AirPods take to
/// switch Bluetooth into their call profile.
///
/// Another app's voice processing can silence the microphone: while a call in Firefox runs it on the MacBook mic,
/// every other app reading that mic gets about -82 dB, where a quiet room is about -65 dB. A built-in microphone that
/// stays that quiet is tried through voice processing as well (`VoiceProcessingSession`), which macOS does not silence;
/// that takes over only when it hears clearly more, and then stays for as long as the device is recorded. While it
/// runs, macOS turns other apps' audio down a little, so it is never used for a microphone that works.
///
/// Thread-safe: audio callbacks, device listeners and the writer queue share the state below under `lock`.
final class MicrophoneCapture {
    /// Starts capturing a device: `(device, sessionID, onSamples, onDeviceChange)`.
    typealias SessionFactory = (
        InputDevice, Int, @escaping MicrophoneAudioHandler, @escaping () -> Void
    ) throws -> any MicrophoneCaptureSession

    /// How long a pending switch keeps the capture from counting as stalled while the new device starts up.
    private static let switchTimeoutSeconds = 5.0
    /// Below this level a microphone is dead: silenced at about -82 dB, where a quiet room is about -65 dB.
    static let deadLevel = -76.0
    /// Seconds of dead microphone before voice processing is tried.
    static let deadSecondsBeforeTrial = 3
    /// How much louder voice processing must hear, in dB, to take over from the dead microphone.
    static let takeoverMargin = 6.0
    /// Seconds a voice-processing trial gets to hear more before it is given up.
    static let trialSeconds = 10
    /// The wait before the next trial, as each one ducks other apps' audio while it runs.
    static let secondsBetweenTrials = 120.0

    private let preferredName: String?
    private let onSamples: MicrophoneAudioHandler
    private let findTarget: (String?) -> InputDevice?
    private let makeSession: SessionFactory
    private let makeVoiceProcessingSession: SessionFactory
    private let canUseVoiceProcessing: (InputDevice) -> Bool
    private let lock = UnfairLock()
    /// The session being recorded.
    private var active: (any MicrophoneCaptureSession)?
    /// A newly started session that takes over as soon as it delivers real audio.
    private var pending: (any MicrophoneCaptureSession)?
    /// Sessions switched away from; `finishSwitch()` stops them outside the audio callbacks.
    private var replaced: [any MicrophoneCaptureSession] = []
    /// The device a switch to another device completed to, until `finishSwitch()` reports it.
    private var switchedTo: InputDevice?
    private var lastActiveAudioUptime = 0.0
    private var nextSessionID = 0
    private var deviceChanged = false
    /// The level of the plain session being recorded, by the second.
    private var plainLevel = LoudnessWindow()
    private var lastPlainLevel: Double?
    private var deadSeconds = 0
    /// Set from the audio thread when the microphone went dead; `tryVoiceProcessing()` starts the trial.
    private var wantsTrial = false
    private var nextTrialUptime = 0.0
    private var trial: Trial?
    /// The device voice processing took over, until `takeVoiceProcessingTakeover()` reports it.
    private var voiceProcessingTookOver: InputDevice?

    /// A voice-processing session tried against the dead microphone, and what it heard.
    private struct Trial {
        let session: any MicrophoneCaptureSession
        var level = LoudnessWindow()
        var seconds = 0
    }

    /// `onSamples` is called on a Core Audio thread, only for the session being recorded. `findTarget`, the session
    /// factories and `canUseVoiceProcessing` default to the real devices; voice processing is tried only on built-in
    /// microphones, the ones seen silenced, as a trial on a quiet headset could take over and duck audio for nothing.
    init(
        preferredName: String?,
        onSamples: @escaping MicrophoneAudioHandler,
        findTarget: @escaping (String?) -> InputDevice? = MicrophoneCapture.systemTarget,
        makeSession: @escaping SessionFactory = MicrophoneSession.init,
        makeVoiceProcessingSession: @escaping SessionFactory = VoiceProcessingSession.init,
        canUseVoiceProcessing: @escaping (InputDevice) -> Bool = { $0.isBuiltIn }
    ) {
        self.preferredName = preferredName
        self.onSamples = onSamples
        self.findTarget = findTarget
        self.makeSession = makeSession
        self.makeVoiceProcessingSession = makeVoiceProcessingSession
        self.canUseVoiceProcessing = canUseVoiceProcessing
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

    /// Starts recording the target device. While another device is recording, the new one waits as pending. A device
    /// recorded through voice processing restarts through it, as its plain signal is still silenced.
    func start() throws {
        guard let target = targetDevice() else { throw MessageError("no microphone available") }
        let (sessionID, staysOnVoiceProcessing) = lock.withLock {
            nextSessionID += 1
            return (nextSessionID, active?.usesVoiceProcessing == true && active?.device.id == target.id)
        }
        let session = try (staysOnVoiceProcessing ? makeVoiceProcessingSession : makeSession)(
            target,
            sessionID,
            { [weak self] in self?.deliver($0, hostTime: $1, from: $2) },
            { [weak self] in self?.noteDeviceChange() }
        )
        lock.withLock {
            if let pending { replaced.append(pending) }
            if let trial, trial.session.device.id != target.id { endTrial() }
            plainLevel = LoudnessWindow()
            deadSeconds = 0
            if active == nil {
                active = session
                lastActiveAudioUptime = uptimeSeconds()
            } else {
                pending = session
            }
        }
    }

    /// Starts trying voice processing on a microphone that went dead, unless one was tried in the last
    /// `secondsBetweenTrials`. Runs on the writer queue.
    func tryVoiceProcessing() throws {
        let started: (device: InputDevice, sessionID: Int)? = lock.withLock {
            guard wantsTrial else { return nil }
            wantsTrial = false
            guard let active, !active.usesVoiceProcessing, pending == nil, trial == nil else { return nil }
            nextTrialUptime = uptimeSeconds() + Self.secondsBetweenTrials
            nextSessionID += 1
            return (active.device, nextSessionID)
        }
        guard let (device, sessionID) = started else { return }
        let session = try makeVoiceProcessingSession(
            device,
            sessionID,
            { [weak self] in self?.deliver($0, hostTime: $1, from: $2) },
            { [weak self] in self?.noteDeviceChange() }
        )
        lock.withLock {
            // The recording moved on while the session started.
            guard active?.device.id == device.id, active?.usesVoiceProcessing == false, pending == nil else {
                replaced.append(session)
                return
            }
            trial = Trial(session: session)
        }
    }

    /// Whether the microphone is recorded through voice processing, or about to be.
    var usesVoiceProcessing: Bool {
        lock.withLock { (pending ?? active)?.usesVoiceProcessing ?? false }
    }

    /// Records the microphone through voice processing or not, as the user asked, from the new session's first
    /// sound. Turned off, voice processing is not tried again for `secondsBetweenTrials`. Runs on the writer queue.
    func useVoiceProcessing(_ isOn: Bool) throws {
        let started: (device: InputDevice, sessionID: Int)? = lock.withLock {
            if !isOn {
                nextTrialUptime = uptimeSeconds() + Self.secondsBetweenTrials
                deadSeconds = 0
            }
            if trial != nil { endTrial() }
            guard let current = pending ?? active, current.usesVoiceProcessing != isOn else { return nil }
            nextSessionID += 1
            return (current.device, nextSessionID)
        }
        guard let (device, sessionID) = started else { return }
        let session = try (isOn ? makeVoiceProcessingSession : makeSession)(
            device,
            sessionID,
            { [weak self] in self?.deliver($0, hostTime: $1, from: $2) },
            { [weak self] in self?.noteDeviceChange() }
        )
        lock.withLock {
            if let pending { replaced.append(pending) }
            plainLevel = LoudnessWindow()
            pending = session
        }
    }

    /// The device voice processing took over, once.
    func takeVoiceProcessingTakeover() -> InputDevice? {
        lock.withLock {
            defer { voiceProcessingTookOver = nil }
            return voiceProcessingTookOver
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
            let sessions = [active, pending, trial?.session].compactMap { $0 } + replaced
            active = nil
            pending = nil
            trial = nil
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
                if active?.usesVoiceProcessing == false { watchLevel(samples, now: now) }
                return true
            }
            if sessionID == trial?.session.id { return judgeTrial(samples, now: now) }
            guard let pending, sessionID == pending.id else { return false }
            let activeWentQuiet = now - lastActiveAudioUptime > captureStallSeconds
            guard samples.contains(where: { $0 != 0 }) || activeWentQuiet else { return false }
            // A restart of the same device (after a stall or a device change) is not a switch to announce.
            if active?.device.id != pending.device.id { switchedTo = pending.device }
            if let active { replaced.append(active) }
            active = pending
            self.pending = nil
            plainLevel = LoudnessWindow()
            deadSeconds = 0
            lastActiveAudioUptime = now
            return true
        }
        if shouldRecord { onSamples(samples, hostTime, sessionID) }
    }

    /// Follows the level of the plain session being recorded: asks for a trial once it has been dead long enough, and
    /// ends a trial once it turns out alive. Under `lock`.
    private func watchLevel(_ samples: [Float], now: Double) {
        guard let level = plainLevel.add(samples) else { return }
        lastPlainLevel = level
        deadSeconds = level < Self.deadLevel ? deadSeconds + 1 : 0
        if trial != nil {
            if level >= Self.deadLevel { endTrial() }
            return
        }
        if let active, deadSeconds >= Self.deadSecondsBeforeTrial, pending == nil, now >= nextTrialUptime,
            canUseVoiceProcessing(active.device)
        {
            wantsTrial = true
        }
    }

    /// Whether to record a buffer from the voice-processing trial: only once it has heard clearly more than the dead
    /// microphone in the same second, when it takes over. Under `lock`.
    private func judgeTrial(_ samples: [Float], now: Double) -> Bool {
        guard var trial, let active else { return false }
        guard let level = trial.level.add(samples) else {
            self.trial = trial
            return false
        }
        trial.seconds += 1
        self.trial = trial
        if let lastPlainLevel, level >= Self.deadLevel, level >= lastPlainLevel + Self.takeoverMargin {
            replaced.append(active)
            self.active = trial.session
            self.trial = nil
            voiceProcessingTookOver = trial.session.device
            lastActiveAudioUptime = now
            return true
        }
        if trial.seconds >= Self.trialSeconds { endTrial() }
        return false
    }

    /// Gives up the voice-processing trial; `finishSwitch()` stops it. Under `lock`.
    private func endTrial() {
        if let trial { replaced.append(trial.session) }
        trial = nil
        deadSeconds = 0
    }
}
