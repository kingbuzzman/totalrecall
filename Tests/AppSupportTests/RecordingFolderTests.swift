import Foundation
import Testing

@testable import AppSupport

/// The folders must match `scripts/record-meetings -n`'s, so both put recordings in one tree; the expected names are
/// what the script makes of the same input.
struct RecordingFolderTests {
    private static let utc = TimeZone(identifier: "UTC")!

    @Test(arguments: [
        ("Weekly Design Review (camera on)", "weekly-design-review"),
        ("Café [x] Größe – Ünïcode!!", "cafe-groe-unicode"),
        ("((()))", "meeting"),
        ("", "meeting"),
        ("one two three four five six seven eight nine ten eleven", "one-two-three-four-five-six-seven-eight"),
    ])
    func shortensTheNameAsTheScriptDoes(title: String, expected: String) {
        #expect(RecordingFolder.shortName(title) == expected)
    }

    @Test func goesUnderOtherByISOWeekDayAndStartTime() {
        let start = date(2027, 1, 1, 9, 5)

        let directory = RecordingFolder.directory(
            root: URL(filePath: "/r"),
            name: "Standup",
            start: start,
            timeZone: Self.utc
        )

        #expect(directory.path == "/r/other/53-2026/01-01/09h05-standup")
    }

    @Test func usesTheTimeZoneOfTheMac() {
        let start = date(2026, 12, 28, 23, 59)
        let madrid = TimeZone(identifier: "Europe/Madrid")!

        let directory = RecordingFolder.directory(root: URL(filePath: "/r"), name: "x", start: start, timeZone: madrid)

        #expect(directory.path == "/r/other/53-2026/12-29/00h59-x")
    }

    @Test func numbersARecordingWhenTheFolderAlreadyHasOne() throws {
        try withTemporaryDirectory { directory in
            #expect(
                names(RecordingFolder.freePaths(in: directory, audioExtension: "m4a")) == ["rec.m4a", "transcript.txt"]
            )

            try Data().write(to: directory.appending(path: "transcript.txt"))
            #expect(
                names(RecordingFolder.freePaths(in: directory, audioExtension: "m4a")) == [
                    "rec-2.m4a", "transcript-2.txt",
                ]
            )

            try Data().write(to: directory.appending(path: "rec-2.m4a.partial.caf"))
            #expect(
                names(RecordingFolder.freePaths(in: directory, audioExtension: "m4a")) == [
                    "rec-3.m4a", "transcript-3.txt",
                ]
            )
        }
    }

    @Test func findsRecordingsThatWereNeverSaved() throws {
        try withTemporaryDirectory { directory in
            let meeting = directory.appending(path: "other/46-2026/11-14/10h00-standup")
            try FileManager.default.createDirectory(at: meeting, withIntermediateDirectories: true)
            for name in ["rec.mp3", "rec-2.mp3.partial.caf", "transcript.txt"] {
                try Data().write(to: meeting.appending(path: name))
            }

            let unsaved = RecordingFolder.unsavedRecordings(under: directory)

            #expect(unsaved.map(\.partial.lastPathComponent) == ["rec-2.mp3.partial.caf"])
            #expect(unsaved.map(\.output.lastPathComponent) == ["rec-2.mp3"])
        }
    }

    private func names(_ paths: (audio: URL, transcript: URL)) -> [String] {
        [paths.audio.lastPathComponent, paths.transcript.lastPathComponent]
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "appsupport-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

struct AudioFormatChoiceTests {
    @Test func defaultsToMP3AsTheScriptRecords() {
        #expect(AudioFormatChoice.default == .mp3)
    }

    @Test func saysEveryFormatButCAFCostsAConversionAndWhatToUse() {
        #expect(AudioFormatChoice.conversionNote.contains("Every format but CAF costs a conversion"))
        #expect(AudioFormatChoice.conversionNote.contains("For the best results, use CAF"))
    }

    @Test func onlyMP3NeedsFFmpeg() {
        #expect(AudioFormatChoice.allCases.filter(\.needsFFmpeg) == [.mp3])
    }
}
