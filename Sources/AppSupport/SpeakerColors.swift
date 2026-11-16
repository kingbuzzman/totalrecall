/// Which color each speaker of a transcript gets: on each side, the first to speak its first color, the next the next,
/// and so on, so that everyone keeps theirs from their first line to their last. Another transcript starts over.
package struct SpeakerColors: Sendable {
    private var numbers: [TranscriptLine.Side: [String: Int]] = [:]

    package init() {}

    /// The number of the color of whoever said `line`, among their side's: given to them the first time they speak.
    package mutating func number(for line: TranscriptLine) -> Int {
        if let number = numbers[line.side]?[line.speaker] { return number }
        let number = numbers[line.side]?.count ?? 0
        numbers[line.side, default: [:]][line.speaker] = number
        return number
    }
}
