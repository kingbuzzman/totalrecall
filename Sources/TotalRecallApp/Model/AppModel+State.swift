import AppSupport
import Foundation

/// What `AppModel` tells the menu and the transcript window: whether it is recording, what, and where today's meetings
/// stand.
extension AppModel {
    enum State: Equatable {
        case idle
        /// Waiting for the captures to deliver audio, which takes a second or so, 2–3 s with AirPods.
        case starting
        case recording(since: Date)
    }

    /// A meeting being recorded, or the last one: its name, the folder its recordings go in, and the meeting on the
    /// calendar it is, if any.
    struct Meeting: Equatable {
        let name: String
        let directory: URL
        var scheduled: ScheduledMeeting?
        /// The event the app added to the calendar for it, which ends when it stops.
        var eventID: String?
    }

    /// Where one of today's meetings stands, for the menu.
    enum MeetingStatus {
        case upcoming, underway, recorded, skipped, ended
    }

    /// The next meeting to record: the first of today's not recorded or skipped that has not ended, which may be
    /// underway already.
    var nextMeeting: ScheduledMeeting? {
        MeetingSchedule.next(in: todaysMeetings, excluding: recordedMeetings.union(skippedMeetings), now: scheduleTime)
    }

    func status(of meeting: ScheduledMeeting) -> MeetingStatus {
        if recordedMeetings.contains(meeting) { return .recorded }
        if skippedMeetings.contains(meeting) { return .skipped }
        if meeting.end <= scheduleTime { return .ended }
        return meeting.start <= scheduleTime ? .underway : .upcoming
    }
}
