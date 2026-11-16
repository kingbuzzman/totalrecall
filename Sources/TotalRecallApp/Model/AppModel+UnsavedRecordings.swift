import AppSupport
import Foundation
import Shared
import TotalRecall
import Transcribe
import os

/// What goes on around the recordings: the speech model, downloaded ahead, and recordings a crash left unsaved.
extension AppModel {
    /// Downloads the speech model in the background, if need be, so the first transcript does not wait for it.
    func prepareTranscription() {
        let language = AppSettings.language
        let log = log
        Task.detached(priority: .utility) {
            do {
                try await Transcribe.prepareTranscription(language: language)
            } catch {
                log.error("cannot transcribe: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Looks for recordings a crash or a forced quit left unsaved, in the background, for the menu to offer saving.
    /// One written to in the last two minutes is left out: it may be a recording `record-meetings` is making right now.
    /// So is one whose output file exists, which saving it would replace.
    func findUnsavedRecordings() {
        let root = AppSettings.recordingsFolder
        Task.detached(priority: .utility) { [weak self] in
            let cutoff = Date().addingTimeInterval(-120)
            let unsaved = RecordingFolder.unsavedRecordings(under: root).filter { partial, output in
                let modified = try? partial.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate
                return (modified.map { $0 < cutoff } ?? false) && !FileManager.default.fileExists(atPath: output.path)
            }
            await MainActor.run { self?.unsavedRecordings = unsaved }
        }
    }

    /// Saves the recordings `findUnsavedRecordings()` found, in the background, converting each partial recording to
    /// the format its name asks for, and deleting it once saved.
    func saveUnsavedRecordings() {
        let unsaved = unsavedRecordings
        unsavedRecordings = []
        savingCount += unsaved.count
        let (notifier, log) = (notifier, log)
        for (partial, output) in unsaved {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let file = OutputFile(path: output.path)
                do {
                    guard !FileManager.default.fileExists(atPath: output.path) else {
                        throw MessageError("\(output.lastPathComponent) already exists")
                    }
                    try file.save()
                    if let encoding = file.encodingURL { try? FileManager.default.removeItem(at: encoding) }
                    notifier.post(title: "Saved an unsaved recording", body: output.path, revealing: output)
                } catch {
                    log.error(
                        "could not save \(partial.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                    notifier.post(
                        title: "Could not save an unsaved recording",
                        body: "\(partial.path): \(error.localizedDescription)"
                    )
                }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.savingCount -= 1
                        self?.becameIdleIfDone()
                    }
                }
            }
        }
    }
}
