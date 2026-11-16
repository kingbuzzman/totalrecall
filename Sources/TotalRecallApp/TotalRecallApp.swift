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
            Image(delegate.model.isRecording ? "MenuBarIconRecording" : "MenuBarIcon")
        }

        Window("Transcript", id: MenuContent.transcriptWindow) {
            TranscriptView()
                .environment(delegate.model)
                .showsAppInDock()
                .focusedWhenOpened(as: MenuContent.transcriptWindow)
        }
        .defaultSize(width: 560, height: 480)

        // A window of its own rather than SwiftUI's Settings scene, which keeps its position and tab in
        // ~/Library/Preferences whatever is done to it; this one's position goes in the app's own settings.
        Window("Settings", id: MenuContent.settingsWindow) {
            SettingsView()
                .environment(delegate.model)
                .showsAppInDock()
                .focusedWhenOpened(as: MenuContent.settingsWindow)
        }
        .windowResizability(.contentSize)
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
