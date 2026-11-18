import Foundation
import Testing

@testable import AppSupport

struct CalendarRulesTests {
    private static let utc = TimeZone(identifier: "UTC")!

    @Test func keepsTwoCalendarsOfTheSameTitleApart() {
        // Two accounts, each with its own "Holidays in United States"; only the first is recorded.
        let events = [
            CalendarEvent(
                title: "Team sync",
                start: at(10),
                end: at(11),
                calendar: "Holidays in United States",
                calendarID: "A"
            ),
            CalendarEvent(
                title: "Planning",
                start: at(12),
                end: at(13),
                calendar: "Holidays in United States",
                calendarID: "B"
            ),
        ]
        let rules = ["A": CalendarRules(isRecorded: true), "B": CalendarRules(isRecorded: false)]

        let meetings = MeetingSchedule.meetings(from: events) { rules[$0] ?? CalendarRules() }

        #expect(meetings.map(\.title) == ["Team sync"])
        #expect(meetings.first?.calendarID == "A")
    }

    @Test(arguments: [
        ("Alex / Sam 1:1", true),
        ("lunch with the team", true),
        ("Sprint planning", false),
        ("Focus time", true),
        ("Prep for the review", true),
    ])
    func ignoresMeetingsWhoseTitleContainsAPhraseIgnoringCase(title: String, ignored: Bool) {
        let rules = CalendarRules(ignoredPhrases: ["1:1", "Lunch"])

        #expect(rules.ignores(title: title) == ignored)
    }

    @Test(arguments: [
        ("1:1 Alex / Sam", true),  // starts with 1:1
        ("Alex / Sam 1:1", false),  // has it, but not at the start
        ("Daily STANDUP", true),  // ends with standup, ignoring case
        ("Standup review", false),
        ("Sprint planning", false),
    ])
    func ignoresMeetingsWhoseTitleMatchesARegularExpressionBetweenSlashes(title: String, ignored: Bool) {
        let rules = CalendarRules(ignoredPhrases: ["/^1:1|standup$/"])

        #expect(rules.ignores(title: title) == ignored)
    }

    @Test func takesOnlyAPhraseBetweenSlashesForARegularExpression() {
        #expect(CalendarRules.pattern(of: "/^1:1/") == "^1:1")
        #expect(CalendarRules.pattern(of: " /a.c/ ") == "a.c")
        #expect(CalendarRules.pattern(of: "1:1") == nil)
        #expect(CalendarRules.pattern(of: "/half") == nil)
        #expect(CalendarRules.pattern(of: "/") == nil)
        // Plain, a dot is a dot.
        #expect(!CalendarRules(ignoredPhrases: ["a.c"]).ignores(title: "abc"))
        #expect(CalendarRules(ignoredPhrases: ["/a.c/"]).ignores(title: "abc"))
    }

    @Test func refusesARegularExpressionThatDoesNotCompile() {
        var rules = CalendarRules()

        #expect(CalendarRules.problem(with: "/(unclosed/") != nil)
        #expect(CalendarRules.problem(with: "//") != nil)
        #expect(CalendarRules.problem(with: "/^ok$/") == nil)
        #expect(CalendarRules.problem(with: "plain (words") == nil)
        let addedBroken = rules.ignore("/(unclosed/")
        let addedGood = rules.ignore("/^ok$/")

        #expect(!addedBroken)
        #expect(addedGood)
        #expect(rules.ignoredPhrases == ["/^ok$/"])
    }

    @Test func aBrokenRegularExpressionSavedBeforeIgnoresNothing() {
        let rules = CalendarRules(ignoredPhrases: ["/(unclosed/"])

        #expect(!rules.ignores(title: "(unclosed"))
        #expect(!rules.ignores(title: "anything"))
    }

    @Test func keepsFocusTimeAndPrepBlocksWhenTurnedOff() {
        let rules = CalendarRules(skipsFocusAndPrep: false)

        #expect(!rules.ignores(title: "Focus time"))
        #expect(!rules.ignores(title: "Prep for the review"))
    }

    @Test func ignoresEachPhraseOnceAndNoEmptyOnes() {
        var rules = CalendarRules()

        rules.ignore("Lunch")
        rules.ignore("  lunch ")
        rules.ignore("   ")
        rules.ignore("1:1")

        #expect(rules.ignoredPhrases == ["Lunch", "1:1"])
    }

    @Test func leavesOutWhatACalendarIgnoresButKeepsTheSameMeetingOnAnother() {
        let events = [
            CalendarEvent(title: "Lunch and learn", start: at(12), end: at(13), calendar: "Work", calendarID: "work"),
            CalendarEvent(title: "Lunch and learn", start: at(12), end: at(13), calendar: "Team", calendarID: "team"),
        ]
        let rules = ["work": CalendarRules(ignoredPhrases: ["lunch"])]

        let meetings = MeetingSchedule.meetings(from: events) { rules[$0] ?? CalendarRules() }

        #expect(meetings.map(\.calendar) == ["Team"])
    }

