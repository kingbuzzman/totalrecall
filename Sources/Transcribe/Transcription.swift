import CoreML
package import Foundation
import Shared

/// Transcribes `source`, in the language of `locale`, whose speech model is installed, to the end: tells whether it has totalrecall's split of you and them, starts a recognizer for
/// each speaker, telling people apart by voice with `--identify-speakers`, and hands each update to the printer
/// `makePrinter` makes. The text file, if any, is created only once transcribing can start, so a failure before then
/// leaves no empty file behind; from then on, whatever has been transcribed is in it, line by line.
///
/// `warn` gets problems the transcript goes on without, `report` what happened to the people it heard, and
/// `onSaveFailure` a failure to write the text file.
func transcribe(
    _ source: any AudioSource & Sendable,
    locale: Locale,
    options: Options,
    textURL: URL?,
    makePrinter: (_ save: ((String) -> Void)?) -> TranscriptPrinter,
    warn: @escaping (String) -> Void,
    report: (String) -> Void,
    onSaveFailure: @escaping (any Error) -> Void
) async throws {
    var pendingChunks: [[[Float]]] = []
    var separatesSpeakers = false
    if source.channelCount >= 2 && !options.mixesChannels {
        (separatesSpeakers, pendingChunks) = try hasSeparateSpeakers(source)
    }

    // With --identify-speakers, people are told apart by voice: on the right channel, or the one mixed channel, and on
    // your microphone, where everyone is you. It is an extra: whatever goes wrong with it is reported, and the
    // transcript goes on without it.
    let warnAboutVoices = { (message: String) in warn("--identify-speakers: \(message)") }
    var speakerModel: MLModel?
    var database: SpeakerDatabase?
    if options.identifiesSpeakers {
        do {
            speakerModel = try await SpeakerModel.builtIn()
        } catch {
            warnAboutVoices("cannot tell voices apart: \(error.localizedDescription)")
        }
    }
    if speakerModel != nil {
        do {
            database = try SpeakerDatabase()
        } catch {
            warnAboutVoices("speakers are not being remembered: \(error.localizedDescription)")
        }
    }
    // What your microphone picks up from the speakers while the system audio has speech is not taken for anyone's voice.
    let systemSpeech = SpeechTimes()
    let identifier = {
        [speakerModel, database, separatesSpeakers] (name: String, isYours: Bool) -> SpeakerIdentifier? in
        guard let speakerModel else { return nil }
        do {
            return try SpeakerIdentifier(
                name: name,
                isYours: isYours,
                sampleRate: source.sampleRate,
                printer: try VoicePrinter(model: speakerModel),
                database: database,
                speechTimes: separatesSpeakers && !isYours ? systemSpeech : nil,
                otherSpeechTimes: separatesSpeakers && isYours ? systemSpeech : nil,
                warn: warnAboutVoices
            )
        } catch {
            warnAboutVoices(error.localizedDescription)
            return nil
        }
    }
    let transcribers =
        separatesSpeakers
        ? [
            try await SpeakerTranscriber(
                speaker: .you,
                locale: locale,
                sampleRate: source.sampleRate,
                identifier: identifier("Them", true)
            ),
            try await SpeakerTranscriber(
                speaker: .them,
                locale: locale,
                sampleRate: source.sampleRate,
                identifier: identifier("Them", false)
            ),
        ]
        : [
            try await SpeakerTranscriber(
                speaker: nil,
                locale: locale,
                sampleRate: source.sampleRate,
                identifier: identifier("Speaker", false)
            )
        ]
    let textFile = try textURL.map(createTextFile)
    // Each line goes out the moment it settles, in that order. For a file, the two speakers' recognizers race through
    // it independently, so their lines can come out of time order.
    let printer = makePrinter(textFile.map { saveLine(to: $0, onFailure: onSaveFailure) })

    // Nor are what it picks up of what they say lines of yours.
    let levels = separatesSpeakers ? ChannelLevels(sampleRate: source.sampleRate) : nil
    let echoes = separatesSpeakers ? EchoFilter(levels: levels, pass: printer.update) : nil

    try await withThrowingTaskGroup(of: Void.self) { group in
        for transcriber in transcribers {
            group.addTask {
                guard let echoes else { return try await transcriber.run(onUpdate: printer.update) }
                guard transcriber.speaker == .them else { return try await transcriber.run(onUpdate: echoes.update) }
                try await transcriber.run(
                    onUpdate: echoes.update,
                    onRecognized: echoes.theirs,
                    onHeard: echoes.theyHaveBeenHeard
                )
                echoes.theyHaveFinished()
            }
        }
        let chunksReadAhead = pendingChunks
        group.addTask {
            for chunk in chunksReadAhead {
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
    printer.finish()
    try textFile?.close()
    for forgotten in transcribers.compactMap(\.identifier).flatMap({ $0.forgetThoseWhoSaidTooLittle() }) {
        report("speaker \(forgotten) said too few words for how long they were heard: forgot them")
    }
    // Some heard as two people may turn out to be one, now that more of them has been heard.
    do {
        for (merged, kept) in try database?.unify() ?? [] {
            let name = kept.name.map { " (\($0))" } ?? ""
            report("speaker \(merged.id) sounds the same as \(kept.id)\(name): merged them")
        }
    } catch {
        warnAboutVoices("cannot merge speakers: \(error.localizedDescription)")
    }
}

/// Checks that this Mac can transcribe `language` (nil or "" for en-US), and downloads its speech model if need be, so
/// that the first recording's transcript does not wait for it.
package func prepareTranscription(language: String?) async throws {
    guard await speechRecognitionIsAvailable() else { throw TranscribeError(speechRecognitionUnavailable) }
    let locale = try await speechLocale(for: language.flatMap { $0.isEmpty ? nil : $0 } ?? Options().language)
    try await installSpeechModel(for: locale)
}

/// A live transcript of the WAV stream `input` carries, such as the one a recording made in the same app writes into
/// a pipe, until the stream ends: each line, as it settles, goes to `textURL` and `onLine`, and the words still being
/// recognized to `onLiveText`, with "" once there are none. `onMessage` gets warnings and news of the people it heard.
/// Throws if transcribing cannot start or fails part way; the text file then has what was transcribed until then.
package func transcribeLive(
    from input: FileHandle,
    to textURL: URL,
    language: String?,
    identifiesSpeakers: Bool,
    onLine: @escaping @Sendable (String) -> Void,
    onLiveText: @escaping @Sendable (String) -> Void,
    onMessage: @escaping @Sendable (String) -> Void
) async throws {
    guard await speechRecognitionIsAvailable() else { throw TranscribeError(speechRecognitionUnavailable) }
    var options = Options()
    if let language, !language.isEmpty { options.language = language }
    options.identifiesSpeakers = identifiesSpeakers
    let locale = try await speechLocale(for: options.language)
    try await installSpeechModel(for: locale)
    let source = try WAVStreamReader(handle: input)
    try await transcribe(
        source,
        locale: locale,
        options: options,
        textURL: textURL,
        makePrinter: { save in
            TranscriptPrinter(
                printsLines: false,
                isLive: false,
                save: { line in
                    save?(line)
                    onLine(line.trimmingCharacters(in: .newlines))
                },
                showLive: onLiveText
            )
        },
        warn: onMessage,
        report: onMessage,
        onSaveFailure: { onMessage("cannot write the transcript: \($0.localizedDescription)") }
    )
}

/// Creates the text file, emptying it if it exists (`--force`).
func createTextFile(_ url: URL) throws -> FileHandle {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw TranscribeError("cannot create \(url.path)")
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
