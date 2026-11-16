package import Foundation

/// An event from the calendar, as the app reads it from Calendar.app.
package struct CalendarEvent: Sendable {
    package let title: String
    package let start: Date
    package let end: Date
    /// The calendar it is on: its title, such as an account's address for a Google calendar, and its identifier,
    /// which tells apart calendars of the same title.
    package let calendar: String
    package let calendarID: String
    package let isAllDay: Bool

    package init(
        title: String,
        start: Date,
        end: Date,
        calendar: String,
        calendarID: String? = nil,
        isAllDay: Bool = false
    ) {
        self.title = title
        self.start = start
        self.end = end
        self.calendar = calendar
        self.calendarID = calendarID ?? calendar
        self.isAllDay = isAllDay
    }

    /// Whether it is a meeting's kind of event: not all-day, and with a length.
    var isTimed: Bool { !isAllDay && end > start }
}
