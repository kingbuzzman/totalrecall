import AudioLab
import Foundation

// The player tool behind the integration tests' fake speakers and microphones (see PlayerProcess): plays click tracks on
// one device, prints a line once it does, and stops when its stdin closes.
//
// Usage: AudioLabPlayer DEVICE SILENT-UNTIL TRACK...
//   SILENT-UNTIL  host time, in seconds, to stay silent until (0 for none)
//   TRACK         pitch,offset-seconds,amplitude, as ClickTrack.argument writes it

func fail(_ message: String) -> Never {
    fputs("AudioLabPlayer: \(message)\n", stderr)
    exit(1)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count >= 3, let silentUntil = Double(arguments[1]) else {
    fail("usage: AudioLabPlayer DEVICE SILENT-UNTIL TRACK...")
}
let tracks = arguments.dropFirst(2).map { argument in
    guard let track = ClickTrack(argument: argument) else { fail("not a click track: \(argument)") }
    return track
}
let player: ClickPlayer
do {
    player = try ClickPlayer(deviceNamed: arguments[0], tracks: tracks, silentUntil: silentUntil)
} catch {
    fail("\(error)")
}
print("playing")
fflush(stdout)
_ = FileHandle.standardInput.readDataToEndOfFile()
player.stop()
