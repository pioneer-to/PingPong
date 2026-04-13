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

extension Double {
    var localSpeedQualityColor: Color {
        if self < Config.speedQualityLowThreshold { return .red }
        if self < Config.speedQualityMediumThreshold { return .orange }
        if self < Config.speedQualityHighThreshold { return .yellow }
        return .green
    }
}

extension Int {
    var signalQualityColor: Color {
        let lowThreshold = Swift.max(0, Swift.min(100, Int((Config.speedQualityLowThreshold / 10.0).rounded())))
        let mediumThreshold = Swift.max(0, Swift.min(100, Int((Config.speedQualityMediumThreshold / 10.0).rounded())))
        let highThreshold = Swift.max(0, Swift.min(100, Int((Config.speedQualityHighThreshold / 10.0).rounded())))

        if self < lowThreshold { return .red }
        if self < mediumThreshold { return .orange }
        if self < highThreshold { return .yellow }
        return .green
    }
}
