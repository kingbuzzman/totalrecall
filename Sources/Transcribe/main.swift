import AVFoundation
import CoreML
import Foundation
import Shared
import Speech

// transcribe: on-device speech to text for totalrecall recordings, from a file or live from `totalrecall -`.

func fail(_ message: String) -> Never {
    fputs("transcribe: \(message)\n", stderr)
    exit(1)
}

let command: Command
do {
    command = try Command.parse(CommandLine.arguments.dropFirst())
} catch {
    fail(error.localizedDescription)
}

let inputPath: String
let textPath: String?
let options: Options
switch command {
case .listLanguages:
    guard await speechRecognitionIsAvailable() else { fail(speechRecognitionUnavailable) }
    let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
    for locale in await SpeechTranscriber.supportedLocales.map({ $0.identifier(.bcp47) }).sorted() {
        let mark = installed.contains(locale) ? "*" : " "
        let name = Locale.current.localizedString(forIdentifier: locale) ?? locale
        print("\(mark) \(locale.padding(toLength: 8, withPad: " ", startingAt: 0)) \(name)")
    }
    exit(0)
case .listSpeakers:
    let (speakers, samples) = changingSpeakers { (try $0.speakers(), try $0.sampleCounts()) }
    if speakers.isEmpty { print("nobody yet: transcribe --identify-speakers remembers the people it hears") }
    for speaker in speakers {
        let seconds = Double(speaker.prints) * SpeakerIdentifier.hopSeconds
        let heard = seconds < 60 ? "\(Int(seconds)) s" : "\(Int((seconds / 60).rounded())) min"
        let since = speaker.createdAt.formatted(date: .abbreviated, time: .omitted)
        let number = String(speaker.id).padding(toLength: 4, withPad: " ", startingAt: 0)
        let name = (speaker.name ?? (speaker.isYou ? Speaker.you.rawValue : "-")) + (speaker.isYou ? " (you)" : "")
        let count = samples[speaker.id, default: 0]
        let sampleCount = count == 0 ? "" : count == 1 ? ", 1 sample" : ", \(count) samples"
        print("\(number) \(name)  (\(heard)\(sampleCount) since \(since))")
    }
    exit(0)
case .nameSpeaker(let speaker, let name):
    guard changingSpeakers({ try $0.rename(speaker, to: name) }) else {
        fail("no speaker \(speaker); see transcribe speakers")
    }
    exit(0)
case .mergeSpeaker(let speaker, let target):
    guard changingSpeakers({ try $0.merge(speaker, into: target) }) else {
        fail(
            speaker == target
                ? "a speaker is already part of themselves"
                : "no speaker \(speaker) or \(target); see transcribe speakers"
        )
    }
    exit(0)
case .forgetSpeaker(let speaker):
    guard changingSpeakers({ try $0.forget(speaker) }) else { fail("no speaker \(speaker); see transcribe speakers") }
    exit(0)
case .playSpeaker(let speaker):
    let samples = speakerSamples(speaker)
    for (index, sample) in samples.enumerated() {
        print("speaker \(speaker), sample \(index + 1) of \(samples.count) (\(Int(sample.seconds.rounded())) s)")
        // Played here rather than by another program, so it stops when transcribe does.
        let player: AVAudioPlayer
        do {
            player = try AVAudioPlayer(data: sample.audio, fileTypeHint: AVFileType.m4a.rawValue)
        } catch {
            fail("cannot play the sample: \(error.localizedDescription)")
        }
        guard player.play() else { fail("cannot play the sample") }
        while player.isPlaying { usleep(50_000) }
    }
    exit(0)
case .saveSpeakerSamples(let speaker, let directory):
    let samples = speakerSamples(speaker)
    let folder = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
    for (index, sample) in samples.enumerated() {
        let url = folder.appending(path: "speaker-\(speaker)-\(index + 1).m4a")
        do {
            try sample.audio.write(to: url, options: .withoutOverwriting)
        } catch {
            fail("cannot save \(url.path): \(error.localizedDescription)")
        }
        print(url.path)
    }
    exit(0)
case .help:
    print("transcribe \(version)\n\n\(usage)")
    exit(0)
case .version:
    print(version)
    exit(0)
case .transcribe(let input, let text, let parsedOptions):
    (inputPath, textPath, options) = (input, text, parsedOptions)
}
let readsStream = inputPath == "-"
let textURL = textPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }

if readsStream && isatty(STDIN_FILENO) != 0 {
    fail("nothing is piped in; - reads a live stream, e.g. totalrecall - | transcribe -")
}
if let textURL {
    let directory = textURL.deletingLastPathComponent().path
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
        fail("directory \(directory) does not exist")
    }
    if FileManager.default.fileExists(atPath: textURL.path) && !options.overwrite {
        fail("\(textURL.path) already exists (use --force to overwrite)")
    }
}

// Ctrl-C reaches every program in the pipeline, and totalrecall answers it by ending the stream. So rather than dying
// with the last words still being recognized, keep going until the stream ends and finish the transcript from it. A
// second Ctrl-C quits right away.
let stopSignals = readsStream ? finishOnStopSignals() : []

