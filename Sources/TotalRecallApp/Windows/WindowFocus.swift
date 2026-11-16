import AppKit
import SwiftUI

/// Brings the app's windows to the front, and remembers where they were. A menu bar app's window opens behind the
/// others: the app only becomes one that can be in front (see `DockPresence`) as the window appears, after SwiftUI has
/// already tried. So each window is kept track of by name, and brought forward once it is in place, and again whenever
/// the menu asks for it. Where each was is kept in the app's settings, rather than where AppKit keeps it, in
/// ~/Library/Preferences.
@MainActor
enum WindowFocus {
    private static var windows: [String: WeakWindow] = [:]
    private static var frameObservers: [String: [any NSObjectProtocol]] = [:]

    /// Brings the window named `name` to the front and gives it the keyboard, if it is open.
    static func bringToFront(_ name: String) {
        // On the next turn of the run loop, after the window has been shown and the app made a regular one.
        DispatchQueue.main.async {
            guard let window = windows[name]?.window, window.isVisible else { return }
            NSApp.activate()
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }

    fileprivate static func register(_ window: NSWindow, as name: String) {
        if windows[name]?.window !== window { rememberFrame(of: window, as: name) }
        windows[name] = WeakWindow(window: window)
        bringToFront(name)
    }

    /// Puts the window where it was last, and saves where it is whenever it moves or changes size.
    private static func rememberFrame(of window: NSWindow, as name: String) {
        let key = "windowFrame.\(name)"
        window.setFrameAutosaveName("")
        if let frame = AppSettings.file[key] as? String { window.setFrame(from: frame) }
        frameObservers[name]?.forEach(NotificationCenter.default.removeObserver)
        frameObservers[name] = [NSWindow.didMoveNotification, NSWindow.didEndLiveResizeNotification].map { change in
            NotificationCenter.default.addObserver(forName: change, object: window, queue: .main) { [weak window] _ in
                MainActor.assumeIsolated {
                    if let window { AppSettings.file[key] = window.frameDescriptor }
                }
            }
        }
    }

    private struct WeakWindow {
        weak var window: NSWindow?
    }
}

extension View {
    /// Keeps track of the window this view is in as `name`, and brings it to the front when it opens.
    func focusedWhenOpened(as name: String) -> some View {
        background(WindowGrabber(name: name))
    }
}

/// Hands the window it is placed in to `WindowFocus`, once it is in one.
private struct WindowGrabber: NSViewRepresentable {
    let name: String

    func makeNSView(context: Context) -> GrabberView {
        GrabberView(name: name)
    }

    func updateNSView(_ view: GrabberView, context: Context) {}

    final class GrabberView: NSView {
        private let name: String

        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MainActor.assumeIsolated { WindowFocus.register(window, as: name) } }
        }
    }
}