    @Test func recordsMeetingCalendarsButNotHolidaysOrBirthdaysUnlessSetUp() {
        #expect(CalendarRules.defaults(isMeetingCalendar: true).isRecorded)
        #expect(!CalendarRules.defaults(isMeetingCalendar: false).isRecorded)
        #expect(CalendarRules.defaults(isMeetingCalendar: true).skipsFocusAndPrep)
    }

    @Test func savesAndReadsBackEveryCalendarsRules() {
        let rules = [
            "A": CalendarRules(isRecorded: false),
            "B": CalendarRules(skipsFocusAndPrep: false, ignoredPhrases: ["1:1"]),
            "C": CalendarRules(language: "es-MX"),
        ]

        #expect(CalendarRules.decode(CalendarRules.encode(rules)) == rules)
        #expect(CalendarRules.decode(nil).isEmpty)
        #expect(CalendarRules.decode("not rules").isEmpty)
        #expect(CalendarRules.decode(["A": "not rules"]).isEmpty)
    }

    @Test func savesTheRulesAsPlainDictionaries() throws {
        let saved = CalendarRules.encode(["A": CalendarRules(isRecorded: false, ignoredPhrases: ["1:1"])])

        let rules = try #require(saved["A"] as? [String: Any])
        #expect(rules["isRecorded"] as? Bool == false)
        #expect(rules["ignoredPhrases"] as? [String] == ["1:1"])
        #expect(rules["language"] == nil, "no language is saved for one never set")
    }

    @Test func readsRulesSavedWithoutALanguageAsUsingTheDefault() {
        let saved: [String: Any] = ["A": ["isRecorded": true, "skipsFocusAndPrep": true, "ignoredPhrases": [String]()]]

        #expect(CalendarRules.decode(saved) == ["A": CalendarRules()])
    }

    @Test(
        arguments: [
            // The calendar's own language wins over the default.
            ("A", "es", "pt-BR"),
            ("A", nil, "pt-BR"),
            // A calendar without one, a blank one, an unknown calendar, or none at all goes by the default.
            ("B", "es", "es"),
            ("C", "es", "es"),
            ("Z", "es", "es"),
            (nil, "es", "es"),
            // Nothing set anywhere: the transcriber's own default.
            ("B", nil, nil),
            ("B", "  ", nil),
        ] as [(String?, String?, String?)]
    )
    func transcribesEachCalendarsMeetingsInItsLanguageOrTheDefault(
        calendar: String?,
        defaultLanguage: String?,
        expected: String?
    ) {
        let rules = [
            "A": CalendarRules(language: " pt-BR "),
            "B": CalendarRules(),
            "C": CalendarRules(language: " "),
        ]

        let language = CalendarRules.language(ofCalendar: calendar, in: rules, defaultLanguage: defaultLanguage)

        #expect(language == expected)
    }

    @Test func triesARuleOnTheTwoWeeksBeforeThisOneThisWeekAndTheTwoAfter() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        calendar.firstWeekday = 2  // Monday
        // Wednesday 2026-11-18: its week runs Monday 11-16 to Monday 11-23.
        let interval = MeetingSchedule.ruleTestInterval(around: at(10, day: 18), calendar: calendar)

        #expect(interval.start == at(0, day: 2))
        #expect(interval.end == at(0, day: 30, month: 11).addingTimeInterval(7 * 86_400))
        #expect(interval.duration == 5 * 7 * 86_400)
    }

    @Test func listsTheMeetingsARuleWouldIgnoreInOrder() {
        let events = [
            CalendarEvent(title: "Sam 1:1", start: at(15, day: 20), end: at(16, day: 20), calendar: "Work"),
            CalendarEvent(title: "Planning", start: at(9, day: 18), end: at(10, day: 18), calendar: "Work"),
            CalendarEvent(title: "1:1 Alex", start: at(9, day: 17), end: at(10, day: 17), calendar: "Work"),
            CalendarEvent(
                title: "1:1 day",
                start: at(0, day: 19),
                end: at(0, day: 20),
                calendar: "Work",
                isAllDay: true
            ),
        ]

        #expect(MeetingSchedule.meetings(matching: "1:1", in: events).map(\.title) == ["1:1 Alex", "Sam 1:1"])
        #expect(MeetingSchedule.meetings(matching: "/^1:1/", in: events).map(\.title) == ["1:1 Alex"])
        #expect(MeetingSchedule.meetings(matching: "/(broken/", in: events).isEmpty)
    }

    /// 2026-`month`-`day` (11-16 unless given) at `hour`:00 UTC.
    private func at(_ hour: Int, day: Int = 16, month: Int = 11) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        return calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }
}
