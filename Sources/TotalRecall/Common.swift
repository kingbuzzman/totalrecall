import Foundation
import os

struct RecordingError: LocalizedError {
    let errorDescription: String?

    init(_ description: String) {
        errorDescription = description
    }
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
