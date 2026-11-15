import AppKit
import AppSupport
import Foundation
import Observation
import TotalRecall
import Transcribe
import os

/// What the app is doing, for the menu, the transcript window and the notifications: starts and stops recordings on the
/// `RecordingEngine`, and follows the transcript of the latest one.
@MainActor @Observable
final class AppModel {
    enum State: Equatable {
        case idle
        /// Waiting for the captures to deliver audio, which takes a second or so, 2–3 s with AirPods.
        case starting
        case recording(since: Date)
    }

    /// A meeting being recorded, or the last one: its name and the folder its recordings go in.
    struct Meeting: Equatable {
        let name: String
        let directory: URL
    }

    private(set) var state = State.idle
    /// The meeting being recorded, or the last one, which Continue records into again.
    private(set) var meeting: Meeting?
    /// The transcript of the latest recording so far, line by line, and the words still being recognized.
    private(set) var transcript: [String] = []
    private(set) var liveText = ""
    private(set) var lastMessage = ""
    /// Recordings being saved, after they stopped, and transcripts going on, including the one being recorded, until
    /// their last words are written.
    private(set) var savingCount = 0
    private(set) var transcribingCount = 0
    /// Partial recordings a crash or a forced quit left unsaved, which the menu offers to save.
    private(set) var unsavedRecordings: [(partial: URL, output: URL)] = []
    /// Now, every second while recording, so the elapsed time shown updates.
    private(set) var now = Date()

    var isRecording: Bool { state != .idle }
    var isBusy: Bool { savingCount > 0 || transcribingCount > 0 }
    /// Transcripts of recordings that have stopped, still being finished.
    var finishingTranscripts: Int { max(0, transcribingCount - (isRecording ? 1 : 0)) }

    private let engine = RecordingEngine()
    private let notifier = Notifier()
    private let log = Logger(subsystem: "local.totalrecall.app", category: "recording")
    /// The latest recording's number: events of earlier ones, still finishing, leave the transcript shown alone.
    private var recordingID = 0
    private var clock: Timer?
    /// Called once nothing is being saved or transcribed any more, for quitting.
    private var whenIdle: (() -> Void)?

    init() {
        notifier.requestPermission()
        prepareTranscription()
        findUnsavedRecordings()
    }

    /// How long the recording has been going, as H:MM:SS.
    var elapsed: String {
        guard case .recording(let since) = state else { return "0:00:00" }
        let seconds = max(0, Int(now.timeIntervalSince(since)))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }

    /// Starts recording a new meeting named `name`, stopping the one being recorded first.
    func startMeeting(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Meeting" : trimmed
        let directory = RecordingFolder.directory(root: AppSettings.recordingsFolder, name: title, start: Date())
        start(Meeting(name: title, directory: directory))
    }

    /// Records the last meeting again, into its folder, as rec-2, transcript-2 and so on, the way `record-meetings`
    /// does when a meeting is restarted.
    func continueMeeting() {
        guard let meeting else { return startMeeting(named: "") }
        start(meeting)
    }

    func stop() {
        guard isRecording else { return }
        engine.stop()
        state = .idle
        clock?.invalidate()
        clock = nil
    }

    /// Stops recording and calls `done` once every file is saved and every transcript finished, for quitting.
    func stopAndFinish(_ done: @escaping () -> Void) {
        state = .idle
        clock?.invalidate()
        clock = nil
        engine.stop { [weak self] in
            guard let self, isBusy else { return done() }
            whenIdle = done
        }
    }

