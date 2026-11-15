import AppKit
import ServiceManagement
import SwiftUI

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
