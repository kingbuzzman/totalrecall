import Foundation

struct ProcessResult {
    let status: Int32
    let standardOutput: String
    let standardError: String

    /// Runs a program to completion, feeding it `input` on stdin.
    static func run(_ executable: URL, _ arguments: [String], input: Data? = nil) async throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let (output, error, stdin) = (Pipe(), Pipe(), Pipe())
        process.standardOutput = output
        process.standardError = error
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        try process.run()

        if let input {
            Thread {
                try? stdin.fileHandleForWriting.write(contentsOf: input)
                try? stdin.fileHandleForWriting.close()
            }
            .start()
        }
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

    /// A pipe that delivers `data` and then ends, like stdin from a program that exited.
    static func reading(_ data: Data) -> FileHandle {
        let pipe = Pipe()
        Thread {
            try? pipe.fileHandleForWriting.write(contentsOf: data)
            try? pipe.fileHandleForWriting.close()
        }
        .start()
        return pipe.fileHandleForReading
    }
}
