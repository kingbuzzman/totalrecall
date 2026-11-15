// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "totalrecall",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "totalrecall", targets: ["TotalRecallCommand"]),
        .executable(name: "transcribe", targets: ["TranscribeCommand"]),
        // The menu bar app; the Makefile wraps it into TotalRecall.app (make build-app).
        .executable(name: "TotalRecallApp", targets: ["TotalRecallApp"]),
    ],
    targets: [
        // Built from source by the Makefile, which points PKG_CONFIG_PATH at it.
        .systemLibrary(name: "CSpeexDSP", pkgConfig: "speexdsp"),
        .target(name: "Shared"),
        // The recorder and the transcriber are libraries, each with a command-line tool on top, so that the app runs
        // both in its own process. Their Info.plists are the tools'.
        .target(name: "TotalRecall", dependencies: ["CSpeexDSP", "Shared"], exclude: ["Info.plist"]),
        .executableTarget(name: "TotalRecallCommand", dependencies: ["TotalRecall", "Shared"]),
        .target(name: "Transcribe", dependencies: ["Shared"], exclude: ["Info.plist"]),
        .executableTarget(name: "TranscribeCommand", dependencies: ["Transcribe"]),
        // What the app decides without a user interface (where recordings go, the formats it offers), kept apart so it
        // can be tested.
        .target(name: "AppSupport"),
        .executableTarget(
            name: "TotalRecallApp",
            dependencies: ["TotalRecall", "Transcribe", "Shared", "AppSupport"],
            exclude: ["Info.plist"]
        ),
        .target(name: "AudioLab", path: "Tests/AudioLab"),
        // Plays the integration tests' fake speakers and microphones, each in a process of its own.
        .executableTarget(name: "AudioLabPlayer", dependencies: ["AudioLab"], path: "Tests/AudioLabPlayer"),
        .testTarget(name: "SharedTests", dependencies: ["Shared", "AudioLab"]),
        .testTarget(name: "TotalRecallTests", dependencies: ["TotalRecall", "Shared"]),
        .testTarget(name: "TranscribeTests", dependencies: ["Transcribe", "AudioLab", "Shared"]),
        .testTarget(name: "AudioLabTests", dependencies: ["AudioLab"]),
        .testTarget(name: "AppSupportTests", dependencies: ["AppSupport"]),
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
