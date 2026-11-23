import Foundation
import SQLite3

enum DatabaseError: LocalizedError {
    case open(String)
    case execution(String)
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .open(let message):
            return "无法打开数据库：\(message)"
        case .execution(let message):
            return "数据库操作失败：\(message)"
        case .unsupportedSchema(let version):
            return "不支持的数据库版本：\(version)"
        }
    }
}

/// The local ledger. A single SQLite connection guarded by a lock keeps the
/// fixed schema usable from the main actor and later background scanners.
final class Database {
    private var handle: OpaquePointer?
    private let lock = NSLock()

    init(url: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &opened,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )

        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(result)"
            if let opened { sqlite3_close(opened) }
            throw DatabaseError.open(message)
        }

        handle = opened
        sqlite3_busy_timeout(opened, 5_000)

        do {
            try execute("PRAGMA journal_mode=WAL;")
            try execute("PRAGMA synchronous=NORMAL;")
            try execute("PRAGMA foreign_keys=ON;")
            try migrate()
        } catch {
            sqlite3_close(opened)
            handle = nil
            throw error
        }
    }

    deinit {
        if let handle { sqlite3_close(handle) }
    }

    func execute(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        try executeUnlocked(sql)
    }

    func scalar(_ sql: String) throws -> Int {
        lock.lock()
        defer { lock.unlock() }
        return try scalarUnlocked(sql)
    }

    private func migrate() throws {
        let version = try scalarUnlocked("PRAGMA user_version;")
        guard version == 0 else {
            guard version == 1 else { throw DatabaseError.unsupportedSchema(version) }
            return
        }

        try execute("BEGIN IMMEDIATE;")
        do {
            try execute("""
            CREATE TABLE IF NOT EXISTS apps (
                bundle_id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                version TEXT,
                install_path TEXT,
                icon_path TEXT,
                first_seen REAL,
                state TEXT
            );
            CREATE TABLE IF NOT EXISTS manifests (
                id INTEGER PRIMARY KEY,
                app_bundle_id TEXT,
                install_started_at REAL,
                install_finished_at REAL,
                observed_scope_json TEXT,
                blind_spots_json TEXT,
                status TEXT,
                created_at REAL
            );
            CREATE TABLE IF NOT EXISTS manifest_items (
                id INTEGER PRIMARY KEY,
                manifest_id INTEGER,
                path TEXT,
                item_type TEXT,
                category TEXT,
                size_bytes INTEGER,
                mtime REAL,
                inode INTEGER,
                registration_kind TEXT,
                verdict TEXT,
                requires_admin INTEGER,
                evidence TEXT
            );
            CREATE TABLE IF NOT EXISTS changes (
                id INTEGER PRIMARY KEY,
                ts REAL,
                path TEXT,
                app_bundle_id TEXT,
                kind TEXT,
                size_delta INTEGER,
                evidence TEXT
            );
            CREATE TABLE IF NOT EXISTS app_events (
                id INTEGER PRIMARY KEY,
                ts REAL,
                app_bundle_id TEXT,
                kind TEXT,
                detail TEXT
            );
            CREATE TABLE IF NOT EXISTS reports (
                id INTEGER PRIMARY KEY,
                created_at REAL,
                kind TEXT,
                content_json TEXT
            );
            CREATE TABLE IF NOT EXISTS meta (
                key TEXT PRIMARY KEY,
                value TEXT
            );
            """)
            try execute("PRAGMA user_version = 1;")
            try execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('schema_version', '1');")
            try execute("COMMIT;")
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    private func executeUnlocked(_ sql: String) throws {
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(handle, sql, nil, nil, &errorMessage)

        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(errorMessage)
            throw DatabaseError.execution(message)
        }
    }

    private func scalarUnlocked(_ sql: String) throws -> Int {
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_column_int64(statement, 0))
    }
}
