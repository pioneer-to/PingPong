//
//  StatusRowView.swift
//  PongBar
//
//  A single target status row showing status dot, name, address, latency, jitter, and loss%.
//  Tapping navigates to the inline chart detail view.
//

import SwiftUI

struct StatusRowView: View {
    let result: PingResult?
    let target: PingTarget
    let detail: String
    var loss: Double?
    var jitterValue: Double?
    var sparklineData: [Double?] = []
    var sparklineColor: Color = .blue
    var onTap: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Status indicator dot
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            // Target name, address, and metrics
            VStack(alignment: .leading, spacing: 1) {
                Text(target.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(detail)
                        .foregroundStyle(.secondary)
                    if let jitterValue, jitterValue >= Config.jitterDisplayThreshold {
                        Text(String(format: "jit %.1fms", jitterValue))
                            .foregroundStyle(jitterValue > Config.jitterWarningThreshold ? .yellow : .secondary)
                    }
                    if let loss, loss > 0 {
                        Text(String(format: "%.0f%% loss", loss))
                            .foregroundStyle(.red.opacity(0.8))
                    }
                }
                .font(.caption)
            }

            Spacer()

            // Sparkline
            if sparklineData.compactMap({ $0 }).count >= 2 {
                SparklineView(values: sparklineData, color: sparklineColor)
            }

            // Latency value
            Text(result?.latencyString ?? "---")
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(result?.latencyColor ?? .secondary)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: result?.latency)

            // Chevron hint
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.quaternary)
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            onTap()
        }
    }

    private var statusColor: Color {
        guard let result else { return .secondary }
        return result.isReachable ? .green : .red
    }
}
