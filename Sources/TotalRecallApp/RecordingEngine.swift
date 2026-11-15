import AppSupport
import Foundation
import TotalRecall
import Transcribe
import os

/// What the app records with: one recording at a time, as `record-meetings` runs `totalrecall DIR/rec.mp3 --stream |
/// transcribe - DIR/transcript.txt --live`, but in this process, the recording streamed to the transcriber through a
/// pipe.
///
/// Starting and stopping run in turn on a queue of their own, so a stop asked for while a recording is still starting
/// waits for it, and nothing blocks the user interface. Stopping returns as soon as the captures are stopped; the file
/// is saved, and the transcript finished, in the background, so the next recording can start at once.
final class RecordingEngine: Sendable {
    /// What happened to recording `id`, reported from any thread, in order.
    enum Event: Sendable {
        /// The recording started, once the captures delivered audio.
        case started
        /// It could not start; nothing is saved.
        case failedToStart(String)
        /// Stopped before it started, so there is nothing to save.
        case nothingRecorded
        /// Stopped: the file is being saved.
        case stopped
        case saved(URL)
        case failedToSave(String)
        /// A line of the transcript, as it settled.
        case line(String)
        /// The words still being recognized; "" once there are none.
        case liveText(String)
        /// News from the recorder or the transcriber, such as a microphone switch.
        case message(String)
        /// The transcript started; it goes on until the recording stops and the last words are written.
        case transcriptStarted
        /// The transcript is complete, or stopped short with this error.
        case transcriptFinished(String?)
    }

    struct Request: Sendable {
        let id: Int
        let directory: URL
        let format: AudioFormatChoice
        /// Part of a microphone's name to prefer whenever it is connected, or nil for the system input.
        let microphone: String?
        let language: String?
        let identifiesSpeakers: Bool
    }

    private let queue = DispatchQueue(label: "totalrecall.app.recording")
    /// The recording going on; only used on `queue`.
    nonisolated(unsafe) private var current: Recording?

    /// Starts a recording into a free rec.EXT and transcript.txt in `request.directory`.
    func start(_ request: Request, events: @escaping @Sendable (Int, Event) -> Void) {
        queue.async { [self] in
            let report: @Sendable (Event) -> Void = { event in events(request.id, event) }
            do {
                current = try Recording.start(request, report: report)
            } catch {
                report(.failedToStart(error.localizedDescription))
            }
        }
    }

    /// Stops the recording going on, if any, and saves it in the background; then calls `done` on the main queue, after
    /// the events of the stop.
    func stop(then done: (@MainActor @Sendable () -> Void)? = nil) {
        queue.async { [self] in
            current?.stop()
            current = nil
            if let done { DispatchQueue.main.async { done() } }
        }
    }
}

/// One recording and its transcript.
private final class Recording: @unchecked Sendable {
    private let session: RecordingSession
    private let pipe: Pipe
    private let audio: URL
    /// Set when it stopped before it started: its transcript, empty, is then deleted once finished.
    private let isDiscarded: OSAllocatedUnfairLock<Bool>
    private let report: @Sendable (RecordingEngine.Event) -> Void

    private init(
        session: RecordingSession,
        pipe: Pipe,
        audio: URL,
        isDiscarded: OSAllocatedUnfairLock<Bool>,
        report: @escaping @Sendable (RecordingEngine.Event) -> Void
    ) {
        self.session = session
        self.pipe = pipe
        self.audio = audio
        self.isDiscarded = isDiscarded
        self.report = report
    }

    static func start(
        _ request: RecordingEngine.Request,
        report: @escaping @Sendable (RecordingEngine.Event) -> Void
    ) throws -> Recording {
        guard requestSystemAudioAccess() else {
            throw AppError(
                "TotalRecall may not record system audio. Allow it in System Settings › Privacy & Security › "
                    + "Screen & System Audio Recording › System Audio Recording Only, then quit and reopen TotalRecall."
            )
        }
        guard requestMicrophoneAccess() else {
            throw AppError(
                "TotalRecall may not use the microphone. Allow it in System Settings › Privacy & Security › Microphone."
            )
        }
        try FileManager.default.createDirectory(at: request.directory, withIntermediateDirectories: true)
        let (audio, transcript) = RecordingFolder.freePaths(
            in: request.directory,
            audioExtension: request.format.fileExtension
        )

        var options = Options()
        if let microphone = request.microphone, !InputDevice.matching(microphone).isEmpty {
            options.microphoneQuery = microphone
        } else if let microphone = request.microphone {
            report(.message("\(microphone) is not connected; recording the system input"))
        }
        let pipe = Pipe()
        // Once the transcriber has stopped reading, a write fails rather than killing the app.
        _ = fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let destination = Destination(path: audio.path, streams: true, streamHandle: pipe.fileHandleForWriting)
        let session = try RecordingSession(options: options, destination: destination) { text in
            for line in text.split(separator: "\n") where !line.isEmpty {
                report(.message(String(line).replacing(#/^totalrecall: /#, with: "")))
            }
        }
        session.onRecordingStarted = { report(.started) }
        do {
            try session.start()
        } catch {
            try? pipe.fileHandleForWriting.close()
            throw error
        }

        // The transcript goes on to the end of the stream, after the recording stops. If it stops early, its end of
        // the pipe is closed, so the recording goes on without it rather than wait for it.
        let input = pipe.fileHandleForReading
        let isDiscarded = OSAllocatedUnfairLock(initialState: false)
        report(.transcriptStarted)
        Task.detached(priority: .userInitiated) {
            defer {
                try? input.close()
                if isDiscarded.withLock({ $0 }) { try? FileManager.default.removeItem(at: transcript) }
            }
            do {
                try await transcribeLive(
                    from: input,
                    to: transcript,
                    language: request.language,
                    identifiesSpeakers: request.identifiesSpeakers,
                    onLine: { report(.line($0)) },
                    onLiveText: { report(.liveText($0)) },
                    onMessage: { report(.message($0)) }
                )
                report(.transcriptFinished(nil))
            } catch {
                report(.transcriptFinished(error.localizedDescription))
            }
        }
        return Recording(session: session, pipe: pipe, audio: audio, isDiscarded: isDiscarded, report: report)
    }

    /// Stops recording at once, ends the stream so the transcript can finish, and saves the file in the background.
    func stop() {
        do {
            try session.stop()
        } catch {
            isDiscarded.withLock { $0 = true }
            try? pipe.fileHandleForWriting.close()
            report(.nothingRecorded)
            return
        }
        try? pipe.fileHandleForWriting.close()
        report(.stopped)
        DispatchQueue.global(qos: .utility).async { [self] in
            do {
                try session.save()
                report(.saved(audio))
            } catch {
                report(
                    .failedToSave(
                        "\(error.localizedDescription); the recording is kept as \(audio.lastPathComponent).partial.caf"
                    )
                )
            }
        }
    }
}

struct AppError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}
