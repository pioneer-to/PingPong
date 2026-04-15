//
//  LocalDeviceSpeedStorage.swift
//  PongBar
//
//  SQLite storage for monitored local-network device link speeds.
//

import Foundation
import SQLite3
import os.log

struct LocalDeviceSpeedSample: Identifiable {
    let id = UUID()
    let timestamp: Date
    let speedMbps: Double
    let pingLatency: Double?
    let signalStrength: Int?
}

enum LinkSpeedUnit {
    case kbitPerSecond
    case mbitPerSecond
    case gbitPerSecond
}

final class LocalDeviceSpeedStorage: @unchecked Sendable {
    static let shared = LocalDeviceSpeedStorage()
    private static let logger = Logger(subsystem: "PongBar", category: "LocalDeviceSpeedSQLite")
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private nonisolated(unsafe) var db: OpaquePointer?
    private let queue = DispatchQueue(label: "LocalDeviceSpeedStorage", qos: .utility)
    private var insertStmt: OpaquePointer?
    private var cachedSelectedMACs: Set<String> = []
    private var insertCount = 0

    private init() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }
        let dir = appSupport.appendingPathComponent("PongBar", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("localdevices.sqlite").path

        queue.sync {
            let permissions: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
            try? FileManager.default.setAttributes(permissions, ofItemAtPath: dir.path)

            if sqlite3_open(dbPath, &db) == SQLITE_OK {
                try? FileManager.default.setAttributes(permissions, ofItemAtPath: dbPath)
                exec("PRAGMA journal_mode=WAL;")
                exec("PRAGMA synchronous=NORMAL;")
                createTables()
                createIndexes()
                prepareStatements()
                cachedSelectedMACs = loadSelectedMACs()
            }
        }
    }

    func syncSelectedDevices(_ devices: [LocalNetworkDevice]) {
        queue.async { [weak self] in
            self?.syncSelectedDevicesInternal(devices)
        }
    }

    func recordSpeed(
        macAddress: String,
        value: Double,
        pingLatency: Double? = nil,
        signalStrength: Int? = nil,
        unit: LinkSpeedUnit = .mbitPerSecond,
        timestamp: Date = Date()
    ) {
        queue.async { [weak self] in
            self?.recordSpeedInternal(macAddress: macAddress, value: value, pingLatency: pingLatency, signalStrength: signalStrength, unit: unit, timestamp: timestamp)
        }
    }

    func fetch(macAddress: String, from startDate: Date, to endDate: Date = Date()) async -> [LocalDeviceSpeedSample] {
        await withCheckedContinuation { continuation in
            queue.async { [weak self] in
                guard let self, let db = self.db else {
                    continuation.resume(returning: [])
                    return
                }
                let key = normalizeMAC(macAddress)
                let sql = """
                SELECT timestamp, speed_mbps, ping_latency, signal_strength
                FROM speed_samples
                WHERE mac = ? AND timestamp >= ? AND timestamp <= ?
                ORDER BY timestamp;
                """
                var stmt: OpaquePointer?
                var rows: [LocalDeviceSpeedSample] = []
                if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                    sqlite3_bind_text(stmt, 1, key, -1, Self.sqliteTransient)
                    sqlite3_bind_double(stmt, 2, startDate.timeIntervalSince1970)
                    sqlite3_bind_double(stmt, 3, endDate.timeIntervalSince1970)
                    while sqlite3_step(stmt) == SQLITE_ROW {
                        let timestamp = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
                        let speed = sqlite3_column_double(stmt, 1)
                        let pingLatency = sqlite3_column_type(stmt, 2) == SQLITE_NULL ? nil : sqlite3_column_double(stmt, 2)
                        let signalStrength = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : Int(sqlite3_column_int(stmt, 3))
                        
                        rows.append(LocalDeviceSpeedSample(
                            timestamp: timestamp, 
                            speedMbps: speed,
                            pingLatency: pingLatency,
                            signalStrength: signalStrength
                        ))
                    }
                }
                sqlite3_finalize(stmt)
                continuation.resume(returning: rows)
            }
        }
    }

    private func createTables() {
        exec(
            """
            CREATE TABLE IF NOT EXISTS selected_devices (
                mac TEXT PRIMARY KEY,
                device_id TEXT NOT NULL,
                display_name TEXT,
                updated_at REAL NOT NULL
            );
            """
        )
        exec(
            """
            CREATE TABLE IF NOT EXISTS speed_samples (
                timestamp REAL NOT NULL,
                mac TEXT NOT NULL,
                speed_mbps REAL NOT NULL,
                ping_latency REAL,
                signal_strength INTEGER
            );
            """
        )
        migrateSchema()
    }

    private func migrateSchema() {
        guard let db else { return }
        var stmt: OpaquePointer?
        
        if sqlite3_prepare_v2(db, "SELECT ping_latency FROM speed_samples LIMIT 1;", -1, &stmt, nil) != SQLITE_OK {
            _ = exec("ALTER TABLE speed_samples ADD COLUMN ping_latency REAL;")
        }
        sqlite3_finalize(stmt)

        if sqlite3_prepare_v2(db, "SELECT signal_strength FROM speed_samples LIMIT 1;", -1, &stmt, nil) != SQLITE_OK {
            _ = exec("ALTER TABLE speed_samples ADD COLUMN signal_strength INTEGER;")
        }
        sqlite3_finalize(stmt)
    }

    private func createIndexes() {
        exec("CREATE INDEX IF NOT EXISTS idx_speed_samples_mac_time ON speed_samples(mac, timestamp);")
        exec("CREATE INDEX IF NOT EXISTS idx_selected_devices_updated_at ON selected_devices(updated_at);")
    }

    private func prepareStatements() {
        guard let db else { return }
        let sql = "INSERT INTO speed_samples (timestamp, mac, speed_mbps, ping_latency, signal_strength) VALUES (?, ?, ?, ?, ?);"
        sqlite3_prepare_v2(db, sql, -1, &insertStmt, nil)
    }

    private func syncSelectedDevicesInternal(_ devices: [LocalNetworkDevice]) {
        guard db != nil else { return }
        let selected = Set(devices.map { normalizeMAC($0.macAddress) })
        guard exec("BEGIN TRANSACTION;") else { return }

        if selected.isEmpty {
            _ = exec("DELETE FROM selected_devices;")
            _ = exec("DELETE FROM speed_samples;")
            _ = exec("COMMIT;")
            cachedSelectedMACs = []
            return
        }

        let inClause = selected.map { "'\($0)'" }.joined(separator: ",")
        _ = exec("DELETE FROM selected_devices WHERE mac NOT IN (\(inClause));")
        _ = exec("DELETE FROM speed_samples WHERE mac NOT IN (\(inClause));")

        let sql = """
        INSERT INTO selected_devices (mac, device_id, display_name, updated_at)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(mac) DO UPDATE SET
            device_id = excluded.device_id,
            display_name = excluded.display_name,
            updated_at = excluded.updated_at;
        """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            let now = Date().timeIntervalSince1970
            for device in devices {
                let mac = normalizeMAC(device.macAddress)
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, mac, -1, Self.sqliteTransient)
                sqlite3_bind_text(stmt, 2, device.id.uuidString, -1, Self.sqliteTransient)
                sqlite3_bind_text(stmt, 3, device.displayName, -1, Self.sqliteTransient)
                sqlite3_bind_double(stmt, 4, now)
                _ = sqlite3_step(stmt)
            }
        }
        sqlite3_finalize(stmt)

        if exec("COMMIT;") {
            cachedSelectedMACs = selected
        } else {
            _ = exec("ROLLBACK;")
        }
    }

    private func recordSpeedInternal(macAddress: String, value: Double, pingLatency: Double?, signalStrength: Int?, unit: LinkSpeedUnit, timestamp: Date) {
        guard let stmt = insertStmt, db != nil else { return }
        let mac = normalizeMAC(macAddress)
        guard cachedSelectedMACs.contains(mac) else { return }

        let speedMbps = convertToMbps(value: value, unit: unit)
        guard speedMbps.isFinite, speedMbps >= 0 else { return }

        sqlite3_reset(stmt)
        sqlite3_clear_bindings(stmt)
        sqlite3_bind_double(stmt, 1, timestamp.timeIntervalSince1970)
        sqlite3_bind_text(stmt, 2, mac, -1, Self.sqliteTransient)
        sqlite3_bind_double(stmt, 3, speedMbps)
        
        if let pingLatency {
            sqlite3_bind_double(stmt, 4, pingLatency)
        } else {
            sqlite3_bind_null(stmt, 4)
        }
        
        if let signalStrength {
            sqlite3_bind_int(stmt, 5, Int32(signalStrength))
        } else {
            sqlite3_bind_null(stmt, 5)
        }

        let rc = sqlite3_step(stmt)
        if rc != SQLITE_DONE {
            Self.logger.error("Local speed insert failed: \(rc)")
            return
        }

        insertCount += 1
        if insertCount >= Config.storageTrimInterval {
            insertCount = 0
            trimOldSamples()
        }
    }

    private func trimOldSamples() {
        let cutoff = Date().addingTimeInterval(-Config.retentionPeriod).timeIntervalSince1970
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM speed_samples WHERE timestamp < ?;", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, cutoff)
            _ = sqlite3_step(stmt)
        }
        sqlite3_finalize(stmt)
    }

    private func loadSelectedMACs() -> Set<String> {
        guard let db else { return [] }
        let sql = "SELECT mac FROM selected_devices;"
        var stmt: OpaquePointer?
        var result: Set<String> = []
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let cString = sqlite3_column_text(stmt, 0) {
                    result.insert(String(cString: cString))
                }
            }
        }
        sqlite3_finalize(stmt)
        return result
    }

    private func convertToMbps(value: Double, unit: LinkSpeedUnit) -> Double {
        switch unit {
        case .kbitPerSecond:
            return value / 1000.0
        case .mbitPerSecond:
            return value
        case .gbitPerSecond:
            return value * 1000.0
        }
    }

    private func normalizeMAC(_ input: String) -> String {
        input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: ":")
    }

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var errorMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errorMsg)
        if rc != SQLITE_OK {
            let message = errorMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMsg)
            Self.logger.error("SQLite exec failed: \(message, privacy: .public)")
            return false
        }
        return true
    }
}
