//
//  ModelColors.swift
//  PongBar
//
//  View-layer color extensions for domain models.
//  Keeps SwiftUI out of the model layer.
//

import SwiftUI

extension PingResult {
    /// Color representing the latency quality.
    var latencyColor: Color {
        guard let ms = latency else { return .red }
        if ms <= Config.latencyGoodThreshold { return .primary }
        if ms <= Config.latencyFairThreshold { return .yellow }
        return .red
    }
}

extension IncidentCategory {
    var color: Color {
        switch self {
        case .localNetwork: return .orange
        case .ispUpstream: return .red
        case .dnsOnly: return .yellow
        case .fullOutage: return .red
        }
    }
}
