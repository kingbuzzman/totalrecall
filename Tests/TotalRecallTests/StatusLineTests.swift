import Testing

@testable import TotalRecall

struct StatusLineTests {
    private static let clearLine = "\r\u{1B}[K"

    let clock = Clock()
    let output = Output()

    private func makeStatus(microphone: Bool = true, streaming: Bool = false, terminal: Bool) -> StatusLine {
        let recorder = Recorder(
            writingTo: CapturingSink(),
            includesMicrophone: microphone,
            isolatesSpeakers: true,
            cancelsEcho: false
        )
        return StatusLine(recorder: recorder, isStreaming: streaming, isTerminal: terminal, write: output.append)
    }

    @Test(arguments: [(0, "00:00:00"), (65_000, "00:01:05"), (3_725_000, "01:02:05")])
    func showsTheLengthOfTheRecording(milliseconds: Int, elapsed: String) {
        let status = makeStatus(terminal: false)
        status.recorder.startRecording(at: clock.at(milliseconds: 0))
        status.recorder.stopRecording(at: clock.at(milliseconds: milliseconds))

        #expect(status.elapsed == elapsed)
    }

    @Test func announcesOnALineOfItsOwn() {
        makeStatus(terminal: false).announce("mic -> AirPods")

        #expect(output.text == "totalrecall: mic -> AirPods\n")
    }

    @Test func clearsTheMeterBeforeAnnouncingOnATerminal() {
        makeStatus(terminal: true).announce("mic -> AirPods")

        #expect(output.text == Self.clearLine + "totalrecall: mic -> AirPods\n")
    }

    @Test func reportsWriteFailures() {
        makeStatus(terminal: false).reportWriteFailure(RecordingError("disk full"))

        #expect(output.text == "totalrecall: write failed: disk full\n")
    }

    @Test func redrawsTheMeterInPlaceOnATerminal() {
        let status = makeStatus(terminal: true)

        status.showLevels(LevelSnapshot(microphonePeak: 1, systemPeak: 0))

        #expect(output.text == Self.clearLine + "● 00:00:00  mic ██████████  system ··········")
    }

    @Test func leavesTheMicOutOfTheMeterWithoutOne() {
        let status = makeStatus(microphone: false, terminal: true)

        status.showLevels(LevelSnapshot(microphonePeak: 0, systemPeak: 1))

        #expect(output.text == Self.clearLine + "● 00:00:00  system ██████████")
    }

    @Test(arguments: [(false, false), (true, true)])
    func showsNoMeterOffATerminalOrWhileStreaming(terminal: Bool, streaming: Bool) {
        makeStatus(streaming: streaming, terminal: terminal).showLevels(LevelSnapshot(microphonePeak: 1, systemPeak: 1))

        #expect(output.text.isEmpty)
    }

    @Test(arguments: [(Float(2), 10), (1, 10), (0.0316, 5), (0.001, 0), (0, 0)])
    func metersPeaksOnASixtyDecibelScale(peak: Float, filled: Int) {
        #expect(
            StatusLine.meter(peak) == String(repeating: "█", count: filled) + String(repeating: "·", count: 10 - filled)
        )
    }
}

final class Output {
    private(set) var text = ""

    func append(_ string: String) {
        text += string
    }
}
