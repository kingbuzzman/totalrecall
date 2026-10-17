import Foundation
import Testing

@testable import TotalRecall

struct CommandTests {
    @Test func recordsWithEverythingOnByDefault() throws {
        #expect(try parse("meeting.m4a") == .record(outputPath: "meeting.m4a", options: Options()))
    }

    @Test func readsEveryRecordingOption() throws {
        let command = try parse("--mic", "AirPods", "--no-speaker-isolation", "--no-echo-cancellation", "--force", "-")

        let options = Options(microphoneQuery: "AirPods", isolatesSpeakers: false, cancelsEcho: false, overwrite: true)
        #expect(command == .record(outputPath: "-", options: options))
    }

    @Test func noMicRecordsSystemAudioOnly() throws {
        #expect(
            try parse("--no-mic", "out.wav")
                == .record(outputPath: "out.wav", options: Options(includesMicrophone: false))
        )
    }

    @Test func shortForceFlag() throws {
        #expect(try parse("-f", "out.wav") == .record(outputPath: "out.wav", options: Options(overwrite: true)))
    }

    @Test(arguments: [
        (["--list-mics"], Command.listMicrophones),
        (["--help"], .help),
        (["-h"], .help),
        (["--version"], .version),
        (["out.wav", "--version", "--bogus"], .version),
        (["--list-mics", "--help"], .listMicrophones),
    ])
    func informationalFlagsWinOverEverythingAfterThem(arguments: [String], expected: Command) throws {
        #expect(try Command.parse(arguments[...]) == expected)
    }

    @Test(arguments: [
        ([], "missing output file"),
        (["--mic"], "--mic needs a name"),
        (["--bogus", "out.wav"], "unexpected argument --bogus"),
        (["one.wav", "two.wav"], "unexpected argument two.wav"),
    ])
    func rejectsInvalidArgumentsWithTheUsage(arguments: [String], problem: String) {
        #expect {
            try Command.parse(arguments[...])
        } throws: { error in
            error.localizedDescription == "\(problem)\n\(usage)"
        }
    }

    private func parse(_ arguments: String...) throws -> Command {
        try Command.parse(arguments[...])
    }
}
