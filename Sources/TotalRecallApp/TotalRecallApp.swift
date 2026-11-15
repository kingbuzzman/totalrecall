import AppKit
import AppSupport
import SwiftUI

/// TotalRecall.app: records and transcribes meetings from the menu bar, as `scripts/record-meetings` does from the
/// terminal: today's meetings from the calendar as they start, and others started from the menu.
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
                .showsAppInDock()
                .focusedWhenOpened(as: MenuContent.transcriptWindow)
        }
        .defaultSize(width: 560, height: 480)

        Settings {
            SettingsView()
                .environment(delegate.model)
                .showsAppInDock()
                .focusedWhenOpened(as: MenuContent.settingsWindow)
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The menu bar icon's window is made as the app finishes launching; it is there on the next turn of the run loop.
        DispatchQueue.main.async { MenuBarIconSharing.apply() }
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) {
            _ in
            MainActor.assumeIsolated { MenuBarIconSharing.apply() }
        }
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
    static let settingsWindow = "settings"

    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        // In case AppKit made the icon's window afresh, such as after the menu bar was rebuilt.
        let _ = MenuBarIconSharing.apply()
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

        schedule

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

        // Only while there is a transcript to show; a window already open stays, with the last one.
        if model.isRecording {
            Button("Show Transcript") {
                openWindow(id: Self.transcriptWindow)
                WindowFocus.bringToFront(Self.transcriptWindow)
            }
            .keyboardShortcut("t")
        }
        Button("Open Recordings Folder") {
            let folder = model.meeting?.directory ?? AppSettings.recordingsFolder
            let existing = FileManager.default.fileExists(atPath: folder.path) ? folder : AppSettings.recordingsFolder
            NSWorkspace.shared.open(existing)
        }

        Divider()

        Button("Settings…") {
            openSettings()
            WindowFocus.bringToFront(Self.settingsWindow)
        }
        .keyboardShortcut(",")
        Button("Quit TotalRecall") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// The next meeting on the calendar, to start now, as when a meeting starts early, and today's meetings.
    @ViewBuilder private var schedule: some View {
        if !model.calendar.hasAccess {
            Button("Allow Calendar Access…") {
                if model.calendar.isDenied {
                    model.calendar.openSystemSettings()
                } else {
                    Task {
                        await model.calendar.requestAccess()
                        model.readCalendar()
                    }
                }
            }
        } else if let next = model.nextMeeting {
            let time = next.start.formatted(date: .omitted, time: .shortened)
            Text(
                next.start <= model.now
                    ? "Now: \(next.shortTitle), since \(time)" : "Next: \(next.shortTitle) at \(time)"
            )
            Button(model.isRecording ? "Stop and Start It Now" : "Start Now") { model.record(next) }
        } else {
            Text(model.todaysMeetings.isEmpty ? "No meetings today" : "No more meetings today")
        }
        if model.calendar.hasAccess && !model.todaysMeetings.isEmpty {
            Menu("Today") {
                ForEach(model.todaysMeetings, id: \.self) { meeting in
                    todayItem(meeting)
                }
            }
        }
    }

    /// One of today's meetings: when, what, and where it stands, with a submenu to record it now or skip it.
    private func todayItem(_ meeting: ScheduledMeeting) -> some View {
        let start = meeting.start.formatted(date: .omitted, time: .shortened)
        let end = meeting.end.formatted(date: .omitted, time: .shortened)
        let status = model.status(of: meeting)
        let note =
            switch status {
            case .recorded: " — recorded"
            case .skipped: " — skipped"
            case .underway: " — now"
            case .upcoming, .ended: ""
            }
        return Menu("\(start)–\(end)  \(meeting.shortTitle)\(note)") {
            Button(model.isRecording ? "Stop and Record It Now" : "Record Now") { model.record(meeting) }
            if status == .upcoming || status == .underway || status == .skipped {
                Button(status == .skipped ? "Don't Skip" : "Skip") { model.toggleSkipped(meeting) }
            }
            Divider()
            Button("Always Ignore Meetings Like This") { model.alwaysIgnore(meeting) }
        }
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
