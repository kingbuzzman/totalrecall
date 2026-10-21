import AVFoundation
import AudioLab
import Foundation
import Shared
import Speech
import Testing
import os

/// transcribe on speech from the system voice, with Apple's on-device recognizer (downloaded on first use).
@Suite(.retriedOnCI)
struct TranscribeTests {
    private static let you = "Good morning everyone, thanks for joining the call."
    private static let them = "Happy to be here, let's get started."

    @Test(.needsSpeechRecognition) func transcribesARecording() async throws {
        let file = try await Speech.file(saying: "The quick brown fox jumps over the lazy dog.", name: "fox.caf")

        let result = try await transcribe(file.path)

        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.standardOutput.hasPrefix("[00:00:00] "))
        #expect(result.standardOutput.lowercased().contains("quick brown fox"))
    }

    @Test(.needsSpeechRecognition) func labelsTotalRecallsChannelSplit() async throws {
        let result = try await transcribe(try await conversation().path)

        let labels = result.standardOutput.split(separator: "\n").map { $0.split(separator: " ").dropFirst().first }
        #expect(result.status == 0, "\(result.standardError)")
        #expect(labels.allSatisfy { $0 == "You:" || $0 == "Them:" }, "\(result.standardOutput)")
        #expect(result.standardOutput.contains("You: Good morning"))
        #expect(result.standardOutput.contains("Them: Happy to be here"))
    }

    @Test(.needsSpeechRecognition) func transcribesBothChannelsTogetherWithMix() async throws {
        let result = try await transcribe("--mix", try await conversation().path)

        #expect(result.status == 0, "\(result.standardError)")
        #expect(!result.standardOutput.contains("You:"))
        #expect(!result.standardOutput.contains("Them:"))
        #expect(result.standardOutput.contains("Good morning"))
        #expect(result.standardOutput.contains("Happy to be here"))
    }

    @Test(.needsSpeechRecognition) func writesTheTranscriptToATextFile() async throws {
        let audio = try await Speech.file(saying: Self.them, name: "to-file.caf")
        let text = TestEnvironment.result("to-file.txt")
        try? FileManager.default.removeItem(at: text)

        let result = try await transcribe(audio.path, text.path)

        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.standardOutput.isEmpty)
        #expect(try String(contentsOf: text, encoding: .utf8).contains("Happy to be here"))
    }

    @Test func leavesAnExistingTextFileAloneWithoutForce() async throws {
        let audio = try await Speech.file(saying: Self.them, name: "existing.caf")
        let text = TestEnvironment.result("existing.txt")
        try Data("keep me".utf8).write(to: text)

        let refused = try await transcribe(audio.path, text.path)

        #expect(refused.status == 1)
        #expect(
            refused.standardError
                == "transcribe: \(text.standardizedFileURL.path) already exists (use --force to overwrite)\n"
        )
        #expect(try String(contentsOf: text, encoding: .utf8) == "keep me")
    }

    @Test(.needsSpeechRecognition) func overwritesAnExistingTextFileWithForce() async throws {
        let audio = try await Speech.file(saying: Self.them, name: "forced.caf")
        let text = TestEnvironment.result("forced.txt")
        try Data("replace me".utf8).write(to: text)

        let result = try await transcribe("--force", audio.path, text.path)

        #expect(result.status == 0, "\(result.standardError)")
        #expect(try String(contentsOf: text, encoding: .utf8).contains("Happy to be here"))
    }

    /// Runs only where the recognizer is missing, such as on CI, where the tests that transcribe are skipped.
    @Test(.disabled("this Mac can recognize speech") { await speechRecognitionIsAvailable() })
    func explainsThatThisMacCannotRecognizeSpeech() async throws {
        let audio = try await Speech.file(saying: Self.them, name: "unavailable.caf")

        let result = try await transcribe(audio.path)

        #expect(result.status == 1)
        #expect(result.standardError == "transcribe: on-device speech recognition is not available on this Mac\n")
    }

    @Test(.needsSpeechRecognition) func transcribesALiveStreamOnStandardInput() async throws {
        let speech = try await Speech.samples(saying: Self.you)
        let stream =
            WAVStream.header(sampleRate: 48_000, channelCount: 2)
            + WAVStream.samples([speech, speech], count: speech.count)

        let result = try await ProcessResult.run(TestEnvironment.transcribe, ["-"], input: stream)

        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.standardOutput.contains("Good morning"))
        #expect(!result.standardOutput.contains("\u{1B}"), "only --live redraws the line being recognized")
    }

    @Test(.needsSpeechRecognition) func savesALiveStreamWithoutPrinting() async throws {
        let text = TestEnvironment.result("stream-to-file.txt")
        try? FileManager.default.removeItem(at: text)

        let result = try await ProcessResult.run(
            TestEnvironment.transcribe,
            ["-", text.path],
            input: try await stream()
        )

        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.standardOutput.isEmpty)
        #expect(try String(contentsOf: text, encoding: .utf8).contains("Good morning"))
    }

    @Test(.needsSpeechRecognition) func showsTheLiveTranscriptWhileSavingItWithLive() async throws {
        let text = TestEnvironment.result("live-to-file.txt")
        try? FileManager.default.removeItem(at: text)

        let result = try await ProcessResult.run(
            TestEnvironment.transcribe,
            ["--live", "-", text.path],
            input: try await stream()
        )

        let saved = try String(contentsOf: text, encoding: .utf8)
        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.standardOutput.contains("Good morning"))
        #expect(result.standardOutput.contains("\r\u{1B}[K"), "the line being recognized is redrawn")
        #expect(saved.contains("Good morning"))
        #expect(!saved.contains("\u{1B}"), "the file gets only the settled lines")
    }

    @Test func refusesAStreamFromTheTerminal() async throws {
        let result = try await ProcessResult.run(
            URL(fileURLWithPath: "/usr/bin/script"),
            ["-q", "/dev/null", TestEnvironment.transcribe.path, "-"]
        )

        #expect(result.status == 1)
        #expect(result.standardOutput.contains("transcribe: nothing is piped in"))
    }

    /// Ctrl-C reaches every program in `totalrecall - | transcribe -`; transcribe finishes once totalrecall ends the stream.
    @Test(.needsSpeechRecognition, .timeLimit(.minutes(1)))
    func finishesTheTranscriptWhenInterruptedBeforeTheStreamEnds() async throws {
        let text = TestEnvironment.result("interrupted.txt")
        let transcribe = try await LiveTranscribe.start(writingTo: text, saying: Self.you)

        transcribe.interrupt()
        transcribe.endStream()

        #expect(await transcribe.exitStatus() == 0)
        #expect(try String(contentsOf: text, encoding: .utf8).contains("Good morning"))
    }

    @Test(.needsSpeechRecognition, .timeLimit(.minutes(1)))
    func quitsAtOnceOnASecondInterrupt() async throws {
        let transcribe = try await LiveTranscribe.start(writingTo: TestEnvironment.result("quit.txt"), saying: Self.you)

        transcribe.interrupt()
        try await Task.sleep(for: .milliseconds(100))
        transcribe.interrupt()

        #expect(await transcribe.exitStatus() == 128 + SIGINT)
        transcribe.endStream()
    }

    @Test func reportsAFileItCannotRead() async throws {
        let result = try await transcribe(TestEnvironment.result("no-such-file.m4a").path)

        #expect(result.status == 1)
        #expect(result.standardError.hasPrefix("transcribe: "))
    }

    @Test(.needsSpeechRecognition) func reportsALanguageItHasNoModelFor() async throws {
        let result = try await transcribe("--language", "xx", TestEnvironment.result("unused.caf").path)

        #expect(result.status == 1)
        #expect(result.standardError == "transcribe: no speech model for xx; see transcribe --list-languages\n")
    }

    @Test(.needsSpeechRecognition) func listsTheLanguages() async throws {
        let result = try await transcribe("--list-languages")

        #expect(result.status == 0)
        #expect(result.standardOutput.contains("en-US"))
    }

    @Test func printsItsVersion() async throws {
        try expectVersion(try await transcribe("--version").standardOutput)
    }

    /// A live stream of speech, as totalrecall streams it.
    private func stream() async throws -> Data {
        let speech = try await Speech.samples(saying: Self.you)
        return WAVStream.header(sampleRate: 48_000, channelCount: 2)
            + WAVStream.samples([speech, speech], count: speech.count)
    }

    /// totalrecall's channel split: you on the left, then them on the right.
    private func conversation() async throws -> URL {
        let you = try await Speech.samples(saying: Self.you)
        let them = try await Speech.samples(saying: Self.them)
        let url = TestEnvironment.result("conversation-\(UUID().uuidString).caf")
        let silence = { [Float](repeating: 0, count: $0) }
        try writeAudioFile([you + silence(them.count), silence(you.count) + them], sampleRate: 48_000, to: url)
        return url
    }

    private func transcribe(_ arguments: String...) async throws -> ProcessResult {
        try await ProcessResult.run(TestEnvironment.transcribe, arguments)
    }
}

