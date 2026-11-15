package import Foundation

/// Where the app saves a recording: the folders `scripts/record-meetings -n` uses for a meeting it records on the spot,
/// ROOT/other/WW-YYYY/MM-DD/HHhMM-short-name/, with the ISO week and the time it started, 24-hour in the Mac's time
/// zone, so both put recordings in one tree.
package enum RecordingFolder {
    /// The folder for a recording named `name` that starts at `start`.
    package static func directory(root: URL, name: String, start: Date, timeZone: TimeZone = .current) -> URL {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = timeZone
        let parts = iso.dateComponents([.yearForWeekOfYear, .weekOfYear, .month, .day, .hour, .minute], from: start)
        let week = String(format: "%02d-%d", parts.weekOfYear!, parts.yearForWeekOfYear!)
        let day = String(format: "%02d-%02d", parts.month!, parts.day!)
        let time = String(format: "%02dh%02d", parts.hour!, parts.minute!)
        return root.appending(path: "other").appending(path: week).appending(path: day)
            .appending(path: "\(time)-\(shortName(name))")
    }

    /// "Core Pod Sprint Retro (webcam ON)" -> "core-pod-sprint-retro": lowercase ASCII words joined by "-", up to
    /// `maxLength` characters, leaving out whatever is in parentheses or brackets; "meeting" when nothing is left.
    package static func shortName(_ title: String, maxLength: Int = 40) -> String {
        let unbracketed = title.replacing(/\([^)]*\)|\[[^\]]*\]/, with: " ")
        let ascii = unbracketed.decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII)
        let words = String(String.UnicodeScalarView(ascii)).lowercased().matches(of: /[a-z0-9]+/).map { String($0.0) }
        var name = ""
        for word in words {
            let longer = name.isEmpty ? word : "\(name)-\(word)"
            if longer.count > maxLength { break }
            name = longer
        }
        return name.isEmpty ? "meeting" : name
    }

    /// rec.EXT and transcript.txt in `directory`, or rec-2.EXT and transcript-2.txt and so on when it already has a
    /// recording, such as when one is restarted within the same minute. A partial recording counts as a recording.
    package static func freePaths(in directory: URL, audioExtension: String) -> (audio: URL, transcript: URL) {
        var number = 1
        while true {
            let suffix = number == 1 ? "" : "-\(number)"
            let audio = directory.appending(path: "rec\(suffix).\(audioExtension)")
            let transcript = directory.appending(path: "transcript\(suffix).txt")
            let taken = [audio, audio.appendingPathExtension("partial.caf"), transcript].contains {
                FileManager.default.fileExists(atPath: $0.path)
            }
            if !taken { return (audio, transcript) }
            number += 1
        }
    }

    /// Partial recordings under `root` that were never saved, as a crash or a forced quit leaves them: each
    /// `<output>.partial.caf`, with the output file it was meant to become.
    package static func unsavedRecordings(under root: URL) -> [(partial: URL, output: URL)] {
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        return files.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasSuffix(".partial.caf") }
            .map { ($0, $0.deletingPathExtension().deletingPathExtension()) }
            .sorted { $0.partial.path < $1.partial.path }
    }
}
