import AppSupport
import Shared
import SwiftUI

/// The language spoken, by default and on each calendar recorded, and telling people apart by voice.
struct TranscriptSettings: View {
    @Environment(AppModel.self) private var model
    @Setting(AppSettings.Key.language) private var language = ""
    @Setting(AppSettings.Key.identifiesSpeakers) private var identifiesSpeakers = false
    @Setting(AppSettings.Key.hidesTranscriptFromCapture) private var hidesFromCapture =
        true
    @State private var asksToIdentifySpeakers = false
    @Environment(\.openWindow) private var openWindow

    /// What turning on Identify Speakers means in law, said each time it is turned on, before it is.
    static let identifyingSpeakersNotice =
        "To recognize people from one call to the next, it saves a voiceprint of everyone it hears, and a few "
        + "samples of their speech, on this Mac. A voiceprint is biometric data: some laws, such as Illinois's "
        + "BIPA and the GDPR in Europe, require each person's consent before you keep one, in writing in "
        + "Illinois. Turn it on only for calls where everyone has agreed. You are responsible for following the "
        + "law where you and they are."

    /// The default language, as set, or transcribe's own, en-US, when it is not.
    private var defaultLanguage: Binding<String> {
        Binding {
            language.trimmingCharacters(in: .whitespaces).nonEmpty ?? "en-US"
        } set: {
            language = $0
        }
    }

    var body: some View {
        Form {
            Section {
                Picker("Default language", selection: defaultLanguage) {
                    SpeechLanguagePickerItems(
                        options: SpeechLanguage.options(model.speech.languages, including: defaultLanguage.wrappedValue)
                    )
                }
                ForEach(model.meetingCalendars) { calendar in
                    CalendarLanguagePicker(
                        calendar: calendar,
                        defaultLanguage: defaultLanguage.wrappedValue,
                        languages: model.speech.languages
                    )
                }
                Text(
                    model.meetingCalendars.isEmpty
                        ? "The language spoken. Switch a meeting's language as it is recorded in the transcript window."
                        : "Each calendar's meetings are transcribed in the default language unless set otherwise "
                            + "here. Switch a meeting's language as it is recorded in the transcript window."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                        + "saving their voiceprints."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                LabeledContent("The people it remembers") {
                    Button("People…") {
                        openWindow(id: MenuContent.peopleWindow)
                        WindowFocus.bringToFront(MenuContent.peopleWindow)
                    }
                }
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

/// The language a calendar's meetings are transcribed in: the default unless another is picked.
private struct CalendarLanguagePicker: View {
    let calendar: CalendarSource.Calendar
    let defaultLanguage: String
    /// The languages the speech recognizer has.
    let languages: [String]

    var body: some View {
        Picker(selection: language) {
            Text("Default (\(defaultLanguage))").tag("")
            Divider()
            SpeechLanguagePickerItems(options: SpeechLanguage.options(languages, including: language.wrappedValue))
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(calendar.color.map { Color(cgColor: $0) } ?? .secondary)
                    .frame(width: 10, height: 10)
                Text(calendar.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// The calendar's language, "" for the default, saved as soon as it changes.
    private var language: Binding<String> {
        Binding {
            AppSettings.rules(for: calendar).language ?? ""
        } set: { language in
            var rules = AppSettings.calendarRules
            var calendarRules = AppSettings.rules(for: calendar)
            calendarRules.language = language.nonEmpty
            rules[calendar.id] = calendarRules
            AppSettings.calendarRules = rules
        }
    }
}

/// A language picker's items: the common languages, then, after a divider, all the others; each tagged with itself.
private struct SpeechLanguagePickerItems: View {
    let options: (common: [String], others: [String])

    var body: some View {
        ForEach(options.common, id: \.self) { Text(SpeechLanguage.name(of: $0)).tag($0) }
        if !options.common.isEmpty && !options.others.isEmpty { Divider() }
        ForEach(options.others, id: \.self) { Text(SpeechLanguage.name(of: $0)).tag($0) }
    }
}
