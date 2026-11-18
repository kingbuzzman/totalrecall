import AVFoundation
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
            identifyingSpeakersIn: nil,
            handlers: LiveTranscriptHandlers(
                onLine: { line, _ in lines.withLock { $0.append(line) } },
                onLiveText: { live in liveTexts.withLock { $0.append(live) } },
                onRewrite: { _ in },
                onMessage: { _ in }
            )
        )
        try await writer.value

        let saved = try String(contentsOf: text, encoding: .utf8)
        #expect(saved.contains("Good morning"))
        #expect(lines.withLock { $0 } == saved.split(separator: "\n").map(String.init))
        #expect(liveTexts.withLock { $0.last }?.isEmpty == true, "the live text is cleared at the end")
    }

    @Test(.enabled("needs on-device speech recognition") { await speechRecognitionIsAvailable() })
    func startsOverInTheLanguageSwitchedToAndGoesOnLive() async throws {
        let first = try await SystemVoice.samples(saying: "Good morning everyone, thanks for joining the call.")
        let second = try await SystemVoice.samples(saying: "Let's talk about the budget for next year.")
        let recorder = try LiveRecording()
        defer { try? FileManager.default.removeItem(at: recorder.url) }
        let text = FileManager.default.temporaryDirectory.appending(path: "transcribe-live-\(UUID()).txt")
        defer { try? FileManager.default.removeItem(at: text) }
        let lines = OSAllocatedUnfairLock<[String]>(initialState: [])
        let restarts = OSAllocatedUnfairLock<[String]>(initialState: [])
        let caughtUp = OSAllocatedUnfairLock(initialState: false)
        let switches = LanguageSwitch()

        let writer = Task.detached {
            try await Self.write(first, then: second, to: recorder) { step in
                switch step {
                case .heardFirst: return lines.withLock { !$0.isEmpty }
                case .switchTo:
                    try await switches.switchTo("en-US")
                    return true
                case .caughtUp: return caughtUp.withLock { $0 }
                }
            }
        }
        try await transcribeLive(
            from: recorder.pipe.fileHandleForReading,
            recordedIn: try FileHandle(forReadingFrom: recorder.url),
            to: text,
            language: nil,
            switches: switches,
            identifyingSpeakersIn: nil,
            handlers: LiveTranscriptHandlers(
                onLine: { line, _ in lines.withLock { $0.append(line) } },
                onLiveText: { _ in },
                onRewrite: { _ in },
                onMessage: { _ in },
                onRestart: { language in
                    restarts.withLock { $0.append(language) }
                    lines.withLock { $0 = [] }
                },
                onCaughtUp: { caughtUp.withLock { $0 = true } }
            )
        )
        try await writer.value

        let saved = try String(contentsOf: text, encoding: .utf8)
        #expect(restarts.withLock { $0 } == ["en-US"])
        #expect(caughtUp.withLock { $0 })
        #expect(saved.ranges(of: "Good morning").count == 1, "the file is written afresh, from the start: \(saved)")
        #expect(saved.contains("budget"))
        #expect(lines.withLock { $0 } == saved.split(separator: "\n").map(String.init))
    }

    private enum Step {
        case heardFirst, switchTo, caughtUp
    }

    /// A recording, as the app makes one: streamed through a pipe, and recorded into a 16-bit CAF file at once.
    private final class LiveRecording: @unchecked Sendable {
        let pipe = Pipe()
        let url = FileManager.default.temporaryDirectory.appending(path: "transcribe-live-\(UUID()).partial.caf")
        private var file: AVAudioFile?

        init() throws {
            file = try AVAudioFile(
                forWriting: url,
                settings: [
                    AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2,
                    AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
                ],
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            try pipe.fileHandleForWriting.write(contentsOf: WAVStream.header(sampleRate: 48_000, channelCount: 2))
        }

        /// `samples` on both channels: recorded, then streamed, as the recorder does.
        func write(_ samples: [Float]) throws {
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file!.processingFormat,
                frameCapacity: AVAudioFrameCount(samples.count)
            )!
            buffer.frameLength = AVAudioFrameCount(samples.count)
            for channel in 0..<2 { buffer.floatChannelData![channel].update(from: samples, count: samples.count) }
            try file!.write(from: buffer)
            try pipe.fileHandleForWriting.write(
                contentsOf: WAVStream.samples([samples, samples], count: samples.count)
            )
        }

        /// Finishes the recording, then ends the stream.
        func stop() throws {
            file = nil
            try pipe.fileHandleForWriting.close()
        }
    }

    /// Records `first`, then silence, a tenth of a second at a time, as a recording would, until it is heard; switches
    /// the language; records silence again until the transcript started over has caught up; then `second`, and stops.
    /// `step` says whether each step is done, and switches the language. Gives up waiting after 60 s.
    private static func write(
        _ first: [Float],
        then second: [Float],
        to recorder: LiveRecording,
        step: @escaping @Sendable (Step) async throws -> Bool
    ) async throws {
        let write = recorder.write
        func writeSilence(until done: Step) async throws {
            for _ in 0..<600 {
                if try await step(done) { return }
                try write([Float](repeating: 0, count: 4_800))
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        try write(first)
        try await writeSilence(until: .heardFirst)
        _ = try await step(.switchTo)
        try await writeSilence(until: .caughtUp)
        try write(second)
        try write([Float](repeating: 0, count: 96_000))
        try recorder.stop()
    }
}
