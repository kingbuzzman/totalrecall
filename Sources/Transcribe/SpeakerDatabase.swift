import Foundation
import SQLite3

/// The people `--identify-speakers` has heard, so each keeps their number, or the name given with
/// `transcribe speakers name`, from one call to the next: a SQLite database at ~/.transcribe/speakers.db, or wherever
/// `TRANSCRIBE_SPEAKERS` in the environment says. Every change goes in as it happens, so the speakers of a call still
/// going are already there. With each speaker go a few samples of their speech, to tell who they are by
/// (`transcribe speakers play`), as AAC audio in an MPEG-4 file, the bytes of a .m4a. Each channel's identifier uses it
/// from its own task, so every call is guarded by a lock.
final class SpeakerDatabase: @unchecked Sendable {
    struct Speaker: Equatable {
        let id: Int
        var name: String?
        /// The average of their voice prints, and how many prints, `SpeakerIdentifier.hopSeconds` of speech each.
        var voice: [Float]
        var prints: Int
        /// When they were first heard.
        var createdAt: Date
        /// Heard on your microphone: you.
        var isYou: Bool
    }

    struct Sample: Equatable {
        let id: Int
        /// A .m4a file's bytes.
        let audio: Data
        let seconds: Double
    }

    /// Each speaker keeps their longest samples, this many.
    static let samplesPerSpeaker = 4

    static var defaultURL: URL {
        if let path = ProcessInfo.processInfo.environment["TRANSCRIBE_SPEAKERS"] {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".transcribe/speakers.db")
    }

    private let database: OpaquePointer
    /// Recursive, as `merge` reads the speakers on the way.
    private let lock = NSRecursiveLock()

    init(url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw TranscribeError("cannot open \(url.path): \(reason)")
        }
        database = handle
        // Another transcribe may be writing too; it never takes long.
        sqlite3_busy_timeout(database, 2_000)
        do {
            try execute("PRAGMA journal_mode = WAL")
            // So a speaker's samples go with them.
            try execute("PRAGMA foreign_keys = ON")
            try execute(
                """
                CREATE TABLE IF NOT EXISTS speakers (
                    id INTEGER PRIMARY KEY,
                    name TEXT,
                    voice BLOB NOT NULL,
                    prints INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    is_you INTEGER NOT NULL DEFAULT 0
                )
                """
            )
            try execute(
                """
                CREATE TABLE IF NOT EXISTS samples (
                    id INTEGER PRIMARY KEY,
                    speaker_id INTEGER NOT NULL REFERENCES speakers (id) ON DELETE CASCADE,
                    audio BLOB NOT NULL,
                    seconds REAL NOT NULL,
                    created_at REAL NOT NULL
                )
                """
            )
            try execute("CREATE INDEX IF NOT EXISTS samples_speaker_id ON samples (speaker_id)")
            try dropSamplesOfThoseWithNames()
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    deinit {
        sqlite3_close(database)
    }

    /// Everyone, in the order they were first heard.
    func speakers() throws -> [Speaker] {
        try speakers(where: "1")
    }

    func speaker(_ id: Int) throws -> Speaker? {
        try speakers(where: "id = ?", [.integer(id)]).first
    }

    private func speakers(where condition: String, _ values: [Value] = []) throws -> [Speaker] {
        let sql = "SELECT id, name, voice, prints, created_at, is_you FROM speakers WHERE \(condition) ORDER BY id"
        return try query(sql, values) { row in
            Speaker(
                id: row.integer(0),
                name: row.text(1),
                voice: row.voice(2),
                prints: row.integer(3),
                createdAt: Date(timeIntervalSince1970: row.real(4)),
                isYou: row.integer(5) != 0
            )
        }
    }

    /// Adds someone heard for the first time, returning their number.
    func add(voice: [Float], prints: Int) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        try execute(
            "INSERT INTO speakers (voice, prints, created_at) VALUES (?, ?, ?)",
            [.voice(voice), .integer(prints), .real(Date().timeIntervalSince1970)]
        )
        return Int(sqlite3_last_insert_rowid(database))
    }

