import Foundation

/// A running `totalrecall`, its stderr kept next to the recording as `<output>.log`.
final class TotalRecallProcess {
    private static let startupTimeout = Duration.seconds(10)

    let output: URL
    let log: URL
    private let process = Process()

    private init(output: URL, arguments: [String], standardOutput: Pipe?) throws {
        self.output = output
        log = output.appendingPathExtension("log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        process.executableURL = TestEnvironment.totalrecall
        process.arguments = ["--force"] + arguments + [standardOutput == nil ? output.path : "-"]
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

    var logText: String {
        (try? String(contentsOf: log, encoding: .utf8)) ?? ""
    }

    /// Sends `signal` and returns the exit status, or the signal that killed it.
    func stop(_ signal: Int32 = SIGINT) async -> Int32 {
        kill(process.processIdentifier, signal)
        return await waitForExit()
    }

    func waitForExit() async -> Int32 {
        while process.isRunning { try? await Task.sleep(for: .milliseconds(20)) }
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
