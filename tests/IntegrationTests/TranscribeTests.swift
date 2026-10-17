import AudioLab
import Foundation
import Shared
import Testing

/// transcribe on speech from `say`, with Apple's on-device recognizer (downloaded on first use).
struct TranscribeTests {
    private static let you = "Good morning everyone, thanks for joining the call."
    private static let them = "Happy to be here, let's get started."

    @Test func transcribesARecording() async throws {
        let file = try await Speech.file(saying: "The quick brown fox jumps over the lazy dog.", name: "fox.caf")

        let result = try await transcribe(file.path)

        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.standardOutput.hasPrefix("[00:00:00] "))
        #expect(result.standardOutput.lowercased().contains("quick brown fox"))
    }

    @Test func labelsTotalRecallsChannelSplit() async throws {
        let result = try await transcribe(try await conversation().path)

        let labels = result.standardOutput.split(separator: "\n").map { $0.split(separator: " ").dropFirst().first }
        #expect(result.status == 0, "\(result.standardError)")
        #expect(labels.first == "You:", "\(result.standardOutput)")
        #expect(labels.last == "Them:", "\(result.standardOutput)")
        #expect(labels.allSatisfy { $0 == "You:" || $0 == "Them:" }, "\(result.standardOutput)")
        #expect(result.standardOutput.contains("You: Good morning"))
        #expect(result.standardOutput.contains("Them: Happy to be here"))
    }

    @Test func transcribesBothChannelsTogetherWithMix() async throws {
        let result = try await transcribe("--mix", try await conversation().path)

        #expect(result.status == 0, "\(result.standardError)")
        #expect(!result.standardOutput.contains("You:"))
        #expect(!result.standardOutput.contains("Them:"))
        #expect(result.standardOutput.contains("Good morning"))
        #expect(result.standardOutput.contains("Happy to be here"))
    }

    @Test func writesTheTranscriptToATextFile() async throws {
        let audio = try await Speech.file(saying: Self.them, name: "to-file.caf")
        let text = TestEnvironment.result("to-file.txt")

        let result = try await transcribe(audio.path, text.path)

        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.standardOutput.isEmpty)
        #expect(try String(contentsOf: text, encoding: .utf8).contains("Happy to be here"))
    }

    @Test func transcribesALiveStreamOnStandardInput() async throws {
        let speech = try await Speech.samples(saying: Self.you)
        let stream =
            WAVStream.header(sampleRate: 48_000, channelCount: 2)
            + WAVStream.samples([speech, speech], count: speech.count)

        let result = try await ProcessResult.run(TestEnvironment.transcribe, ["-"], input: stream)

        #expect(result.status == 0, "\(result.standardError)")
        #expect(result.standardOutput.contains("Good morning"))
    }

    @Test func reportsAFileItCannotRead() async throws {
        let result = try await transcribe(TestEnvironment.result("no-such-file.m4a").path)

        #expect(result.status == 1)
        #expect(result.standardError.hasPrefix("transcribe: "))
    }

    @Test func reportsALanguageItHasNoModelFor() async throws {
        let result = try await transcribe("--language", "xx", TestEnvironment.result("unused.caf").path)

        #expect(result.status == 1)
        #expect(result.standardError == "transcribe: no speech model for xx; see transcribe --list-languages\n")
    }

    @Test func listsTheLanguages() async throws {
        let result = try await transcribe("--list-languages")

        #expect(result.status == 0)
        #expect(result.standardOutput.contains("en-US"))
    }

    @Test func printsItsVersion() async throws {
        #expect(try await transcribe("--version").standardOutput == "\(try #require(TestEnvironment.version))\n")
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

enum Speech {
    static func samples(saying text: String) async throws -> [Float] {
        let url = TestEnvironment.result("say-\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        let say = try await ProcessResult.run(
            URL(fileURLWithPath: "/usr/bin/say"),
            ["-o", url.path, "--data-format=LEF32@48000", text]
        )
        guard say.status == 0 else { throw SpeechError(description: "say failed: \(say.standardError)") }
        return try Recording(contentsOf: url).left
    }

    static func file(saying text: String, name: String) async throws -> URL {
        let url = TestEnvironment.result(name)
        try writeAudioFile([try await samples(saying: text)], sampleRate: 48_000, to: url)
        return url
    }
}

struct SpeechError: Error, CustomStringConvertible {
    let description: String
}
