import AppKit
import SwiftUI

/// ⌘P for People while the menu under the menu bar icon is open, without an item for it in sight: SwiftUI's menu has
/// no hidden items, so a hidden AppKit one, which still takes its key, is added to the menu each time it opens.
@MainActor
enum HiddenPeopleItem {
    /// Opens People; set by the menu, which has SwiftUI's `openWindow` to do it with.
    static var openPeople: (() -> Void)?

    private static let tag = 0x7065_6f70  // "peop"
    private static let target = Target()
    private static var observer: (any NSObjectProtocol)?

    /// Adds the item to the menu bar icon's menu whenever it opens.
    static func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSMenu.didBeginTrackingNotification,
            object: nil,
            queue: nil
        ) { notification in
            nonisolated(unsafe) let menu = notification.object as? NSMenu  // posted on the main thread, used there
            MainActor.assumeIsolated { if let menu { add(to: menu) } }
        }
    }

    /// Only to the menu bar icon's menu, the one with Quit in it, and only once.
    private static func add(to menu: NSMenu) {
        guard menu.items.contains(where: { $0.title == "Quit" }), menu.item(withTag: tag) == nil else { return }
        let item = NSMenuItem(title: "People…", action: #selector(Target.openPeople), keyEquivalent: "p")
        item.keyEquivalentModifierMask = .command
        item.target = target
        item.tag = tag
        item.isHidden = true
        item.allowsKeyEquivalentWhenHidden = true
        menu.addItem(item)
    }

    private final class Target: NSObject {
        @MainActor @objc func openPeople() {
            HiddenPeopleItem.openPeople?()
        }
    }
}
