// swift-tools-version: 6.2
import PackageDescription

/// Every target: the Swift 6 language mode, which checks for data races, imports that are checked rather than leaked
/// between files and modules, existentials spelled `any`, and a failed build on any compiler warning.
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
    .treatAllWarnings(as: .error),
]

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
        .target(name: "AudioLab", path: "Tests/AudioLab", swiftSettings: strict),
        .testTarget(name: "SharedTests", dependencies: ["Shared"], swiftSettings: strict),
        .testTarget(name: "TotalRecallTests", dependencies: ["TotalRecall", "Shared"], swiftSettings: strict),
        .testTarget(name: "TranscribeTests", dependencies: ["Transcribe", "Shared"], swiftSettings: strict),
        .testTarget(name: "AudioLabTests", dependencies: ["AudioLab"], swiftSettings: strict),
        .testTarget(name: "IntegrationTests", dependencies: ["AudioLab", "Shared"], swiftSettings: strict),
    ]
)
