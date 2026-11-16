import AVFoundation
import Accelerate
import Foundation
import Shared
import Speech

/// Who is speaking, from totalrecall's channel split: your microphone on the left, everyone else on the right.
enum Speaker: String {
    case you = "You"
    case them = "Them"
}

/// A word of a line, with what follows it up to the next word, such as a space or punctuation, and when it was said.
struct TimedWord: Equatable {
    var text: String
    let start: Double
    let end: Double
}

/// A piece of transcript: volatile while the recognizer may still revise it, final once it no longer will.
struct TranscriptUpdate {
    let speaker: Speaker?
    var start: Double
    var text: String
    let isFinal: Bool
    /// Which of the people on the speaker's channel it is, such as "Them 2", with `--identify-speakers`.
    var voice: String?
    /// Where a final line ends, when it is known.
    var end: Double?
    /// A final line's words, in order, when the recognizer says when each was said: they make up its text.
    var words: [TimedWord] = []
    /// Where the line this is part of starts, split where who speaks changes (`SpeakerIdentifier.parts(of:)`).
    var lineStart: Double?
    /// A final line held back a while, to say who spoke it or whether it is an echo, sent ahead so its words can go on
    /// showing until it comes. A final line without words then says it never will.
    var isHeld = false
}

/// Transcribes one speaker's audio with Apple's on-device speech recognizer, reporting in-progress text as it is
/// heard and final text once the recognizer settles on it. `append` and `finish` are called from one task, the
/// results are read on another.
final class SpeakerTranscriber: @unchecked Sendable {
    let speaker: Speaker?
    /// Tells apart the people on this channel, with `--identify-speakers`.
    let identifier: SpeakerIdentifier?
    let transcriber: SpeechTranscriber
    private let analyzer: SpeechAnalyzer
    private let sourceFormat: AVAudioFormat
    private let analyzerFormat: AVAudioFormat
    private let converter: AVAudioConverter
    /// The samples to convert, reused from one `append` to the next. The converted buffer goes to the recognizer, so
    /// that one is new each time.
    private var source: AVAudioPCMBuffer?
    private let converterInput = ConverterInput()
    private let inputStream: AsyncStream<AnalyzerInput>
    private let input: AsyncStream<AnalyzerInput>.Continuation

    init(speaker: Speaker?, locale: Locale, sampleRate: Double, identifier: SpeakerIdentifier? = nil) async throws {
        self.speaker = speaker
        self.identifier = identifier
        transcriber = Self.makeModule(locale: locale)
        analyzer = SpeechAnalyzer(modules: [transcriber])
        sourceFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        guard
            let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
            let converter = AVAudioConverter(from: sourceFormat, to: analyzerFormat)
        else {
            throw MessageError("the speech recognizer cannot take \(Int(sampleRate)) Hz audio")
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

    /// Starts recognizing; results go to `onUpdate` until `finish()` has been called and the last one is in. With an
    /// identifier, only a final line says who spoke it, once who did is settled (`SpeakerIdentifier.settle`), so it
    /// comes a few seconds later than it would, while the words still being recognized go on showing under the
    /// channel's name. `onRecognized` gets every update the moment the recognizer makes it, and `onHeard` how far into
    /// the audio it has listened, as it goes on, speech or not.
    func run(
        onUpdate: @escaping @Sendable (TranscriptUpdate) -> Void,
        onRecognized: (@Sendable (TranscriptUpdate) -> Void)? = nil,
        onHeard: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        if let onHeard {
            await analyzer.setVolatileRangeChangedHandler { range, _, _ in onHeard(range.end.seconds) }
        }
        try await analyzer.start(inputSequence: inputStream)
        let (lines, line) = AsyncStream.makeStream(of: TranscriptUpdate.self)
        async let labeled: Void = label(lines, onUpdate: onUpdate)
        for try await result in transcriber.results {
            let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            var update = TranscriptUpdate(
                speaker: speaker,
                start: result.range.start.seconds,
                text: text,
                isFinal: result.isFinal
            )
            if result.isFinal {
                update.end = result.range.end.seconds
                update.words = Self.words(of: result.text)
            }
            onRecognized?(update)
            if result.isFinal, identifier != nil {
                var held = update
                held.isHeld = true
                onUpdate(held)
                line.yield(update)
            } else {
                onUpdate(update)
            }
        }
        line.finish()
        await labeled
    }

    /// Says who spoke each line, in order, once it is settled: split where who speaks changes.
    private func label(_ lines: AsyncStream<TranscriptUpdate>, onUpdate: (TranscriptUpdate) -> Void) async {
        guard let identifier else { return }
        for await update in lines {
            await identifier.settle(through: update.end ?? update.start)
            // Not for bare punctuation, which is no one's words.
            guard update.text.hasWords else {
                onUpdate(update)
                continue
            }
            for part in identifier.parts(of: update) { onUpdate(part) }
        }
    }

    /// The words of a line, by the times the recognizer gives them; none if it gives none. What has no time of its
    /// own, such as a space or punctuation, goes with the word before it.
    static func words(of text: AttributedString) -> [TimedWord] {
        var words: [TimedWord] = []
        var leading = ""
        for run in text.runs {
            let piece = String(text[run.range].characters)
            if let range = run.audioTimeRange {
                words.append(TimedWord(text: leading + piece, start: range.start.seconds, end: range.end.seconds))
                leading = ""
            } else if words.isEmpty {
                leading += piece
            } else {
                words[words.count - 1].text += piece
            }
        }
        return words
    }

    func append(_ samples: [Float]) {
        guard !samples.isEmpty else { return }
        // Before the recognizer hears it, so who is speaking is known by the time it settles on what they said.
        identifier?.append(samples)
        guard let buffer = convert(samples) else { return }
        input.yield(AnalyzerInput(buffer: buffer))
    }

    /// Ends the audio; `run` returns once the recognizer has finalized the rest.
    func finish() async throws {
        identifier?.finish()
        input.finish()
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    }

    private func convert(_ samples: [Float]) -> AVAudioPCMBuffer? {
        self.source = .reusing(self.source, format: sourceFormat, frameCapacity: AVAudioFrameCount(samples.count))
        guard let source = self.source else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        source.floatChannelData![0].update(from: samples, count: samples.count)
        let ratio = analyzerFormat.sampleRate / sourceFormat.sampleRate
        let capacity = AVAudioFrameCount((Double(samples.count) * ratio).rounded(.up)) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: capacity) else { return nil }
        let error = converterInput.convert(source, with: converter, into: output)
        return error == nil && output.frameLength > 0 ? output : nil
    }
}

/// Hands a chunk of audio to the transcribers: one channel each, or, for a single transcriber, all channels mixed.
func feed(_ chunk: [[Float]], to transcribers: [SpeakerTranscriber]) {
    guard transcribers.count == 1 else {
        // The system audio first, so your microphone's identifier knows when it had speech.
        for (transcriber, channel) in zip(transcribers, chunk).reversed() { transcriber.append(channel) }
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
