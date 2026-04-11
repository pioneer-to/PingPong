//
//  SettingsView.swift
//  PongBar
//
//  Application settings window for configuring ping intervals, notifications, and preferences.
//

import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Environment(NetworkMonitor.self) private var monitor
    @AppStorage("pingInterval") private var pingInterval: Double = 3.0
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("showPublicIP") private var showPublicIP: Bool = true
    @AppStorage("menuBarDisplayMode") private var menuBarDisplayMode: String = "dot"

    // Notification toggles per target
    @AppStorage("notify.internet") private var notifyInternet: Bool = true
    @AppStorage("notify.router") private var notifyRouter: Bool = true
    @AppStorage("notify.dns") private var notifyDNS: Bool = true

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }

            targetsTab
                .tabItem { Label("Targets", systemImage: "target") }

            notificationsTab
                .tabItem { Label("Notifications", systemImage: "bell") }

            menuBarTab
                .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }

            dnsTab
                .tabItem { Label("DNS", systemImage: "server.rack") }

            dataTab
                .tabItem { Label("Data", systemImage: "externaldrive") }

            advancedTab
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 480, height: 380)
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            Section("Monitoring") {
                HStack {
                    Text("Ping interval")
                    Spacer()
                    Picker("", selection: $pingInterval) {
                        Text("1s").tag(1.0)
                        Text("3s").tag(3.0)
                        Text("5s").tag(5.0)
                        Text("10s").tag(10.0)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }

            Section("System") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                @Bindable var m = monitor
                Toggle("Pause monitoring during sleep", isOn: $m.pauseDuringSleep)
            }

            Section("Privacy") {
                Toggle("Show public IP (contacts api.ipify.org)", isOn: $showPublicIP)
                    .onChange(of: showPublicIP) { _, newValue in
                        if !newValue {
                            monitor.publicIP = nil
                            monitor.publicIPPingResult = nil
                        }
                    }
            }
        }
        .formStyle(.grouped)
        .onChange(of: pingInterval) { _, newValue in
            monitor.pingInterval = newValue
            monitor.stop()
            monitor.start()
        }
    }

    // MARK: - Custom Targets

    @State private var newTargetName = ""
    @State private var copiedDiag = false
    @State private var newTargetHost = ""

    private var targetsTab: some View {
        Form {
            Section("Built-in Targets") {
                HStack {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Internet (\(Config.internetHost))")
                    Spacer()
                    Text("Always on").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Router (auto-detect)")
                    Spacer()
                    Text("Always on").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("DNS Resolve (\(Config.dnsTestDomain))")
                    Spacer()
                    Text("Always on").font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Custom Targets") {
                ForEach(monitor.customTargets) { target in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { target.isEnabled },
                            set: { _ in monitor.toggleCustomTarget(target) }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)

                        VStack(alignment: .leading) {
                            Text(target.name)
                                .font(.body)
                            Text(target.host)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            monitor.removeCustomTarget(target)
                        } label: {
                            Image(systemName: "trash")
                                .font(.caption)
                                .foregroundStyle(.red.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Add new target
                HStack(spacing: 8) {
                    TextField("Name", text: $newTargetName)
                        .frame(width: 100)
                    TextField("Host / IP", text: $newTargetHost)
                    Button("Add") {
                        guard !newTargetName.isEmpty, !newTargetHost.isEmpty else { return }
                        monitor.addCustomTarget(name: newTargetName, host: newTargetHost)
                        newTargetName = ""
                        newTargetHost = ""
                    }
                    .disabled(newTargetName.isEmpty || newTargetHost.isEmpty)
                }
            }

            if monitor.customTargets.count >= 6 {
                Section {
                    Text("Maximum 6 custom targets recommended to keep the popover clean.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Notifications

    private var notificationsTab: some View {
        Form {
            Section("Notify when target goes down") {
                Toggle("Internet (1.1.1.1)", isOn: $notifyInternet)
                Toggle("Router", isOn: $notifyRouter)
                Toggle("DNS Resolve", isOn: $notifyDNS)
            }

            Section {
                Text("Notifications include downtime duration on recovery. A 30-second cooldown prevents spam.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Menu Bar

    private var menuBarTab: some View {
        Form {
            Section("Menu Bar Display") {
                Picker("Show in menu bar", selection: $menuBarDisplayMode) {
                    Text("Dot only").tag("dot")
                    Text("Dot + Latency").tag("dotLatency")
                    Text("Dot + Loss %").tag("dotLoss")
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - DNS

    @State private var activeService: String = "..."
    @State private var currentDNS: [String] = []
    @State private var selectedPreset: DNSPreset = .dhcp
    @State private var customDNS1: String = ""
    @State private var customDNS2: String = ""
    @State private var dnsStatus: String? = nil
    @State private var dnsStatusIsError: Bool = false
    @State private var dnsApplyTask: Task<Void, Never>?

    private var dnsTab: some View {
        Form {
            Section("Active Connection") {
                HStack {
                    Text("Service")
                    Spacer()
                    Text(activeService)
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Current DNS")
                    Spacer()
                    Text(currentDNS.isEmpty ? "DHCP (Auto)" : currentDNS.joined(separator: ", "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Section("Quick Switch") {
                ForEach(DNSPreset.allCases) { preset in
                    Button {
                        dnsApplyTask?.cancel()
                        dnsApplyTask = Task {
                            if await DNSSwitcherService.applyPreset(preset) {
                                guard !Task.isCancelled else { return }
                                selectedPreset = preset
                                dnsStatus = "Applied: \(preset.rawValue)"
                                dnsStatusIsError = false
                                await refreshDNSInfo()
                            } else {
                                guard !Task.isCancelled else { return }
                                dnsStatus = "Failed to apply"
                                dnsStatusIsError = true
                            }
                            try? await Task.sleep(for: .seconds(3))
                            dnsStatus = nil
                        }
                    } label: {
                        HStack {
                            Image(systemName: selectedPreset == preset ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selectedPreset == preset ? .green : .secondary)
                            VStack(alignment: .leading) {
                                Text(preset.rawValue)
                                    .foregroundStyle(.primary)
                                if let servers = preset.servers {
                                    Text(servers.joined(separator: ", "))
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section("Custom DNS") {
                HStack {
                    TextField("Primary", text: $customDNS1)
                        .textFieldStyle(.roundedBorder)
                    TextField("Secondary", text: $customDNS2)
                        .textFieldStyle(.roundedBorder)
                    Button("Apply") {
                        let primary = customDNS1.trimmingCharacters(in: .whitespaces)
                        let secondary = customDNS2.trimmingCharacters(in: .whitespaces)
                        var servers: [String] = []
                        if HostValidator.isValidIPAddress(primary) { servers.append(primary) }
                        if !secondary.isEmpty {
                            if HostValidator.isValidIPAddress(secondary) {
                                servers.append(secondary)
                            } else {
                                dnsStatus = "Invalid secondary DNS"
                                dnsStatusIsError = true
                                return
                            }
                        }
                        guard !servers.isEmpty else { dnsStatus = "Invalid DNS"; dnsStatusIsError = true; return }

                        dnsApplyTask?.cancel()
                        dnsApplyTask = Task {
                            if await DNSSwitcherService.applyCustom(servers: servers) {
                                guard !Task.isCancelled else { return }
                                dnsStatus = "Applied custom DNS"
                                dnsStatusIsError = false
                                await refreshDNSInfo()
                            } else {
                                guard !Task.isCancelled else { return }
                                dnsStatus = "Failed"
                                dnsStatusIsError = true
                            }
                            try? await Task.sleep(for: .seconds(3))
                            dnsStatus = nil
                        }
                    }
                }
            }

            if let status = dnsStatus {
                Section {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(dnsStatusIsError ? .red : .green)
                }
            }
        }
        .formStyle(.grouped)
        .task { await refreshDNSInfo() }
    }

    private func refreshDNSInfo() async {
        if let svc = await DNSSwitcherService.getActiveServiceName() {
            activeService = svc
            currentDNS = await DNSSwitcherService.getCurrentDNS(service: svc)
            selectedPreset = await DNSSwitcherService.detectCurrentPreset(service: svc)
        }
    }

    // MARK: - Data

    private var dataTab: some View {
        Form {
            Section("Storage") {
                HStack {
                    Text("Latency samples")
                    Spacer()
                    Text("\(SQLiteStorage.shared.count) samples")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Incidents")
                    Spacer()
                    Text("\(monitor.incidentManager.incidents.count) records")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Diagnostics") {
                Button {
                    DiagnosticReportService.copyToClipboard(from: monitor)
                    copiedDiag = true
                    Task {
                        try? await Task.sleep(for: .seconds(2))
                        copiedDiag = false
                    }
                } label: {
                    HStack {
                        Image(systemName: copiedDiag ? "checkmark" : "doc.on.clipboard")
                        Text(copiedDiag ? "Copied!" : "Copy Diagnostic Report")
                    }
                }
            }

            Section {
                Button("Clear Incident History") {
                    monitor.clearHistory()
                }
                .foregroundStyle(.red)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Advanced

    @AppStorage(Config.Keys.internetHost) private var internetHost: String = Config.Defaults.internetHost
    @AppStorage(Config.Keys.dnsTestDomain) private var dnsTestDomain: String = Config.Defaults.dnsTestDomain
    @AppStorage(Config.Keys.pingTimeout) private var pingTimeout: Int = Config.Defaults.pingTimeout
    @AppStorage(Config.Keys.dnsTimeout) private var dnsTimeout: Int = Config.Defaults.dnsTimeout
    @AppStorage(Config.Keys.latencyGoodThreshold) private var latencyGood: Double = Config.Defaults.latencyGoodThreshold
    @AppStorage(Config.Keys.latencyFairThreshold) private var latencyFair: Double = Config.Defaults.latencyFairThreshold
    @AppStorage(Config.Keys.jitterWarningThreshold) private var jitterWarn: Double = Config.Defaults.jitterWarningThreshold
    @AppStorage(Config.Keys.notificationCooldown) private var notifCooldown: Double = Config.Defaults.notificationCooldown
    @AppStorage(Config.Keys.retentionPeriod) private var retention: Double = Config.Defaults.retentionPeriod
    @AppStorage(Config.Keys.networkSwitchGracePings) private var gracePings: Int = Config.Defaults.networkSwitchGracePings

    private var retentionDays: Binding<Double> {
        Binding(
            get: { retention / 86400 },
            set: { retention = $0 * 86400 }
        )
    }

    private var advancedTab: some View {
        Form {
            Section("Hosts") {
                HStack {
                    Text("Internet host")
                    Spacer()
                    TextField("", text: $internetHost)
                        .frame(width: 140)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("DNS test domain")
                        Spacer()
                        TextField("", text: $dnsTestDomain)
                            .frame(width: 140)
                            .textFieldStyle(.roundedBorder)
                            .foregroundColor(HostValidator.isValidDomain(dnsTestDomain) ? nil : .red)
                    }
                    if !HostValidator.isValidDomain(dnsTestDomain) {
                        Text("Invalid domain (e.g. apple.com)")
                            .font(.caption2)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section("Timeouts (seconds)") {
                HStack {
                    Text("Ping timeout")
                    Spacer()
                    TextField("", value: $pingTimeout, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: pingTimeout) { _, v in pingTimeout = max(1, min(v, 30)) }
                }
                HStack {
                    Text("DNS timeout")
                    Spacer()
                    TextField("", value: $dnsTimeout, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: dnsTimeout) { _, v in dnsTimeout = max(1, min(v, 30)) }
                }
            }

            Section("Thresholds") {
                HStack {
                    Text("Latency good (ms)")
                    Spacer()
                    TextField("", value: $latencyGood, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: latencyGood) { _, v in
                            latencyGood = max(1, min(v, 9999))
                            latencyFair = min(max(latencyFair, latencyGood + 1), 10000)
                        }
                }
                HStack {
                    Text("Latency fair (ms)")
                    Spacer()
                    TextField("", value: $latencyFair, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: latencyFair) { _, v in latencyFair = min(max(latencyGood + 1, v), 10000) }
                }
                HStack {
                    Text("Jitter warning (ms)")
                    Spacer()
                    TextField("", value: $jitterWarn, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: jitterWarn) { _, v in jitterWarn = max(0.1, min(v, 1000)) }
                }
            }

            Section("Network Switch") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Grace period (pings)")
                        Spacer()
                        TextField("", value: $gracePings, format: .number)
                            .frame(width: 60)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: gracePings) { _, v in gracePings = max(1, min(v, 30)) }
                    }
                    Text("Number of consecutive failures before registering an incident. Prevents false alerts during VPN/WiFi switching.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Storage") {
                HStack {
                    Text("Retention (days)")
                    Spacer()
                    TextField("", value: retentionDays, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: retention) { _, v in retention = max(86400, min(v, 90 * 86400)) }
                }
                HStack {
                    Text("Notification cooldown (s)")
                    Spacer()
                    TextField("", value: $notifCooldown, format: .number)
                        .frame(width: 60)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: notifCooldown) { _, v in notifCooldown = max(5, min(v, 600)) }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Helpers

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Login item registration failed — silently ignore
        }
    }
}
