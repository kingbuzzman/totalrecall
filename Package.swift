// swift-tools-version: 6.2
import PackageDescription

/// Every target: the Swift 6 language mode, which checks for data races, plus every feature the compiler lists as a
/// Swift 7 default (checked imports, existentials spelled `any`, nonisolated async functions running on their caller's
/// actor, isolated conformances, immutable weak captures), and a failed build on any compiler warning.
let strict: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .enableUpcomingFeature("MemberImportVisibility"),
    .enableUpcomingFeature("InternalImportsByDefault"),
    .enableUpcomingFeature("ExistentialAny"),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
    .enableUpcomingFeature("ImmutableWeakCaptures"),
    .treatAllWarnings(as: .error),
]

/// Linker warnings fail the link too; no compiler setting covers them.
let strictLinking: [LinkerSetting] = [.unsafeFlags(["-Xlinker", "-fatal_warnings"])]

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
            swiftSettings: strict,
            linkerSettings: strictLinking
        ),
        .executableTarget(
            name: "Transcribe",
            dependencies: ["Shared"],
            exclude: ["Info.plist"],
            swiftSettings: strict,
            linkerSettings: strictLinking
        ),
        .target(name: "AudioLab", path: "Tests/AudioLab", swiftSettings: strict),
        // Plays the integration tests' fake speakers and microphones, each in a process of its own.
        .executableTarget(
            name: "AudioLabPlayer",
            dependencies: ["AudioLab"],
            path: "Tests/AudioLabPlayer",
            swiftSettings: strict,
            linkerSettings: strictLinking
        ),
        .testTarget(
            name: "SharedTests",
            dependencies: ["Shared"],
            swiftSettings: strict,
            linkerSettings: strictLinking
        ),
        .testTarget(
            name: "TotalRecallTests",
            dependencies: ["TotalRecall", "Shared"],
            swiftSettings: strict,
            linkerSettings: strictLinking
        ),
        .testTarget(
            name: "TranscribeTests",
            dependencies: ["Transcribe", "Shared"],
            swiftSettings: strict,
            linkerSettings: strictLinking
        ),
        .testTarget(
            name: "AudioLabTests",
            dependencies: ["AudioLab"],
            swiftSettings: strict,
            linkerSettings: strictLinking
        ),
        .testTarget(
            name: "IntegrationTests",
            dependencies: ["AudioLab", "AudioLabPlayer", "Shared"],
            swiftSettings: strict,
            linkerSettings: strictLinking
        ),
    ]
)
