import Accelerate

/// Who talks when on one channel, put together from windows of it, each `Segmenter.windowLength` long and
/// `windowStep` after the last, so each moment is in several: `Segmenter` says who of each window's people talks in each
/// of its frames, and a print of each tells who they are. Speakers are numbered from 1.
///
/// While the call goes on, each print goes to whoever it sounds like, on average, of those heard so far, or is someone
/// new: who spoke a line is known within seconds, as a live transcript needs. Once the call is over, `conclude` sorts
/// all the prints again, together, each by every other, rather than by the first ones heard, so the transcript can be
/// written again with who really spoke each line. Benchmarked on the AMI meetings, through call-quality audio, this
/// mislabels 2-7% of speech, where printing 3 s windows mislabeled 14-22%.
struct SpeakerTurns {
    /// A window: where in the audio it starts, in samples at `VoicePrinter.sampleRate`, and who talks in each frame.
    struct Window {
        let start: Int
        let frames: [Talkers]
    }

    /// A print of one of a window's people, from the frames they talk alone in; or, `isShort`, from too little of
    /// them alone to tell people apart by, which only joins whoever it sounds like most.
    struct Print {
        let print: [Float]
        let isShort: Bool
    }

    /// 5 s: two windows hear each moment. Benchmarked on the AMI meetings, every 2.5 s told people apart no better, at
    /// twice the cost, the segmentation model taking about 10 ms of CPU a window.
    static let windowStep = 80_000
    /// A print joins a speaker whose prints it is this close to on average, as in `VoiceGroups`; benchmarked on the
    /// AMI meetings, from 0.6 to 0.8 told people apart as well, and 0.75 merged two people in one.
    static let sameSpeaker: Float = 0.7
    /// Once the call is over, a speaker of fewer prints than this, about 15 s of speech, is someone else heard oddly,
    /// and joins whoever they sound like most: benchmarked, 6 merged the quietest of 3 people on a short call.
    static let fewestPrints = 3

    private(set) var windows: [Window] = []
    /// Each window's people's prints, by person; nil for one not heard enough to print.
    private var prints: [[Print?]] = []
    /// Who each window's people are, by person; nil for one not known.
    private(set) var speakers: [[Int?]] = []
    /// The sum and count of each speaker's prints, but short ones: how they sound on average.
    private var voices: [Int: (sum: [Float], count: Int)] = [:]
    private(set) var isConcluded = false

    /// How each speaker sounds: the average of their prints, but short ones, of length 1.
    var centers: [Int: [Float]] {
        voices.mapValues { vDSP.divide($0.sum, vDSP.sumOfSquares($0.sum).squareRoot()) }
    }

    /// How many prints each speaker has, but short ones.
    var printCounts: [Int: Int] { voices.mapValues(\.count) }

    /// Adds a window, with its people's prints, and says who each is: of the speakers heard so far, two of a window's
    /// people being two of them, the nearest, closest first; or, for a print that is not short, someone new.
    mutating func add(_ window: Window, prints windowPrints: [Print?]) {
        windows.append(window)
        prints.append(windowPrints)
        var people = [Int?](repeating: nil, count: windowPrints.count)
        var taken: Set<Int> = []
        let order = windowPrints.indices.filter { windowPrints[$0] != nil }
            .sorted { (windowPrints[$0]!.isShort ? 1 : 0, $0) < (windowPrints[$1]!.isShort ? 1 : 0, $1) }
        for person in order {
            let print = windowPrints[person]!
            let others = voices.filter { !taken.contains($0.key) }
            if let nearest = VoiceGroups.nearest(to: print.print, among: others),
                Self.distance(print.print, voices[nearest]!) <= Self.sameSpeaker
            {
                people[person] = nearest
            } else if !print.isShort {
                people[person] = (voices.keys.max() ?? 0) + 1
            }
            guard let speaker = people[person] else { continue }
            taken.insert(speaker)
            if !print.isShort { learn(print.print, of: speaker) }
        }
        speakers.append(people)
    }

