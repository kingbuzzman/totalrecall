package import Foundation

/// A meeting to record. The same meeting on two calendars is one meeting: the calendar only says where its recording
/// goes, so it is left out of equality.
package struct ScheduledMeeting: Hashable, Sendable {
    package let title: String
    package let start: Date
    package let end: Date
    package let calendar: String
    /// The identifier of that calendar, whose rules it goes by.
    package let calendarID: String

    package init(title: String, start: Date, end: Date, calendar: String, calendarID: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.calendar = calendar
        self.calendarID = calendarID ?? calendar
    }

    package static func == (a: Self, b: Self) -> Bool {
        (a.title, a.start, a.end) == (b.title, b.start, b.end)
    }

    package func hash(into hasher: inout Hasher) {
        hasher.combine(title)
        hasher.combine(start)
        hasher.combine(end)
    }

    /// The folder its recordings go in: under its calendar, by when it was meant to start, so restarting it records
    /// into the same folder.
    package func directory(root: URL, timeZone: TimeZone = .current) -> URL {
        RecordingFolder.directory(root: root, calendar: calendar, name: title, start: start, timeZone: timeZone)
    }

    /// A meeting added to the calendar from the menu, `title`, starting at `now` and lasting until stopped: on whole
    /// minutes, as calendars keep them, so that the event read back is the same meeting; to begin with, `minutes` long.
    package static func startingNow(
        _ title: String,
        now: Date,
        minutes: Int,
        calendar: String,
        calendarID: String
    ) -> ScheduledMeeting {
        let start = minute(of: now, roundingUp: false)
        return ScheduledMeeting(
            title: title,
            start: start,
            end: start.addingTimeInterval(Double(max(1, minutes)) * 60),
            calendar: calendar,
            calendarID: calendarID
        )
    }

    /// The meeting, stopped at `now`: ending at the end of that minute, and lasting a minute at least.
    package func stopped(at now: Date) -> ScheduledMeeting {
        let end = max(Self.minute(of: now, roundingUp: true), start.addingTimeInterval(60))
        return ScheduledMeeting(title: title, start: start, end: end, calendar: calendar, calendarID: calendarID)
    }

    /// The start of the minute `date` is in, or of the next one when rounding up and it is not on a minute already.
    /// Minutes since the reference date fall on the clock's minutes, as every time zone is whole minutes off UTC.
    private static func minute(of date: Date, roundingUp: Bool) -> Date {
        let minutes = date.timeIntervalSinceReferenceDate / 60
        return Date(timeIntervalSinceReferenceDate: (roundingUp ? minutes.rounded(.up) : minutes.rounded(.down)) * 60)
    }

    /// The title without whatever is in parentheses or brackets: "Standup (webcam ON)" -> "Standup".
    package var shortTitle: String {
        let title = RecordingFolder.unbracketed(title).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? self.title : title
    }
}
