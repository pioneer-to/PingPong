//
//  IncidentManager.swift
//  PingPongBar
//
//  Manages incident lifecycle: creation, resolution, persistence (SQLite), and classification.
//  Extracted from NetworkMonitor for testability and separation of concerns.
//

import Foundation

/// Manages network incident tracking with SQLite persistence.
@MainActor
@Observable
final class IncidentManager {
    /// Active (unresolved) incidents keyed by target.
    var activeIncidents: [PingTarget: Incident] = [:]

    /// All recorded incidents, newest first.
    var incidents: [Incident] = []

    /// Consecutive failure count per target (for grace period).
    var consecutiveFailures: [PingTarget: Int] = [:]

    // MARK: - Lifecycle

    func load() async {
        let saved = await SQLiteStorage.shared.loadIncidents()
        let legacyIncidents = migrateLegacyUserDefaultsIncidents(existingIDs: Set(saved.map(\.id)))
        let staleThreshold = Date().addingTimeInterval(-Config.retentionPeriod)

        var loaded = (saved + legacyIncidents)
            .sorted { $0.startTime > $1.startTime }
        if loaded.count > Config.maxIncidents {
            loaded = Array(loaded.prefix(Config.maxIncidents))
        }
        if !legacyIncidents.isEmpty {
            SQLiteStorage.shared.saveIncidentsBatch(loaded)
        }

        for i in 0..<loaded.count {
            if !loaded[i].isResolved {
                if loaded[i].startTime < staleThreshold {
                    loaded[i].endTime = loaded[i].startTime
                    loaded[i].isStale = true
                    SQLiteStorage.shared.saveIncident(loaded[i])
                } else {
                    activeIncidents[loaded[i].target] = loaded[i]
                }
            }
        }
        incidents = loaded
    }

    private func migrateLegacyUserDefaultsIncidents(existingIDs: Set<UUID>) -> [Incident] {
        let keys = ["PingPongBar.incidents", "PongBar.incidents"]
        var migrated: [Incident] = []
        var seenIDs = existingIDs

        for key in keys {
            defer { UserDefaults.standard.removeObject(forKey: key) }
            guard let data = UserDefaults.standard.data(forKey: key),
                  let decoded = try? JSONDecoder().decode([Incident].self, from: data) else {
                continue
            }
            for incident in decoded where !seenIDs.contains(incident.id) {
                migrated.append(incident)
                seenIDs.insert(incident.id)
            }
        }

        return migrated
    }

    // MARK: - Incident Tracking

    /// Check and manage incidents for a target result. Call after all metrics are updated.
    func checkIncident(_ result: PingResult, currentResults: [PingTarget: PingResult]) {
        let target = result.target

        if !result.isReachable {
            consecutiveFailures[target, default: 0] += 1

            // Only trigger NEW incidents for the primary 'internet' target.
            // Other targets (router, dns) are used for classification but don't
            // need their own separate incident records if they fail as part of a larger outage.
            if target == .internet && activeIncidents[target] == nil &&
               consecutiveFailures[target, default: 0] >= Config.networkSwitchGracePings {
                let category = classify(currentResults: currentResults)
                let incident = Incident(target: target, category: category)
                activeIncidents[target] = incident
                incidents.insert(incident, at: 0)
                SQLiteStorage.shared.saveIncident(incident)
                NotificationService.notifyDown(target: target)
            }
        } else {
            consecutiveFailures[target] = 0

            if var incident = activeIncidents[target] {
                incident.endTime = Date()
                let downtime = incident.duration
                activeIncidents[target] = nil
                if let index = incidents.firstIndex(where: { $0.id == incident.id }) {
                    incidents[index] = incident
                }
                SQLiteStorage.shared.saveIncident(incident)
                NotificationService.notifyRecovery(target: target, downtime: downtime)
            }
        }

        if incidents.count > Config.maxIncidents {
            let removed = incidents.removeLast()
            SQLiteStorage.shared.deleteIncident(id: removed.id)
        }
    }

    /// Reset failure counters (e.g. on network change).
    func resetFailureCounters() {
        consecutiveFailures.removeAll()
    }

    /// Save all current incidents (periodic + quit).
    func saveAll() {
        SQLiteStorage.shared.saveIncidentsBatch(incidents)
    }

    /// Clear all incident history.
    func clearHistory() {
        incidents.removeAll()
        activeIncidents.removeAll()
        SQLiteStorage.shared.clearIncidents()
    }

    // MARK: - Classification

    private func classify(currentResults: [PingTarget: PingResult]) -> IncidentCategory {
        let routerUp = currentResults[.router]?.isReachable ?? false
        let internetUp = currentResults[.internet]?.isReachable ?? false
        let dnsUp = currentResults[.dns]?.isReachable ?? false

        if !routerUp && !internetUp && !dnsUp { return .fullOutage }
        if !routerUp { return .localNetwork }
        if routerUp && !internetUp { return .ispUpstream }
        if internetUp && !dnsUp { return .dnsOnly }
        // Reached when all built-in targets are up — the failing target is VPN or
        // a transient failure on a single target while others recovered.
        return .dnsOnly
    }

    // MARK: - Computed

    var uptimeToday: Double {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: Date())
        let now = Date()
        let totalSeconds = now.timeIntervalSince(startOfDay)
        guard totalSeconds > 0 else { return 100.0 }

        var intervals: [(start: Date, end: Date)] = []
        for incident in incidents {
            let end = incident.endTime ?? now
            guard end > startOfDay else { continue }
            let start = max(incident.startTime, startOfDay)
            let clippedEnd = min(end, now)
            guard clippedEnd > start else { continue }
            intervals.append((start, clippedEnd))
        }

        intervals.sort { $0.start < $1.start }
        var merged: [(start: Date, end: Date)] = []
        for interval in intervals {
            if var last = merged.last, interval.start <= last.end {
                last.end = max(last.end, interval.end)
                merged[merged.count - 1] = last
            } else {
                merged.append(interval)
            }
        }

        let downtimeSeconds = merged.reduce(0.0) { $0 + $1.end.timeIntervalSince($1.start) }
        return min(100, max(0, (1.0 - downtimeSeconds / totalSeconds)) * 100)
    }

    var todayIncidentCount: Int {
        let startOfDay = Calendar.current.startOfDay(for: Date())
        return incidents.filter { $0.startTime >= startOfDay }.count
    }
}
