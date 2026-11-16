package import os

/// Where totalrecall, transcribe and TotalRecall.app log, so one place has all of them: `log show --predicate
/// 'subsystem == "local.totalrecall"'`, or Console.app. Failures are logged as errors, which macOS keeps; the rest as
/// info, which it shows as it happens, and does not keep.
package enum Log {
    package static let subsystem = "local.totalrecall"

    /// Capturing and saving recordings.
    package static let recording = Logger(subsystem: subsystem, category: "recording")
    /// Recognizing speech.
    package static let transcript = Logger(subsystem: subsystem, category: "transcript")
    /// Telling people apart by voice, and remembering them.
    package static let speakers = Logger(subsystem: subsystem, category: "speakers")
    /// The menu bar app itself: its settings, windows and calendar.
    package static let app = Logger(subsystem: subsystem, category: "app")
}
