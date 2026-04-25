//
//  MetricsEngine.swift
//  PingPongBar
//
//  Computes latency history, jitter, packet loss, and persists samples to SQLite.
//  Extracted from NetworkMonitor for testability.
//

import Foundation

/// Tracks per-target metrics: latency history, jitter, rolling packet loss.
@MainActor
@Observable
final class MetricsEngine {
    /// Recent latency history for sparkline (last N samples per target).
    var latencyHistory: [PingTarget: [Double?]] = [
        .internet: [], .router: [], .dns: [], .vpn: []
    ]

    /// Rolling packet loss percentage per target.
    var packetLoss: [PingTarget: Double] = [:]

    /// Jitter per target in ms.
    var jitter: [PingTarget: Double] = [:]

    /// Rolling reachability history for loss%.
    private var reachabilityHistory: [PingTarget: [Bool]] = [
        .internet: [], .router: [], .dns: [], .vpn: []
    ]

    /// Previous spike state for detection.
    private var previousLoss: [PingTarget: Double] = [:]

    /// Spike alerts — set when loss jumps significantly.
    var lossSpike: [PingTarget: Bool] = [:]

    // MARK: - Update

    /// Update metrics for a ping result. Call once per target per tick.
    func update(result: PingResult, vpnActive: Bool) {
        let target = result.target

        // Latency history
        var history = latencyHistory[target] ?? []
        history.append(result.latency)
        if history.count > Config.maxHistorySamples {
            history.removeFirst(history.count - Config.maxHistorySamples)
        }
        latencyHistory[target] = history

        // Reachability for loss%
        var reachHistory = reachabilityHistory[target] ?? []
        reachHistory.append(result.isReachable)
        if reachHistory.count > Config.lossWindow {
            reachHistory.removeFirst(reachHistory.count - Config.lossWindow)
        }
        reachabilityHistory[target] = reachHistory

        if !reachHistory.isEmpty {
            let failures = reachHistory.filter { !$0 }.count
            let newLoss = Double(failures) / Double(reachHistory.count) * 100

            // Spike detection: loss jumped by >20% in one tick
            let prev = previousLoss[target] ?? 0
            lossSpike[target] = (newLoss - prev) > Config.lossSpikeThreshold

            previousLoss[target] = newLoss
            packetLoss[target] = newLoss
        }

        // Jitter — uses shared LatencyStats.jitter() for consistency with chart stats
        let latencies = history.compactMap { $0 }
        let recent = Array(latencies.suffix(Config.jitterWindow))
        jitter[target] = LatencyStats.jitter(from: recent)

        // Persist sample
        SQLiteStorage.shared.record(LatencySample(
            target: target, timestamp: result.timestamp, latency: result.latency, vpnActive: vpnActive
        ))
    }
}
