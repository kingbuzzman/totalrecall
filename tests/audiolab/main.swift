import AVFoundation
import CoreAudio
import Foundation

// audiolab: test helper for totalrecall's integration tests. It needs no real microphone or speakers, so it runs on
// headless CI machines; the only hardware it uses is BlackHole loopback devices.
//
// A fake mic is a process that plays a known click track into a loopback device (whatever is played into BlackHole
// comes back out of its input) and publishes a public aggregate device wrapping that loopback. The aggregate is a
// real, input-capable device: it can become the system input, change sample rate, and appear or disappear when the
// fake-mic process starts or stops, which is how AirPods look to totalrecall.
//
// Clicks are phase-locked to the host clock (a burst every --interval ms, at --offset ms past each interval), so every
// fake device and the system track share one time grid, and a recording can be checked for dropped audio, silence,
// and channel sync regardless of which device produced it.

let usage = """
    usage: audiolab fake-mic --name NAME --loopback DEVICE --pitch HZ [--interval MS] [--offset MS] [--silent-for S]
                             [--echo-pitch HZ --echo-offset MS --echo-gain DB]
           audiolab play --device DEVICE --pitch HZ [--interval MS] [--offset MS] [--gain DB]
           audiolab set-input NAME | set-output NAME | set-rate NAME RATE
           audiolab default-input | default-output
           audiolab wait-device NAME [--timeout S] | wait-gone NAME [--timeout S]
           audiolab has-device NAME
           audiolab cleanup
           audiolab info FILE
           audiolab analyze FILE --channel left|right --pitches HZ[,HZ...] [--interval MS] [--tolerance MS]
                            [--max-gap MS] [--max-skips N] [--min-clicks N] [--expect-order HZ[,HZ...]]
                            [--skip-start S | --tail S] [--skip-end S]
           audiolab level FILE --channel left|right --pitch HZ [--skip-start S]
           audiolab sync FILE --left-pitches HZ[,HZ...] --right-pitch HZ [--interval MS] [--max-drift MS]
    """

let fakeDeviceUIDPrefix = "audiolab-"
let burstSeconds = 0.010
let defaultIntervalMilliseconds = 100.0
let fakeMicGainDecibels = -6.0

func fail(_ message: String) -> Never {
    fputs("audiolab: \(message)\n", stderr)
    exit(1)
}

func check(_ status: OSStatus, _ action: String) {
    if status != noErr { fail("\(action) failed (OSStatus \(status))") }
}

// MARK: - Arguments

struct Options {
    var positional: [String] = []
    var named: [String: String] = [:]

    init(_ arguments: ArraySlice<String>) {
        var remaining = arguments
        while let argument = remaining.popFirst() {
            if argument.hasPrefix("--") {
                guard let value = remaining.popFirst() else { fail("\(argument) needs a value") }
                named[String(argument.dropFirst(2))] = value
            } else {
                positional.append(argument)
            }
        }
    }

    func string(_ name: String) -> String {
        guard let value = named[name] else { fail("missing --\(name)\n\(usage)") }
        return value
    }

    func double(_ name: String, default defaultValue: Double? = nil) -> Double {
        guard let text = named[name] else {
            guard let defaultValue else { fail("missing --\(name)\n\(usage)") }
            return defaultValue
        }
        guard let value = Double(text) else { fail("--\(name) must be a number") }
        return value
    }

    func optionalDouble(_ name: String) -> Double? {
        guard let text = named[name] else { return nil }
        guard let value = Double(text) else { fail("--\(name) must be a number") }
        return value
    }

    func doubles(_ name: String) -> [Double] {
        string(name).split(separator: ",").map { text in
            guard let value = Double(text) else { fail("--\(name) must be numbers") }
            return value
        }
    }

    func argument(_ index: Int, _ label: String) -> String {
        guard positional.count > index else { fail("missing \(label)\n\(usage)") }
        return positional[index]
    }
}

// MARK: - Core Audio helpers

let systemObject = AudioObjectID(kAudioObjectSystemObject)

func propertyAddress(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}

func stringProperty(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
    var address = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr, let value else { return nil }
    return value.takeRetainedValue() as String
}

func allDevices() -> [AudioDeviceID] {
    var address = propertyAddress(kAudioHardwarePropertyDevices)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &size) == noErr else { return [] }
    var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &devices) == noErr else { return [] }
    return devices
}

func device(named name: String) -> AudioDeviceID? {
    allDevices().first { stringProperty($0, kAudioObjectPropertyName) == name }
}

