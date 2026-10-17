import AVFoundation
package import Foundation

package enum Channel: String, Sendable {
    case left
    case right
}

/// A stereo recording to analyze: the click tracks it holds, how loud a tone is, and how far the channels drift.
package struct Recording {
    package struct FileFormat: Equatable, CustomStringConvertible {
        /// The encoding's four-character code without padding, such as "lpcm", "aac", ".mp3" or "flac".
        package let codec: String
        package let channelCount: Int
        package let sampleRate: Double

        package init(codec: String, channelCount: Int, sampleRate: Double) {
            self.codec = codec
            self.channelCount = channelCount
            self.sampleRate = sampleRate
        }

        package var description: String { "\(codec), \(channelCount) channels, \(Int(sampleRate)) Hz" }
    }

    package let left: [Float]
    package let right: [Float]
    package let sampleRate: Double
    /// Nil for audio that did not come from a file.
    package let fileFormat: FileFormat?

    package var duration: Double { Double(left.count) / sampleRate }

    package init(left: [Float], right: [Float], sampleRate: Double) {
        self.left = left
        self.right = right
        self.sampleRate = sampleRate
        fileFormat = nil
    }

    package init(contentsOf url: URL) throws {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        guard
            file.length > 0,
            let buffer = AVAudioPCMBuffer(
                pcmFormat: file.processingFormat,
                frameCapacity: AVAudioFrameCount(file.length)
            )
        else {
            throw AudioLabError("\(url.path) is empty")
        }
        try file.read(into: buffer)
        let channels = (0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![channel], count: Int(buffer.frameLength)))
        }
        left = channels[0]
        right = channels[min(1, channels.count - 1)]
        sampleRate = file.processingFormat.sampleRate
        let formatID = (file.fileFormat.settings[AVFormatIDKey] as? UInt32) ?? 0
        let codec = String(bytes: withUnsafeBytes(of: formatID.bigEndian) { Array($0) }, encoding: .ascii) ?? ""
        fileFormat = FileFormat(
            codec: codec.trimmingCharacters(in: .whitespaces),
            channelCount: Int(file.fileFormat.channelCount),
            sampleRate: file.fileFormat.sampleRate
        )
    }

    package subscript(channel: Channel) -> [Float] {
        channel == .left ? left : right
    }

    /// The clicks of the given pitches on a channel, ignoring the first `skipStart` and last `skipEnd` seconds.
    package func clicks(
        on channel: Channel,
        pitches: [Double],
        skipStart: Double = 0,
        skipEnd: Double = 0
    ) -> ClickTrain {
        let end = duration - skipEnd
        let clicks = detectClicks(self[channel], pitches: pitches, sampleRate: sampleRate)
            .filter { $0.time >= skipStart && $0.time <= end }
        return ClickTrain(
            channel: channel,
            clicks: clicks,
            expectedCount: Int((end - skipStart) / ClickTrack.intervalSeconds)
        )
    }

    /// The clicks in the last `seconds` before the final `skipEnd` seconds.
    package func clicks(
        on channel: Channel,
        pitches: [Double],
        last seconds: Double,
        skipEnd: Double = 0
    ) -> ClickTrain {
        clicks(on: channel, pitches: pitches, skipStart: max(duration - skipEnd - seconds, 0), skipEnd: skipEnd)
    }

    /// How loud the clicks of `pitch` are, in dB: the median of the loudest 2% of analysis windows, which is stable
    /// even when the clicks are faint.
    package func level(on channel: Channel, pitch: Double, skipStart: Double = 0) -> Double {
        let window = Int(sampleRate * ClickTrack.burstSeconds)
        let amplitudes = toneAmplitudes(
            self[channel],
            pitch: pitch,
            sampleRate: sampleRate,
            window: window,
            hop: window / 4
        )
        let peaks = amplitudes.dropFirst(Int(skipStart * sampleRate) / (window / 4)).sorted(by: >)
        let level = peaks.isEmpty ? 0 : peaks[min(peaks.count - 1, peaks.count / 100)]
        return 20 * log10(max(Double(level), 1e-7))
    }

    /// How far the right channel's clicks trail the left channel's at the start and at the end of the recording.
    package func sync(leftPitches: [Double], rightPitch: Double) throws -> ChannelSync {
        let leftClicks = detectClicks(left, pitches: leftPitches, sampleRate: sampleRate)
        let rightClicks = detectClicks(right, pitches: [rightPitch], sampleRate: sampleRate)
        guard leftClicks.count > 10, rightClicks.count > 10 else {
            throw AudioLabError("too few clicks to measure sync (\(leftClicks.count) left, \(rightClicks.count) right)")
        }
        func medianOffset(_ range: ClosedRange<Double>) -> Double? {
            let offsets = leftClicks.filter { range.contains($0.time) }
                .compactMap { left in
                    rightClicks.first { $0.time >= left.time }
                        .map { ($0.time - left.time).truncatingRemainder(dividingBy: ClickTrack.intervalSeconds) }
                }
                .sorted()
            return offsets.isEmpty ? nil : offsets[offsets.count / 2]
        }
        let third = duration / 3
        guard let start = medianOffset(0...third), let end = medianOffset((2 * third)...duration) else {
            throw AudioLabError("too few clicks to measure sync")
        }
        return ChannelSync(startMilliseconds: start * 1_000, endMilliseconds: end * 1_000)
    }
}

