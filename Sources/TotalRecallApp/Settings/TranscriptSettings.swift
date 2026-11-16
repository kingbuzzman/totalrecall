import SwiftUI

/// The language spoken, and telling people apart by voice.
struct TranscriptSettings: View {
    @Setting(AppSettings.Key.language) private var language = ""
    @Setting(AppSettings.Key.identifiesSpeakers) private var identifiesSpeakers = false
    @Setting(AppSettings.Key.hidesTranscriptFromCapture) private var hidesFromCapture =
        true
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
