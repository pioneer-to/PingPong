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
    let activeBand: String?
    let supportedBands: [String]
    var showStatusIndicator: Bool = true
    var showDisclosure: Bool = false
    var isCurrentDevice: Bool = false
    var isWANBlocked: Bool = false
    
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
                    .font(isCurrentDevice ? .body.weight(.medium) : .body)
                    .foregroundStyle(.primary)
                HStack(spacing: 6) {
                    Text(result?.detail ?? device.ipAddress)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(orderedBands, id: \.self) { band in
                        Text(bandBadgeText(for: band))
                            .font(.caption2)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(activeBand == band ? .white : bandBadgeColor(for: band))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(
                                Capsule()
                                    .fill(activeBand == band ? bandBadgeColor(for: band) : Color.clear)
                            )
                            .overlay(
                                Capsule()
                                    .stroke(bandBadgeColor(for: band).opacity(activeBand == band ? 0 : 0.6), lineWidth: 1)
                            )
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if device.usePing {
                Text(pingText)
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(pingColor)
                    .frame(width: 48, alignment: .trailing)
            } else {
                Text("off")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(width: 48, alignment: .trailing)
            }

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
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowBackgroundColor)
        )
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var rowBackgroundColor: Color {
        if isWANBlocked {
            return Color.red.opacity(isHovered ? 0.16 : 0.09)
        }
        if isCurrentDevice {
            return Color.accentColor.opacity(isHovered ? 0.13 : 0.08)
        }
        return isHovered ? Color.primary.opacity(0.05) : Color.clear
    }

    private var statusColor: Color {
        guard let result else { return .secondary }
        return result.isReachable ? .green : .red
    }

    private var speedColor: Color {
        guard let speedMbps else { return .secondary }
        return speedMbps.localSpeedQualityColor
    }

    private var pingText: String {
        guard let result = result else { return "---" }
        return result.latencyString
    }

    private var pingColor: Color {
        guard let result = result, result.isReachable else { return .red }
        return result.latencyColor
    }

    private var signalText: String {
        guard let signalStrengthPercent else { return "---" }
        return "\(signalStrengthPercent)%"
    }

    private var signalColor: Color {
        guard let signalStrengthPercent else { return .secondary }
        return signalStrengthPercent.signalQualityColor
    }

    private var orderedBands: [String] {
        let preferredOrder = ["2.4GHz", "5GHz", "6GHz"]
        let normalized = Set(supportedBands.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        return preferredOrder.filter { normalized.contains($0) }
    }

    private func bandBadgeColor(for band: String) -> Color {
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

    private func bandBadgeText(for band: String) -> String {
        switch band {
        case "2.4GHz":
            return "2.4"
        case "5GHz":
            return "5"
        case "6GHz":
            return "6"
        default:
            return band.replacingOccurrences(of: "GHz", with: "")
        }
    }
}
