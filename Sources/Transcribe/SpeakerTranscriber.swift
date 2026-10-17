import AVFoundation
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
    private let inputStream: AsyncStream<AnalyzerInput>
    private let input: AsyncStream<AnalyzerInput>.Continuation

    init(speaker: Speaker?, locale: Locale, sampleRate: Double) async throws {
        self.speaker = speaker
        transcriber = SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [.audioTimeRange]
        )
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
        guard let source = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return nil }
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
    let mixed =
        chunk.count == 1
        ? chunk[0]
        : (0..<chunk[0].count).map { frame in chunk.reduce(0) { $0 + $1[frame] } / Float(chunk.count) }
    transcribers[0].append(mixed)
}

/// Downloads the on-device speech model for these transcribers if it is not installed yet.
func installSpeechModel(for transcribers: [SpeakerTranscriber]) async throws {
    let modules = transcribers.map(\.transcriber)
    guard let request = try await AssetInventory.assetInstallationRequest(supporting: modules) else { return }
    fputs("downloading the speech model...\n", stderr)
    try await request.downloadAndInstall()
}

struct TranscribeError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}
