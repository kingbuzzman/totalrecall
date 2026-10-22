import Foundation
import SQLite3

/// Manages the speaker identification database at ~/.transcribe/speakers.db
final class SpeakerDatabase: @unchecked Sendable {
    private let db: OpaquePointer

    /// Opens or creates the database, initializing tables if needed.
    init() throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".transcribe", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("speakers.db").path

        var handle: OpaquePointer?
        guard sqlite3_open(path, &handle) == SQLITE_OK, let db = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown error"
            sqlite3_close(handle)
            throw DatabaseError("cannot open database: \(message)")
        }
        self.db = db
        try createTables()
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Schema

    private func createTables() throws {
        let sql = """
            CREATE TABLE IF NOT EXISTS speakers (
                id          BLOB PRIMARY KEY,
                name        TEXT,
                created_at  TEXT NOT NULL
            );

            CREATE TABLE IF NOT EXISTS voice_samples (
                id          BLOB PRIMARY KEY,
                speaker_id  BLOB REFERENCES speakers(id),
                embedding   BLOB NOT NULL,
                channel     INTEGER,
                confidence  REAL,
                created_at  TEXT NOT NULL
            );

            CREATE INDEX IF NOT EXISTS idx_samples_speaker ON voice_samples(speaker_id);
            """
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw DatabaseError("cannot create tables: \(errorMessage)")
        }
    }

    // MARK: - Speaker Operations

    /// Creates a new speaker and returns its UUID.
    func createSpeaker() throws -> UUID {
        let id = UUID()
        let sql = "INSERT INTO speakers (id, name, created_at) VALUES (?, NULL, ?)"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bindUUID(id, to: statement, at: 1)
        bindText(ISO8601DateFormatter().string(from: Date()), to: statement, at: 2)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError("cannot create speaker: \(errorMessage)")
        }
        return id
    }

    /// Returns all speakers.
    func allSpeakers() throws -> [IdentifiedSpeaker] {
        let sql = "SELECT id, name, created_at FROM speakers ORDER BY created_at"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var speakers: [IdentifiedSpeaker] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            speakers.append(IdentifiedSpeaker(
                id: readUUID(from: statement, at: 0),
                name: readText(from: statement, at: 1),
                createdAt: readText(from: statement, at: 2) ?? ""
            ))
        }
        return speakers
    }

    /// Sets a speaker's display name.
    func labelSpeaker(_ id: UUID, name: String?) throws {
        let sql = "UPDATE speakers SET name = ? WHERE id = ?"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        if let name {
            bindText(name, to: statement, at: 1)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        bindUUID(id, to: statement, at: 2)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError("cannot label speaker: \(errorMessage)")
        }
    }

    /// Merges two speakers: all samples from `source` are moved to `target`, then `source` is deleted.
    func mergeSpeakers(source: UUID, into target: UUID) throws {
        let updateSQL = "UPDATE voice_samples SET speaker_id = ? WHERE speaker_id = ?"
        let updateStatement = try prepare(updateSQL)
        defer { sqlite3_finalize(updateStatement) }

        bindUUID(target, to: updateStatement, at: 1)
        bindUUID(source, to: updateStatement, at: 2)

        guard sqlite3_step(updateStatement) == SQLITE_DONE else {
            throw DatabaseError("cannot move samples: \(errorMessage)")
        }

        let deleteSQL = "DELETE FROM speakers WHERE id = ?"
        let deleteStatement = try prepare(deleteSQL)
        defer { sqlite3_finalize(deleteStatement) }

        bindUUID(source, to: deleteStatement, at: 1)

        guard sqlite3_step(deleteStatement) == SQLITE_DONE else {
            throw DatabaseError("cannot delete speaker: \(errorMessage)")
        }
    }

    // MARK: - Voice Sample Operations

    /// Adds a voice sample, optionally linked to a speaker.
    func addSample(embedding: [Float], channel: Int, speakerID: UUID?, confidence: Double?) throws -> UUID {
        let id = UUID()
        let sql = """
            INSERT INTO voice_samples (id, speaker_id, embedding, channel, confidence, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bindUUID(id, to: statement, at: 1)
        if let speakerID {
            bindUUID(speakerID, to: statement, at: 2)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        bindEmbedding(embedding, to: statement, at: 3)
        sqlite3_bind_int(statement, 4, Int32(channel))
        if let confidence {
            sqlite3_bind_double(statement, 5, confidence)
        } else {
            sqlite3_bind_null(statement, 5)
        }
        bindText(ISO8601DateFormatter().string(from: Date()), to: statement, at: 6)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError("cannot add sample: \(errorMessage)")
        }
        return id
    }

    /// Links an orphan sample to a speaker.
    func linkSample(_ sampleID: UUID, to speakerID: UUID, confidence: Double) throws {
        let sql = "UPDATE voice_samples SET speaker_id = ?, confidence = ? WHERE id = ?"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bindUUID(speakerID, to: statement, at: 1)
        sqlite3_bind_double(statement, 2, confidence)
        bindUUID(sampleID, to: statement, at: 3)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError("cannot link sample: \(errorMessage)")
        }
    }

    /// Returns all samples with their embeddings for matching.
    func allSamplesWithEmbeddings() throws -> [(sampleID: UUID, speakerID: UUID?, embedding: [Float])] {
        let sql = "SELECT id, speaker_id, embedding FROM voice_samples"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        var samples: [(UUID, UUID?, [Float])] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let sampleID = readUUID(from: statement, at: 0)
            let speakerID = readOptionalUUID(from: statement, at: 1)
            let embedding = readEmbedding(from: statement, at: 2)
            samples.append((sampleID, speakerID, embedding))
        }
        return samples
    }

    /// Returns the speaker name if set, or nil.
    func speakerName(for id: UUID) throws -> String? {
        let sql = "SELECT name FROM speakers WHERE id = ?"
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }

        bindUUID(id, to: statement, at: 1)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return readText(from: statement, at: 0)
    }

    // MARK: - Matching

    /// Finds the best matching speaker for an embedding using cosine similarity.
    /// Returns the speaker ID and similarity score, or nil if no match exceeds the threshold.
    func findMatch(for embedding: [Float], threshold: Double = 0.75) throws -> (speakerID: UUID, similarity: Double)? {
        let samples = try allSamplesWithEmbeddings()
        var bestMatch: (speakerID: UUID, similarity: Double)?

        for (_, speakerID, sampleEmbedding) in samples {
            guard let speakerID else { continue }  // skip orphans
            let similarity = cosineSimilarity(embedding, sampleEmbedding)
            if similarity > threshold && (bestMatch == nil || similarity > bestMatch!.similarity) {
                bestMatch = (speakerID, similarity)
            }
        }
        return bestMatch
    }

    // MARK: - Helpers

    private var errorMessage: String {
        String(cString: sqlite3_errmsg(db))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DatabaseError("cannot prepare statement: \(errorMessage)")
        }
        return statement
    }

    private func bindUUID(_ uuid: UUID, to statement: OpaquePointer, at index: Int32) {
        _ = withUnsafeBytes(of: uuid.uuid) { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, 16, SQLITE_TRANSIENT)
        }
    }

    private func bindText(_ text: String, to statement: OpaquePointer, at index: Int32) {
        sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
    }

    private func bindEmbedding(_ embedding: [Float], to statement: OpaquePointer, at index: Int32) {
        _ = embedding.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), SQLITE_TRANSIENT)
        }
    }

    private func readUUID(from statement: OpaquePointer, at index: Int32) -> UUID {
        let blob = sqlite3_column_blob(statement, index)!
        let bytes = blob.assumingMemoryBound(to: UInt8.self)
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private func readOptionalUUID(from statement: OpaquePointer, at index: Int32) -> UUID? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return readUUID(from: statement, at: index)
    }

    private func readText(from statement: OpaquePointer, at index: Int32) -> String? {
        guard let text = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: text)
    }

    private func readEmbedding(from statement: OpaquePointer, at index: Int32) -> [Float] {
        let blob = sqlite3_column_blob(statement, index)!
        let count = Int(sqlite3_column_bytes(statement, index)) / MemoryLayout<Float>.size
        let pointer = blob.assumingMemoryBound(to: Float.self)
        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    struct DatabaseError: LocalizedError {
        let errorDescription: String?

        init(_ description: String) {
            errorDescription = description
        }
    }
}

// MARK: - Identified Speaker Model

struct IdentifiedSpeaker: Sendable {
    let id: UUID
    let name: String?
    let createdAt: String

    /// Display name: the speaker's name if set, otherwise a truncated UUID.
    var displayName: String {
        name ?? String(id.uuidString.prefix(8).lowercased())
    }
}

// MARK: - Cosine Similarity

/// Computes cosine similarity between two vectors. Returns -1 to 1, higher is more similar.
private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }

    var dotProduct: Float = 0
    var normA: Float = 0
    var normB: Float = 0

    for i in 0..<a.count {
        dotProduct += a[i] * b[i]
        normA += a[i] * a[i]
        normB += b[i] * b[i]
    }

    let denominator = sqrt(normA) * sqrt(normB)
    guard denominator > 0 else { return 0 }

    return Double(dotProduct / denominator)
}

// MARK: - SQLite Transient

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
