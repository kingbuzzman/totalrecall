import Foundation
import Testing

@testable import AppSupport

/// The schedule must decide as `scripts/record-meetings` does; the expected values are what the script makes of the same
/// input.
struct MeetingScheduleTests {
    private static let utc = TimeZone(identifier: "UTC")!

    @Test(arguments: [
        ("Focus Time", true), ("focustime block", true), ("Prep for review", true), ("Preparation", true),
        ("Prepared remarks", true), ("Preparing", true), ("Team prep", true), ("Repreparation", false),
        ("Prepping", false), ("Represent", false), ("Daily Standup", false),
    ])
    func skipsFocusTimeAndPrepBlocks(title: String, skipped: Bool) {
        #expect(MeetingSchedule.isSkipped(title: title) == skipped)
    }

    @Test func keepsMeetingsInOrderLeavingOutAllDayEventsAndOnesWithoutALength() {
        let events = [
            CalendarEvent(title: "Retro", start: at(14, 0), end: at(15, 0), calendar: "work"),
            CalendarEvent(title: "Holiday", start: at(0, 0), end: at(23, 59), calendar: "work", isAllDay: true),
            CalendarEvent(title: "Standup", start: at(10, 0), end: at(10, 15), calendar: "work"),
            CalendarEvent(title: "Reminder", start: at(11, 0), end: at(11, 0), calendar: "work"),
            CalendarEvent(title: "Focus Time", start: at(12, 0), end: at(13, 0), calendar: "work"),
            CalendarEvent(title: "Planning", start: at(10, 0), end: at(11, 0), calendar: "work"),
        ]

        let meetings = MeetingSchedule.meetings(from: events)

        #expect(meetings.map(\.title) == ["Standup", "Planning", "Retro"])
    }

    @Test func keepsAMeetingOnTwoCalendarsOnceOnTheFirst() {
        let events = [
            CalendarEvent(title: "Standup", start: at(10, 0), end: at(10, 15), calendar: "work@example.com"),
            CalendarEvent(title: "Standup", start: at(10, 0), end: at(10, 15), calendar: "Home"),
        ]

        let meetings = MeetingSchedule.meetings(from: events)

        #expect(meetings.count == 1)
        #expect(meetings.first?.calendar == "work@example.com")
    }

    @Test(arguments: [
        ("someone@example.com", "/r/someone@example.com/47-2026/11-16/10h00-daily-standup"),
        ("Work/Team", "/r/Work-Team/47-2026/11-16/10h00-daily-standup"),
        (". Home .", "/r/Home/47-2026/11-16/10h00-daily-standup"),
        ("", "/r/47-2026/11-16/10h00-daily-standup"),
        ("...", "/r/47-2026/11-16/10h00-daily-standup"),
    ])
    func recordsUnderTheCalendarByTheScheduledStart(calendar: String, expected: String) {
        let meeting = ScheduledMeeting(
            title: "Daily Standup (camera on)",
            start: at(10, 0),
            end: at(10, 30),
            calendar: calendar
        )

        #expect(meeting.directory(root: URL(filePath: "/r"), timeZone: Self.utc).path == expected)
    }

    @Test func nextIsTheFirstNotDoneThatHasNotEndedEvenIfUnderway() {
        let standup = meeting("Standup", at(10, 0), at(10, 30))
        let planning = meeting("Planning", at(10, 15), at(11, 0))
        let retro = meeting("Retro", at(14, 0), at(15, 0))
        let meetings = [standup, planning, retro]

        #expect(MeetingSchedule.next(in: meetings, excluding: [], now: at(9, 0)) == standup)
        #expect(MeetingSchedule.next(in: meetings, excluding: [standup], now: at(10, 20)) == planning)
        #expect(MeetingSchedule.next(in: meetings, excluding: [], now: at(11, 0)) == retro)
        #expect(MeetingSchedule.next(in: meetings, excluding: [retro], now: at(11, 0)) == nil)
    }

