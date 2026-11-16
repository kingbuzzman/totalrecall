import AppKit
import AppSupport
import Shared
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
        Group {
            switch model.state {
            case .idle:
                Text("Not recording")
            case .starting:
                Text("Starting “\(model.meeting?.name ?? "")”…")
            case .recording:
                RecordingLine()
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
                choosingCalendar(Button(startTitle("Start Recording")) { model.startMeeting(named: "") }) {
                    Button("Start Recording On…") {
                        if let choice = askForMeeting(name: false, calendar: true) {
                            model.startMeeting(named: "", on: choice.calendar)
                        }
                    }
                }
                if let meeting = model.meeting {
                    Button("Continue “\(meeting.name)”") { model.continueMeeting() }
                }
            }
            // New Meeting puts the meeting on a calendar, so it is there only while there is one to put it on.
            if !model.meetingCalendars.isEmpty {
                let newMeeting = model.isRecording ? "Stop and Start a New Meeting" : "New Meeting"
                choosingCalendar(
                    Button(startTitle(newMeeting) + "…") {
                        if let choice = askForMeeting(name: true, calendar: false) {
                            model.startMeeting(named: choice.name, addsEvent: true)
                        }
                    }
                ) {
                    Button("\(newMeeting) On…") {
                        if let choice = askForMeeting(name: true, calendar: true) {
                            model.startMeeting(named: choice.name, on: choice.calendar, addsEvent: true)
                        }
                    }
                }
            }

            if !model.unsavedRecordings.isEmpty {
                let count = model.unsavedRecordings.count
                Button("Save \(counted(count, "Unsaved Recording"))") {
                    model.saveUnsavedRecordings()
                }
            }

            // Only while there is a transcript to show; a window already open stays, with the last one.
            if model.isRecording {
                Divider()

                Button("Show Transcript") {
                    openWindow(id: Self.transcriptWindow)
                    WindowFocus.bringToFront(Self.transcriptWindow)
                }
                .keyboardShortcut("t")
            }

            Divider()

            Button("Settings…") {
                openSettings()
                WindowFocus.bringToFront(Self.settingsWindow)
            }
            .keyboardShortcut(",")
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")

        }
        // In case AppKit made the icon's window afresh, such as after the menu bar was rebuilt.
        .onAppear { MenuBarIconSharing.apply() }
    }

    /// The next meeting on the calendar, and today's meetings, any of which can be recorded now from its submenu.
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
            let time = next.start.shortTime
            Text(
                next.start <= model.scheduleTime
                    ? "Now: \(next.shortTitle), since \(time)" : "Next: \(next.shortTitle) at \(time)"
            )
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
        let status = model.status(of: meeting)
        let note =
            switch status {
            case .recorded: " — recorded"
            case .skipped: " — skipped"
            case .underway: " — now"
            case .upcoming, .ended: ""
            }
        return Menu("\(meeting.start.shortTime)–\(meeting.end.shortTime)  \(meeting.shortTitle)\(note)") {
            Button(model.isRecording ? "Stop and Record It Now" : "Record Now") { model.record(meeting) }
            if status == .upcoming || status == .underway || status == .skipped {
                Button(status == .skipped ? "Don't Skip" : "Skip") { model.toggleSkipped(meeting) }
            }
            Divider()
            Button("Always Ignore Meetings Like This") { model.alwaysIgnore(meeting) }
        }
    }

    /// `item`, and, while there is more than one calendar to file a recording under, `alternate` for when ⌘ is held,
    /// which asks which. Neither has a keyboard shortcut: an item with a ⌘ shortcut cannot also have an alternate for
    /// ⌘. The alternates ask in a dialog rather than a submenu, which the clock, redrawing its line of the menu every
    /// second, would close.
    @ViewBuilder
    private func choosingCalendar(_ item: some View, @ViewBuilder alternate: () -> some View) -> some View {
        if model.meetingCalendars.count > 1 {
            item.modifierKeyAlternate(.command, alternate)
        } else {
            item
        }
    }

    /// "Start Recording on Work": an item that starts a meeting, with the calendar it is filed under, when there is a
    /// choice of calendars, as holding ⌘ gives.
    private func startTitle(_ title: String) -> String {
        guard model.meetingCalendars.count > 1, let calendar = model.defaultMeetingCalendar else { return title }
        return "\(title) on \(calendar.title)"
    }

    /// Asks for the new meeting's name, the calendar to file it under, the default one picked to begin with, or both;
    /// nil if cancelled.
    private func askForMeeting(name asksName: Bool, calendar asksCalendar: Bool) -> MeetingChoice? {
        let alert = NSAlert()
        alert.messageText = asksName ? "New meeting" : "Start recording"
        alert.informativeText =
            asksName
            ? "Its recording and transcript go in a folder named after it." : "Pick the calendar to file it under."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.placeholderString = "Meeting"
        // The last name given, selected: typing replaces it, or it can be changed a little, as for the next of a series.
        field.stringValue = AppSettings.lastMeetingName
        let calendars = model.meetingCalendars
        let popUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 280, height: 26), pullsDown: false)
        popUp.addItems(withTitles: calendars.map(\.title))
        if let index = calendars.firstIndex(where: { $0 == model.defaultMeetingCalendar }) {
            popUp.selectItem(at: index)
        }
        // Laid out by frame, top to bottom, 8 points apart: in a stack view, the field shrinks to nothing.
        let views: [NSView] = (asksName ? [field] : []) + (asksCalendar ? [popUp] : [])
        let height = views.map(\.frame.height).reduce(0, +) + CGFloat(views.count - 1) * 8
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: height))
        var top = height
        for view in views {
            top -= view.frame.height
            view.setFrameOrigin(NSPoint(x: 0, y: top))
            accessory.addSubview(view)
            top -= 8
        }
        alert.accessoryView = accessory
        alert.addButton(withTitle: "Record")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = asksName ? field : popUp
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        if asksName { AppSettings.lastMeetingName = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }
        let picked = calendars.indices.contains(popUp.indexOfSelectedItem) ? calendars[popUp.indexOfSelectedItem] : nil
        return MeetingChoice(name: field.stringValue, calendar: picked)
    }
}

/// What the new meeting dialog was given: the meeting's name, and the calendar to file it under, if it asked for one.
private struct MeetingChoice {
    let name: String
    let calendar: CalendarSource.Calendar?
}

/// "Recording “Standup” · 0:12:34": the one line of the menu that reads the time every second, in a view of its own so
/// that only it is redrawn each second.
private struct RecordingLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Text("Recording “\(model.meeting?.name ?? "")” · \(model.elapsed)")
    }
}
