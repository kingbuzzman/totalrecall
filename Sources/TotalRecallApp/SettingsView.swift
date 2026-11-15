import AppKit
import AppSupport
import ServiceManagement
import SwiftUI
import TotalRecall

/// Where recordings go, their format, and how they are recorded and transcribed. Changes apply from the next recording.
struct SettingsView: View {
    @AppStorage(AppSettings.Key.recordingsFolder) private var recordingsFolder = AppSettings.defaultRecordingsFolder
    @AppStorage(AppSettings.Key.format) private var format = AudioFormatChoice.default
    @AppStorage(AppSettings.Key.microphone) private var microphone = ""
    @AppStorage(AppSettings.Key.language) private var language = ""
    @AppStorage(AppSettings.Key.identifiesSpeakers) private var identifiesSpeakers = false
    @State private var launchesAtLogin = SMAppService.mainApp.status == .enabled
    @State private var launchAtLoginError: String?
    @State private var microphones: [String] = []

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
                Text("Each recording goes in other/WEEK-YEAR/MM-DD/HHhMM-name/, as rec and transcript.txt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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

            Section("Recording") {
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

            Section("Transcript") {
                TextField("Language", text: $language, prompt: Text("en-US"))
                Text("The language spoken, such as es or es-MX.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Identify speakers", isOn: $identifiesSpeakers)
                Text("Tells people apart by voice, as Them 1, Them 2, …, and remembers them from call to call.")
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
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { microphones = InputDevice.all().map(\.name) }
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