    /// Sorts every print again, all together, now that the call is over: those not short by average linkage, then
    /// speakers of too few prints folded into others (see `VoiceGroups`), and the short ones to whoever they sound
    /// like most. Speakers are numbered again, in the order they are first heard.
    mutating func conclude() {
        isConcluded = true
        let places = prints.indices.flatMap { window in
            prints[window].indices.compactMap { person in prints[window][person].map { (window, person, $0) } }
        }
        let full = places.filter { !$0.2.isShort }
        guard !full.isEmpty else { return }
        let vectors = full.map(\.2.print)
        let groups = VoiceGroups.fold(
            VoiceGroups.group(vectors, within: Self.sameSpeaker),
            of: vectors,
            fewest: Self.fewestPrints
        )
        speakers = prints.map { [Int?](repeating: nil, count: $0.count) }
        voices = [:]
        for ((window, person, print), group) in zip(full, groups) {
            speakers[window][person] = group + 1
            learn(print.print, of: group + 1)
        }
        for (window, person, print) in places where print.isShort {
            speakers[window][person] = VoiceGroups.nearest(to: print.print, among: voices)
        }
    }

    /// Who talks in each of the time cells from `start` to `end`, in seconds into the audio, as the windows that hear
    /// each say: as many as they say on average, those most of them say talk. A cell is `Segmenter.frameStep` long.
    func talkers(from start: Double, to end: Double) -> [(cell: Int, speakers: [Int])] {
        let cells = Self.cell(at: start)..<max(Self.cell(at: end), Self.cell(at: start))
        guard !cells.isEmpty else { return [] }
        var heard = [Int](repeating: 0, count: cells.count)
        var talking = [Int](repeating: 0, count: cells.count)
        var votes = [[Int: Int]](repeating: [:], count: cells.count)
        let first = windows.partitioningIndex {
            $0.start + Segmenter.windowLength > cells.lowerBound * Segmenter.frameStep
        }
        for index in windows.indices[first...] {
            let window = windows[index]
            if window.start > cells.upperBound * Segmenter.frameStep { break }
            for (frame, talkers) in window.frames.enumerated() {
                let cell = (window.start + frame * Segmenter.frameStep + Segmenter.frameCenter) / Segmenter.frameStep
                guard cells.contains(cell) else { continue }
                let offset = cell - cells.lowerBound
                heard[offset] += 1
                talking[offset] += talkers.count
                for person in 0..<Segmenter.people where talkers.contains(.person(person)) {
                    if let speaker = speakers[index][person] { votes[offset][speaker, default: 0] += 1 }
                }
            }
        }
        return (0..<cells.count).compactMap { offset in
            guard heard[offset] > 0 else { return nil }
            let count = Int((Double(talking[offset]) / Double(heard[offset])).rounded())
            let ranked = votes[offset].sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(count).map(\.key)
            return (cells.lowerBound + offset, ranked)
        }
    }

    /// How long each speaker talks from `start` to `end`, in seconds into the audio.
    func talkTime(from start: Double, to end: Double) -> [Int: Double] {
        var time: [Int: Double] = [:]
        for (_, speakers) in talkers(from: start, to: end) {
            for speaker in speakers { time[speaker, default: 0] += Self.cellSeconds }
        }
        return time
    }

    static let cellSeconds = Double(Segmenter.frameStep) / VoicePrinter.sampleRate

    static func cell(at time: Double) -> Int { Int((time * VoicePrinter.sampleRate) / Double(Segmenter.frameStep)) }

    /// 1 less how alike `print` is to a speaker's prints, on average.
    static func distance(_ print: [Float], _ voice: (sum: [Float], count: Int)) -> Float {
        1 - vDSP.dot(print, voice.sum) / Float(voice.count)
    }

    private mutating func learn(_ print: [Float], of speaker: Int) {
        var voice = voices[speaker] ?? ([Float](repeating: 0, count: print.count), 0)
        vDSP.add(voice.sum, print, result: &voice.sum)
        voice.count += 1
        voices[speaker] = voice
    }
}

extension RandomAccessCollection {
    /// The index of the first element for which `isAfter` holds, it holding for every one after it.
    func partitioningIndex(where isAfter: (Element) -> Bool) -> Index {
        var (low, high) = (startIndex, endIndex)
        while low < high {
            let middle = index(low, offsetBy: distance(from: low, to: high) / 2)
            if isAfter(self[middle]) { high = middle } else { low = index(after: middle) }
        }
        return low
    }
}
