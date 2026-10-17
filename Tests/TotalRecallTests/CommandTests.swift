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

    @Test func streamsWhileSavingAFile() throws {
        #expect(
            try parse("meeting.mp3", "--stream") == .record(outputPath: "meeting.mp3", options: Options(streams: true))
        )
    }

    @Test func dashOnlyStreams() throws {
        #expect(try parse("-") == .record(outputPath: "-", options: Options()))
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
        (["--stream"], "--stream needs an output file; to only stream, use -"),
        (["-", "--stream"], "--stream is for saving a file and streaming it; - already streams"),
        (["out.wav", "-"], "unexpected argument -; to save a file and stream it, use --stream"),
        (["-", "out.wav"], "unexpected argument out.wav; to save a file and stream it, use --stream"),
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
