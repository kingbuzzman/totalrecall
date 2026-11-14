import Foundation

/// One capture's outage: when to retry it, and what to tell the user. Retries back off while the capture stays down;
/// once audio flows again, the next outage starts over from the first, shortest delay.
final class CaptureOutage {
    /// Delays between restarts within one outage; the last repeats. A rebuilt capture gets this long to deliver.
    static let retryDelays = [0.5, 1, 2, 4, 5]
    /// Outages shorter than this, such as a device switch, are not announced.
    static let announceAfterSeconds = 5.0
    /// While the capture stays down, the user is reminded this often.
    static let reminderSeconds = 300.0

    private let name: String
    private let announce: (String) -> Void
    private var start: Double?
    private var attempts = 0
    private var nextRestart = 0.0
    private var isAnnounced = false
    private var nextReminder = 0.0
    private var lastError: String?
    private var deliveries = 0

    /// `name` is how the capture is called in messages, such as "system audio".
    init(name: String, announce: @escaping (String) -> Void) {
        self.name = name
        self.announce = announce
    }

    var isOngoing: Bool { start != nil }

    /// Checks whether the capture delivered audio since the last call (`deliveries` is its running count of buffers),
    /// which ends the outage, and tells the user about one that goes on.
    func update(deliveries: Int, now: Double) {
        if deliveries != self.deliveries {
            self.deliveries = deliveries
            if let start { end(after: now - start) }
        }
        guard let start else { return }
        if !isAnnounced, now - start >= Self.announceAfterSeconds {
            isAnnounced = true
            nextReminder = start + Self.reminderSeconds
            announce("\(name) stopped delivering audio; retrying")
        } else if isAnnounced, now >= nextReminder {
            nextReminder += Self.reminderSeconds
            announce("still no \(name) after \(describe(now - start)); retrying")
        }
    }

    func canRestart(now: Double) -> Bool {
        now >= nextRestart
    }

    /// Starts an outage, or continues the current one, and schedules the retry after this restart further out.
    func restarting(now: Double) {
        if start == nil { start = now }
        nextRestart = now + Self.retryDelays[min(attempts, Self.retryDelays.count - 1)]
        attempts += 1
    }

    /// Tells the user why a restart failed, once per outage for each distinct reason.
    func restartFailed(_ error: any Error) {
        let reason = error.localizedDescription
        guard reason != lastError else { return }
        lastError = reason
        announce("\(name) unavailable, retrying: \(reason)")
    }

    /// A device change is a new reason to restart: retry it at the shortest delay again.
    func resetBackoff() {
        attempts = 0
    }

    private func end(after seconds: Double) {
        if isAnnounced { announce("\(name) back after \(describe(seconds))") }
        start = nil
        attempts = 0
        nextRestart = 0
        isAnnounced = false
        lastError = nil
    }

    private func describe(_ seconds: Double) -> String {
        let whole = Int(seconds)
        if whole < 60 { return "\(whole)s" }
        if whole < 3600 { return "\(whole / 60)m \(whole % 60)s" }
        return "\(whole / 3600)h \(whole / 60 % 60)m"
    }
}
