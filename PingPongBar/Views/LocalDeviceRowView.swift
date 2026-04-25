//
//  LocalDeviceRowView.swift
//  PingPongBar
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
    var isInitialDataPending: Bool = false
    
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

            if isCurrentDevice {
                Text("")
                    .frame(width: 48, alignment: .trailing)
            } else if shouldShowPingSpinner {
                loadingSpinner
                    .frame(width: 48, alignment: .trailing)
            } else if device.usePing {
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

            Group {
                if shouldShowSignalSpinner {
                    loadingSpinner
                } else {
                    Text(signalText)
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(signalColor)
                }
            }
            .frame(width: 56, alignment: .trailing)

            Group {
                if shouldShowSpeedSpinner {
                    loadingSpinner
                } else {
                    Text(Formatters.localDeviceSpeedPlain(speedMbps))
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(speedColor)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: speedMbps)
                }
            }
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
            return Color.green.opacity(isHovered ? 0.16 : 0.10)
        }
        return isHovered ? Color.primary.opacity(0.05) : Color.clear
    }

    private var loadingSpinner: some View {
        ProgressView()
            .controlSize(.small)
            .scaleEffect(0.55)
    }

    private var shouldShowPingSpinner: Bool {
        isInitialDataPending && device.usePing && result == nil
    }

    private var shouldShowSignalSpinner: Bool {
        isInitialDataPending && signalStrengthPercent == nil
    }

    private var shouldShowSpeedSpinner: Bool {
        isInitialDataPending && speedMbps == nil
    }

    private var statusColor: Color {
        if isCurrentDevice { return .green }
        if speedMbps != nil || signalStrengthPercent != nil { return .green }
        guard let result else { return .secondary }
        return result.isReachable ? .green : .red
    }

    private var speedColor: Color {
        guard let speedMbps else { return .secondary }
        return speedMbps.localSpeedQualityColor
    }

    private var pingText: String {
        guard let result = result else { return "---" }
        guard let latency = result.latency else { return "---" }
        if latency < 1 { return "<1" }
        return String(format: "%.0f", latency)
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
