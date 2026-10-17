import AVFoundation
import Accelerate
import Foundation
import Speech

/// Who is speaking, from totalrecall's channel split: your microphone on the left, everyone else on the right.
enum Speaker: String {
    case you = "You"
    case them = "Them"
}

/// A piece of transcript: volatile while the recognizer may still revise it, final once it no longer will.
struct TranscriptUpdate {
    let speaker: Speaker?
    let start: Double
    let text: String
    let isFinal: Bool
}

/// Transcribes one speaker's audio with Apple's on-device speech recognizer, reporting in-progress text as it is
/// heard and final text once the recognizer settles on it. `append` and `finish` are called from one task, the
/// results are read on another.
final class SpeakerTranscriber: @unchecked Sendable {
    let speaker: Speaker?
    let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let sourceFormat: AVAudioFormat
    private let analyzerFormat: AVAudioFormat
    private let converter: AVAudioConverter
    /// The samples to convert, reused from one `append` to the next. The converted buffer goes to the recognizer, so
    /// that one is new each time.
    private var source: AVAudioPCMBuffer?
    private let inputStream: AsyncStream<AnalyzerInput>
    private let input: AsyncStream<AnalyzerInput>.Continuation

    init(speaker: Speaker?, locale: Locale, sampleRate: Double) async throws {
        self.speaker = speaker
        transcriber = Self.makeModule(locale: locale)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
            let converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
        else {
            throw TranscribeError("the speech recognizer cannot take \(Int(sampleRate)) Hz audio")
        }
        self.analyzerFormat = analyzerFormat
        self.converter = converter
        (inputStream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
    }

    static func makeModule(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
    }

    /// Starts recognizing; results go to `onUpdate` until `finish()` has been called and the last one is in.
    func run(onUpdate: (TranscriptUpdate) -> Void) async throws {
        try await analyzer.start(inputSequence: inputStream)
        for try await result in transcriber.results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            onUpdate(
                TranscriptUpdate(
                    speaker: speaker,
                    start: result.range.start.seconds,
                    text: text,
                    isFinal: result.isFinal
                )
            )
        }
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty, let buffer = convert(samples) else { return }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends the audio; `run` returns once the recognizer has finalized the rest.
    func finish() async throws {
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    private func convert(_ samples: [Float]) -> AVAudioPCMBuffer? {
        if self.source.map({ $0.frameCapacity < samples.count }) ?? true {
            self.source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        }
        guard let source = self.source else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        source.floatChannelData![0].update(from: samples, count: samples.count)
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }
        var consumed = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return source
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

/// Hands a chunk of audio to the transcribers: one channel each, or, for a single transcriber, all channels mixed.
func feed(_ chunk: [[Float]], to transcribers: [SpeakerTranscriber]) {
    guard transcribers.count == 1 else {
        for (transcriber, channel) in zip(transcribers, chunk) { transcriber.append(channel) }
        return
    }
    transcribers[0].append(mixDown(chunk))
}

/// The average of the channels.
func mixDown(_ chunk: [[Float]]) -> [Float] {
    guard chunk.count > 1 else { return chunk.first ?? [] }
    var sum = chunk[0]
    for channel in chunk.dropFirst() { vDSP.add(sum, channel, result: &sum) }
    // Not vDSP.divide, which is not correctly rounded.
    let channelCount = Float(chunk.count)
    sum.withUnsafeMutableBufferPointer { sum in
        for frame in sum.indices { sum[frame] /= channelCount }
    }
    return sum
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
    throw TranscribeError(
        variants.isEmpty
            ? "no speech model for \(identifier); see transcribe --list-languages"
            : "no speech model for \(identifier); try \(variants.joined(separator: ", "))"
    )
}

/// Downloads the on-device speech model for this locale if it is not installed yet. Transcribers can only be made once
/// it is, as the audio format the recognizer takes comes from the model.
func installSpeechModel(for locale: Locale) async throws {
    let modules = [SpeakerTranscriber.makeModule(locale: locale)]
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
    fputs("downloading the \(locale.identifier(.bcp47)) speech model...\n", stderr)
    try await request.downloadAndInstall()
}

struct TranscribeError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}
