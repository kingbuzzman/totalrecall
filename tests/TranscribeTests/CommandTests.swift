import Testing

@testable import Transcribe

struct CommandTests {
    @Test func transcribesInEnglishWithSpeakerLabelsByDefault() throws {
        #expect(try parse("call.m4a") == .transcribe(inputPath: "call.m4a", textPath: nil, options: Options()))
    }

    @Test func readsEveryOption() throws {
        let command = try parse("--language", "es-MX", "--mix", "-", "call.txt")

        let options = Options(language: "es-MX", mixesChannels: true)
        #expect(command == .transcribe(inputPath: "-", textPath: "call.txt", options: options))
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
