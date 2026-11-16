import AppKit
import AppSupport
import Foundation
import os

/// The notifications: of a meeting about to start, a recording starting or failing to, and its files, saved and, once
/// transcribed, gone to the Trash; and what their buttons do.
extension AppModel {
    /// "Standup starts in 5 minutes", with Record Now and Skip.
    func announceWarning(of meeting: ScheduledMeeting, now: Date, body: String) {
        notifier.post(
            title: MeetingSchedule.warning(for: meeting, now: now),
            body: body,
            kind: .meeting,
            info: [
                InfoKey.title: meeting.title,
                InfoKey.start: String(meeting.start.timeIntervalSinceReferenceDate),
                InfoKey.end: String(meeting.end.timeIntervalSinceReferenceDate),
            ]
        )
    }

    /// "Recording “Standup”", with Stop Recording.
    func announceStarted(_ name: String) {
        notifier.post(title: "Recording “\(name)”", body: "Stop it here or from the menu bar.", kind: .recording)
    }

    /// "Could not record", with Try Again.
    func announceFailedToRecord(_ reason: String) {
        notifier.post(title: "Could not record", body: reason, kind: .failedToRecord)
    }

    /// "Saved “10h00-standup”"; clicking it shows the file in Finder.
    func announceSaved(_ audio: URL) {
        notifier.post(
            title: "Saved “\(audio.deletingLastPathComponent().lastPathComponent)”",
            body: audio.lastPathComponent,
            revealing: audio
        )
    }

    /// The recording went to the Trash once transcribed, with Open Transcript and Restore Recording; clicking it shows
    /// the transcript, which stays, in Finder.
    func announceTrashed(_ audio: URL, to trashed: URL?, keeping transcript: URL) {
        var info = [InfoKey.transcript: transcript.path, InfoKey.audio: audio.path]
        info[InfoKey.trashed] = trashed?.path
        notifier.post(
            title: "Transcribed “\(transcript.deletingLastPathComponent().lastPathComponent)”",
            body: "The recording went to the Trash; the transcript stays.",
            kind: .trashed,
            info: info,
            revealing: transcript
        )
    }

    /// Does what a notification's button says, with what the notification was posted with.
    func perform(_ action: Notifier.Action, _ info: [String: String]) {
        switch action {
        case .recordNow:
            guard let meeting = meeting(in: info), self.meeting?.scheduled != meeting || !isRecording else { return }
            record(meeting)
        case .skip:
            if let meeting = meeting(in: info), status(of: meeting) != .skipped { toggleSkipped(meeting) }
        case .stopRecording:
            stop()
        case .tryAgain:
            if !isRecording { continueMeeting() }
        case .openTranscript:
            if let path = info[InfoKey.transcript] { NSWorkspace.shared.open(URL(filePath: path)) }
        case .restoreRecording:
            guard let audio = info[InfoKey.audio], let trashed = info[InfoKey.trashed] else { return }
            do {
                try FileManager.default.moveItem(at: URL(filePath: trashed), to: URL(filePath: audio))
                NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: audio)])
            } catch {
                log.error(
                    "could not restore \(audio, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                notifier.post(title: "Could not restore the recording", body: error.localizedDescription)
            }
        }
    }

    /// The meeting of today's a notification is about.
    private func meeting(in info: [String: String]) -> ScheduledMeeting? {
        guard let title = info[InfoKey.title],
            let start = info[InfoKey.start].flatMap(Double.init),
            let end = info[InfoKey.end].flatMap(Double.init)
        else { return nil }
        return todaysMeetings.first {
            $0.title == title && $0.start.timeIntervalSinceReferenceDate == start
                && $0.end.timeIntervalSinceReferenceDate == end
        }
    }

    private enum InfoKey {
        static let title = "meetingTitle"
        static let start = "meetingStart"
        static let end = "meetingEnd"
        static let transcript = "transcript"
        static let audio = "audio"
        static let trashed = "trashed"
    }
}