func requireDevice(named name: String) -> AudioDeviceID {
    guard let deviceID = device(named: name) else { fail("no device named \"\(name)\"") }
    return deviceID
}

func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioDeviceID {
    var address = propertyAddress(selector)
    var deviceID = AudioDeviceID(kAudioObjectUnknown)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    AudioObjectGetPropertyData(systemObject, &address, 0, nil, &size, &deviceID)
    return deviceID
}

func setDefaultDevice(_ selector: AudioObjectPropertySelector, to deviceID: AudioDeviceID, name: String) {
    var address = propertyAddress(selector)
    var value = deviceID
    check(AudioObjectSetPropertyData(systemObject, &address, 0, nil, UInt32(MemoryLayout<AudioDeviceID>.size), &value), "selecting \(name)")
    guard defaultDevice(selector) == deviceID else { fail("macOS refused \"\(name)\" as the default device") }
}

func nominalSampleRate(_ deviceID: AudioDeviceID) -> Double {
    var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
    var rate = 0.0
    var size = UInt32(MemoryLayout<Double>.size)
    AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &rate)
    return rate
}

func waitUntil(_ description: String, timeout: Double, _ condition: () -> Bool) {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { fail("timed out waiting for \(description)") }
        Thread.sleep(forTimeInterval: 0.05)
    }
}

// MARK: - Click tracks

struct ClickTrack {
    let pitch: Double
    let interval: Double
    let offset: Double
    let amplitude: Float

    /// Value of this track at an absolute host time in seconds.
    func sample(at seconds: Double) -> Float {
        let phase = (seconds - offset).truncatingRemainder(dividingBy: interval)
        let positivePhase = phase < 0 ? phase + interval : phase
        guard positivePhase < burstSeconds else { return 0 }
        return amplitude * Float(sin(2 * Double.pi * pitch * positivePhase))
    }
}

func decibelsToAmplitude(_ decibels: Double) -> Float {
    Float(pow(10, decibels / 20))
}

func hostSeconds(_ hostTime: UInt64) -> Double {
    Double(AudioConvertHostTimeToNanos(hostTime)) / 1e9
}

/// Plays click tracks phase-locked to the host clock on one device. Uses each buffer's output time stamp (when it
/// will be heard) and the device's current sample rate, so the grid holds through latency and rate changes.
final class ClickPlayer {
    private let device: AudioDeviceID
    private var ioProcID: AudioDeviceIOProcID?
    private let sampleRate: UnsafeMutablePointer<Double>
    private var rateListener: AudioObjectPropertyListenerBlock?

    init(device: AudioDeviceID, tracks: [ClickTrack], silentUntil: Double = 0) {
        self.device = device
        sampleRate = UnsafeMutablePointer<Double>.allocate(capacity: 1)
        sampleRate.pointee = nominalSampleRate(device)
        let sampleRate = sampleRate
        let rateListener: AudioObjectPropertyListenerBlock = { _, _ in sampleRate.pointee = nominalSampleRate(device) }
        var rateAddress = propertyAddress(kAudioDevicePropertyNominalSampleRate)
        AudioObjectAddPropertyListenerBlock(device, &rateAddress, nil, rateListener)
        self.rateListener = rateListener
        check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, device, nil) { _, _, _, outputData, outputTime in
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
        }, "registering playback")
    }

    func start() {
        check(AudioDeviceStart(device, ioProcID), "starting playback")
    }

    func stop() {
        AudioDeviceStop(device, ioProcID)
        if let ioProcID { AudioDeviceDestroyIOProcID(device, ioProcID) }
        if let rateListener {
            var rateAddress = propertyAddress(kAudioDevicePropertyNominalSampleRate)
            AudioObjectRemovePropertyListenerBlock(device, &rateAddress, nil, rateListener)
        }
    }
}

func waitForTermination(cleanup: @escaping () -> Void) -> Never {
    let terminationSignals = [SIGINT, SIGTERM, SIGHUP]
    for signalNumber in terminationSignals { signal(signalNumber, SIG_IGN) }
    let sources = terminationSignals.map { signalNumber in
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler {
            cleanup()
            exit(0)
        }
        source.resume()
        return source
    }
    withExtendedLifetime(sources) { dispatchMain() }
}

// MARK: - Commands

