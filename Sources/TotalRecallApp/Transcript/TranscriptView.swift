import AppKit
import AppSupport
import Shared
import SwiftUI

/// The transcript of the recording going on, or the last one, as it is written: each line as it settles, in a table that
/// follows the latest line while it is scrolled to the bottom, and the words still being recognized, in grey, in a strip
/// of their own at the bottom of the window.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Setting(AppSettings.Key.hidesTranscriptFromCapture) private var hidesFromCapture =
        true
    /// Whether the table is scrolled to the bottom, to offer a way back there when it is not.
    @State private var isAtBottom = true
    /// Counts the clicks of the button back to the latest line, which the table scrolls on.
    @State private var latestRequests = 0
    /// Whether the window is open. SwiftUI keeps a closed window's views for when it opens again, so the table, and
    /// all it holds, goes once the window closes, and is made afresh when it opens.
    @State private var isOpen = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(spacing: 0) {
                if model.transcript.isEmpty {
                    ContentUnavailableView(
                        model.isRecording ? "Listening…" : "No transcript yet",
                        systemImage: "text.bubble",
                        description: Text("What is said shows up here as it is recognized.")
                    )
                    .frame(maxHeight: .infinity)
                } else if isOpen {
                    lines
                } else {
                    Spacer()
                }
            }
            .overlay {
                if let stage = model.languageSwitch {
                    LanguageSwitchOverlay(stage: stage, isRecording: model.isRecording)
                }
            }
            let liveLines = TranscriptLine.parsing(liveText: model.liveText)
            if !liveLines.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(Array(liveLines.enumerated()), id: \.offset) { _, line in
                        TranscriptRow(line: line, isLive: true)
                    }
                }
            }
            if !model.lastMessage.isEmpty {
                Divider()
                Text(model.lastMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
            }
        }
        .frame(minWidth: 420, minHeight: 300)
        .onAppear { isOpen = true }
        .onDisappear { isOpen = false }
        .hiddenFromCapture(hidesFromCapture)
    }

    private var header: some View {
        HStack {
            RecordingIndicator()
            Text(model.meeting?.name ?? "TotalRecall")
                .font(.headline)
            if case .recording(let since) = model.state {
                // A clock of its own, every second while the window is open: the model's elapsed time only moves
                // while the menu is open.
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(clockTime(max(0, Int(context.date.timeIntervalSince(since))), padsHours: false))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isRecording {
                LanguageMenu()
                Toggle(
                    "Voice processing",
                    isOn: Binding(get: { model.usesVoiceProcessing }, set: { model.useVoiceProcessing($0) })
                )
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(
                    "Records your mic through macOS voice processing, as a call in Firefox on the MacBook mic needs: "
                        + "it silences the mic for every other app. Turned on by itself when that happens; turns other "
                        + "audio down a little while on."
                )
            }
            // The same setting as in Settings › Transcript, at hand for when a screenshot of it is wanted.
            Button {
                hidesFromCapture.toggle()
            } label: {
                Image(systemName: hidesFromCapture ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(
                hidesFromCapture
                    ? "Hidden from screenshots and screen sharing; click to show it"
                    : "Shown in screenshots and screen sharing; click to hide it"
            )
            Button("People") {
                openWindow(id: MenuContent.peopleWindow)
                WindowFocus.bringToFront(MenuContent.peopleWindow)
            }
            .help("The people Identify Speakers remembers: name, hear or merge them")
            if let directory = model.meeting?.directory {
                Button("Show in Finder") { NSWorkspace.shared.open(directory) }
                    .disabled(!FileManager.default.fileExists(atPath: directory.path))
            }
        }
        .padding(12)
    }

    /// The lines so far, in a native table (see `TranscriptTable`), with a button back to the latest line when
    /// scrolled up.
    private var lines: some View {
        TranscriptTable(lines: model.transcript, isAtBottom: $isAtBottom, scrollToLatestRequests: latestRequests)
            .overlay(alignment: .bottomTrailing) {
                if !isAtBottom {
                    Button {
                        latestRequests += 1
                    } label: {
                        Label("Latest", systemImage: "arrow.down")
                    }
                    .padding(10)
                }
            }
    }
}

/// The language the transcript is in, as a menu of the languages the speech recognizer has, to switch to while it
/// records: the recording goes on, and the transcript starts over in the one picked.
private struct LanguageMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.transcriptLanguage
        Menu {
            // The one it is in first, as set, such as es, which the recognizer lists only by region.
            Button(SpeechLanguage.name(of: current)) {}
                .disabled(true)
            Divider()
            let options = SpeechLanguage.options(model.speech.languages.filter { $0 != current }, including: "")
            ForEach(options.common, id: \.self) { language in
                Button(SpeechLanguage.name(of: language)) { model.switchLanguage(to: language) }
            }
            Divider()
            ForEach(options.others, id: \.self) { language in
                Button(SpeechLanguage.name(of: language)) { model.switchLanguage(to: language) }
            }
        } label: {
            Label(current, systemImage: "globe")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(model.speech.languages.isEmpty)
        .help(
            "The language the transcript is in. Pick another and it starts over in it, from the start of the "
                + "recording, which goes on all the while."
        )
    }
}

/// Over the transcript while it is switched to another language: that it is, and that the recording goes on. The lines
/// show through it, as they come again.
private struct LanguageSwitchOverlay: View {
    let stage: AppModel.LanguageSwitchStage
    let isRecording: Bool

    var body: some View {
        let language = Locale.current.localizedString(forIdentifier: stage.language) ?? stage.language
        VStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(title(language))
                .font(.headline)
            Text(
                isRecording ? "Still recording, don't worry." : "Recording stopped; the transcript finishes on its own."
            )
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 8)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func title(_ language: String) -> String {
        switch stage {
        case .preparing: "Getting \(language) ready…"
        case .catchingUp: "Transcribing everything so far in \(language)…"
        }
    }
}

/// The red dot, blinking, while it records; under the pointer, a button that stops it, as Stop Recording in the menu.
private struct RecordingIndicator: View {
    @Environment(AppModel.self) private var model
    @State private var isHovered = false

    var body: some View {
        if model.isRecording {
            Button {
                model.stop()
            } label: {
                Image(systemName: isHovered ? "stop.circle.fill" : "record.circle.fill")
                    .foregroundStyle(.red)
                    .symbolEffect(.pulse, options: .repeating, isActive: !isHovered)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .onHover { isHovered = $0 }
            .help("Stop recording")
        } else {
            Image(systemName: "record.circle")
                .foregroundStyle(.secondary)
        }
    }
}

/// A line of the words still being recognized, in the strip below the table, laid out like its rows.
private struct TranscriptRow: View {
    let line: TranscriptLine
    var isLive = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(line.time)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: TranscriptTable.Column.timeWidth, alignment: .leading)
            Text(line.speaker)
                .fontWeight(.semibold)
                .foregroundStyle(Color(nsColor: SpeakerPalette.color(line.side, 0)))
                .lineLimit(1)
                .frame(width: TranscriptTable.Column.speakerWidth, alignment: .leading)
            Text(line.text)
                .italic(isLive)
                .foregroundStyle(isLive ? .secondary : .primary)
                // The words still being recognized keep to a few lines, showing the latest.
                .lineLimit(isLive ? 3 : nil)
                .truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 12)
        .background(
            Color(nsColor: SpeakerPalette.color(line.side, 0)).opacity(line.side == .unknown ? 0 : isLive ? 0.05 : 0.12)
        )
    }
}
