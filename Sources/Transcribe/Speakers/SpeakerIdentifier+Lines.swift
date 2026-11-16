import Foundation

/// Who said the words of a line: split where who speaks changes, by when its words were said.
extension SpeakerIdentifier {
    /// A word goes by who talks from this long before it to this long after it, as words' times are rough.
    private static let wordMargin = 0.1
    /// A turn of a line's words fewer than `fewestWords`, or shorter than `shortestTurn`, is taken for the speakers'
    /// around it: too short to be sure of, and more often a word's times being off than someone saying it.
    private static let fewestWords = 3
    private static let shortestTurn = 1.0
    /// Words no one is heard saying go to whoever talks the most this close around the line.
    private static let nearby = 2.0

    /// The line, split where who speaks changes, each part saying who spoke it (`voice`): as the speakers heard so far
    /// sound, or, once the call is over (`conclude`), as everyone does. A part is `fewestWords` words and `shortestTurn`
    /// long at least; a line without the times of its words is one part. Nobody, if nobody is heard near it.
    func parts(of line: TranscriptUpdate) -> [TranscriptUpdate] {
        let end = line.end ?? line.start
        let words = line.words.isEmpty ? [TimedWord(text: line.text, start: line.start, end: end)] : line.words
        return lock.withLock {
            if !turns.isConcluded { lines.append((line.start, end)) }
            var speakers = words.map { word in
                turns.talkTime(from: word.start - Self.wordMargin, to: word.end + Self.wordMargin).loudest
            }
            let nearby = turns.talkTime(from: line.start - Self.nearby, to: end + Self.nearby).loudest
            for index in speakers.indices where speakers[index] == nil {
                speakers[index] =
                    speakers[..<index].compactMap { $0 }.last ?? speakers[index...].compactMap { $0 }.first ?? nearby
            }
            return Self.turns(of: words, by: speakers).enumerated().map { index, turn in
                var part = line
                part.words = line.words.isEmpty ? [] : Array(words[turn.words])
                part.text = words[turn.words].map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                // The first part keeps the line's start, which the line held back to say who spoke it goes by.
                part.start = index == 0 ? line.start : words[turn.words.lowerBound].start
                part.end = line.words.isEmpty ? line.end : words[turn.words.upperBound - 1].end
                part.lineStart = line.start
                part.voice = turn.speaker.map { label($0) }
                return part
            }
        }
    }

    /// The words, in turns of one speaker each, those too short to be sure of taken for the turn before, or, for the
    /// first, the one after.
    private static func turns(of words: [TimedWord], by speakers: [Int?]) -> [(speaker: Int?, words: Range<Int>)] {
        var turns: [(speaker: Int?, words: Range<Int>)] = []
        for (index, speaker) in speakers.enumerated() {
            if let last = turns.last, last.speaker == speaker {
                turns[turns.count - 1].words = last.words.lowerBound..<index + 1
            } else {
                turns.append((speaker, index..<index + 1))
            }
        }
        func isShort(_ turn: (speaker: Int?, words: Range<Int>)) -> Bool {
            turn.words.count < fewestWords
                || words[turn.words.last!].end - words[turn.words.first!].start < shortestTurn
        }
        while turns.count > 1, let short = turns.indices.first(where: { isShort(turns[$0]) }) {
            let into = short == 0 ? 1 : short - 1
            let merged =
                min(
                    turns[short].words.lowerBound,
                    turns[into].words.lowerBound
                )..<max(
                    turns[short].words.upperBound,
                    turns[into].words.upperBound
                )
            turns[into].words = merged
            turns.remove(at: short)
            // Turns of the same speaker that now meet are one.
            if into > 0, turns.indices.contains(into), turns[into - 1].speaker == turns[into].speaker {
                turns[into - 1].words = turns[into - 1].words.lowerBound..<turns[into].words.upperBound
                turns.remove(at: into)
            } else if turns.indices.contains(into + 1), turns[into].speaker == turns[into + 1].speaker {
                turns[into].words = turns[into].words.lowerBound..<turns[into + 1].words.upperBound
                turns.remove(at: into + 1)
            }
        }
        return turns
    }

    /// Who a speaker is, as the transcript calls them.
    private func label(_ speaker: Int) -> String {
        if let final = finalNames[speaker] { return final }
        if var voice = recognized[speaker] {
            // Looked up each time, so a name given while the call goes on is used from then on.
            remember { voice = try database?.voice(voice.id) ?? voice }
            return voice.name ?? (voice.isYou ? Speaker.you.rawValue : "\(name) \(voice.person)")
        }
        if speaker == you { return Speaker.you.rawValue }
        guard database != nil else { return "\(name) \(speaker)" }
        // Someone not recognized on your microphone is you, as far as anyone knows, rather than someone else: a voice
        // of yours that sounds different for a while, as AirPods do after a pause, is not taken for someone else's.
        return isYours ? Speaker.you.rawValue : "\(name) \(Self.letter(speaker))"
    }

    /// A, B, …, Z, AA, AB, …: someone not remembered, by their number in this call.
    static func letter(_ number: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var (number, text) = (number, "")
        while number > 0 {
            text = String(letters[(number - 1) % 26]) + text
            number = (number - 1) / 26
        }
        return text
    }
}
