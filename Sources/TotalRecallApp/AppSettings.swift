import AppSupport
import Foundation

/// The settings, kept in the app's user defaults; Settings changes them through `@AppStorage` with the same keys.
enum AppSettings {
    enum Key {
        static let recordingsFolder = "recordingsFolder"
        static let format = "audioFormat"
        static let microphone = "microphone"
        static let language = "language"
        static let identifiesSpeakers = "identifiesSpeakers"
    }

    /// Where the recordings go, as `record-meetings` puts them: ~/Meetings unless changed.
    static let defaultRecordingsFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Meetings")
        .path

    static var recordingsFolder: URL {
        URL(filePath: UserDefaults.standard.string(forKey: Key.recordingsFolder) ?? defaultRecordingsFolder)
    }

    static var format: AudioFormatChoice {
        UserDefaults.standard.string(forKey: Key.format).flatMap(AudioFormatChoice.init) ?? .default
    }

    /// Part of the name of a microphone to prefer whenever it is connected; nil for the system input.
    static var microphone: String? {
        UserDefaults.standard.string(forKey: Key.microphone).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The language spoken, such as es or es-MX; nil for transcribe's default, en-US.
    static var language: String? {
        UserDefaults.standard.string(forKey: Key.language).flatMap {
            let language = $0.trimmingCharacters(in: .whitespaces)
            return language.isEmpty ? nil : language
        }
    }

    static var identifiesSpeakers: Bool {
        UserDefaults.standard.bool(forKey: Key.identifiesSpeakers)
    }
}
