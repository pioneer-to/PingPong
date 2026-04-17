//
//  MTRView.swift
//  PongBar
//
//  Continuous MTR (My Traceroute) view with live per-hop latency and loss.
//  Shows a table of hops with real-time stats and mini sparklines.
//

import SwiftUI

struct MTRView: View {
    let host: String
    var goBack: () -> Void

    @State private var session: MTRSession?

    var body: some View {
        VStack(spacing: 0) {
            PopoverNavigationHeader(onBack: {
                session?.stop()
                goBack()
            }) {
                Text("MTR")
                    .font(.headline)
            } trailing: {
                if let session, session.isRunning {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                        Text("#\(session.roundCount)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Divider()

            // Target
            Text(host)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.vertical, 4)

            Divider()

            // Column headers
            HStack(spacing: 0) {
                Text("#")
                    .frame(width: 20, alignment: .trailing)
                Text("Host")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.leading, 8)
                Text("Loss")
                    .frame(width: 42, alignment: .trailing)
                Text("Avg")
                    .frame(width: 36, alignment: .trailing)
                Text("Last")
                    .frame(width: 36, alignment: .trailing)
                Text("Best")
                    .frame(width: 36, alignment: .trailing)
                Text("Wrst")
                    .frame(width: 36, alignment: .trailing)
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)

            Divider()

            // Hop rows
            if let session {
                if session.hops.isEmpty && session.isRunning {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Discovering hops...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 20)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(session.hops) { hop in
                                MTRHopRow(hop: hop)
                            }
                        }
                    }
                    .frame(minHeight: 200, maxHeight: 400)
                }
            }
        }
        .onAppear {
            let s = MTRSession(target: host)
            session = s
            s.start()
        }
        .onDisappear {
            session?.stop()
        }
    }
}

/// A single hop row in the MTR table.
private struct MTRHopRow: View {
    let hop: MTRHopStats

    var body: some View {
        HStack(spacing: 0) {
            Text("\(hop.hopNumber)")
                .frame(width: 20, alignment: .trailing)
                .foregroundStyle(.secondary)

            // Status dot
            Circle()
                .fill(dotColor)
                .frame(width: 5, height: 5)
                .padding(.leading, 4)

            // Host (truncated)
            Text(displayHost)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 4)

            // Loss %
            Text(hop.sent > 0 ? String(format: "%.0f%%", hop.lossPercent) : "---")
                .frame(width: 42, alignment: .trailing)
                .foregroundStyle(hop.lossPercent > 0 ? .red : .secondary)

            // Avg
            Text(hop.received > 0 ? String(format: "%.0f", hop.avgLatency) : "---")
                .frame(width: 36, alignment: .trailing)

            // Last
            Text(hop.lastLatency.map { String(format: "%.0f", $0) } ?? "---")
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(hop.lastLatency == nil ? .red : .primary)

            // Best
            Text(hop.received > 0 ? String(format: "%.0f", hop.bestLatency) : "---")
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(.green)

            // Worst
            Text(hop.received > 0 ? String(format: "%.0f", hop.worstLatency) : "---")
                .frame(width: 36, alignment: .trailing)
                .foregroundStyle(hop.worstLatency > Config.latencyFairThreshold ? .red : .secondary)
        }
        .font(.system(size: 10, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
    }

    private var displayHost: String {
        if hop.host == "* * *" { return "* * *" }
        // Show just IP if host is an IP already
        if hop.host.first?.isNumber == true { return hop.host }
        return hop.host
    }

    private var dotColor: Color {
        if hop.host == "* * *" { return .secondary }  // ICMP filtered — normal
        if hop.lossPercent > 50 { return .red }
        if hop.lossPercent > 0 { return .yellow }
        return .green
    }
}
