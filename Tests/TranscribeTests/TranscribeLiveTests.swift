import AudioLab
import Foundation
import Shared
import Testing
import os

@testable import Transcribe

/// The live transcript the app shows, of a recording streamed through a pipe, as it records it.
struct TranscribeLiveTests {
    @Test(.enabled("needs on-device speech recognition") { await speechRecognitionIsAvailable() })
    func transcribesAStreamIntoTheTextFileAndHandsOnEachLine() async throws {
        let speech = try await SystemVoice.samples(saying: "Good morning everyone, thanks for joining the call.")
        let pipe = Pipe()
        let text = FileManager.default.temporaryDirectory.appending(path: "transcribe-live-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: text) }
        let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
        let liveTexts = OSAllocatedUnfairLock<[String]>(initialState: [])

        let writer = Task.detached {
            let handle = pipe.fileHandleForWriting
            try handle.write(contentsOf: WAVStream.header(sampleRate: 48_000, channelCount: 2))
            try handle.write(contentsOf: WAVStream.samples([speech, speech], count: speech.count))
            try handle.close()
        }
        try await transcribeLive(
            from: pipe.fileHandleForReading,
            to: text,
            language: nil,
            identifiesSpeakers: false,
            onLine: { line in lines.withLock { $0.append(line) } },
            onLiveText: { live in liveTexts.withLock { $0.append(live) } },
            onMessage: { _ in }
        )
        try await writer.value

        let saved = try String(contentsOf: text, encoding: .utf8)
        #expect(saved.contains("Good morning"))
        #expect(lines.withLock { $0 } == saved.split(separator: "\n").map(String.init))
        #expect(liveTexts.withLock { $0.last } == "", "the live text is cleared at the end")
    }
}
