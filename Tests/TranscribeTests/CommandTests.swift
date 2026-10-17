import Foundation
import Testing

@testable import Transcribe

struct CommandTests {
    @Test func transcribesInEnglishWithSpeakerLabelsByDefault() throws {
        #expect(try parse("call.m4a") == .transcribe(inputPath: "call.m4a", textPath: nil, options: Options()))
    }

    @Test func readsEveryOption() throws {
        let command = try parse("--language", "es-MX", "--mix", "--live", "--force", "-", "call.txt")

        let options = Options(language: "es-MX", mixesChannels: true, showsLive: true, overwrite: true)
        #expect(command == .transcribe(inputPath: "-", textPath: "call.txt", options: options))
    }

    @Test func shortForceFlag() throws {
        #expect(
            try parse("-f", "call.m4a", "call.txt")
                == .transcribe(inputPath: "call.m4a", textPath: "call.txt", options: Options(overwrite: true))
        )
    }

    @Test(arguments: [
        (["--list-languages"], Command.listLanguages),
        (["--help"], .help),
        (["-h"], .help),
        (["--version"], .version),
        (["call.m4a", "--version", "--bogus"], .version),
    ])
    func informationalFlagsWinOverEverythingAfterThem(arguments: [String], expected: Command) throws {
        #expect(try Command.parse(arguments[...]) == expected)
    }

    @Test(arguments: [
        ([], "expected an audio file or -\n\(usage)"),
        (["a.m4a", "b.txt", "c.txt"], "expected an audio file or -\n\(usage)"),
        (["--bogus", "a.m4a"], "unexpected argument --bogus\n\(usage)"),
        (["--language"], "--language needs a language, such as es"),
        (["--language", "--mix", "a.m4a"], "--language needs a language, such as es"),
        (["--live", "a.m4a"], "--live is for a live stream (-); a file is transcribed faster than it was spoken"),
        (["--live"], "expected an audio file or -\n\(usage)"),
    ])
    func rejectsInvalidArguments(arguments: [String], message: String) {
        #expect {
            try Command.parse(arguments[...])
        } throws: { error in
            error.localizedDescription == message
        }
    }

    private func parse(_ arguments: String...) throws -> Command {
        try Command.parse(arguments[...])
    }
}
