import Foundation
import Observation
import Shared
import Transcribe
import os

/// The speech recognizer's languages, to switch a transcript to, and their models, downloaded ahead of a recording in
/// them so its transcript does not wait for one.
@MainActor @Observable
final class SpeechModels {
    /// The languages the recognizer has, such as en-US and es-MX; read once, in the background.
    private(set) var languages: [String] = []
    /// The languages whose model was got ready, or tried.
    @ObservationIgnored private var prepared: Set<String> = []
    @ObservationIgnored private let log = Log.recording

    init() {
        Task { [weak self] in
            let languages = await Transcribe.speechLanguages()
            self?.languages = languages
        }
    }

    /// Downloads the models of `languages` in the background, if need be, each only once; nil, or blank, is
    /// transcribe's default, en-US.
    func prepare(_ languages: [String?]) {
        let languages = Set(languages.map { $0?.trimmingCharacters(in: .whitespaces).nonEmpty ?? "" })
            .subtracting(prepared)
        guard !languages.isEmpty else { return }
        prepared.formUnion(languages)
        let log = log
        Task.detached(priority: .utility) {
            for language in languages.sorted() {
                do {
                    try await Transcribe.prepareTranscription(language: language)
                } catch {
                    log.error(
                        "cannot transcribe \(language.nonEmpty ?? "en-US", privacy: .public): \(error.localizedDescription, privacy: .public)"
                    )
                }
            }
        }
    }
}
