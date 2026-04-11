//
//  ThroughputEngine.swift
//  PongBar
//
//  Computes per-interface throughput (bytes/sec) by sampling OS counters
//  and calculating deltas. Handles 32-bit counter overflow.
//

import Foundation

/// Computed throughput reading for one interface.
struct ThroughputReading {
    let interfaceName: String
    let downloadBytesPerSec: Double
    let uploadBytesPerSec: Double
    let timestamp: Date
}

/// Tracks per-interface throughput by sampling counters each tick.
@MainActor
@Observable
final class ThroughputEngine {
    /// Current throughput readings keyed by interface name.
    var currentReadings: [String: ThroughputReading] = [:]

    /// Previous counter snapshots for delta computation.
    private var previousCounters: [String: InterfaceCounters] = [:]

    // MARK: - Update

    /// Sample counters and compute throughput from pre-captured snapshot.
    func update(from snapshot: InterfaceSnapshot) {
        let current = ThroughputService.readCounters(from: snapshot)
        var newReadings: [String: ThroughputReading] = [:]

        for (name, counters) in current {
            if let prev = previousCounters[name] {
                let elapsed = counters.timestamp.timeIntervalSince(prev.timestamp)
                // Skip if elapsed too short (prevents division by near-zero)
                guard elapsed >= 0.5 else { continue }

                // macOS if_data.ifi_ibytes is UInt32. Counters stored as UInt64 for future-proofing.
                // Overflow handling uses UInt32 range since that's the actual counter width.
                let rxDelta = Self.computeDelta(current: counters.bytesIn, previous: prev.bytesIn)
                let txDelta = Self.computeDelta(current: counters.bytesOut, previous: prev.bytesOut)

                // Sanity check: discard if > 100 Gbps (likely counter corruption)
                let maxBytesPerSec: Double = 12_500_000_000 // 100 Gbps
                let rxPerSec = Double(rxDelta) / elapsed
                let txPerSec = Double(txDelta) / elapsed

                if rxPerSec <= maxBytesPerSec && txPerSec <= maxBytesPerSec {
                    newReadings[name] = ThroughputReading(
                        interfaceName: name,
                        downloadBytesPerSec: rxPerSec,
                        uploadBytesPerSec: txPerSec,
                        timestamp: counters.timestamp
                    )
                }
            }
            // Store current as previous for next tick
            // (first sample for new interface: no reading, just baseline)
        }

        previousCounters = current
        currentReadings = newReadings
    }

    /// Reset all state. Call after wake from sleep or interface change to avoid stale deltas.
    func reset() {
        previousCounters.removeAll()
        currentReadings.removeAll()
    }

    // MARK: - Overflow Handling

    /// Compute delta between two counter values, handling UInt32 overflow.
    /// macOS ifi_ibytes is UInt32 (wraps at 4GB). If counters become 64-bit in future,
    /// simple subtraction will work correctly without overflow handling.
    private static func computeDelta(current: UInt64, previous: UInt64) -> UInt64 {
        if current >= previous {
            return current - previous
        } else {
            // UInt32 counter wrapped past 4GB
            return (UInt64(UInt32.max) - previous) + current + 1
        }
    }
}
