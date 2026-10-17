import Foundation

// transcribe: on-device speech to text for totalrecall recordings, from a file or live from `totalrecall -`.

let usage = """
    usage: transcribe [--mix] <audio-file | -> [<text-file>]
           transcribe --version

    Transcribes speech on-device with Apple's speech recognizer (English). With - it reads a live WAV stream from
    stdin, such as totalrecall -, and prints the text as it is spoken; otherwise it transcribes the audio file.
    Prints the transcript, or writes it to <text-file>.
    Recordings with totalrecall's channel split (your mic left, everyone else right) are labeled You and Them.

      --mix     transcribe both channels together, without speaker labels
    """

/// Audio is read and handed to the recognizers in chunks of this length.
let chunkSeconds = 0.1
/// To tell totalrecall's channel split from a mixed recording, listen until there has been this much sound.
let speakerDetectionSeconds = 1.0
let maxSpeakerDetectionSeconds = 10.0

func fail(_ message: String) -> Never {
    fputs("transcribe: \(message)\n", stderr)
    exit(1)
}

/// Whether a stereo source has different audio on its two channels (totalrecall's split: you left, everyone else
/// right) rather than the same on both (a mixed or system-only recording). Returns the chunks it read on the way, so
/// they can still be transcribed.
func hasSeparateSpeakers(_ source: AudioSource) throws -> (Bool, [[[Float]]]) {
    let chunkFrames = Int(source.sampleRate * chunkSeconds)
    var chunks: [[[Float]]] = []
    var (framesRead, soundFrames) = (0, 0)
    while let chunk = try source.read(maxFrames: chunkFrames) {
        chunks.append(chunk)
        let (left, right) = (chunk[0], chunk[1])
        if zip(left, right).contains(where: { $0 != $1 }) { return (true, chunks) }
        framesRead += left.count
        soundFrames += left.count(where: { $0 != 0 })
        if Double(soundFrames) >= source.sampleRate * speakerDetectionSeconds
            || Double(framesRead) >= source.sampleRate * maxSpeakerDetectionSeconds
        {
            return (false, chunks)
        }
    }
    return (false, chunks)
}

var arguments = CommandLine.arguments.dropFirst()
var mixesChannels = false
var paths: [String] = []
while let argument = arguments.popFirst() {
    switch argument {
    case "--mix": mixesChannels = true
    case "-h", "--help":
        print("transcribe \(version)\n\n\(usage)")
        exit(0)
    case "--version":
        print(version)
        exit(0)
    default:
        guard argument == "-" || !argument.hasPrefix("-") else { fail("unexpected argument \(argument)\n\(usage)") }
        paths.append(argument)
    }
}
guard (1...2).contains(paths.count) else { fail("expected an audio file or -\n\(usage)") }
let isLive = paths[0] == "-"
let textURL = paths.count == 2 ? URL(fileURLWithPath: (paths[1] as NSString).expandingTildeInPath) : nil

do {
    let source: AudioSource =
        isLive
        ? try StreamAudioSource(handle: .standardInput)
        : try FileAudioSource(url: URL(fileURLWithPath: (paths[0] as NSString).expandingTildeInPath))
    var pendingChunks: [[[Float]]] = []
    var separatesSpeakers = false
    if source.channelCount >= 2 && !mixesChannels {
        (separatesSpeakers, pendingChunks) = try hasSeparateSpeakers(source)
    }

    let locale = Locale(identifier: "en-US")
    let transcribers =
        separatesSpeakers
        ? [
            try await SpeakerTranscriber(speaker: .you, locale: locale, sampleRate: source.sampleRate),
            try await SpeakerTranscriber(speaker: .them, locale: locale, sampleRate: source.sampleRate),
        ]
        : [try await SpeakerTranscriber(speaker: nil, locale: locale, sampleRate: source.sampleRate)]
    try await installSpeechModel(for: transcribers)
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
