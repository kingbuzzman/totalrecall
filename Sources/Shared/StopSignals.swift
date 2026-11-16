package import Foundation

/// Calls `handler` on `queue`, with the signal's number, on SIGINT, SIGTERM or SIGHUP instead of terminating, so the
/// recording can be saved or the transcript finished. Also ignores SIGPIPE, so writing to a closed stderr or pipe cannot
/// kill the process first. Keep the returned sources alive for as long as the handler should run.
package func handleStopSignals(
    _ signals: [Int32] = [SIGINT, SIGTERM, SIGHUP],
    queue: DispatchQueue = .main,
    handler: @escaping (_ signal: Int32) -> Void
) -> [any DispatchSourceSignal] {
    signal(SIGPIPE, SIG_IGN)
    return signals.map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: queue)
        source.setEventHandler { handler(signalNumber) }
        source.resume()
        return source
    }
}