    @Test func warnsOncePerMeetingWithinTheLeadEvenWhenStartedLate() {
        let standup = meeting("Standup", at(10, 0), at(10, 30))
        let retro = meeting("Retro", at(14, 0), at(15, 0))
        let lead: TimeInterval = 5 * 60

        #expect(MeetingSchedule.warningsDue(in: [standup, retro], lead: lead, excluding: [], now: at(9, 54)).isEmpty)
        #expect(
            MeetingSchedule.warningsDue(in: [standup, retro], lead: lead, excluding: [], now: at(9, 55)) == [standup]
        )
        #expect(MeetingSchedule.warningsDue(in: [standup], lead: lead, excluding: [], now: at(9, 59)) == [standup])
        #expect(MeetingSchedule.warningsDue(in: [standup], lead: lead, excluding: [standup], now: at(9, 56)).isEmpty)
        #expect(MeetingSchedule.warningsDue(in: [standup], lead: lead, excluding: [], now: at(10, 0)).isEmpty)
        #expect(MeetingSchedule.warningsDue(in: [standup], lead: 0, excluding: [], now: at(9, 58)).isEmpty)
    }

    @Test(arguments: [
        (300, "Standup in 5 minutes"), (150, "Standup in 2 minutes"), (90, "Standup in 2 minutes"),
        (30, "Standup in 1 minute"), (270, "Standup in 4 minutes"),
    ])
    func saysHowManyMinutesAwayAsTheScriptDoes(secondsAway: Int, expected: String) {
        let now = at(10, 0)
        let standup = meeting("Standup [x] (webcam)", now.addingTimeInterval(TimeInterval(secondsAway)), at(10, 30))

        #expect(MeetingSchedule.warning(for: standup, now: now) == expected)
    }

    @Test func readsTodayFromMidnightToMidnight() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc

        let monday = MeetingSchedule.day(containing: at(23, 59), calendar: calendar)
        let tuesday = MeetingSchedule.day(containing: at(0, 0, day: 17), calendar: calendar)

        #expect(monday == DateInterval(start: at(0, 0), end: at(0, 0, day: 17)))
        #expect(tuesday.start == monday.end, "a minute after midnight, it is the new day's meetings")
    }

    @Test(arguments: [(8, 3, 23.0), (1, 11, 25.0), (16, 11, 24.0)])
    func takesTheDaysTheClocksChangeAsTheyAre(day: Int, month: Int, hours: Double) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let noon = calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!

        #expect(MeetingSchedule.day(containing: noon, calendar: calendar).duration == hours * 3_600)
    }

    @Test func recordsTomorrowsStandupThoughTodaysOfTheSameNameAndTimeWasRecorded() {
        let mondays = meeting("Daily Standup", at(10, 0), at(10, 15))
        let tuesdays = meeting("Daily Standup", at(10, 0, day: 17), at(10, 15, day: 17))

        #expect(mondays != tuesdays, "a recurring meeting is a meeting a day")
        #expect(MeetingSchedule.next(in: [tuesdays], excluding: [mondays], now: at(9, 0, day: 17)) == tuesdays)
        // Its folder is the day it is on.
        #expect(
            tuesdays.directory(root: URL(filePath: "/r"), timeZone: Self.utc).path
                == "/r/work/47-2026/11-17/10h00-daily-standup"
        )
    }

    private func meeting(_ title: String, _ start: Date, _ end: Date) -> ScheduledMeeting {
        ScheduledMeeting(title: title, start: start, end: end, calendar: "work")
    }

    /// 2026-11-`day` (16, a Monday of ISO week 47, unless given) at `hour`:`minute` UTC.
    @Test func startsAMeetingAddedFromTheMenuOnTheMinute() {
        let meeting = ScheduledMeeting.startingNow(
            "Sync",
            now: at(10, 7) + 42.5,
            minutes: 45,
            calendar: "Work",
            calendarID: "w"
        )

        #expect(meeting == ScheduledMeeting(title: "Sync", start: at(10, 7), end: at(10, 52), calendar: "Work"))
        #expect(meeting.calendarID == "w")
    }

    @Test(arguments: [
        (12 * 60 + 0.5, 10, 20),  // to the end of the minute it stopped in
        (13 * 60.0, 10, 20),  // already on a minute
        (5.0, 10, 8),  // a minute at least
    ])
    func endsAMeetingAddedFromTheMenuWhenItStops(after seconds: Double, hour: Int, minute: Int) {
        let meeting = ScheduledMeeting.startingNow(
            "Sync",
            now: at(10, 7),
            minutes: 30,
            calendar: "Work",
            calendarID: "w"
        )

        let stopped = meeting.stopped(at: at(10, 7) + seconds)

        #expect(stopped.end == at(hour, minute))
        #expect((stopped.title, stopped.start, stopped.calendarID) == ("Sync", at(10, 7), "w"))
    }

    private func at(_ hour: Int, _ minute: Int, day: Int = 16) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }
}
