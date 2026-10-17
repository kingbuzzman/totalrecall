import Foundation

// The only place that ends the process: everything below main.swift reports failures by throwing.

func fail(_ message: String) -> Never {
    fputs("totalrecall: \(message)\n", stderr)
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

let output = OutputFile(path: outputPath)
do {
    try output.checkCanCreate(overwrite: options.overwrite)
} catch {
    fail(error.localizedDescription)
}
if options.includesMicrophone && !requestMicrophoneAccess() {
    fail(
        "microphone access denied; allow your terminal in System Settings > Privacy & Security > Microphone, "
            + "or use --no-mic"
    )
}

let session: RecordingSession
do {
    session = try RecordingSession(options: options, output: output)
} catch {
    fail("cannot create \(output.partialURL.path): \(error.localizedDescription)")
}
do {
    try session.start()
} catch {
    fail(error.localizedDescription)
}

let stopSignals = handleStopSignals {
    do {
        try session.stopAndSave()
    } catch {
        fail(
            "could not save \(output.url.path): \(error.localizedDescription); "
                + "the raw recording is kept at \(output.partialURL.path)"
        )
    }
    exit(0)
}
dispatchMain()
