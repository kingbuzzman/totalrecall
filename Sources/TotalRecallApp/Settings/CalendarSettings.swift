import AppKit
import AppSupport
import Shared
import SwiftUI

/// Access to the calendars, whether their meetings are recorded and warned of, and for each calendar, whether its
/// meetings are recorded and which of them to ignore.
struct CalendarSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rules = AppSettings.calendarRules
    @AppStorage(AppSettings.Key.newMeetingMinutes, store: AppSettings.store) private var newMeetingMinutes = AppSettings
        .defaultNewMeetingMinutes
    @AppStorage(AppSettings.Key.recordsAutomatically, store: AppSettings.store) private var recordsAutomatically = true
    @AppStorage(AppSettings.Key.warningMinutes, store: AppSettings.store) private var warningMinutes = AppSettings
        .defaultWarningMinutes

    var body: some View {
        Form {
            if model.calendar.hasAccess {
                Section("Meetings on the calendar") {
                    Toggle("Record meetings automatically", isOn: $recordsAutomatically)
                    Text(
                        "Starts recording each meeting when it starts, if nothing is being recorded. A recording only "
                            + "stops when you stop it."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Stepper(value: $warningMinutes, in: 0...30) {
                        LabeledContent("Warn before each meeting") {
                            Text(warningMinutes == 0 ? "Off" : "\(warningMinutes) min")
                        }
                    }
                }
                // Always there, so nothing below moves when the last calendar is turned off: greyed out instead.
                Section {
                    Picker("Default meeting calendar", selection: defaultMeetingCalendar) {
                        if model.meetingCalendars.isEmpty { Text("None").tag("") }
                        ForEach(model.meetingCalendars) { calendar in
                            Text(calendar.title).tag(calendar.id)
                        }
                    }
                    .disabled(model.meetingCalendars.isEmpty)
                    Picker("Default meeting length", selection: $newMeetingMinutes) {
                        ForEach(AppSettings.newMeetingLengths, id: \.self) { minutes in
                            Text(Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes])))
                                .tag(minutes)
                        }
                    }
                    .disabled(model.meetingCalendars.isEmpty)
                } footer: {
                    Text(
                        "Recordings started from the menu are filed under this calendar; hold ⌘ in the menu to "
                            + "pick another. New Meeting… also puts the meeting on it, the default length long "
                            + "while it's recorded, then ending when you stop."
                    )
                    .foregroundStyle(.secondary)
                }
                ForEach(accounts, id: \.self) { account in
                    Section(account.isEmpty ? "Other" : account) {
                        ForEach(model.calendar.calendars.filter { $0.account == account }) { calendar in
                            CalendarRow(calendar: calendar, rules: binding(for: calendar)) { interval in
                                model.calendar.events(onCalendar: calendar.id, in: interval)
                            }
                        }
                    }
                }
                Section {
                    Text(
                        "Meetings on the calendars turned on are warned of and recorded. Holidays and birthdays start "
                            + "off; any other calendar, added later too, starts on. Read-only calendars, which "
                            + "events can't be added to, are never recorded. A meeting in Today can be ignored from "
                            + "then on with Always Ignore Meetings Like This."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            } else {
                Section {
                    Text(
                        "TotalRecall reads today's meetings from Calendar.app, with every account it has, to warn you "
                            + "of them and record them as they start."
                    )
                    if model.calendar.isDenied {
                        Text(
                            "Access was turned down; allow TotalRecall in System Settings › Privacy & Security › "
                                + "Calendars."
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        Button("Open System Settings") { model.calendar.openSystemSettings() }
                    } else {
                        Button("Allow Calendar Access") {
                            Task {
                                await model.calendar.requestAccess()
                                model.readCalendar()
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minHeight: 260, maxHeight: 560)
        // Such as a meeting ignored from the menu while Settings is open.
        .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
            let saved = AppSettings.calendarRules
            if saved != rules { rules = saved }
        }
    }

    private var accounts: [String] {
        var seen: Set<String> = []
        return model.calendar.calendars.map(\.account).filter { seen.insert($0).inserted }
    }

    /// The default meeting calendar: the one chosen, or the one the app falls back to when none was.
    private var defaultMeetingCalendar: Binding<String> {
        Binding {
            model.defaultMeetingCalendar?.id ?? ""
        } set: { id in
            AppSettings.store.set(id, forKey: AppSettings.Key.defaultMeetingCalendar)
        }
    }

    /// A calendar's rules, as set up or its defaults, saved as soon as they change.
    private func binding(for calendar: CalendarSource.Calendar) -> Binding<CalendarRules> {
        Binding {
            AppSettings.rules(for: calendar, in: rules)
        } set: { newRules in
            rules[calendar.id] = newRules
            AppSettings.calendarRules = rules
        }
    }
}

/// A calendar: its color and title, and a switch for whether its meetings are recorded; when they are, what it ignores
/// and a button to edit that, in a sheet. Every calendar is the same kind of row, so their dots and switches line up.
private struct CalendarRow: View {
    let calendar: CalendarSource.Calendar
    @Binding var rules: CalendarRules
    /// The calendar's events in an interval, to try a rule on.
    let events: (DateInterval) -> [CalendarEvent]
    @State private var editsRules = false

    var body: some View {
        Toggle(isOn: $rules.isRecorded) {
            HStack(spacing: 8) {
                Circle()
                    .fill(calendar.color.map { Color(cgColor: $0) } ?? .secondary)
                    .frame(width: 10, height: 10)
                Text(calendar.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                if calendar.isReadOnly {
                    Label("Read-only", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if rules.isRecorded {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Edit Rules…") { editsRules = true }
                }
            }
        }
        .disabled(calendar.isReadOnly)
        .help(
            calendar.isReadOnly
                ? "This calendar is read-only: events can't be added to it, as with holidays, birthdays, or a "
                    + "calendar shared with you for viewing only. Your own meetings aren't on it, so it can't be "
                    + "recorded, or chosen for new meetings."
                : rules.isRecorded ? "Its meetings are recorded" : "Its meetings are not recorded"
        )
        .sheet(isPresented: $editsRules) {
            CalendarRulesEditor(calendarTitle: calendar.title, rules: $rules, events: events)
        }
    }

    /// What it ignores, in a few words: "Ignores 2 phrases · focus & prep".
    private var summary: String {
        var parts: [String] = []
        if !rules.ignoredPhrases.isEmpty { parts.append(counted(rules.ignoredPhrases.count, "phrase")) }
        if rules.skipsFocusAndPrep { parts.append("focus & prep") }
        return parts.isEmpty ? "Ignores nothing" : "Ignores " + parts.joined(separator: " · ")
    }
}

/// Which of a calendar's meetings to ignore, in a sheet: focus time and prep blocks, and meetings by words, phrases or
/// regular expressions in their titles, each of which can be tried on the calendar first.
private struct CalendarRulesEditor: View {
    let calendarTitle: String
    @Binding var rules: CalendarRules
    let events: (DateInterval) -> [CalendarEvent]
    @Environment(\.dismiss) private var dismiss
    @State private var newPhrase = ""
    /// The phrase being tried, in a sheet of the meetings it would ignore.
    @State private var tried: TriedPhrase?

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    Toggle("Ignore focus time and prep blocks", isOn: $rules.skipsFocusAndPrep)
                }
                Section {
                    ForEach(rules.ignoredPhrases, id: \.self) { phrase in
                        LabeledContent {
                            HStack {
                                Button("Test") { tried = TriedPhrase(phrase: phrase) }
                                    .help("Show the meetings it would ignore, two weeks back to two weeks ahead")
                                Button("Remove") { rules.ignoredPhrases.removeAll { $0 == phrase } }
                            }
                        } label: {
                            HStack {
                                Text(phrase)
                                    .font(CalendarRules.pattern(of: phrase) == nil ? .body : .body.monospaced())
                                if CalendarRules.pattern(of: phrase) != nil {
                                    Text("regex").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    LabeledContent {
                        HStack {
                            Button("Test") { tried = TriedPhrase(phrase: newPhrase) }
                                .disabled(isEmpty || problem != nil)
                                .help("Show the meetings it would ignore, before adding it")
                            Button("Add", action: add)
                                .disabled(isEmpty || problem != nil)
                        }
                    } label: {
                        // Without a label of its own: in a form, a text field's title is laid out beside it as a
                        // label, and the field itself squeezed to nothing.
                        TextField(
                            "Ignore meetings with",
                            text: $newPhrase,
                            prompt: Text("Word or phrase, such as 1:1, or /regex/, such as /^1:1/")
                        )
                        .labelsHidden()
                        .onSubmit(add)
                    }
                } header: {
                    Text("Ignore meetings whose title contains")
                } footer: {
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    } else {
                        Text(
                            "Between slashes, a regular expression; otherwise, any title containing it. Case is ignored."
                        )
                        .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 560, height: 420)
        .navigationTitle("Rules for \(calendarTitle)")
        .sheet(item: $tried) { tried in
            let interval = MeetingSchedule.ruleTestInterval(around: Date())
            RuleTestView(
                phrase: tried.phrase,
                calendarTitle: calendarTitle,
                interval: interval,
                meetings: MeetingSchedule.meetings(matching: tried.phrase, in: events(interval))
            )
        }
    }

    private var isEmpty: Bool {
        newPhrase.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// What is wrong with the phrase being typed, a regular expression that does not compile; nil when nothing is.
    private var problem: String? {
        CalendarRules.problem(with: newPhrase)
    }

    private func add() {
        // A phrase that cannot be added, such as a broken regular expression, stays in the field to be fixed.
        if rules.ignore(newPhrase) { newPhrase = "" }
    }
}

/// A phrase tried in `RuleTestView`.
private struct TriedPhrase: Identifiable {
    let phrase: String
    var id: String { phrase }
}

/// The meetings of one calendar a rule would ignore, from two weeks back to two weeks ahead: to see what it catches
/// before relying on it, and that it catches nothing it should not.
private struct RuleTestView: View {
    let phrase: String
    let calendarTitle: String
    let interval: DateInterval
    let meetings: [CalendarEvent]
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summary).font(.headline)
                Text(
                    "On \(calendarTitle), \(interval.start.formatted(date: .abbreviated, time: .omitted)) to "
                        + "\(interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)): two "
                        + "weeks back, this week, and two weeks ahead."
                )
                .font(.callout)
                .foregroundStyle(.secondary)
            }
            if meetings.isEmpty {
                ContentUnavailableView(
                    "Nothing to ignore",
                    systemImage: "checkmark.circle",
                    description: Text("No meeting in these five weeks matches it.")
                )
                .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                List(Array(meetings.enumerated()), id: \.offset) { _, meeting in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(meeting.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .frame(width: 96, alignment: .leading)
                        Text(meeting.start.shortTime)
                            .monospacedDigit()
                            .frame(width: 64, alignment: .leading)
                        Text(meeting.title)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // Those already past in grey: what it would have ignored.
                    .foregroundStyle(meeting.end < Date() ? .secondary : .primary)
                }
                .frame(minHeight: 220)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private var summary: String {
        "“\(phrase)” would ignore \(counted(meetings.count, "meeting"))"
    }
}