/// `transcribe - <text-file>` reading a stream that is still open.
final class LiveTranscribe {
    private let process = Process()
    private let input = Pipe()

    private init() {}

    /// Starts it and streams it the speech, returning once it has read all of it.
    static func start(writingTo text: URL, saying words: String) async throws -> LiveTranscribe {
        let live = LiveTranscribe()
        let speech = try await Speech.samples(saying: words)
        live.process.executableURL = TestEnvironment.transcribe
        live.process.arguments = ["--force", "-", text.path]
        live.process.standardInput = live.input
        live.process.standardOutput = FileHandle.nullDevice
        live.process.standardError = FileHandle.nullDevice
        try live.process.run()
        let stream =
            WAVStream.header(sampleRate: 48_000, channelCount: 1) + WAVStream.samples([speech], count: speech.count)
        let input = live.input.fileHandleForWriting
        await withCheckedContinuation { continuation in
            Thread {
                try? input.write(contentsOf: stream)
                continuation.resume()
            }
            .start()
        }
        return live
    }

    func interrupt() {
        kill(process.processIdentifier, SIGINT)
    }

    func endStream() {
        try? input.fileHandleForWriting.close()
    }

    func exitStatus(sourceLocation: SourceLocation = #_sourceLocation) async -> Int32 {
        let watchdog = killIfRunning(
            process.processIdentifier,
            after: .seconds(60),
            "transcribe - <text-file>",
            sourceLocation: sourceLocation
        )
        defer { watchdog.cancel() }
        while process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
        return process.terminationStatus
    }
}

