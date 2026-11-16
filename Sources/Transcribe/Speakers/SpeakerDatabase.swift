package import Foundation
import Shared

/// The people `--identify-speakers` has heard, so each keeps their number, or the name given them, from one call to the
/// next: a SQLite database, for `transcribe` at ~/.transcribe/speakers.db, or wherever `TRANSCRIBE_SPEAKERS` in the
/// environment says, and for TotalRecall.app in its Application Support folder. Every change goes in as it happens, so the people of a call
/// still going are already there.
///
/// A person has one or more voices: the ways they have been heard, each recognized on its own. Telling two people are
/// one merges them, which only files the one's voices under the other: no voice is averaged into another, so a merge
/// that turns out wrong can be undone by splitting a voice back out. With each voice go clips of its speech, as AAC
/// audio in an MPEG-4 file (the bytes of a .m4a), to hear who someone is by and to print their voice again with another
/// model. A voice's print is kept per speaker model, as one model's prints mean nothing to another.
package final class SpeakerDatabase: @unchecked Sendable {
    /// Someone heard, under the number transcripts call them by ("Them 3"), until given a name.
    package struct Person: Equatable, Sendable {
        package let id: Int
        package var name: String?
        /// Heard on your microphone: you.
        package var isYou: Bool
        /// When they were first heard.
        package var createdAt: Date
    }

    /// One way someone sounds, as the identifier recognizes them: the average of its prints in the database's model,
    /// and how many prints, `SpeakerIdentifier.hopSeconds` of speech each; with its person's name and whether that is
    /// you.
    package struct Voice: Equatable, Sendable {
        package let id: Int
        package let person: Int
        package var name: String?
        package var isYou: Bool
        package var print: [Float]
        package var prints: Int
        package var createdAt: Date
    }

    /// Some seconds of a voice's speech.
    package struct Clip: Equatable, Sendable {
        package let id: Int
        package let voice: Int
        /// A .m4a file's bytes.
        package let audio: Data
        package let seconds: Double
        package let recordedAt: Date
    }

    /// Each person keeps their longest clips, this many.
    static let clipsPerPerson = 20
    /// People whose voices are this alike, both heard this many prints at least, are one: different people's are rarely
    /// closer than 0.5.
    static let samePerson: Float = 0.35
    static let samePersonPrints = SpeakerIdentifier.settledPrints
    /// People this far apart, between their most alike voices, or further, most likely are two: merging them asks
    /// first.
    package static let soundAlike = SpeakerIdentifier.soundAlike
    /// How long a voice is heard for each of its prints, in seconds.
    package static let secondsPerPrint = SpeakerIdentifier.hopSeconds

    package static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["TRANSCRIBE_SPEAKERS"] { return URL(typedPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".transcribe/speakers.db")
    }

    /// The tables, made if they are not there yet.
    private static let schema = [
        """
        CREATE TABLE IF NOT EXISTS people (
            id INTEGER PRIMARY KEY,
            name TEXT,
            is_you INTEGER NOT NULL DEFAULT 0,
            created_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS voices (
            id INTEGER PRIMARY KEY,
            person_id INTEGER NOT NULL REFERENCES people (id) ON DELETE CASCADE,
            created_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS voice_prints (
            voice_id INTEGER NOT NULL REFERENCES voices (id) ON DELETE CASCADE,
            model TEXT NOT NULL,
            print BLOB NOT NULL,
            prints INTEGER NOT NULL,
            PRIMARY KEY (voice_id, model)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS clips (
            id INTEGER PRIMARY KEY,
            voice_id INTEGER NOT NULL REFERENCES voices (id) ON DELETE CASCADE,
            audio BLOB NOT NULL,
            seconds REAL NOT NULL,
            recorded_at REAL NOT NULL
        )
        """,
        "CREATE INDEX IF NOT EXISTS voices_person_id ON voices (person_id)",
        "CREATE INDEX IF NOT EXISTS clips_voice_id ON clips (voice_id)",
    ]

    /// The speaker model whose prints this database reads and writes.
    let model: String
    private let sqlite: SQLiteDatabase

    package init(url: URL = defaultURL, model: String = SpeakerModel.name) throws {
        self.model = model
        sqlite = try SQLiteDatabase(url: url)
        for statement in Self.schema { try sqlite.execute(statement) }
    }

    // MARK: - People

    /// Everyone, in the order they were first heard.
    package func people() throws -> [Person] {
        try sqlite.query("SELECT id, name, is_you, created_at FROM people ORDER BY id") { row in
            Person(id: row.integer(0), name: row.text(1), isYou: row.bool(2), createdAt: row.date(3))
        }
    }

    package func person(_ id: Int) throws -> Person? {
        try sqlite.query("SELECT id, name, is_you, created_at FROM people WHERE id = ?", [.integer(id)]) { row in
            Person(id: row.integer(0), name: row.text(1), isYou: row.bool(2), createdAt: row.date(3))
        }
        .first
    }

    /// Names someone, or with nil takes their name away. False if there is no such person.
    @discardableResult
    package func rename(_ person: Int, to name: String?) throws -> Bool {
        try changes("UPDATE people SET name = ? WHERE id = ?", [.textOrNull(name), .integer(person)])
    }

    /// Takes someone out, with their voices and clips. False if there is no such person.
    @discardableResult
    package func forget(_ person: Int) throws -> Bool {
        try changes("DELETE FROM people WHERE id = ?", [.integer(person)])
    }

    /// Makes `person` part of `target`, for one person taken for two: their voices are filed under `target`, which
    /// keeps its name unless it has none, is you if either was, and was first heard when the earlier of the two was.
    /// Each voice stays as it was, to be split back out if the merge was wrong. False if either is missing, or they
    /// are the same.
    @discardableResult
    package func merge(_ person: Int, into target: Int) throws -> Bool {
        try sqlite.transaction {
            guard person != target, let merged = try self.person(person), let kept = try self.person(target) else {
                return false
            }
            try sqlite.execute(
                "UPDATE people SET name = ?, is_you = ?, created_at = ? WHERE id = ?",
                [
                    .textOrNull(kept.name ?? merged.name), .integer(kept.isYou || merged.isYou ? 1 : 0),
                    .real(min(kept.createdAt, merged.createdAt).timeIntervalSince1970), .integer(target),
                ]
            )
            try sqlite.execute(
                "UPDATE voices SET person_id = ? WHERE person_id = ?",
                [.integer(target), .integer(person)]
            )
            try sqlite.execute("DELETE FROM people WHERE id = ?", [.integer(person)])
            try keepLongestClips(of: target)
            return true
        }
    }

    /// Takes a voice out of its person into a person of its own, with no name, for a merge that was wrong. Returns the
    /// new person, or nil if there is no such voice, or it is its person's only one.
    @discardableResult
    package func split(_ voice: Int) throws -> Int? {
        try sqlite.transaction {
            guard let found = try self.voice(voice, inAnyModel: true), try voices(of: found.person).count > 1 else {
                return nil
            }
            let person = try addPerson(createdAt: found.createdAt)
            try sqlite.execute("UPDATE voices SET person_id = ? WHERE id = ?", [.integer(person), .integer(voice)])
            return person
        }
    }

    /// How alike two people sound: the distance between the most alike of their voices; nil when either has no voice
    /// in this model.
    package func distance(between person: Int, and other: Int) throws -> Float? {
        let (theirs, others) = (try voices(of: person), try voices(of: other))
        return theirs.flatMap { voice in others.map { voiceDistance(voice.print, $0.print) } }.min()
    }

    // MARK: - Voices

    /// Every voice with a print in this model, in the order they were first heard.
    package func voices() throws -> [Voice] {
        try voices(where: "1")
    }

    func voice(_ id: Int) throws -> Voice? {
        try voices(where: "voices.id = ?", [.integer(id)]).first
    }

    package func voices(of person: Int) throws -> [Voice] {
        try voices(where: "voices.person_id = ?", [.integer(person)])
    }

    /// Adds someone heard for the first time, with their first voice.
    func addPerson(print: [Float], prints: Int) throws -> Voice {
        try sqlite.transaction {
            let now = Date()
            let person = try addPerson(createdAt: now)
            try sqlite.execute(
                "INSERT INTO voices (person_id, created_at) VALUES (?, ?)",
                [.integer(person), .real(now.timeIntervalSince1970)]
            )
            let id = sqlite.lastInsertedID
            try sqlite.execute(
                "INSERT INTO voice_prints (voice_id, model, print, prints) VALUES (?, ?, ?, ?)",
                [.integer(id), .text(model), .floats(print), .integer(prints)]
            )
            guard let voice = try voice(id) else {
                throw MessageError("speaker database: the voice just added is gone")
            }
            return voice
        }
    }

    /// Saves what a voice has come to sound like, as it is heard. False if there is no such voice.
    @discardableResult
    func update(_ voice: Int, print: [Float], prints: Int) throws -> Bool {
        try changes(
            "UPDATE voice_prints SET print = ?, prints = ? WHERE voice_id = ? AND model = ?",
            [.floats(print), .integer(prints), .integer(voice), .text(model)]
        )
    }

    /// Marks the person a voice is as you, heard on your microphone. False if there is no such voice.
    @discardableResult
    func markAsYou(_ voice: Int) throws -> Bool {
        try changes(
            "UPDATE people SET is_you = 1 WHERE id = (SELECT person_id FROM voices WHERE id = ?)",
            [.integer(voice)]
        )
    }

    /// Takes a voice out, with its clips, and its person if that was their only one. False if there is no such voice.
    func forgetVoice(_ voice: Int) throws -> Bool {
        try sqlite.transaction {
            guard let found = try self.voice(voice, inAnyModel: true) else { return false }
            try sqlite.execute("DELETE FROM voices WHERE id = ?", [.integer(voice)])
            try sqlite.execute(
                "DELETE FROM people WHERE id = ? AND NOT EXISTS (SELECT 1 FROM voices WHERE person_id = ?)",
                [.integer(found.person), .integer(found.person)]
            )
            return true
        }
    }

    // MARK: - Underneath

    private func addPerson(createdAt: Date) throws -> Int {
        try sqlite.execute("INSERT INTO people (created_at) VALUES (?)", [.real(createdAt.timeIntervalSince1970)])
        return sqlite.lastInsertedID
    }

    /// Voices joined with their person and their print in this model; or, `inAnyModel`, every voice, printed or not.
    private func voices(where condition: String, _ values: [SQLiteDatabase.Value] = []) throws -> [Voice] {
        try sqlite.query(
            """
            SELECT voices.id, voices.person_id, people.name, people.is_you, voice_prints.print, voice_prints.prints,
                voices.created_at
            FROM voices JOIN people ON people.id = voices.person_id
                JOIN voice_prints ON voice_prints.voice_id = voices.id AND voice_prints.model = ?
            WHERE \(condition) ORDER BY voices.id
            """,
            [.text(model)] + values
        ) { row in
            Voice(
                id: row.integer(0),
                person: row.integer(1),
                name: row.text(2),
                isYou: row.bool(3),
                print: row.floats(4),
                prints: row.integer(5),
                createdAt: row.date(6)
            )
        }
    }

    /// A voice, `inAnyModel`: whether or not it has a print in this model, which is then empty.
    private func voice(_ id: Int, inAnyModel: Bool) throws -> Voice? {
        guard inAnyModel else { return try voice(id) }
        return try sqlite.query(
            """
            SELECT voices.id, voices.person_id, people.name, people.is_you, voices.created_at
            FROM voices JOIN people ON people.id = voices.person_id WHERE voices.id = ?
            """,
            [.integer(id)]
        ) { row in
            Voice(
                id: row.integer(0),
                person: row.integer(1),
                name: row.text(2),
                isYou: row.bool(3),
                print: [],
                prints: 0,
                createdAt: row.date(4)
            )
        }
        .first
    }

    private func keepLongestClips(of person: Int) throws {
        try sqlite.execute(
            """
            DELETE FROM clips WHERE voice_id IN (SELECT id FROM voices WHERE person_id = ?) AND id NOT IN (
                SELECT clips.id FROM clips JOIN voices ON voices.id = clips.voice_id
                WHERE voices.person_id = ? ORDER BY clips.seconds DESC, clips.id LIMIT ?
            )
            """,
            [.integer(person), .integer(person), .integer(Self.clipsPerPerson)]
        )
    }

    /// Runs a change, and tells whether it changed any row.
    private func changes(_ sql: String, _ values: [SQLiteDatabase.Value]) throws -> Bool {
        try sqlite.transaction {
            try sqlite.execute(sql, values)
            return sqlite.changes > 0
        }
    }
}

