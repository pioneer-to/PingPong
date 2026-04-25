//
//  LatencyStats.swift
//  PingPongBar
//
//  Shared latency statistics computation and downsampling logic.
//  Used by both TargetDetailView and CustomTargetDetailView.
//

import Foundation

/// Computed statistics from a set of latency samples.
struct LatencyStatsResult {
    let avg: Double
    let min: Double
    let max: Double
    let loss: Double
    let jitter: Double
}

enum LatencyStats {
    /// Compute stats from raw samples.
    static func compute(from samples: [LatencySample]) -> LatencyStatsResult {
        let latencies = samples.compactMap(\.latency)
        let avg = latencies.isEmpty ? 0 : latencies.reduce(0, +) / Double(latencies.count)
        let minV = latencies.min() ?? 0
        let maxV = latencies.max() ?? 0
        let loss = samples.isEmpty ? 0 : Double(samples.count - latencies.count) / Double(samples.count) * 100

        let jitterV = jitter(from: latencies)

        return LatencyStatsResult(avg: avg, min: minV, max: maxV, loss: loss, jitter: jitterV)
    }

    /// Compute jitter (stddev of consecutive latency deltas) from an array of latency values.
    /// Shared between MetricsEngine (in-memory window) and chart stats (SQLite range).
    static func jitter(from latencies: [Double]) -> Double {
        guard latencies.count >= 2 else { return 0 }
        var deltas: [Double] = []
        for i in 1..<latencies.count {
            deltas.append(abs(latencies[i] - latencies[i - 1]))
        }
        guard !deltas.isEmpty else { return 0 }
        let mean = deltas.reduce(0, +) / Double(deltas.count)
        let variance = deltas.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(deltas.count)
        return sqrt(variance)
    }

    /// Downsample by averaging buckets. Preserves packet loss and VPN state.
    static func downsample(_ data: [LatencySample], to targetCount: Int) -> [LatencySample] {
        guard data.count > targetCount, targetCount > 0 else { return data }
        let bucketSize = max(1, data.count / targetCount)
        var result: [LatencySample] = []

        var i = 0
        while i < data.count {
            let end = min(i + bucketSize, data.count)
            let bucket = data[i..<end]

            let latencies = bucket.compactMap(\.latency)
            let lossRatio = Double(bucket.count - latencies.count) / Double(bucket.count)
            let midpoint = bucket[bucket.startIndex + bucket.count / 2]

            let avgLatency: Double? = lossRatio > 0.5 ? nil :
                (latencies.isEmpty ? nil : latencies.reduce(0, +) / Double(latencies.count))

            let vpnRatio = Double(bucket.filter(\.vpnActive).count) / Double(bucket.count)

            result.append(LatencySample(
                target: midpoint.target,
                timestamp: midpoint.timestamp,
                latency: avgLatency,
                vpnActive: vpnRatio > 0.5
            ))
            i = end
        }
        return result
    }
}
