package import Foundation

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
        for event in events where event.isTimed {
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
        events.filter { $0.isTimed && CalendarRules.matches($0.title, phrase: phrase) }
            .sorted { ($0.start, $0.title) < ($1.start, $1.title) }
    }

    /// The day `now` is in, midnight to midnight as `calendar` has it: what "today's meetings" are read from, again
    /// every minute, so a new day's come once it starts. Not always 24 hours: a day the clocks change is 23 or 25.
    package static func day(containing now: Date, calendar: Calendar = .current) -> DateInterval {
        calendar.dateInterval(of: .day, for: now)
            ?? DateInterval(start: calendar.startOfDay(for: now), duration: 86_400)
    }
}
