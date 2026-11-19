import CoreML
package import Foundation
import Shared
import Speech

/// Where a transcript goes, and who hears of what happens on the way.
struct TranscriptionOutput {
    /// Makes the printer each update goes to, given `save`, which writes a line to the text file, when there is one.
    let makePrinter: (_ save: ((String) -> Void)?) -> TranscriptPrinter
    /// Gets problems the transcript goes on without.
    let warn: (String) -> Void
    /// Gets what happened to the people it heard.
    let report: (String) -> Void
    /// Gets a failure to write the text file.
    let onSaveFailure: (any Error) -> Void
    /// Gets the recognizers once they are made, to follow how far they have listened.
    var onTranscribers: ([SpeakerTranscriber]) -> Void = { _ in }
    /// Says, once the audio has ended, whether the transcript was given up part way, to be made again: it is then not
    /// written again by who turned out to speak, nor are the people heard remembered.
    var isAbandoned: () -> Bool = { false }
}

/// Transcribes `source`, in the language of `locale`, whose speech model is installed, to the end: tells whether it has
/// totalrecall's split of you and them, starts a recognizer for each speaker, telling people apart by voice with
/// `--identify-speakers`, and hands each update to `output`'s printer. The text file, if any, is created only once
/// transcribing can start, so a failure before then leaves no empty file behind; from then on, whatever has been
/// transcribed is in it, line by line. Telling people apart, it is written again at the end, each line said by whoever
/// turned out to say it, now that all of them have been heard.
func transcribe(
    _ source: any AudioSource & Sendable,
    locale: Locale,
    options: Options,
    textURL: URL?,
    output: TranscriptionOutput
) async throws {
    var pendingChunks: [[[Float]]] = []
    var separatesSpeakers = options.isSplit
    if !options.isSplit && source.channelCount >= 2 && !options.mixesChannels {
        (separatesSpeakers, pendingChunks) = try hasSeparateSpeakers(source)
    }
    let voices = await Voices.load(if: options.identifiesSpeakers, from: options.speakers, warn: output.warn)
    let transcribers = try await makeTranscribers(
        for: source,
        locale: locale,
        separatesSpeakers: separatesSpeakers,
        voices: voices
    )
    output.onTranscribers(transcribers)
    let textFile = try textURL.map(createTextFile)
    // Each line goes out the moment it settles, in that order. For a file, the two speakers' recognizers race through
    // it independently, so their lines can come out of time order.
    let printer = output.makePrinter(textFile.map { saveLine(to: $0, onFailure: output.onSaveFailure) })
    // Nor are what it picks up of what they say lines of yours.
    let echoes = separatesSpeakers ? Echoes(sampleRate: source.sampleRate, printer: printer) : nil
    try await run(transcribers, on: source, readAhead: pendingChunks, printer: printer, echoes: echoes)
    printer.finish()
    try textFile?.close()
    let identifiers = transcribers.compactMap(\.identifier)
    guard !identifiers.isEmpty, !output.isAbandoned() else { return }
    for identifier in identifiers { identifier.conclude() }
    let text = printer.rewritten { line in
        transcribers.first { $0.speaker == line.speaker }?.identifier?.parts(of: line) ?? [line]
    }
    if let textURL {
        do {
            try Data(text.utf8).write(to: textURL, options: .atomic)
        } catch {
            output.onSaveFailure(error)
        }
    }
    voices.tidyUp(report: output.report)
}

/// With --identify-speakers, people are told apart by voice: on the right channel, or the one mixed channel, and on
/// your microphone, where everyone is you. It is an extra: whatever goes wrong with it is reported, and the transcript
/// goes on without it.
private struct Voices {
    /// The voice print model and the who-talks-when one.
    let models: (prints: MLModel, segmentation: MLModel)?
    let database: SpeakerDatabase?
    let warn: (String) -> Void

    /// The speaker models and the database at `url` of the people heard before, when `identifiesSpeakers`.
    static func load(if identifiesSpeakers: Bool, from url: URL, warn: @escaping (String) -> Void) async -> Voices {
        let warnAboutVoices = { (message: String) in warn("--identify-speakers: \(message)") }
        guard identifiesSpeakers else { return Voices(models: nil, database: nil, warn: warnAboutVoices) }
        let models: (MLModel, MLModel)
        do {
            models = (try await SpeakerModel.builtIn(), try await SpeakerModel.builtInSegmentation())
        } catch {
            warnAboutVoices("cannot tell voices apart: \(error.localizedDescription)")
            return Voices(models: nil, database: nil, warn: warnAboutVoices)
        }
        do {
            return Voices(models: models, database: try SpeakerDatabase(url: url), warn: warnAboutVoices)
        } catch {
            warnAboutVoices("speakers are not being remembered: \(error.localizedDescription)")
            return Voices(models: models, database: nil, warn: warnAboutVoices)
        }
    }

    /// A speaker's identifier, or nil without the model or when it cannot be made.
    func identifier(
        name: String,
        isYours: Bool,
        sampleRate: Double,
        speechTimes: SpeechTimes?,
        otherSpeechTimes: SpeechTimes?
    ) -> SpeakerIdentifier? {
        guard let models else { return nil }
        do {
            return try SpeakerIdentifier(
                name: name,
                isYours: isYours,
                sampleRate: sampleRate,
                segmenter: try Segmenter(model: models.segmentation),
                printer: try VoicePrinter(model: models.prints),
                database: database,
                speechTimes: speechTimes,
                otherSpeechTimes: otherSpeechTimes,
                warn: warn
            )
        } catch {
            warn(error.localizedDescription)
            return nil
        }
    }

