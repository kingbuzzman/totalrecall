import AppSupport
import Testing

struct SpeakerColorsTests {
    @Test func numbersEachSidesSpeakersInTheOrderTheyFirstSpeak() {
        var colors = SpeakerColors()
        let lines = [
            TranscriptLine(time: "00:00:01", speaker: "Them 3", text: "Hi", heardOn: .them),
            TranscriptLine(time: "00:00:02", speaker: "Javier", text: "Hello", heardOn: .you),
            TranscriptLine(time: "00:00:03", speaker: "Them 7", text: "Morning", heardOn: .them),
            TranscriptLine(time: "00:00:04", speaker: "Them 3", text: "Shall we?", heardOn: .them),
            TranscriptLine(time: "00:00:05", speaker: "You", text: "Sure", heardOn: .you),
        ]

        #expect(lines.map { colors.number(for: $0) } == [0, 0, 1, 0, 1])
    }

    @Test func startsOverForAnotherTranscript() {
        var first = SpeakerColors()
        _ = first.number(for: TranscriptLine(time: "", speaker: "Them 3", text: "", heardOn: .them))
        var second = SpeakerColors()

        #expect(second.number(for: TranscriptLine(time: "", speaker: "Them 9", text: "", heardOn: .them)) == 0)
    }
}
