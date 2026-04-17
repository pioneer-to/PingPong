//
//  CustomTargetRowView.swift
//  PongBar
//
//  Status row for user-defined custom ping targets. Clickable → chart detail.
//

import SwiftUI

struct CustomTargetRowView: View {
    let target: CustomTarget
    let result: PingResult?
    var sparklineData: [Double?] = []
    var onTap: () -> Void = {}

    @State private var isHovered = false

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    Text(target.name)
                        .font(.body)
                        .foregroundStyle(.primary)
                    Text(target.host)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if sparklineData.compactMap({ $0 }).count >= 2 {
                    SparklineView(values: sparklineData, color: .orange)
                }

                Text(result?.latencyString ?? "---")
                    .font(.system(.body, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(result?.latencyColor ?? .secondary)
                    .contentTransition(.numericText())
                    .animation(.easeInOut(duration: 0.2), value: result?.latency)

                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.quaternary)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 12)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.05) : Color.clear)
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
