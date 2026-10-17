import Testing

@testable import AudioLab

struct RecordingAnalysisTests {
    private static let sampleRate = 48_000.0

    @Test func findsEveryClickOfACleanTrack() {
        let recording = record(seconds: 3, left: [ClickTrack(pitch: 1_000)])

        let train = recording.clicks(on: .left, pitches: [1_000])

        #expect(train.count == 30)
        #expect(train.longestGapMilliseconds == 0)
        #expect(train.offGrid.isEmpty)
        #expect(train.pitchOrder == [1_000])
    }

    @Test func measuresLostAudio() {
        var recording = record(seconds: 3, left: [ClickTrack(pitch: 1_000)])
        recording = recording.replacing(.left, from: 1.0, seconds: 0.35, with: 0)

        let train = recording.clicks(on: .left, pitches: [1_000])

        #expect(abs(train.longestGapMilliseconds - 300) < 5)
        #expect(train.gaps.count == 1)
        #expect(train.offGrid.isEmpty)
    }

    @Test func flagsAudioThatWasRepeated() {
        let recording = record(seconds: 3, left: [ClickTrack(pitch: 1_000)])
        let samples = recording.left
        let cut = Int(1.05 * Self.sampleRate)
        let repeated = Array(samples[..<cut]) + Array(samples[(cut - 2_400)...])

        let train = Recording(left: repeated, right: repeated, sampleRate: Self.sampleRate).clicks(
            on: .left,
            pitches: [1_000]
        )

        #expect(!train.offGrid.isEmpty)
    }

    @Test func followsTheOrderOfPitches() {
        let first = record(seconds: 1, left: [ClickTrack(pitch: 1_000)]).left
        let second = record(seconds: 1, left: [ClickTrack(pitch: 1_500)]).left
        let samples = first + second + first

        let train = Recording(left: samples, right: samples, sampleRate: Self.sampleRate)
            .clicks(on: .left, pitches: [1_000, 1_500])

        #expect(train.pitchOrder == [1_000, 1_500, 1_000])
        #expect(train.offGrid.isEmpty)
    }

    @Test func ignoresTheSkippedStartAndEnd() {
        let recording = record(seconds: 3, left: [ClickTrack(pitch: 1_000)])

        #expect(recording.clicks(on: .left, pitches: [1_000], skipStart: 1, skipEnd: 1).count == 10)
        #expect(recording.clicks(on: .left, pitches: [1_000], last: 0.5).count == 5)
    }

    @Test func measuresTheLevelOfATone() {
        let recording = record(seconds: 2, left: [ClickTrack(pitch: 3_000, gainDecibels: -12)])

        #expect(abs(recording.level(on: .left, pitch: 3_000) - -12) < 1)
        #expect(recording.level(on: .left, pitch: 1_000) < -60)
    }

    @Test func measuresHowFarTheChannelsDrift() throws {
        let steady = record(
            seconds: 6,
            left: [ClickTrack(pitch: 1_000)],
            right: [ClickTrack(pitch: 3_000, offsetMilliseconds: 50)]
        )

        let sync = try steady.sync(leftPitches: [1_000], rightPitch: 3_000)

        #expect(abs(sync.startMilliseconds - 50) < 2)
        #expect(sync.driftMilliseconds < 1)
    }

    @Test func refusesToMeasureSyncWithoutClicks() {
        let silent = Recording(
            left: [Float](repeating: 0, count: 48_000),
            right: [Float](repeating: 0, count: 48_000),
            sampleRate: Self.sampleRate
        )

        #expect(throws: AudioLabError.self) { try silent.sync(leftPitches: [1_000], rightPitch: 3_000) }
    }

    @Test func keepsTheLouderPitchOfAClickSplitBetweenTwo() {
        let clicks = [
            Click(time: 1.000, pitch: 1_000, amplitude: 0.1),
            Click(time: 1.005, pitch: 1_500, amplitude: 0.4),
            Click(time: 1.100, pitch: 1_500, amplitude: 0.4),
        ]

        #expect(mergingSplitClicks(clicks).map(\.pitch) == [1_500, 1_500])
    }

    private func record(seconds: Double, left: [ClickTrack], right: [ClickTrack] = []) -> Recording {
        let frames = Int(seconds * Self.sampleRate)
        func render(_ tracks: [ClickTrack]) -> [Float] {
            (0..<frames).map { frame in
                let time = Double(frame) / Self.sampleRate + 0.05
                return tracks.reduce(0) { $0 + $1.sample(at: time) }
            }
        }
        return Recording(left: render(left), right: render(right), sampleRate: Self.sampleRate)
    }
}

extension Recording {
    fileprivate func replacing(
        _ channel: Channel,
        from start: Double,
        seconds: Double,
        with value: Float
    ) -> Recording {
        var samples = self[channel]
        let range = Int(start * sampleRate)..<Int((start + seconds) * sampleRate)
        samples.replaceSubrange(range, with: repeatElement(value, count: range.count))
        return channel == .left
            ? Recording(left: samples, right: right, sampleRate: sampleRate)
            : Recording(left: left, right: samples, sampleRate: sampleRate)
    }
}
