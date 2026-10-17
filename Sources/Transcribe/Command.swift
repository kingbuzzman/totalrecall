import Foundation

let usage = """
    usage: transcribe [--language LANG] [--mix] <audio-file | -> [<text-file>]
           transcribe --list-languages
           transcribe --version

    Transcribes speech on-device with Apple's speech recognizer. With - it reads a live WAV stream from stdin, such
    as totalrecall -, and prints the text as it is spoken; otherwise it transcribes the audio file.
    Prints the transcript, or writes it to <text-file>.
    Recordings with totalrecall's channel split (your mic left, everyone else right) are labeled You and Them.

      --language LANG   the language spoken, such as es or es-MX (default: en-US)
      --list-languages  list the languages the speech recognizer supports; * marks installed models
      --mix             transcribe both channels together, without speaker labels
    """

struct Options: Equatable {
    var language = "en-US"
    var mixesChannels = false
}

/// Invalid command-line arguments.
struct UsageError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
}

enum Command: Equatable {
    case transcribe(inputPath: String, textPath: String?, options: Options)
    case listLanguages
    case help
    case version

    /// Parses the arguments after the program name. `--list-languages`, `--help` and `--version` win over anything
    /// after them.
    static func parse(_ arguments: ArraySlice<String>) throws -> Command {
        var arguments = arguments
        var options = Options()
        var paths: [String] = []
        while let argument = arguments.popFirst() {
            switch argument {
            case "--mix":
                options.mixesChannels = true
            case "--language":
                guard let value = arguments.popFirst(), !value.hasPrefix("-") else {
                    throw UsageError("--language needs a language, such as es")
                }
                options.language = value
            case "--list-languages":
                return .listLanguages
            case "-h", "--help":
                return .help
            case "--version":
                return .version
            default:
                guard argument == "-" || !argument.hasPrefix("-") else {
                    throw UsageError("unexpected argument \(argument)\n\(usage)")
                }
                paths.append(argument)
            }
        }
        guard (1...2).contains(paths.count) else { throw UsageError("expected an audio file or -\n\(usage)") }
        return .transcribe(inputPath: paths[0], textPath: paths.count == 2 ? paths[1] : nil, options: options)
    }
}
