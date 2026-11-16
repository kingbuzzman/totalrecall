import Foundation
import Shared
import Speech

let speechRecognitionUnavailable = "on-device speech recognition is not available on this Mac"

/// Whether this Mac can transcribe at all. Some cannot, such as the virtual machines CI runs on: the recognizer is
/// either unavailable outright or offers no languages, which would otherwise read as a missing model for every one.
func speechRecognitionIsAvailable() async -> Bool {
    guard SpeechTranscriber.isAvailable else { return false }
    return !(await SpeechTranscriber.supportedLocales.isEmpty)
}

/// The recognizer's locale for a `--language` value such as `es` or `es-MX`. A language without a region is
/// recognized with the Mac's region if the recognizer has it (`es` on a US Mac is es-US), else the language's main
/// region (es-ES), else any region it has for the language.
func speechLocale(for identifier: String) async throws -> Locale {
    try speechLocale(
        for: identifier,
        among: await SpeechTranscriber.supportedLocales,
        currentRegion: Locale.current.region
    )
}

func speechLocale(for identifier: String, among supported: [Locale], currentRegion: Locale.Region?) throws -> Locale {
    let wanted = Locale.Language(identifier: identifier)
    let sameLanguage = supported.sorted { $0.identifier < $1.identifier }
        .filter { $0.language.languageCode == wanted.languageCode }
    let regions =
        wanted.region.map { [$0] }
        ?? [currentRegion, Locale.Language(identifier: wanted.maximalIdentifier).region].compactMap { $0 }
    for region in regions {
        if let locale = sameLanguage.first(where: { $0.region == region }) { return locale }
    }
    if wanted.region == nil, let locale = sameLanguage.first { return locale }
    let variants = sameLanguage.map { $0.identifier(.bcp47) }
    throw MessageError(
        variants.isEmpty
            ? "no speech model for \(identifier); see transcribe --list-languages"
            : "no speech model for \(identifier); try \(variants.joined(separator: ", "))"
    )
}

/// Checks that this Mac can transcribe, and gives the recognizer's locale for `language`, with its speech model
/// downloaded if need be.
func readySpeechLocale(for language: String) async throws -> Locale {
    guard await speechRecognitionIsAvailable() else { throw MessageError(speechRecognitionUnavailable) }
    let locale = try await speechLocale(for: language)
    try await installSpeechModel(for: locale)
    return locale
}

/// Downloads the on-device speech model for this locale if it is not installed yet. Transcribers can only be made once
/// it is, as the audio format the recognizer takes comes from the model.
func installSpeechModel(for locale: Locale) async throws {
    let modules = [SpeakerTranscriber.makeModule(locale: locale)]
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
    fputs("downloading the \(locale.identifier(.bcp47)) speech model...\n", stderr)
    try await request.downloadAndInstall()
}
