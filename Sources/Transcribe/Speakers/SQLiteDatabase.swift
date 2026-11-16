import Foundation
import SQLite3
import Shared

/// A SQLite database file, opened for reading and writing, with the few things `SpeakerDatabase` asks of it: statements
/// run with values bound to their `?`s, rows read by column, and transactions. Calls from different threads take turns.
final class SQLiteDatabase: @unchecked Sendable {
    enum Value {
        case integer(Int)
        case real(Double)
        case text(String)
        case floats([Float])
        case data(Data)
        case null

        static func textOrNull(_ text: String?) -> Value { text.map(Value.text) ?? .null }
    }

    /// A row of a query's result, read by column.
    struct Row {
        fileprivate let statement: OpaquePointer

        func integer(_ column: Int32) -> Int { Int(sqlite3_column_int64(statement, column)) }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        func bool(_ column: Int32) -> Bool { integer(column) != 0 }

        func floats(_ column: Int32) -> [Float] {
            let bytes = Int(sqlite3_column_bytes(statement, column))
            var floats = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
            guard let blob = sqlite3_column_blob(statement, column) else { return floats }
            floats.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(start: blob, count: $0.count)) }
            return floats
        }

        func data(_ column: Int32) -> Data {
            guard let blob = sqlite3_column_blob(statement, column) else { return Data() }
            return Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, column)))
        }
    }

    /// Tells SQLite to copy what is bound, as the Swift value it comes from does not outlive the call.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private let handle: OpaquePointer
    /// Recursive, so a transaction can run statements of its own.
    private let lock = NSRecursiveLock()

    /// Opens the file at `url`, creating it and its folder if need be, with foreign keys enforced and write-ahead
    /// logging, so another process can read while this one writes.
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            let reason = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "out of memory"
            sqlite3_close(handle)
            throw MessageError("cannot open \(url.path): \(reason)")
        }
        self.handle = handle
        // Another transcribe, or the app, may be writing too; it never takes long.
        sqlite3_busy_timeout(handle, 2_000)
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA foreign_keys = ON")
        } catch {
            sqlite3_close(handle)
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    /// The row ID of the last row inserted.
    var lastInsertedID: Int { lock.withLock { Int(sqlite3_last_insert_rowid(handle)) } }

    /// How many rows the last statement changed.
    var changes: Int { lock.withLock { Int(sqlite3_changes(handle)) } }

    func execute(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values) { _ in () }
    }

    /// Runs `sql` and reads each row of its result with `read`.
    func query<Result>(_ sql: String, _ values: [Value] = [], row read: (Row) -> Result) throws -> [Result] {
        try lock.withLock {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                throw failure()
            }
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() { bind(value, at: Int32(index + 1), in: statement) }
            var rows: [Result] = []
            while true {
                switch sqlite3_step(statement) {
                case SQLITE_ROW: rows.append(read(Row(statement: statement)))
                case SQLITE_DONE: return rows
                default: throw failure()
                }
            }
        }
    }

    /// Runs `change` in a transaction: all of it goes in, or, if it throws, none of it.
    func transaction<Result>(_ change: () throws -> Result) throws -> Result {
        try lock.withLock {
            try execute("SAVEPOINT change")
            do {
                let result = try change()
                try execute("RELEASE change")
                return result
            } catch {
                try? execute("ROLLBACK TO change")
                try? execute("RELEASE change")
                throw error
            }
        }
    }

    private func bind(_ value: Value, at position: Int32, in statement: OpaquePointer) {
        switch value {
        case .integer(let integer): sqlite3_bind_int64(statement, position, Int64(integer))
        case .real(let real): sqlite3_bind_double(statement, position, real)
        case .text(let text): sqlite3_bind_text(statement, position, text, -1, Self.transient)
        case .floats(let floats): floats.withUnsafeBytes { bindBlob($0, at: position, in: statement) }
        case .data(let data): data.withUnsafeBytes { bindBlob($0, at: position, in: statement) }
        case .null: sqlite3_bind_null(statement, position)
        }
    }

    private func bindBlob(_ bytes: UnsafeRawBufferPointer, at position: Int32, in statement: OpaquePointer) {
        sqlite3_bind_blob(statement, position, bytes.baseAddress, Int32(bytes.count), Self.transient)
    }

    private func failure() -> MessageError {
        MessageError("speaker database: \(String(cString: sqlite3_errmsg(handle)))")
    }
}
