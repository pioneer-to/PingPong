//
//  PingTarget.swift
//  PongBar
//
//  Network monitoring target definitions and result types.
//

import Foundation

/// Represents the three network monitoring targets.
enum PingTarget: String, Codable, Identifiable {
    case internet
    case router
    case dns
    case vpn

    var id: String { rawValue }

    /// Built-in monitoring targets (excludes vpn which is dynamic).
    static let builtInCases: [PingTarget] = [.internet, .router, .dns]

    var displayName: String {
        switch self {
        case .internet: return "Internet"
        case .router: return "Router"
        case .dns: return "DNS Resolve"
        case .vpn: return "VPN Server"
        }
    }

}

/// Result of a single ping/check operation.
struct PingResult: Identifiable {
    let id = UUID()
    let target: PingTarget
    let timestamp: Date
    let isReachable: Bool
    /// Latency in milliseconds; nil if unreachable.
    let latency: Double?
    /// Additional info such as the resolved IP or gateway address.
    let detail: String?

    /// Formatted latency string for display.
    var latencyString: String {
        guard let ms = latency else { return "---" }
        if ms < 1 {
            return "<1 ms"
        }
        return String(format: "%.0f ms", ms)
    }
}
