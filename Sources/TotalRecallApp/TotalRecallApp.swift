import AppKit
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
            // The red dot only once the recording really has started: a ring while it starts.
            switch delegate.model.state {
            case .idle: Image("MenuBarIcon")
            case .starting: Image("MenuBarIconStarting")
            case .recording: Image("MenuBarIconRecording")
            }
        }

        Window("Transcript", id: MenuContent.transcriptWindow) {
            TranscriptView()
                .environment(delegate.model)
                .showsAppInDock()
                .focusedWhenOpened(as: MenuContent.transcriptWindow)
        }
        .defaultSize(width: 560, height: 480)
        // ⌘P opens People: not in the menu bar icon's menu, only in the app's own menus, while one of its windows is in
        // front; in the place of Print, which the app has nothing for.
        .commands {
            CommandGroup(replacing: .printItem) { PeopleMenuItem() }
        }

        // The people Identify Speakers remembers, opened from the transcript.
        Window("People", id: MenuContent.peopleWindow) {
            PeopleView()
                .environment(delegate.model)
                .frame(width: 540)
                .showsAppInDock()
                .focusedWhenOpened(as: MenuContent.peopleWindow)
        }
        .windowResizability(.contentSize)

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
        HiddenPeopleItem.start()
        // The menu bar icon's window is made as the app finishes launching; it is there on the next turn of the run loop.
        DispatchQueue.main.async { MenuBarIconSharing.apply() }
        NotificationCenter.default.addObserver(forName: SettingsFile.didChange, object: nil, queue: .main) {
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

/// People…, ⌘P, in the app's own menus.
private struct PeopleMenuItem: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("People…") {
            openWindow(id: MenuContent.peopleWindow)
            WindowFocus.bringToFront(MenuContent.peopleWindow)
        }
        .keyboardShortcut("p")
    }
}
