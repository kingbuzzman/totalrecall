import AppKit
import AppSupport
import Foundation
import Observation
import Shared
import TotalRecall
import Transcribe
import os

/// What the app is doing, for the menu, the transcript window and the notifications: starts and stops recordings on the
/// `RecordingEngine`, and follows the transcript of the latest one. Like `scripts/record-meetings`, it warns of each of
/// today's meetings on the calendar shortly before it, and starts recording it when it starts if nothing is being
/// recorded; it never stops a recording itself.
@MainActor @Observable
final class AppModel {
    private(set) var state = State.idle
    /// The meeting being recorded, or the last one, which Continue records into again.
    private(set) var meeting: Meeting?
    /// The transcript of the latest recording so far, line by line, and the words still being recognized.
    private(set) var transcript: [TranscriptLine] = []
    private(set) var liveText = ""
    private(set) var lastMessage = ""
    /// Recordings being saved, after they stopped, and transcripts going on, including the one being recorded, until
    /// their last words are written. Saving is counted in AppModel+UnsavedRecordings.swift too.
    var savingCount = 0
    private(set) var transcribingCount = 0
    /// Partial recordings a crash or a forced quit left unsaved, which the menu offers to save.
    var unsavedRecordings: [(partial: URL, output: URL)] = []
    /// Now, every second, for the warnings and starting meetings. Not observed: anything the menu reads redraws it, and
    /// a redraw closes the submenu open in it, so what the menu shows changes only when it must.
    @ObservationIgnored private(set) var now = Date()
    /// How long the recording has been going, as H:MM:SS, every second while recording and a menu is open; only the
    /// line showing it reads it.
    private(set) var elapsed = "0:00:00"
    /// The menus open, submenus included: the elapsed time only needs updating while one is, and must not while a
    /// submenu is open or about to open (see `updateElapsed()`).
    @ObservationIgnored private var openMenus: [NSMenu] = []
    /// The time the meetings' places in the menu go by, such as whether one is underway: now as of when a meeting last
    /// started or ended.
    private(set) var scheduleTime = Date()
    /// Today's meetings on the calendar, and those recorded (or being recorded) or skipped, which are not started again.
    private(set) var todaysMeetings: [ScheduledMeeting] = []
    private(set) var recordedMeetings: Set<ScheduledMeeting> = []
    private(set) var skippedMeetings: Set<ScheduledMeeting> = []
    /// The calendars whose meetings are recorded, which a meeting started from the menu can be filed under, and the
    /// one it is unless another is picked: the default meeting calendar of Settings.
    private(set) var meetingCalendars: [CalendarSource.Calendar] = []
    private(set) var defaultMeetingCalendar: CalendarSource.Calendar?
    let calendar: CalendarSource

    var isRecording: Bool { state != .idle }
    var isBusy: Bool { savingCount > 0 || transcribingCount > 0 }
    /// Transcripts of recordings that have stopped, still being finished.
    var finishingTranscripts: Int { max(0, transcribingCount - (isRecording ? 1 : 0)) }

    private let engine = RecordingEngine()
    let notifier = Notifier()
    let log = Logger(subsystem: "local.totalrecall.app", category: "recording")
    /// The latest recording's number: events of earlier ones, still finishing, leave the transcript shown alone.
    private var recordingID = 0
    private var clock: Timer?
    /// The meetings already warned of, and when the calendar was last read.
    private var warnedMeetings: Set<ScheduledMeeting> = []
    private var lastCalendarRead = Date.distantPast
    /// How many of today's meetings' starts and ends have passed: when it changes, so do their places in the menu.
    private var boundariesPassed = 0
    private var observers: [any NSObjectProtocol] = []
    /// Played with each warning, as `record-meetings` does: one of macOS's own sounds, softly.
    private let chime: NSSound? = {
        let sound = NSSound(contentsOfFile: "/System/Library/Sounds/Glass.aiff", byReference: true)
        sound?.volume = 0.3
        return sound
    }()
    /// Called once nothing is being saved or transcribed any more, for quitting.
    private var whenIdle: (() -> Void)?

