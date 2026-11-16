/// The calendar a meeting started from the menu, rather than from the calendar, is filed under.
package enum MeetingCalendar {
    /// `chosen`, the calendar chosen in Settings, while it is still one of the `recorded` calendars; otherwise the
    /// first of them, as when nothing was chosen, or the calendar chosen was turned off or removed; nil when no
    /// calendar is recorded.
    package static func resolve(chosen: String?, recorded: [String]) -> String? {
        if let chosen, recorded.contains(chosen) { return chosen }
        return recorded.first
    }
}