package struct Click {
    package let time: Double
    package let pitch: Double
    let amplitude: Float
}

/// Clicks on one channel, checked against the 100 ms grid they were played on.
package struct ClickTrain: CustomStringConvertible {
    private static let toleranceSeconds = 0.010

    package let channel: Channel
    package let clicks: [Click]
    package let expectedCount: Int
    /// The longest stretch of missing clicks, beyond the normal interval.
    package let longestGapMilliseconds: Double
    /// Where clicks are missing.
    package let gaps: [Double]
    /// Where a click is off the grid, such as audio repeated or skipped at a device switch.
    package let offGrid: [Double]
    /// The pitches in the order they were heard, each run of the same pitch once.
    package let pitchOrder: [Double]

    init(channel: Channel, clicks: [Click], expectedCount: Int) {
        let interval = ClickTrack.intervalSeconds
        var gaps: [(time: Double, seconds: Double)] = []
        var offGrid: [Double] = []
        for (previous, next) in zip(clicks, clicks.dropFirst()) {
            let spacing = next.time - previous.time
            let intervals = (spacing / interval).rounded()
            if abs(spacing - intervals * interval) > Self.toleranceSeconds || intervals < 1 {
                offGrid.append(previous.time)
            }
            if intervals > 1 { gaps.append((previous.time, spacing - interval)) }
        }
        var pitchOrder: [Double] = []
        for click in clicks where pitchOrder.last != click.pitch { pitchOrder.append(click.pitch) }
        self.channel = channel
        self.clicks = clicks
        self.expectedCount = expectedCount
        longestGapMilliseconds = (gaps.map(\.seconds).max() ?? 0) * 1_000
        self.gaps = gaps.map(\.time)
        self.offGrid = offGrid
        self.pitchOrder = pitchOrder
    }

    package var count: Int { clicks.count }

    package var description: String {
        let order = pitchOrder.map { String(Int($0)) }.joined(separator: " -> ")
        var lines = [
            "\(channel): \(count) clicks (~\(expectedCount) expected), longest gap \(Int(longestGapMilliseconds)) ms, "
                + "\(offGrid.count) off-grid, pitch order \(order)"
        ]
        if !gaps.isEmpty { lines.append("gaps at \(Self.times(gaps))") }
        if !offGrid.isEmpty { lines.append("off-grid at \(Self.times(offGrid))") }
        return lines.joined(separator: "; ")
    }

    private static func times(_ seconds: [Double]) -> String {
        seconds.prefix(8).map { String(format: "%.3fs", $0) }.joined(separator: ", ")
    }
}

