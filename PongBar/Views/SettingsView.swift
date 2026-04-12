//
//  SettingsView.swift
//  PongBar
//
//  Application settings window for configuring ping intervals, notifications, and preferences.
//

import SwiftUI
import ServiceManagement
import Security
import AppKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(NetworkMonitor.self) private var monitor
    @AppStorage("pingInterval") private var pingInterval: Double = 3.0
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("showPublicIP") private var showPublicIP: Bool = true
    @AppStorage("menuBarDisplayMode") private var menuBarDisplayMode: String = "dot"

    // Local network credentials
    @AppStorage("local.username") private var localUsername: String = ""
    @AppStorage("local.password") private var localPassword: String = ""
    @AppStorage("local.selectedDeviceIDs") private var localSelectedDeviceIDsRaw: String = ""
    @State private var localSelectedDeviceIDs: Set<String> = []

    // Notification toggles per target
    @AppStorage("notify.internet") private var notifyInternet: Bool = true
    @AppStorage("notify.router") private var notifyRouter: Bool = true
    @AppStorage("notify.dns") private var notifyDNS: Bool = true

    @State private var isLoadingSettings = false
    @State private var isShowingDevicePicker = false
    @State private var pendingRouterIP: String = ""
    @State private var localUsernameDraft: String = ""
    @State private var localPasswordDraft: String = ""

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

            localNetworkTab
                .tabItem { Label("Local Network", systemImage: "person.badge.key") }

            dnsTab
                .tabItem { Label("DNS", systemImage: "server.rack") }

            dataTab
                .tabItem { Label("Data", systemImage: "externaldrive") }

            advancedTab
                .tabItem { Label("Advanced", systemImage: "slider.horizontal.3") }
        }
        .frame(width: 680, height: 380)
        .task {
            await loadSettings()
        }
        .overlay {
            if isLoadingSettings { ProgressView() }
        }
    }

    @MainActor
    private func loadSettings() async {
        guard !isLoadingSettings else { return }
        isLoadingSettings = true
        defer { isLoadingSettings = false }

        // Replace the old DispatchGroup-based parallel work with structured concurrency.
        // If the original code was launching multiple reads (e.g., from different sources), use a task group:
        await withTaskGroup(of: Void.self) { group in
            // Example placeholders: replace with the concrete read tasks that previously used readGroup.enter/leave
            // group.addTask { await readUserDefaults() }
            // group.addTask { await readRemoteConfig() }
            // group.addTask { await readKeychain() }
        }

        // After all tasks complete, assign results to @State or model objects as needed.
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
                Toggle("Show public IP (via ifconfig.co / ident.me )", isOn: $showPublicIP)
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
                    Text("Dot + Speed").tag("dotSpeed")
                    Text("Dot + Loss %").tag("dotLoss")
                }
                .pickerStyle(.radioGroup)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Local Network

    private var localNetworkTab: some View {
        Form {
            Section("Credentials") {
                HStack(alignment: .center, spacing: 12) {
                    VStack(spacing: 8) {
                        HStack(spacing: 10) {
                            Text("Username")
                                .font(.body.weight(.medium))
                                .frame(width: 90, alignment: .leading)
                            TextField("Router username", text: $localUsernameDraft)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.username)
                                .disableAutocorrection(true)
                        }

                        HStack(spacing: 10) {
                            Text("Password")
                                .font(.body.weight(.medium))
                                .frame(width: 90, alignment: .leading)
                            SecureField("Router password", text: $localPasswordDraft)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.password)
                        }

                        if !localPassword.isEmpty {
                            HStack {
                                Text("Stored")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(repeating: "•", count: max(6, min(localPassword.count, 16))))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Spacer()
                            }
                        }
                    }

                    Button("Save") {
                        localUsername = localUsernameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                        localPassword = localPasswordDraft
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(localUsernameDraft == localUsername && localPasswordDraft == localPassword)
                }
            }

            Section("Devices to Monitor") {
                HStack {
                    Button {
                        pendingRouterIP = "192.168.178.1"
                        isShowingDevicePicker = true
                    } label: {
                        Label("Add Device", systemImage: "plus.circle")
                    }

                    Spacer()
                    Text("\(monitor.localDevices.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if monitor.localDevices.isEmpty {
                    Text("No local devices configured yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LocalDevicesEditor()
                        .frame(minHeight: 110, maxHeight: 210)
                }
            }
            .sheet(isPresented: $isShowingDevicePicker) {
                LocalDevicePickerView(routerIP: pendingRouterIP) { selected in
                    var updated = monitor.localDevices
                    if !updated.contains(where: { $0.macAddress == selected.macAddress }) {
                        updated.append(selected)
                        monitor.saveLocalDevices(updated)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            localUsernameDraft = localUsername
            localPasswordDraft = localPassword
            let raw = localSelectedDeviceIDsRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty { localSelectedDeviceIDs = [] }
            else { localSelectedDeviceIDs = Set(raw.split(separator: ",").map(String.init)) }
        }
        .onChange(of: localSelectedDeviceIDs) { _, newValue in
            localSelectedDeviceIDsRaw = newValue.joined(separator: ",")
        }
        .onChange(of: monitor.localDevices) { _, newDevices in
            let valid = Set(newDevices.map { $0.id.uuidString })
            localSelectedDeviceIDs = localSelectedDeviceIDs.intersection(valid)
        }
    }

    // Minimal helper to avoid complex inline closures in the view builder
    private func bindingForDevice(id deviceID: String) -> Binding<Bool> {
        Binding<Bool>(
            get: { localSelectedDeviceIDs.contains(deviceID) },
            set: { newValue in
                if newValue {
                    localSelectedDeviceIDs.insert(deviceID)
                } else {
                    localSelectedDeviceIDs.remove(deviceID)
                }
            }
        )
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

private struct LocalDevicesEditor: View {
    @Environment(NetworkMonitor.self) private var monitor
    @State private var draggedDeviceID: UUID?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(monitor.localDevices) { device in
                    LocalDeviceSettingsRow(
                        device: device,
                        result: monitor.localResults[device.id],
                        sparklineData: monitor.localLatencyHistory[device.id] ?? []
                    ) {
                        draggedDeviceID = device.id
                        return NSItemProvider(object: device.id.uuidString as NSString)
                    }
                    .onDrop(
                        of: [UTType.text],
                        delegate: LocalDeviceDropDelegate(
                            targetDevice: device,
                            devices: monitor.localDevices,
                            draggedDeviceID: $draggedDeviceID,
                            onMove: moveDevices
                        )
                    )
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func moveDevices(from source: IndexSet, to destination: Int) {
        var updated = monitor.localDevices
        updated.move(fromOffsets: source, toOffset: destination)
        monitor.saveLocalDevices(updated)
    }
}

private struct LocalDeviceDropDelegate: DropDelegate {
    let targetDevice: LocalNetworkDevice
    let devices: [LocalNetworkDevice]
    @Binding var draggedDeviceID: UUID?
    let onMove: (IndexSet, Int) -> Void

    func dropEntered(info: DropInfo) {
        guard let draggedDeviceID,
              draggedDeviceID != targetDevice.id,
              let fromIndex = devices.firstIndex(where: { $0.id == draggedDeviceID }),
              let toIndex = devices.firstIndex(where: { $0.id == targetDevice.id })
        else {
            return
        }

        if devices[toIndex].id != draggedDeviceID {
            onMove(IndexSet(integer: fromIndex), toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        draggedDeviceID = nil
        return true
    }
}

private struct LocalDeviceSettingsRow: View {
    @Environment(NetworkMonitor.self) private var monitor
    let device: LocalNetworkDevice
    let result: PingResult?
    let sparklineData: [Double?]
    let onDragStart: () -> NSItemProvider

    @State private var isEditingName = false
    @State private var nameDraft = ""
    @State private var isSymbolPickerShown = false

    private let symbolOptions = [
        "desktopcomputer", "laptopcomputer", "iphone", "ipad", "tv.fill", "applewatch",
        "gamecontroller.fill", "printer.fill", "hifispeaker.fill", "airpodspro", "wifi.router", "camera.fill"
    ]

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .onDrag(onDragStart)
                .help("Drag to reorder")

            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Button {
                isSymbolPickerShown.toggle()
            } label: {
                Image(systemName: device.symbolName)
                    .frame(width: 18, height: 18)
                    .foregroundStyle(.primary)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $isSymbolPickerShown, arrowEdge: .bottom) {
                DeviceSymbolPicker(
                    selectedSymbol: device.symbolName,
                    symbols: symbolOptions,
                    onSelect: { symbol in
                        saveSymbol(symbol)
                        isSymbolPickerShown = false
                    },
                    onOpenSFSymbolsApp: {
                        let opened = openSFSymbolsApp()
                        if opened {
                            isSymbolPickerShown = false
                        }
                        return opened
                    }
                )
            }

            if isEditingName {
                TextField("Device name", text: $nameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commitName)
                    .onAppear {
                        if nameDraft.isEmpty {
                            nameDraft = device.displayName
                        }
                    }
            } else {
                HStack(spacing: 4) {
                    Text(device.displayName)
                        .lineLimit(1)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(device.ipAddress)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .onTapGesture {
                    nameDraft = device.displayName
                    withAnimation(.easeInOut(duration: 0.15)) {
                        isEditingName = true
                    }
                }
            }

            Spacer()

            Toggle("Use Ping", isOn: Binding(
                get: { device.usePing },
                set: { newValue in
                    setUsePing(newValue)
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Button {
                removeDevice()
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Remove device")
        }
        .padding(.vertical, 2)
    }

    private var statusColor: Color {
        guard let result else { return .secondary }
        return result.isReachable ? .green : .red
    }

    private func commitName() {
        let sanitized = sanitizeName(nameDraft)
        saveName(sanitized)
        withAnimation(.easeInOut(duration: 0.15)) {
            isEditingName = false
        }
    }

    private func sanitizeName(_ value: String) -> String {
        let cleaned = value
            .components(separatedBy: .controlCharacters)
            .joined()
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(cleaned.prefix(40))
    }

    private func saveName(_ value: String) {
        guard let index = monitor.localDevices.firstIndex(where: { $0.id == device.id }) else { return }
        var updated = monitor.localDevices
        updated[index].customName = value
        monitor.saveLocalDevices(updated)
    }

    private func saveSymbol(_ symbol: String) {
        let sanitized = sanitizeSymbolName(symbol)
        guard !sanitized.isEmpty,
              let index = monitor.localDevices.firstIndex(where: { $0.id == device.id })
        else {
            return
        }
        var updated = monitor.localDevices
        updated[index].symbolName = sanitized
        monitor.saveLocalDevices(updated)
    }

    private func sanitizeSymbolName(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
    }

    private func setUsePing(_ enabled: Bool) {
        guard let index = monitor.localDevices.firstIndex(where: { $0.id == device.id }) else { return }
        var updated = monitor.localDevices
        updated[index].usePing = enabled
        monitor.saveLocalDevices(updated)
    }

    private func removeDevice() {
        var updated = monitor.localDevices
        updated.removeAll { $0.id == device.id }
        monitor.saveLocalDevices(updated)
    }

    private func openSFSymbolsApp() -> Bool {
        let fileManager = FileManager.default
        let appPaths = [
            "/Applications/SF-Symbole.app",
            "/System/Applications/SF-Symbole.app"
        ]

        guard let matchedPath = appPaths.first(where: { fileManager.fileExists(atPath: $0) }) else {
            return false
        }

        let appURL = URL(fileURLWithPath: matchedPath)
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: appURL, configuration: configuration) { _, _ in }
        return true
    }
}

private struct DeviceSymbolPicker: View {
    let selectedSymbol: String
    let symbols: [String]
    let onSelect: (String) -> Void
    let onOpenSFSymbolsApp: () -> Bool

    @State private var customSymbolName: String
    @State private var appOpenError: String?

    private let columns = [GridItem(.adaptive(minimum: 28, maximum: 36), spacing: 8)]

    init(
        selectedSymbol: String,
        symbols: [String],
        onSelect: @escaping (String) -> Void,
        onOpenSFSymbolsApp: @escaping () -> Bool
    ) {
        self.selectedSymbol = selectedSymbol
        self.symbols = symbols
        self.onSelect = onSelect
        self.onOpenSFSymbolsApp = onOpenSFSymbolsApp
        _customSymbolName = State(initialValue: selectedSymbol)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Choose Symbol")
                .font(.headline)

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(symbols, id: \.self) { symbol in
                    Button {
                        onSelect(symbol)
                    } label: {
                        Image(systemName: symbol)
                            .frame(width: 28, height: 24)
                            .foregroundStyle(symbol == selectedSymbol ? .white : .primary)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(symbol == selectedSymbol ? Color.accentColor : Color.clear)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            HStack(spacing: 8) {
                TextField("Custom symbol name", text: $customSymbolName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(applyCustomSymbol)
                Button("Apply") {
                    applyCustomSymbol()
                }
                .buttonStyle(.bordered)
            }

            Divider()

            Button {
                if !onOpenSFSymbolsApp() {
                    appOpenError = "SF-Symbole.app not found."
                } else {
                    appOpenError = nil
                }
            } label: {
                Label("Open SF-Symbole.app", systemImage: "square.grid.2x2")
            }
            .buttonStyle(.plain)

            if let appOpenError {
                Text(appOpenError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(10)
        .frame(width: 260)
    }

    private func applyCustomSymbol() {
        let sanitized = customSymbolName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }

        guard !sanitized.isEmpty else { return }
        customSymbolName = sanitized
        onSelect(sanitized)
    }
}

#Preview("SettingsView") {
    let monitor = NetworkMonitor()
    // Keep it static for previews
    monitor.stop()

    return SettingsView()
        .environment(monitor)
        .frame(width: 480, height: 380)
}
