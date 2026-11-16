import AppKit
import ServiceManagement
import SwiftUI

/// Where recordings go, hiding the menu bar icon, and opening at login.
struct GeneralSettings: View {
    @Setting(AppSettings.Key.recordingsFolder) private var recordingsFolder = AppSettings
        .defaultRecordingsFolder
    @Setting(AppSettings.Key.hidesMenuBarIconFromCapture) private var hidesMenuBarIcon =
        true
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
