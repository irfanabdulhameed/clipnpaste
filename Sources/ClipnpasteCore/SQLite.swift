import Foundation
import SQLite3

enum SQLiteValue {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)

    static func of(_ v: String?) -> SQLiteValue { v.map { .text($0) } ?? .null }
    static func of(_ v: Data?) -> SQLiteValue { v.map { .blob($0) } ?? .null }
    static func of(_ v: Int?) -> SQLiteValue { v.map { .int(Int64($0)) } ?? .null }
}

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "SQLite error \(code): \(message)" }
}

/// One sqlite3 connection. Not thread-safe: the owner keeps it on one actor.
final class SQLiteDatabase {
    private let handle: OpaquePointer

    init(path: String) throws {
        var db: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open \(path)"
            sqlite3_close_v2(db)
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
    }

    deinit { sqlite3_close_v2(handle) }

    /// Runs statements that take no parameters.
    func execute(_ sql: String) throws {
        let rc = sqlite3_exec(handle, sql, nil, nil, nil)
        guard rc == SQLITE_OK else { throw failure(rc) }
    }

    /// Runs one statement and ignores any rows.
    func run(_ sql: String, _ values: [SQLiteValue] = []) throws {
        try withStatement(sql, values) { stmt in
            let rc = sqlite3_step(stmt)
            guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw failure(rc) }
        }
    }

    func query<T>(_ sql: String, _ values: [SQLiteValue] = [], _ row: (SQLiteRow) throws -> T) throws -> [T] {
        try withStatement(sql, values) { stmt in
            var out: [T] = []
            while true {
                let rc = sqlite3_step(stmt)
                if rc == SQLITE_DONE { break }
                guard rc == SQLITE_ROW else { throw failure(rc) }
                out.append(try row(SQLiteRow(stmt: stmt)))
            }
            return out
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    /// Rows inserted, changed or deleted since the connection opened.
    var totalChanges: Int { Int(sqlite3_total_changes64(handle)) }

    private func withStatement<T>(_ sql: String, _ values: [SQLiteValue], _ body: (OpaquePointer) throws -> T) throws -> T {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else { throw failure(rc) }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in values.enumerated() {
            let rc = Self.bind(value, at: Int32(i + 1), in: stmt)
            guard rc == SQLITE_OK else { throw failure(rc) }
        }
        return try body(stmt)
    }

    private static var transient: sqlite3_destructor_type { unsafeBitCast(-1, to: sqlite3_destructor_type.self) }

    private static func bind(_ value: SQLiteValue, at i: Int32, in stmt: OpaquePointer) -> Int32 {
        switch value {
        case .null:
            return sqlite3_bind_null(stmt, i)
        case .int(let v):
            return sqlite3_bind_int64(stmt, i, v)
        case .double(let v):
            return sqlite3_bind_double(stmt, i, v)
        case .text(var s):
            // Explicit length, so text with NUL characters survives.
            return s.withUTF8 { buf in
                guard let base = buf.baseAddress else { return sqlite3_bind_text(stmt, i, "", 0, transient) }
                return base.withMemoryRebound(to: CChar.self, capacity: buf.count) {
                    sqlite3_bind_text(stmt, i, $0, Int32(buf.count), transient)
                }
            }
        case .blob(let data):
            return data.withUnsafeBytes { buf in
                guard let base = buf.baseAddress, buf.count > 0 else { return sqlite3_bind_zeroblob(stmt, i, 0) }
                return sqlite3_bind_blob(stmt, i, base, Int32(buf.count), transient)
            }
        }
    }

    private func failure(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(handle)))
    }
}

/// The current row of a stepping statement; valid only inside the `query` callback.
struct SQLiteRow {
    fileprivate let stmt: OpaquePointer

    func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }

    func int(_ i: Int32) -> Int? { isNull(i) ? nil : Int(sqlite3_column_int64(stmt, i)) }

    func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }

    func double(_ i: Int32) -> Double? { isNull(i) ? nil : sqlite3_column_double(stmt, i) }

    func string(_ i: Int32) -> String? {
        guard !isNull(i), let p = sqlite3_column_text(stmt, i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
    }

    func data(_ i: Int32) -> Data? {
        guard !isNull(i) else { return nil }
        let n = Int(sqlite3_column_bytes(stmt, i))
        guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return Data() }
        return Data(bytes: p, count: n)
    }
}
