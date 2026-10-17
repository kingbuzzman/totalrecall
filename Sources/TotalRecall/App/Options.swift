import Foundation

let usage = """
    usage: totalrecall [--mic NAME | --no-mic] [--no-speaker-isolation] [--no-echo-cancellation] [--force]
                       [--stream] <output-file>
           totalrecall [--mic NAME | --no-mic] [--no-speaker-isolation] [--no-echo-cancellation] -
           totalrecall --list-mics
           totalrecall --version

    Records all system audio plus a microphone until Ctrl-C, then saves <output-file>.
    By default your microphone goes to the left channel and everyone else (system audio) to the right.
    The microphone follows the system input, so plugging in or removing AirPods switches it mid-recording.
    Format follows the extension: .m4a .wav .aiff .caf natively, anything else (.mp3, .flac, ...) via ffmpeg.
    With --stream it also streams the recording to stdout as WAV: totalrecall meeting.mp3 --stream | transcribe -
    With - instead of <output-file> it only streams, saving no file: totalrecall - | transcribe -

      --mic NAME                prefer this microphone whenever it is available (case-insensitive substring of a
                                --list-mics name); falls back to the system input when it is not
      --no-mic                  record system audio only
      --no-speaker-isolation    mix microphone and system audio into both channels instead of splitting them left/right
      --no-echo-cancellation    keep the raw microphone signal, including speaker audio it picks up
      --force                   overwrite <output-file> if it exists
      --stream                  also stream the recording to stdout while saving <output-file>
    """

struct Options: Equatable {
    var microphoneQuery: String?
    var includesMicrophone = true
    var isolatesSpeakers = true
    var cancelsEcho = true
    var overwrite = false
    /// With an output file, also stream the recording to stdout (`--stream`).
    var streams = false
}

/// Invalid command-line arguments; the description ends with the usage text.
struct UsageError: LocalizedError {
    let problem: String

    var errorDescription: String? { "\(problem)\n\(usage)" }
}

enum Command: Equatable {
    case record(outputPath: String, options: Options)
    case listMicrophones
    case help
    case version

    /// Parses the arguments after the program name. `--list-mics`, `--help` and `--version` win over anything
    /// after them.
    static func parse(_ arguments: ArraySlice<String>) throws -> Command {
        var arguments = arguments
        var options = Options()
        var outputPath: String?
        while let argument = arguments.popFirst() {
            switch argument {
            case "--list-mics":
                return .listMicrophones
            case "--mic":
                guard let query = arguments.popFirst() else { throw UsageError(problem: "--mic needs a name") }
                options.microphoneQuery = query
            case "--no-mic":
                options.includesMicrophone = false
            case "--no-speaker-isolation":
                options.isolatesSpeakers = false
            case "--no-echo-cancellation":
                options.cancelsEcho = false
            case "-f", "--force":
                options.overwrite = true
            case "--stream":
                options.streams = true
            case "-h", "--help":
                return .help
            case "--version":
                return .version
            default:
                guard argument == "-" || !argument.hasPrefix("-") else {
                    throw UsageError(problem: "unexpected argument \(argument)")
                }
                if let outputPath {
                    let hint =
                        [outputPath, argument].contains("-") ? "; to save a file and stream it, use --stream" : ""
                    throw UsageError(problem: "unexpected argument \(argument)\(hint)")
                }
                outputPath = argument
            }
        }
        guard let outputPath else {
            throw UsageError(
                problem: options.streams
                    ? "--stream needs an output file; to only stream, use -" : "missing output file"
            )
        }
        if options.streams && outputPath == "-" {
            throw UsageError(problem: "--stream is for saving a file and streaming it; - already streams")
        }
        return .record(outputPath: outputPath, options: options)
    }
}
