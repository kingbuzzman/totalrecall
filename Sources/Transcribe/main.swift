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

    let transcribers =
        separatesSpeakers
        ? [
            try await SpeakerTranscriber(speaker: .you, locale: locale, sampleRate: source.sampleRate),
            try await SpeakerTranscriber(speaker: .them, locale: locale, sampleRate: source.sampleRate),
        ]
        : [try await SpeakerTranscriber(speaker: nil, locale: locale, sampleRate: source.sampleRate)]
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
