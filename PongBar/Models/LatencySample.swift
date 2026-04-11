//
//  LatencySample.swift
//  PongBar
//
//  Timestamped latency measurement for persistent chart history.
//

import Foundation

/// A single latency measurement at a point in time.
struct LatencySample: Identifiable {
    let id = UUID()
    let target: PingTarget
    let timestamp: Date
    /// Latency in ms; nil means the target was unreachable.
    let latency: Double?
    /// Whether VPN was active when this sample was taken.
    let vpnActive: Bool
    /// Override storage key for custom targets (e.g. "custom.google.com").
    /// If nil, uses target.rawValue.
    let storageKey: String?
    /// Whether the target was reachable.
    var isReachable: Bool { latency != nil }

    /// The key used for SQLite storage and retrieval.
    var effectiveKey: String { storageKey ?? target.rawValue }

    init(target: PingTarget, timestamp: Date, latency: Double?, vpnActive: Bool = false, storageKey: String? = nil) {
        self.target = target
        self.timestamp = timestamp
        self.latency = latency
        self.vpnActive = vpnActive
        self.storageKey = storageKey
    }
}
