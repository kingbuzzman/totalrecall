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
        static let recordsAutomatically = "recordsAutomatically"
        static let warningMinutes = "warningMinutes"
        static let calendarRules = "calendarRules"
        static let defaultMeetingCalendar = "defaultMeetingCalendar"
        static let addsNewMeetingsToCalendar = "addsNewMeetingsToCalendar"
        static let lastMeetingName = "lastMeetingName"
        static let newMeetingMinutes = "newMeetingMinutes"
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
        UserDefaults.standard.object(forKey: Key.warningMinutes) == nil
            ? defaultWarningMinutes : UserDefaults.standard.integer(forKey: Key.warningMinutes)
    }

    /// What to record from each calendar set up in Settings, by calendar identifier. A calendar not set up goes by
    /// `CalendarRules.defaults`, so one added later is recorded too.
    static var calendarRules: [String: CalendarRules] {
        get { CalendarRules.decode(UserDefaults.standard.data(forKey: Key.calendarRules)) }
        set { UserDefaults.standard.set(CalendarRules.encode(newValue), forKey: Key.calendarRules) }
    }

    /// The identifier of the calendar a meeting started from the menu is filed under, as chosen in Settings; nil when
    /// none was chosen.
    static var defaultMeetingCalendar: String? {
        UserDefaults.standard.string(forKey: Key.defaultMeetingCalendar).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// How long the event New Meeting adds lasts until the meeting is stopped, when its end moves to then; 30 minutes
    /// unless changed.
    static let defaultNewMeetingMinutes = 30
    static let newMeetingLengths = [15, 30, 45, 60, 90, 120]
    static var newMeetingMinutes: Int {
        let minutes = UserDefaults.standard.integer(forKey: Key.newMeetingMinutes)
        return minutes > 0 ? minutes : defaultNewMeetingMinutes
    }

    /// The name last given to New Meeting, which it suggests next time, to be changed or kept.
    static var lastMeetingName: String {
        get { UserDefaults.standard.string(forKey: Key.lastMeetingName) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: Key.lastMeetingName) }
    }

    /// Whether New Meeting adds the meeting to its calendar, as an event lasting as long as it is recorded; on unless
    /// turned off.
    static var addsNewMeetingsToCalendar: Bool {
        flag(Key.addsNewMeetingsToCalendar, unset: true)
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

    /// A setting that is on or off, or `unset` when never set. Read with `bool(forKey:)`, which also takes the text a
    /// launch argument gives, such as `-recordsAutomatically NO`, where a cast to Bool would take it for unset.
    private static func flag(_ key: String, unset: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil ? unset : UserDefaults.standard.bool(forKey: key)
    }
}
