//
//  MainStatusView.swift
//  PongBar
//
//  Primary status view showing all targets, uptime, and navigation to history.
//

import SwiftUI
import AppKit

struct MainStatusView: View {
    @Environment(NetworkMonitor.self) private var monitor
    var navigate: (PopoverPage) -> Void
    @State private var isShowingTR064Debug = false
    @State private var isTR064DebugLoading = false
    @State private var tr064DebugOutput = ""
    @AppStorage("networkMap.traceTargetInput") private var traceTargetInput = ""
    @State private var isResolvingTraceTarget = false
    @FocusState private var isTraceTargetFieldFocused: Bool
    @State private var dectRingCandidate: DECTDevice?
    @State private var dectRingProcessDevice: DECTDevice?
    @State private var isShowingDECTRingProcess = false
    @State private var isDECTRingRunning = false
    @State private var dectRingLogOutput = ""
    @State private var dectRingTask: Task<Void, Never>?
    @State private var isShowingQuitConfirmation = false

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

            Divider()
                .padding(.vertical, 4)

            tracerouteInputRow

            Divider()
                .padding(.vertical, 4)

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
            if !monitor.localDevices.isEmpty {
                HStack(spacing: 8) {
                    Text("")
                        .frame(width: 14)
                    Text("")
                        .frame(width: 20)
                    Text("Device")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Ping")
                        .frame(width: 48, alignment: .trailing)
                    Text("Signal")
                        .frame(width: 56, alignment: .trailing)
                    Text("Mbit/s")
                        .frame(width: 60, alignment: .trailing)
                    Text("")
                        .frame(width: 12)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
                
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(monitor.localDevices) { device in
                            let currentDeviceIP = monitor.interfaceInfo?.ipAddress?.trimmingCharacters(in: .whitespacesAndNewlines)
                            let deviceIP = (monitor.localResults[device.id]?.detail ?? device.ipAddress).trimmingCharacters(in: .whitespacesAndNewlines)
                            let isCurrentDevice = currentDeviceIP != nil && !deviceIP.isEmpty && currentDeviceIP == deviceIP
                            let hasKnownIP = !deviceIP.isEmpty
                            Button {
                                navigate(.localDeviceSpeedDetail(device))
                            } label: {
                                LocalDeviceRowView(
                                    device: device,
                                    result: monitor.localResults[device.id],
                                    speedMbps: monitor.localSpeeds[device.id],
                                    signalStrengthPercent: monitor.localSignalStrengths[device.id],
                                    activeBand: monitor.localBands[device.id],
                                    supportedBands: device.supportedBands,
                                    showStatusIndicator: !isCurrentDevice,
                                    showDisclosure: true,
                                    isCurrentDevice: isCurrentDevice,
                                    isWANBlocked: monitor.isLocalDeviceWANBlocked(device)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if !isCurrentDevice {
                                    if monitor.isLocalDeviceWANBlocked(device) {
                                        Button("Enable Wifi access") {
                                            Task {
                                                await monitor.setLocalDeviceWANAccess(device, blocked: false)
                                            }
                                        }
                                        .disabled(!hasKnownIP)
                                    } else {
                                        Button("Disable Wifi access") {
                                            Task {
                                                await monitor.setLocalDeviceWANAccess(device, blocked: true)
                                            }
                                        }
                                        .disabled(!hasKnownIP)
                                    }
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 250)
                .fixedSize(horizontal: false, vertical: true)
            }

            // DECT Devices
            Divider()
                .padding(.vertical, 4)

            HStack(spacing: 8) {
                Text("")
                    .frame(width: 14)
                Text("")
                    .frame(width: 20)
                Text("DECT Device")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Numbers")
                    .frame(width: 180, alignment: .trailing)
                Text("")
                    .frame(width: 12)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.bottom, 2)

            if monitor.dectDevices.isEmpty {
                HStack(spacing: 8) {
                    Text("")
                        .frame(width: 14)
                    Text("")
                        .frame(width: 20)
                    Text("No DECT devices found")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("")
                        .frame(width: 180)
                    Text("")
                        .frame(width: 12)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            } else {
                ForEach(monitor.dectDevices) { device in
                    Button {
                        dectRingCandidate = device
                    } label: {
                        HStack(spacing: 8) {
                            DECTStatusIndicatorView(device: device)
                                .frame(width: 14)

                            Image(systemName: device.isInCall ? "waveform.and.mic" : "candybarphone")
                                .frame(width: 20)
                                .foregroundStyle(device.isInCall ? Color.yellow : Color.secondary)

                            Text(device.name)
                                .font(.body)
                                .lineLimit(1)
                                .truncationMode(.tail)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Text(numberSummary(for: device))
                                .font(.system(.body, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 180, alignment: .trailing)

                            Text("")
                                .frame(width: 12)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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

        }
        .overlay {
            if isShowingTR064Debug {
                ZStack {
                    Color.black.opacity(0.08)
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

            if isShowingDECTRingProcess {
                ZStack {
                    Color.black.opacity(0.08)
                        .ignoresSafeArea()

                    DECTRingProcessSheetView(
                        isRunning: isDECTRingRunning,
                        output: dectRingLogOutput,
                        onCancel: {
                            Task { await cancelDECTRingProcess() }
                        },
                        onOK: {
                            isShowingDECTRingProcess = false
                            dectRingProcessDevice = nil
                            dectRingLogOutput = ""
                        },
                        onRetry: {
                            Task { await retryDECTRingProcess() }
                        }
                    )
                    .padding(12)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
        .onAppear {
            isTraceTargetFieldFocused = false
        }
        .onDisappear {
            isShowingTR064Debug = false
            isTraceTargetFieldFocused = false
            dectRingTask?.cancel()
            dectRingTask = nil
            isDECTRingRunning = false
        }
        .alert(
            "Find/ring phone?",
            isPresented: Binding(
                get: { dectRingCandidate != nil },
                set: { if !$0 { dectRingCandidate = nil } }
            ),
            presenting: dectRingCandidate
        ) { device in
            Button("Cancel", role: .cancel) {
                dectRingCandidate = nil
            }
            Button("Ring") {
                beginDECTRingProcess(for: device)
            }
        } message: { device in
            Text("Trigger ringing for \(device.name)?")
        }
        .alert("Really quit?", isPresented: $isShowingQuitConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("OK", role: .destructive) {
                NSApp.terminate(nil)
            }
        }
    }

    private func numberSummary(for device: DECTDevice) -> String {
        let internalNumber = device.internalNumber ?? "---"
        let externalNumber = device.externalNumber ?? "---"
        return "\(internalNumber) / \(externalNumber)"
    }

    @MainActor
    private func appendDECTRingLog(_ line: String) {
        if !dectRingLogOutput.isEmpty {
            dectRingLogOutput += "\n"
        }
        dectRingLogOutput += line
    }

    private func beginDECTRingProcess(for device: DECTDevice) {
        dectRingCandidate = nil
        dectRingProcessDevice = device
        isShowingDECTRingProcess = true
        dectRingLogOutput = ""
        startDECTRingTask(for: device)
    }

    private func startDECTRingTask(for device: DECTDevice) {
        guard !isDECTRingRunning else { return }
        isDECTRingRunning = true
        appendDECTRingLog("[START] DECT ring process")

        let task = Task {
            do {
                try await monitor.ringDECTDevice(device) { line in
                    appendDECTRingLog(line)
                }
                appendDECTRingLog("[DONE] Ring process completed.")
            } catch is CancellationError {
                appendDECTRingLog("[CANCELLED] Process cancelled.")
            } catch {
                appendDECTRingLog("[ERROR] \(error.localizedDescription)")
            }
            await MainActor.run {
                isDECTRingRunning = false
                dectRingTask = nil
            }
        }

        dectRingTask = task
    }

    private func cancelDECTRingProcess() async {
        if isDECTRingRunning {
            appendDECTRingLog("[ACTION] Cancel requested...")
            dectRingTask?.cancel()
        }
        await monitor.hangupDECTCall { line in
            appendDECTRingLog(line)
        }
    }

    private func retryDECTRingProcess() async {
        guard !isDECTRingRunning, let device = dectRingProcessDevice else { return }
        appendDECTRingLog("[RETRY] Re-initiating ring process...")
        startDECTRingTask(for: device)
    }

    private var headerRow: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("PingPong Network Monitor")
                    .font(.headline)
                Spacer()
                HStack(spacing: 6) {
                    ControlGroup {
                        Button {
                            AppContainer.settingsWindowController.show()
                        } label: {
                            Label("Settings", systemImage: "gearshape")
                                .labelStyle(.iconOnly)
                        }
                        .help("Open settings")

                        Button {
                            isShowingQuitConfirmation = true
                        } label: {
                            Label("Quit", systemImage: "xmark.circle")
                                .labelStyle(.iconOnly)
                        }
                        .help("Quit PingPong")
                    }
                    .controlSize(.small)

                    Button {
                        runTR064Debug()
                    } label: {
                        Label("TR-064 Debug", systemImage: "house.badge.wifi.fill")
                            .labelStyle(.iconOnly)
                    }
                    .controlSize(.small)
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

    private var tracerouteInputRow: some View {
        HStack(spacing: 8) {
            Text("Traceroute to")
                .font(.body)

            TextField("google.com", text: $traceTargetInput)
                .textFieldStyle(.roundedBorder)
                .focused($isTraceTargetFieldFocused)
                .onSubmit {
                    runTraceFromInput()
                }

            Button("Trace") {
                runTraceFromInput()
            }
            .buttonStyle(.bordered)
            .disabled(isResolvingTraceTarget)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func runTraceFromInput() {
        guard !isResolvingTraceTarget else { return }
        isResolvingTraceTarget = true

        Task {
            let sanitized = sanitizeTraceInput(traceTargetInput)
            let primaryResolved = await resolveTargetIPAddress(for: sanitized)
            let fallbackResolved = await resolveTargetIPAddress(for: "google.com")
            let resolvedIP = primaryResolved ?? fallbackResolved ?? "google.com"

            await MainActor.run {
                traceTargetInput = sanitized
                isResolvingTraceTarget = false
                isTraceTargetFieldFocused = false
                navigate(.networkMap(resolvedIP))
            }
        }
    }

    private func sanitizeTraceInput(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "google.com" }

        if let url = URL(string: trimmed),
           let host = url.host,
           HostValidator.isValid(host) {
            return host
        }

        if HostValidator.isValid(trimmed) {
            return trimmed
        }

        return "google.com"
    }

    private func resolveTargetIPAddress(for host: String) async -> String? {
        if HostValidator.isValidIPAddress(host) {
            return host
        }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: resolveTargetIPAddressSync(for: host))
            }
        }
    }

    private func resolveTargetIPAddressSync(for host: String) -> String? {
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        hints.ai_family = AF_UNSPEC

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return nil
        }
        defer { freeaddrinfo(result) }

        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let current = ptr {
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let status = getnameinfo(
                current.pointee.ai_addr,
                current.pointee.ai_addrlen,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if status == 0 {
                return String(cString: hostBuffer)
            }
            ptr = current.pointee.ai_next
        }

        return nil
    }

    private func runTR064Debug() {
        isShowingTR064Debug = true
        isTR064DebugLoading = true
        tr064DebugOutput = "Starting TR-064 debug..."

        Task {
            let output = await buildTR064DebugOutput { partialOutput in
                await MainActor.run {
                    tr064DebugOutput = partialOutput
                }
            }
            await MainActor.run {
                tr064DebugOutput = output
                isTR064DebugLoading = false
            }
        }
    }

    private func buildTR064DebugOutput(
        onUpdate: @escaping @Sendable (String) async -> Void
    ) async -> String {
        let startedAt = Date()
        let account = UserDefaults.standard.string(forKey: "local.username")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = UserDefaults.standard.string(forKey: "local.password")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let credentialsPresent = !account.isEmpty && !password.isEmpty

        let routerIP = guessedRouterIP(from: monitor.gatewayIP)
        var lines: [String] = []
        var rawLines: [String] = []

        func emit() async {
            await onUpdate(lines.joined(separator: "\n"))
        }

        func addLine(_ line: String, addToRaw: Bool = true) async {
            lines.append(line)
            if addToRaw {
                rawLines.append(line)
            }
            await emit()
        }

        await addLine("[START] TR-064 debug")
        await addLine("Router IP used: \(routerIP)")
        await addLine("Gateway reported by app: \(monitor.gatewayIP)")
        await addLine("Credentials present: \(credentialsPresent ? "yes" : "no")")

        guard credentialsPresent else {
            await addLine("Error: Missing local TR-064 credentials (local.username / local.password).")
            appendMacMatchLines(into: &lines, map: [:])
            lines.append("")
            lines.append("Summary:")
            lines.append("- TR-064 debug did not run because credentials are missing.")
            lines.append("")
            lines.append("Full Response Text:")
            lines.append(rawLines.joined(separator: "\n"))
            await emit()
            return lines.joined(separator: "\n")
        }

        var map: [String: (active: Bool, ip: String?)] = [:]
        var fullHostList: [LocalNetworkDevice] = []
        var successAttempt: Int?
        var lastError: String?
        let backoff: [Duration] = [.milliseconds(500), .seconds(1), .seconds(2)]

        for (index, delay) in backoff.enumerated() {
            let attempt = index + 1
            await addLine("Attempt \(attempt)/\(backoff.count): querying TR-064 host list (device-picker flow)...")

            let attemptStarted = Date()
            do {
                let service = FritzBoxTR064Service()
                let devices = try await service.fetchConnectedDevices(
                    routerIP: routerIP,
                    username: account,
                    password: password
                )
                let elapsed = Date().timeIntervalSince(attemptStarted)
                fullHostList = devices.sorted(by: { $0.originalName < $1.originalName })
                map = Dictionary(uniqueKeysWithValues: fullHostList.map {
                    (
                        $0.macAddress
                            .lowercased()
                            .replacingOccurrences(of: "-", with: ":"),
                        (active: true, ip: $0.ipAddress)
                    )
                })
                successAttempt = attempt
                await addLine("Attempt \(attempt): host list has \(fullHostList.count) active entries (success)")
                await addLine(String(format: "Attempt \(attempt): duration %.2fs", elapsed))
                break
            } catch {
                let elapsed = Date().timeIntervalSince(attemptStarted)
                lastError = error.localizedDescription
                await addLine("Attempt \(attempt): host list failed - error: \(error.localizedDescription)")
                await addLine(String(format: "Attempt \(attempt): duration %.2fs", elapsed))
                if index < backoff.count - 1 {
                    await addLine("Attempt \(attempt): waiting before retry...")
                    try? await Task.sleep(for: delay)
                }
            }
        }

        await addLine("")
        await addLine("Host List Overview (from device-picker flow):")
        if fullHostList.isEmpty {
            await addLine("- No active host entries returned")
        } else {
            for host in fullHostList {
                await addLine("- name=\(host.originalName), mac=\(host.macAddress), ip=\(host.ipAddress), active=1")
            }
        }

        await addLine("")
        await addLine("Selected Device Query (MAC/IP/Name + NewX_AVM-DE_Speed / NewX_AVM-DE_SignalStrength / NewX_AVM-DE_Mesh):")
        if monitor.localDevices.isEmpty {
            await addLine("- No local devices configured")
        } else {
            let detailStarted = Date()
            for device in monitor.localDevices {
                let state = localMapEntry(for: device.macAddress, in: map)
                let hostFromList = fullHostList.first(where: {
                    $0.macAddress.lowercased().replacingOccurrences(of: "-", with: ":")
                    == device.macAddress.lowercased().replacingOccurrences(of: "-", with: ":")
                })
                let attrs = await TR064HostService.fetchHostDebugAttributes(
                    routerIP: routerIP,
                    username: account,
                    password: password,
                    macAddress: device.macAddress,
                    ipAddress: state?.ip ?? hostFromList?.ipAddress
                )
                let activeText = state?.active == true ? "online" : "offline"
                let speedTextFromTag = attrs.speed.flatMap { Double($0) }.map(Formatters.localDeviceSpeed) ?? attrs.speed
                let effectiveSpeedText = speedTextFromTag
                    ?? "---"
                await addLine("- \(device.displayName) [\(device.macAddress)] -> \(activeText)")
                await addLine("  name=\(attrs.name ?? hostFromList?.originalName ?? "n/a"), mac=\(attrs.mac ?? device.macAddress), ip=\(attrs.ip ?? state?.ip ?? hostFromList?.ipAddress ?? "n/a")")
                await addLine("  NewX_AVM-DE_Speed=\(effectiveSpeedText), NewX_AVM-DE_SignalStrength=\(attrs.signalStrength ?? "---"), NewX_AVM-DE_Mesh=\(attrs.mesh ?? "---")")
                await addLine("  sourceAction=\(attrs.sourceAction), interface=\(attrs.interfaceType ?? "n/a"), active=\(attrs.active ?? "n/a"), diag=\(attrs.diagnostic)")
            }
            let detailElapsed = Date().timeIntervalSince(detailStarted)
            await addLine(String(format: "- Per-device attribute query duration: %.2fs", detailElapsed))
        }

        await addLine("")
        await addLine("Result Summary:")
        if let successAttempt {
            await addLine("- Map empty: no")
            await addLine("- Succeeded on attempt: \(successAttempt)")
            await addLine("- Host entries: \(map.count)")
        } else {
            await addLine("- Map empty: yes")
            await addLine("- Failed after attempts: \(backoff.count)")
            if let lastError, !lastError.isEmpty {
                await addLine("- Error: \(lastError)")
            } else {
                await addLine("- Error: TR-064 returned no host map (empty or unreachable/invalid response).")
            }
        }

        appendMacMatchLines(into: &lines, map: map)

        let totalElapsed = Date().timeIntervalSince(startedAt)
        lines.append("")
        lines.append(String(format: "Total debug duration: %.2fs", totalElapsed))
        lines.append("")
        lines.append("Full Response Text:")
        lines.append(rawLines.joined(separator: "\n"))

        await emit()
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

    private func localMapEntry<T>(for macAddress: String, in map: [String: T]) -> T? {
        let key1 = macAddress.lowercased()
        let key2 = key1.replacingOccurrences(of: "-", with: ":")
        let key3 = key1.replacingOccurrences(of: ":", with: "-")
        let key4 = key1.replacingOccurrences(of: ":", with: "")
        return map[key1] ?? map[key2] ?? map[key3] ?? map[key4]
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
        PopoverOverlayCard {
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
            ScrollView(.vertical) {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
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
    }
}

private struct DECTRingProcessSheetView: View {
    let isRunning: Bool
    let output: String
    let onCancel: () -> Void
    let onOK: () -> Void
    let onRetry: () -> Void

    var body: some View {
        PopoverOverlayCard {
            HStack {
                Text("Ring Phone")
                    .font(.headline)
                Spacer()
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            ScrollView {
                Text(output)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(10)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )

            HStack {
                Button("Cancel") {
                    onCancel()
                }
                Spacer()
                Button("Retry") {
                    onRetry()
                }
                .disabled(isRunning)
                Button("OK") {
                    onOK()
                }
                .disabled(isRunning)
            }
        }
    }
}

private struct DECTStatusIndicatorView: View {
    let device: DECTDevice
    @State private var isPulsing = false

    var body: some View {
        Group {
            if device.isInCall {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.yellow)
                    .scaleEffect(isPulsing ? 1.15 : 0.9)
                    .opacity(isPulsing ? 1.0 : 0.65)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                            isPulsing = true
                        }
                    }
            } else {
                Circle()
                    .fill(device.active ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 14, height: 14)
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
