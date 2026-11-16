import Foundation

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
