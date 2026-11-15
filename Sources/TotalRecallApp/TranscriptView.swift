import AppKit
import SwiftUI

/// The transcript of the recording going on, or the last one, as it is written: each line as it settles, and the words
/// still being recognized, in grey, below them.
struct TranscriptView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if model.transcript.isEmpty && model.liveText.isEmpty {
                ContentUnavailableView(
                    model.isRecording ? "Listening…" : "No transcript yet",
                    systemImage: "text.bubble",
                    description: Text("What is said shows up here as it is recognized.")
                )
                .frame(maxHeight: .infinity)
            } else {
                lines
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
            if let directory = model.meeting?.directory {
                Button("Show in Finder") { NSWorkspace.shared.open(directory) }
                    .disabled(!FileManager.default.fileExists(atPath: directory.path))
            }
        }
        .padding(12)
    }

    private var lines: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(model.transcript.enumerated()), id: \.offset) { index, line in
                        Text(line).id(index)
                    }
                    if !model.liveText.isEmpty {
                        Text(model.liveText).foregroundStyle(.secondary).id("live")
                    }
                }
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .onChange(of: model.transcript.count) { scrollToEnd(proxy) }
            .onChange(of: model.liveText) { scrollToEnd(proxy) }
        }
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if !model.liveText.isEmpty {
            proxy.scrollTo("live", anchor: .bottom)
        } else if !model.transcript.isEmpty {
            proxy.scrollTo(model.transcript.count - 1, anchor: .bottom)
        }
    }
}
