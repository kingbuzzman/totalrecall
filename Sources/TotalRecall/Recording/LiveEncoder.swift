import Foundation

/// Encodes the recording into the output file's format while it is being recorded, so that saving only has to finish
/// the file, instead of converting the whole recording after Ctrl-C: that takes seconds for every hour of audio, about
/// 16 s an hour for .mp3 and 20 s for .m4a. The partial recording is still written, and is still what a crash leaves
/// behind. If encoding fails or falls behind, its file is dropped and the partial recording converted when saving, as
/// it was before.
///
/// Encoding runs on a queue of its own, so a slow or stuck encoder never holds up the recording; past
/// `maxBacklogFrames` of audio waiting for it, it is given up on.
final class LiveEncoder: @unchecked Sendable {
    /// Two minutes of audio.
    static let maxBacklogFrames = Int(sampleRate) * 120
    /// Longest to wait for ffmpeg to finish the file when saving, before converting the partial recording instead.
    static let finishTimeoutSeconds = 30.0

    /// Where the encoding goes until it is saved, such as `meeting.encoding.mp3` next to `meeting.mp3`.
    let url: URL
    private let encoder: any Encoder
    private let queue = DispatchQueue(label: "totalrecall.encoder", qos: .utility)
    private let lock = UnfairLock()
    /// Frames handed to the queue but not encoded yet; under `lock`.
    private var backlogFrames = 0
    /// Why encoding stopped, once it has; under `lock`.
    private var failure: (any Error)?

    /// Starts encoding for `output`, or returns nil when its format needs no encoding (.caf) or the encoder cannot
    /// start, such as without ffmpeg; then saving converts the partial recording, as it would have anyway.
    static func start(for output: OutputFile) -> LiveEncoder? {
        guard let url = output.encodingURL else { return nil }
        try? FileManager.default.removeItem(at: url)  // left by a crash; it is only ever an encoding of ours
        let encoder: any Encoder
        do {
            if let settings = nativeSettings(forExtension: url.pathExtension) {
                encoder = try AudioFileSink(url: url, settings: settings)
            } else {
                guard let ffmpeg = findFFmpeg() else { return nil }
                encoder = try FFmpegEncoder(ffmpeg: ffmpeg, writingTo: url)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return LiveEncoder(url: url, encoder: encoder)
    }

    init(url: URL, encoder: any Encoder) {
        self.url = url
        self.encoder = encoder
    }

    /// Queues the audio for encoding; returns at once. A channel shorter than `count` is encoded as silence after its
    /// end.
    func append(left: [Float], right: [Float], count: Int) {
        let accepted = lock.withLock {
            guard failure == nil else { return false }
            guard backlogFrames + count <= Self.maxBacklogFrames else {
                failure = RecordingError("encoding fell more than \(Self.maxBacklogFrames / Int(sampleRate)) s behind")
                return false
            }
            backlogFrames += count
            return true
        }
        guard accepted else { return }
        queue.async { [self] in
            if lock.withLock({ failure == nil }) {
                do {
                    try encoder.write(left: left, right: right, count: count)
                } catch {
                    lock.withLock { failure = failure ?? error }
                }
            }
            lock.withLock { backlogFrames -= count }
        }
    }

    /// Waits for the audio still queued, finishes the file and returns it; or, if encoding failed, deletes it and
    /// throws why.
    func finish() throws -> URL {
        try queue.sync {
            do {
                if let failure = lock.withLock({ failure }) { throw failure }
                try encoder.finish()
                return url
            } catch {
                encoder.cancel()
                try? FileManager.default.removeItem(at: url)
                throw error
            }
        }
    }

    /// Stops encoding and deletes the file, for a recording that is not being saved.
    func cancel() {
        lock.withLock { failure = failure ?? CancellationError() }
        queue.sync {
            encoder.cancel()
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// What `LiveEncoder` encodes with. Only used on its queue.
protocol Encoder: AnyObject {
    func write(left: [Float], right: [Float], count: Int) throws
    func finish() throws
    func cancel()
}

/// The formats macOS encodes itself, written as they come.
extension AudioFileSink: Encoder {
    func finish() throws { close() }
    func cancel() { close() }
}

/// ffmpeg, for the formats macOS cannot encode, such as .mp3: fed 32-bit float samples on its stdin as they come.
final class FFmpegEncoder: Encoder {
    private let process = Process()
    private let input: FileHandle
    private let exited = DispatchSemaphore(value: 0)

    init(ffmpeg: URL, writingTo url: URL) throws {
        let pipe = Pipe()
        process.executableURL = ffmpeg
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y", "-f", "f32le", "-ar", "\(Int(sampleRate))", "-ac", "2",
            "-i", "pipe:0", url.path,
        ]
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [exited] _ in exited.signal() }
        input = pipe.fileHandleForWriting
        // A write after ffmpeg has exited fails with EPIPE rather than killing the process.
        _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        // Only ffmpeg reads the pipe, so writes fail rather than block once it is gone.
        try pipe.fileHandleForReading.close()
    }

    func write(left: [Float], right: [Float], count: Int) throws {
        var interleaved = [Float](repeating: 0, count: count * 2)
        for frame in 0..<min(left.count, count) { interleaved[frame * 2] = left[frame] }
        for frame in 0..<min(right.count, count) { interleaved[frame * 2 + 1] = right[frame] }
        try input.write(contentsOf: interleaved.withUnsafeBytes { Data($0) })
    }

    func finish() throws {
        try input.close()
        guard exited.wait(timeout: .now() + LiveEncoder.finishTimeoutSeconds) == .success else {
            throw RecordingError("ffmpeg did not finish within \(Int(LiveEncoder.finishTimeoutSeconds)) s")
        }
        guard process.terminationStatus == 0 else {
            throw RecordingError("ffmpeg exited with status \(process.terminationStatus)")
        }
    }

    func cancel() {
        try? input.close()
        if process.isRunning { process.terminate() }
    }
}
