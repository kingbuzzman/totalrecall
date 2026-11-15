/// A line of a transcript, as `transcribe` writes it: "[00:01:23] Them 2: Sounds good.", split into its time, who spoke
/// and what they said, to show as a row of a table.
package struct TranscriptLine: Equatable, Sendable {
    /// Who spoke, from your side or the others', for telling them apart at a glance.
    package enum Side: Sendable {
        /// Your microphone: "You".
        case you
        /// Everyone else: "Them", "Them 2", "Speaker 1", or a name given with `transcribe speakers name`.
        case them
        /// No one in particular: a recording without the split of you and them.
        case unknown
    }

    /// When it was said, as HH:MM:SS from the start of the recording; "" for words still being recognized.
    package let time: String
    /// Who said it, as the transcript labels them; "" when it does not.
    package let speaker: String
    package let text: String

    package init(time: String, speaker: String, text: String) {
        self.time = time
        self.speaker = speaker
        self.text = text
    }

    package var side: Side {
        switch speaker {
        case "": .unknown
        case "You": .you
        default: .them
        }
    }

    /// A line of the transcript; one that does not start with a time is kept whole as its text.
    package init(parsing line: String) {
        guard let match = line.wholeMatch(of: /\[(\d{2}:\d{2}:\d{2})\] (.*)/) else {
            self.init(time: "", speaker: "", text: line)
            return
        }
        let (speaker, text) = Self.speakerAndText(String(match.2))
        self.init(time: String(match.1), speaker: speaker, text: text)
    }

    /// The words still being recognized, as `transcribe` shows them live: "You: Good mor  |  Them: Hi there", a line
    /// for each speaker.
    package static func parsing(liveText: String) -> [TranscriptLine] {
        liveText.split(separator: "  |  ").map { part in
            let (speaker, text) = speakerAndText(String(part))
            return TranscriptLine(time: "", speaker: speaker, text: text)
        }
    }

    /// "Them 2: Sounds good." -> ("Them 2", "Sounds good."). A label is short and has no colon of its own, so text that
    /// only happens to have a colon in it is not taken for one.
    private static func speakerAndText(_ line: String) -> (String, String) {
        guard let match = line.wholeMatch(of: /([^:]{1,40}): (.*)/) else { return ("", line) }
        return (String(match.1), String(match.2))
    }
}
