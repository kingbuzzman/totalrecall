import Foundation
import Testing

@testable import Transcribe

struct CommandTests {
    @Test func transcribesInEnglishWithSpeakerLabelsByDefault() throws {
        #expect(try parse("call.m4a") == .transcribe(inputPath: "call.m4a", textPath: nil, options: Options()))
    }

    @Test func readsEveryOption() throws {
        let command = try parse(
            "--language",
            "es-MX",
            "--mix",
            "--live",
            "--identify-speakers",
            "--force",
            "-",
            "call.txt"
        )

        let options = Options(
            language: "es-MX",
            mixesChannels: true,
            showsLive: true,
            identifiesSpeakers: true,
            overwrite: true
        )
        #expect(command == .transcribe(inputPath: "-", textPath: "call.txt", options: options))
    }

    @Test func shortForceFlag() throws {
        #expect(
            try parse("-f", "call.m4a", "call.txt")
                == .transcribe(inputPath: "call.m4a", textPath: "call.txt", options: Options(overwrite: true))
        )
    }

    @Test func identifiesSpeakersInAFileToo() throws {
        #expect(
            try parse("--identify-speakers", "call.m4a")
                == .transcribe(inputPath: "call.m4a", textPath: nil, options: Options(identifiesSpeakers: true))
        )
    }

    @Test(arguments: [
        (["speakers"], Command.listSpeakers),
        (["speakers", "name", "3", "Ada"], .nameSpeaker(3, name: "Ada")),
        (["speakers", "name", "3", "Ada", "L."], .nameSpeaker(3, name: "Ada L.")),
        (["speakers", "merge", "5", "3"], .mergeSpeaker(5, into: 3)),
        (["speakers", "forget", "5"], .forgetSpeaker(5)),
        (["speakers", "play", "5"], .playSpeaker(5)),
        (["speakers", "save", "5", "samples"], .saveSpeakerSamples(5, directory: "samples")),
    ])
    func readsTheSpeakersCommands(arguments: [String], expected: Command) throws {
        #expect(try Command.parse(arguments[...]) == expected)
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
        (["speakers", "name", "Ada"], "expected a speaker's number, such as 3; transcribe speakers lists them"),
        (["speakers", "name", "3"], "expected a name for speaker 3"),
        (["speakers", "merge", "5"], "expected a speaker's number, such as 3; transcribe speakers lists them"),
        (["speakers", "forget", "5", "6"], "unexpected argument 6\n\(usage)"),
        (["speakers", "rename"], "unknown speakers command rename\n\(usage)"),
        (["speakers", "play"], "expected a speaker's number, such as 3; transcribe speakers lists them"),
        (["speakers", "save", "5"], "expected a directory to save speaker 5's samples in"),
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
