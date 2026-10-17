import CoreAudio
import Foundation

/// Stopped before the captures were live and the recording started, so there is nothing to save.
struct StoppedBeforeRecording: LocalizedError {
    var errorDescription: String? { "stopped before the recording started; nothing was saved" }
}

/// One recording from start to save: starts the captures, starts the recording once they deliver audio and the echo
/// canceller has a baseline of ambient sound, writes the partial file on a timer while the supervisor keeps the
/// captures alive, shows levels, and saves the output file when stopped.
final class RecordingSession {
    private static let tickSeconds = 0.25
    private static let ticksPerLevelUpdate = 4
    private static let silentSystemWarningSeconds = 10.0
    /// How often to check whether the recording can start.
    private static let startupPollSeconds = 0.01
    /// Longest to wait for the recording to be able to start, such as with a muted microphone, before starting anyway.
    private static let maxStartupWaitSeconds = 6.0

    private let output: OutputFile
    private let recorder: Recorder
    private let systemCapture: SystemAudioCapture
    private let microphoneCapture: MicrophoneCapture?
    private let supervisor: CaptureSupervisor
    private let status: StatusLine
    private let writerQueue: DispatchQueue
    private let startupTimer: DispatchSourceTimer
    private let writerTimer: DispatchSourceTimer
    /// Whether the recording started; used only on the writer queue.
    private var hasStarted = false
    private var ticks = 0
    private var hasWarnedAboutSilence = false

    /// Creates the partial recording; throws if it cannot be created.
    init(options: Options, output: OutputFile) throws {
        let recorder = try Recorder(
            writingTo: output.partialURL,
            includesMicrophone: options.includesMicrophone,
            isolatesSpeakers: options.isolatesSpeakers,
            cancelsEcho: options.cancelsEcho
        )
        let systemCapture = SystemAudioCapture(onSamples: recorder.appendSystem)
        let microphoneCapture =
            options.includesMicrophone
            ? MicrophoneCapture(preferredName: options.microphoneQuery, onSamples: recorder.appendMicrophone)
            : nil
        let status = StatusLine(recorder: recorder)
        let writerQueue = DispatchQueue(label: "totalrecall.writer")
        self.output = output
        self.recorder = recorder
        self.systemCapture = systemCapture
        self.microphoneCapture = microphoneCapture
        self.status = status
        self.writerQueue = writerQueue
        supervisor = CaptureSupervisor(
            recorder: recorder,
            systemCapture: systemCapture,
            microphoneCapture: microphoneCapture,
            announce: status.announce
        )
        startupTimer = DispatchSource.makeTimerSource(queue: writerQueue)
        writerTimer = DispatchSource.makeTimerSource(queue: writerQueue)
    }

    /// Starts the captures, and the recording as soon as the recorder is ready. If a capture cannot start, deletes the
    /// partial recording and throws.
    func start() throws {
        do {
            try systemCapture.start()
            try microphoneCapture?.start()
        } catch {
            try? FileManager.default.removeItem(at: output.partialURL)
            throw error
        }
        onSystemDeviceChange(queue: writerQueue) { [supervisor] in supervisor.systemDevicesChanged() }

        let deadline = uptimeSeconds() + Self.maxStartupWaitSeconds
        startupTimer.schedule(deadline: .now(), repeating: Self.startupPollSeconds)
        startupTimer.setEventHandler { [weak self] in
            guard let self, recorder.isReadyToRecord || uptimeSeconds() >= deadline else { return }
            startupTimer.cancel()
            beginRecording()
        }
        startupTimer.resume()
    }

    /// Ends the recording now, stops the captures, finishes the partial recording and converts it to the output file.
    /// If saving fails, the partial recording is kept. Throws `StoppedBeforeRecording` if the recording had not
    /// started yet.
    func stopAndSave() throws {
        let stopTime = AudioGetCurrentHostTime()
        let hadStarted = writerQueue.sync {
            startupTimer.cancel()
            if hasStarted {
                recorder.stopRecording(at: stopTime)
                writerTimer.cancel()
            }
            microphoneCapture?.stop()
            systemCapture.stop()
            do {
                try recorder.close()
            } catch {
                status.reportWriteFailure(error)
            }
            return hasStarted
        }
        guard hadStarted else {
            try? FileManager.default.removeItem(at: output.partialURL)
            throw StoppedBeforeRecording()
        }
        fputs("\nSaving \(status.elapsed) of audio...\n", stderr)
        try output.save()
        fputs("Saved \(output.url.path)\n", stderr)
    }

    /// Starts the recording at the moment it tells the user so. Runs on the writer queue.
    private func beginRecording() {
        hasStarted = true
        let isReady = recorder.isReadyToRecord
        recorder.startRecording()
        let channelLayout = recorder.isolatesSpeakers ? " (mic left, system right)" : " (mixed)"
        let source =
            microphoneCapture?.device.map { "system audio + mic \"\($0.name)\"\(channelLayout)" }
            ?? "system audio"
        fputs("Recording \(source) -> \(output.url.path)\nPress Ctrl-C to stop and save.\n", stderr)
        if !isReady {
            status.announce("no sound from the mic or system audio yet; recording anyway")
        }
        status.showLevels(LevelSnapshot(microphonePeak: 0, systemPeak: 0, systemHasHeardSound: false))

        writerTimer.schedule(deadline: .now() + Self.tickSeconds, repeating: Self.tickSeconds)
        writerTimer.setEventHandler { [weak self] in self?.tick() }
        writerTimer.resume()
    }

    /// Runs on the writer queue.
    private func tick() {
        supervisor.supervise()
        do {
            try recorder.writeAvailable()
        } catch {
            status.reportWriteFailure(error)
        }
        ticks += 1
        guard ticks % Self.ticksPerLevelUpdate == 0 else { return }
        let levels = recorder.levels()
        warnIfSystemAudioIsSilent(levels)
        status.showLevels(levels)
    }

    /// Usually means the terminal lacks the system audio recording permission, which fails silently.
    private func warnIfSystemAudioIsSilent(_ levels: LevelSnapshot) {
        guard !hasWarnedAboutSilence, !levels.systemHasHeardSound else { return }
        guard Double(ticks) * Self.tickSeconds >= Self.silentSystemWarningSeconds else { return }
        hasWarnedAboutSilence = true
        status.announce(
            "No system audio captured yet. If something is playing, allow your terminal in System Settings > "
                + "Privacy & Security > Screen & System Audio Recording (System Audio Recording Only), "
                + "then restart totalrecall."
        )
    }
}
