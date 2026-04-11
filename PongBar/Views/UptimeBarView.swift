//
//  UptimeBarView.swift
//  PongBar
//
//  Compact uptime percentage bar for today's network availability.
//

import SwiftUI

struct UptimeBarView: View {
    let percentage: Double

    var body: some View {
        HStack(spacing: 8) {
            Text("Uptime today")
                .font(.caption)
                .foregroundStyle(.secondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(Color.primary.opacity(0.1))
                        .frame(height: 4)

                    // Filled portion
                    Capsule()
                        .fill(barColor)
                        .frame(width: geometry.size.width * max(0, min(percentage / 100, 1.0)), height: 4)
                        .animation(.easeInOut(duration: 0.3), value: percentage)
                }
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 16)

            Text(String(format: "%.1f%%", percentage))
                .font(.system(.caption, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var barColor: Color {
        if percentage >= Config.uptimeGreenThreshold { return .green }
        if percentage >= Config.uptimeYellowThreshold { return .yellow }
        return .red
    }
}
