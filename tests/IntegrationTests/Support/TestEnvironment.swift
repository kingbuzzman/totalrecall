import Foundation

enum TestEnvironment {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The binaries under test: the release builds in the repository root, or the ones the environment names, such as
    /// the instrumented builds of make coverage.
    static let totalrecall = executable(named: "totalrecall", override: "TOTALRECALL")
    static let transcribe = executable(named: "transcribe", override: "TRANSCRIBE")

    static let version = (try? String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)

    static let isCI = ProcessInfo.processInfo.environment["CI"] == "true"

    /// Recordings and logs, kept after the run (CI uploads them).
    static let results: URL = {
        let path = ProcessInfo.processInfo.environment["RESULTS"]
        let results = path.map(URL.init(fileURLWithPath:)) ?? root.appendingPathComponent(".build/test-results")
        try? FileManager.default.createDirectory(at: results, withIntermediateDirectories: true)
        return results
    }()

    static func result(_ name: String) -> URL {
        results.appendingPathComponent(name)
    }

    private static func executable(named name: String, override variable: String) -> URL {
        ProcessInfo.processInfo.environment[variable].map(URL.init(fileURLWithPath:))
            ?? root.appendingPathComponent(name)
    }
}
