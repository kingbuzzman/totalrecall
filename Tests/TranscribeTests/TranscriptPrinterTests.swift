import Testing

@testable import Transcribe

struct TranscriptPrinterTests {
    let printer = TranscriptPrinter(printsLines: false, isLive: false)

    @Test func ordersTheTranscriptByTimeAcrossSpeakers() {
        printer.update(TranscriptUpdate(speaker: .them, start: 5, text: "Fine, thanks.", isFinal: true))
        printer.update(TranscriptUpdate(speaker: .you, start: 1, text: "How are you?", isFinal: true))

        #expect(printer.transcript == "[00:00:01] You: How are you?\n[00:00:05] Them: Fine, thanks.\n")
    }

    @Test func leavesOutTextStillBeingRecognized() {
        printer.update(TranscriptUpdate(speaker: nil, start: 0, text: "Hello", isFinal: true))
        printer.update(TranscriptUpdate(speaker: nil, start: 2, text: "wor", isFinal: false))

        #expect(printer.transcript == "[00:00:00] Hello\n")
    }

    @Test func dropsFinalTextWithoutWords() {
        printer.update(TranscriptUpdate(speaker: nil, start: 0, text: ".", isFinal: true))
        printer.update(TranscriptUpdate(speaker: nil, start: 1, text: "42", isFinal: true))

        #expect(printer.transcript == "[00:00:01] 42\n")
    }

    @Test(arguments: [(3_725.9, "01:02:05"), (59.99, "00:00:59"), (.nan, "00:00:00"), (.infinity, "00:00:00")])
    func timestampsEachLine(start: Double, time: String) {
        printer.update(TranscriptUpdate(speaker: nil, start: start, text: "Hi", isFinal: true))

        #expect(printer.transcript == "[\(time)] Hi\n")
    }
}
