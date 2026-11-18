package import Foundation
import Shared
import os

/// Who a live transcript goes to, as it is written: each line as it settles, and whether it was heard on your microphone;
/// the words still being recognized ("" once there are none); telling people apart, all the lines again at the end,
/// each said by whoever turned out to say it; and warnings and news of the people it heard. Switched to another
/// language (`LanguageSwitch`), it starts over in it, from the start, and once it has caught up with the stream, says
/// so.
package struct LiveTranscriptHandlers: Sendable {
    package let onLine: @Sendable (_ line: String, _ isYours: Bool) -> Void
    package let onLiveText: @Sendable (String) -> Void
    package let onRewrite: @Sendable ([(line: String, isYours: Bool)]) -> Void
    package let onMessage: @Sendable (String) -> Void
    package let onRestart: @Sendable (_ language: String) -> Void
    package let onCaughtUp: @Sendable () -> Void

    package init(
        onLine: @escaping @Sendable (_ line: String, _ isYours: Bool) -> Void,
        onLiveText: @escaping @Sendable (String) -> Void,
        onRewrite: @escaping @Sendable ([(line: String, isYours: Bool)]) -> Void,
        onMessage: @escaping @Sendable (String) -> Void,
        onRestart: @escaping @Sendable (_ language: String) -> Void = { _ in },
        onCaughtUp: @escaping @Sendable () -> Void = {}
    ) {
        self.onLine = onLine
        self.onLiveText = onLiveText
        self.onRewrite = onRewrite
        self.onMessage = onMessage
        self.onRestart = onRestart
        self.onCaughtUp = onCaughtUp
    }
}

/// Switches a live transcript (`transcribeLive`) to another language while the stream goes on: once that language's
/// speech model is ready, the transcript starts over in it, from the start of the stream, then goes on live.
package final class LanguageSwitch: Sendable {
    private struct State {
        /// The switches asked for, the latest of which wins.
        var requests = 0
        /// The language to go on in, and its recognizer's locale, once ready, until the transcript takes it.
        var ready: (language: String, locale: Locale)?
        /// Goes up each time a language is ready: the transcript going on is given up for one in it.
        var generation = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    package init() {}

    /// Gets `language`'s speech model ready, downloading it if need be, then has the transcript start over in it,
    /// unless another switch was asked for meanwhile. Throws if this Mac cannot transcribe it.
    package func switchTo(_ language: String) async throws {
        let request = state.withLock { state in
            state.requests += 1
            return state.requests
        }
        let locale = try await readySpeechLocale(for: language)
        state.withLock { state in
            guard state.requests == request else { return }
            state.ready = (language, locale)
            state.generation += 1
        }
    }

    var generation: Int {
        state.withLock { $0.generation }
    }

    /// The language ready to go on in, once, and the generation it is ready as of; nil if none is.
    func take() -> (language: String, locale: Locale, generation: Int)? {
        state.withLock { state in
            defer { state.ready = nil }
            return state.ready.map { ($0.language, $0.locale, state.generation) }
        }
    }
}

/// A live transcript of the WAV stream `input` carries, such as the one a recording made in the same app writes into
/// a pipe, until the stream ends: each line, as it settles, goes to `textURL` and `handlers`, as do the words still
/// being recognized. Given `identifyingSpeakersIn`, people are told apart by voice and remembered in the database there.
/// Given `recording`, the 16-bit PCM CAF file the stream is recorded into, open from the start, and switched to another
/// language through `switches`, the transcript starts over in it, reading the recording from its start, written to
/// `textURL` afresh, and goes on live, following the recording as it grows, once it catches up (see `LiveAudio`).
/// Throws if transcribing cannot start or fails part way; the text file then has what was transcribed until then.
package func transcribeLive(
    from input: FileHandle,
    recordedIn recording: FileHandle? = nil,
    to textURL: URL,
    language: String?,
    switches: LanguageSwitch = LanguageSwitch(),
    identifyingSpeakersIn speakers: URL?,
    handlers: LiveTranscriptHandlers
) async throws {
    var options = Options()
    options.language = language?.nonEmpty ?? options.language
    if let speakers {
        options.identifiesSpeakers = true
        options.speakers = speakers
    }
    let audio = LiveAudio(stream: try WAVStreamReader(handle: input), recording: recording)
    defer { audio.close() }
    var generation = switches.generation
    var locale = try await readySpeechLocale(for: options.language)
    var isRestart = false
    while true {
        let stops = { @Sendable [generation] in switches.generation != generation }
        let reader: any Reader =
            isRestart ? try audio.recordingReader(stopsWhen: stops) : audio.streamReader(stopsWhen: stops)
        // Nothing of a transcript given up goes anywhere, once it is: the next one starts over.
        let isCurrent = { @Sendable [generation] in !reader.wasStopped && switches.generation == generation }
        let transcribers = OSAllocatedUnfairLock<[SpeakerTranscriber]>(initialState: [])
        var output = TranscriptionOutput(
            makePrinter: { save in
                TranscriptPrinter(
                    printsLines: false,
                    isLive: false,
                    save: save,
                    showLine: { line, isYours in if isCurrent() { handlers.onLine(line, isYours) } },
                    showLive: { text in if isCurrent() { handlers.onLiveText(text) } },
                    showAll: { lines in if isCurrent() { handlers.onRewrite(lines) } }
                )
            },
            warn: { message in if isCurrent() { handlers.onMessage(message) } },
            report: handlers.onMessage,
            onSaveFailure: { error in
                if isCurrent() { handlers.onMessage("cannot write the transcript: \(error.localizedDescription)") }
            }
        )
        output.onTranscribers = { made in transcribers.withLock { $0 = made } }
        output.isAbandoned = { reader.wasStopped }
        let catchingUp =
            isRestart
            ? Task.detached {
                await waitToCatchUp(with: audio, heardBy: { transcribers.withLock { $0 } }, while: isCurrent)
                if isCurrent() { handlers.onCaughtUp() }
            } : nil
        defer { catchingUp?.cancel() }
        try await transcribe(reader, locale: locale, options: options, textURL: textURL, output: output)
        guard reader.wasStopped, let next = switches.take() else { return }
        (locale, generation) = (next.locale, next.generation)
        isRestart = true
        handlers.onRestart(next.language)
    }
}

/// Returns once the recognizers have listened to within a few seconds of all the audio recorded so far, as they have
/// once a transcript started over has caught up with the recording; or once `isCurrent` says it was given up, or the
/// task is cancelled.
private func waitToCatchUp(
    with audio: LiveAudio,
    heardBy transcribers: @Sendable () -> [SpeakerTranscriber],
    while isCurrent: @Sendable () -> Bool
) async {
    while !Task.isCancelled, isCurrent() {
        let made = transcribers()
        if !made.isEmpty, let heard = made.map(\.heard).min(), heard >= audio.recordedSeconds - catchUpSeconds {
            return
        }
        try? await Task.sleep(for: .milliseconds(250))
    }
}

/// How far behind the recording a transcript started over may be, in seconds, to have caught up with it.
let catchUpSeconds = 3.0