/// Clips: some seconds of each voice's speech.
extension SpeakerDatabase {
    /// Keeps a clip of a voice's speech, `seconds` long, unless its person already has `clipsPerPerson` longer ones.
    func addClip(_ audio: Data, seconds: Double, to voice: Int) throws {
        try sqlite.transaction {
            try sqlite.execute(
                "INSERT INTO clips (voice_id, audio, seconds, recorded_at) VALUES (?, ?, ?, ?)",
                [.integer(voice), .data(audio), .real(seconds), .real(Date().timeIntervalSince1970)]
            )
            if let person = try self.voice(voice, inAnyModel: true)?.person { try keepLongestClips(of: person) }
        }
    }

    /// Someone's clips, of all their voices, the longest first.
    package func clips(of person: Int) throws -> [Clip] {
        try sqlite.query(
            """
            SELECT clips.id, clips.voice_id, clips.audio, clips.seconds, clips.recorded_at
            FROM clips JOIN voices ON voices.id = clips.voice_id
            WHERE voices.person_id = ? ORDER BY clips.seconds DESC, clips.id
            """,
            [.integer(person)]
        ) { row in
            Clip(
                id: row.integer(0),
                voice: row.integer(1),
                audio: row.data(2),
                seconds: row.real(3),
                recordedAt: row.date(4)
            )
        }
    }

    /// How many clips each person has, by number; those with none are left out.
    package func clipCounts() throws -> [Int: Int] {
        Dictionary(
            uniqueKeysWithValues: try sqlite.query(
                "SELECT voices.person_id, count(*) FROM clips JOIN voices ON voices.id = clips.voice_id GROUP BY 1"
            ) { ($0.integer(0), $0.integer(1)) }
        )
    }

    /// Moves a voice's clips to another voice, for a voice first taken for someone new that turned out to be them.
    func moveClips(of voice: Int, to target: Int) throws {
        try sqlite.transaction {
            try sqlite.execute("UPDATE clips SET voice_id = ? WHERE voice_id = ?", [.integer(target), .integer(voice)])
            if let person = try self.voice(target, inAnyModel: true)?.person { try keepLongestClips(of: person) }
        }
    }
}

extension SQLiteDatabase.Row {
    fileprivate func date(_ column: Int32) -> Date { Date(timeIntervalSince1970: real(column)) }
}
