//
//  NetworkMapView.swift
//  PongBar
//
//  Network Weather Map — animated topology visualization showing the path
//  from your Mac through each hop to the destination. Nodes are colored
//  by latency, links pulse with traffic, and loss is shown as broken links.
//

import SwiftUI

struct NetworkMapView: View {
    let host: String
    var goBack: () -> Void

    @State private var session: MTRSession?

    var body: some View {
        VStack(spacing: 0) {
            PopoverNavigationHeader(onBack: {
                session?.stop()
                goBack()
            }) {
                Text("Network Map")
                    .font(.headline)
            } trailing: {
                if let session, session.isRunning {
                    Circle()
                        .fill(.green)
                        .frame(width: 6, height: 6)
                }
            }

            Divider()

            // Map visualization
            if let session {
                if session.hops.isEmpty && session.isRunning {
                    VStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Mapping route...")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    TopologyCanvas(hops: session.hops, target: host)
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

/// Canvas-based topology rendering: Mac → hop1 → hop2 → ... → target
private struct TopologyCanvas: View {
    let hops: [MTRHopStats]
    let target: String

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1)) { timeline in
        let animationPhase = timeline.date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: 2.0) / 2.0
        Canvas { context, size in
            let nodeCount = hops.count + 2  // +1 for "My Mac", +1 for target
            let padding: CGFloat = 20
            let usableWidth = size.width - padding * 2
            let usableHeight = size.height - padding * 2
            let centerY = size.height / 2

            // Layout: nodes in a zigzag/serpentine pattern
            let positions = computePositions(
                count: nodeCount,
                width: usableWidth,
                height: usableHeight,
                padding: padding,
                centerY: centerY
            )

            // Draw links between nodes
            for i in 0..<(positions.count - 1) {
                let from = positions[i]
                let to = positions[i + 1]

                let hopIndex = i - 1  // -1 because first node is "My Mac"
                let isTimeout = hopIndex >= 0 && hopIndex < hops.count && hops[hopIndex].host == "* * *"
                let loss = hopIndex >= 0 && hopIndex < hops.count ? hops[hopIndex].lossPercent : 0

                // Link line
                var linkPath = Path()
                linkPath.move(to: from)
                linkPath.addLine(to: to)

                if isTimeout {
                    // Unknown hop (ICMP filtered) — gray dashed, not an error
                    context.stroke(linkPath, with: .color(.secondary.opacity(0.3)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                } else if loss > 50 {
                    // Real packet loss — dashed red
                    context.stroke(linkPath, with: .color(.red.opacity(0.4)),
                                   style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                } else {
                    let linkColor = colorForLoss(loss)
                    context.stroke(linkPath, with: .color(linkColor.opacity(0.3)), lineWidth: 1.5)

                    // Animated packet dot traveling along the link
                    let progress = (animationPhase + Double(i) * 0.15).truncatingRemainder(dividingBy: 1.0)
                    let dotX = from.x + (to.x - from.x) * progress
                    let dotY = from.y + (to.y - from.y) * progress
                    let dotRect = CGRect(x: dotX - 2, y: dotY - 2, width: 4, height: 4)
                    context.fill(Ellipse().path(in: dotRect), with: .color(linkColor.opacity(0.8)))
                }
            }

            // Draw nodes
            for (i, pos) in positions.enumerated() {
                let nodeRadius: CGFloat = i == 0 || i == positions.count - 1 ? 8 : 6

                let color: Color
                let label: String

                if i == 0 {
                    color = .blue
                    label = "My Mac"
                } else if i == positions.count - 1 {
                    color = .purple
                    label = target
                } else {
                    let hop = hops[i - 1]
                    color = colorForHop(hop)
                    label = hop.host == "* * *" ? "—" : shortHost(hop.host)
                }

                // Node circle with glow
                let nodeRect = CGRect(x: pos.x - nodeRadius, y: pos.y - nodeRadius,
                                      width: nodeRadius * 2, height: nodeRadius * 2)

                // Glow
                let glowRect = nodeRect.insetBy(dx: -3, dy: -3)
                context.fill(Ellipse().path(in: glowRect), with: .color(color.opacity(0.15)))

                // Node
                context.fill(Ellipse().path(in: nodeRect), with: .color(color))

                // Label below node
                let text = Text(label)
                    .font(.system(size: 7))
                    .foregroundStyle(.secondary)
                context.draw(text, at: CGPoint(x: pos.x, y: pos.y + nodeRadius + 8))

                // Latency above node (for hops)
                if i > 0 && i < positions.count - 1 {
                    let hop = hops[i - 1]
                    let latText: String
                    if hop.host == "* * *" {
                        latText = ""  // No label for filtered hops
                    } else if let last = hop.lastLatency {
                        latText = String(format: "%.0fms", last)
                    } else {
                        latText = "---"
                    }
                    let latLabel = Text(latText)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(color)
                    context.draw(latLabel, at: CGPoint(x: pos.x, y: pos.y - nodeRadius - 8))
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, maxHeight: 300)
        .padding(8)
        } // TimelineView
    }

    /// Compute zigzag positions for nodes that fit in the available space.
    private func computePositions(count: Int, width: CGFloat, height: CGFloat,
                                  padding: CGFloat, centerY: CGFloat) -> [CGPoint] {
        guard count > 1 else {
            return count == 1 ? [CGPoint(x: padding + width / 2, y: padding + 20)] : []
        }

        let maxPerRow = 5
        var positions: [CGPoint] = []
        let rowSpacing: CGFloat = 50

        var x = padding
        var y = padding + 20
        var direction: CGFloat = 1  // 1 = left-to-right, -1 = right-to-left
        var colInRow = 0

        for _ in 0..<count {
            positions.append(CGPoint(x: x, y: y))
            colInRow += 1

            if colInRow >= maxPerRow {
                // Move to next row
                y += rowSpacing
                colInRow = 0
                direction *= -1
            } else {
                let step = width / CGFloat(min(count - 1, maxPerRow - 1))
                x += step * direction
            }
        }

        return positions
    }

    private func colorForHop(_ hop: MTRHopStats) -> Color {
        if hop.host == "* * *" { return .secondary }  // ICMP filtered — normal, not an error
        if hop.lossPercent > 20 { return .red }
        if hop.lossPercent > 0 { return .yellow }
        if let lat = hop.lastLatency {
            if lat > Config.latencyFairThreshold { return .red }
            if lat > Config.latencyGoodThreshold { return .yellow }
        }
        return .green
    }

    private func colorForLoss(_ loss: Double) -> Color {
        if loss > 20 { return .red }
        if loss > 0 { return .yellow }
        return .green
    }

    private func shortHost(_ host: String) -> String {
        if host.count <= 12 { return host }
        // Truncate long hostnames
        let parts = host.split(separator: ".")
        if parts.count >= 2 {
            return "\(parts[0])..."
        }
        return String(host.prefix(10)) + "..."
    }
}
