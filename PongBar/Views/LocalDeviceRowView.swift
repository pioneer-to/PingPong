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
    let speedMbps: Double?
    let signalStrengthPercent: Int?
    let band: String?
    var showStatusIndicator: Bool = true
    var showDisclosure: Bool = false
    
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if showStatusIndicator {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)
                } else {
                    Color.clear
                        .frame(width: 8, height: 8)
                }
            }
            .frame(width: 14, alignment: .center)

            Image(systemName: device.symbolName)
                .frame(width: 16, height: 16)
                .foregroundStyle(.primary)
                .frame(width: 20, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.displayName)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(result?.detail ?? device.ipAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let band, !band.isEmpty {
                        Text(band)
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(bandBadgeColor, in: Capsule())
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(signalText)
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(signalColor)
                .frame(width: 56, alignment: .trailing)

            Text(Formatters.localDeviceSpeedPlain(speedMbps))
                .font(.system(.body, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(speedColor)
                .contentTransition(.numericText())
                .animation(.easeInOut(duration: 0.2), value: speedMbps)
                .frame(width: 60, alignment: .trailing)

            if showDisclosure {
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 12, alignment: .trailing)
            }
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

    private var speedColor: Color {
        guard let speedMbps else { return .secondary }
        return speedMbps.localSpeedQualityColor
    }

    private var signalText: String {
        guard let signalStrengthPercent else { return "---" }
        return "\(signalStrengthPercent)%"
    }

    private var signalColor: Color {
        guard let signalStrengthPercent else { return .secondary }
        return signalStrengthPercent.signalQualityColor
    }

    private var bandBadgeColor: Color {
        switch band {
        case "2.4GHz":
            return .teal
        case "5GHz":
            return .blue
        case "6GHz":
            return .indigo
        default:
            return .secondary
        }
    }
}
