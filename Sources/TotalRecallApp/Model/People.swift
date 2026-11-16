import AVFoundation
import Foundation
import Observation
import Shared
import Transcribe
import os

/// The people Identify Speakers remembers, for the People tab of Settings: who they are, how long each was heard, and
/// their voices; renaming, merging, splitting and forgetting them; and playing their clips. Read afresh whenever the tab
/// appears and after every change, as a recording going on adds people as it hears them.
@MainActor @Observable
final class People {
    /// Someone, with what the tab shows of them.
    struct Entry: Identifiable {
        let person: SpeakerDatabase.Person
        let voices: [SpeakerDatabase.Voice]
        let clips: Int

        var id: Int { person.id }

        /// Their name, or "You", or the number transcripts call them by.
        var name: String { person.name ?? (person.isYou ? "You" : "Them \(person.id)") }

        /// How long they have been heard, all their voices together.
        var heardSeconds: Double {
            Double(voices.reduce(0) { $0 + $1.prints }) * SpeakerDatabase.secondsPerPrint
        }
    }

    private(set) var entries: [Entry] = []
    /// What went wrong reading or changing the database, if anything did.
    private(set) var problem: String?
    /// The audio file whose voices are being learned, while they are.
    private(set) var learningFrom: String?
    /// What came of the last file learned from.
    private(set) var learned: String?
    /// The person whose clips are playing, and the clip, when only one is.
    var playing: Int? { player.person }
    var playingClip: Int? { player.clip }

    @ObservationIgnored private var database: SpeakerDatabase?
    @ObservationIgnored private let log = Log.speakers
    private let player = ClipPlayer()

    func reload() {
        change(reloading: false) {
            let people = try $0.people()
            let voices = Dictionary(grouping: try $0.voices(), by: \.person)
            let clips = try $0.clipCounts()
            entries = people.map { Entry(person: $0, voices: voices[$0.id] ?? [], clips: clips[$0.id] ?? 0) }
        }
    }

    func rename(_ person: Int, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        change { try $0.rename(person, to: name.isEmpty ? nil : name) }
    }

    /// How alike `person` and `other` sound: the distance between their most alike voices; nil when either has none.
    /// From the voices already read, as the tab asks it of every pair.
    func distance(_ person: Int, _ other: Int) -> Float? {
        guard let theirs = entries.first(where: { $0.id == person })?.voices,
            let others = entries.first(where: { $0.id == other })?.voices
        else { return nil }
        return theirs.flatMap { voice in others.map { voiceDistance(voice.print, $0.print) } }.min()
    }

    /// How alike `person` and `other` sound, in percent: 100 for the same voice, 0 for none in common; the same person
    /// is mostly 70 to 80, different people 25 or less. Nil when either has no voice.
    func similarity(_ person: Int, _ other: Int) -> Int? {
        distance(person, other).map { Int((max(0, min(1, 1 - $0)) * 100).rounded()) }
    }

    /// Whether `person` and `other` sound alike enough to be taken for one person without asking.
    func soundAlike(_ person: Int, _ other: Int) -> Bool {
        (distance(person, other) ?? .infinity) < SpeakerDatabase.soundAlike
    }

    func merge(_ person: Int, into target: Int) {
        change { try $0.merge(person, into: target) }
    }

    func split(voice: Int) {
        change { try $0.split(voice) }
    }

    func forget(_ person: Int) {
        if playing == person { player.stop() }
        change { try $0.forget(person) }
    }

    /// Whether `url` is an audio file voices can be learned from.
    static func canLearn(from url: URL) -> Bool {
        voiceFileExtensions.contains(url.pathExtension.lowercased())
    }

    /// Learns the voices in an audio file, as a recording with Identify Speakers does, in the background; everyone
    /// heard is added, or recognized as someone already here.
    func learnVoices(from url: URL) {
        guard learningFrom == nil else { return }
        learningFrom = url.lastPathComponent
        learned = nil
        let (before, language, speakers) = (entries.count, AppSettings.language, AppSettings.speakers)
        Task.detached(priority: .userInitiated) {
            let failure: String?
            do {
                try await Transcribe.learnVoices(from: url, language: language, speakers: speakers) { _ in }
                failure = nil
            } catch {
                failure = error.localizedDescription
            }
            await MainActor.run { self.finishLearning(from: url, before: before, failure: failure) }
        }
    }

    private func finishLearning(from url: URL, before: Int, failure: String?) {
        learningFrom = nil
        reload()
        if let failure {
            problem = "Could not learn the voices in \(url.lastPathComponent): \(failure)"
            log.error("could not learn the voices in \(url.path, privacy: .public): \(failure, privacy: .public)")
        } else {
            let added = entries.count - before
            learned =
                "\(url.lastPathComponent): " + (added > 0 ? "\(counted(added, "new person")) heard" : "nobody new")
        }
    }

    /// Plays someone's clips, longest first, one after another; or stops them if they are playing.
    func play(_ person: Int) {
        guard playing != person else { return player.stop() }
        var clips: [SpeakerDatabase.Clip] = []
        change(reloading: false) { clips = try $0.clips(of: person) }
        player.play(clips.map(\.audio), of: person)
    }

    /// Someone's clips, the longest first.
    func clips(of person: Int) -> [SpeakerDatabase.Clip] {
        var clips: [SpeakerDatabase.Clip] = []
        change(reloading: false) { clips = try $0.clips(of: person) }
        return clips
    }

    /// Plays one clip, or stops it if it is playing.
    func play(_ clip: SpeakerDatabase.Clip, of person: Int) {
        guard playingClip != clip.id else { return player.stop() }
        player.play([clip.audio], of: person, clip: clip.id)
    }

    func stop() {
        player.stop()
    }

    /// Runs a read or a change on the database, opened the first time, keeping what went wrong; then reads everyone
    /// afresh, unless told not to.
    private func change(reloading: Bool = true, _ body: (SpeakerDatabase) throws -> Void) {
        do {
            if database == nil { database = try SpeakerDatabase(url: AppSettings.speakers) }
            if let database { try body(database) }
            problem = nil
        } catch {
            problem = error.localizedDescription
            log.error("speaker database: \(error.localizedDescription, privacy: .public)")
        }
        if reloading, database != nil { reload() }
    }
}

/// Plays clips, given as the bytes of .m4a files, one after another.
@MainActor @Observable
private final class ClipPlayer: NSObject, AVAudioPlayerDelegate {
    /// Whose clips are playing, and which clip, when only one is.
    private(set) var person: Int?
    private(set) var clip: Int?
    @ObservationIgnored private var queue: [Data] = []
    @ObservationIgnored private var player: AVAudioPlayer?

    func play(_ clips: [Data], of person: Int, clip: Int? = nil) {
        stop()
        queue = clips
        self.person = person
        self.clip = clip
        playNext()
    }

    func stop() {
        player?.stop()
        player = nil
        queue = []
        person = nil
        clip = nil
    }

    private func playNext() {
        guard !queue.isEmpty, let next = try? AVAudioPlayer(data: queue.removeFirst()) else { return stop() }
        next.delegate = self
        player = next
        if !next.play() { stop() }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        MainActor.assumeIsolated { playNext() }
    }
}
