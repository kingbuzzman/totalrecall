package import Foundation

/// A `ClickPlayer` in a process of its own: the player tool (`Tests/AudioLabPlayer`), started for one device and stopped
/// by closing its stdin, so it also stops if the tests die. totalrecall records system audio through a tap of what every
/// process plays; with the speakers and the fake microphones all playing from the test process, that tap lost the
/// system clicks on CI, while with each player in a process of its own, as in the shell harness that passed there, it
/// kept them. The players share the host clock, so their click grids still line up.
package final class PlayerProcess: @unchecked Sendable {
    private static let timeout = Duration.seconds(5)

    /// The player tool: built next to the test bundle, as the integration tests depend on it, or the one the environment
    /// names.
    static let executable: URL = {
        if let path = ProcessInfo.processInfo.environment["AUDIOLAB_PLAYER"] { return URL(fileURLWithPath: path) }
        return Bundle(for: PlayerProcess.self).bundleURL.deletingLastPathComponent()
            .appendingPathComponent("AudioLabPlayer")
    }()

    private let process = Process()
    private let input = Pipe()

    /// Returns once the device is playing.
    package init(deviceNamed name: String, tracks: [ClickTrack], silentUntil: Double = 0) async throws {
        let output = Pipe()
        process.executableURL = Self.executable
        process.arguments = [name, "\(silentUntil)"] + tracks.map(\.argument)
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        // Only the player writes to it now, so a player that dies ends the read below.
        try output.fileHandleForWriting.close()

        let readiness = Readiness()
        let reader = output.fileHandleForReading
        // The player prints a line once it plays; the read is blocking, so it gets a thread of its own.
        Thread { readiness.set(!reader.availableData.isEmpty) }.start()
        let deadline = ContinuousClock.now + Self.timeout
        while readiness.value == nil {
            guard ContinuousClock.now < deadline else {
                stop()
                throw AudioLabError("the player for \(name) did not start within \(Self.timeout)")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        guard readiness.value == true else {
            stop()
            throw AudioLabError("the player for \(name) failed with status \(process.terminationStatus)")
        }
    }

    deinit {
        stop()
    }

    /// Stops playing. Closing its stdin tells the player to stop; one still running after `timeout` is killed.
    package func stop() {
        try? input.fileHandleForWriting.close()
        let deadline = ContinuousClock.now + Self.timeout
        while process.isRunning && ContinuousClock.now < deadline { usleep(10_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
        }
    }
}

extension FileHandle {
    /// A pipe that delivers `data` and then ends, like stdin from a program that exited.
    package static func reading(_ data: Data) -> FileHandle {
        let pipe = Pipe()
        Thread {
            try? pipe.fileHandleForWriting.write(contentsOf: data)
            try? pipe.fileHandleForWriting.close()
        }
        .start()
        return pipe.fileHandleForReading
    }
}

/// Whether the player said it is playing (true) or ended without saying so (false); nil until one of them.
private final class Readiness: @unchecked Sendable {
    private let lock = NSLock()
    private var state: Bool?

    var value: Bool? {
        lock.withLock { state }
    }

    func set(_ isPlaying: Bool) {
        lock.withLock { state = isPlaying }
    }
}
