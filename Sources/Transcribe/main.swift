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
let isLive = inputPath == "-"
let textURL = textPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }

// Ctrl-C reaches every program in the pipeline, and totalrecall answers it by ending the stream. So rather than dying
// with the last words still being recognized (and, with a <text-file>, nothing written), keep going until the stream
// ends and finish the transcript from it. A second Ctrl-C quits right away.
let stopSignals = isLive ? finishOnStopSignals() : []

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
    let locale = try await speechLocale(for: options.language)
    try await installSpeechModel(for: locale)
    // Read here first, to tell the speakers apart, then by the reading task below.
    let source: any AudioSource & Sendable =
        isLive
        ? try StreamAudioSource(handle: .standardInput)
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
    // Live, lines are printed as they are spoken; for a file, the recognizers race ahead independently, so the
    // transcript is printed in time order at the end.
    let printer = TranscriptPrinter(printsLines: isLive && textURL == nil, isLive: isLive)

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
    if let textURL {
        try printer.transcript.write(to: textURL, atomically: true, encoding: .utf8)
    } else if !isLive {
        print(printer.transcript, terminator: "")
    }
} catch {
    fail(error.localizedDescription)
}
