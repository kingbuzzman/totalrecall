package import Foundation

/// Where the app saves a recording: the folders `scripts/record-meetings` uses, so both put recordings in one tree:
/// ROOT/CALENDAR/WW-YYYY/MM-DD/HHhMM-short-name/, with the calendar the meeting is on, the ISO week, and when it was
/// meant to start, 24-hour in the Mac's time zone. A meeting on no calendar goes straight under ROOT, by week.
package enum RecordingFolder {
    /// The folder for a recording named `name` that starts, or was meant to start, at `start`, of a meeting on the
    /// calendar named `calendar`; nil or "" for none.
    package static func directory(
        root: URL,
        calendar: String? = nil,
        name: String,
        start: Date,
        timeZone: TimeZone = .current
    ) -> URL {
        var iso = Calendar(identifier: .iso8601)
        iso.timeZone = timeZone
        let parts = iso.dateComponents([.yearForWeekOfYear, .weekOfYear, .month, .day, .hour, .minute], from: start)
        let week = String(format: "%02d-%d", parts.weekOfYear!, parts.yearForWeekOfYear!)
        let day = String(format: "%02d-%02d", parts.month!, parts.day!)
        let time = String(format: "%02dh%02d", parts.hour!, parts.minute!)
        let base = calendarFolder(calendar ?? "").map { root.appending(path: $0) } ?? root
        return base.appending(path: week).appending(path: day).appending(path: "\(time)-\(shortName(name))")
    }

    /// The calendar's name with "/" as "-", without dots or spaces at either end; nil when nothing is left.
    package static func calendarFolder(_ calendar: String) -> String? {
        let name = calendar.replacing("/", with: "-").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return name.isEmpty ? nil : name
    }

    /// "Weekly Design Review (camera on)" -> "weekly-design-review": lowercase ASCII words joined by "-", up to
    /// `maxLength` characters, leaving out whatever is in parentheses or brackets; "meeting" when nothing is left.
    package static func shortName(_ title: String, maxLength: Int = 40) -> String {
        let ascii = unbracketed(title).decomposedStringWithCompatibilityMapping.unicodeScalars.filter(\.isASCII)
        let words = String(String.UnicodeScalarView(ascii)).lowercased().matches(of: /[a-z0-9]+/).map { String($0.0) }
        var name = ""
        for word in words {
            let longer = name.isEmpty ? word : "\(name)-\(word)"
            if longer.count > maxLength { break }
            name = longer
        }
        return name.isEmpty ? "meeting" : name
    }

    /// `title` without whatever is in parentheses or brackets, each such part a space instead: "Standup (webcam ON)" ->
    /// "Standup ".
    static func unbracketed(_ title: String) -> String {
        title.replacing(/\([^)]*\)|\[[^\]]*\]/, with: " ")
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

    /// Whether the transcript at `url` has any words in it: a meeting in which nothing was recognized leaves it empty,
    /// and its recording is then all there is of it.
    package static func hasWords(transcript url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains { !$0.isWhitespace }
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
