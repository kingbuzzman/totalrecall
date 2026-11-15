import AVFoundation
package import Foundation

/// Where the recording goes: a file, a live WAV stream on stdout (`-`) for another program such as `transcribe -`, or
/// both (`--stream`).
package struct Destination {
    /// The file to save, or nil when only streaming.
    package let file: OutputFile?
    package let streams: Bool
    /// Where the stream goes: stdout, or a pipe for an app that transcribes it as it records.
    let streamHandle: FileHandle

    package init(path: String, streams: Bool = false, streamHandle: FileHandle = .standardOutput) {
        file = path == "-" ? nil : OutputFile(path: path)
        self.streams = path == "-" || streams
        self.streamHandle = streamHandle
    }

    var description: String {
        let stream = streamHandle.fileDescriptor == STDOUT_FILENO ? "stdout" : "the transcript"
        guard let file else { return stream }
        return streams ? "\(file.url.path) and \(stream)" : file.url.path
    }
}

/// The file the user asked for, plus the crash-safe `.partial.caf` next to it that is recorded into until saving.
package struct OutputFile {
    package let url: URL
    package let partialURL: URL
    /// With `TOTALRECALL_RAW=1` in the environment, where the unprocessed audio is saved as well (`<output>.raw.caf`), a
    /// debugging aid for tuning the processing against real recordings.
    let rawURL: URL?

    package init(path: String, environment: [String: String] = ProcessInfo.processInfo.environment) {
        url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        partialURL = url.appendingPathExtension("partial.caf")
        let savesRaw = environment["TOTALRECALL_RAW"] == "1"
        rawURL = savesRaw ? url.appendingPathExtension("raw.caf") : nil
    }

    /// Throws unless the directory exists and, without `overwrite`, neither file exists yet.
    package func checkCanCreate(overwrite: Bool) throws {
        let directory = url.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RecordingError("directory \(directory) does not exist")
        }
        for existing in [url, partialURL] where FileManager.default.fileExists(atPath: existing.path) && !overwrite {
            throw RecordingError("\(existing.path) already exists (use --force to overwrite)")
        }
    }

    /// Where `LiveEncoder` encodes the recording while it is recorded, such as `meeting.encoding.mp3` for
    /// `meeting.mp3`; nil for a .caf, which is the partial recording's own format, or a file without an extension.
    package var encodingURL: URL? {
        let fileExtension = url.pathExtension
        guard !fileExtension.isEmpty, fileExtension.lowercased() != "caf" else { return nil }
        return url.deletingPathExtension().appendingPathExtension("encoding").appendingPathExtension(fileExtension)
    }

    /// Saves the output file, then deletes the partial recording: from `encoded`, the recording already encoded while
    /// it was recorded, when there is one; otherwise by converting the partial recording to the format the extension
    /// names.
    package func save(encoded: URL? = nil) throws {
        try? FileManager.default.removeItem(at: url)
        let fileExtension = url.pathExtension.lowercased()
        if let encoded {
            try FileManager.default.moveItem(at: encoded, to: url)
        } else if fileExtension == "caf" {
            try FileManager.default.moveItem(at: partialURL, to: url)
            return
        } else if let settings = nativeSettings(forExtension: fileExtension) {
            try transcode(partialURL, to: url, settings: settings)
        } else {
            try transcodeWithFFmpeg(partialURL, to: url)
        }
        try FileManager.default.removeItem(at: partialURL)
    }
}

/// ffmpeg from the PATH or, as an app opened from Finder has a PATH without them, Homebrew's; nil when there is none.
package func findFFmpeg(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
    let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
    let directories = path + ["/opt/homebrew/bin", "/usr/local/bin"]
    return directories.lazy
        .map { URL(fileURLWithPath: $0).appendingPathComponent("ffmpeg") }
        .first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

private func transcode(_ source: URL, to destination: URL, settings: [String: Any]) throws {
    let input = try AVAudioFile(forReading: source, commonFormat: .pcmFormatFloat32, interleaved: false)
    let output = try AVAudioFile(
        forWriting: destination,
        settings: settings,
        commonFormat: .pcmFormatFloat32,
        interleaved: false
    )
    let chunk = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 65_536)!
    while input.framePosition < input.length {
        try input.read(into: chunk)
        try output.write(from: chunk)
    }
    output.close()
}

private func transcodeWithFFmpeg(_ source: URL, to destination: URL) throws {
    guard let ffmpeg = findFFmpeg() else {
        throw RecordingError("saving .\(destination.pathExtension) needs ffmpeg (brew install ffmpeg)")
    }
    let process = Process()
    process.executableURL = ffmpeg
    process.arguments = [
        "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path, destination.path,
    ]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw RecordingError("ffmpeg exited with status \(process.terminationStatus)")
    }
}
