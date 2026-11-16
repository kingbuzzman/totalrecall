import Foundation
import Shared

let usage = """
    usage: transcribe [--language LANG] [--mix] [--identify-speakers] [--force] <audio-file> [<text-file>]
           transcribe [--language LANG] [--mix] [--identify-speakers] [--force] [--live] - [<text-file>]
           transcribe speakers [name <number> <name> | merge <number> <into-number> [--anyway] | forget <number>]
           transcribe speakers [split <voice> | play <number> | save <number> <directory>]
           transcribe --list-languages
           transcribe --version

    Transcribes speech on-device with Apple's speech recognizer, from an audio file or, with -, from a live WAV stream
    on stdin, such as totalrecall - | transcribe -
    Prints each line of the transcript as the recognizer settles on it, or writes it to <text-file>.
    Recordings with totalrecall's channel split (your mic left, everyone else right) are labeled You and Them.

      --language LANG      the language spoken, such as es or es-MX (default: en-US)
      --list-languages     list the languages the speech recognizer supports; * marks installed models
      --mix                transcribe both channels together, without speaker labels
      --identify-speakers  tell the people on the right channel apart by voice, as Them 1, Them 2, ..., or everyone,
                           as Speaker 1, Speaker 2, ..., on a recording without the split or with --mix; once it
                           ends, <text-file> is written again by who turned out to say each line, and they are
                           remembered, so each keeps their number, or name, from call to call
      --live               show the live transcript, including the words still being recognized, even with a <text-file>
      --force              overwrite <text-file> if it exists

    transcribe speakers lists the people --identify-speakers remembers, in ~/.transcribe/speakers.db (or the file
    TRANSCRIBE_SPEAKERS names), with the voices of those heard more than one way. name gives one a name to go by instead of their number; merge makes the first number
    part of the second, for one person taken for two, keeping each voice as it was, and refuses two who do not sound
    alike unless --anyway; split takes a voice back out into a person of its own, for a merge that was wrong; forget
    takes one out. The longest stretches of everyone's speech are kept, to tell who they are by: play plays them, save
    writes them as .m4a files.
    """

struct Options: Equatable {
    var language = "en-US"
    var mixesChannels = false
    /// Show the live transcript on stdout (`--live`), even when writing a text file.
    var showsLive = false
    /// Tell the people on a channel apart by voice (`--identify-speakers`), remembering them in `speakers`.
    var identifiesSpeakers = false
    var speakers = SpeakerDatabase.defaultURL
    var overwrite = false
}

enum Command: Equatable {
    case transcribe(inputPath: String, textPath: String?, options: Options)
    case listLanguages
    case listSpeakers
    case nameSpeaker(Int, name: String)
    case mergeSpeaker(Int, into: Int, anyway: Bool = false)
    case splitVoice(Int)
    case forgetSpeaker(Int)
    case playSpeaker(Int)
    case saveSpeakerSamples(Int, directory: String)
    case help
    case version

    /// Parses the arguments after the program name. `--list-languages`, `--help` and `--version` win over anything
    /// after them.
    static func parse(_ arguments: ArraySlice<String>) throws -> Command {
        var arguments = arguments
        var options = Options()
        var paths: [String] = []
        if arguments.first == "speakers" { return try parseSpeakers(arguments.dropFirst()) }
        while let argument = arguments.popFirst() {
            switch argument {
            case "--mix":
                options.mixesChannels = true
            case "--live":
                options.showsLive = true
            case "--identify-speakers":
                options.identifiesSpeakers = true
            case "-f", "--force":
                options.overwrite = true
            case "--language":
                guard let value = arguments.popFirst(), !value.hasPrefix("-") else {
                    throw MessageError("--language needs a language, such as es")
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
                    throw MessageError("unexpected argument \(argument)\n\(usage)")
                }
                paths.append(argument)
            }
        }
        guard (1...2).contains(paths.count) else { throw MessageError("expected an audio file or -\n\(usage)") }
        if options.showsLive && paths[0] != "-" {
            throw MessageError("--live is for a live stream (-); a file is transcribed faster than it was spoken")
        }
        return .transcribe(inputPath: paths[0], textPath: paths.count == 2 ? paths[1] : nil, options: options)
    }

    /// `transcribe speakers ...`; a name may be several words.
    private static func parseSpeakers(_ arguments: ArraySlice<String>) throws -> Command {
        var arguments = arguments
        func number() throws -> Int {
            guard let argument = arguments.popFirst(), let number = Int(argument) else {
                throw MessageError("expected a speaker's number, such as 3; transcribe speakers lists them")
            }
            return number
        }
        let command: Command
        switch arguments.popFirst() {
        case nil:
            command = .listSpeakers
        case "name":
            let speaker = try number()
            guard !arguments.isEmpty else { throw MessageError("expected a name for speaker \(speaker)") }
            command = .nameSpeaker(speaker, name: arguments.joined(separator: " "))
            arguments = []
        case "merge":
            command = .mergeSpeaker(try number(), into: try number(), anyway: arguments.first == "--anyway")
            if arguments.first == "--anyway" { arguments.removeFirst() }
        case "split":
            guard let argument = arguments.popFirst(), let voice = Int(argument) else {
                throw MessageError("expected a voice's number, such as 7; transcribe speakers lists them")
            }
            command = .splitVoice(voice)
        case "forget":
            command = .forgetSpeaker(try number())
        case "play":
            command = .playSpeaker(try number())
        case "save":
            let speaker = try number()
            guard let directory = arguments.popFirst() else {
                throw MessageError("expected a directory to save speaker \(speaker)'s samples in")
            }
            command = .saveSpeakerSamples(speaker, directory: directory)
        case let other?:
            throw MessageError("unknown speakers command \(other)\n\(usage)")
        }
        guard arguments.isEmpty else { throw MessageError("unexpected argument \(arguments.first!)\n\(usage)") }
        return command
    }
}
