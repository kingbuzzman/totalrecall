import Testing

/// On CI, runs a test that failed once more, from scratch, and lets that second attempt decide. CI's virtual machines,
/// unlike a real Mac, now and then stall every audio stream at once for tens of milliseconds, or hang `say`; a real bug
/// fails both attempts. The first attempt's failures still show in the log, as a known issue. Anywhere else, a test
/// runs once, as usual. List it before `.audioRig`, so each attempt gets a rig of its own.
struct RetriedOnCI: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> RetriedOnCI? {
        testCase == nil || !TestEnvironment.isCI ? nil : self
    }

    @concurrent func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        nonisolated(unsafe) var failed = false  // set only while the first attempt runs, read after it
        try await withKnownIssue("failed on CI's virtual machine, so it is tried again", isIntermittent: true) {
            try await function()
        } matching: { _ in
            failed = true
            return true
        }
        if failed { try await function() }
    }
}

extension Trait where Self == RetriedOnCI {
    static var retriedOnCI: Self { RetriedOnCI() }
}
