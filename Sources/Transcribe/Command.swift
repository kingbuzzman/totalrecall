import Foundation

let usage = """
    usage: transcribe [--language LANG] [--mix] [--force] <audio-file> [<text-file>]
           transcribe [--language LANG] [--mix] [--force] [--live] [--identify-speakers] - [<text-file>]
           transcribe speakers list
           transcribe speakers label <uuid> <name>
           transcribe speakers merge <uuid> <uuid>
           transcribe --list-languages
           transcribe --version

    Transcribes speech on-device with Apple's speech recognizer, from an audio file or, with -, from a live WAV stream
    on stdin, such as totalrecall - | transcribe -
    Prints each line of the transcript as the recognizer settles on it, or writes it to <text-file>.
    Recordings with totalrecall's channel split (your mic left, everyone else right) are labeled You and Them.

      --language LANG       the language spoken, such as es or es-MX (default: en-US)
      --list-languages      list the languages the speech recognizer supports; * marks installed models
      --mix                 transcribe both channels together, without speaker labels
      --live                show the live transcript, including the words still being recognized, even with a <text-file>
      --identify-speakers   use voice-based speaker identification instead of channel-based You/Them
      --force               overwrite <text-file> if it exists

    Speaker management:
      speakers list                   list all known speakers
      speakers label <uuid> <name>    set a speaker's display name
      speakers merge <uuid> <uuid>    merge two speakers into one
    """

struct Options: Equatable {
    var language = "en-US"
    var mixesChannels = false
    /// Show the live transcript on stdout (`--live`), even when writing a text file.
    var showsLive = false
    var overwrite = false
    /// Use voice-based speaker identification instead of channel-based You/Them.
    var identifySpeakers = false
}

enum Command: Equatable {
    case transcribe(inputPath: String, textPath: String?, options: Options)
    case listLanguages
    case speakersList
    case speakersLabel(uuid: String, name: String)
    case speakersMerge(source: String, target: String)
    case help
    case version

    /// Parses the arguments after the program name. `--list-languages`, `--help` and `--version` win over anything
    /// after them.
    static func parse(_ arguments: ArraySlice<String>) throws -> Command {
        var arguments = arguments
        var options = Options()
        var paths: [String] = []

        // Check for speakers subcommand first
        if let first = arguments.first, first == "speakers" {
            arguments = arguments.dropFirst()
            return try parseSpeakersCommand(arguments)
        }

        while let argument = arguments.popFirst() {
            switch argument {
            case "--mix":
                options.mixesChannels = true
            case "--live":
                options.showsLive = true
            case "-f", "--force":
                options.overwrite = true
            case "--identify-speakers":
                options.identifySpeakers = true
            case "--language":
                guard let value = arguments.popFirst(), !value.hasPrefix("-") else {
                    throw TranscribeError("--language needs a language, such as es")
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
                    throw TranscribeError("unexpected argument \(argument)\n\(usage)")
                }
                paths.append(argument)
            }
        }
        guard (1...2).contains(paths.count) else { throw TranscribeError("expected an audio file or -\n\(usage)") }
        if options.showsLive && paths[0] != "-" {
            throw TranscribeError("--live is for a live stream (-); a file is transcribed faster than it was spoken")
        }
        if options.identifySpeakers && paths[0] != "-" {
            throw TranscribeError("--identify-speakers is for a live stream (-); file transcription uses channel-based speaker detection")
        }
        return .transcribe(inputPath: paths[0], textPath: paths.count == 2 ? paths[1] : nil, options: options)
    }

    private static func parseSpeakersCommand(_ arguments: ArraySlice<String>) throws -> Command {
        var arguments = arguments
        guard let subcommand = arguments.popFirst() else {
            throw TranscribeError("expected: speakers list | speakers label <uuid> <name> | speakers merge <uuid> <uuid>")
        }
        switch subcommand {
        case "list":
            return .speakersList
        case "label":
            guard let uuid = arguments.popFirst(), let name = arguments.popFirst() else {
                throw TranscribeError("usage: speakers label <uuid> <name>")
            }
            return .speakersLabel(uuid: uuid, name: name)
        case "merge":
            guard let source = arguments.popFirst(), let target = arguments.popFirst() else {
                throw TranscribeError("usage: speakers merge <source-uuid> <target-uuid>")
            }
            return .speakersMerge(source: source, target: target)
        default:
            throw TranscribeError("unknown speakers command: \(subcommand)")
        }
    }
}
