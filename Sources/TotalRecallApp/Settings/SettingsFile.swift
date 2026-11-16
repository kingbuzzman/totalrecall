import Foundation
import Observation
import os

/// Settings kept in a property list file of their own, read when the app starts and written whole, as plain XML, on
/// every change. Not user defaults: they keep an app's settings in ~/Library/Preferences, and drop writes to a file
/// anywhere else. A view that reads a setting is redrawn when it changes; anything else hears of changes through
/// `didChange`.
@Observable
final class SettingsFile: @unchecked Sendable {
    static let didChange = Notification.Name("local.totalrecall.app.settingsDidChange")

    @ObservationIgnored private let url: URL
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private let log = Logger(subsystem: "local.totalrecall.app", category: "settings")
    private var values: [String: Any]

    init(url: URL) {
        self.url = url
        let saved = try? PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil)
        values = saved as? [String: Any] ?? [:]
    }

    /// The setting `key`, as a property list value; nil when unset. Setting it saves the file.
    subscript(key: String) -> Any? {
        get { lock.withLock { values[key] } }
        set {
            let all = lock.withLock {
                values[key] = newValue
                return values
            }
            save(all)
            NotificationCenter.default.post(name: Self.didChange, object: self)
        }
    }

    private func save(_ all: [String: Any]) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let data = try PropertyListSerialization.data(fromPropertyList: all, format: .xml, options: 0)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("cannot save \(self.url.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
