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
        ("", "/r/other/47-2026/11-16/10h00-daily-standup"),
        ("...", "/r/other/47-2026/11-16/10h00-daily-standup"),
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

        #expect(MeetingSchedule.warningsDue(in: [standup, retro], lead: lead, excluding: [], now: at(9, 54)) == [])
        #expect(
            MeetingSchedule.warningsDue(in: [standup, retro], lead: lead, excluding: [], now: at(9, 55)) == [standup]
        )
        #expect(MeetingSchedule.warningsDue(in: [standup], lead: lead, excluding: [], now: at(9, 59)) == [standup])
        #expect(MeetingSchedule.warningsDue(in: [standup], lead: lead, excluding: [standup], now: at(9, 56)) == [])
        #expect(MeetingSchedule.warningsDue(in: [standup], lead: lead, excluding: [], now: at(10, 0)) == [])
        #expect(MeetingSchedule.warningsDue(in: [standup], lead: 0, excluding: [], now: at(9, 58)) == [])
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

    private func meeting(_ title: String, _ start: Date, _ end: Date) -> ScheduledMeeting {
        ScheduledMeeting(title: title, start: start, end: end, calendar: "work")
    }

    /// 2026-11-16 (a Monday, ISO week 47) at `hour`:`minute` UTC.
    private func at(_ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        return calendar.date(from: DateComponents(year: 2026, month: 11, day: 16, hour: hour, minute: minute))!
    }
}
