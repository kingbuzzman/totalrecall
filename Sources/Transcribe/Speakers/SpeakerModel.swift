import CoreML
import Foundation
import MachO
import Shared
import Synchronization

/// The speaker models, converted to Core ML into Models/ by the scripts in scripts/:
/// - voice prints: WeSpeaker's ResNet34-LM, trained on VoxCeleb, CC BY 4.0
///   (https://huggingface.co/Wespeaker/wespeaker-voxceleb-resnet34-LM), Models/SpeakerEmbedding.mlpackage;
/// - who talks when: pyannote's segmentation-3.0, MIT (https://huggingface.co/pyannote/segmentation-3.0),
///   Models/SpeakerSegmentation.mlpackage.
///
/// The Makefile builds each package's model and weights into transcribe, as sections of its binary, so it stays one file
/// to install, and Core ML loads them from there, in memory. They must stay there for as long as the model is used:
/// Core ML reads the weights again whenever it plans the model for an input length it has not had yet.
package enum SpeakerModel {
    /// What the database labels the voice prints with, as another model's mean nothing to it.
    package static let name = "wespeaker-voxceleb-resnet34-lm"
    /// The package's files, as the Makefile builds them in: the model, which names its weights `weights`, and those.
    private static let model = "Data/com.apple.CoreML/model.mlmodel"
    private static let weights = "Data/com.apple.CoreML/weights/weight.bin"
    private static let weightsName = "weights/weight.bin"
    /// Packages' models and weights, kept from when they are loaded on.
    private static let loaded = Mutex<[Data]>([])

    /// The voice print model built into transcribe.
    static func builtIn() async throws -> MLModel {
        try await load(model: section("__voice_model"), weights: section("__voice_weights"))
    }

    /// The who-talks-when model built into transcribe.
    static func builtInSegmentation() async throws -> MLModel {
        try await load(model: section("__seg_model"), weights: section("__seg_weights"))
    }

    /// The model of a package, such as Models/SpeakerEmbedding.mlpackage for the tests.
    static func load(package: URL) async throws -> MLModel {
        let (model, weights) = try (
            Data(contentsOf: package.appending(path: model)), Data(contentsOf: package.appending(path: weights))
        )
        loaded.withLock { $0 += [model, weights] }
        return try await load(model: model, weights: weights)
    }

    private static func load(model: Data, weights: Data) async throws -> MLModel {
        let asset = try MLModelAsset(specification: model, blobMapping: [URL(string: weightsName)!: weights])
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        return try await MLModel.load(asset: asset, configuration: configuration)
    }

    /// A section of transcribe's binary, where it is: mapped in for as long as transcribe runs, and never freed.
    private static func section(_ name: String) throws -> Data {
        var size: UInt = 0
        let header = #dsohandle.assumingMemoryBound(to: mach_header_64.self)
        guard let bytes = getsectiondata(header, "__TEXT", name, &size), size > 0 else {
            throw MessageError("this transcribe was built without its speaker models; build it with make")
        }
        return Data(bytesNoCopy: bytes, count: Int(size), deallocator: .none)
    }
}
