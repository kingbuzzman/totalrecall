import AppKit
import SwiftUI

/// TotalRecall.app: records and transcribes meetings from the menu bar, as `scripts/record-meetings` does from the
/// terminal, without the calendar for now: recordings start and stop from the menu.
@main
struct TotalRecallApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(delegate.model)
        } label: {
            Image(delegate.model.isRecording ? "MenuBarIconRecording" : "MenuBarIcon")
        }

        Window("Transcript", id: MenuContent.transcriptWindow) {
            TranscriptView()
                .environment(delegate.model)
        }
        .defaultSize(width: 560, height: 480)

        Settings {
            SettingsView()
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationWillFinishLaunching(_ notification: Notification) {
        // A write to a pipe whose reader has gone, such as a transcript that stopped, fails instead of killing the app.
        signal(SIGPIPE, SIG_IGN)
    }

    /// Quitting while recording saves the recording and finishes its transcript first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isRecording || model.isBusy else { return .terminateNow }
        model.stopAndFinish { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

/// The menu under the menu bar icon.
struct MenuContent: View {
    static let transcriptWindow = "transcript"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        switch model.state {
        case .idle:
            Text("Not recording")
        case .starting:
            Text("Starting “\(model.meeting?.name ?? "")”…")
        case .recording:
            Text("Recording “\(model.meeting?.name ?? "")” · \(model.elapsed)")
        }
        if model.savingCount > 0 {
            Text(model.savingCount == 1 ? "Saving a recording…" : "Saving \(model.savingCount) recordings…")
        }
        if model.finishingTranscripts > 0 {
            Text(
                model.finishingTranscripts == 1
                    ? "Finishing a transcript…" : "Finishing \(model.finishingTranscripts) transcripts…"
            )
        }

        Divider()

        if model.isRecording {
            Button("Stop Recording") { model.stop() }
                .keyboardShortcut(".")
        } else {
            Button("Start Recording") { model.startMeeting(named: "") }
                .keyboardShortcut("r")
            if let meeting = model.meeting {
                Button("Continue “\(meeting.name)”") { model.continueMeeting() }
            }
        }
        Button(model.isRecording ? "Stop and Start a New Meeting…" : "New Meeting…") {
            if let name = askForMeetingName() { model.startMeeting(named: name) }
        }
        .keyboardShortcut("n")

        if !model.unsavedRecordings.isEmpty {
            let count = model.unsavedRecordings.count
            Button(count == 1 ? "Save 1 Unsaved Recording" : "Save \(count) Unsaved Recordings") {
                model.saveUnsavedRecordings()
            }
        }

        Divider()

        Button("Show Transcript") {
            openWindow(id: Self.transcriptWindow)
            NSApp.activate()
        }
        .keyboardShortcut("t")
        Button("Open Recordings Folder") {
            let folder = model.meeting?.directory ?? AppSettings.recordingsFolder
            let existing = FileManager.default.fileExists(atPath: folder.path) ? folder : AppSettings.recordingsFolder
            NSWorkspace.shared.open(existing)
        }

        Divider()

        Button("Settings…") {
            openSettings()
            NSApp.activate()
        }
        .keyboardShortcut(",")
        Button("Quit TotalRecall") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Asks for the new meeting's name; nil if cancelled.
    private func askForMeetingName() -> String? {
        let alert = NSAlert()
        alert.messageText = "New meeting"
        alert.informativeText = "Its recording and transcript go in a folder named after it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Meeting"
        alert.accessoryView = field
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }
}
