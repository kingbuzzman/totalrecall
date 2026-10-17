import Foundation

/// Calls `handler` on the main queue on SIGINT, SIGTERM or SIGHUP instead of terminating, so the recording can be
/// saved. Also ignores SIGPIPE, so writing to a closed stderr cannot kill the process first. Keep the returned
/// sources alive for as long as the handler should run.
func handleStopSignals(
    _ signals: [Int32] = [SIGINT, SIGTERM, SIGHUP],
    handler: @escaping () -> Void
) -> [DispatchSourceSignal] {
    signal(SIGPIPE, SIG_IGN)
    return signals.map { signalNumber in
        signal(signalNumber, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
        source.setEventHandler(handler: handler)
        source.resume()
        return source
    }
}
