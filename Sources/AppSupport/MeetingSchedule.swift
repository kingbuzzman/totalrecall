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
}

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
        let title = title.replacing(/\([^)]*\)|\[[^\]]*\]/, with: " ").trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? self.title : title
    }
}

/// Which meetings to record, and when to warn of them, as `scripts/record-meetings` decides.
package enum MeetingSchedule {
    /// Focus time and blocks to prepare for a meeting are not meetings.
    package static func isSkipped(title: String) -> Bool {
        title.contains(/(?i)focus\s*time|\bprep(are|ared|aring|aration)?\b/)
    }

    /// The meetings among `events`: all-day events and events without a length are left out, and so is what the
    /// rules of the calendar an event is on leave out (by default, focus time and prep blocks); a meeting on more than
    /// one calendar is kept once, on the first calendar it comes on where it is not left out. In order of start, then
    /// end, then title.
    package static func meetings(
        from events: [CalendarEvent],
        rules: (_ calendarID: String) -> CalendarRules = { _ in CalendarRules() }
    ) -> [ScheduledMeeting] {
        var meetings: [ScheduledMeeting] = []
        var seen: Set<ScheduledMeeting> = []
        for event in events where !event.isAllDay && event.end > event.start {
            let calendarRules = rules(event.calendarID)
            guard calendarRules.isRecorded, !calendarRules.ignores(title: event.title) else { continue }
            let title = event.title.trimmingCharacters(in: .whitespaces)
            let meeting = ScheduledMeeting(
                title: title,
                start: event.start,
                end: event.end,
                calendar: event.calendar,
                calendarID: event.calendarID
            )
            if seen.insert(meeting).inserted { meetings.append(meeting) }
        }
        return meetings.sorted { ($0.start, $0.end, $0.title) < ($1.start, $1.end, $1.title) }
    }

    /// The next meeting to record: the first not in `done` that has not ended yet, which may already be underway.
    package static func next(
        in meetings: [ScheduledMeeting],
        excluding done: Set<ScheduledMeeting>,
        now: Date
    )
        -> ScheduledMeeting?
    {
        meetings.first { !done.contains($0) && $0.end > now }
    }

    /// The meetings to warn of now: those starting within `lead`, not yet started, and not in `excluding`. One already
    /// less than `lead` away when the app starts still gets its warning. None when `lead` is 0.
    package static func warningsDue(
        in meetings: [ScheduledMeeting],
        lead: TimeInterval,
        excluding warned: Set<ScheduledMeeting>,
        now: Date
    ) -> [ScheduledMeeting] {
        guard lead > 0 else { return [] }
        return meetings.filter { !warned.contains($0) && $0.start.addingTimeInterval(-lead) <= now && now < $0.start }
    }

    /// "Standup in 5 minutes", for a warning at `now`: whole minutes, rounding half to even, at least 1.
    package static func warning(for meeting: ScheduledMeeting, now: Date) -> String {
        let minutes = max(1, Int((meeting.start.timeIntervalSince(now) / 60).rounded(.toNearestOrEven)))
        return "\(meeting.shortTitle) in \(minutes) minute\(minutes == 1 ? "" : "s")"
    }

    /// The weeks a rule is tried on, to see what it would ignore: from the start of the week two weeks before the one
    /// `now` is in to the end of the week two weeks after it, five weeks in all, as `calendar` begins its weeks.
    package static func ruleTestInterval(around now: Date, calendar: Calendar = .current) -> DateInterval {
        let thisWeek =
            calendar.dateInterval(of: .weekOfYear, for: now) ?? DateInterval(start: now, duration: 7 * 86_400)
        let start = calendar.date(byAdding: .weekOfYear, value: -2, to: thisWeek.start) ?? thisWeek.start
        let end = calendar.date(byAdding: .weekOfYear, value: 2, to: thisWeek.end) ?? thisWeek.end
        return DateInterval(start: start, end: end)
    }

    /// The meetings among `events` that `phrase` would leave out, in order: those with a length, not all-day, whose
    /// title contains it, or matches it for a regular expression.
    package static func meetings(matching phrase: String, in events: [CalendarEvent]) -> [CalendarEvent] {
        events.filter { !$0.isAllDay && $0.end > $0.start && CalendarRules.matches($0.title, phrase: phrase) }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// The day `now` is in, midnight to midnight as `calendar` has it: what "today's meetings" are read from, again
    /// every minute, so a new day's come once it starts. Not always 24 hours: a day the clocks change is 23 or 25.
    package static func day(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
    }
}
