import Foundation
import Testing

/// totalrecall's answers that need no audio devices.
struct CommandLineTests {
    @Test func printsItsVersion() async throws {
        let result = try await totalrecall("--version")

        #expect(result.status == 0)
        #expect(result.standardOutput == "\(try #require(TestEnvironment.version))\n")
    }

    @Test func printsTheUsage() async throws {
        let result = try await totalrecall("--help")

        #expect(result.status == 0)
        #expect(result.standardOutput.contains("usage: totalrecall"))
    }

    @Test func listsTheMicrophonesMarkingTheSystemInput() async throws {
        let result = try await totalrecall("--list-mics")

        let lines = result.standardOutput.split(separator: "\n")
        #expect(result.status == 0)
        #expect(lines.allSatisfy { $0.hasPrefix("* ") || $0.hasPrefix("  ") }, "\(result.standardOutput)")
        #expect(lines.count { $0.hasPrefix("* ") } <= 1, "\(result.standardOutput)")
    }

    @Test func refusesToWriteAudioToATerminal() async throws {
        let result = try await ProcessResult.run(
            URL(fileURLWithPath: "/usr/bin/script"),
            ["-q", "/dev/null", TestEnvironment.totalrecall.path, "-"]
        )

        #expect(result.status == 1)
        #expect(result.standardOutput.contains("totalrecall: refusing to write audio to the terminal"))
    }

    @Test func needsAnOutputFile() async throws {
        let result = try await totalrecall()

        #expect(result.status == 1)
        #expect(result.standardError.hasPrefix("totalrecall: missing output file"))
    }

    @Test func refusesAnUnknownMicrophone() async throws {
        let result = try await totalrecall("--mic", "no such microphone", TestEnvironment.result("unused.wav").path)

        #expect(result.status == 1)
        #expect(result.standardError.hasPrefix("totalrecall: no microphone matches \"no such microphone\""))
    }

    @Test func refusesAMissingDirectory() async throws {
        let missing = TestEnvironment.result("no-such-directory")

        let result = try await totalrecall(missing.appendingPathComponent("out.wav").path)

        #expect(result.status == 1)
        #expect(result.standardError == "totalrecall: directory \(missing.path) does not exist\n")
    }

    @Test func leavesAnExistingFileAloneWithoutForce() async throws {
        let existing = TestEnvironment.result("existing.wav")
        try Data("keep me".utf8).write(to: existing)

        let result = try await totalrecall(existing.path)

        #expect(result.status == 1)
        #expect(result.standardError.contains("already exists (use --force to overwrite)"))
        #expect(try String(contentsOf: existing, encoding: .utf8) == "keep me")
    }

    private func totalrecall(_ arguments: String...) async throws -> ProcessResult {
        try await ProcessResult.run(TestEnvironment.totalrecall, arguments)
    }
}
