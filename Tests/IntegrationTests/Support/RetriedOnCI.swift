import Synchronization
import Testing

/// On CI, runs a test that failed again, from scratch, up to `attempts` times in all, and lets the last attempt decide.
/// CI's virtual machines, unlike a real Mac, now and then stall every audio stream at once for tens of milliseconds, or
/// hang `say`; a real bug fails every attempt. Earlier attempts' failures still show in the log, as known issues.
/// Once `failuresToGiveUp` tests have failed every attempt, as when the rig itself is broken, the rest fail at once,
/// rather than each try `attempts` times what will fail too. Anywhere else, a test runs once, as usual. List it before
/// `.audioRig`, so each attempt gets a rig of its own.
struct RetriedOnCI: SuiteTrait, TestTrait, TestScoping {
    /// A test hits a stall in about 1 run in 50 on its own, but in up to 1 in 3 while other jobs share the machine.
    private static let attempts = 3
    private static let failuresToGiveUp = 3
    /// How many tests have failed every attempt so far, in this run.
    private static let failures = Mutex(0)

    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> RetriedOnCI? {
        testCase == nil || !TestEnvironment.isCI ? nil : self
    }

    @concurrent func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @concurrent @Sendable () async throws -> Void
    ) async throws {
        let failedSoFar = Self.failures.withLock { $0 }
        guard failedSoFar < Self.failuresToGiveUp else {
            Issue.record(
                "not run: \(failedSoFar) tests already failed every attempt, so the test rig is most likely broken"
            )
            return
        }
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
        // The last attempt decides: its issues are the test's, and counted, a thrown error too, which is thrown on.
        nonisolated(unsafe) var lastFailed = false  // set only while it runs, read after it
        defer { if lastFailed { Self.failures.withLock { $0 += 1 } } }
        try await withKnownIssue(isIntermittent: true) {
            try await function()
        } matching: { _ in
            lastFailed = true
            return false
        }
    }
}

extension Trait where Self == RetriedOnCI {
    static var retriedOnCI: Self { RetriedOnCI() }
}
