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

let destination = Destination(path: outputPath)
switch destination {
case .file(let output):
    do {
        try output.checkCanCreate(overwrite: options.overwrite)
    } catch {
        fail(error.localizedDescription)
    }
case .standardOutput:
    if isatty(STDOUT_FILENO) != 0 {
        fail("refusing to write audio to the terminal; pipe it into another program, e.g. totalrecall - | transcribe -")
    }
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
    switch destination {
    case .file(let output): fail("cannot create \(output.partialURL.path): \(error.localizedDescription)")
    case .standardOutput: fail("cannot write to stdout: \(error.localizedDescription)")
    }
}

func stopAndExit() -> Never {
    do {
        try session.stopAndSave()
    } catch let error as StoppedBeforeRecording {
        fail(error.localizedDescription)
    } catch {
        guard case .file(let output) = destination else { fail(error.localizedDescription) }
        fail(
            "could not save \(output.url.path): \(error.localizedDescription); "
                + "the raw recording is kept at \(output.partialURL.path)"
        )
    }
    exit(0)
}

session.onOutputClosed = { DispatchQueue.main.async { stopAndExit() } }
do {
    try session.start()
} catch {
    fail(error.localizedDescription)
}
let stopSignals = handleStopSignals { stopAndExit() }
dispatchMain()
