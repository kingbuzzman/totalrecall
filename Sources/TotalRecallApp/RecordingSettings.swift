import AppSupport
import SwiftUI
import TotalRecall

/// The audio format, with what each costs, and the microphone.
struct RecordingSettings: View {
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
