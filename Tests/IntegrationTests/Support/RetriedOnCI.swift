import Testing

/// On CI, runs a test that failed again, from scratch, up to `attempts` times in all, and lets the last attempt decide.
/// CI's virtual machines, unlike a real Mac, now and then stall every audio stream at once for tens of milliseconds, or
/// hang `say`; a real bug fails every attempt. Earlier attempts' failures still show in the log, as known issues.
/// Anywhere else, a test runs once, as usual. List it before `.audioRig`, so each attempt gets a rig of its own.
struct RetriedOnCI: SuiteTrait, TestTrait, TestScoping {
    /// A test hits a stall in about 1 run in 50 on its own, but in up to 1 in 3 while other jobs share the machine.
    private static let attempts = 3

    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> RetriedOnCI? {
        testCase == nil || !TestEnvironment.isCI ? nil : self
    }

    @concurrent func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        for _ in 1..<Self.attempts {
            nonisolated(unsafe) var failed = false  // set only while this attempt runs, read after it
            try await withKnownIssue("failed on CI's virtual machine, so it is tried again", isIntermittent: true) {
                try await function()
            } matching: { _ in
                failed = true
                return true
            }
            if !failed { return }
        }
        try await function()
    }
}

extension Trait where Self == RetriedOnCI {
    static var retriedOnCI: Self { RetriedOnCI() }
}
