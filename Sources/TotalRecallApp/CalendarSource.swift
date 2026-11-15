import AppKit
import AppSupport
import EventKit
import Foundation
import Observation

/// Today's events from Calendar.app, with every account it has (Google, Exchange, iCloud, ...), through EventKit, once
/// the user gives the app access to their calendars.
@MainActor @Observable
final class CalendarSource {
    /// A calendar, under the account it belongs to, for Settings. Told apart by its identifier: two accounts can each
    /// have a calendar of the same title.
    struct Calendar: Hashable, Identifiable {
        let id: String
        let title: String
        let account: String
        let color: CGColor?
        /// Whether it can have meetings: not a calendar of birthdays, holidays or another subscription, whose events
        /// are all-day ones. Only says whether it is recorded until set in Settings.
        let isMeetingCalendar: Bool
    }

    private(set) var hasAccess = false
    /// Whether the user was asked and said no, or access is restricted: then only System Settings can grant it.
    private(set) var isDenied = false
    private(set) var calendars: [Calendar] = []

    /// Called whenever Calendar.app's events change, such as a meeting added or moved.
    @ObservationIgnored var onChange: (@MainActor () -> Void)?
    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var changes: (any NSObjectProtocol)?

    init() {
        updateStatus()
        changes = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                self?.updateStatus()
                self?.onChange?()
            }
        }
    }

    /// Asks for access to the calendars, if the user has not been asked yet; macOS shows its prompt once.
    func requestAccess() async {
        guard EKEventStore.authorizationStatus(for: .event) == .notDetermined else { return }
        _ = try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Bool, any Error>) in
            store.requestFullAccessToEvents { granted, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: granted) }
            }
        }
        // The store was made before access was given; it only sees the calendars once reset.
        store.reset()
        updateStatus()
    }

    /// Opens the Calendars pane of System Settings, where access the user turned down can be given after all.
    func openSystemSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!
        )
    }

    /// The events of today, the day `now` is in, on the calendars whose identifiers `isRecorded` says yes to; none
    /// without access.
    func todaysEvents(now: Date = Date(), on isRecorded: (Calendar) -> Bool) -> [CalendarEvent] {
        guard hasAccess else { return [] }
        let day = MeetingSchedule.day(containing: now)
        let included = store.calendars(for: .event).filter { isRecorded(Self.calendar($0)) }
        guard !included.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: day.start, end: day.end, calendars: included)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                calendar: event.calendar?.title ?? "",
                calendarID: event.calendar?.calendarIdentifier,
                isAllDay: event.isAllDay
            )
        }
    }

    /// The events of the calendar `id` in `interval`, such as to try a rule on; none without access.
    func events(onCalendar id: String, in interval: DateInterval) -> [CalendarEvent] {
        guard hasAccess, let calendar = store.calendar(withIdentifier: id) else { return [] }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: [calendar])
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                calendar: calendar.title,
                calendarID: id,
                isAllDay: event.isAllDay
            )
        }
    }

    private func updateStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        hasAccess = status == .fullAccess
        isDenied = status == .denied || status == .restricted
        calendars =
            hasAccess
            ? store.calendars(for: .event).map(Self.calendar)
                .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
            : []
    }

    private static func calendar(_ calendar: EKCalendar) -> Calendar {
        let isSubscription = calendar.type == .birthday || calendar.type == .subscription
        let isHolidays = calendar.title.localizedCaseInsensitiveContains("holiday")
        return Calendar(
            id: calendar.calendarIdentifier,
            title: calendar.title,
            account: calendar.source?.title ?? "",
            color: calendar.cgColor,
            isMeetingCalendar: !isSubscription && !isHolidays
        )
    }
}
