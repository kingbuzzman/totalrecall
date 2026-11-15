import AppKit
import AppSupport
import ServiceManagement
import Shared
import SwiftUI
import TotalRecall

/// Settings, a tab for each part: where recordings go and when they start, which calendars, how they are recorded and
/// transcribed, and the version. Changes apply from the next recording.
struct SettingsView: View {
    var body: some View {
        TabView {
            Tab("General", systemImage: "gearshape") { GeneralSettings() }
            Tab("Calendars", systemImage: "calendar") { CalendarSettings() }
            Tab("Recording", systemImage: "waveform") { RecordingSettings() }
            Tab("Transcript", systemImage: "text.bubble") { TranscriptSettings() }
            Tab("About", systemImage: "info.circle") { AboutView() }
        }
        .frame(width: 540)
    }
}

/// Where recordings go, when meetings are recorded, and opening at login.
private struct GeneralSettings: View {
    @AppStorage(AppSettings.Key.recordingsFolder) private var recordingsFolder = AppSettings.defaultRecordingsFolder
    @AppStorage(AppSettings.Key.recordsAutomatically) private var recordsAutomatically = true
    @AppStorage(AppSettings.Key.warningMinutes) private var warningMinutes = AppSettings.defaultWarningMinutes
    @AppStorage(AppSettings.Key.hidesMenuBarIconFromCapture) private var hidesMenuBarIcon = true
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?