func play(_ options: Options) -> Never {
    let track = ClickTrack(
        pitch: options.double("pitch"),
        interval: options.double("interval", default: defaultIntervalMilliseconds) / 1000,
        offset: options.double("offset", default: 0) / 1000,
        amplitude: decibelsToAmplitude(options.double("gain", default: fakeMicGainDecibels))
    )
    let player = ClickPlayer(device: requireDevice(named: options.string("device")), tracks: [track])
    player.start()
    print("playing")
    fflush(stdout)
    waitForTermination { player.stop() }
}

func fakeMic(_ options: Options) -> Never {
    let name = options.string("name")
    let loopback = requireDevice(named: options.string("loopback"))
    guard let loopbackUID = stringProperty(loopback, kAudioDevicePropertyDeviceUID) else { fail("cannot read loopback device UID") }
    let interval = options.double("interval", default: defaultIntervalMilliseconds) / 1000
    var tracks = [ClickTrack(pitch: options.double("pitch"), interval: interval, offset: options.double("offset", default: 0) / 1000, amplitude: decibelsToAmplitude(fakeMicGainDecibels))]
    if let echoPitch = options.optionalDouble("echo-pitch") {
        tracks.append(ClickTrack(pitch: echoPitch, interval: interval, offset: options.double("echo-offset") / 1000, amplitude: decibelsToAmplitude(options.double("echo-gain"))))
    }
    let silentUntil = hostSeconds(AudioGetCurrentHostTime()) + options.double("silent-for", default: 0)
    let player = ClickPlayer(device: loopback, tracks: tracks, silentUntil: silentUntil)
    player.start()

    let aggregateDescription: [String: Any] = [
        kAudioAggregateDeviceNameKey: name,
        kAudioAggregateDeviceUIDKey: fakeDeviceUIDPrefix + UUID().uuidString,
        kAudioAggregateDeviceIsPrivateKey: false,
        kAudioAggregateDeviceMainSubDeviceKey: loopbackUID,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: loopbackUID]],
    ]
    var aggregateID = AudioObjectID(kAudioObjectUnknown)
    check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateID), "creating fake mic")
    print("ready \(aggregateID)")
    fflush(stdout)
    waitForTermination {
        AudioHardwareDestroyAggregateDevice(aggregateID)
        player.stop()
    }
}

/// Destroys fake mics left behind by fake-mic processes that were killed before they could clean up.
func cleanup() {
    for device in allDevices() where stringProperty(device, kAudioDevicePropertyDeviceUID)?.hasPrefix(fakeDeviceUIDPrefix) == true {
        AudioHardwareDestroyAggregateDevice(device)
    }
}

// MARK: - Analysis

struct Recording {
    let left: [Float]
    let right: [Float]
    let sampleRate: Double
    let fileFormat: AVAudioFormat
    let duration: Double

    init(path: String) {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: URL(fileURLWithPath: path), commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            fail("cannot read \(path): \(error.localizedDescription)")
        }
        guard file.length > 0, let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
            fail("\(path) is empty")
        }
        do {
            try file.read(into: buffer)
        } catch {
            fail("cannot read \(path): \(error.localizedDescription)")
        }
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        left = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: frameCount))
        right = Array(UnsafeBufferPointer(start: buffer.floatChannelData![min(1, channelCount - 1)], count: frameCount))
        sampleRate = file.processingFormat.sampleRate
        fileFormat = file.fileFormat
        duration = Double(frameCount) / sampleRate
    }

    func channel(_ name: String) -> [Float] {
        switch name {
        case "left": return left
        case "right": return right
        default: fail("--channel must be left or right")
        }
    }
}

/// Amplitude of `pitch` in each analysis window (Goertzel), one value every `hop` frames.
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

struct Click {
    let time: Double
    let pitch: Double
    let amplitude: Float
}

func detectClicks(_ samples: [Float], pitches: [Double], sampleRate: Double) -> [Click] {
    let window = Int(sampleRate * burstSeconds)
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
            var peakIndex = index
            var end = index
            while end < amplitudes.count && amplitudes[end] >= threshold {
                if amplitudes[end] > amplitudes[peakIndex] { peakIndex = end }
                end += 1
            }
            clicks.append(Click(time: Double(peakIndex * hop + window / 2) / sampleRate, pitch: pitch, amplitude: amplitudes[peakIndex]))
            index = end + refractoryHops
        }
    }
    return mergingSplitClicks(clicks.sorted { $0.time < $1.time })
}

