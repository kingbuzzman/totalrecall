import Testing

@testable import Transcribe

struct TranscriptPrinterTests {
    private static let clearLine = "\r\u{1B}[K"

    let output = Output()
    let saved = Output()

    private func makePrinter(
        printsLines: Bool = true,
        live: Bool = false,
        saves: Bool = false,
        width: Int = 80
    ) -> TranscriptPrinter {
        let saved = saved
        let save: ((String) -> Void)? = saves ? { saved.append($0) } : nil
        return TranscriptPrinter(
            printsLines: printsLines,
            isLive: live,
            terminalWidth: { width },
            write: output.append,
            save: save
        )
    }

    @Test func writesLinesInTheOrderTheySettleNotByTime() {
        let printer = makePrinter(saves: true)
        printer.update(TranscriptUpdate(speaker: .them, start: 5, text: "Fine, thanks.", isFinal: true))
        printer.update(TranscriptUpdate(speaker: .you, start: 1, text: "How are you?", isFinal: true))

        let lines = "[00:00:05] Them: Fine, thanks.\n[00:00:01] You: How are you?\n"
        #expect(output.text == lines)
        #expect(saved.text == lines)
    }

    @Test func leavesOutTextStillBeingRecognized() {
        let printer = makePrinter(saves: true)
        printer.update(TranscriptUpdate(speaker: nil, start: 0, text: "Hello", isFinal: true))
        printer.update(TranscriptUpdate(speaker: nil, start: 2, text: "wor", isFinal: false))

        #expect(output.text == "[00:00:00] Hello\n")
        #expect(saved.text == "[00:00:00] Hello\n")
    }

    @Test func dropsFinalTextWithoutWords() {
        let printer = makePrinter()
        printer.update(TranscriptUpdate(speaker: nil, start: 0, text: ".", isFinal: true))
        printer.update(TranscriptUpdate(speaker: nil, start: 1, text: "42", isFinal: true))

        #expect(output.text == "[00:00:01] 42\n")
    }

    @Test(arguments: [(3_725.9, "01:02:05"), (59.99, "00:00:59"), (.nan, "00:00:00"), (.infinity, "00:00:00")])
    func timestampsEachLine(start: Double, time: String) {
        let printer = makePrinter()
        printer.update(TranscriptUpdate(speaker: nil, start: start, text: "Hi", isFinal: true))

        #expect(output.text == "[\(time)] Hi\n")
    }

    @Test func savingAloneWritesNothingToStandardOutput() {
        let printer = makePrinter(printsLines: false, saves: true)
        printer.update(TranscriptUpdate(speaker: .you, start: 1, text: "Hi", isFinal: true))
        printer.finish()

        #expect(saved.text == "[00:00:01] You: Hi\n")
        #expect(output.text.isEmpty)
    }

    @Test func savesOnlySettledLinesWhileShowingTheLiveTranscript() {
        let printer = makePrinter(live: true, saves: true)
        printer.update(TranscriptUpdate(speaker: .them, start: 2, text: "Hel", isFinal: false))
        printer.update(TranscriptUpdate(speaker: .them, start: 2, text: "Hello", isFinal: true))
        printer.finish()

        #expect(saved.text == "[00:00:02] Them: Hello\n")
        #expect(output.text.contains(dimmed("… Them: Hel")))
    }

    @Test func showsTextStillBeingRecognizedDimmedOnTheLastLine() {
        let printer = makePrinter(live: true)

        printer.update(TranscriptUpdate(speaker: .them, start: 0, text: "so the", isFinal: false))
        printer.update(TranscriptUpdate(speaker: .you, start: 0, text: "right", isFinal: false))

        #expect(output.text.hasSuffix(Self.clearLine + dimmed("… You: right  |  Them: so the")))
    }

    @Test func movesFinalTextAboveTheLiveLine() {
        let printer = makePrinter(live: true)
        printer.update(TranscriptUpdate(speaker: .them, start: 0, text: "so the", isFinal: false))
        printer.update(TranscriptUpdate(speaker: .you, start: 0, text: "right", isFinal: false))
        output.clear()

        printer.update(TranscriptUpdate(speaker: .you, start: 0, text: "Right.", isFinal: true))

        #expect(output.text == Self.clearLine + "[00:00:00] You: Right.\n" + Self.clearLine + dimmed("… Them: so the"))
    }

