package import Foundation

/// What to record from one calendar: whether to record its meetings at all, and which of them to leave out, by their
/// titles. Kept per calendar, by the calendar's identifier, not its title: two accounts can each have a calendar of the
/// same name, such as "Holidays in United States", and each has rules of its own.
package struct CalendarRules: Codable, Equatable, Sendable {
    /// Whether this calendar's meetings are warned of and recorded.
    package var isRecorded: Bool
    /// Whether focus time and blocks to prepare for a meeting are left out, as `record-meetings` leaves them out.
    package var skipsFocusAndPrep: Bool
    /// Meetings whose title contains any of these, ignoring case, are left out. One between slashes, such as
    /// `/^1:1|standup$/`, is a regular expression the title is matched against, also ignoring case.
    package var ignoredPhrases: [String]

    package init(isRecorded: Bool = true, skipsFocusAndPrep: Bool = true, ignoredPhrases: [String] = []) {
        self.isRecorded = isRecorded
        self.skipsFocusAndPrep = skipsFocusAndPrep
        self.ignoredPhrases = ignoredPhrases
    }

    /// The rules of a calendar never set up: its meetings recorded, focus time and prep blocks left out; unless it is
    /// a calendar of holidays, birthdays or another subscription, whose events are all-day ones, not meetings.
    package static func defaults(isMeetingCalendar: Bool) -> CalendarRules {
        CalendarRules(isRecorded: isMeetingCalendar)
    }

    /// Whether a meeting titled `title` on this calendar is left out.
    package func ignores(title: String) -> Bool {
        if skipsFocusAndPrep && MeetingSchedule.isSkipped(title: title) { return true }
        return ignoredPhrases.contains { Self.matches(title, phrase: $0) }
    }

    /// Adds `phrase` to those left out, unless it is empty, already there, ignoring case, or a regular expression that
    /// does not compile. Returns whether it was added.
    @discardableResult
    package mutating func ignore(_ phrase: String) -> Bool {
        let phrase = phrase.trimmingCharacters(in: .whitespaces)
        guard !phrase.isEmpty, Self.problem(with: phrase) == nil,
            !ignoredPhrases.contains(where: { $0.caseInsensitiveCompare(phrase) == .orderedSame })
        else { return false }
        ignoredPhrases.append(phrase)
        return true
    }

    /// The regular expression a phrase between slashes stands for, such as `^1:1` for `/^1:1/`; nil for a plain
    /// phrase.
    package static func pattern(of phrase: String) -> String? {
        let phrase = phrase.trimmingCharacters(in: .whitespaces)
        guard phrase.count >= 2, phrase.hasPrefix("/"), phrase.hasSuffix("/") else { return nil }
        return String(phrase.dropFirst().dropLast())
    }

    /// What is wrong with a phrase: a regular expression that is empty or does not compile; nil when nothing is.
    package static func problem(with phrase: String) -> String? {
        guard let pattern = pattern(of: phrase) else { return nil }
        guard !pattern.isEmpty else { return "The regular expression is empty." }
        do {
            _ = try Regex(pattern)
            return nil
        } catch {
            return "Not a regular expression: \(error.localizedDescription)"
        }
    }

    /// Whether `title` contains `phrase`, or matches it, for a regular expression; ignoring case either way. A
    /// regular expression that does not compile matches nothing.
    package static func matches(_ title: String, phrase: String) -> Bool {
        if let pattern = pattern(of: phrase) {
            guard !pattern.isEmpty, let regex = try? Regex(pattern) else { return false }
            return title.contains(regex.ignoresCase())
        }
        let phrase = phrase.trimmingCharacters(in: .whitespaces)
        return !phrase.isEmpty && title.localizedCaseInsensitiveContains(phrase)
    }

    /// Every calendar's rules, by calendar identifier, as they are saved; none from data that is not theirs.
    package static func decode(_ data: Data?) -> [String: CalendarRules] {
        data.flatMap { try? JSONDecoder().decode([String: CalendarRules].self, from: $0) } ?? [:]
    }

    package static func encode(_ rules: [String: CalendarRules]) -> Data {
        (try? JSONEncoder().encode(rules)) ?? Data()
    }
}