/// A device switch can land in the middle of a click, which is then part one pitch and part another and is detected
/// once per pitch, a few milliseconds apart. Clicks are 100 ms apart, so detections this close are one click: keep the
/// louder one.
func mergingSplitClicks(_ clicks: [Click]) -> [Click] {
    let sameClickSeconds = 0.02
    var merged: [Click] = []
    for click in clicks {
        if let last = merged.last, click.time - last.time < sameClickSeconds {
            if click.amplitude > last.amplitude { merged[merged.count - 1] = click }
        } else {
            merged.append(click)
        }
    }
    return merged
}

func analyze(_ options: Options) -> Never {
    let recording = Recording(path: options.argument(0, "FILE"))
    let channelName = options.string("channel")
    let interval = options.double("interval", default: defaultIntervalMilliseconds) / 1000
    let tolerance = options.double("tolerance", default: 10) / 1000
    let skipEnd = options.double("skip-end", default: 0)
    let skipStart = options.optionalDouble("tail").map { max(recording.duration - skipEnd - $0, 0) } ?? options.double("skip-start", default: 0)
    let clicks = detectClicks(recording.channel(channelName), pitches: options.doubles("pitches"), sampleRate: recording.sampleRate)
        .filter { $0.time >= skipStart && $0.time <= recording.duration - skipEnd }

    var longestGap = 0.0
    var offGrid: [String] = []
    var gaps: [String] = []
    for (previous, next) in zip(clicks, clicks.dropFirst()) {
        let spacing = next.time - previous.time
        let intervals = (spacing / interval).rounded()
        if abs(spacing - intervals * interval) > tolerance || intervals < 1 {
            offGrid.append(String(format: "%.3fs (spacing %.0f ms)", previous.time, spacing * 1000))
        }
        if intervals > 1 {
            longestGap = max(longestGap, spacing - interval)
            gaps.append(String(format: "%.3fs (%.0f ms)", previous.time, (spacing - interval) * 1000))
        }
    }
    var order: [Double] = []
    for click in clicks where order.last != click.pitch { order.append(click.pitch) }

    let expectedClicks = Int((recording.duration - skipStart - skipEnd) / interval)
    print(String(format: "    %@: %d clicks (~%d expected), longest gap %.0f ms, %d off-grid, pitch order %@",
                 channelName, clicks.count, expectedClicks, longestGap * 1000, offGrid.count,
                 order.map { String(Int($0)) }.joined(separator: " -> ")))
    if !gaps.isEmpty { print("      gaps at: \(gaps.prefix(8).joined(separator: ", "))") }
    if !offGrid.isEmpty { print("      off-grid at: \(offGrid.prefix(8).joined(separator: ", "))") }

    var failures: [String] = []
    if let maxGap = options.optionalDouble("max-gap"), longestGap * 1000 > maxGap {
        failures.append(String(format: "longest gap %.0f ms > %.0f ms", longestGap * 1000, maxGap))
    }
    if let maxSkips = options.optionalDouble("max-skips"), Double(offGrid.count) > maxSkips {
        failures.append("\(offGrid.count) off-grid clicks > \(Int(maxSkips))")
    }
    if let minClicks = options.optionalDouble("min-clicks"), Double(clicks.count) < minClicks {
        failures.append("\(clicks.count) clicks < \(Int(minClicks))")
    }
    if options.named["expect-order"] != nil, order != options.doubles("expect-order") {
        failures.append("pitch order \(order.map { Int($0) }) != expected \(options.doubles("expect-order").map { Int($0) })")
    }
    guard failures.isEmpty else { fail(failures.joined(separator: "; ")) }
    exit(0)
}

func level(_ options: Options) -> Never {
    let recording = Recording(path: options.argument(0, "FILE"))
    let skipStart = options.double("skip-start", default: 0)
    let samples = recording.channel(options.string("channel"))
    let window = Int(recording.sampleRate * burstSeconds)
    let amplitudes = toneAmplitudes(samples, pitch: options.double("pitch"), sampleRate: recording.sampleRate, window: window, hop: window / 4)
    let skippedWindows = Int(skipStart * recording.sampleRate) / (window / 4)
    // The loudest 2% of windows are the click peaks; their median is a stable level even when the clicks are faint.
    let peaks = amplitudes.dropFirst(skippedWindows).sorted(by: >)
    let peakLevel = peaks.isEmpty ? 0 : peaks[min(peaks.count - 1, peaks.count / 100)]
    print(String(format: "%.1f", 20 * log10(max(Double(peakLevel), 1e-7))))
    exit(0)
}

