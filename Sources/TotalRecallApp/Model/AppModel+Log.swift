import AppSupport
import Foundation
import os

/// What the app tells the system log about each recording.
extension AppModel {
    /// Tells the log (see `Log`) what happened to recording `id`, as it happens, at info level; failures are logged as
    /// errors where they are handled.
    func logEvent(_ event: RecordingEngine.Event, of id: Int) {
        let what: String? =
            switch event {
            case .started: "started"
            case .nothingRecorded: "stopped before it started; nothing recorded"
            case .stopped: "stopped; saving"
            case .saved(let url): "saved \(url.path)"
            case .message(let message): message
            case .voiceProcessing(let isOn): isOn ? "mic on voice processing" : "mic off voice processing"
            case .transcriptStarted: "transcript started"
            case .transcriptFinished(let error): error == nil ? "transcript finished" : nil
            case .audioTrashed(let audio, _, _): "moved \(audio.lastPathComponent) to the Trash, transcribed"
            case .rewritten(let lines): "transcript written again by who turned out to speak: \(lines.count) lines"
            case .transcriptRestarted(let language): "transcript started over in \(language)"
            case .transcriptCaughtUp: "transcript caught up with the recording"
            case .languageSwitchFailed(let language, let reason): "could not switch to \(language): \(reason)"
            case .failedToStart, .failedToSave, .line, .liveText: nil
            }
        if let what { log.info("recording \(id, privacy: .public): \(what, privacy: .public)") }
    }

    /// What a recording starts with: where it goes, and the settings it records and transcribes by.
    func logStart(_ request: RecordingEngine.Request, of meeting: Meeting) {
        log.info(
            """
            recording \(request.id, privacy: .public) of “\(meeting.name, privacy: .public)” into \(meeting.directory.path, privacy: .public): \
            \(request.format.rawValue, privacy: .public), mic \(request.microphone ?? "system input", privacy: .public), \
            language \(request.language ?? "en-US", privacy: .public), identify speakers \(request.identifiesSpeakers, privacy: .public), \
            trash once transcribed \(request.trashesAudioOnceTranscribed, privacy: .public)
            """
        )
    }
}
