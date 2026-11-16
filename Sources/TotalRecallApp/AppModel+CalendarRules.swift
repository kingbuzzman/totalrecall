import AppSupport

/// Changing a calendar's rules from the menu.
extension AppModel {
    /// Leaves out from now on every meeting of the same title on the same calendar: its title, without what is in
    /// parentheses or brackets, becomes one of the calendar's ignored phrases.
    func alwaysIgnore(_ meeting: ScheduledMeeting) {
        var rules = AppSettings.calendarRules
        let calendar = calendar.calendars.first { $0.id == meeting.calendarID }
        var calendarRules =
            rules[meeting.calendarID] ?? calendar.map(AppSettings.rules(for:)) ?? CalendarRules()
        calendarRules.ignore(meeting.shortTitle)
        rules[meeting.calendarID] = calendarRules
        AppSettings.calendarRules = rules
        readCalendar()
    }
}