func finishOnStopSignals() -> [any DispatchSourceSignal] {
    signal(SIGPIPE, SIG_IGN)
    let queue = DispatchQueue(label: "transcribe.signals")
    nonisolated(unsafe) var isStopping = false  // only touched on `queue`
    return [SIGINT, SIGTERM, SIGHUP].map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
        source.setEventHandler {
            if isStopping { exit(128 + signalNumber) }
            isStopping = true
        }
        source.resume()
        return source
    }
}

do {
    guard await speechRecognitionIsAvailable() else { throw TranscribeError(speechRecognitionUnavailable) }
    let locale = try await speechLocale(for: options.language)
    try await installSpeechModel(for: locale)
    // Read here first, to tell the speakers apart, then by the reading task below.
    let source: any AudioSource & Sendable =
        readsStream
        ? try WAVStreamReader(handle: .standardInput)
        : try FileAudioSource(url: URL(fileURLWithPath: (inputPath as NSString).expandingTildeInPath))
    var pendingChunks: [[[Float]]] = []
    var separatesSpeakers = false
    if source.channelCount >= 2 && !options.mixesChannels {
        (separatesSpeakers, pendingChunks) = try hasSeparateSpeakers(source)
    }

    // With --identify-speakers, people are told apart by voice: on the right channel, or the one mixed channel, and on
    // your microphone, where everyone is you. It is an extra: whatever goes wrong with it is reported, and the
    // transcript goes on without it.
    var speakerModel: MLModel?
    var database: SpeakerDatabase?
    if options.identifiesSpeakers {
        do {
            speakerModel = try SpeakerModel.builtIn()
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
    let identifier = { [speakerModel, database] (name: String, isYours: Bool) -> SpeakerIdentifier? in
        guard let speakerModel else { return nil }
        do {
            return try SpeakerIdentifier(
                name: name,
                isYours: isYours,
                sampleRate: source.sampleRate,
                printer: try VoicePrinter(model: speakerModel),
                database: database,
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
    // Created only now, once transcribing can start, so a failure before it leaves no empty file behind; from here on,
    // whatever has been transcribed is in it, even if transcribe is stopped part way.
    let textFile = try textURL.map(createTextFile)
    // Each line goes out the moment it settles, in that order. For a file, the two speakers' recognizers race through
    // it independently, so their lines can come out of time order.
    let printer = TranscriptPrinter(
        printsLines: textFile == nil || options.showsLive,
        isLive: options.showsLive,
        save: textFile.map(saveLine)
    )

    try await withThrowingTaskGroup(of: Void.self) { group in
        for transcriber in transcribers {
            group.addTask { try await transcriber.run(onUpdate: printer.update) }
        }
        let chunksReadAhead = pendingChunks
        group.addTask {
            for chunk in chunksReadAhead { feed(chunk, to: transcribers) }
            let chunkFrames = Int(source.sampleRate * chunkSeconds)
            while let chunk = try source.read(maxFrames: chunkFrames) { feed(chunk, to: transcribers) }
            for transcriber in transcribers { try await transcriber.finish() }
        }
        try await group.waitForAll()
    }
    printer.finish()
    try textFile?.close()
} catch {
    fail(error.localizedDescription)
}

/// Reports a problem with `--identify-speakers`, which the transcript goes on without.
func warnAboutVoices(_ message: String) {
    fputs("transcribe: --identify-speakers: \(message)\n", stderr)
}

/// A speaker's samples, longest first, failing if there are none.
func speakerSamples(_ speaker: Int) -> [SpeakerDatabase.Sample] {
    let (exists, samples) = changingSpeakers { (try $0.speaker(speaker) != nil, try $0.samples(of: speaker)) }
    guard exists else { fail("no speaker \(speaker); see transcribe speakers") }
    guard !samples.isEmpty else {
        fail(
            "no samples of speaker \(speaker): they are kept from stretches of \(Int(SpeakerIdentifier.shortestSample)) s or more, until they have a name"
        )
    }
    return samples
}

/// Opens the speaker database for `transcribe speakers`, failing if it cannot be read or changed.
func changingSpeakers<Result>(_ change: (SpeakerDatabase) throws -> Result) -> Result {
    do {
        return try change(try SpeakerDatabase())
    } catch {
        fail(error.localizedDescription)
    }
}

/// Creates the text file, emptying it if it exists (`--force`).
func createTextFile(_ url: URL) throws -> FileHandle {
    guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
        throw TranscribeError("cannot create \(url.path)")
    }
    return try FileHandle(forWritingTo: url)
}

/// Appends each line to the text file as it settles; a failed write ends transcribe, as the transcript is incomplete.
func saveLine(to file: FileHandle) -> (String) -> Void {
    { line in
        do {
            try file.write(contentsOf: Data(line.utf8))
        } catch {
            fail("cannot write the transcript: \(error.localizedDescription)")
        }
    }
}
