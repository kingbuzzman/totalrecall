import AVFoundation
import CoreML
import Foundation
import Shared
import Speech

// transcribe: on-device speech to text for totalrecall recordings, from a file or live from `totalrecall -`. The
// command-line tool, and the only code that ends the process; the transcribing itself is in Transcription.swift, which
// the app uses too.

func fail(_ message: String) -> Never {
    fputs("transcribe: \(message)\n", stderr)
    exit(1)
}

/// Runs transcribe with the arguments after the program name, then exits.
package func runCommandLine(_ arguments: ArraySlice<String>) async -> Never {
    let command: Command
    do {
        command = try Command.parse(arguments)
    } catch {
        fail(error.localizedDescription)
    }
    switch command {
    case .listLanguages:
        await listLanguages()
    case .listSpeakers:
        listSpeakers()
    case .nameSpeaker(let speaker, let name):
        guard changingSpeakers({ try $0.rename(speaker, to: name) }) else { failNoSpeaker(speaker) }
    case .mergeSpeaker(let speaker, let target):
        guard changingSpeakers({ try $0.merge(speaker, into: target) }) else {
            fail(
                speaker == target
                    ? "a speaker is already part of themselves"
                    : "no speaker \(speaker) or \(target); see transcribe speakers"
            )
        }
    case .forgetSpeaker(let speaker):
        guard changingSpeakers({ try $0.forget(speaker) }) else { failNoSpeaker(speaker) }
    case .playSpeaker(let speaker):
        playSamples(of: speaker)
    case .saveSpeakerSamples(let speaker, let directory):
        saveSamples(of: speaker, in: directory)
    case .help:
        print("transcribe \(version)\n\n\(usage)")
    case .version:
        print(version)
    case .transcribe(let inputPath, let textPath, let options):
        await transcribe(inputPath: inputPath, textPath: textPath, options: options)
    }
    exit(0)
}

/// `transcribe --list-languages`: the languages on-device recognition has, `*` marking those whose model is installed.
private func listLanguages() async {
    guard await speechRecognitionIsAvailable() else { fail(speechRecognitionUnavailable) }
    let installed = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
    for locale in await SpeechTranscriber.supportedLocales.map({ $0.identifier(.bcp47) }).sorted() {
        let mark = installed.contains(locale) ? "*" : " "
        let name = Locale.current.localizedString(forIdentifier: locale) ?? locale
        print("\(mark) \(locale.padding(toLength: 8, withPad: " ", startingAt: 0)) \(name)")
    }
}

/// `transcribe speakers`: the people remembered, how long each was heard, and those who sound alike.
private func listSpeakers() {
    let (speakers, samples) = changingSpeakers { (try $0.speakers(), try $0.sampleCounts()) }
    if speakers.isEmpty { print("nobody yet: transcribe --identify-speakers remembers the people it hears") }
    for speaker in speakers {
        let seconds = Double(speaker.prints) * SpeakerIdentifier.hopSeconds
        let heard = seconds < 60 ? "\(Int(seconds)) s" : "\(Int((seconds / 60).rounded())) min"
        let since = speaker.createdAt.formatted(date: .abbreviated, time: .omitted)
        let number = String(speaker.id).padding(toLength: 4, withPad: " ", startingAt: 0)
        let name = (speaker.name ?? (speaker.isYou ? Speaker.you.rawValue : "-")) + (speaker.isYou ? " (you)" : "")
        let count = samples[speaker.id, default: 0]
        let sampleCount = count == 0 ? "" : ", " + counted(count, "sample")
        // Maybe one person, heard as two: not alike enough to be merged without being told to.
        let alike = speakers.filter {
            $0.id != speaker.id && voiceDistance($0.voice, speaker.voice) < SpeakerIdentifier.soundAlike
        }
        let soundsLike = alike.isEmpty ? "" : "  sounds like " + alike.map { String($0.id) }.joined(separator: ", ")
        print("\(number) \(name)  (\(heard)\(sampleCount) since \(since))\(soundsLike)")
    }
}

/// `transcribe speakers play`: plays the samples kept of a speaker, one after another.
private func playSamples(of speaker: Int) {
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
}

