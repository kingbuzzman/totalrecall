import Foundation
import Shared
import Testing

struct StopSignalsTests {
    @Test(.timeLimit(.minutes(1)))
    func handlesTheSignalOnTheMainQueueInsteadOfTerminating() async throws {
        let handled = AsyncStream.makeStream(of: Bool.self)
        let sources = handleStopSignals([SIGUSR1]) { signal in
            handled.continuation.yield(Thread.isMainThread && signal == SIGUSR1)
        }
        defer { sources.forEach { $0.cancel() } }

        // The source starts listening asynchronously, so keep signalling until it hears one.
        let signaller = Task {
            while !Task.isCancelled {
                kill(getpid(), SIGUSR1)
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        defer { signaller.cancel() }

        var iterator = handled.stream.makeAsyncIterator()
        #expect(await iterator.next() == true)
    }
}