    private func start(_ meeting: Meeting) {
        if isRecording { engine.stop() }
        recordingID += 1
        self.meeting = meeting
        transcript = []
        liveText = ""
        lastMessage = ""
        state = .starting
        let request = RecordingEngine.Request(
            id: recordingID,
            directory: meeting.directory,
            format: AppSettings.format,
            microphone: AppSettings.microphone,
            language: AppSettings.language,
            identifiesSpeakers: AppSettings.identifiesSpeakers
        )
        // Through the main queue rather than a task each, so the events keep their order.
        engine.start(request) { [weak self] id, event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, of: id) } }
        }
    }

    private func handle(_ event: RecordingEngine.Event, of id: Int) {
        let isLatest = id == recordingID
        switch event {
        case .started:
            guard isLatest, state == .starting else { return }
            state = .recording(since: Date())
            now = Date()
            clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.now = Date() }
            }
            notifier.post(title: "Recording “\(meeting?.name ?? "")”", body: "Stop it from the menu bar.")
        case .failedToStart(let reason):
            log.error("could not start recording: \(reason, privacy: .public)")
            if isLatest { state = .idle }
            notifier.post(title: "Could not record", body: reason)
        case .nothingRecorded:
            break
        case .stopped:
            savingCount += 1
        case .saved(let url):
            savingCount -= 1
            notifier.post(
                title: "Saved “\(url.deletingLastPathComponent().lastPathComponent)”",
                body: url.lastPathComponent,
                revealing: url
            )
            becameIdleIfDone()
        case .failedToSave(let reason):
            savingCount -= 1
            log.error("could not save: \(reason, privacy: .public)")
            notifier.post(title: "Could not save the recording", body: reason)
            becameIdleIfDone()
        case .line(let line):
            if isLatest { transcript.append(line) }
        case .liveText(let text):
            if isLatest { liveText = text }
        case .message(let message):
            log.info("\(message, privacy: .public)")
            if isLatest { lastMessage = message }
        case .transcriptStarted:
            transcribingCount += 1
        case .transcriptFinished(let error):
            transcribingCount -= 1
            if let error {
                log.error("transcript stopped: \(error, privacy: .public)")
                if isLatest { lastMessage = "The transcript stopped: \(error)" }
                notifier.post(title: "The transcript stopped", body: error)
            }
            becameIdleIfDone()
        }
    }

    private func becameIdleIfDone() {
        guard !isBusy, let whenIdle else { return }
        self.whenIdle = nil
        whenIdle()
    }

    /// Downloads the speech model in the background, if need be, so the first transcript does not wait for it.
    private func prepareTranscription() {
        let language = AppSettings.language
        let log = log
        Task.detached(priority: .utility) {
            do {
                try await Transcribe.prepareTranscription(language: language)
            } catch {
                log.error("cannot transcribe: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Looks for recordings a crash or a forced quit left unsaved, in the background, for the menu to offer saving.
    /// One written to in the last two minutes is left out: it may be a recording `record-meetings` is making right now.
    /// So is one whose output file exists, which saving it would replace.
    func findUnsavedRecordings() {
        let root = AppSettings.recordingsFolder
        Task.detached(priority: .utility) { [weak self] in
            let cutoff = Date().addingTimeInterval(-120)
            let unsaved = RecordingFolder.unsavedRecordings(under: root).filter { partial, output in
                let modified = try? partial.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                return (modified.map { $0 < cutoff } ?? false) && !FileManager.default.fileExists(atPath: output.path)
            }
            await MainActor.run { self?.unsavedRecordings = unsaved }
        }
    }

    /// Saves the recordings `findUnsavedRecordings()` found, in the background, converting each partial recording to
    /// the format its name asks for, and deleting it once saved.
    func saveUnsavedRecordings() {
        let unsaved = unsavedRecordings
        unsavedRecordings = []
        savingCount += unsaved.count
        let notifier = notifier
        for (partial, output) in unsaved {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let file = OutputFile(path: output.path)
                do {
                    guard !FileManager.default.fileExists(atPath: output.path) else {
                        throw AppError("\(output.lastPathComponent) already exists")
                    }
                    try file.save()
                    if let encoding = file.encodingURL { try? FileManager.default.removeItem(at: encoding) }
                    notifier.post(title: "Saved an unsaved recording", body: output.path, revealing: output)
                } catch {
                    notifier.post(
                        title: "Could not save an unsaved recording",
                        body: "\(partial.path): \(error.localizedDescription)"
                    )
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.savingCount -= 1
                        self?.becameIdleIfDone()
                    }
                }
            }
        }
    }
}
