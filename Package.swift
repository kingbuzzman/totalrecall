// swift-tools-version: 6.2
import PackageDescription

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
        .target(name: "Shared"),
        .executableTarget(name: "TotalRecall", dependencies: ["CSpeexDSP", "Shared"], exclude: ["Info.plist"]),
        .executableTarget(name: "Transcribe", dependencies: ["Shared"], exclude: ["Info.plist"]),
        .target(name: "AudioLab", path: "Tests/AudioLab"),
        // Plays the integration tests' fake speakers and microphones, each in a process of its own.
        .executableTarget(name: "AudioLabPlayer", dependencies: ["AudioLab"], path: "Tests/AudioLabPlayer"),
        .testTarget(name: "SharedTests", dependencies: ["Shared", "AudioLab"]),
        .testTarget(name: "TotalRecallTests", dependencies: ["TotalRecall", "Shared"]),
        .testTarget(name: "TranscribeTests", dependencies: ["Transcribe", "AudioLab"]),
        .testTarget(name: "AudioLabTests", dependencies: ["AudioLab"]),
        .testTarget(name: "IntegrationTests", dependencies: ["AudioLab", "AudioLabPlayer", "Shared"]),
    ]
)

/// Every target: the Swift 6 language mode, which checks for data races, plus every feature the compiler lists as a
/// Swift 7 default (checked imports, existentials spelled `any`, nonisolated async functions running on their caller's
/// actor, isolated conformances, immutable weak captures), and a failed build on any compiler or linker warning (no
/// compiler setting covers the linker's).
for target in package.targets where target.type != .system {
    target.swiftSettings = [
        .swiftLanguageMode(.v6),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("ImmutableWeakCaptures"),
        .treatAllWarnings(as: .error),
    ]
    target.linkerSettings = [.unsafeFlags(["-Xlinker", "-fatal_warnings"])]
}