    @Test func labelsALineWithWhoOnTheChannelSpokeIt() {
        let printer = makePrinter(saves: true)
        printer.update(TranscriptUpdate(speaker: .them, start: 3, text: "Hi.", isFinal: true, voice: "Them 2"))

        #expect(saved.text == "[00:00:03] Them 2: Hi.\n")
    }

    @Test func clearsTheChannelsLiveTextOnceTheLineSaysWhoSpokeIt() {
        let printer = makePrinter(live: true)
        printer.update(TranscriptUpdate(speaker: .them, start: 0, text: "so the", isFinal: false))
        output.clear()

        printer.update(TranscriptUpdate(speaker: .them, start: 0, text: "So the.", isFinal: true, voice: "Them 2"))

        #expect(output.text == Self.clearLine + "[00:00:00] Them 2: So the.\n" + Self.clearLine)
    }

    @Test func keepsShowingTheWordsAfterALineHeldBackToSayWhoSpokeIt() {
        let printer = makePrinter(live: true)
        printer.update(TranscriptUpdate(speaker: .them, start: 6, text: "and then", isFinal: false))
        output.clear()

        printer.update(
            TranscriptUpdate(speaker: .them, start: 2, text: "Hello there.", isFinal: true, voice: "Them 2", end: 4)
        )

        #expect(
            output.text == Self.clearLine + "[00:00:02] Them 2: Hello there.\n" + Self.clearLine
                + dimmed("… Them: and then")
        )
    }

    @Test func keepsShowingALineHeldBackUntilItComes() {
        let printer = makePrinter(live: true)
        printer.update(TranscriptUpdate(speaker: .them, start: 2, text: "Hello the", isFinal: false))
        printer.update(
            TranscriptUpdate(speaker: .them, start: 2, text: "Hello there.", isFinal: true, end: 4, isHeld: true)
        )
        printer.update(TranscriptUpdate(speaker: .them, start: 6, text: "and then", isFinal: false))
        #expect(output.text.hasSuffix(dimmed("… Them: Hello there. and then")))
        output.clear()

        printer.update(
            TranscriptUpdate(speaker: .them, start: 2, text: "Hello there.", isFinal: true, voice: "Them 2", end: 4)
        )

        #expect(
            output.text == Self.clearLine + "[00:00:02] Them 2: Hello there.\n" + Self.clearLine
                + dimmed("… Them: and then")
        )
    }

    @Test func stopsShowingALineHeldBackThatNeverComes() {
        let printer = makePrinter(live: true, saves: true)
        printer.update(
            TranscriptUpdate(speaker: .you, start: 2, text: "Hello there.", isFinal: true, end: 4, isHeld: true)
        )
        printer.update(TranscriptUpdate(speaker: .you, start: 6, text: "and then", isFinal: false))
        output.clear()

        printer.update(TranscriptUpdate(speaker: .you, start: 2, text: "", isFinal: true, end: 4))

        #expect(output.text == Self.clearLine + dimmed("… You: and then"))
        #expect(saved.text.isEmpty)
    }

    @Test func keepsTheMostRecentWordsThatFitTheTerminal() {
        let printer = makePrinter(live: true, width: 21)

        printer.update(TranscriptUpdate(speaker: nil, start: 0, text: "one two three four five", isFinal: false))

        #expect(output.text.hasSuffix(dimmed("ne two three four five".suffix(20))))
    }

    @Test func clearsTheLiveLineWhenFinished() {
        let printer = makePrinter(live: true)
        printer.update(TranscriptUpdate(speaker: nil, start: 0, text: "almost", isFinal: false))
        output.clear()

        printer.finish()

        #expect(output.text == Self.clearLine)
    }

    @Test func showsNoLiveLineWithoutLive() {
        let printer = makePrinter()

        printer.update(TranscriptUpdate(speaker: nil, start: 0, text: "almost", isFinal: false))
        printer.finish()

        #expect(output.text.isEmpty)
    }

    private func dimmed<Text: StringProtocol>(_ text: Text) -> String {
        "\u{1B}[2m\(text)\u{1B}[0m"
    }
}

final class Output: @unchecked Sendable {
    private(set) var text = ""

    func append(_ string: String) {
        text += string
    }

    func clear() {
        text = ""
    }
}
