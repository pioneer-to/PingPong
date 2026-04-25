//
//  ThroughputRowView.swift
//  PingPongBar
//
//  Compact download/upload throughput display for the popover header.
//

import SwiftUI

struct ThroughputRowView: View {
    let downloadBytesPerSec: Double
    let uploadBytesPerSec: Double
    var label: String? = nil

    var body: some View {
        let dlStr = Formatters.bytesPerSecond(downloadBytesPerSec)
        let ulStr = Formatters.bytesPerSecond(uploadBytesPerSec)

        HStack(spacing: 8) {
            if let lbl = label {
                Text(lbl)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.purple)
            }

            HStack(spacing: 3) {
                Image(systemName: "arrow.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Text(dlStr ?? "—")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }

            HStack(spacing: 3) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 8))
                    .foregroundStyle(.secondary)
                Text(ulStr ?? "—")
                    .font(.system(size: 10, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
            }
        }
    }
}