    init() {
        calendar = CalendarSource()
        calendar.onChange = { [weak self] in self?.readCalendar() }
        notifier.onAction { [weak self] action, info in self?.perform(action, info) }
        notifier.requestPermission()
        prepareTranscription()
        findUnsavedRecordings()
        // For every run loop mode: an open menu runs the run loop in its own, in which a timer of the default mode
        // waits, so the elapsed time in the menu would stand still until it is opened again.
        let clock = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(clock, forMode: .common)
        self.clock = clock
        // A Mac that slept through a meeting's start records it on waking; the calendar may have changed meanwhile.
        observe(NSWorkspace.didWakeNotification, on: NSWorkspace.shared.notificationCenter) { model, _ in
            model.readCalendar()
        }
        // On opening the menu, the elapsed time as of now, not of when it was last open.
        for (name, opens) in [(NSMenu.didBeginTrackingNotification, true), (NSMenu.didEndTrackingNotification, false)] {
            observe(name, queue: nil) { model, notification in
                guard let menu = notification.object as? NSMenu else { return }
                model.openMenus.removeAll { $0 === menu }
                if opens { model.openMenus.append(menu) }
                model.updateElapsed()
            }
        }
        // Such as calendars turned off in Settings.
        observe(UserDefaults.didChangeNotification) { model, _ in model.readCalendar() }
        Task {
            await calendar.requestAccess()
            readCalendar()
        }
    }

    /// Calls `handle` with the model and the notification whenever `center` posts `name`, on `queue`, for as long as
    /// the model is around.
    private func observe(
        _ name: Notification.Name,
        on center: NotificationCenter = .default,
        queue: OperationQueue? = .main,
        _ handle: @escaping @MainActor (AppModel, Notification) -> Void
    ) {
        observers.append(
            center.addObserver(forName: name, object: nil, queue: queue) { [weak self] notification in
                nonisolated(unsafe) let notification = notification  // delivered on the main thread, used there
                MainActor.assumeIsolated { if let self { handle(self, notification) } }
            }
        )
    }

