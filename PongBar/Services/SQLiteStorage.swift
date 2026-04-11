//
//  SQLiteStorage.swift
//  PongBar
//
//  SQLite-based persistent storage for latency samples.
//  Uses WAL mode, pre-compiled prepared statements, and batch transactions.
//

import Foundation
import SQLite3
import os.log

/// SQLite-backed storage for latency samples.
/// Optimized: WAL mode, cached prepared statement, batch inserts per tick.
/// All mutable state is guarded by `queue` — opt out of default MainActor isolation.
final class SQLiteStorage: @unchecked Sendable {
    static let shared = SQLiteStorage()
    private static let logger = Logger(subsystem: "PongBar", category: "SQLite")

    private nonisolated(unsafe) var db: OpaquePointer?
    private let queue = DispatchQueue(label: "SQLiteStorage", qos: .utility)
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Pre-compiled insert statement (reused across writes).
    private var insertStmt: OpaquePointer?

    /// Pending samples to batch-insert in a single transaction.
    private var pendingSamples: [LatencySample] = []

    /// Thread-safe cached count using OSAllocatedUnfairLock.
    /// Written on `queue`, read from @MainActor (UI).
    private let cachedCount = OSAllocatedUnfairLock(initialState: 0)

    private var insertCount = 0

    private init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return }
        let dir = appSupport.appendingPathComponent("PongBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("samples.sqlite").path

        // All DB operations must run on the serial queue for thread safety
        queue.sync {
            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                exec("PRAGMA journal_mode=WAL;")
                exec("PRAGMA synchronous=NORMAL;")
                createTable()
                createIndex()
                prepareStatements()
                cachedCount.withLock { $0 = self.sampleCount() }
            }
        }
    }

    // No deinit — singleton is never deallocated.
    // DB is flushed via flushSync() on app termination.

    // MARK: - Schema & Migration

    private static let currentSchemaVersion = 3

    private func createTable() {
        exec("""
        CREATE TABLE IF NOT EXISTS samples (
            timestamp REAL NOT NULL,
            target TEXT NOT NULL,
            latency REAL
        );
        """)
        exec("CREATE TABLE IF NOT EXISTS schema_version (version INTEGER);")

        // Check and migrate
        let version = getSchemaVersion()
        if version < Self.currentSchemaVersion {
            migrateSchema(from: version)
        }
    }

    private func createIndex() {
        exec("CREATE INDEX IF NOT EXISTS idx_samples_target_time ON samples(target, timestamp);")
        exec("CREATE INDEX IF NOT EXISTS idx_incidents_start ON incidents(start_time);")
    }

    private func getSchemaVersion() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        var version = 0
        if sqlite3_prepare_v2(db, "SELECT version FROM schema_version LIMIT 1;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                version = Int(sqlite3_column_int(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return version
    }

    private func migrateSchema(from version: Int) {
        if version < 2 {
            exec("ALTER TABLE samples ADD COLUMN vpn INTEGER DEFAULT 0;")
        }
        if version < 3 {
            exec("""
            CREATE TABLE IF NOT EXISTS incidents (
                id TEXT PRIMARY KEY,
                target TEXT NOT NULL,
                start_time REAL NOT NULL,
                end_time REAL,
                category TEXT,
                is_stale INTEGER DEFAULT 0
            );
            """)
        }
        exec("DELETE FROM schema_version;")
        exec("INSERT INTO schema_version (version) VALUES (\(Self.currentSchemaVersion));")
    }

    private func prepareStatements() {
        guard let db else { return }
        let sql = "INSERT INTO samples (timestamp, target, latency, vpn) VALUES (?, ?, ?, ?);"
        sqlite3_prepare_v2(db, sql, -1, &insertStmt, nil)
    }

    // MARK: - Write (Batched)

    /// Queue a sample for batch insert.
    func record(_ sample: LatencySample) {
        queue.async { [weak self] in
            self?.pendingSamples.append(sample)
        }
    }

    /// Synchronous flush for app termination — blocks until all pending writes complete.
    /// Synchronous flush — guaranteed to write all pending data. Used on app termination.
    func flushSync() {
        queue.sync {
            self.flushInternal()
        }
    }

    /// Flush all pending samples in a single transaction. Call once per tick.
    func flush() {
        queue.async { [weak self] in
            self?.flushInternal()
        }
    }

    /// Must be called on `queue`.
    private func flushInternal() {
        guard let _ = db, let stmt = insertStmt else { return }
        let samples = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        guard !samples.isEmpty else { return }

        guard exec("BEGIN TRANSACTION;") else {
            pendingSamples.insert(contentsOf: samples, at: 0)
            return
        }

        let SQLITE_TRANSIENT = Self.sqliteTransient
        var insertedCount = 0

        for sample in samples {
            sqlite3_reset(stmt)
            sqlite3_clear_bindings(stmt)

            sqlite3_bind_double(stmt, 1, sample.timestamp.timeIntervalSince1970)
            sqlite3_bind_text(stmt, 2, sample.effectiveKey, -1, SQLITE_TRANSIENT)
            if let latency = sample.latency {
                sqlite3_bind_double(stmt, 3, latency)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_int(stmt, 4, sample.vpnActive ? 1 : 0)
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE {
                insertedCount += 1
            } else {
                Self.logger.error("Sample insert failed: \(rc) for \(sample.effectiveKey, privacy: .public)")
            }
        }

        if !exec("COMMIT;") {
            exec("ROLLBACK;")
            pendingSamples.insert(contentsOf: samples, at: 0)
            return
        }

        let successCount = insertedCount
        cachedCount.withLock { $0 += successCount }
        insertCount += successCount

        if insertCount >= Config.storageTrimInterval {
            insertCount = 0
            trimOldSamples()
        }
    }

    // MARK: - Read

    /// Fetch samples by target enum.
    func fetch(target: PingTarget, from startDate: Date, to endDate: Date = Date()) async -> [LatencySample] {
        await fetch(key: target.rawValue, target: target, from: startDate, to: endDate)
    }

    /// Fetch samples by arbitrary string key (for custom targets).
    func fetch(key: String, from startDate: Date, to endDate: Date = Date()) async -> [LatencySample] {
        await fetch(key: key, target: .internet, from: startDate, to: endDate)
    }

    /// Internal fetch by string key. Non-blocking async.
    private func fetch(key: String, target: PingTarget, from startDate: Date, to endDate: Date) async -> [LatencySample] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let db = self.db else {
                    continuation.resume(returning: [])
                    return
                }
                let sql = "SELECT timestamp, latency, vpn FROM samples WHERE target = ? AND timestamp >= ? AND timestamp <= ? ORDER BY timestamp;"
                var stmt: OpaquePointer?
                var results: [LatencySample] = []

                let SQLITE_TRANSIENT = Self.sqliteTransient

                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
                    sqlite3_bind_double(stmt, 2, startDate.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 3, endDate.timeIntervalSince1970)

                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                        let latency: Double? = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 1)
                        let vpn = sqlite3_column_int(stmt, 2) != 0
                        results.append(LatencySample(target: target, timestamp: timestamp, latency: latency, vpnActive: vpn))
                    }
                }
                sqlite3_finalize(stmt)
                continuation.resume(returning: results)
            }
        }
    }



    /// Approximate sample count. Thread-safe via OSAllocatedUnfairLock.
    var count: Int { cachedCount.withLock { $0 } }

    // MARK: - Maintenance

    private func trimOldSamples() {
        guard let db else { return }
        let cutoff = Date().addingTimeInterval(-Config.retentionPeriod).timeIntervalSince1970
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM samples WHERE timestamp < ?;", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff)
            sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
        cachedCount.withLock { $0 = self.sampleCount() }
    }

    /// Count samples in the database. Must be called on `queue`.
    private nonisolated func sampleCount() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        var result = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM samples;", -1, &stmt, nil) == SQLITE_OK {
            if sqlite3_step(stmt) == SQLITE_ROW {
                result = Int(sqlite3_column_int64(stmt, 0))
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    // MARK: - Incident Persistence

    /// Save or update an incident in SQLite.
    func saveIncident(_ incident: Incident) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let SQLITE_TRANSIENT = Self.sqliteTransient
            let sql = "INSERT OR REPLACE INTO incidents (id, target, start_time, end_time, category, is_stale) VALUES (?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, incident.id.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, incident.target.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 3, incident.startTime.timeIntervalSince1970)
                if let end = incident.endTime {
                    sqlite3_bind_double(stmt, 4, end.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                if let cat = incident.category {
                    sqlite3_bind_text(stmt, 5, cat.rawValue, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                sqlite3_bind_int(stmt, 6, incident.isStale ? 1 : 0)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Load all incidents from SQLite, newest first.
    func loadIncidents() async -> [Incident] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let db = self.db else {
                    continuation.resume(returning: [])
                    return
                }
                let sql = "SELECT id, target, start_time, end_time, category, is_stale FROM incidents ORDER BY start_time DESC LIMIT ?;"
                var stmt: OpaquePointer?
                var results: [Incident] = []

                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_int(stmt, 1, Int32(Config.maxIncidents))

                    while sqlite3_step(stmt) == SQLITE_ROW {
                        guard let idStr = sqlite3_column_text(stmt, 0),
                              let targetStr = sqlite3_column_text(stmt, 1) else { continue }

                        let id = UUID(uuidString: String(cString: idStr)) ?? UUID()
                        let target = PingTarget(rawValue: String(cString: targetStr)) ?? .internet
                        let startTime = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                        let endTime: Date? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 3))
                        let category: IncidentCategory? = {
                            guard let catStr = sqlite3_column_text(stmt, 4) else { return nil }
                            return IncidentCategory(rawValue: String(cString: catStr))
                        }()
                        let isStale = sqlite3_column_int(stmt, 5) != 0

                        var incident = Incident(id: id, target: target, startTime: startTime, category: category)
                        incident.endTime = endTime
                        incident.isStale = isStale
                        results.append(incident)
                    }
                }
                sqlite3_finalize(stmt)
                continuation.resume(returning: results)
            }
        }
    }

    /// Delete a specific incident.
    func deleteIncident(id: UUID) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let SQLITE_TRANSIENT = Self.sqliteTransient
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "DELETE FROM incidents WHERE id = ?;", -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, id.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// Batch save all incidents in a single transaction.
    func saveIncidentsBatch(_ incidents: [Incident]) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let SQLITE_TRANSIENT = Self.sqliteTransient
            guard self.exec("BEGIN TRANSACTION;") else { return }
            guard self.exec("DELETE FROM incidents;") else {
                self.exec("ROLLBACK;")
                return
            }
            let sql = "INSERT INTO incidents (id, target, start_time, end_time, category, is_stale) VALUES (?, ?, ?, ?, ?, ?);"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                self.exec("ROLLBACK;")
                return
            }
            for incident in incidents {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, incident.id.uuidString, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(stmt, 2, incident.target.rawValue, -1, SQLITE_TRANSIENT)
                sqlite3_bind_double(stmt, 3, incident.startTime.timeIntervalSince1970)
                if let end = incident.endTime {
                    sqlite3_bind_double(stmt, 4, end.timeIntervalSince1970)
                } else {
                    sqlite3_bind_null(stmt, 4)
                }
                if let cat = incident.category {
                    sqlite3_bind_text(stmt, 5, cat.rawValue, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(stmt, 5)
                }
                sqlite3_bind_int(stmt, 6, incident.isStale ? 1 : 0)
                if sqlite3_step(stmt) != SQLITE_DONE {
                    Self.logger.error("Incident insert failed, rolling back")
                    sqlite3_finalize(stmt)
                    self.exec("ROLLBACK;")
                    return
                }
            }
            sqlite3_finalize(stmt)
            if !self.exec("COMMIT;") {
                self.exec("ROLLBACK;")
            }
        }
    }

    /// Clear all incidents.
    func clearIncidents() {
        queue.async { [weak self] in
            self?.exec("DELETE FROM incidents;")
        }
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var errorMsg: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(db, sql, nil, nil, &errorMsg)
        if result != SQLITE_OK {
            let message = errorMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMsg)
            Self.logger.error("SQLite exec failed: \(message, privacy: .public) for: \(sql, privacy: .public)")
            return false
        }
        return true
    }
}
