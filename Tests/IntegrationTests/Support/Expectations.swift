import AudioLab
import Foundation
import Testing

/// Every click there, on the grid: nothing lost, repeated or skipped.
func expectNoLostAudio(
    _ train: ClickTrain,
    atLeast minimum: Int = 1,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(train.longestGapMilliseconds == 0, "\(train)", sourceLocation: sourceLocation)
    #expect(train.offGrid.isEmpty, "\(train)", sourceLocation: sourceLocation)
    #expect(train.count >= minimum, "\(train)", sourceLocation: sourceLocation)
}

func expectSaved(_ status: Int32, _ recording: TotalRecallProcess, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(status == 0, "totalrecall exited \(status): \(recording.logText)", sourceLocation: sourceLocation)
}

/// `--version` prints VERSION as is for a final build, VERSION-dev<commit> for any other CI build, and
/// VERSION-devYYYYMMDD.HHMMSS, the time of the build, for a local one.
func expectVersion(_ output: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
    let version = try #require(TestEnvironment.version, sourceLocation: sourceLocation)
    let suffix = TestEnvironment.isFinal ? "" : TestEnvironment.isCI ? "-dev[0-9a-f]{7,}" : #"-dev\d{8}\.\d{6}"#
    let pattern = try Regex(NSRegularExpression.escapedPattern(for: version) + suffix + "\n")
    #expect(output.wholeMatch(of: pattern) != nil, "printed \(output.debugDescription)", sourceLocation: sourceLocation)
}
