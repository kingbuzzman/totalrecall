import CoreAudio
import Testing

@testable import TotalRecall

struct RateWatchTests {
    private static let bufferFrames = 512.0

    let watch = RateWatch(expectedRate: 48_000)

    @Test func acceptsADeviceDeliveringAtTheExpectedRate() {
        #expect(deliver(rate: 48_000, buffers: 20).allSatisfy { $0 })
    }

    @Test func toleratesASingleOddTimestamp() {
        var stamps = timestamps(rate: 48_000, buffers: 10)
        stamps[5].mSampleTime += 200

        #expect(stamps.map(watch.isOnRate).allSatisfy { $0 })
    }

    @Test func givesUpForGoodOnceTheDeviceSwitchesRate() {
        let switched = deliver(rate: 44_100, buffers: 5)
        let afterwards = deliver(rate: 48_000, buffers: 5, startingAt: 1)

        #expect(switched == [true, true, true, false, false])
        #expect(afterwards.allSatisfy { !$0 })
    }

    @Test func trustsTimestampsWithoutValidTimes() {
        var stamps = timestamps(rate: 44_100, buffers: 10)
        for index in stamps.indices { stamps[index].mFlags = [] }

        #expect(stamps.map(watch.isOnRate).allSatisfy { $0 })
    }

    private func deliver(rate: Double, buffers: Int, startingAt seconds: Double = 0) -> [Bool] {
        timestamps(rate: rate, buffers: buffers, startingAt: seconds).map(watch.isOnRate)
    }

    private func timestamps(rate: Double, buffers: Int, startingAt seconds: Double = 0) -> [AudioTimeStamp] {
        (0..<buffers).map { index in
            var stamp = AudioTimeStamp()
            stamp.mSampleTime = seconds * 48_000 + Double(index) * Self.bufferFrames
            stamp.mHostTime = AudioConvertNanosToHostTime(
                UInt64((seconds + Double(index) * Self.bufferFrames / rate) * 1e9)
            )
            stamp.mFlags = [.sampleTimeValid, .hostTimeValid]
            return stamp
        }
    }
}