/// `transcribe speakers save`: writes the samples kept of a speaker as .m4a files into `directory`.
private func saveSamples(of speaker: Int, in directory: String) {
    let samples = speakerSamples(speaker)
    let folder = URL(typedPath: directory)
    for (index, sample) in samples.enumerated() {
        let url = folder.appending(path: "speaker-\(speaker)-\(index + 1).m4a")
        do {
            try sample.audio.write(to: url, options: .withoutOverwriting)
        } catch {
            fail("cannot save \(url.path): \(error.localizedDescription)")
        }
        print(url.path)
    }
}

/// `transcribe <audio-file> [<text-file>]` or `transcribe - [<text-file>]`: transcribes a file, or a live stream on
/// stdin, to stdout or the text file.
private func transcribe(inputPath: String, textPath: String?, options: Options) async {
    let readsStream = inputPath == "-"
    let textURL = textPath.map { URL(typedPath: $0).standardizedFileURL }
    if readsStream && isatty(STDIN_FILENO) != 0 {
        fail("nothing is piped in; - reads a live stream, e.g. totalrecall - | transcribe -")
    }
    do {
        try checkCanCreate(textURL.map { [$0] } ?? [], overwrite: options.overwrite)
    } catch {
        fail(error.localizedDescription)
    }

    // Ctrl-C reaches every program in the pipeline, and totalrecall answers it by ending the stream. So rather than dying
    // with the last words still being recognized, keep going until the stream ends and finish the transcript from it. A
    // second Ctrl-C quits right away.
    let stopSignals = readsStream ? finishOnStopSignals() : []
    do {
        let locale = try await readySpeechLocale(for: options.language)
        // Read here first, to tell the speakers apart, then by the reading task below.
        let source: any AudioSource & Sendable =
            readsStream
            ? try WAVStreamReader(handle: .standardInput)
            : try FileAudioSource(url: URL(typedPath: inputPath))
        let output = TranscriptionOutput(
            makePrinter: { save in
                TranscriptPrinter(printsLines: save == nil || options.showsLive, isLive: options.showsLive, save: save)
            },
            warn: { fputs("transcribe: \($0)\n", stderr) },
            report: { fputs("transcribe: \($0)\n", stderr) },
            // A failed write ends transcribe, as the transcript is incomplete.
            onSaveFailure: { fail("cannot write the transcript: \($0.localizedDescription)") }
        )
        try await transcribe(source, locale: locale, options: options, textURL: textURL, output: output)
    } catch {
        fail(error.localizedDescription)
    }
    withExtendedLifetime(stopSignals) {}
}

/// Ignores SIGINT, SIGTERM and SIGHUP the first time, so the transcript can finish from the end of the stream, and
/// quits on the second; keep the returned sources for as long as that should hold.
private func finishOnStopSignals() -> [any DispatchSourceSignal] {
    nonisolated(unsafe) var isStopping = false  // only touched on the signals' queue
    return handleStopSignals(queue: DispatchQueue(label: "transcribe.signals")) { signalNumber in
        if isStopping { exit(128 + signalNumber) }
        isStopping = true
    }
}

/// A speaker's samples, longest first, failing if there are none.
func speakerSamples(_ speaker: Int) -> [SpeakerDatabase.Sample] {
    let (exists, samples) = changingSpeakers { (try $0.speaker(speaker) != nil, try $0.samples(of: speaker)) }
    guard exists else { failNoSpeaker(speaker) }
    guard !samples.isEmpty else {
        fail(
            "no samples of speaker \(speaker): they are kept from stretches of \(Int(SpeakerIdentifier.shortestSample)) s or more, until they have a name"
        )
    }
    return samples
}

private func failNoSpeaker(_ speaker: Int) -> Never {
    fail("no speaker \(speaker); see transcribe speakers")
}

/// Opens the speaker database for `transcribe speakers`, failing if it cannot be read or changed.
func changingSpeakers<Result>(_ change: (SpeakerDatabase) throws -> Result) -> Result {
    do {
        return try change(try SpeakerDatabase())
    } catch {
        fail(error.localizedDescription)
    }
}
