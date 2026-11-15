import CoreAudio
package import Foundation

/// Stopped before the captures were live and the recording started, so there is nothing to save.
package struct StoppedBeforeRecording: LocalizedError {
    package var errorDescription: String? { "stopped before the recording started; nothing was saved" }
}

/// One recording from start to save: starts the captures, starts the recording once they deliver audio and the echo
/// canceller has a baseline of ambient sound, writes to the destination on a timer while the supervisor keeps the
/// captures alive, shows levels, and saves the output file when stopped, encoding it as it records so that saving is
/// quick.
package final class RecordingSession {
    private static let tickSeconds = 0.25
    private static let ticksPerLevelUpdate = 4
    /// How often to check whether the recording can start.
    private static let startupPollSeconds = 0.01
    /// Longest to wait for the recording to be able to start, such as with a muted microphone, before starting anyway.
    private static let maxStartupWaitSeconds = 6.0

    /// Called on the writer queue when only streaming to stdout and the program reading it has gone away. With
    /// `--stream`, the file keeps recording instead.
    package var onOutputClosed: (@Sendable () -> Void)?
    /// Called on the writer queue the moment the recording starts, once the captures deliver audio (see `start()`).
    package var onRecordingStarted: (@Sendable () -> Void)?
    private let destination: Destination
    /// Encodes the recording into the output file's format as it records, when that needs encoding.
    private let encoder: LiveEncoder?
    private let recorder: Recorder
    private let systemCapture: SystemAudioCapture
    private let microphoneCapture: MicrophoneCapture?
    private let supervisor: CaptureSupervisor
    private let status: StatusLine
    private let say: (String) -> Void
    /// Whether it runs in the command-line tool, which Ctrl-C stops, rather than an app given `messages`.
    private let isCommandLine: Bool
    private let writerQueue: DispatchQueue
    private let startupTimer: any DispatchSourceTimer
    private let writerTimer: any DispatchSourceTimer
    /// Whether the recording started; used only on the writer queue.
    private var hasStarted = false
    /// Whether `stop()` found the recording started, so `save()` has something to save.
    private var hasRecording = false
    private var isOutputClosed = false
    private var ticks = 0
    /// Stops the device-change notifications `start()` asked for; in an app, which goes on after a recording, they
    /// would otherwise keep each recording's session alive.
    private var stopWatchingDevices: () -> Void = {}

    /// Creates the partial recording and starts the stream, as the destination asks; throws if that fails. Progress
    /// goes to stderr, with a level meter on a terminal, or, given `messages`, to it, a line at a time.
    package init(options: Options, destination: Destination, messages: ((String) -> Void)? = nil) throws {
        let sinks = try Sinks(for: destination)
        let encoder = sinks.encoder
        let fileAndStream = sinks.fileAndStream
        let recorder = Recorder(
            writingTo: sinks.recording,
            rawSink: sinks.raw,
            includesMicrophone: options.includesMicrophone,
            isolatesSpeakers: options.isolatesSpeakers,
            cancelsEcho: options.cancelsEcho
        )
        let systemCapture = SystemAudioCapture(onSamples: recorder.appendSystem)
        let microphoneCapture =
            options.includesMicrophone
            ? MicrophoneCapture(preferredName: options.microphoneQuery, onSamples: recorder.appendMicrophone)
            : nil
        let status =
            messages.map {
                StatusLine(recorder: recorder, isStreaming: destination.streams, isTerminal: false, write: $0)
            }
            ?? StatusLine(recorder: recorder, isStreaming: destination.streams)
        let writerQueue = DispatchQueue(label: "totalrecall.writer")
        self.destination = destination
        self.encoder = encoder
        isCommandLine = messages == nil
        say = messages.map { write in { write($0 + "\n") } } ?? { fputs($0 + "\n", stderr) }
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
        if let fileAndStream, let file = destination.file {
            fileAndStream.onStreamClosed = { [status] in
                status.announce("the program reading the stream exited; still recording to \(file.url.path)")
            }
        }
    }

    /// What the recording is written to, as the destination asks: the partial recording, encoded into the output
    /// file's format as it records, the stream, or both, and the raw audio with `TOTALRECALL_RAW=1`.
    private struct Sinks {
        let recording: any AudioSink
        let raw: AudioFileSink?
        let encoder: LiveEncoder?
        /// The file and the stream, when it is both.
        let fileAndStream: FileAndStreamSink?

        init(for destination: Destination) throws {
            let partial = try destination.file.map { try AudioFileSink(url: $0.partialURL) }
            raw = try destination.file?.rawURL.map { try AudioFileSink(url: $0) }
            let stream = destination.streams ? try WAVStreamSink(handle: destination.streamHandle) : nil
            let encoder = destination.file.flatMap(LiveEncoder.start)
            self.encoder = encoder
            let file: (any AudioSink)? = partial.map { partial in
                encoder.map { EncodingSink(file: partial, encoder: $0) as any AudioSink } ?? partial
            }
            if let file, let stream {
                let both = FileAndStreamSink(file: file, stream: stream)
                fileAndStream = both
                recording = both
            } else {
                fileAndStream = nil
                // A destination always has a file, a stream or both.
                recording = file ?? stream!
            }
        }
    }

    /// Starts the captures, and the recording as soon as the recorder is ready. If a capture cannot start, deletes the
    /// partial recording and throws.
    package func start() throws {
        do {
            try systemCapture.start()
            try microphoneCapture?.start()
        } catch {
            // In an app, unlike the command line, the process goes on: leave nothing running behind.
            microphoneCapture?.stop()
            systemCapture.stop()
            encoder?.cancel()
            removePartialRecording()
            throw error
        }
        stopWatchingDevices = onSystemDeviceChange(queue: writerQueue) { [supervisor] in
            supervisor.systemDevicesChanged()
        }

        let deadline = uptimeSeconds() + Self.maxStartupWaitSeconds
        startupTimer.schedule(deadline: .now(), repeating: Self.startupPollSeconds)
        startupTimer.setEventHandler { [weak self] in
            guard let self, recorder.isReadyToRecord || uptimeSeconds() >= deadline else { return }
            startupTimer.cancel()
            beginRecording()
        }
        startupTimer.resume()
    }

    /// Length of the recording so far, in seconds; 0 until it has started.
    package var secondsRecorded: Double { recorder.secondsRecorded }

    /// Stops and saves: `stop()`, then `save()`.
    package func stopAndSave() throws {
        try stop()
        try save()
    }

    /// Ends the recording now, stops the captures and finishes the partial recording and the stream: quick, so that
    /// another recording can start at once. Throws `StoppedBeforeRecording` if the recording had not started yet,
    /// having deleted what there was of it.
    package func stop() throws {
        let stopTime = AudioGetCurrentHostTime()
        hasRecording = writerQueue.sync {
            startupTimer.cancel()
            if hasStarted {
                recorder.stopRecording(at: stopTime)
                writerTimer.cancel()
            }
            stopWatchingDevices()
            microphoneCapture?.stop()
            systemCapture.stop()
            do {
                try recorder.close()
            } catch {
                // A stream's reader usually exits at the same time: Ctrl-C stops every program in the pipeline.
                if destination.file != nil { status.reportWriteFailure(error) }
            }
            return hasStarted
        }
        guard hasRecording else {
            encoder?.cancel()
            removePartialRecording()
            throw StoppedBeforeRecording()
        }
        if destination.file == nil {
            let reason = isOutputClosed ? " (the program reading it exited)" : ""
            status.say("Streamed \(status.elapsed) of audio\(reason).")
        }
    }

    /// After `stop()`, saves the output file: finishes the encoding done while recording, or, if there was none or it
    /// failed, converts the partial recording. If that fails, the partial recording is kept, and this throws.
    package func save() throws {
        guard hasRecording, let output = destination.file else { return }
        say((isCommandLine ? "\n" : "") + "Saving \(status.elapsed) of audio...")
        var encoded: URL?
        do {
            encoded = try encoder?.finish()
        } catch {
            status.announce("encoding while recording failed (\(error.localizedDescription)); converting the recording")
        }
        try output.save(encoded: encoded)
        say("Saved \(output.url.path)")
    }

    private func removePartialRecording() {
        if let output = destination.file { try? FileManager.default.removeItem(at: output.partialURL) }
    }

    /// Starts the recording at the moment it tells the user so. Runs on the writer queue.
    private func beginRecording() {
        hasStarted = true
        let isReady = recorder.isReadyToRecord
        recorder.startRecording()
        onRecordingStarted?()
        let channelLayout = recorder.isolatesSpeakers ? " (mic left, system right)" : " (mixed)"
        let source =
            microphoneCapture?.device.map { "system audio + mic \"\($0.name)\"\(channelLayout)" }
            ?? "system audio"
        say("Recording \(source) -> \(destination.description)")
        if isCommandLine { say("Press Ctrl-C to stop and save.") }
        if !isReady {
            status.announce("no sound from the mic or system audio yet; recording anyway")
        }
        status.showLevels(LevelSnapshot(microphonePeak: 0, systemPeak: 0))

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
            handleWriteFailure(error)
        }
        guard !isOutputClosed else { return }
        ticks += 1
        guard ticks.isMultiple(of: Self.ticksPerLevelUpdate) else { return }
        let levels = recorder.levels()
        status.showLevels(levels)
    }

    /// When only streaming, a failed write means the program reading the stream has exited, which ends the recording.
    /// With a file, it is the file that failed: the stream's failures never get here (see `FileAndStreamSink`).
    private func handleWriteFailure(_ error: any Error) {
        guard destination.file == nil else {
            status.reportWriteFailure(error)
            return
        }
        guard !isOutputClosed else { return }
        isOutputClosed = true
        onOutputClosed?()
    }
}
