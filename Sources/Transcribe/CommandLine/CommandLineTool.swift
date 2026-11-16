import AVFoundation
import CoreML
import Foundation
import Shared
import Speech
import os

// transcribe: on-device speech to text for totalrecall recordings, from a file or live from `totalrecall -`. The
// command-line tool, and the only code that ends the process; the transcribing itself is in Transcription.swift, which
// the app uses too.

func fail(_ message: String) -> Never {
    fputs("transcribe: \(message)\n", stderr)
    Log.transcript.error("transcribe: \(message, privacy: .public)")
    exit(1)
}

/// Tells the user, on stderr, and the log, at info, of a problem transcribe goes on without, or of the people it heard.
private func say(_ message: String) {
    fputs("transcribe: \(message)\n", stderr)
    Log.transcript.info("transcribe: \(message, privacy: .public)")
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
    case .mergeSpeaker(let speaker, let target, let anyway):
        mergeSpeaker(speaker, into: target, anyway: anyway)
    case .splitVoice(let voice):
        guard let person = changingSpeakers({ try $0.split(voice) }) else {
            fail("no voice \(voice) that its speaker has others besides; see transcribe speakers")
        }
        print("voice \(voice) is speaker \(person) now")
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

/// `transcribe speakers`: the people remembered, how long each was heard, the voices of those heard more than one way,
/// and those who sound alike.
private func listSpeakers() {
    let (people, voices, clips) = changingSpeakers { (try $0.people(), try $0.voices(), try $0.clipCounts()) }
    if people.isEmpty { print("nobody yet: transcribe --identify-speakers remembers the people it hears") }
    let voicesOf = Dictionary(grouping: voices, by: \.person)
    func distance(_ one: Int, _ other: Int) -> Float {
        (voicesOf[one] ?? []).flatMap { voice in (voicesOf[other] ?? []).map { voiceDistance(voice.print, $0.print) } }
            .min() ?? .infinity
    }
    for person in people {
        let theirs = voicesOf[person.id] ?? []
        let seconds = Double(theirs.reduce(0) { $0 + $1.prints }) * SpeakerIdentifier.secondsPerPrint
        let heard = seconds < 60 ? "\(Int(seconds)) s" : "\(Int((seconds / 60).rounded())) min"
        let since = person.createdAt.formatted(date: .abbreviated, time: .omitted)
        let number = String(person.id).padding(toLength: 4, withPad: " ", startingAt: 0)
        let name = (person.name ?? (person.isYou ? Speaker.you.rawValue : "-")) + (person.isYou ? " (you)" : "")
        let count = clips[person.id, default: 0]
        let clipCount = count == 0 ? "" : ", " + counted(count, "clip")
        let voiceNumbers = theirs.count < 2 ? "" : "  voices " + theirs.map { String($0.id) }.joined(separator: ", ")
        // Maybe one person, heard as two: not alike enough to be merged without being told to.
        let alike = people.filter { $0.id != person.id && distance($0.id, person.id) < SpeakerIdentifier.soundAlike }
        let soundsLike = alike.isEmpty ? "" : "  sounds like " + alike.map { String($0.id) }.joined(separator: ", ")
        print("\(number) \(name)  (\(heard)\(clipCount) since \(since))\(voiceNumbers)\(soundsLike)")
    }
}

/// `transcribe speakers merge`: one person taken for two. Refused, unless `anyway`, when no voice of the one sounds like
/// any of the other's: then they are most likely two people, and merging them would have one taken for the other.
private func mergeSpeaker(_ speaker: Int, into target: Int, anyway: Bool) {
    guard speaker != target else { fail("a speaker is already part of themselves") }
    let (exist, distance) = changingSpeakers {
        (try $0.person(speaker) != nil && $0.person(target) != nil, try $0.distance(between: speaker, and: target))
    }
    guard exist else { fail("no speaker \(speaker) or \(target); see transcribe speakers") }
    if !anyway, (distance ?? .infinity) >= SpeakerIdentifier.soundAlike {
        let howFar =
            distance.map {
                String(format: "%.2f apart, where one person's voices are under %.2f", $0, SpeakerIdentifier.soundAlike)
            } ?? "no voice of theirs to compare"
        fail(
            "speakers \(speaker) and \(target) do not sound alike (\(howFar)); hear them with transcribe speakers "
                + "play, and add --anyway to merge them all the same"
        )
    }
    _ = changingSpeakers { try $0.merge(speaker, into: target) }
}

/// `transcribe speakers play`: plays the clips kept of a speaker, one after another.
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
        try FileManager.default.checkCanCreate(textURL.map { [$0] } ?? [], overwrite: options.overwrite)
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
            warn: say,
            report: say,
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

/// A speaker's clips, longest first, failing if there are none.
func speakerSamples(_ speaker: Int) -> [SpeakerDatabase.Clip] {
    let (exists, clips) = changingSpeakers { (try $0.person(speaker) != nil, try $0.clips(of: speaker)) }
    guard exists else { failNoSpeaker(speaker) }
    guard !clips.isEmpty else {
        fail(
            "no clips of speaker \(speaker): they are kept from stretches of \(Int(ClipCollector.shortest)) s or more"
        )
    }
    return clips
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