    /// Starts recording a new meeting named `name`, filed under `calendar`, or the default meeting calendar, stopping
    /// the one being recorded first; when `addsEvent`, as New Meeting does, put on that calendar too.
    func startMeeting(named name: String, on calendar: CalendarSource.Calendar? = nil, addsEvent: Bool = false) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = trimmed.isEmpty ? "Meeting" : trimmed
        if addsEvent, let target = calendar ?? defaultMeetingCalendar {
            let scheduled = ScheduledMeeting.startingNow(
                title,
                now: Date(),
                minutes: AppSettings.newMeetingMinutes,
                calendar: target.title,
                calendarID: target.id
            )
            do {
                let eventID = try self.calendar.add(scheduled)
                // Recorded already, so that once the calendar reads it back, it is not started again.
                recordedMeetings.insert(scheduled)
                let directory = scheduled.directory(root: AppSettings.recordingsFolder)
                return start(Meeting(name: title, directory: directory, scheduled: scheduled, eventID: eventID))
            } catch {
                notifier.post(title: "Could not add “\(title)” to \(target.title)", body: error.localizedDescription)
            }
        }
        let directory = RecordingFolder.directory(
            root: AppSettings.recordingsFolder,
            calendar: (calendar ?? defaultMeetingCalendar)?.title,
            name: title,
            start: Date()
        )
        start(Meeting(name: title, directory: directory))
    }

    /// Records the last meeting again, into its folder, as rec-2, transcript-2 and so on, the way `record-meetings`
    /// does when a meeting is restarted.
    func continueMeeting() {
        guard let meeting else { return startMeeting(named: "") }
        start(meeting)
    }

    func stop() {
        guard isRecording else { return }
        endEvent()
        engine.stop()
        state = .idle
    }

    /// Stops recording and calls `done` once every file is saved and every transcript finished, for quitting.
    func stopAndFinish(_ done: @escaping () -> Void) {
        if isRecording { endEvent() }
        state = .idle
        clock?.invalidate()
        clock = nil
        engine.stop { [weak self] in
            guard let self, isBusy else { return done() }
            whenIdle = done
        }
    }

    private func start(_ meeting: Meeting) {
        if isRecording {
            endEvent()
            engine.stop()
        }
        recordingID += 1
        self.meeting = meeting
        transcript = []
        liveText = ""
        lastMessage = ""
        state = .starting
        let request = RecordingEngine.Request(
            id: recordingID,
            directory: meeting.directory,
            format: AppSettings.format,
            microphone: AppSettings.microphone,
            language: AppSettings.language,
            identifiesSpeakers: AppSettings.identifiesSpeakers,
            trashesAudioOnceTranscribed: AppSettings.trashesAudioOnceTranscribed
        )
        // Through the main queue rather than a task each, so the events keep their order.
        engine.start(request) { [weak self] id, event in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.handle(event, of: id) } }
        }
    }

    /// Ends the event the app added for the meeting being recorded, if it did, as it stops: to the minute.
    private func endEvent() {
        guard var meeting, let eventID = meeting.eventID, let scheduled = meeting.scheduled else { return }
        let stopped = scheduled.stopped(at: Date())
        do {
            try calendar.moveEnd(ofEvent: eventID, to: stopped.end)
            recordedMeetings.insert(stopped)
            meeting.scheduled = stopped
            self.meeting = meeting
        } catch {
            notifier.post(title: "Could not end “\(meeting.name)” on the calendar", body: error.localizedDescription)
        }
    }

    private func handle(_ event: RecordingEngine.Event, of id: Int) {
        let isLatest = id == recordingID
        switch event {
        case .started:
            guard isLatest, state == .starting else { return }
            state = .recording(since: Date())
            updateElapsed()
            announceStarted(meeting?.name ?? "")
        case .failedToStart(let reason):
            log.error("could not start recording: \(reason, privacy: .public)")
            if isLatest { state = .idle }
            announceFailedToRecord(reason)
        case .nothingRecorded:
            break
        case .stopped:
            savingCount += 1
        case .saved(let url):
            savingCount -= 1
            announceSaved(url)
            becameIdleIfDone()
        case .failedToSave(let reason):
            savingCount -= 1
            log.error("could not save: \(reason, privacy: .public)")
            notifier.post(title: "Could not save the recording", body: reason)
            becameIdleIfDone()
        case .line(let line):
            if isLatest { transcript.append(TranscriptLine(parsing: line)) }
        case .liveText(let text):
            if isLatest { liveText = text }
        case .message(let message):
            log.info("\(message, privacy: .public)")
            if isLatest { lastMessage = message }
        case .transcriptStarted:
            transcribingCount += 1
        case .transcriptFinished(let error):
            transcribingCount -= 1
            if let error {
                log.error("transcript stopped: \(error, privacy: .public)")
                if isLatest { lastMessage = "The transcript stopped: \(error)" }
                notifier.post(title: "The transcript stopped", body: error)
            }
            becameIdleIfDone()
        case .audioTrashed(let audio, let trashed, let transcript):
            announceTrashed(audio, to: trashed, keeping: transcript)
        }
    }

    func becameIdleIfDone() {
        guard !isBusy, let whenIdle else { return }
        self.whenIdle = nil
        whenIdle()
    }
}

/// Today's meetings: which is next, where each stands, recording or skipping them, and, every second, warning of
/// those about to start and starting the next once it has started.
extension AppModel {
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

    /// Records a meeting on the calendar now, such as one starting early, stopping what is being recorded first. It
    /// goes in the meeting's own folder, and is not started again when its time comes.
    func record(_ meeting: ScheduledMeeting) {
        skippedMeetings.remove(meeting)
        recordedMeetings.insert(meeting)
        let directory = meeting.directory(root: AppSettings.recordingsFolder)
        start(Meeting(name: meeting.shortTitle, directory: directory, scheduled: meeting))
    }

    /// Leaves a meeting out of recording and warnings, or puts it back.
    func toggleSkipped(_ meeting: ScheduledMeeting) {
        if skippedMeetings.remove(meeting) == nil { skippedMeetings.insert(meeting) }
    }