    /// Saves what someone's voice has come to sound like, as they are heard. False if there is no such speaker.
    @discardableResult
    func update(_ id: Int, voice: [Float], prints: Int) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try execute(
            "UPDATE speakers SET voice = ?, prints = ? WHERE id = ?",
            [.voice(voice), .integer(prints), .integer(id)]
        )
        return sqlite3_changes(database) > 0
    }

    /// Marks someone as you, heard on your microphone. False if there is no such speaker.
    @discardableResult
    func markAsYou(_ id: Int) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try execute("UPDATE speakers SET is_you = 1 WHERE id = ?", [.integer(id)])
        return sqlite3_changes(database) > 0
    }

    /// Names someone, or with nil takes their name away. Their samples go, as they were kept to tell who they are.
    /// False if there is no such speaker.
    func rename(_ id: Int, to name: String?) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try execute("UPDATE speakers SET name = ? WHERE id = ?", [name.map(Value.text) ?? .null, .integer(id)])
        let renamed = sqlite3_changes(database) > 0
        try dropSamplesOfThoseWithNames()
        return renamed
    }

    /// Makes `id` part of `target`, for one person that was taken for two: their voices are averaged, `target` keeps
    /// its name unless it has none, and they were first heard when the earlier of the two was. False if either is
    /// missing.
    func merge(_ id: Int, into target: Int) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let speakers = try speakers()
        guard id != target, let merged = speakers.first(where: { $0.id == id }),
            let kept = speakers.first(where: { $0.id == target })
        else { return false }
        let prints = merged.prints + kept.prints
        let voice = zip(merged.voice, kept.voice).map {
            ($0 * Float(merged.prints) + $1 * Float(kept.prints)) / Float(max(prints, 1))
        }
        try execute("BEGIN")
        do {
            try execute(
                "UPDATE speakers SET voice = ?, prints = ?, name = ?, created_at = ?, is_you = ? WHERE id = ?",
                [
                    .voice(voice),
                    .integer(prints),
                    (kept.name ?? merged.name).map(Value.text) ?? .null,
                    .real(min(merged.createdAt, kept.createdAt).timeIntervalSince1970),
                    .integer(merged.isYou || kept.isYou ? 1 : 0),
                    .integer(target),
                ]
            )
            try execute("UPDATE samples SET speaker_id = ? WHERE speaker_id = ?", [.integer(target), .integer(id)])
            try keepLongestSamples(of: target)
            try execute("DELETE FROM speakers WHERE id = ?", [.integer(id)])
            try dropSamplesOfThoseWithNames()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
        return true
    }

    /// Keeps a sample of someone's speech, `seconds` long, unless they already have `samplesPerSpeaker` longer ones.
    func addSample(_ audio: Data, seconds: Double, to speaker: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute(
            "INSERT INTO samples (speaker_id, audio, seconds, created_at) VALUES (?, ?, ?, ?)",
            [.integer(speaker), .data(audio), .real(seconds), .real(Date().timeIntervalSince1970)]
        )
        try keepLongestSamples(of: speaker)
    }

    /// Someone's samples, the longest first.
    func samples(of speaker: Int) throws -> [Sample] {
        try query(
            "SELECT id, audio, seconds FROM samples WHERE speaker_id = ? ORDER BY seconds DESC, id",
            [.integer(speaker)]
        ) { row in
            Sample(id: row.integer(0), audio: row.data(1), seconds: row.real(2))
        }
    }

    /// How many samples each speaker has, by number; those with none are left out.
    func sampleCounts() throws -> [Int: Int] {
        Dictionary(
            uniqueKeysWithValues: try query("SELECT speaker_id, count(*) FROM samples GROUP BY speaker_id") {
                ($0.integer(0), $0.integer(1))
            }
        )
    }

    /// Moves someone's samples to another speaker, keeping the longest, for one person first taken for someone new.
    func moveSamples(of id: Int, to target: Int) throws {
        lock.lock()
        defer { lock.unlock() }
        try execute("UPDATE samples SET speaker_id = ? WHERE speaker_id = ?", [.integer(target), .integer(id)])
        try keepLongestSamples(of: target)
    }

    /// Samples are only for telling who someone is.
    private func dropSamplesOfThoseWithNames() throws {
        try execute("DELETE FROM samples WHERE speaker_id IN (SELECT id FROM speakers WHERE name IS NOT NULL)")
    }

    private func keepLongestSamples(of speaker: Int) throws {
        try execute(
            """
            DELETE FROM samples WHERE speaker_id = ? AND id NOT IN
                (SELECT id FROM samples WHERE speaker_id = ? ORDER BY seconds DESC, id LIMIT ?)
            """,
            [.integer(speaker), .integer(speaker), .integer(Self.samplesPerSpeaker)]
        )
    }

    /// Takes them and their samples out. False if there is no such speaker.
    func forget(_ id: Int) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        try execute("DELETE FROM speakers WHERE id = ?", [.integer(id)])
        return sqlite3_changes(database) > 0
    }

    // MARK: - SQLite

    enum Value {
        case integer(Int)
        case real(Double)
        case text(String)
        case voice([Float])
        case data(Data)
        case null
    }

    /// A row of a query's result, read by column.
    struct Row {
        fileprivate let statement: OpaquePointer

        func integer(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }

        func voice(_ column: Int32) -> [Float] {
            let bytes = Int(sqlite3_column_bytes(statement, column))
            var voice = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            guard let blob = sqlite3_column_blob(statement, column) else { return voice }
            voice.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: blob, count: $0.count)) }
            return voice
        }

        func data(_ column: Int32) -> Data {
            guard let blob = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    /// Tells SQLite to copy what is bound, as the Swift value it comes from does not outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func query<Result>(_ sql: String, _ values: [Value] = [], row read: (Row) -> Result) throws -> [Result] {
        lock.lock()
        defer { lock.unlock() }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw failure()
        }
        defer { sqlite3_finalize(statement) }
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .integer(let integer): sqlite3_bind_int64(statement, position, Int64(integer))
            case .real(let real): sqlite3_bind_double(statement, position, real)
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
            case .voice(let voice):
                voice.withUnsafeBytes {
                    _ = sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), Self.transient)
                }
            case .data(let data):
                data.withUnsafeBytes {
                    _ = sqlite3_bind_blob(statement, position, $0.baseAddress, Int32($0.count), Self.transient)
                }
            case .null: sqlite3_bind_null(statement, position)
            }
        }
        var rows: [Result] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: rows.append(read(Row(statement: statement)))
            case SQLITE_DONE: return rows
            default: throw failure()
            }
        }
    }

    private func failure() -> TranscribeError {
        TranscribeError("speaker database: \(String(cString: sqlite3_errmsg(database)))")
    }
}
