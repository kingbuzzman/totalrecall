import AVFoundation
import Testing

@testable import TotalRecall

struct DestinationTests {
    @Test func dashIsStandardOutput() {
        let destination = Destination(path: "-")

        #expect(destination.description == "stdout")
        guard case .standardOutput = destination else {
            Issue.record("expected standard output, got \(destination)")
            return
        }
    }

    @Test func anythingElseIsAFile() {
        #expect(Destination(path: "/tmp/meeting.m4a").description == "/tmp/meeting.m4a")
    }
}

struct OutputFileTests {
    @Test func expandsTheHomeDirectoryAndNormalizesThePath() {
        let output = OutputFile(path: "~/calls/../meeting.m4a")

        #expect(output.url.path == NSHomeDirectory() + "/meeting.m4a")
        #expect(output.partialURL.path == NSHomeDirectory() + "/meeting.m4a.partial.caf")
    }

    @Test func savesNoRawAudioUnlessAsked() {
        #expect(OutputFile(path: "/tmp/meeting.m4a", environment: [:]).rawURL == nil)
        #expect(
            OutputFile(path: "/tmp/meeting.m4a", environment: ["TOTALRECALL_RAW": "1"]).rawURL?.path
                == "/tmp/meeting.m4a.raw.caf"
        )
    }

    @Test func refusesAMissingDirectory() throws {
        try withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("missing")
            let output = OutputFile(path: missing.appendingPathComponent("out.wav").path)

            #expect {
                try output.checkCanCreate(overwrite: true)
            } throws: { error in
                error.localizedDescription == "directory \(missing.path) does not exist"
            }
        }
    }

    @Test(arguments: [false, true])
    func refusesToOverwriteWithoutForce(partial: Bool) throws {
        try withTemporaryDirectory { directory in
            let output = OutputFile(path: directory.appendingPathComponent("out.wav").path)
            let existing = partial ? output.partialURL : output.url
            try Data("keep me".utf8).write(to: existing)

            #expect {
                try output.checkCanCreate(overwrite: false)
            } throws: { error in
                error.localizedDescription == "\(existing.path) already exists (use --force to overwrite)"
            }
            #expect(throws: Never.self) { try output.checkCanCreate(overwrite: true) }
        }
    }

    @Test(arguments: [
        ("caf", kAudioFormatLinearPCM),
        ("wav", kAudioFormatLinearPCM),
        ("aiff", kAudioFormatLinearPCM),
        ("m4a", kAudioFormatMPEG4AAC),
    ])
    func convertsThePartialRecordingToTheFormatOfTheExtension(fileExtension: String, format: AudioFormatID) throws {
        try withTemporaryDirectory { directory in
            let output = OutputFile(path: directory.appendingPathComponent("out.\(fileExtension)").path)
            try writePartialRecording(for: output)

            try output.save()

            let saved = try AVAudioFile(forReading: output.url)
            #expect(saved.formatID == format)
            #expect(saved.fileFormat.channelCount == 2)
            #expect(saved.fileFormat.sampleRate == sampleRate)
            #expect(saved.length >= 4_800)
            #expect(!FileManager.default.fileExists(atPath: output.partialURL.path))
        }
    }

    @Test(arguments: [("caf", 0, "caff"), ("wav", 0, "RIFF"), ("aiff", 0, "FORM"), ("m4a", 4, "ftyp")])
    func writesTheContainerOfTheExtension(fileExtension: String, offset: Int, magic: String) throws {
        try withTemporaryDirectory { directory in
            let output = OutputFile(path: directory.appendingPathComponent("out.\(fileExtension)").path)
            try writePartialRecording(for: output)

            try output.save()

            let header = try Data(contentsOf: output.url).dropFirst(offset).prefix(4)
            #expect(String(decoding: header, as: UTF8.self) == magic)
        }
    }

    @Test func replacesAnExistingFile() throws {
        try withTemporaryDirectory { directory in
            let output = OutputFile(path: directory.appendingPathComponent("out.wav").path)
            try Data("old".utf8).write(to: output.url)
            try writePartialRecording(for: output)

            try output.save()

            #expect(try AVAudioFile(forReading: output.url).length == 4_800)
        }
    }

    @Test(.enabled(if: FFmpeg.isInstalled, "needs ffmpeg"))
    func convertsOtherFormatsWithFFmpeg() throws {
        try withTemporaryDirectory { directory in
            let output = OutputFile(path: directory.appendingPathComponent("out.flac").path)
            try writePartialRecording(for: output)

            try output.save()

            #expect(try AVAudioFile(forReading: output.url).formatID == kAudioFormatFLAC)
        }
    }

    @Test func keepsThePartialRecordingWhenFFmpegFails() throws {
        try withTemporaryDirectory { directory in
            let output = OutputFile(path: directory.appendingPathComponent("out.not-a-format").path)
            try writePartialRecording(for: output)

            #expect {
                try output.save()
            } throws: { error in
                error.localizedDescription.hasPrefix("ffmpeg exited with status ")
            }
            #expect(FileManager.default.fileExists(atPath: output.partialURL.path))
        }
    }

    private func writePartialRecording(for output: OutputFile) throws {
        let sink = try AudioFileSink(url: output.partialURL)
        let tone = sine(frequency: 440, count: 4_800)
        try sink.write(left: tone, right: tone, count: tone.count)
        sink.close()
    }
}

extension AVAudioFile {
    var formatID: AudioFormatID? {
        fileFormat.settings[AVFormatIDKey] as? AudioFormatID
    }
}

enum FFmpeg {
    static let isInstalled: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["ffmpeg", "-version"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }()
}