func sync(_ options: Options) -> Never {
    let recording = Recording(path: options.argument(0, "FILE"))
    let interval = options.double("interval", default: defaultIntervalMilliseconds) / 1000
    let leftClicks = detectClicks(recording.left, pitches: options.doubles("left-pitches"), sampleRate: recording.sampleRate)
    let rightClicks = detectClicks(recording.right, pitches: [options.double("right-pitch")], sampleRate: recording.sampleRate)
    guard leftClicks.count > 10, rightClicks.count > 10 else {
        fail("not enough clicks to measure sync (\(leftClicks.count) left, \(rightClicks.count) right)")
    }

    func medianOffset(_ range: ClosedRange<Double>) -> Double? {
        let offsets = leftClicks.filter { range.contains($0.time) }.compactMap { left in
            rightClicks.first { $0.time >= left.time }.map { ($0.time - left.time).truncatingRemainder(dividingBy: interval) }
        }.sorted()
        return offsets.isEmpty ? nil : offsets[offsets.count / 2]
    }
    let third = recording.duration / 3
    guard let earlyOffset = medianOffset(0...third), let lateOffset = medianOffset((2 * third)...recording.duration) else {
        fail("not enough clicks to measure sync")
    }
    let drift = abs(lateOffset - earlyOffset) * 1000
    print(String(format: "    sync: right trails left by %.1f ms at the start, %.1f ms at the end (drift %.1f ms)", earlyOffset * 1000, lateOffset * 1000, drift))
    if let maxDrift = options.optionalDouble("max-drift"), drift > maxDrift {
        fail(String(format: "drift %.1f ms > %.0f ms", drift, maxDrift))
    }
    exit(0)
}

func info(_ options: Options) -> Never {
    let recording = Recording(path: options.argument(0, "FILE"))
    let formatID = recording.fileFormat.streamDescription.pointee.mFormatID
    let code = String(bytes: withUnsafeBytes(of: formatID.bigEndian) { Array($0) }, encoding: .ascii) ?? "\(formatID)"
    print(String(format: "format=%@ channels=%d rate=%.0f duration=%.2f", code.trimmingCharacters(in: .whitespaces), recording.fileFormat.channelCount, recording.fileFormat.sampleRate, recording.duration))
    exit(0)
}

// MARK: - Main

let commandArguments = CommandLine.arguments.dropFirst()
guard let command = commandArguments.first else { fail(usage) }
let options = Options(commandArguments.dropFirst())
switch command {
case "fake-mic":
    fakeMic(options)
case "play":
    play(options)
case "set-input":
    let name = options.argument(0, "NAME")
    setDefaultDevice(kAudioHardwarePropertyDefaultInputDevice, to: requireDevice(named: name), name: name)
case "set-output":
    let name = options.argument(0, "NAME")
    setDefaultDevice(kAudioHardwarePropertyDefaultOutputDevice, to: requireDevice(named: name), name: name)
    setDefaultDevice(kAudioHardwarePropertyDefaultSystemOutputDevice, to: requireDevice(named: name), name: name)
case "set-rate":
    let name = options.argument(0, "NAME")
    guard let rate = Double(options.argument(1, "RATE")) else { fail("RATE must be a number") }
    let deviceID = requireDevice(named: name)
    var address = propertyAddress(kAudioDevicePropertyNominalSampleRate)
    var value = rate
    check(AudioObjectSetPropertyData(deviceID, &address, 0, nil, UInt32(MemoryLayout<Double>.size), &value), "setting \(name) sample rate")
    waitUntil("\(name) to run at \(Int(rate)) Hz", timeout: 5) { nominalSampleRate(deviceID) == rate }
case "default-input":
    print(stringProperty(defaultDevice(kAudioHardwarePropertyDefaultInputDevice), kAudioObjectPropertyName) ?? "")
case "default-output":
    print(stringProperty(defaultDevice(kAudioHardwarePropertyDefaultOutputDevice), kAudioObjectPropertyName) ?? "")
case "wait-device":
    let name = options.argument(0, "NAME")
    waitUntil("device \(name)", timeout: options.double("timeout", default: 5)) { device(named: name) != nil }
case "wait-gone":
    let name = options.argument(0, "NAME")
    waitUntil("device \(name) to disappear", timeout: options.double("timeout", default: 5)) { device(named: name) == nil }
case "has-device":
    exit(device(named: options.argument(0, "NAME")) == nil ? 1 : 0)
case "cleanup":
    cleanup()
case "info":
    info(options)
case "analyze":
    analyze(options)
case "level":
    level(options)
case "sync":
    sync(options)
default:
    fail(usage)
}
