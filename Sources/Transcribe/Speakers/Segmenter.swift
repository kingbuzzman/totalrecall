import CoreML
import Foundation
import Shared

/// Which of a window's people talk in one of its frames: up to 2 of its 3.
struct Talkers: OptionSet, Hashable {
    let rawValue: UInt8

    static func person(_ index: Int) -> Talkers { Talkers(rawValue: 1 << index) }

    var count: Int { rawValue.nonzeroBitCount }
}

/// Finds who talks when in a window of audio, at `VoicePrinter.sampleRate`: `Segmenter`, or a stand-in in the tests.
protocol SpeakerSegmenting {
    /// Who talks in each of the window's `Segmenter.frameCount` frames. The window is `Segmenter.windowLength` long.
    func segment(_ window: ArraySlice<Float>) throws -> [Talkers]
}

/// Who talks when in 10 s of audio: for each of its 589 frames, about 17 ms apart, which of up to 3 people talk, two at
/// once included, and nobody in pauses, music or noise. They are only this window's people: who each is, from one window
/// to the next, is for their voice prints to tell. pyannote's segmentation-3.0 (see `SpeakerModel`).
final class Segmenter: SpeakerSegmenting {
    static let windowLength = 160_000
    static let frameCount = 589
    static let people = 3
    /// Frame `i` hears the window's 991 samples from `i * frameStep`, so it is centered on `i * frameStep + frameCenter`.
    static let frameStep = 270
    static let frameCenter = 495
    /// The model's classes, in order: nobody, each alone, each pair.
    private static let classes: [Talkers] = [
        [], .person(0), .person(1), .person(2), [.person(0), .person(1)], [.person(0), .person(2)],
        [.person(1), .person(2)],
    ]

    private let model: MLModel
    private let input: MLMultiArray

    init(model: MLModel) throws {
        self.model = model
        input = try MLMultiArray(shape: [1, 1, NSNumber(value: Self.windowLength)], dataType: .float32)
    }

    /// The time, in seconds into a window, that its frame `index` is centered on.
    static func time(ofFrame index: Int) -> Double {
        Double(index * frameStep + frameCenter) / VoicePrinter.sampleRate
    }

    func segment(_ window: ArraySlice<Float>) throws -> [Talkers] {
        precondition(window.count == Self.windowLength, "a window of \(window.count) samples")
        window.withUnsafeBufferPointer { samples in
            input.dataPointer.bindMemory(to: Float.self, capacity: Self.windowLength)
                .update(from: samples.baseAddress!, count: Self.windowLength)
        }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
        let classCount = Self.classes.count
        guard let scores = output.featureValue(for: "classes")?.multiArrayValue,
            scores.count == Self.frameCount * classCount
        else { throw MessageError("the segmentation model gave no frames") }
        let values = MLShapedArray<Float>(converting: scores).scalars
        return (0..<Self.frameCount).map { frame in
            let row = values[frame * classCount..<(frame + 1) * classCount]
            return Self.classes[row.indices.max { row[$0] < row[$1] }! - frame * classCount]
        }
    }
}
