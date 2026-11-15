import Testing

@testable import AppSupport

struct TranscriptLineTests {
    @Test func splitsALineIntoTimeSpeakerAndText() {
        let line = TranscriptLine(parsing: "[00:01:23] Them 2: Sounds good: let's ship it.")

        #expect(line == TranscriptLine(time: "00:01:23", speaker: "Them 2", text: "Sounds good: let's ship it."))
        #expect(line.side == .them)
    }

    @Test(arguments: [
        ("[00:00:03] You: Today we review the plan.", TranscriptLine.Side.you),
        ("[00:00:05] Them: The migration finished.", .them),
        ("[00:00:07] Ada: Thanks.", .them),
        ("[00:00:09] Speaker 1: Hello.", .them),
        ("[00:00:11] Hello everyone.", .unknown),
    ])
    func tellsYourLinesFromTheOthers(line: String, side: TranscriptLine.Side) {
        #expect(TranscriptLine(parsing: line).side == side)
    }

    @Test func keepsALineWithoutASpeakerWhole() {
        #expect(
            TranscriptLine(parsing: "[00:00:11] Hello everyone.")
                == TranscriptLine(time: "00:00:11", speaker: "", text: "Hello everyone.")
        )
        #expect(
            TranscriptLine(parsing: "not a transcript line")
                == TranscriptLine(time: "", speaker: "", text: "not a transcript line")
        )
    }

    @Test func splitsTheWordsStillBeingRecognizedBySpeaker() {
        #expect(
            TranscriptLine.parsing(liveText: "You: Good mor  |  Them: Hi there")
                == [
                    TranscriptLine(time: "", speaker: "You", text: "Good mor"),
                    TranscriptLine(time: "", speaker: "Them", text: "Hi there"),
                ]
        )
        #expect(TranscriptLine.parsing(liveText: "").isEmpty)
    }
}
