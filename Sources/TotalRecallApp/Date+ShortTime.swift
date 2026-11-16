import Foundation

extension Date {
    /// The time of day, as the Mac shows it in short: "9:30 AM", or "09:30" on a 24-hour clock.
    var shortTime: String { formatted(date: .omitted, time: .shortened) }
}
