import AVFoundation
import Foundation
import Shared

/// Clips of someone's speech, to hear who they are by: a sentence of one voice, at least `shortest` of them talking
/// alone with no pause in it over `longestGap`, only the gaps between words, as words strung across silences, or two
/// people taking turns, is not what tells a voice apart; at most `longest`. They are cut as the call goes on, while the
/// audio is still kept, and kept, with their print, for whoever they turn out to be once it is over.
struct ClipCollector {
    struct Clip {
        let audio: Data
        let seconds: Double
        let print: [Float]
    }

    static let shortest = 5.0
    static let longest = 15.0
    /// Measured on a real meeting, a 0.3 s gap left a 5 s run in 4 of 14 long stretches of one person, 0.5 s in 11.
    static let longestGap = 0.5
    /// The clips kept, the longest.
    static let mostClips = 60

    private(set) var clips: [Clip] = []
    /// The time cell clips are looked for from, and the run of someone talking alone going on there, by cell.
    var cursor = 0
    var run: (speaker: Int, cells: [Int])?

    mutating func keep(_ clip: Clip) {
        clips.append(clip)
        clips.sort { $0.seconds > $1.seconds }
        if clips.count > Self.mostClips { clips.removeLast() }
    }
}

extension SpeakerIdentifier {
    /// Looks for clips in the time no window to come will hear, up to `time` in seconds; `atTheEnd`, the run going on
    /// ends there.
    func collectClips(through time: Double, atTheEnd: Bool = false) {
        guard database != nil else { return }
        let talkers = lock.withLock { turns.talkers(from: Double(clips.cursor) * SpeakerTurns.cellSeconds, to: time) }
        let gapCells = Int(ClipCollector.longestGap / SpeakerTurns.cellSeconds)
        let longestCells = Int(ClipCollector.longest / SpeakerTurns.cellSeconds)
        for (cell, speakers) in talkers {
            if let run = clips.run,
                cell - run.cells.last! - 1 > gapCells || speakers.count > 1
                    || speakers.first.map({ $0 != run.speaker }) ?? false
            {
                cutClip()
            }
            guard speakers.count == 1 else { continue }
            if clips.run == nil { clips.run = (speakers[0], []) }
            clips.run?.cells.append(cell)
            if let run = clips.run, run.cells.last! - run.cells.first! + 1 >= longestCells { cutClip() }
        }
        clips.cursor = SpeakerTurns.cell(at: time)
        if atTheEnd { cutClip() }
    }

    /// Keeps a clip of the run going on, if it is long enough, and still in the audio kept.
    private func cutClip() {
        defer { clips.run = nil }
        guard let run = clips.run else { return }
        let step = Segmenter.frameStep
        let (first, last) = (run.cells.first! * step, (run.cells.last! + 1) * step)
        let seconds = Double(last - first) / VoicePrinter.sampleRate
        guard seconds >= ClipCollector.shortest, first >= historyStart, last <= historyStart + history.count else {
            return
        }
        let audio = history[(first - historyStart)..<(last - historyStart)]
        // Printed from the cells they talk in, not the gaps between their words.
        let talking = Set(run.cells)
        let frames = printer.frames(of: audio)
        let kept = frames.indices.filter { index in
            talking.contains((first + index * VoicePrinter.hopLength + VoicePrinter.frameLength / 2) / step)
        }
        guard !kept.isEmpty else { return }
        do {
            let print = try printer.voicePrint(of: kept.map { frames[$0] })
            clips.keep(ClipCollector.Clip(audio: try m4a(audio), seconds: seconds, print: print))
        } catch {
            if !hasWarnedAboutPrints {
                hasWarnedAboutPrints = true
                warn("cannot keep a clip of a voice: \(error.localizedDescription)")
            }
        }
    }
}

/// Audio at `VoicePrinter.sampleRate` as the bytes of a .m4a file: AAC, which macOS plays anywhere.
func m4a(_ samples: ArraySlice<Float>) throws -> Data {
    let url = FileManager.default.temporaryDirectory.appending(path: "speaker-sample-\(UUID()).m4a")
    defer { try? FileManager.default.removeItem(at: url) }
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: VoicePrinter.sampleRate,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 32_000,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    guard
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count))
    else { throw MessageError("cannot make a sample of \(samples.count) frames") }
    buffer.frameLength = buffer.frameCapacity
    samples.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: $0.count) }
    try file.write(from: buffer)
    file.close()
    return try Data(contentsOf: url)
}
