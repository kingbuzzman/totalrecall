import AppKit
import Foundation
import UserNotifications

/// Banners for what happens while the app sits in the menu bar: a recording starting, being saved, or failing. Clicking
/// one about a saved file shows it in Finder.
final class Notifier: NSObject, UNUserNotificationCenterDelegate, Sendable {
    private static let revealKey = "reveal"

    /// Notifications need an app bundle; run bare, such as with swift run, it posts nothing.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    func requestPermission() {
        guard let center else { return }
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(title: String, body: String, revealing url: URL? = nil) {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let url { content.userInfo = [Self.revealKey: url.path] }
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
        guard let path = response.notification.request.content.userInfo[Self.revealKey] as? String else { return }
        await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
    }
}
