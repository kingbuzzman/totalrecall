import AppKit
import Foundation
import UserNotifications
import os

/// Banners for what happens while the app sits in the menu bar: a meeting about to start, a recording starting, being
/// saved, or failing. Clicking one about a file shows it in Finder; some have buttons, such as Record Now on a
/// meeting about to start, which `onAction` carries out.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    /// The buttons a notification can have.
    enum Action: String, CaseIterable {
        case recordNow, skip, stopRecording, tryAgain, openTranscript, restoreRecording

        var title: String {
            switch self {
            case .recordNow: "Record Now"
            case .skip: "Skip"
            case .stopRecording: "Stop Recording"
            case .tryAgain: "Try Again"
            case .openTranscript: "Open Transcript"
            case .restoreRecording: "Restore Recording"
            }
        }
    }

    /// The kinds of notification with buttons, and their buttons.
    enum Kind: String, CaseIterable {
        /// A meeting about to start.
        case meeting
        /// A recording that started.
        case recording
        case failedToRecord
        /// A recording that went to the Trash once transcribed.
        case trashed

        var actions: [Action] {
            switch self {
            case .meeting: [.recordNow, .skip]
            case .recording: [.stopRecording]
            case .failedToRecord: [.tryAgain]
            case .trashed: [.openTranscript, .restoreRecording]
            }
        }
    }

    private static let revealKey = "reveal"

    /// Called on the main actor with the button clicked, and the information its notification was posted with.
    private let handler = OSAllocatedUnfairLock<(@MainActor @Sendable (Action, [String: String]) -> Void)?>(
        initialState: nil
    )

    /// Notifications need an app bundle; run bare, such as with swift run, it posts nothing.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func onAction(_ handle: @escaping @MainActor @Sendable (Action, [String: String]) -> Void) {
        handler.withLock { $0 = handle }
    }

    func requestPermission() {
        guard let center else { return }
        center.delegate = self
        center.setNotificationCategories(
            Set(
                Kind.allCases.map { kind in
                    UNNotificationCategory(
                        identifier: kind.rawValue,
                        actions: kind.actions.map { UNNotificationAction(identifier: $0.rawValue, title: $0.title) },
                        intentIdentifiers: []
                    )
                }
            )
        )
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Posts a notification; of `kind`, for its buttons, with `info` for what they act on; clicking it shows the file
    /// at `url`, if any, in Finder.
    func post(
        title: String,
        body: String,
        kind: Kind? = nil,
        info: [String: String] = [:],
        revealing url: URL? = nil
    ) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.categoryIdentifier = kind?.rawValue ?? ""
        var info = info
        info[Self.revealKey] = url?.path
        content.userInfo = info
        center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Shows banners even while the app is the active one, such as with Settings open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo.reduce(into: [String: String]()) { info, entry in
            if let key = entry.key as? String, let value = entry.value as? String { info[key] = value }
        }
        if let action = Action(rawValue: response.actionIdentifier) {
            let handle = handler.withLock { $0 }
            await MainActor.run { handle?(action, info) }
        } else if response.actionIdentifier == UNNotificationDefaultActionIdentifier, let path = info[Self.revealKey] {
            await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
        }
    }
}
