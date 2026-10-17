import AudioLab
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
