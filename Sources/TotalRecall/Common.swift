import Foundation
import os

/// Asks a yes-or-no question with `ask`, whose answer comes on another thread, such as a permission prompt's, and waits
/// for it.
func waitForAnswer(_ ask: (_ answer: @escaping @Sendable (Bool) -> Void) -> Void) -> Bool {
    let answered = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var granted = false  // written before `answered.signal()`, read after `answered.wait()`
    ask { answer in
        granted = answer
        answered.signal()
    }
    answered.wait()
    return granted
}

func uptimeSeconds() -> Double {
    Double(DispatchTime.now().uptimeNanoseconds) / 1e9
}

/// An `os_unfair_lock`, for state shared with audio callbacks: cheaper than `NSLock`, and an audio thread that waits on
/// it donates its priority to the thread holding it.
struct UnfairLock {
    private let lock = OSAllocatedUnfairLock()

    func withLock<Result>(_ body: () throws -> Result) rethrows -> Result {
        try lock.withLockUnchecked(body)
    }
}
