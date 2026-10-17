import Testing

@testable import Transcribe

struct TranscriptPrinterTests {
    private static let clearLine = "\r\u{1B}[K"

    let output = Output()

    private func makePrinter(printsLines: Bool = false, live: Bool = false, width: Int = 80) -> TranscriptPrinter {
        TranscriptPrinter(
            printsLines: printsLines,
            isLive: live,
            isTerminal: live,
            terminalWidth: { width },
            write: output.append
        )
    }

    @Test func ordersTheTranscriptByTimeAcrossSpeakers() {
        let printer = makePrinter()
        printer.update(TranscriptUpdate(speaker: .them, start: 5, text: "Fine, thanks.", isFinal: true))
        printer.update(TranscriptUpdate(speaker: .you, start: 1, text: "How are you?", isFinal: true))

        #expect(printer.transcript == "[00:00:01] You: How are you?\n[00:00:05] Them: Fine, thanks.\n")
        #expect(output.text.isEmpty)
    }

    @Test func leavesOutTextStillBeingRecognized() {
        let printer = makePrinter()
        printer.update(TranscriptUpdate(speaker: nil, start: 0, text: "Hello", isFinal: true))
        printer.update(TranscriptUpdate(speaker: nil, start: 2, text: "wor", isFinal: false))

        #expect(printer.transcript == "[00:00:00] Hello\n")
    }

    @Test func dropsFinalTextWithoutWords() {
        let printer = makePrinter(printsLines: true)
        printer.update(TranscriptUpdate(speaker: nil, start: 0, text: ".", isFinal: true))
        printer.update(TranscriptUpdate(speaker: nil, start: 1, text: "42", isFinal: true))

        #expect(printer.transcript == "[00:00:01] 42\n")
        #expect(output.text == "[00:00:01] 42\n")
    }

    @Test(arguments: [(3_725.9, "01:02:05"), (59.99, "00:00:59"), (.nan, "00:00:00"), (.infinity, "00:00:00")])
    func timestampsEachLine(start: Double, time: String) {
        let printer = makePrinter()
        printer.update(TranscriptUpdate(speaker: nil, start: start, text: "Hi", isFinal: true))

        #expect(printer.transcript == "[\(time)] Hi\n")
    }

    @Test func printsFinalLinesAsTheyArrive() {
        let printer = makePrinter(printsLines: true)
        printer.update(TranscriptUpdate(speaker: .you, start: 1, text: "Hi", isFinal: true))
        printer.update(TranscriptUpdate(speaker: .them, start: 2, text: "Hel", isFinal: false))
        printer.update(TranscriptUpdate(speaker: .them, start: 2, text: "Hello", isFinal: true))

        #expect(output.text == "[00:00:01] You: Hi\n[00:00:02] Them: Hello\n")
    }

    @Test func showsTextStillBeingRecognizedDimmedOnTheLastLine() {
        let printer = makePrinter(printsLines: true, live: true)

        printer.update(TranscriptUpdate(speaker: .them, start: 0, text: "so the", isFinal: false))
        printer.update(TranscriptUpdate(speaker: .you, start: 0, text: "right", isFinal: false))

        #expect(output.text.hasSuffix(Self.clearLine + dimmed("… You: right  |  Them: so the")))
    }

    @Test func movesFinalTextAboveTheLiveLine() {
        let printer = makePrinter(printsLines: true, live: true)
        printer.update(TranscriptUpdate(speaker: .them, start: 0, text: "so the", isFinal: false))
        printer.update(TranscriptUpdate(speaker: .you, start: 0, text: "right", isFinal: false))
        output.clear()

        printer.update(TranscriptUpdate(speaker: .you, start: 0, text: "Right.", isFinal: true))

        #expect(output.text == Self.clearLine + "[00:00:00] You: Right.\n" + Self.clearLine + dimmed("… Them: so the"))
    }

    @Test func keepsTheMostRecentWordsThatFitTheTerminal() {
        let printer = makePrinter(printsLines: true, live: true, width: 21)

        printer.update(TranscriptUpdate(speaker: nil, start: 0, text: "one two three four five", isFinal: false))

        #expect(output.text.hasSuffix(dimmed("ne two three four five".suffix(20))))
    }

    @Test func clearsTheLiveLineWhenFinished() {
        let printer = makePrinter(printsLines: true, live: true)
        printer.update(TranscriptUpdate(speaker: nil, start: 0, text: "almost", isFinal: false))
        output.clear()

        printer.finish()

        #expect(output.text == Self.clearLine)
    }

    @Test func showsNoLiveLineOffATerminal() {
        let printer = TranscriptPrinter(printsLines: true, isLive: true, isTerminal: false, write: output.append)

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
