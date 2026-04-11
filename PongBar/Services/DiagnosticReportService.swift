//
//  DiagnosticReportService.swift
//  PongBar
//
//  Generates a plain-text diagnostic report for sharing with ISP support or debugging.
//

import Foundation
import AppKit

/// Generates a network diagnostic report from current monitor state.
enum DiagnosticReportService {
    /// Generate a full diagnostic report.
    static func generate(from monitor: NetworkMonitor) -> String {
        var lines: [String] = []

        lines.append("═══════════════════════════════════")
        lines.append("  PongBar Diagnostic Report")
        lines.append("  Generated: \(DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .medium))")
        lines.append("═══════════════════════════════════")
        lines.append("")

        // Network Interface
        lines.append("── Network Interface ──")
        if let info = monitor.interfaceInfo {
            lines.append("  Type:      \(info.type.rawValue)")
            lines.append("  Interface: \(info.interfaceName)")
            if let ip = info.ipAddress { lines.append("  IP:        \(ip)") }
            if let ssid = info.wifiSSID { lines.append("  WiFi SSID: \(ssid)") }
            if let rssi = info.wifiRSSI { lines.append("  WiFi RSSI: \(rssi) dBm (\(info.signalQuality ?? ""))") }
        } else {
            lines.append("  No active interface detected")
        }
        lines.append("  Gateway:   \(monitor.gatewayIP)")
        lines.append("  Public IP: \(monitor.publicIP ?? "unknown")")
        lines.append("")

        // Current Status
        lines.append("── Current Status ──")
        for target in PingTarget.builtInCases {
            let result = monitor.currentResults[target]
            let status = result?.isReachable == true ? "✓ UP" : "✗ DOWN"
            let latency = result?.latencyString ?? "---"
            let loss = monitor.metrics.packetLoss[target].map { String(format: "%.1f%%", $0) } ?? "---"
            let jit = monitor.metrics.jitter[target].map { String(format: "%.1fms", $0) } ?? "---"
            lines.append("  \(target.displayName.padding(toLength: 14, withPad: " ", startingAt: 0)) \(status)  Latency: \(latency)  Loss: \(loss)  Jitter: \(jit)")
        }
        // VPN server
        if let vpnResult = monitor.publicIPPingResult, let pip = monitor.publicIP {
            let status = vpnResult.isReachable ? "✓ UP" : "✗ DOWN"
            lines.append("  \("VPN Server".padding(toLength: 14, withPad: " ", startingAt: 0)) \(status)  Latency: \(vpnResult.latencyString)  IP: \(pip)")
        }
        lines.append("")

        // Uptime
        lines.append("── Uptime Today ──")
        lines.append("  \(String(format: "%.1f%%", monitor.incidentManager.uptimeToday))")
        lines.append("")

        // Recent Incidents (last 20)
        lines.append("── Recent Incidents ──")
        let recent = Array(monitor.incidentManager.incidents.prefix(Config.diagnosticRecentIncidents))
        if recent.isEmpty {
            lines.append("  No incidents recorded")
        } else {
            for incident in recent {
                let time = Formatters.timeOnly(incident.startTime)
                let date = DateFormatter.localizedString(from: incident.startTime, dateStyle: .short, timeStyle: .none)
                let resolved = incident.isResolved ? "resolved" : "ACTIVE"
                let cat = incident.category?.label ?? ""
                lines.append("  \(date) \(time)  \(incident.summary)  \(incident.durationString)  [\(resolved)] \(cat)")
            }
        }
        lines.append("")

        // System Info
        lines.append("── System Info ──")
        lines.append("  macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        lines.append("  Ping interval: \(Int(monitor.pingInterval))s")
        lines.append("  Samples stored: \(SQLiteStorage.shared.count)")
        lines.append("")
        lines.append("═══════════════════════════════════")

        return lines.joined(separator: "\n")
    }

    /// Copy the report to the clipboard.
    static func copyToClipboard(from monitor: NetworkMonitor) {
        let report = generate(from: monitor)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(report, forType: .string)
    }
}
