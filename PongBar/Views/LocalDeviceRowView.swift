//
//  LocalDeviceRowView.swift
//  PongBar
//
//  Status row for a monitored local network device. Displays the chosen SF symbol, Name, and latency graph.
//

import SwiftUI

struct LocalDeviceRowView: View {
    let device: LocalNetworkDevice
    let result: PingResult?
    var sparklineData: [Double?] = []
    
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Image(systemName: device.symbolName)
                .frame(width: 16, height: 16)
                .foregroundStyle(.primary)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                Text(device.ipAddress)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if sparklineData.compactMap({ $0 }).count >= 2 {
                SparklineView(values: sparklineData, color: .purple)
            }

            Text(result?.latencyString ?? "---")
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(result?.latencyColor ?? .secondary)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: result?.latency)
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
    }

    private var statusColor: Color {
        guard let result else { return .secondary }
        return result.isReachable ? .green : .red
    }
}
