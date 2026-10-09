import Foundation
import SQLite3

/// The tiny SQLite wrapper behind `SelfStore` (patterned on DeeMind's and DeeMemory's,
/// which are internal to their modules). WAL, foreign keys, secure_delete, 2 s busy
/// timeout; nested transactions become savepoints.
final class SelfDatabase {
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

        var string: String? { if case .text(let s) = self { s } else { nil } }
        var double: Double? {
            switch self {
            case .real(let d): d
            case .int(let i): Double(i)
            default: nil
            }
        }
        var int: Int? {
            switch self {
            case .int(let i): Int(i)
            case .real(let d): Int(d)
            default: nil
            }
        }
        var data: Data? { if case .blob(let d) = self { d } else { nil } }
    }

    typealias Row = [String: Value]

    private var db: OpaquePointer?
    private var depth = 0
    let path: String

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

    func execute(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw Failure.step(msg)
        }
    }

    @discardableResult
    func query(_ sql: String, _ args: [Value] = []) throws -> [Row] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw Failure.prepare("\(errorMessage) — \(sql.prefix(80))") }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .real(let d): sqlite3_bind_double(stmt, idx, d)
            case .int(let n): sqlite3_bind_int64(stmt, idx, n)
            case .text(let s): sqlite3_bind_text(stmt, idx, s, -1, transient)
            case .blob(let d): _ = d.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32(d.count), transient) }
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
                    row[name] = .blob(n > 0 ? Data(bytes: sqlite3_column_blob(stmt, c), count: n) : Data())
                default: row[name] = .null
                }
            }
            rows.append(row)
        }
        return rows
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        let name = "sp\(depth)"
        if depth == 0 { try execute("BEGIN IMMEDIATE;") } else { try execute("SAVEPOINT \(name);") }
        depth += 1
        do {
            let r = try body()
            depth -= 1
            if depth == 0 { try execute("COMMIT;") } else { try execute("RELEASE \(name);") }
            return r
        } catch {
            depth -= 1
            if depth == 0 { try? execute("ROLLBACK;") } else { try? execute("ROLLBACK TO \(name); RELEASE \(name);") }
            throw error
        }
    }

    func tableExists(_ name: String) throws -> Bool {
        try !query("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", [.text(name)]).isEmpty
    }

    func checkpoint() throws { try execute("PRAGMA wal_checkpoint(TRUNCATE);") }
}
