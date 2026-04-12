//
//  MainStatusView.swift
//  PongBar
//
//  Primary status view showing all targets, uptime, and navigation to history.
//

import SwiftUI

struct MainStatusView: View {
    @Environment(NetworkMonitor.self) private var monitor
    var navigate: (PopoverPage) -> Void
    @State private var isShowingTR064Debug = false
    @State private var isTR064DebugLoading = false
    @State private var tr064DebugOutput = ""

    var body: some View {
        VStack(spacing: 0) {
            // Header
            headerRow
            Divider()

            // Target status rows (clickable → chart detail)
            StatusRowView(
                result: monitor.currentResults[.internet],
                target: .internet,
                detail: Config.internetHost,
                loss: monitor.metrics.packetLoss[.internet],
                jitterValue: monitor.metrics.jitter[.internet],
                sparklineData: monitor.metrics.latencyHistory[.internet] ?? [],
                sparklineColor: .blue
            ) { navigate(.targetDetail(.internet, Config.internetHost)) }

            StatusRowView(
                result: monitor.currentResults[.router],
                target: .router,
                detail: monitor.gatewayIP,
                loss: monitor.metrics.packetLoss[.router],
                jitterValue: monitor.metrics.jitter[.router],
                sparklineData: monitor.metrics.latencyHistory[.router] ?? [],
                sparklineColor: .green
            ) { navigate(.targetDetail(.router, monitor.gatewayIP)) }

            DNSRowView(
                result: monitor.currentResults[.dns],
                detail: monitor.activeDNSServer ?? Config.dnsTestDomain,
                loss: monitor.metrics.packetLoss[.dns],
                jitterValue: monitor.metrics.jitter[.dns],
                sparklineData: monitor.metrics.latencyHistory[.dns] ?? []
            ) { navigate(.targetDetail(.dns, monitor.activeDNSServer ?? Config.dnsTestDomain)) }

            // VPN Server ping (visible only when public IP responds = VPN active)
            if let pip = monitor.publicIP, monitor.isVPNDetected, monitor.publicIPPingResult != nil {
                StatusRowView(
                    result: monitor.publicIPPingResult,
                    target: .vpn,
                    detail: pip,
                    sparklineData: monitor.publicIPLatencyHistory,
                    sparklineColor: .cyan
                ) { navigate(.targetDetail(.vpn, pip)) }
            }

            // Custom targets (clickable → chart detail)
            ForEach(monitor.customTargets.filter(\.isEnabled)) { target in
                CustomTargetRowView(
                    target: target,
                    result: monitor.customResults[target.id],
                    sparklineData: monitor.customLatencyHistory[target.id] ?? []
                ) {
                    navigate(.customTargetDetail("custom.\(target.host)", target.name))
                }
            }

            // Local Network LAN Devices
            ForEach(monitor.localDevices) { device in
                LocalDeviceRowView(
                    device: device,
                    result: monitor.localResults[device.id],
                    sparklineData: monitor.localLatencyHistory[device.id] ?? []
                )
            }

            Divider()
                .padding(.vertical, 4)

            // Uptime bar
            UptimeBarView(percentage: monitor.incidentManager.uptimeToday)

            Divider()
                .padding(.vertical, 4)

            // Incident history link
            Button {
                navigate(.history)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Text("Incident History")
                        .font(.body)
                        .foregroundStyle(.primary)
                    if monitor.incidentManager.todayIncidentCount > 0 {
                        Text("(\(monitor.incidentManager.todayIncidentCount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Divider()
                .padding(.vertical, 4)

            // Footer
            footerRow
        }
        .overlay {
            if isShowingTR064Debug {
                ZStack {
                    Color.black.opacity(0.2)
                        .ignoresSafeArea()
                        .onTapGesture {
                            isShowingTR064Debug = false
                        }

                    TR064DebugSheetView(
                        isLoading: isTR064DebugLoading,
                        output: tr064DebugOutput,
                        onClose: { isShowingTR064Debug = false }
                    )
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .onDisappear {
            isShowingTR064Debug = false
        }
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("PingPong Network Monitor")
                    .font(.headline)
                Spacer()
                VStack(spacing: 6) {
                    SettingsLink {
                        Image(systemName: "gearshape")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .simultaneousGesture(TapGesture().onEnded {
                        NSApp.activate(ignoringOtherApps: true)
                    })

                    Button {
                        runTR064Debug()
                    } label: {
                        Image(systemName: "house.badge.wifi.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Run TR-064 debug")
                }
            }
            // Network info: interface + public IP
            HStack(spacing: 4) {
                if let info = monitor.interfaceInfo {
                    Text(info.summary)
                }
                if let publicIP = monitor.publicIP {
                    Text("·")
                    Text(publicIP)
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            // Throughput: physical interface
            if let info = monitor.interfaceInfo,
               let reading = monitor.throughput.currentReadings[info.interfaceName] {
                ThroughputRowView(
                    downloadBytesPerSec: reading.downloadBytesPerSec,
                    uploadBytesPerSec: reading.uploadBytesPerSec
                )
            }

            // Throughput: VPN tunnel (if active)
            if monitor.isVPNDetected {
                let vpnPrefixes = ["utun", "ipsec", "ppp"]
                let vpnReadings = monitor.throughput.currentReadings.filter { name in
                    vpnPrefixes.contains(where: { name.key.hasPrefix($0) })
                }
                if let vpnReading = vpnReadings.values.max(by: {
                    ($0.downloadBytesPerSec + $0.uploadBytesPerSec) < ($1.downloadBytesPerSec + $1.uploadBytesPerSec)
                }) {
                    ThroughputRowView(
                        downloadBytesPerSec: vpnReading.downloadBytesPerSec,
                        uploadBytesPerSec: vpnReading.uploadBytesPerSec,
                        label: "VPN"
                    )
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var footerRow: some View {
        HStack {
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Quit PongBar")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func runTR064Debug() {
        isShowingTR064Debug = true
        isTR064DebugLoading = true
        tr064DebugOutput = "Running TR-064 debug..."

        Task {
            let output = await buildTR064DebugOutput()
            await MainActor.run {
                tr064DebugOutput = output
                isTR064DebugLoading = false
            }
        }
    }

    private func buildTR064DebugOutput() async -> String {
        let account = UserDefaults.standard.string(forKey: "local.username")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = UserDefaults.standard.string(forKey: "local.password")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let credentialsPresent = !account.isEmpty && !password.isEmpty

        let routerIP = guessedRouterIP(from: monitor.gatewayIP)
        var lines: [String] = []
        lines.append("Router IP used: \(routerIP)")
        lines.append("Credentials present: \(credentialsPresent ? "yes" : "no")")

        guard credentialsPresent else {
            lines.append("Error: Missing local TR-064 credentials (local.username / local.password).")
            appendMacMatchLines(into: &lines, map: [:])
            return lines.joined(separator: "\n")
        }

        var map: [String: (active: Bool, ip: String?)] = [:]
        var successAttempt: Int?
        var lastError: String?
        let backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]

        for (index, delay) in backoff.enumerated() {
            let attempt = index + 1
            let result = await TR064HostService.onlineMapWithError(routerIP: routerIP, username: account, password: password)
            map = result.map
            lastError = result.error

            if map.isEmpty {
                if let error = result.error, !error.isEmpty {
                    lines.append("Attempt \(attempt): map is empty (failed) - error: \(error)")
                } else {
                    lines.append("Attempt \(attempt): map is empty (failed)")
                }
                if index < backoff.count - 1 {
                    try? await Task.sleep(for: delay)
                }
            } else {
                successAttempt = attempt
                lines.append("Attempt \(attempt): map has \(map.count) entries (success)")
                break
            }
        }

        if let successAttempt {
            lines.append("Map empty: no")
            lines.append("Succeeded on attempt: \(successAttempt)")
        } else {
            lines.append("Map empty: yes")
            lines.append("Failed after attempts: \(backoff.count)")
            if let lastError, !lastError.isEmpty {
                lines.append("Error: \(lastError)")
            } else {
                lines.append("Error: TR-064 returned no host map (empty or unreachable/invalid response).")
            }
        }

        appendMacMatchLines(into: &lines, map: map)
        return lines.joined(separator: "\n")
    }

    private func appendMacMatchLines(
        into lines: inout [String],
        map: [String: (active: Bool, ip: String?)]
    ) {
        if monitor.localDevices.isEmpty {
            lines.append("Device MAC matches: no local devices configured")
            return
        }

        lines.append("Device MAC matches:")
        for device in monitor.localDevices {
            let key1 = device.macAddress.lowercased()
            let key2 = key1.replacingOccurrences(of: "-", with: ":")
            let key3 = key1.replacingOccurrences(of: ":", with: "-")
            let entry = map[key1] ?? map[key2] ?? map[key3]
            if let entry {
                let ip = entry.ip ?? "n/a"
                lines.append("- \(device.displayName) [\(device.macAddress)] -> match: yes, active: \(entry.active), ip: \(ip)")
            } else {
                lines.append("- \(device.displayName) [\(device.macAddress)] -> match: no")
            }
        }
    }

    private func guessedRouterIP(from gateway: String) -> String {
        if isPrivateIPv4(gateway) {
            return gateway
        }
        return "192.168.178.1"
    }

    private func isPrivateIPv4(_ ip: String) -> Bool {
        ip.hasPrefix("192.168.")
        || ip.hasPrefix("10.")
        || ip.hasPrefix("172.16.")
        || ip.hasPrefix("172.17.")
        || ip.hasPrefix("172.18.")
        || ip.hasPrefix("172.19.")
        || ip.hasPrefix("172.20.")
        || ip.hasPrefix("172.21.")
        || ip.hasPrefix("172.22.")
        || ip.hasPrefix("172.23.")
        || ip.hasPrefix("172.24.")
        || ip.hasPrefix("172.25.")
        || ip.hasPrefix("172.26.")
        || ip.hasPrefix("172.27.")
        || ip.hasPrefix("172.28.")
        || ip.hasPrefix("172.29.")
        || ip.hasPrefix("172.30.")
        || ip.hasPrefix("172.31.")
    }
}

private struct TR064DebugSheetView: View {
    let isLoading: Bool
    let output: String
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TR-064 Debug")
                    .font(.headline)
                Spacer()
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                Button("Close") {
                    onClose()
                }
            }
            ScrollView([.vertical, .horizontal]) {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
        }
        .padding(12)
        .frame(maxWidth: 700, maxHeight: 480)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(radius: 14)
    }
}

#Preview("MainStatusView") {
    let monitor = NetworkMonitor()
    // Stop the repeating timer for a stable preview environment
    monitor.stop()

    // Seed some example data for a meaningful preview
    monitor.currentResults[.internet] = PingResult(target: .internet, timestamp: .now, isReachable: true, latency: 24, detail: Config.internetHost)
    monitor.currentResults[.router] = PingResult(target: .router, timestamp: .now, isReachable: true, latency: 2, detail: "192.168.1.1")
    monitor.currentResults[.dns] = PingResult(target: .dns, timestamp: .now, isReachable: true, latency: 9, detail: "1.1.1.1")

    monitor.publicIP = "203.0.113.10"
    monitor.isVPNDetected = true
    monitor.publicIPPingResult = PingResult(target: .vpn, timestamp: .now, isReachable: true, latency: 35, detail: "203.0.113.10")
    monitor.publicIPLatencyHistory = [30, 34, 36, 32, 31, 35, 33]

    return MainStatusView(navigate: { _ in })
        .environment(monitor)
        .frame(width: 360)
}
