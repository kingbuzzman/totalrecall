import CoreAudio
import Foundation

@testable import TotalRecall

/// Host times on whole milliseconds, which are whole frames at the recording rate, so tests can expect exact counts.
struct Clock {
    let origin: UInt64

    init(origin: UInt64 = AudioGetCurrentHostTime()) {
        self.origin = origin
    }

    func at(milliseconds: Int) -> UInt64 {
        origin + AudioConvertNanosToHostTime(UInt64(milliseconds) * 1_000_000)
    }

    func before(milliseconds: Int) -> UInt64 {
        origin - AudioConvertNanosToHostTime(UInt64(milliseconds) * 1_000_000)
    }
}

func frameCount(milliseconds: Int) -> Int {
    Int(sampleRate) * milliseconds / 1_000
}

/// Distinct, non-zero samples, so a test can tell which ones were kept.
func ramp(_ count: Int, from start: Int = 0, scale: Float = 1e-5) -> [Float] {
    (start..<start + count).map { Float($0 + 1) * scale }
}

func constant(_ value: Float, count: Int) -> [Float] {
    [Float](repeating: value, count: count)
}

func silence(_ count: Int) -> [Float] {
    constant(0, count: count)
}

func sine(frequency: Double, count: Int, sampleRate: Double = sampleRate, amplitude: Float = 0.5) -> [Float] {
    (0..<count).map { amplitude * Float(sin(2 * .pi * frequency * Double($0) / sampleRate)) }
}

func rmsDecibels<Samples: Collection<Float>>(_ samples: Samples) -> Float {
    let meanSquare = samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))
    return 10 * log10(max(meanSquare, 1e-12))
}

/// Deterministic white noise in -1...1.
struct Noise {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func samples(_ count: Int, amplitude: Float) -> [Float] {
        (0..<count).map { _ in amplitude * next() }
    }

    private mutating func next() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(Int32(truncatingIfNeeded: state >> 32)) / Float(Int32.max)
    }
}

/// Collects what is written to it, the way a file would store it.
final class CapturingSink: AudioSink {
    private(set) var left: [Float] = []
    private(set) var right: [Float] = []
    private(set) var isClosed = false

    func write(left: [Float], right: [Float], count: Int) throws {
        self.left += Self.fitted(left, to: count)
        self.right += Self.fitted(right, to: count)
    }

    func close() {
        isClosed = true
    }

    private static func fitted(_ samples: [Float], to count: Int) -> [Float] {
        Array(samples.prefix(count)) + silence(max(count - samples.count, 0))
    }
}

func withTemporaryDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("totalrecall-tests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}
