import Foundation

/// "1 sample", "3 samples": `count` and `noun`, plural unless there is one.
package func counted(_ count: Int, _ noun: String) -> String {
    "\(count) \(noun)\(count == 1 ? "" : "s")"
}

/// `seconds` as a clock shows them: HH:MM:SS, or H:MM:SS without `padsHours`.
package func clockTime(_ seconds: Int, padsHours: Bool = true) -> String {
    String(format: padsHours ? "%02d:%02d:%02d" : "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
}
