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

    /// A meeting being recorded, or the last one: its name, the folder its recordings go in, the meeting on the
    /// calendar it is, if any, and the language it is transcribed in.
    struct Meeting: Equatable {
        let name: String
        let directory: URL
        var scheduled: ScheduledMeeting?
        /// The event the app added to the calendar for it, which ends when it stops.
        var eventID: String?
        /// The calendar it is filed under, started from the menu rather than from the calendar.
        var filedUnder: String?
        /// The language switched to in the transcript window, which Continue goes on in.
        var switchedLanguage: String?

        /// The language it is transcribed in: the one switched to, else its calendar's, else the default; nil for
        /// transcribe's, en-US.
        var language: String? {
            switchedLanguage ?? AppSettings.language(forCalendar: scheduled?.calendarID ?? filedUnder)
        }
    }

    /// Where switching the transcript to another language stands, while it does: getting the language's speech model
    /// ready, then transcribing all of the recording so far in it, until it catches up.
    enum LanguageSwitchStage: Equatable {
        case preparing(String)
        case catchingUp(String)

        var language: String {
            switch self {
            case .preparing(let language), .catchingUp(let language): language
            }
        }
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
