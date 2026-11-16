import Testing

@testable import AppSupport

struct MeetingCalendarTests {
    @Test func usesTheCalendarChosenWhileItIsRecorded() {
        #expect(MeetingCalendar.resolve(chosen: "b", recorded: ["a", "b"]) == "b")
    }

    @Test(arguments: [nil, "gone"])
    func fallsBackToTheFirstRecordedCalendar(chosen: String?) {
        #expect(MeetingCalendar.resolve(chosen: chosen, recorded: ["a", "b"]) == "a")
    }

    @Test func isNoneWhenNoCalendarIsRecorded() {
        #expect(MeetingCalendar.resolve(chosen: "a", recorded: []) == nil)
    }
}
