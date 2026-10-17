import Foundation
import Shared

// The only place that ends the process: everything below main.swift reports failures by throwing.

func fail(_ message: String) -> Never {
    // On a terminal, start on a clean line, like every other message (see StatusLine).
    let clearLine = isatty(STDERR_FILENO) != 0 ? "\r\u{1B}[K" : ""
    fputs("\(clearLine)totalrecall: \(message)\n", stderr)
    exit(1)
}

let command: Command
do {
    command = try Command.parse(CommandLine.arguments.dropFirst())
} catch {
    fail(error.localizedDescription)
}

let outputPath: String
let options: Options
switch command {
case .listMicrophones:
    let systemInput = defaultInputDevice()
    for device in InputDevice.all() {
        print("\(device.id == systemInput ? "*" : " ") \(device.name)")
    }
    exit(0)
case .help:
    print("totalrecall \(version)\n\n\(usage)")
    exit(0)
case .version:
    print("\(version)")
    exit(0)
case .record(let path, let parsedOptions):
    outputPath = path
    options = parsedOptions
}

if let microphoneQuery = options.microphoneQuery, InputDevice.matching(microphoneQuery).isEmpty {
    let available = InputDevice.all().map { "  \($0.name)" }.joined(separator: "\n")
    fail("no microphone matches \"\(microphoneQuery)\"; available:\n\(available)")
}

let destination = Destination(path: outputPath, streams: options.streams)
if let output = destination.file {
    do {
        try output.checkCanCreate(overwrite: options.overwrite)
    } catch {
        fail(error.localizedDescription)
    }
}
if destination.streams && isatty(STDOUT_FILENO) != 0 {
    fail("refusing to write audio to the terminal; pipe it into another program, e.g. totalrecall - | transcribe -")
}
if !destination.streams && standardOutputIsPipe() {
    fail(
        "stdout is a pipe, but nothing would be streamed into it; add --stream to stream the recording, "
            + "e.g. totalrecall \(outputPath) --stream | transcribe -"
    )
}
if !requestSystemAudioAccess() {
    fail(
        "system audio recording is not allowed; allow your terminal in System Settings > Privacy & Security > "
            + "Screen & System Audio Recording > System Audio Recording Only, then quit and reopen it"
    )
}
if options.includesMicrophone && !requestMicrophoneAccess() {
    fail(
        "microphone access denied; allow your terminal in System Settings > Privacy & Security > Microphone, "
            + "or use --no-mic"
    )
}

let session: RecordingSession
do {
    session = try RecordingSession(options: options, destination: destination)
} catch {
    guard let output = destination.file else { fail("cannot write to stdout: \(error.localizedDescription)") }
    fail("cannot create \(output.partialURL.path): \(error.localizedDescription)")
}

@MainActor func stopAndExit() -> Never {
    do {
        try session.stopAndSave()
    } catch let error as StoppedBeforeRecording {
        fail(error.localizedDescription)
    } catch {
        guard let output = destination.file else { fail(error.localizedDescription) }
        fail(
            "could not save \(output.url.path): \(error.localizedDescription); "
                + "the raw recording is kept at \(output.partialURL.path)"
        )
    }
    exit(0)
}

/// Whether stdout is a pipe into another program, rather than the terminal, a file or /dev/null.
func standardOutputIsPipe() -> Bool {
    var info = stat()
    return fstat(STDOUT_FILENO, &info) == 0 && info.st_mode & S_IFMT == S_IFIFO
}

session.onOutputClosed = { @Sendable in DispatchQueue.main.async { stopAndExit() } }
do {
    try session.start()
} catch {
    fail(error.localizedDescription)
}
let stopSignals = handleStopSignals { stopAndExit() }
dispatchMain()
