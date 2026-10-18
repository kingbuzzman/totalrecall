import CoreAudio
import Foundation

/// A 10 ms tone burst every 100 ms, phase-locked to the host clock, so every device that plays one shares a time grid
/// and a recording can be checked for lost audio, silence and channel sync whichever device produced it.
package struct ClickTrack: Sendable {
    package static let burstSeconds = 0.010
    package static let intervalSeconds = 0.1

    package let pitch: Double
    let offsetSeconds: Double
    let amplitude: Float

    package init(pitch: Double, offsetMilliseconds: Double = 0, gainDecibels: Double = -6) {
        self.pitch = pitch
        offsetSeconds = offsetMilliseconds / 1_000
        amplitude = Float(pow(10, gainDecibels / 20))
    }

    /// The track as one command-line argument, `pitch,offset-seconds,amplitude`, for the player tool; exact, as Swift
    /// prints the shortest digits that read back as the same value.
    package var argument: String {
        "\(pitch),\(offsetSeconds),\(amplitude)"
    }

    /// A track from its `argument`.
    package init?(argument: String) {
        let parts = argument.split(separator: ",")
        guard parts.count == 3, let pitch = Double(parts[0]), let offset = Double(parts[1]),
            let amplitude = Float(parts[2])
        else { return nil }
        self.pitch = pitch
        offsetSeconds = offset
        self.amplitude = amplitude
    }

    func sample(at seconds: Double) -> Float {
        let phase = (seconds - offsetSeconds).truncatingRemainder(dividingBy: Self.intervalSeconds)
        let positivePhase = phase < 0 ? phase + Self.intervalSeconds : phase
        guard positivePhase < Self.burstSeconds else { return 0 }
        return amplitude * Float(sin(2 * .pi * pitch * positivePhase))
    }
}

/// Plays click tracks on one device. Each buffer is filled for the host time it will be heard at, at the device's
/// current sample rate, so the grid holds through latency and rate changes. The tests run each in a process of its own
/// (see `PlayerProcess`); the player tool is what runs it in-process.
package final class ClickPlayer: @unchecked Sendable {
    private let device: AudioDeviceID
    private let sampleRate: UnsafeMutablePointer<Double>
    /// EXPERIMENT: IOProc callbacks so far, read racily by the player tool's stats.
    package let callbacks = UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private var ioProcID: AudioDeviceIOProcID?
    private var rateListener: AudioObjectPropertyListenerBlock?

    package init(deviceNamed name: String, tracks: [ClickTrack], silentUntil: Double = 0) throws {
        let device = try AudioDevices.requireDevice(named: name)
        self.device = device
        let sampleRate = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        sampleRate.pointee = AudioDevices.nominalSampleRate(device)
        self.sampleRate = sampleRate
        let callbacks = callbacks
        callbacks.pointee = 0

        let rateListener: AudioObjectPropertyListenerBlock = { _, _ in
            sampleRate.pointee = AudioDevices.nominalSampleRate(device)
        }
        var rateAddress = AudioDevices.propertyAddress(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(device, &rateAddress, nil, rateListener)
        self.rateListener = rateListener

        try AudioDevices.check(
            AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, nil) { _, _, _, outputData, outputTime in
                callbacks.pointee += 1
                let startSeconds = hostSeconds(outputTime.pointee.mHostTime)
                let rate = sampleRate.pointee
                for buffer in UnsafeMutableAudioBufferListPointer(outputData) {
                    guard let data = buffer.mData, buffer.mNumberChannels > 0 else { continue }
                    let channelCount = Int(buffer.mNumberChannels)
                    let samples = data.assumingMemoryBound(to: Float.self)
                    let frameCount = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channelCount)
                    for frame in 0..<frameCount {
                        let seconds = startSeconds + Double(frame) / rate
                        let value = seconds < silentUntil ? 0 : tracks.reduce(0) { $0 + $1.sample(at: seconds) }
                        for channel in 0..<channelCount { samples[frame * channelCount + channel] = value }
                    }
                }
            },
            "playing on \(name)"
        )
        try AudioDevices.check(AudioDeviceStart(device, ioProcID), "starting \(name)")
    }

    package func stop() {
        if let ioProcID {
            AudioDeviceStop(device, ioProcID)
            AudioDeviceDestroyIOProcID(device, ioProcID)
        }
        ioProcID = nil
        if let rateListener {
            var rateAddress = AudioDevices.propertyAddress(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &rateAddress, nil, rateListener)
        }
        rateListener = nil
    }
}

func hostSeconds(_ hostTime: UInt64) -> Double {
    Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9
}
