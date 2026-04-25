//
//  MTRService.swift
//  PingPongBar
//
//  Continuous MTR (My Traceroute) — combines traceroute with per-hop pinging.
//  First discovers hops via traceroute, then pings each hop simultaneously
//  on a loop, tracking per-hop latency and loss over time.
//

import Foundation

/// Live statistics for a single hop in the MTR session.
struct MTRHopStats: Identifiable {
    let hopNumber: Int
    let host: String
    let ip: String
    var id: Int { hopNumber }

    var sent: Int = 0
    var received: Int = 0
    var lastLatency: Double?
    var bestLatency: Double = .infinity
    var worstLatency: Double = 0
    var totalLatency: Double = 0
    var latencyHistory: [Double?] = []

    var lossPercent: Double {
        guard sent > 0 else { return 0 }
        return Double(sent - received) / Double(sent) * 100
    }

    var avgLatency: Double {
        guard received > 0 else { return 0 }
        return totalLatency / Double(received)
    }

    mutating func recordPing(_ latency: Double?) {
        sent += 1
        latencyHistory.append(latency)
        if latencyHistory.count > 30 { latencyHistory.removeFirst() }

        if let ms = latency {
            received += 1
            lastLatency = ms
            totalLatency += ms
            bestLatency = min(bestLatency, ms)
            worstLatency = max(worstLatency, ms)
        } else {
            lastLatency = nil
        }
    }
}

/// Manages a continuous MTR session to a target host.
@MainActor
@Observable
final class MTRSession {
    var hops: [MTRHopStats] = []
    var isRunning = false
    var roundCount = 0
    let target: String

    private var task: Task<Void, Never>?

    init(target: String) {
        self.target = target
    }

    nonisolated deinit {
        // Task cancellation is cooperative — cleanup handled by onDisappear calling stop()
    }

    /// Start the MTR session: discover hops, then ping them continuously.
    func start() {
        guard !isRunning else { return }
        isRunning = true
        roundCount = 0

        task = Task { @MainActor in
            // Phase 1: Discover hops via traceroute
            let discovered = await discoverHops()
            if Task.isCancelled { return }

            hops = discovered

            // Phase 2: Continuously ping all hops
            while !Task.isCancelled && isRunning {
                await pingAllHops()
                roundCount += 1
                try? await Task.sleep(for: .seconds(Config.mtrRoundInterval))
            }
        }
    }

    /// Stop the MTR session.
    func stop() {
        isRunning = false
        task?.cancel()
        task = nil
    }

    // MARK: - Hop Discovery

    private func discoverHops() async -> [MTRHopStats] {
        let traceHops = await TracerouteService.trace(to: target)
        return traceHops.map { hop in
            let ip = hop.ip ?? hop.host
            let displayHost = hop.isTimeout ? "* * *" : hop.host
            return MTRHopStats(hopNumber: hop.hopNumber, host: displayHost, ip: ip)
        }
    }

    // MARK: - Continuous Pinging

    @MainActor
    private func pingAllHops() async {
        // Ping all hops concurrently using a task group
        let results = await withTaskGroup(of: (Int, Double?).self, returning: [(Int, Double?)].self) { group in
            for (index, hop) in hops.enumerated() {
                let ip = hop.ip
                // Skip timeout hops that have no known IP
                guard ip != "* * *" else { continue }

                group.addTask {
                    let latency = await PingService.ping(ip, timeout: Config.mtrHopTimeout)
                    return (index, latency)
                }
            }

            var results: [(Int, Double?)] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        // Apply results
        for (index, latency) in results {
            guard index < hops.count else { continue }
            hops[index].recordPing(latency)
        }

        // Also record timeout for hops we didn't ping
        for i in 0..<hops.count {
            if hops[i].ip == "* * *" {
                hops[i].recordPing(nil)
            }
        }
    }
}
