import Foundation
import SQLite3

/// A deliberately tiny wrapper over the SQLite that ships inside iOS (libsqlite3).
/// Dee stores *state* here — emotion levels, personality traits, age settings and
/// daily aggregates — never transcripts.
public final class SQLiteStore: @unchecked Sendable {
    public enum Failure: Error, CustomStringConvertible {
        case open(String), prepare(String), step(String)
        public var description: String {
            switch self {
            case .open(let m): "SQLite open: \(m)"
            case .prepare(let m): "SQLite prepare: \(m)"
            case .step(let m): "SQLite step: \(m)"
            }
        }
    }

    public enum Value: Equatable, Sendable {
        case real(Double), int(Int64), text(String), null
    }

    private var db: OpaquePointer?
    /// Recursive so `transaction` can hold it for its whole body while the body
    /// calls `execute`/`query` — no other thread can interleave statements.
    private let lock = NSRecursiveLock()
    private var savepointDepth = 0
    public let path: String

    /// `path` of ":memory:" gives an in-memory database (tests).
    public init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close_v2(db)
            db = nil
            throw Failure.open(msg)
        }
        // Another connection (a second Mind, a widget) waits up to 2 s for the
        // write lock instead of failing at once with SQLITE_BUSY.
        sqlite3_busy_timeout(db, 2000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
    }

    deinit { sqlite3_close_v2(db) }

    private var errorMessage: String { String(cString: sqlite3_errmsg(db)) }

    /// Runs one or more statements without results.
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw Failure.step(msg)
        }
    }

    /// Runs a statement with bound parameters; returns rows as column→value maps.
    @discardableResult
    public func query(_ sql: String, _ params: [Value] = []) throws -> [[String: Value]] {
        lock.lock(); defer { lock.unlock() }
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
            case .null: sqlite3_bind_null(stmt, idx)
            }
        }
        var rows: [[String: Value]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw Failure.step(errorMessage) }
            var row: [String: Value] = [:]
            for c in 0..<sqlite3_column_count(stmt) {
                let name = String(cString: sqlite3_column_name(stmt, c))
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row[name] = .int(sqlite3_column_int64(stmt, c))
                case SQLITE_FLOAT: row[name] = .real(sqlite3_column_double(stmt, c))
                case SQLITE_TEXT: row[name] = .text(String(cString: sqlite3_column_text(stmt, c)))
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Runs `body` inside a transaction, holding the store's lock throughout.
    /// Nested calls become savepoints inside the outer transaction.
    public func transaction(_ body: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        if sqlite3_get_autocommit(db) == 0 {
            savepointDepth += 1
            let name = "sp\(savepointDepth)"
            defer { savepointDepth -= 1 }
            try execute("SAVEPOINT \(name);")
            do {
                try body()
                try execute("RELEASE \(name);")
            } catch {
                try? execute("ROLLBACK TO \(name); RELEASE \(name);")
                throw error
            }
            return
        }
        try execute("BEGIN IMMEDIATE;")
        do {
            try body()
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }
}

public extension SQLiteStore.Value {
    var double: Double? {
        switch self {
        case .real(let d): d
        case .int(let n): Double(n)
        case .text(let s): Double(s)
        case .null: nil
        }
    }
    var string: String? {
        switch self {
        case .text(let s): s
        case .real(let d): String(d)
        case .int(let n): String(n)
        case .null: nil
        }
    }
}
