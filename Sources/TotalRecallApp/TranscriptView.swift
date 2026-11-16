import AppKit
import AppSupport
import SwiftUI

/// The transcript of the recording going on, or the last one, as it is written: each line as it settles, in a table that
/// follows the latest line while it is scrolled to the bottom, and the words still being recognized, in grey, in a strip
/// of their own at the bottom of the window.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppSettings.Key.hidesTranscriptFromCapture) private var hidesFromCapture = true
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
            Image(systemName: model.isRecording ? "record.circle.fill" : "record.circle")
                .foregroundStyle(model.isRecording ? .red : .secondary)
            Text(model.meeting?.name ?? "TotalRecall")
                .font(.headline)
            if case .recording = model.state {
                Text(model.elapsed).monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
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
                .foregroundStyle(Color(nsColor: line.side.color))
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
        .background(Color(nsColor: line.side.color).opacity(line.side == .unknown ? 0 : isLive ? 0.05 : 0.12))
    }
}
