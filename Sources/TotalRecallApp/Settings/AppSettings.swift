import AppSupport
import Foundation
import Shared

/// The settings, kept in ~/Library/Application Support/TotalRecall/Settings.plist, beside the people the app remembers;
/// Settings changes them through `@Setting` with the same keys.
enum AppSettings {
    /// Where the app keeps what it keeps: its settings, and the people it remembers.
    static let folder = URL.applicationSupportDirectory.appending(path: "TotalRecall")

    /// The people Identify Speakers remembers: the app's own, apart from those `transcribe` remembers.
    static let speakers = folder.appending(path: "speakers.db")

    static let file = SettingsFile(url: folder.appending(path: "Settings.plist"))

    enum Key {
        static let recordingsFolder = "recordingsFolder"
        static let format = "audioFormat"
        static let microphone = "microphone"
        static let language = "language"
        static let identifiesSpeakers = "identifiesSpeakers"
        static let recordsAutomatically = "recordsAutomatically"
        static let warningMinutes = "warningMinutes"
        static let calendarRules = "calendarRules"
        static let defaultMeetingCalendar = "defaultMeetingCalendar"
        static let lastMeetingName = "lastMeetingName"
        static let newMeetingMinutes = "newMeetingMinutes"
        static let trashesAudioOnceTranscribed = "trashesAudioOnceTranscribed"
        static let hidesTranscriptFromCapture = "hidesTranscriptFromCapture"
        static let hidesMenuBarIconFromCapture = "hidesMenuBarIconFromCapture"
    }

    /// Whether the menu bar icon, red dot and all, is kept out of screenshots and screen sharing; on unless turned off.
    static var hidesMenuBarIconFromCapture: Bool {
        flag(Key.hidesMenuBarIconFromCapture, unset: true)
    }

    /// Whether meetings on the calendar are recorded when they start; on unless turned off.
    static var recordsAutomatically: Bool {
        flag(Key.recordsAutomatically, unset: true)
    }

    /// How many minutes before each meeting to warn of it, as `record-meetings --warn` does; 5 unless changed, 0 for
    /// no warnings.
    static let defaultWarningMinutes = 5
    static var warningMinutes: Int {
        file[Key.warningMinutes] as? Int ?? defaultWarningMinutes
    }

    /// What to record from each calendar set up in Settings, by calendar identifier. A calendar not set up goes by
    /// `CalendarRules.defaults`, so one added later is recorded too.
    static var calendarRules: [String: CalendarRules] {
        get { CalendarRules.decode(file[Key.calendarRules]) }
        set { file[Key.calendarRules] = CalendarRules.encode(newValue) }
    }

    /// The identifier of the calendar a meeting started from the menu is filed under, as chosen in Settings; nil when
    /// none was chosen.
    static var defaultMeetingCalendar: String? {
        (file[Key.defaultMeetingCalendar] as? String)?.nonEmpty
    }

    /// How long the event New Meeting adds lasts until the meeting is stopped, when its end moves to then; 30 minutes
    /// unless changed.
    static let defaultNewMeetingMinutes = 30
    static let newMeetingLengths = [15, 30, 45, 60, 90, 120]
    static var newMeetingMinutes: Int {
        let minutes = file[Key.newMeetingMinutes] as? Int ?? 0
        return minutes > 0 ? minutes : defaultNewMeetingMinutes
    }

    /// The name last given to New Meeting, which it suggests next time, to be changed or kept.
    static var lastMeetingName: String {
        get { file[Key.lastMeetingName] as? String ?? "" }
        set { file[Key.lastMeetingName] = newValue }
    }

    /// The rules of `calendar`: as set up, or its defaults; a read-only calendar is never recorded, whatever was set.
    static func rules(for calendar: CalendarSource.Calendar) -> CalendarRules {
        rules(for: calendar, in: calendarRules)
    }

    /// The rules of `calendar` among `rules`, as `rules(for:)` gives them.
    static func rules(for calendar: CalendarSource.Calendar, in rules: [String: CalendarRules]) -> CalendarRules {
        var calendarRules = rules[calendar.id] ?? CalendarRules.defaults(isMeetingCalendar: calendar.isMeetingCalendar)
        if calendar.isReadOnly { calendarRules.isRecorded = false }
        return calendarRules
    }

    /// Where the recordings go, as `record-meetings` puts them: ~/Meetings unless changed.
    static let defaultRecordingsFolder = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Meetings")
        .path

    static var recordingsFolder: URL {
        URL(filePath: file[Key.recordingsFolder] as? String ?? defaultRecordingsFolder)
    }

    static var format: AudioFormatChoice {
        (file[Key.format] as? String).flatMap(AudioFormatChoice.init) ?? .default
    }

    /// Part of the name of a microphone to prefer whenever it is connected; nil for the system input.
    static var microphone: String? {
        (file[Key.microphone] as? String)?.nonEmpty
    }

    /// The language spoken, such as es or es-MX; nil for transcribe's default, en-US.
    static var language: String? {
        (file[Key.language] as? String)?.trimmingCharacters(in: .whitespaces).nonEmpty
    }

    /// Whether a recording goes to the Trash once saved and transcribed, keeping only the transcript; on unless turned
    /// off.
    static var trashesAudioOnceTranscribed: Bool {
        flag(Key.trashesAudioOnceTranscribed, unset: true)
    }

    static var identifiesSpeakers: Bool {
        flag(Key.identifiesSpeakers, unset: false)
    }

    /// A setting that is on or off, or `unset` when never set.
    private static func flag(_ key: String, unset: Bool) -> Bool {
        file[key] as? Bool ?? unset
    }
}
