//
//  SparklineView.swift
//  PongBar
//
//  Tiny inline latency sparkline chart for status rows.
//  Uses @ViewBuilder instead of AnyView to preserve SwiftUI structural diffing.
//

import SwiftUI

/// A compact sparkline showing latency trend from recent samples.
struct SparklineView: View {
    let values: [Double?]
    let color: Color
    @Environment(PopoverState.self) private var popoverState

    @ViewBuilder
    var body: some View {
        let dataPoints = values.compactMap { $0 }
        if dataPoints.count >= 2 {
            if popoverState.isVisible {
                let minVal = dataPoints.min() ?? 0
                let maxVal = dataPoints.max() ?? 1
                let range = max(maxVal - minVal, 1)

                Canvas { context, size in
                    let step = size.width / CGFloat(values.count - 1)
                    var path = Path()
                    var started = false

                    for (index, value) in values.enumerated() {
                        guard let v = value else { continue }
                        let x = CGFloat(index) * step
                        let normalized = (v - minVal) / range
                        let y = size.height - (CGFloat(normalized) * size.height)

                        if !started {
                            path.move(to: CGPoint(x: x, y: y))
                            started = true
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }

                    context.stroke(path, with: .color(color.opacity(0.6)), lineWidth: 1)
                }
                .frame(width: 40, height: 14)
            } else {
                Color.clear
                    .frame(width: 40, height: 14)
            }
        }
    }
}