    var body: some View {
        Form {
            Section("Recordings") {
                LabeledContent("Save to") {
                    HStack {
                        Text((recordingsFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                        Button("Show") { NSWorkspace.shared.open(URL(filePath: recordingsFolder)) }
                            .disabled(!FileManager.default.fileExists(atPath: recordingsFolder))
                    }
                }
                Text(
                    "A meeting on the calendar goes in CALENDAR/WEEK-YEAR/MM-DD/HHhMM-name/, by when it was meant to "
                        + "start; one started from the menu, in other/."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

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

            Section {
                Toggle("Hide the menu bar icon from screenshots and screen sharing", isOn: $hidesMenuBarIcon)
                Text("So no one on a shared screen sees the red dot of a recording. Some apps may show it anyway.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Open at login", isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, enabled in setLaunchesAtLogin(enabled) }
                if let launchAtLoginError {
                    Text(launchAtLoginError).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(filePath: recordingsFolder)
        panel.prompt = "Choose"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url {
            recordingsFolder = url.path
        }
    }

    private func setLaunchesAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginError = nil
        } catch {
            launchAtLoginError = error.localizedDescription
            launchesAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

/// Access to the calendars, and for each, whether its meetings are recorded and which of them to ignore.
private struct CalendarSettings: View {
    @Environment(AppModel.self) private var model
    @State private var rules = AppSettings.calendarRules

    var body: some View {
        Form {
            if model.calendar.hasAccess {
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
                            + "off; any other calendar, added later too, starts on. A meeting in Today can be ignored "
                            + "from then on with Always Ignore Meetings Like This."
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

    /// A calendar's rules, as set up or its defaults, saved as soon as they change.
    private func binding(for calendar: CalendarSource.Calendar) -> Binding<CalendarRules> {
        Binding {
            rules[calendar.id] ?? CalendarRules.defaults(isMeetingCalendar: calendar.isMeetingCalendar)
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
                if rules.isRecorded {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Edit Rules…") { editsRules = true }
                }
            }
        }
        .help(rules.isRecorded ? "Its meetings are recorded" : "Its meetings are not recorded")
        .sheet(isPresented: $editsRules) {
            CalendarRulesEditor(calendarTitle: calendar.title, rules: $rules, events: events)
        }
    }

    /// What it ignores, in a few words: "Ignores 2 phrases · focus & prep".
    private var summary: String {
        var parts: [String] = []
        if !rules.ignoredPhrases.isEmpty {
            let count = rules.ignoredPhrases.count
            parts.append(count == 1 ? "1 phrase" : "\(count) phrases")
        }
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

/// The audio format, with what each costs, and the microphone.
private struct RecordingSettings: View {
    @AppStorage(AppSettings.Key.format) private var format = AudioFormatChoice.default
    @AppStorage(AppSettings.Key.microphone) private var microphone = ""
    @State private var microphones: [String] = []

    var body: some View {
        Form {
            Section("Audio format") {
                Picker("Format", selection: $format) {
                    ForEach(AudioFormatChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                Text(format.detail)
                    .font(.callout)
                if format.needsFFmpeg && findFFmpeg() == nil {
                    Label(
                        "ffmpeg is not installed: run brew install ffmpeg, or choose M4A.",
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                }
                Text(AudioFormatChoice.conversionNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Microphone") {
                Picker("Microphone", selection: $microphone) {
                    Text("System input (follows AirPods)").tag("")
                    ForEach(microphones, id: \.self) { name in
                        Text(name).tag(name)
                    }
                    if !microphone.isEmpty && !microphones.contains(microphone) {
                        Text("\(microphone) (not connected)").tag(microphone)
                    }
                }
                Text("A microphone chosen here is used whenever it is connected; otherwise the system input.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { microphones = InputDevice.all().map(\.name) }
    }
}

/// The language spoken, and telling people apart by voice.
private struct TranscriptSettings: View {
    @AppStorage(AppSettings.Key.language) private var language = ""
    @AppStorage(AppSettings.Key.identifiesSpeakers) private var identifiesSpeakers = false
    @AppStorage(AppSettings.Key.hidesTranscriptFromCapture) private var hidesFromCapture = true
    @State private var asksToIdentifySpeakers = false

    /// What turning on Identify Speakers means in law, said each time it is turned on, before it is.
    static let identifyingSpeakersNotice =
        "To recognize people from one call to the next, it saves a voiceprint of everyone it hears, and a few "
        + "samples of their speech, on this Mac. A voiceprint is biometric data: some laws, such as Illinois's "
        + "BIPA and the GDPR in Europe, require each person's consent before you keep one, in writing in "
        + "Illinois. Turn it on only for calls where everyone has agreed. You are responsible for following the "
        + "law where you and they are."

    var body: some View {
        Form {
            Section {
                TextField("Language", text: $language, prompt: Text("en-US"))
                Text("The language spoken, such as es or es-MX.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section {
                // Turning it on asks first; turning it off doesn't.
                Toggle(
                    "Identify speakers",
                    isOn: Binding(
                        get: { identifiesSpeakers },
                        set: { isOn in
                            if isOn { asksToIdentifySpeakers = true } else { identifiesSpeakers = false }
                        }
                    )
                )
                Text(
                    "Tells people apart by voice, as Them 1, Them 2, …, and remembers them from call to call by "
                        + "saving their voiceprints, which some laws only allow with their consent."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .alert("Identify speakers?", isPresented: $asksToIdentifySpeakers) {
                Button("Turn On") { identifiesSpeakers = true }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(Self.identifyingSpeakersNotice)
            }
            Section {
                Toggle("Hide the transcript from screenshots and screen sharing", isOn: $hidesFromCapture)
                Text(
                    "Asks macOS to leave the transcript window out of screenshots and shared screens. Some apps that "
                        + "share the screen may show it anyway. Turn it off to take a screenshot of it yourself."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The version, and the credit the speaker model's license asks for.
private struct AboutView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("TotalRecall").font(.title2.bold())
            Text("Version \(version)")
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Text("Records and transcribes meetings on this Mac. Your audio and your words never leave it.")
                .multilineTextAlignment(.center)
                // Wraps to as many lines as it takes, rather than being cut short.
                .fixedSize(horizontal: false, vertical: true)
            Link(
                "github.com/kingbuzzman/totalrecall",
                destination: URL(string: "https://github.com/kingbuzzman/totalrecall")!
            )
            Divider().padding(.vertical, 4)
            Text(
                "Identify Speakers uses WeSpeaker's ResNet34-LM speaker model, trained on VoxCeleb, under the "
                    + "Creative Commons Attribution 4.0 license."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link(
                    "Model",
                    destination: URL(string: "https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM")!
                )
                Link("License", destination: URL(string: "https://creativecommons.org/licenses/by/4.0/")!)
            }
            .font(.caption)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
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
                        Text(meeting.start.formatted(date: .omitted, time: .shortened))
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
        let count = meetings.count
        let what = count == 1 ? "1 meeting" : "\(count) meetings"
        return "“\(phrase)” would ignore \(what)"
    }
}