package struct ChannelSync: CustomStringConvertible {
    package let startMilliseconds: Double
    package let endMilliseconds: Double

    package var driftMilliseconds: Double { abs(endMilliseconds - startMilliseconds) }

    package var description: String {
        String(
            format: "right trails left by %.1f ms at the start, %.1f ms at the end (drift %.1f ms)",
            startMilliseconds,
            endMilliseconds,
            driftMilliseconds
        )
    }
}

/// The amplitude of `pitch` in each analysis window (Goertzel), one value every `hop` frames.
func toneAmplitudes(_ samples: [Float], pitch: Double, sampleRate: Double, window: Int, hop: Int) -> [Float] {
    let coefficient = Float(2 * cos(2 * Double.pi * pitch / sampleRate))
    var amplitudes: [Float] = []
    var start = 0
    while start + window <= samples.count {
        var previous: Float = 0
        var beforePrevious: Float = 0
        for index in start..<(start + window) {
            let current = samples[index] + coefficient * previous - beforePrevious
            beforePrevious = previous
            previous = current
        }
        let power = previous * previous + beforePrevious * beforePrevious - coefficient * previous * beforePrevious
        amplitudes.append(2 * sqrt(max(power, 0)) / Float(window))
        start += hop
    }
    return amplitudes
}

func detectClicks(_ samples: [Float], pitches: [Double], sampleRate: Double) -> [Click] {
    let window = Int(sampleRate * ClickTrack.burstSeconds)
    let hop = window / 4
    let refractoryHops = Int(0.03 * sampleRate) / hop
    let minimumAmplitude: Float = 0.003
    var clicks: [Click] = []
    for pitch in pitches {
        let amplitudes = toneAmplitudes(samples, pitch: pitch, sampleRate: sampleRate, window: window, hop: hop)
        let threshold = max((amplitudes.max() ?? 0) * 0.3, minimumAmplitude)
        var index = 0
        while index < amplitudes.count {
            guard amplitudes[index] >= threshold else {
                index += 1
                continue
            }
            var peak = index
            var end = index
            while end < amplitudes.count && amplitudes[end] >= threshold {
                if amplitudes[end] > amplitudes[peak] { peak = end }
                end += 1
            }
            let time = Double(peak * hop + window / 2) / sampleRate
            clicks.append(Click(time: time, pitch: pitch, amplitude: amplitudes[peak]))
            index = end + refractoryHops
        }
    }
    return mergingSplitClicks(clicks.sorted { $0.time < $1.time })
}

/// A device switch can land mid-click, which is then part one pitch and part another and detected once per pitch, a
/// few milliseconds apart. Clicks are 100 ms apart, so detections this close are one click: the louder one is kept.
func mergingSplitClicks(_ clicks: [Click]) -> [Click] {
    var merged: [Click] = []
    for click in clicks {
        if let last = merged.last, click.time - last.time < 0.02 {
            if click.amplitude > last.amplitude { merged[merged.count - 1] = click }
        } else {
            merged.append(click)
        }
    }
    return merged
}

/// Writes float channels to an audio file in the format its extension names.
package func writeAudioFile(_ channels: [[Float]], sampleRate: Double, to url: URL) throws {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: sampleRate,
        AVNumberOfChannelsKey: channels.count,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
    ]
    let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
    let buffer = AVAudioPCMBuffer(
        pcmFormat: file.processingFormat,
        frameCapacity: AVAudioFrameCount(channels[0].count)
    )!
    buffer.frameLength = buffer.frameCapacity
    for (index, samples) in channels.enumerated() {
        buffer.floatChannelData![index].update(from: samples, count: samples.count)
    }
    try file.write(from: buffer)
}
