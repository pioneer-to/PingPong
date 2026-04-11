//
//  PongBarApp.swift
//  PongBar
//

import SwiftUI

/// Main entry point for the PongBar menu bar application.
/// Uses MenuBarExtra with .window style for a rich SwiftUI popover.
@main
struct PongBarApp: App {
    @State private var monitor = NetworkMonitor()
    @AppStorage("menuBarDisplayMode") private var menuBarDisplayMode: String = "dot"

    var body: some Scene {
        MenuBarExtra {
            PopoverContentView()
                .environment(monitor)
                .frame(minWidth: 300, idealWidth: 360)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(monitor.overallStatusColor)

                if menuBarDisplayMode == "dotLatency" {
                    if let latency = monitor.currentResults[.internet]?.latency {
                        Text(String(format: "%.0f ms", latency))
                            .font(.system(.caption, design: .monospaced))
                            .monospacedDigit()
                    }
                } else if menuBarDisplayMode == "dotLoss" {
                    if let loss = monitor.metrics.packetLoss[.internet], loss > 0 {
                        Text(String(format: "%.0f%%", loss))
                            .font(.system(.caption, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.red)
                    }
                }
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(monitor)
        }
    }
}
