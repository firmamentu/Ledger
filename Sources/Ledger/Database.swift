import Foundation
import SQLite3

// C 宏 SQLITE_TRANSIENT 不导入 Swift；等价写法（-1）让 SQLite 自行拷贝绑定值
private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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

    // MARK: - meta 键值

    func metaGet(_ key: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        var statement: OpaquePointer?
        let sql = "SELECT value FROM meta WHERE key = ?;"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)

        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(statement, 0))
    }

    func metaSet(_ key: String, _ value: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        var statement: OpaquePointer?
        let sql = "INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?);"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, key, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, value, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
    }

    // MARK: - 记账数据（M3）

    struct AppSummary {
        var bundleID: String
        var name: String
        var version: String?
        var installPath: String?
        var iconPath: String?
        var state: String?
        var footprint: Int64
        var hasSignatureWarning: Bool
        var fileCount: Int
        var registrationCount: Int
    }

    func appRow(atInstallPath installPath: String) throws -> (bundleID: String, state: String)? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        let statement = try prepareUnlocked("SELECT bundle_id, state FROM apps WHERE install_path = ? LIMIT 1;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, installPath, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return (
            String(cString: sqlite3_column_text(statement, 0)),
            String(cString: sqlite3_column_text(statement, 1))
        )
    }

    func setAppState(bundleID: String, state: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        let statement = try prepareUnlocked("UPDATE apps SET state = ? WHERE bundle_id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, state, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, bundleID, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func setAppInstallPath(bundleID: String, installPath: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        let statement = try prepareUnlocked("UPDATE apps SET install_path = ? WHERE bundle_id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, installPath, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, bundleID, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
    }

    /// recorded/tracked 的 App（启动对账用，§12 Ledger 退出期卸载）。
    func trackedApps() throws -> [(bundleID: String, installPath: String?, state: String)] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        let statement = try prepareUnlocked("SELECT bundle_id, install_path, state FROM apps WHERE state IN ('recorded', 'tracked');")
        defer { sqlite3_finalize(statement) }

        var result: [(bundleID: String, installPath: String?, state: String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append((
                String(cString: sqlite3_column_text(statement, 0)),
                sqlite3_column_text(statement, 1).map { String(cString: $0) },
                String(cString: sqlite3_column_text(statement, 2))
            ))
        }
        return result
    }

    func insertApp(bundleID: String, name: String, version: String?, installPath: String, iconPath: String?, firstSeen: Double, state: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        // ON CONFLICT 更新但不覆盖 first_seen（重装应保留首次见到时间）
        let statement = try prepareUnlocked("""
        INSERT INTO apps(bundle_id, name, version, install_path, icon_path, first_seen, state)
        VALUES(?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(bundle_id) DO UPDATE SET
            name = excluded.name,
            version = excluded.version,
            install_path = excluded.install_path,
            icon_path = excluded.icon_path,
            state = excluded.state;
        """)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, bundleID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, name, -1, sqliteTransient)
        if let version { sqlite3_bind_text(statement, 3, version, -1, sqliteTransient) } else { sqlite3_bind_null(statement, 3) }
        sqlite3_bind_text(statement, 4, installPath, -1, sqliteTransient)
        if let iconPath { sqlite3_bind_text(statement, 5, iconPath, -1, sqliteTransient) } else { sqlite3_bind_null(statement, 5) }
        sqlite3_bind_double(statement, 6, firstSeen)
        sqlite3_bind_text(statement, 7, state, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func insertManifest(appBundleID: String, start: Double, finish: Double, observedScope: String, blindSpots: String, status: String, createdAt: Double) throws -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        let statement = try prepareUnlocked(
            "INSERT INTO manifests(app_bundle_id, install_started_at, install_finished_at, observed_scope_json, blind_spots_json, status, created_at) VALUES(?, ?, ?, ?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, appBundleID, -1, sqliteTransient)
        sqlite3_bind_double(statement, 2, start)
        sqlite3_bind_double(statement, 3, finish)
        sqlite3_bind_text(statement, 4, observedScope, -1, sqliteTransient)
        sqlite3_bind_text(statement, 5, blindSpots, -1, sqliteTransient)
        sqlite3_bind_text(statement, 6, status, -1, sqliteTransient)
        sqlite3_bind_double(statement, 7, createdAt)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
        return sqlite3_last_insert_rowid(handle)
    }

    func insertManifestItems(_ rows: [(manifestID: Int64, path: String, itemType: String, category: String, size: Int64, mtime: Double, inode: Int64, registrationKind: String?, verdict: String, requiresAdmin: Bool, evidence: String)]) throws {
        guard !rows.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        try executeUnlocked("BEGIN IMMEDIATE;")
        do {
            let statement = try prepareUnlocked(
                "INSERT INTO manifest_items(manifest_id, path, item_type, category, size_bytes, mtime, inode, registration_kind, verdict, requires_admin, evidence) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);"
            )
            defer { sqlite3_finalize(statement) }
            for row in rows {
                sqlite3_bind_int64(statement, 1, row.manifestID)
                sqlite3_bind_text(statement, 2, row.path, -1, sqliteTransient)
                sqlite3_bind_text(statement, 3, row.itemType, -1, sqliteTransient)
                sqlite3_bind_text(statement, 4, row.category, -1, sqliteTransient)
                sqlite3_bind_int64(statement, 5, row.size)
                sqlite3_bind_double(statement, 6, row.mtime)
                sqlite3_bind_int64(statement, 7, row.inode)
                if let kind = row.registrationKind {
                    sqlite3_bind_text(statement, 8, kind, -1, sqliteTransient)
                } else {
                    sqlite3_bind_null(statement, 8)
                }
                sqlite3_bind_text(statement, 9, row.verdict, -1, sqliteTransient)
                sqlite3_bind_int64(statement, 10, row.requiresAdmin ? 1 : 0)
                sqlite3_bind_text(statement, 11, row.evidence, -1, sqliteTransient)
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
                }
                sqlite3_reset(statement)
                sqlite3_clear_bindings(statement)
            }
            try executeUnlocked("COMMIT;")
        } catch {
            try? executeUnlocked("ROLLBACK;")
            throw error
        }
    }

    func supersedeManifests(appBundleID: String, except newID: Int64) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        let statement = try prepareUnlocked(
            "UPDATE manifests SET status = 'superseded' WHERE app_bundle_id = ? AND id != ? AND status != 'superseded';"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, appBundleID, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 2, newID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func insertAppEvent(ts: Double, bundleID: String, kind: String, detail: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        let statement = try prepareUnlocked(
            "INSERT INTO app_events(ts, app_bundle_id, kind, detail) VALUES(?, ?, ?, ?);"
        )
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, ts)
        sqlite3_bind_text(statement, 2, bundleID, -1, sqliteTransient)
        sqlite3_bind_text(statement, 3, kind, -1, sqliteTransient)
        sqlite3_bind_text(statement, 4, detail, -1, sqliteTransient)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
    }

    func appSummaries() throws -> [AppSummary] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        let statement = try prepareUnlocked("""
        SELECT a.bundle_id, a.name, a.version, a.install_path, a.icon_path, a.state,
               COALESCE((SELECT SUM(mi.size_bytes) FROM manifest_items mi
                         JOIN manifests m ON mi.manifest_id = m.id
                         WHERE m.app_bundle_id = a.bundle_id AND m.status != 'superseded'), 0),
               EXISTS(SELECT 1 FROM app_events e
                      WHERE e.app_bundle_id = a.bundle_id AND e.detail LIKE 'signature_warning%'),
               (SELECT COUNT(*) FROM manifest_items mi
                JOIN manifests m ON mi.manifest_id = m.id
                WHERE m.app_bundle_id = a.bundle_id AND m.status != 'superseded' AND mi.item_type != 'registration'),
               (SELECT COUNT(*) FROM manifest_items mi
                JOIN manifests m ON mi.manifest_id = m.id
                WHERE m.app_bundle_id = a.bundle_id AND m.status != 'superseded' AND mi.item_type = 'registration')
        FROM apps a
        ORDER BY 7 DESC;
        """)
        defer { sqlite3_finalize(statement) }

        var result: [AppSummary] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            result.append(AppSummary(
                bundleID: String(cString: sqlite3_column_text(statement, 0)),
                name: String(cString: sqlite3_column_text(statement, 1)),
                version: sqlite3_column_text(statement, 2).map { String(cString: $0) },
                installPath: sqlite3_column_text(statement, 3).map { String(cString: $0) },
                iconPath: sqlite3_column_text(statement, 4).map { String(cString: $0) },
                state: sqlite3_column_text(statement, 5).map { String(cString: $0) },
                footprint: sqlite3_column_int64(statement, 6),
                hasSignatureWarning: sqlite3_column_int64(statement, 7) != 0,
                fileCount: Int(sqlite3_column_int64(statement, 8)),
                registrationCount: Int(sqlite3_column_int64(statement, 9))
            ))
        }
        return result
    }

    private func prepareUnlocked(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw DatabaseError.open("数据库已关闭") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
        return statement!
    }

    // MARK: - 索引持久化

    func loadIndexEntries() throws -> [(path: String, size: Int64, mtime: Double, inode: Int64)] {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        var statement: OpaquePointer?
        let sql = "SELECT path, size_bytes, mtime, inode FROM index_entries;"
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        var rows: [(path: String, size: Int64, mtime: Double, inode: Int64)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            rows.append((
                path: String(cString: sqlite3_column_text(statement, 0)),
                size: sqlite3_column_int64(statement, 1),
                mtime: sqlite3_column_double(statement, 2),
                inode: sqlite3_column_int64(statement, 3)
            ))
        }
        return rows
    }

    /// 单事务批量应用索引变化：upsert 与 delete 分别成批。
    func applyIndexChanges(
        upserts: [(path: String, size: Int64, mtime: Double, inode: Int64)],
        deletes: [String]
    ) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { throw DatabaseError.open("数据库已关闭") }

        try executeUnlocked("BEGIN IMMEDIATE;")
        do {
            if !upserts.isEmpty {
                var statement: OpaquePointer?
                let sql = "INSERT OR REPLACE INTO index_entries(path, size_bytes, mtime, inode) VALUES(?, ?, ?, ?);"
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
                }
                defer { sqlite3_finalize(statement) }
                for row in upserts {
                    sqlite3_bind_text(statement, 1, row.path, -1, sqliteTransient)
                    sqlite3_bind_int64(statement, 2, row.size)
                    sqlite3_bind_double(statement, 3, row.mtime)
                    sqlite3_bind_int64(statement, 4, row.inode)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
                    }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }

            if !deletes.isEmpty {
                var statement: OpaquePointer?
                let sql = "DELETE FROM index_entries WHERE path = ?;"
                guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
                    throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
                }
                defer { sqlite3_finalize(statement) }
                for path in deletes {
                    sqlite3_bind_text(statement, 1, path, -1, sqliteTransient)
                    guard sqlite3_step(statement) == SQLITE_DONE else {
                        throw DatabaseError.execution(String(cString: sqlite3_errmsg(handle)))
                    }
                    sqlite3_reset(statement)
                    sqlite3_clear_bindings(statement)
                }
            }

            try executeUnlocked("COMMIT;")
        } catch {
            try? executeUnlocked("ROLLBACK;")
            throw error
        }
    }

    private func migrate() throws {
        let version = try scalarUnlocked("PRAGMA user_version;")
        if version == 1 {
            // M2 起新增索引持久化表（规格 §8 未覆盖的内部表，见 devlog）：幂等补建，兼容既有库
            try execute("""
            CREATE TABLE IF NOT EXISTS index_entries (
                path TEXT PRIMARY KEY,
                size_bytes INTEGER,
                mtime REAL,
                inode INTEGER
            );
            """)
            return
        }
        guard version == 0 else { throw DatabaseError.unsupportedSchema(version) }

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
            CREATE TABLE IF NOT EXISTS index_entries (
                path TEXT PRIMARY KEY,
                size_bytes INTEGER,
                mtime REAL,
                inode INTEGER
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
