import Foundation
import SQLite3

/// A tiny SQLite wrapper owned by `MemoryStore` (patterned on DeeMind's store, plus
/// BLOB support for face prints). WAL journal, a 2 s busy timeout, foreign keys and
/// `secure_delete` (so "forget" really overwrites the bytes on disk).
final class MemoryDatabase {
    enum Failure: Error, CustomStringConvertible {
        case open(String), prepare(String), step(String)
        var description: String {
            switch self {
            case .open(let m): "SQLite open: \(m)"
            case .prepare(let m): "SQLite prepare: \(m)"
            case .step(let m): "SQLite step: \(m)"
            }
        }
    }

    enum Value: Equatable, Sendable {
        case real(Double), int(Int64), text(String), blob(Data), null
    }

    typealias Row = [String: Value]

    private var db: OpaquePointer?
    let path: String

    /// `path` of ":memory:" gives an in-memory database (tests).
    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            db = nil
            throw Failure.open(msg)
        }
        sqlite3_busy_timeout(db, 2000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try execute("PRAGMA foreign_keys=ON;")
        try execute("PRAGMA secure_delete=ON;")
    }

    deinit { sqlite3_close_v2(db) }

    private var errorMessage: String { String(cString: sqlite3_errmsg(db)) }

    /// Row id of the last INSERT on this connection.
    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }

    /// Rows changed by every statement since the connection opened. Unchanged
    /// value = nothing was written, so read caches are still valid.
    var totalChanges: Int64 { sqlite3_total_changes64(db) }

    /// Folds the WAL back into the main file and truncates it to zero bytes, so
    /// deleted (secure-deleted) text does not linger in `-wal`.
    func checkpoint() throws {
        try execute("PRAGMA wal_checkpoint(TRUNCATE);")
    }

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw Failure.step(msg)
        }
    }

    @discardableResult
    func query(_ sql: String, _ params: [Value] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure.prepare(errorMessage) }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p {
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .blob(let data):
                _ = data.withUnsafeBytes { raw in
                    sqlite3_bind_blob(stmt, idx, raw.baseAddress, Int32(data.count), transient)
                }
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure.step(errorMessage) }
            var row: Row = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, c))
                    if n > 0, let p = sqlite3_column_blob(stmt, c) {
                        row[name] = .blob(Data(bytes: p, count: n))
                    } else {
                        row[name] = .blob(Data())
                    }
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Runs `body` in one transaction (BEGIN IMMEDIATE … COMMIT, rolled back on throw).
    /// Nested calls become savepoints.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        if sqlite3_get_autocommit(db) == 0 {
            try execute("SAVEPOINT nested;")
            do {
                let v = try body()
                try execute("RELEASE nested;")
                return v
            } catch {
                try? execute("ROLLBACK TO nested; RELEASE nested;")
                throw error
            }
        }
        try execute("BEGIN IMMEDIATE;")
        do {
            let v = try body()
            try execute("COMMIT;")
            return v
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
}

extension MemoryDatabase.Value {
    var double: Double? {
        switch self {
        case .real(let d): d
        case .int(let n): Double(n)
        case .text(let s): Double(s)
        default: nil
        }
    }
    var int: Int? {
        switch self {
        case .int(let n): Int(n)
        case .real(let d): Int(d)
        case .text(let s): Int(s)
        default: nil
        }
    }
    var string: String? {
        switch self {
        case .text(let s): s
        case .real(let d): String(d)
        case .int(let n): String(n)
        default: nil
        }
    }
    var data: Data? {
        if case .blob(let d) = self { return d }
        return nil
    }
}
