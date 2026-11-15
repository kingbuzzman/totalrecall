import AppKit
import SwiftUI

/// Puts the app in the Dock and the Cmd-Tab switcher while one of its windows is open, so it can be found like any
/// other app's; with none open, it lives in the menu bar only.
@MainActor
enum DockPresence {
    private static var openWindows = 0

    static func windowOpened() {
        openWindows += 1
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    static func windowClosed() {
        openWindows = max(0, openWindows - 1)
        if openWindows == 0 { NSApp.setActivationPolicy(.accessory) }
    }
}

extension View {
    /// Keeps the app in the Dock for as long as this window is open.
    func showsAppInDock() -> some View {
        onAppear { DockPresence.windowOpened() }
            .onDisappear { DockPresence.windowClosed() }
    }
}
