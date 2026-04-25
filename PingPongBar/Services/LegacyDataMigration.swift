//
//  LegacyDataMigration.swift
//  PingPongBar
//
//  Restores data from the pre-rename PongBar app identity.
//

import Foundation
import SQLite3

enum LegacyDataMigration {
    private static let markerKey = "legacyPongBarDataMigrationCompleted"
    private static let legacyBundleIDs = ["k.PongBar"]
    private static let legacySupportDirectoryName = "PongBar"
    private static let currentSupportDirectoryName = "PingPongBar"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: markerKey) == nil else { return }

        migrateUserDefaults(into: defaults)
        migrateApplicationSupportFiles()

        defaults.set(true, forKey: markerKey)
        defaults.synchronize()
    }

    private static func migrateUserDefaults(into defaults: UserDefaults) {
        for bundleID in legacyBundleIDs {
            guard let legacyDomain = UserDefaults.standard.persistentDomain(forName: bundleID) else {
                continue
            }

            for (key, value) in legacyDomain {
                guard shouldCopyPreference(key: key), defaults.object(forKey: key) == nil else {
                    continue
                }
                defaults.set(value, forKey: key)
            }

            copyMappedPreference(
                from: "PongBar.customTargets",
                to: "PingPongBar.customTargets",
                legacyDomain: legacyDomain,
                defaults: defaults
            )

            copyMappedPreference(
                from: "PongBar.incidents",
                to: "PingPongBar.incidents",
                legacyDomain: legacyDomain,
                defaults: defaults
            )
        }
    }

    private static func shouldCopyPreference(key: String) -> Bool {
        !key.hasPrefix("NS")
            && key != "ApplePersistenceIgnoreState"
            && key != "PongBar.customTargets"
            && key != "PongBar.incidents"
    }

    private static func copyMappedPreference(
        from legacyKey: String,
        to currentKey: String,
        legacyDomain: [String: Any],
        defaults: UserDefaults
    ) {
        guard defaults.object(forKey: currentKey) == nil, let value = legacyDomain[legacyKey] else {
            return
        }
        defaults.set(value, forKey: currentKey)
    }

    private static func migrateApplicationSupportFiles() {
        guard let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let legacyDirectory = appSupport.appendingPathComponent(legacySupportDirectoryName, isDirectory: true)
        let currentDirectory = appSupport.appendingPathComponent(currentSupportDirectoryName, isDirectory: true)

        guard FileManager.default.fileExists(atPath: legacyDirectory.path) else { return }
        try? FileManager.default.createDirectory(at: currentDirectory, withIntermediateDirectories: true)

        migrateSQLiteFile(named: "samples.sqlite", from: legacyDirectory, to: currentDirectory)
        migrateSQLiteFile(named: "localdevices.sqlite", from: legacyDirectory, to: currentDirectory)
    }

    private static func migrateSQLiteFile(named fileName: String, from legacyDirectory: URL, to currentDirectory: URL) {
        let source = legacyDirectory.appendingPathComponent(fileName)
        let destination = currentDirectory.appendingPathComponent(fileName)

        guard FileManager.default.fileExists(atPath: source.path) else { return }
        guard shouldReplaceDatabase(at: destination) else { return }

        try? FileManager.default.removeItem(at: destination)
        try? FileManager.default.removeItem(at: currentDirectory.appendingPathComponent("\(fileName)-wal"))
        try? FileManager.default.removeItem(at: currentDirectory.appendingPathComponent("\(fileName)-shm"))

        do {
            try FileManager.default.copyItem(at: source, to: destination)
            copySidecar(named: "\(fileName)-wal", from: legacyDirectory, to: currentDirectory)
            copySidecar(named: "\(fileName)-shm", from: legacyDirectory, to: currentDirectory)
        } catch {
            // Keep startup non-fatal; the app can still run with a fresh store.
        }
    }

    private static func copySidecar(named fileName: String, from legacyDirectory: URL, to currentDirectory: URL) {
        let source = legacyDirectory.appendingPathComponent(fileName)
        let destination = currentDirectory.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.copyItem(at: source, to: destination)
    }

    private static func shouldReplaceDatabase(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return true }

        if url.lastPathComponent == "samples.sqlite" {
            return sqliteRowCount(in: url, table: "samples") == 0
                && sqliteRowCount(in: url, table: "incidents") == 0
        }

        if url.lastPathComponent == "localdevices.sqlite" {
            return sqliteRowCount(in: url, table: "speed_samples") == 0
                && sqliteRowCount(in: url, table: "selected_devices") == 0
        }

        return false
    }

    private static func sqliteRowCount(in url: URL, table: String) -> Int {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else {
            return 0
        }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM \(table);", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }
}