enum Speech {
    /// `text` in the system voice, as mono samples at 48 kHz.
    static func samples(saying text: String) async throws -> [Float] {
        // Read only by the converter below, which the macOS 26 SDK marks @Sendable; the macOS 27 SDK does not.
        nonisolated(unsafe) let voice = try await synthesize(text)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let ratio = format.sampleRate / voice.format.sampleRate
        let output = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(Double(voice.frameLength) * ratio) + 1
        )!
        nonisolated(unsafe) var fed = false  // only touched by the converter, which calls this block in turn
        var error: NSError?
        AVAudioConverter(from: voice.format, to: format)!.convert(to: output, error: &error) { _, status in
            status.pointee = fed ? .endOfStream : .haveData
            defer { fed = true }
            return fed ? nil : voice
        }
        if let error { throw error }
        return Array(UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
    }

    /// The speech in the voice's own format, made in-process by AVSpeechSynthesizer. Speech still unfinished after 30 s
    /// is hung: the test fails, rather than the whole run stalling until CI gives up.
    private static func synthesize(_ text: String) async throws -> AVAudioPCMBuffer {
        let synthesizer = AVSpeechSynthesizer()
        defer { synthesizer.stopSpeaking(at: .immediate) }
        let pending = OSAllocatedUnfairLock<CheckedContinuation<AVAudioPCMBuffer, any Error>?>(initialState: nil)
        nonisolated(unsafe) var samples: [Float] = []  // only touched by the synthesizer's callback
        return try await withCheckedThrowingContinuation { continuation in
            pending.withLock { $0 = continuation }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                pending.withLock { $0.take() }?.resume(throwing: SpeechError(description: "speech synthesis hung"))
            }
            synthesizer.write(AVSpeechUtterance(string: text)) { buffer in
                guard let buffer = buffer as? AVAudioPCMBuffer, let channel = buffer.floatChannelData?[0] else {
                    return
                }
                // Copied as they come, as the synthesizer may reuse its buffers; an empty one ends the speech.
                guard buffer.frameLength == 0 else {
                    return samples += UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
                }
                let speech = AVAudioPCMBuffer(
                    pcmFormat: buffer.format,
                    frameCapacity: AVAudioFrameCount(samples.count)
                )!
                speech.frameLength = speech.frameCapacity
                speech.floatChannelData![0].update(from: samples, count: samples.count)
                pending.withLock { $0.take() }?.resume(returning: speech)
            }
        }
    }

    static func file(saying text: String, name: String) async throws -> URL {
        let url = TestEnvironment.result(name)
        try writeAudioFile([try await samples(saying: text)], sampleRate: 48_000, to: url)
        return url
    }
}

/// Whether this Mac has Apple's on-device speech recognizer, with at least one language; as transcribe checks it.
func speechRecognitionIsAvailable() async -> Bool {
    guard SpeechTranscriber.isAvailable else { return false }
    return !(await SpeechTranscriber.supportedLocales.isEmpty)
}

extension Trait where Self == ConditionTrait {
    /// Skips the tests that transcribe on a Mac without on-device speech recognition, such as CI's virtual machines.
    static var needsSpeechRecognition: Self {
        .enabled("needs on-device speech recognition, which this Mac does not have") {
            await speechRecognitionIsAvailable()
        }
    }
}

struct SpeechError: Error, CustomStringConvertible {
    let description: String
}
