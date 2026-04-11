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
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("PongBar")
                    .font(.headline)
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .simultaneousGesture(TapGesture().onEnded {
                    NSApp.activate(ignoringOtherApps: true)
                })
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
}