    /// Once the transcript is done: merges those heard as two people who turn out to be one, now that more of them has
    /// been heard.
    func tidyUp(report: (String) -> Void) {
        do {
            for (merged, kept) in try database?.unify() ?? [] {
                let name = kept.name.map { " (\($0))" } ?? ""
                report("speaker \(merged.id) sounds the same as \(kept.id)\(name): merged them")
            }
        } catch {
            warn("cannot merge speakers: \(error.localizedDescription)")
        }
    }
}

/// A recognizer for each speaker: you and them, with totalrecall's split, or one for everyone. What your microphone
/// picks up from the speakers while the system audio has speech is not taken for anyone's voice.
private func makeTranscribers(
    for source: any AudioSource,
    locale: Locale,
    separatesSpeakers: Bool,
    voices: Voices
) async throws -> [SpeakerTranscriber] {
    let systemSpeech = SpeechTimes()
    func transcriber(_ speaker: Speaker?, name: String) async throws -> SpeakerTranscriber {
        let isYours = speaker == .you
        let identifier = voices.identifier(
            name: name,
            isYours: isYours,
            sampleRate: source.sampleRate,
            speechTimes: separatesSpeakers && !isYours ? systemSpeech : nil,
            otherSpeechTimes: separatesSpeakers && isYours ? systemSpeech : nil
        )
        return try await SpeakerTranscriber(
            speaker: speaker,
            locale: locale,
            sampleRate: source.sampleRate,
            identifier: identifier
        )
    }
    guard separatesSpeakers else { return [try await transcriber(nil, name: "Speaker")] }
    return [try await transcriber(.you, name: "Them"), try await transcriber(.them, name: "Them")]
}

/// With totalrecall's split, what keeps what your microphone picks up from the speakers out of your lines: how loud each
/// channel is, and the filter that goes by it and by what they said.
private struct Echoes: Sendable {
    let levels: ChannelLevels
    let filter: EchoFilter

    init(sampleRate: Double, printer: TranscriptPrinter) {
        levels = ChannelLevels(sampleRate: sampleRate)
        filter = EchoFilter(levels: levels, pass: printer.update)
    }
}

/// Feeds `source`, after the chunks already read from it, to the transcribers, each running in a task of its own, until
/// they have all finished; their updates go to the printer, through the echo filter when there is one.
private func run(
    _ transcribers: [SpeakerTranscriber],
    on source: any AudioSource & Sendable,
    readAhead: [[[Float]]],
    printer: TranscriptPrinter,
    echoes: Echoes?
) async throws {
    let levels = echoes?.levels
    try await withThrowingTaskGroup(of: Void.self) { group in
        for transcriber in transcribers {
            group.addTask {
                guard let echoes = echoes?.filter else { return try await transcriber.run(onUpdate: printer.update) }
                guard transcriber.speaker == .them else { return try await transcriber.run(onUpdate: echoes.update) }
                try await transcriber.run(
                    onUpdate: echoes.update,
                    onRecognized: echoes.theirs,
                    onHeard: echoes.theyHaveBeenHeard
                )
                echoes.theyHaveFinished()
            }
        }
        group.addTask {
            for chunk in readAhead {
                levels?.add(chunk)
                feed(chunk, to: transcribers)
            }
            let chunkFrames = Int(source.sampleRate * chunkSeconds)
            while let chunk = try source.read(maxFrames: chunkFrames) {
                levels?.add(chunk)
                feed(chunk, to: transcribers)
            }
            for transcriber in transcribers { try await transcriber.finish() }
        }
        try await group.waitForAll()
    }
}

/// Checks that this Mac can transcribe `language` (nil or "" for en-US), and downloads its speech model if need be, so
/// that the first recording's transcript does not wait for it.
package func prepareTranscription(language: String?) async throws {
    _ = try await readySpeechLocale(for: language?.nonEmpty ?? Options().language)
}

/// The languages the speech recognizer has, such as en-US and es-MX, in order.
package func speechLanguages() async -> [String] {
    Array(Set(await SpeechTranscriber.supportedLocales.map { $0.identifier(.bcp47) })).sorted()
}

/// The audio files `learnVoices` reads: what TotalRecall saves recordings as, and the other formats macOS reads.
package let voiceFileExtensions: Set<String> = [
    "mp3", "m4a", "mp4", "aac", "wav", "wave", "aif", "aiff", "caf", "flac",
]

/// Tells apart the people in the audio file at `url` and remembers them in the database at `speakers`, as a recording
/// with Identify Speakers does, without writing a transcript; the speech is still recognized, as only those who say
/// words are kept. `onMessage` hears of problems it goes on without.
package func learnVoices(
    from url: URL,
    language: String?,
    speakers: URL,
    onMessage: @escaping @Sendable (String) -> Void
) async throws {
    var options = Options()
    options.language = language?.nonEmpty ?? options.language
    options.identifiesSpeakers = true
    options.speakers = speakers
    let locale = try await readySpeechLocale(for: options.language)
    let output = TranscriptionOutput(
        makePrinter: { _ in TranscriptPrinter(printsLines: false, isLive: false) },
        warn: onMessage,
        report: onMessage,
        onSaveFailure: { _ in }
    )
    try await transcribe(try FileAudioSource(url: url), locale: locale, options: options, textURL: nil, output: output)
}

/// Creates the text file, emptying it if it exists (`--force`).
func createTextFile(_ url: URL) throws -> FileHandle {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw MessageError("cannot create \(url.path)")
    }
    return try FileHandle(forWritingTo: url)
}

/// Appends each line to the text file as it settles, calling `onFailure` when a write fails.
func saveLine(to file: FileHandle, onFailure: @escaping (any Error) -> Void) -> (String) -> Void {
    { line in
        do {
            try file.write(contentsOf: Data(line.utf8))
        } catch {
            onFailure(error)
        }
    }
}
