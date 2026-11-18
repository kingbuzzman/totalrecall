import AppSupport
import Foundation
import os

/// The transcript of the latest recording, as it comes, and switching it to another language from the transcript
/// window: the recording goes on, and once the language is ready, the transcript starts over in it, from the start,
/// and catches up.
extension AppModel {
    /// The language the transcript is in, or being switched to: transcribe's default, en-US, unless set.
    var transcriptLanguage: String {
        languageSwitch?.language ?? meeting?.language ?? "en-US"
    }

    /// Switches the transcript to `language`, unless it is in it already.
    func switchLanguage(to language: String) {
        guard isRecording, language != transcriptLanguage else { return }
        log.info("switching the transcript to \(language, privacy: .public)")
        languageSwitch = .preparing(language)
        engine.switchLanguage(to: language)
    }

    /// Follows the transcript of the latest recording: its lines, and all of them again once it is over; the words
    /// still being recognized; and a switch to another language, which starts it over, its lines coming again from the
    /// start, until it catches up, or fails.
    func followTranscript(_ event: RecordingEngine.Event) {
        switch event {
        case .line(let line, let isYours):
            transcript.append(TranscriptLine(parsing: line, heardOn: isYours ? .you : .them))
        case .rewritten(let lines):
            transcript = lines.map { TranscriptLine(parsing: $0.line, heardOn: $0.isYours ? .you : .them) }
        case .liveText(let text):
            liveText = text
        case .transcriptRestarted(let language):
            transcript = []
            liveText = ""
            meeting?.switchedLanguage = language
            languageSwitch = .catchingUp(language)
        case .transcriptCaughtUp:
            languageSwitch = nil
        case .languageSwitchFailed(let language, let reason):
            // One to another language asked for since goes on.
            guard languageSwitch?.language == language else { return }
            languageSwitch = nil
            lastMessage = "Could not switch the transcript to \(language): \(reason)"
        default:
            break
        }
    }
}

/// A language, such as es-MX, as the menus show it.
enum SpeechLanguage {
    /// "Spanish (Mexico) — es-MX"; the language as it is when macOS has no name for it.
    static func name(of language: String) -> String {
        guard let name = Locale.current.localizedString(forIdentifier: language) else { return language }
        return "\(name) — \(language)"
    }

    /// The languages most often wanted, listed first, in this order, those the recognizer has.
    static let common = ["en-US", "en-GB", "es-ES", "es-MX", "fr-FR", "de-DE", "pt-BR", "it-IT", "zh-CN", "ja-JP"]

    /// The languages to pick from, in two groups: the common ones, after `current` if the recognizer does not have it,
    /// such as es, set before, which it lists only by region ("" is none); then all the others it has.
    static func options(_ languages: [String], including current: String) -> (common: [String], others: [String]) {
        let set = current.isEmpty || languages.contains(current) ? [] : [current]
        let common = common.filter(languages.contains)
        return (set + common, languages.filter { !common.contains($0) })
    }
}
