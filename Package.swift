// swift-tools-version: 6.2
import PackageDescription

/// The code that ships fails to build on any compiler warning.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "totalrecall",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "totalrecall", targets: ["TotalRecall"]),
        .executable(name: "transcribe", targets: ["Transcribe"]),
    ],
    targets: [
        // Built from source by the Makefile, which points PKG_CONFIG_PATH at it.
        .systemLibrary(name: "CSpeexDSP", pkgConfig: "speexdsp"),
        .target(name: "Shared", swiftSettings: strict),
        .executableTarget(
            name: "TotalRecall",
            dependencies: ["CSpeexDSP", "Shared"],
            exclude: ["Info.plist"],
            swiftSettings: strict
        ),
        .executableTarget(name: "Transcribe", dependencies: ["Shared"], exclude: ["Info.plist"], swiftSettings: strict),
        .target(name: "AudioLab", path: "Tests/AudioLab"),
        .testTarget(name: "SharedTests", dependencies: ["Shared"]),
        .testTarget(name: "TotalRecallTests", dependencies: ["TotalRecall", "Shared"]),
        .testTarget(name: "TranscribeTests", dependencies: ["Transcribe", "Shared"]),
        .testTarget(name: "AudioLabTests", dependencies: ["AudioLab"]),
        .testTarget(name: "IntegrationTests", dependencies: ["AudioLab", "Shared"]),
    ],
    swiftLanguageModes: [.v5]
)
