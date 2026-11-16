import AppKit
import Shared
import SwiftUI
import os

/// Keeps the menu bar icon out of screenshots and screen sharing, as `hiddenFromCapture` does a window. The icon is
/// drawn in a window of its own, one AppKit keeps for each status item; SwiftUI's `MenuBarExtra` does not hand it over,
/// so it is found among the app's windows by its class.
@MainActor
enum MenuBarIconSharing {
    private static let log = Log.app

    static func apply() {
        let hides = AppSettings.hidesMenuBarIconFromCapture
        let icons = NSApp.windows.filter { String(describing: type(of: $0)).contains("StatusBarWindow") }
        for window in icons {
            window.sharingType = hides ? .none : .readOnly
        }
        let classes = NSApp.windows.map { String(describing: type(of: $0)) }.joined(separator: ", ")
        log.debug("menu bar icon windows: \(icons.count, privacy: .public) of \(classes, privacy: .public)")
    }
}

extension View {
    /// Keeps the window this view is in out of screenshots and screen sharing, while `isHidden`, by asking macOS not to
    /// share its contents (`NSWindow.sharingType`). Tools that capture through ScreenCaptureKit may not honor it on
    /// recent macOS; then the window shows, as it would anyway.
    func hiddenFromCapture(_ isHidden: Bool) -> some View {
        background(WindowSharing(hidesWindow: isHidden))
    }
}

/// Sets the sharing of the window it is placed in, once it is in one.
private struct WindowSharing: NSViewRepresentable {
    let hidesWindow: Bool

    func makeNSView(context: Context) -> SharingView {
        SharingView()
    }

    func updateNSView(_ view: SharingView, context: Context) {
        view.hidesWindow = hidesWindow
    }

    final class SharingView: NSView {
        var hidesWindow = false {
            didSet { apply() }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        private func apply() {
            window?.sharingType = hidesWindow ? .none : .readOnly
        }
    }
}
