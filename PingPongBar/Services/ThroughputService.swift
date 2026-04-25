//
//  ThroughputService.swift
//  PingPongBar
//
//  Reads cumulative byte counters from an InterfaceSnapshot.
//  No longer calls getifaddrs() directly — uses shared snapshot.
//

import Foundation

/// Raw byte counters for a single network interface snapshot.
struct InterfaceCounters {
    let interfaceName: String
    let bytesIn: UInt64
    let bytesOut: UInt64
    let timestamp: Date
}

/// Reads per-interface byte counters from a pre-captured snapshot.
enum ThroughputService {
    /// Extract counters from an already-captured snapshot (no syscall).
    static func readCounters(from snapshot: InterfaceSnapshot) -> [String: InterfaceCounters] {
        snapshot.trafficCounters()
    }
}
