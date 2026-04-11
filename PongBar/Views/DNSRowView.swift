//
//  DNSRowView.swift
//  PongBar
//
//  DNS status row with inline quick-switch menu for changing DNS servers.
//

import SwiftUI

struct DNSRowView: View {
    let result: PingResult?
    let detail: String
    var loss: Double?
    var jitterValue: Double?
    var sparklineData: [Double?] = []
    var onTap: () -> Void

    @State private var isHovered = false
    @State private var currentPreset: DNSPreset = .dhcp
    @State private var dnsTask: Task<Void, Never>?

    private var statusColor: Color {
        guard let result else { return .secondary }
        return result.isReachable ? .green : .red
    }

    var body: some View {
        HStack(spacing: 8) {
            // Clickable area → opens chart detail
            Button {
                onTap()
            } label: {
                HStack(spacing: 8) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 8, height: 8)

                    VStack(alignment: .leading, spacing: 1) {
                        Text("DNS Resolve")
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
            }
            .buttonStyle(.plain)

            // DNS quick-switch — separate from chart tap
            Menu {
                ForEach(DNSPreset.allCases) { preset in
                    Button {
                        dnsTask?.cancel()
                        dnsTask = Task {
                            let ok = await DNSSwitcherService.applyPreset(preset)
                            guard !Task.isCancelled else { return }
                            if ok { currentPreset = preset }
                        }
                    } label: {
                        if currentPreset == preset {
                            Label(presetLabel(preset), systemImage: "checkmark")
                        } else {
                            Text(presetLabel(preset))
                        }
                    }
                }
            } label: {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.purple)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.vertical, 4)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isHovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { hovering in isHovered = hovering }
        .task { currentPreset = await DNSSwitcherService.detectCurrentPreset() }
    }

    private func presetLabel(_ preset: DNSPreset) -> String {
        if let servers = preset.servers {
            return "\(preset.rawValue) (\(servers.first ?? ""))"
        }
        return preset.rawValue
    }
}
