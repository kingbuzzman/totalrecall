import AudioLab
import Foundation
import Testing

struct ProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String

    /// Runs a program to completion, feeding it `input` on stdin. One still running after `timeout` is hung: it is
    /// killed and the test fails, rather than the whole run stalling until CI gives up. The default leaves room for
    /// transcribe to download a speech model.
    static func run(
        _ executable: URL,
        _ arguments: [String],
        input: Data? = nil,
        timeout: Duration = .seconds(120),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let (output, error) = (Pipe(), Pipe())
        process.standardOutput = output
        process.standardError = error
        process.standardInput = input.map(FileHandle.reading) ?? FileHandle.nullDevice
        try process.run()
        let watchdog = killIfRunning(
            process.processIdentifier,
            after: timeout,
            "\(executable.lastPathComponent) \(arguments.joined(separator: " "))",
            sourceLocation: sourceLocation
        )
        defer { watchdog.cancel() }

        async let outputData = output.fileHandleForReading.readAll()
        async let errorData = error.fileHandleForReading.readAll()
        let (standardOutput, standardError) = await (outputData, errorData)
        while process.isRunning { try await Task.sleep(for: .milliseconds(10)) }

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: standardOutput, as: UTF8.self),
            standardError: String(decoding: standardError, as: UTF8.self)
        )
    }
}

extension FileHandle {
    /// Everything until the end of the stream, read on a thread of its own: blocking the tests' threads on a read can
    /// starve the thread pool the writer needs.
    func readAll() async -> Data {
        await withCheckedContinuation { continuation in
            Thread { continuation.resume(returning: self.readDataToEndOfFile()) }.start()
        }
    }
}

/// Kills the process `pid` if it is still running after `timeout`, failing the current test with a message naming
/// `command`; cancel the returned task once the process has exited.
func killIfRunning(
    _ pid: pid_t,
    after timeout: Duration,
    _ command: String,
    sourceLocation: SourceLocation
) -> Task<Void, Never> {
    Task {
        try? await Task.sleep(for: timeout)
        guard !Task.isCancelled else { return }
        Issue.record("\(command) did not finish within \(timeout), so it was killed", sourceLocation: sourceLocation)
        kill(pid, SIGKILL)
    }
}
