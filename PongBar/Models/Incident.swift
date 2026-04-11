//
//  Incident.swift
//  PongBar
//
//  Incident model for tracking network outages with smart classification.
//

import Foundation

/// Classification of an incident based on which targets are affected.
enum IncidentCategory: String, Codable {
    case localNetwork    // Router unreachable — local network problem
    case ispUpstream     // Router OK but internet down — ISP issue
    case dnsOnly         // Internet OK but DNS failing
    case fullOutage      // Everything down

    var label: String {
        switch self {
        case .localNetwork: return "Local Network"
        case .ispUpstream: return "ISP / Upstream"
        case .dnsOnly: return "DNS Only"
        case .fullOutage: return "Full Outage"
        }
    }

}

/// Represents a network incident (period of unreachability for a target).
struct Incident: Identifiable, Codable {
    let id: UUID
    let target: PingTarget
    let startTime: Date
    var endTime: Date?
    var category: IncidentCategory?
    /// True if the incident was auto-closed because the app was not running — real end time unknown.
    var isStale: Bool = false

    /// Whether the incident has been resolved (target is reachable again).
    var isResolved: Bool { endTime != nil }

    /// Duration of the incident.
    var duration: TimeInterval {
        let end = endTime ?? Date()
        return end.timeIntervalSince(startTime)
    }

    /// Human-readable duration string.
    var durationString: String {
        Formatters.duration(duration)
    }

    /// Short description of the incident.
    var summary: String {
        if let category {
            return category.label
        }
        switch target {
        case .internet: return "Internet lost"
        case .router: return "Router unreachable"
        case .dns: return "DNS timeout"
        case .vpn: return "VPN server unreachable"
        }
    }

    init(id: UUID = UUID(), target: PingTarget, startTime: Date = Date(), category: IncidentCategory? = nil) {
        self.id = id
        self.target = target
        self.startTime = startTime
        self.category = category
    }
}
