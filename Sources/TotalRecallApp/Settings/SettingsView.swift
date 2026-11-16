import SwiftUI

/// Settings, a tab for each part: where recordings go, which calendars and when their meetings start, how they are
/// recorded and transcribed, and the version. Changes apply from the next recording.
struct SettingsView: View {
    /// The tab shown: General each time Settings opens, as the last one looked at is not kept.
    @State private var tab = 0

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: 0) { GeneralSettings() }
            Tab("Calendars", systemImage: "calendar", value: 1) { CalendarSettings() }
            Tab("Recording", systemImage: "waveform", value: 2) { RecordingSettings() }
            Tab("Transcript", systemImage: "text.bubble", value: 3) { TranscriptSettings() }
            Tab("About", systemImage: "info.circle", value: 4) { AboutSettings() }
        }
        .frame(width: 540)
    }
}
