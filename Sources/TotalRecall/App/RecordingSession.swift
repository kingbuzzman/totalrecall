import CoreAudio
import Foundation

/// Stopped before the captures were live and the recording started, so there is nothing to save.
struct StoppedBeforeRecording: LocalizedError {
    var errorDescription: String? { "stopped before the recording started; nothing was saved" }
}

/// One recording from start to save: starts the captures, starts the recording once they deliver audio and the echo
/// canceller has a baseline of ambient sound, writes to the destination on a timer while the supervisor keeps the
/// captures alive, shows levels, and saves the output file when stopped.
final class RecordingSession {
    private static let tickSeconds = 0.25
    private static let ticksPerLevelUpdate = 4
    /// How often to check whether the recording can start.
    private static let startupPollSeconds = 0.01
    /// Longest to wait for the recording to be able to start, such as with a muted microphone, before starting anyway.
    private static let maxStartupWaitSeconds = 6.0

    /// Called on the writer queue when only streaming to stdout and the program reading it has gone away. With
    /// `--stream`, the file keeps recording instead.
    var onOutputClosed: (@Sendable () -> Void)?
    private let destination: Destination
    private let recorder: Recorder
    private let systemCapture: SystemAudioCapture
    private let microphoneCapture: MicrophoneCapture?
    private let supervisor: CaptureSupervisor
    private let status: StatusLine
    private let writerQueue: DispatchQueue
    private let startupTimer: any DispatchSourceTimer
    private let writerTimer: any DispatchSourceTimer
    /// Whether the recording started; used only on the writer queue.
    private var hasStarted = false
    private var isOutputClosed = false
    private var ticks = 0

    /// Creates the partial recording and starts the stream, as the destination asks; throws if that fails.
    init(options: Options, destination: Destination) throws {
        let fileSink = try destination.file.map { try AudioFileSink(url: $0.partialURL) }
        let rawSink = try destination.file?.rawURL.map(AudioFileSink.init)
        let streamSink = destination.streams ? try WAVStreamSink(handle: .standardOutput) : nil
        var fileAndStream: FileAndStreamSink?
        let sink: any AudioSink
        if let fileSink, let streamSink {
            let both = FileAndStreamSink(file: fileSink, stream: streamSink)
            fileAndStream = both
            sink = both
        } else if let fileSink {
            sink = fileSink
        } else {
            // A destination always has a file, a stream or both.
            sink = streamSink!
        }
        let recorder = Recorder(
            writingTo: sink,
            rawSink: rawSink,
            includesMicrophone: options.includesMicrophone,
            isolatesSpeakers: options.isolatesSpeakers,
            cancelsEcho: options.cancelsEcho
        )
        let systemCapture = SystemAudioCapture(onSamples: recorder.appendSystem)
        let microphoneCapture =
            options.includesMicrophone
            ? MicrophoneCapture(preferredName: options.microphoneQuery, onSamples: recorder.appendMicrophone)
            : nil
        let status = StatusLine(recorder: recorder, isStreaming: destination.streams)
        let writerQueue = DispatchQueue(label: "totalrecall.writer")
        self.destination = destination
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

    /// Starts the captures, and the recording as soon as the recorder is ready. If a capture cannot start, deletes the
    /// partial recording and throws.
    func start() throws {
        do {
            try systemCapture.start()
            try microphoneCapture?.start()
        } catch {
            removePartialRecording()
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

    /// Ends the recording now, stops the captures, finishes the recording and, for a file, converts the partial
    /// recording to the output file; if that fails, the partial recording is kept. Throws `StoppedBeforeRecording` if
    /// the recording had not started yet.
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
                // A stream's reader usually exits at the same time: Ctrl-C stops every program in the pipeline.
                if destination.file != nil { status.reportWriteFailure(error) }
            }
            return hasStarted
        }
        guard hadStarted else {
            removePartialRecording()
            throw StoppedBeforeRecording()
        }
        guard let output = destination.file else {
            let reason = isOutputClosed ? " (the program reading it exited)" : ""
            status.say("Streamed \(status.elapsed) of audio\(reason).")
            return
        }
        fputs("\nSaving \(status.elapsed) of audio...\n", stderr)
        try output.save()
        fputs("Saved \(output.url.path)\n", stderr)
    }

    private func removePartialRecording() {
        if let output = destination.file { try? FileManager.default.removeItem(at: output.partialURL) }
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
        fputs("Recording \(source) -> \(destination.description)\nPress Ctrl-C to stop and save.\n", stderr)
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
        guard ticks % Self.ticksPerLevelUpdate == 0 else { return }
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