    /// Reads today's meetings from the calendar again.
    func readCalendar() {
        lastCalendarRead = Date()
        let calendars = Dictionary(calendar.calendars.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // Each set only if it changed: the menu redraws for any change, and a redraw closes the submenu open in it.
        let recorded = calendar.calendars.filter { AppSettings.rules(for: $0).isRecorded }
        set(\.meetingCalendars, to: recorded)
        let defaultID = MeetingCalendar.resolve(
            chosen: AppSettings.defaultMeetingCalendar,
            recorded: recorded.map(\.id)
        )
        set(\.defaultMeetingCalendar, to: recorded.first { $0.id == defaultID })
        let events = calendar.todaysEvents { AppSettings.rules(for: $0).isRecorded }
        let meetings = MeetingSchedule.meetings(from: events) { id in
            calendars[id].map(AppSettings.rules(for:)) ?? CalendarRules()
        }
        // Compared with the calendar too, which equality leaves out, so that a meeting moved to another is seen.
        if meetings.map(\.calendar) != todaysMeetings.map(\.calendar) || meetings != todaysMeetings {
            todaysMeetings = meetings
            scheduleTime = Date()
        }
        // Yesterday's are of no more use.
        let today = Set(todaysMeetings)
        set(\.recordedMeetings, to: recordedMeetings.intersection(today.union(meeting?.scheduled.map { [$0] } ?? [])))
        set(\.skippedMeetings, to: skippedMeetings.intersection(today))
        warnedMeetings.formIntersection(today)
        tick()
    }

    /// Sets the property at `path` to `value`, unless it is that already: any set, even of the same value, redraws the
    /// menu.
    private func set<Value: Equatable>(_ path: ReferenceWritableKeyPath<AppModel, Value>, to value: Value) {
        if self[keyPath: path] != value { self[keyPath: path] = value }
    }

    /// Every second: warns of the meetings about to start, and starts recording the next one once it has started, if
    /// nothing is being recorded and that is on. Reads the calendar again every minute.
    private func tick() {
        now = Date()
        if now.timeIntervalSince(lastCalendarRead) >= 60 { return readCalendar() }
        updateElapsed()
        let boundaries = todaysMeetings.reduce(0) { $0 + ($1.start <= now ? 1 : 0) + ($1.end <= now ? 1 : 0) }
        if boundaries != boundariesPassed {
            boundariesPassed = boundaries
            scheduleTime = now
        }
        let lead = TimeInterval(AppSettings.warningMinutes * 60)
        let excluded = warnedMeetings.union(recordedMeetings).union(skippedMeetings)
        for meeting in MeetingSchedule.warningsDue(in: todaysMeetings, lead: lead, excluding: excluded, now: now) {
            warnedMeetings.insert(meeting)
            let time = meeting.start.shortTime
            let body =
                AppSettings.recordsAutomatically && !isRecording
                ? "Recording starts at \(time)." : "It starts at \(time)."
            announceWarning(of: meeting, now: now, body: body)
            chime?.stop()
            chime?.play()
        }
        let excludedFromStart = recordedMeetings.union(skippedMeetings)
        if AppSettings.recordsAutomatically, !isRecording,
            let next = MeetingSchedule.next(in: todaysMeetings, excluding: excludedFromStart, now: now),
            next.start <= now
        {
            record(next)
        }
    }

    /// Only while a menu is open, and the pointer on none of its items: a change redraws the menu, which throws off the
    /// highlighted item and closes the submenu open, or about to open, under the pointer.
    private func updateElapsed() {
        let highlighted = openMenus.compactMap { $0.highlightedItem?.title }
        Logger(subsystem: "local.totalrecall.app", category: "menu").debug(
            "open menus: \(self.openMenus.count, privacy: .public), highlighted: \(highlighted, privacy: .public)"
        )
        guard !openMenus.isEmpty, highlighted.isEmpty, case .recording(let since) = state else { return }
        elapsed = clockTime(max(0, Int(now.timeIntervalSince(since))), padsHours: false)
    }
}
