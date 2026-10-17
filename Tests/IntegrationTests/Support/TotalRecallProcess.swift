import Foundation
import Testing

/// A running `totalrecall`, its stderr kept next to the recording as `<output>.log`.
final class TotalRecallProcess {
    private static let startupTimeout = Duration.seconds(10)
    /// Saving takes a few seconds at most, converting with ffmpeg included; a totalrecall still running after this long
    /// is hung.
    private static let exitTimeout = Duration.seconds(30)

    let output: URL
    let log: URL
    private let process = Process()

    /// Records to `output`, streams to `standardOutput`, or both with `savesFile`.
    private init(output: URL, arguments: [String], standardOutput: Pipe?, savesFile: Bool = false) throws {
        self.output = output
        log = output.appendingPathExtension("log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.executableURL = TestEnvironment.totalrecall
        let destination =
            switch (standardOutput, savesFile) {
            case (nil, _): [output.path]
            case (_, false): ["-"]
            case (_, true): [output.path, "--stream"]
            }
        process.arguments = ["--force"] + arguments + destination
        process.standardError = try FileHandle(forWritingTo: log)
        process.standardOutput = standardOutput ?? FileHandle.nullDevice
        try process.run()
        try standardOutput?.fileHandleForWriting.close()
    }

    /// Starts recording to `output` and waits until totalrecall says it is recording.
    static func record(to output: URL, _ arguments: String...) async throws -> TotalRecallProcess {
        let recording = try TotalRecallProcess(output: output, arguments: arguments, standardOutput: nil)
        try await recording.waitUntilRecording()
        return recording
    }

    /// Starts streaming WAV to `pipe` and waits until totalrecall says it is recording.
    static func stream(to pipe: Pipe, logTo log: URL, _ arguments: String...) async throws -> TotalRecallProcess {
        let streaming = try TotalRecallProcess(
            output: log.deletingPathExtension(),
            arguments: arguments,
            standardOutput: pipe
        )
        try await streaming.waitUntilRecording()
        return streaming
    }

    /// Starts recording to `output` while streaming WAV to `pipe` (`--stream`), and waits until totalrecall says it is
    /// recording.
    static func recordAndStream(to output: URL, pipe: Pipe, _ arguments: String...) async throws -> TotalRecallProcess {
        let recording = try TotalRecallProcess(
            output: output,
            arguments: arguments,
            standardOutput: pipe,
            savesFile: true
        )
        try await recording.waitUntilRecording()
        return recording
    }

    var logText: String {
        (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    /// Sends `signal` and returns the exit status, or the signal that killed it.
    func stop(_ signal: Int32 = SIGINT, sourceLocation: SourceLocation = #_sourceLocation) async -> Int32 {
        kill(process.processIdentifier, signal)
        return await waitForExit(sourceLocation: sourceLocation)
    }

    /// The exit status, or the signal that killed it. A totalrecall that has not exited within `exitTimeout` is hung: it
    /// is killed and the test fails with its log, rather than the whole run stalling until CI gives up.
    func waitForExit(sourceLocation: SourceLocation = #_sourceLocation) async -> Int32 {
        let deadline = ContinuousClock.now + Self.exitTimeout
        while process.isRunning {
            if ContinuousClock.now >= deadline {
                Issue.record(
                    "totalrecall did not exit within \(Self.exitTimeout), so it was killed: \(logText)",
                    sourceLocation: sourceLocation
                )
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                break
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return process.terminationStatus
    }

    private func waitUntilRecording() async throws {
        let deadline = ContinuousClock.now + Self.startupTimeout
        while !logText.contains("Press Ctrl-C") {
            guard process.isRunning, ContinuousClock.now < deadline else {
                if process.isRunning { process.terminate() }
                throw TotalRecallDidNotStart(log: logText)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

struct TotalRecallDidNotStart: Error, CustomStringConvertible {
    let log: String

    var description: String { "totalrecall did not start recording: \(log)" }
}
