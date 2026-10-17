import Foundation

/// One recording from start to save: feeds both captures into the recorder, writes the partial file on a timer while
/// the supervisor keeps the captures alive, shows levels, and saves the output file when stopped.
final class RecordingSession {
    private static let tickSeconds = 0.25
    private static let ticksPerLevelUpdate = 4
    private static let silentSystemWarningSeconds = 10.0

    private let output: OutputFile
    private let recorder: Recorder
    private let systemCapture: SystemAudioCapture
    private let microphoneCapture: MicrophoneCapture?
    private let supervisor: CaptureSupervisor
    private let status: StatusLine
    private let writerQueue: DispatchQueue
    private let writerTimer: DispatchSourceTimer
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
        writerTimer = DispatchSource.makeTimerSource(queue: writerQueue)
    }

    /// Starts capturing and writing. If a capture cannot start, deletes the partial recording and throws.
    func start() throws {
        do {
            try systemCapture.start()
            try microphoneCapture?.start()
        } catch {
            try? FileManager.default.removeItem(at: output.partialURL)
            throw error
        }
        onSystemDeviceChange(queue: writerQueue) { [supervisor] in supervisor.systemDevicesChanged() }

        let channelLayout = recorder.isolatesSpeakers ? " (mic left, system right)" : " (mixed)"
        let source =
            microphoneCapture?.device.map { "system audio + mic \"\($0.name)\"\(channelLayout)" }
            ?? "system audio"
        fputs("Recording \(source) -> \(output.url.path)\nPress Ctrl-C to stop and save.\n", stderr)

        writerTimer.schedule(deadline: .now() + Self.tickSeconds, repeating: Self.tickSeconds)
        writerTimer.setEventHandler { [weak self] in self?.tick() }
        writerTimer.resume()
    }

    /// Stops the captures, finishes the partial recording and converts it to the output file. If saving fails, the
    /// partial recording is kept.
    func stopAndSave() throws {
        writerQueue.sync {
            writerTimer.cancel()
            microphoneCapture?.stop()
            systemCapture.stop()
            do {
                try recorder.close()
            } catch {
                status.reportWriteFailure(error)
            }
        }
        fputs("\nSaving \(status.elapsed) of audio...\n", stderr)
        try output.save()
        fputs("Saved \(output.url.path)\n", stderr)
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
