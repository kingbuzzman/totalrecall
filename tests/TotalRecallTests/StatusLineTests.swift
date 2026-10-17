import Testing

@testable import TotalRecall

struct StatusLineTests {
    @Test(arguments: [(0, "00:00:00"), (65_000, "00:01:05"), (3_725_000, "01:02:05")])
    func showsTheLengthOfTheRecording(milliseconds: Int, elapsed: String) {
        let clock = Clock()
        let recorder = Recorder(
            writingTo: CapturingSink(),
            includesMicrophone: false,
            isolatesSpeakers: true,
            cancelsEcho: false
        )
        recorder.startRecording(at: clock.at(milliseconds: 0))
        recorder.stopRecording(at: clock.at(milliseconds: milliseconds))

        #expect(StatusLine(recorder: recorder, isStreaming: false).elapsed == elapsed)
    }
}
