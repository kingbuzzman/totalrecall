import AVFoundation
import Foundation

/// The file the user asked for, plus the crash-safe `.partial.caf` next to it that is recorded into until saving.
struct OutputFile {
    let url: URL
    let partialURL: URL

    init(path: String) {
        url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        partialURL = url.appendingPathExtension("partial.caf")
    }

    /// Throws unless the directory exists and, without `overwrite`, neither file exists yet.
    func checkCanCreate(overwrite: Bool) throws {
        let directory = url.deletingLastPathComponent().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw RecordingError("directory \(directory) does not exist")
        }
        for existing in [url, partialURL] where FileManager.default.fileExists(atPath: existing.path) && !overwrite {
            throw RecordingError("\(existing.path) already exists (use --force to overwrite)")
        }
    }

    /// Converts the partial recording to the format the extension names, then deletes it.
    func save() throws {
        try? FileManager.default.removeItem(at: url)
        switch url.pathExtension.lowercased() {
        case "caf":
            try FileManager.default.moveItem(at: partialURL, to: url)
            return
        case "wav", "wave":
            try transcode(partialURL, to: url, settings: pcmSettings(bigEndian: false))
        case "aif", "aiff":
            try transcode(partialURL, to: url, settings: pcmSettings(bigEndian: true))
        case "m4a", "mp4", "aac":
            try transcode(partialURL, to: url, settings: aacSettings)
        default:
            try transcodeWithFFmpeg(partialURL, to: url)
        }
        try FileManager.default.removeItem(at: partialURL)
    }
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
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [
        "ffmpeg", "-nostdin", "-hide_banner", "-loglevel", "error", "-y", "-i", source.path, destination.path,
    ]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        throw RecordingError("ffmpeg exited with status \(process.terminationStatus)")
    }
}
