//
//  NetworkMonitor.swift
//  PingPongBar
//
//  Central orchestrator: runs ping checks on a timer, delegates metrics
//  to MetricsEngine and incidents to IncidentManager.
//

import SwiftUI
import Network

/// Observable network monitor that drives the entire app state.
@MainActor
@Observable
final class NetworkMonitor {
    // MARK: - Sub-engines

    let metrics = MetricsEngine()
    let incidentManager = IncidentManager()
    let throughput = ThroughputEngine()

    // MARK: - Current Status

    /// Latest result for each target.
    var currentResults: [PingTarget: PingResult] = [:]

    /// The current gateway IP address.
    var gatewayIP: String = "..."

    /// Whether the monitor is running.
    var isRunning = false

    /// Current network path status from NWPathMonitor.
    var networkPathStatus: NWPath.Status = .unsatisfied

    /// Active network interface information.
    var interfaceInfo: NetworkInterfaceInfo?

    /// Public-facing IP address.
    var publicIP: String?

    /// Active DNS server IP.
    var activeDNSServer: String?

    /// Ping result to public IP (VPN server latency).
    var publicIPPingResult: PingResult?

    /// Public IP latency history for sparkline.
    var publicIPLatencyHistory: [Double?] = []

    /// Whether VPN is currently detected (utun/ipsec/ppp interface active).
    var isVPNDetected: Bool = false

    // MARK: - Custom Targets

    var customTargets: [CustomTarget] = []
    var customResults: [UUID: PingResult] = [:]
    var customLatencyHistory: [UUID: [Double?]] = [:]

    // MARK: - Local Network Devices
    var localDevices: [LocalNetworkDevice] = []
    var localResults: [UUID: PingResult] = [:]
    var localSpeeds: [UUID: Double] = [:]
    var localSignalStrengths: [UUID: Int] = [:]
    var localBands: [UUID: String] = [:]
    var localWANBlockedByMAC: [String: Bool] = [:]
    var hasCompletedInitialLocalDeviceRefresh = false
    var dectDevices: [DECTDevice] = []
    var builtInLastUpdatedAt: Date?
    var localDeviceLastUpdatedAt: Date?
    var dectLastUpdatedAt: Date?

    // MARK: - Configuration

    var pingInterval: TimeInterval
    var localDeviceSpeedInterval: TimeInterval

    var pauseDuringSleep: Bool {
        get { UserDefaults.standard.object(forKey: Config.Keys.pauseDuringSleep) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Config.Keys.pauseDuringSleep) }
    }

    // MARK: - Private

    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "PingPongBar.NWPathMonitor")
    private var isChecking = false
    private var isSuspended = false
    private var checkCycleCount = 0
    private var pathUpdateTask: Task<Void, Never>?
    private var lastInterfaceName: String?
    private var localDeviceRefreshTask: Task<Void, Never>?
    private var localDeviceTimer: Timer?
    private var dectCallTimer: Timer?
    private var isRefreshingDECT = false
    private var isDECTRingOperationInProgress = false

    private let dectPollOffsetSeconds: TimeInterval = 3

    // MARK: - Computed

    var overallStatusColor: Color {
        let results = Array(currentResults.values)
        guard !results.isEmpty else { return .secondary }

        let reachableCount = results.filter(\.isReachable).count
        if reachableCount == results.count { return .green }
        if reachableCount == 0 { return .red }
        if currentResults[.router]?.isReachable == false { return .red }
        if currentResults[.internet]?.isReachable == false { return .orange }
        return .yellow
    }

    // MARK: - Lifecycle

    init() {
        self.pingInterval = Config.pingInterval
        self.localDeviceSpeedInterval = Config.localDeviceSpeedInterval
        customTargets = CustomTargetStore.load()
        localDevices = LocalNetworkDeviceStore.load()
        localWANBlockedByMAC = loadLocalWANBlockedByMAC()
        LocalDeviceSpeedStorage.shared.syncSelectedDevices(localDevices)
        startPathMonitor()
        NotificationService.requestPermission()
        start()

        Task {
            await incidentManager.load()
            publicIP = await PublicIPService.fetch()
        }

        // Save on quit (synchronous)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.incidentManager.saveAll()
            }
            SQLiteStorage.shared.flushSync()
        }

        // Sleep/wake
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pauseDuringSleep else { return }
                self.isSuspended = true
                self.stop()
                self.pathMonitor?.cancel()
                self.pathMonitor = nil
            }
        }
        ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.pauseDuringSleep, self.isSuspended else { return }
                try? await Task.sleep(for: .seconds(Config.wakeDelay))
                guard self.isSuspended else { return }
                self.isSuspended = false
                self.throughput.reset()
                self.startPathMonitor()
                self.start()
            }
        }
    }

    nonisolated deinit {}

    func start() {
        guard !isRunning else { return }
        isRunning = true
        Task { await performChecks() }
        Task { await refreshLocalDeviceSpeeds() }
        // Startup: refresh DECT with offset and full inventory refresh.
        scheduleInitialDECTRefresh(forceInventoryRefresh: true)
        // Create timer without auto-scheduling, add only to .common mode
        // so it fires exactly once per interval even during scroll/tracking events.
        let t = Timer(timeInterval: pingInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.performChecks() }
        }
        RunLoop.current.add(t, forMode: .common)
        timer = t
        startLocalDeviceTimer()
        startDECTTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        localDeviceTimer?.invalidate()
        localDeviceTimer = nil
        dectCallTimer?.invalidate()
        dectCallTimer = nil
        isRunning = false
    }

    func restartLocalDeviceSpeedMonitoring() {
        localDeviceTimer?.invalidate()
        localDeviceTimer = nil
        dectCallTimer?.invalidate()
        dectCallTimer = nil
        guard isRunning else { return }
        startLocalDeviceTimer()
        startDECTTimer()
        Task { await refreshLocalDeviceSpeeds() }
        scheduleInitialDECTRefresh(forceInventoryRefresh: false)
    }

    private func startLocalDeviceTimer() {
        let t = Timer(timeInterval: localDeviceSpeedInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.refreshLocalDeviceSpeeds() }
        }
        RunLoop.current.add(t, forMode: .common)
        localDeviceTimer = t
    }

    private func startDECTTimer() {
        let t = Timer(timeInterval: localDeviceSpeedInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in
                guard let self else { return }
                try? await Task.sleep(for: .seconds(self.dectPollOffsetSeconds))
                await self.refreshDECTDevices(forceInventoryRefresh: false)
            }
        }
        RunLoop.current.add(t, forMode: .common)
        dectCallTimer = t
    }

    private func scheduleInitialDECTRefresh(forceInventoryRefresh: Bool) {
        Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(self.dectPollOffsetSeconds))
            await self.refreshDECTDevices(forceInventoryRefresh: forceInventoryRefresh)
        }
    }

    // MARK: - NWPathMonitor

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self, !self.isSuspended else { return }
                self.pathUpdateTask?.cancel()
                self.pathUpdateTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled, let self, !self.isSuspended else { return }

                    GatewayService.needsRefresh = true
                    self.networkPathStatus = path.status

                    let freshInfo = NetworkInterfaceService.getActiveInterface()
                    let newIfaceName = freshInfo?.interfaceName
                    if newIfaceName != self.lastInterfaceName {
                        self.incidentManager.resetFailureCounters()
                        self.lastInterfaceName = newIfaceName
                    }
                    self.interfaceInfo = freshInfo
                    self.throughput.reset()

                    // On ANY network change: clear VPN row and cached IP immediately,
                    // then re-fetch after routing has settled.
                    self.publicIPPingResult = nil
                    self.publicIPLatencyHistory.removeAll()
                    PublicIPService.clearCache()
                    DNSResolveService.clearCache()
                    self.publicIP = nil

                    // First fetch — routing may not be ready yet
                    let firstIP = await PublicIPService.fetch()
                    self.publicIP = firstIP

                    await self.performChecks()

                    // Retry after 3s — VPN tunnels often need time to establish routing.
                    // If IP changed, update; if same, no visible effect.
                    try? await Task.sleep(for: .seconds(3))
                    guard !Task.isCancelled, !self.isSuspended else { return }
                    PublicIPService.clearCache()
                    DNSResolveService.clearCache()
                    let retryIP = await PublicIPService.fetch()
                    if retryIP != firstIP {
                        self.publicIP = retryIP
                    }
                }
            }
        }
        monitor.start(queue: pathMonitorQueue)
        pathMonitor = monitor
    }

    // MARK: - Core Logic

    private func performChecks() async {
        // Safety: isChecking guard is safe because all callers hop to @MainActor
        // before invoking performChecks(). MainActor is serial — no two tasks can
        // interleave between the guard check and the assignment.
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }

        // Single getifaddrs() snapshot for all services
        let snapshot = InterfaceSnapshot.capture()

        let gw = await GatewayService.getGatewayIP(snapshot: snapshot)
        gatewayIP = gw ?? "unknown"
        interfaceInfo = NetworkInterfaceService.getActiveInterface(from: snapshot)
        throughput.update(from: snapshot)
        activeDNSServer = DNSResolveService.getActiveDNSServer()

        let currentPublicIP = PublicIPService.currentIP
        let pingTO = Config.pingTimeout
        let dnsDomain = Config.dnsTestDomain

        async let internetLatency = PingService.ping(Config.internetHost, timeout: pingTO)
        async let routerLatency: Double? = {
            if let gw { return await PingService.ping(gw, timeout: pingTO) }
            return nil
        }()
        async let dnsLatency = DNSResolveService.resolve(domain: dnsDomain)
        async let publicIPLatency: Double? = {
            if let pip = currentPublicIP { return await PingService.ping(pip) }
            return nil
        }()

        let iNet = await internetLatency
        let rtr = await routerLatency
        let dns = await dnsLatency
        let pubPing = await publicIPLatency
        let now = Date()
        isVPNDetected = NetworkInterfaceService.isVPNActive()
        let vpnActive = isVPNDetected
        updateCurrentLocalDeviceFromInterface(now: now)

        let internetResult = PingResult(target: .internet, timestamp: now, isReachable: iNet != nil, latency: iNet, detail: Config.internetHost)
        let routerResult = PingResult(target: .router, timestamp: now, isReachable: rtr != nil, latency: rtr, detail: gatewayIP)
        let dnsResult = PingResult(target: .dns, timestamp: now, isReachable: dns != nil, latency: dns, detail: activeDNSServer ?? Config.dnsTestDomain)

        // Update metrics via engine
        currentResults[.internet] = internetResult
        currentResults[.router] = routerResult
        currentResults[.dns] = dnsResult
        builtInLastUpdatedAt = now
        metrics.update(result: internetResult, vpnActive: vpnActive)
        metrics.update(result: routerResult, vpnActive: vpnActive)
        metrics.update(result: dnsResult, vpnActive: vpnActive)

        // Check incidents via manager
        incidentManager.checkIncident(internetResult, currentResults: currentResults)
        incidentManager.checkIncident(routerResult, currentResults: currentResults)
        incidentManager.checkIncident(dnsResult, currentResults: currentResults)

        // Spike alert notification
        for target in PingTarget.builtInCases {
            if metrics.lossSpike[target] == true {
                NotificationService.notifyDown(target: target)
            }
        }

        // Public IP / VPN — show VPN Server row only when VPN tunnel is detected
        if let pip = publicIP, isVPNDetected {
            publicIPPingResult = PingResult(target: .vpn, timestamp: now, isReachable: pubPing != nil, latency: pubPing, detail: pip)
            publicIPLatencyHistory.append(pubPing)
            if publicIPLatencyHistory.count > Config.maxHistorySamples {
                publicIPLatencyHistory.removeFirst(publicIPLatencyHistory.count - Config.maxHistorySamples)
            }
            SQLiteStorage.shared.record(LatencySample(target: .vpn, timestamp: now, latency: pubPing, vpnActive: true))
        } else {
            publicIPPingResult = nil
        }

        // Custom targets (concurrent)
        let enabledTargets = customTargets.filter(\.isEnabled)
        let customPingResults = await withTaskGroup(of: (UUID, Double?).self, returning: [(UUID, Double?)].self) { group in
            for target in enabledTargets {
                group.addTask { (target.id, await PingService.ping(target.host)) }
            }
            var results: [(UUID, Double?)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (id, latency) in customPingResults {
            guard let target = enabledTargets.first(where: { $0.id == id }) else { continue }
            // NOTE: .internet is a placeholder target for custom entries — they are keyed by UUID
            // in customResults, not by PingTarget. The detail field holds the actual host.
            customResults[id] = PingResult(target: .internet, timestamp: now, isReachable: latency != nil, latency: latency, detail: target.host)
            var history = customLatencyHistory[id] ?? []
            history.append(latency)
            if history.count > Config.maxHistorySamples { history.removeFirst(history.count - Config.maxHistorySamples) }
            customLatencyHistory[id] = history
            SQLiteStorage.shared.record(LatencySample(target: .internet, timestamp: now, latency: latency, vpnActive: vpnActive, storageKey: "custom.\(target.host)"))
        }
        
        SQLiteStorage.shared.flush()

        checkCycleCount += 1
        if checkCycleCount % 10 == 0 {
            incidentManager.saveAll()
        }
    }

    private func refreshDECTDevices(forceInventoryRefresh: Bool) async {
        guard !isDECTRingOperationInProgress else { return }
        guard !isRefreshingDECT else { return }
        isRefreshingDECT = true
        defer { isRefreshingDECT = false }

        let credentials = dectRefreshCredentials()
        let account = credentials.username
        let password = credentials.password
        guard !account.isEmpty, !password.isEmpty else { return }

        let routerIPGuess = guessedRouterIP(from: gatewayIP)
        do {
            let devices = try await FritzBoxDECTService.fetchDECTDevices(
                routerIP: routerIPGuess,
                username: account,
                password: password,
                forceInventoryRefresh: forceInventoryRefresh
            )
            await MainActor.run {
                self.dectDevices = devices
                self.dectLastUpdatedAt = Date()
            }
        } catch {
            if let fallback = dectFallbackCredentials(), fallback.username != account || fallback.password != password {
                do {
                    let devices = try await FritzBoxDECTService.fetchDECTDevices(
                        routerIP: routerIPGuess,
                        username: fallback.username,
                        password: fallback.password,
                        forceInventoryRefresh: forceInventoryRefresh
                    )
                    await MainActor.run {
                        self.dectDevices = devices
                        self.dectLastUpdatedAt = Date()
                    }
                    return
                } catch {
                    print("Failed to fetch DECT devices with fallback credentials: \(error)")
                }
            } else {
                print("Failed to fetch DECT devices: \(error)")
            }
        }
    }

    private func refreshLocalDeviceSpeeds() async {
        guard !isDECTRingOperationInProgress else { return }
        guard !localDevices.isEmpty else {
            localDeviceLastUpdatedAt = Date()
            hasCompletedInitialLocalDeviceRefresh = true
            return
        }
        guard localDeviceRefreshTask == nil else { return }

        let account = UserDefaults.standard.string(forKey: "local.username")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = UserDefaults.standard.string(forKey: "local.password")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !account.isEmpty, !password.isEmpty else {
            localDeviceLastUpdatedAt = Date()
            hasCompletedInitialLocalDeviceRefresh = true
            return
        }

        let devicesSnapshot = localDevices
        let routerIPGuess = guessedRouterIP(from: gatewayIP)
        localDeviceRefreshTask = Task { [weak self] in
            guard let self else { return }

            var statusMap = await TR064HostService.onlineMap(routerIP: routerIPGuess, username: account, password: password)
            if statusMap.isEmpty {
                try? await Task.sleep(for: .milliseconds(300))
                statusMap = await TR064HostService.onlineMap(routerIP: routerIPGuess, username: account, password: password)
            }

            let wifiAssociationMap = await TR064HostService.wifiAssociationMap(
                routerIP: routerIPGuess,
                username: account,
                password: password,
                macAddresses: devicesSnapshot.map(\.macAddress)
            )

            let pingResults: [UUID: Double?] = await withTaskGroup(of: (UUID, Double?).self) { group in
                for device in devicesSnapshot {
                    let state = self.localMapEntry(for: device.macAddress, in: statusMap)
                    let ip = state?.ip ?? device.ipAddress
                    let isOnline = state?.active ?? false
                    if ip.isEmpty { continue }

                    let needsInitialProbe = (device.pingSupported == nil && isOnline)
                    if needsInitialProbe || device.usePing {
                        group.addTask {
                            let latency = await PingService.ping(ip, timeout: 2)
                            return (device.id, latency)
                        }
                    }
                }
                var results: [UUID: Double?] = [:]
                for await (id, latency) in group {
                    results[id] = latency
                }
                return results
            }

            let now = Date()
            await MainActor.run {
                defer {
                    self.localDeviceLastUpdatedAt = now
                    self.hasCompletedInitialLocalDeviceRefresh = true
                    self.localDeviceRefreshTask = nil
                }
                var devicesChanged = false
                var updatedDevices = self.localDevices

                for (index, device) in updatedDevices.enumerated() {
                    let state = self.localMapEntry(for: device.macAddress, in: statusMap)
                    let ip = state?.ip ?? device.ipAddress
                    let isCurrentDevice = self.isCurrentLocalDevice(device, ipAddress: ip)
                    let wifiState = self.localMapEntry(for: device.macAddress, in: wifiAssociationMap)
                    let hasRouterLiveData = state?.speedMbps != nil
                        || state?.signalStrengthPercent != nil
                        || wifiState?.signalStrengthPercent != nil
                    let isOnline = isCurrentDevice || (state?.active ?? false) || hasRouterLiveData
                    let previousReachable = self.localResults[device.id]?.isReachable ?? false

                    var finalLatency: Double? = nil
                    var finalReachable = isOnline

                    if let latencyMapEntry = pingResults[device.id] {
                        let latency = latencyMapEntry
                        
                        if device.pingSupported == nil {
                            updatedDevices[index].pingSupported = (latency != nil)
                            if latency != nil {
                                updatedDevices[index].usePing = true
                            }
                            updatedDevices[index].pingProbeLastCheckedAt = now
                            devicesChanged = true
                        }
                        
                        if updatedDevices[index].usePing {
                            finalLatency = latency
                            finalReachable = isOnline || (latency != nil)
                        }
                    }

                    self.localResults[device.id] = PingResult(
                        target: .internet,
                        timestamp: now,
                        isReachable: finalReachable,
                        latency: finalLatency,
                        detail: ip
                    )

                    let normalizedActiveBand = self.normalizedBandLabel(wifiState?.band ?? state?.band)
                    if let normalizedActiveBand {
                        self.localBands[device.id] = normalizedActiveBand
                        if !updatedDevices[index].supportedBands.contains(normalizedActiveBand) {
                            updatedDevices[index].supportedBands.append(normalizedActiveBand)
                            updatedDevices[index].supportedBands = self.orderedUniqueBands(updatedDevices[index].supportedBands)
                            devicesChanged = true
                        }
                    } else {
                        self.localBands[device.id] = nil
                    }

                    if let sig = wifiState?.signalStrengthPercent ?? state?.signalStrengthPercent {
                        self.localSignalStrengths[device.id] = sig
                    } else {
                        self.localSignalStrengths[device.id] = nil
                    }

                    let speed = isCurrentDevice
                        ? (self.currentDeviceLinkSpeedMbps() ?? self.nonZeroSpeed(from: state?.speedMbps) ?? self.currentDeviceThroughputMbps())
                        : state?.speedMbps
                    if let speed {
                        self.localSpeeds[device.id] = speed
                        
                        var currentPingLatency: Double? = nil
                        if let latencyOpt = pingResults[device.id] {
                            currentPingLatency = latencyOpt
                        }
                        
                        LocalDeviceSpeedStorage.shared.recordSpeed(
                            macAddress: device.macAddress,
                            value: speed,
                            pingLatency: currentPingLatency,
                            signalStrength: wifiState?.signalStrengthPercent ?? state?.signalStrengthPercent ?? (isCurrentDevice ? self.currentWiFiSignalPercent() : nil),
                            unit: .mbitPerSecond,
                            timestamp: now
                        )
                    } else if !isCurrentDevice {
                        self.localSpeeds[device.id] = nil
                    }

                    if previousReachable && !finalReachable && device.notifyConnectivityDown {
                        NotificationService.notifyDown(target: .internet)
                    }
                }
                
                if devicesChanged {
                    self.saveLocalDevices(updatedDevices)
                }
            }
        }
    }

    private func guessedRouterIP(from gateway: String) -> String {
        if gateway.hasPrefix("192.168.")
            || gateway.hasPrefix("10.")
            || gateway.hasPrefix("172.16.")
            || gateway.hasPrefix("172.17.")
            || gateway.hasPrefix("172.18.")
            || gateway.hasPrefix("172.19.")
            || gateway.hasPrefix("172.20.")
            || gateway.hasPrefix("172.21.")
            || gateway.hasPrefix("172.22.")
            || gateway.hasPrefix("172.23.")
            || gateway.hasPrefix("172.24.")
            || gateway.hasPrefix("172.25.")
            || gateway.hasPrefix("172.26.")
            || gateway.hasPrefix("172.27.")
            || gateway.hasPrefix("172.28.")
            || gateway.hasPrefix("172.29.")
            || gateway.hasPrefix("172.30.")
            || gateway.hasPrefix("172.31.") {
            return gateway
        }
        return "192.168.178.1"
    }

    private func localMapEntry<T>(for macAddress: String, in map: [String: T]) -> T? {
        let key1 = macAddress.lowercased()
        let key2 = key1.replacingOccurrences(of: "-", with: ":")
        let key3 = key1.replacingOccurrences(of: ":", with: "-")
        let key4 = key1.replacingOccurrences(of: ":", with: "")
        return map[key1] ?? map[key2] ?? map[key3] ?? map[key4]
    }

    func isCurrentLocalDevice(_ device: LocalNetworkDevice) -> Bool {
        isCurrentLocalDevice(device, ipAddress: localResults[device.id]?.detail ?? device.ipAddress)
    }

    private func isCurrentLocalDevice(_ device: LocalNetworkDevice, ipAddress: String?) -> Bool {
        let currentMAC = normalizeMACKey(interfaceInfo?.macAddress ?? "")
        let deviceMAC = normalizeMACKey(device.macAddress)
        if !currentMAC.isEmpty, !deviceMAC.isEmpty, currentMAC == deviceMAC {
            return true
        }

        let currentIP = interfaceInfo?.ipAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let candidateIP = ipAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !currentIP.isEmpty && !candidateIP.isEmpty && currentIP == candidateIP {
            return true
        }
        return false
    }

    private func currentDeviceThroughputMbps() -> Double? {
        guard
            let interfaceName = interfaceInfo?.interfaceName,
            let reading = throughput.currentReadings[interfaceName]
        else {
            return nil
        }

        let totalBytesPerSecond = reading.downloadBytesPerSec + reading.uploadBytesPerSec
        let megabitsPerSecond = (totalBytesPerSecond * 8) / 1_000_000
        guard megabitsPerSecond.isFinite, megabitsPerSecond > 0 else { return nil }
        return megabitsPerSecond
    }

    private func currentDeviceLinkSpeedMbps() -> Double? {
        guard let speed = interfaceInfo?.linkSpeedMbps, speed.isFinite, speed > 0 else { return nil }
        return speed
    }

    private func nonZeroSpeed(from speed: Double?) -> Double? {
        guard let speed, speed.isFinite, speed > 0 else { return nil }
        return speed
    }

    private func currentWiFiSignalPercent() -> Int? {
        guard let rssi = interfaceInfo?.wifiRSSI else { return nil }
        let clamped = min(max(rssi, -90), -30)
        return Int(round((Double(clamped + 90) / 60.0) * 100.0))
    }

    private func updateCurrentLocalDeviceFromInterface(now: Date) {
        guard !localDevices.isEmpty, let interfaceInfo else { return }

        for device in localDevices where isCurrentLocalDevice(device) {
            localResults[device.id] = PingResult(
                target: .internet,
                timestamp: now,
                isReachable: true,
                latency: localResults[device.id]?.latency,
                detail: interfaceInfo.ipAddress ?? device.ipAddress
            )

            if let speed = currentDeviceLinkSpeedMbps() ?? currentDeviceThroughputMbps() {
                localSpeeds[device.id] = speed
                LocalDeviceSpeedStorage.shared.recordSpeed(
                    macAddress: device.macAddress,
                    value: speed,
                    pingLatency: localResults[device.id]?.latency,
                    signalStrength: currentWiFiSignalPercent(),
                    unit: .mbitPerSecond,
                    timestamp: now
                )
            }

            if let signal = currentWiFiSignalPercent() {
                localSignalStrengths[device.id] = signal
            }
        }
    }

    private func normalizeMACKey(_ macAddress: String) -> String {
        let lower = macAddress.lowercased()
        return lower.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
    }

    private func loadLocalWANBlockedByMAC() -> [String: Bool] {
        UserDefaults.standard.dictionary(forKey: Config.Keys.localDeviceWANBlockStates) as? [String: Bool] ?? [:]
    }

    private func saveLocalWANBlockedByMAC() {
        UserDefaults.standard.set(localWANBlockedByMAC, forKey: Config.Keys.localDeviceWANBlockStates)
    }

    private func normalizedBandLabel(_ band: String?) -> String? {
        guard let raw = band?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        let lower = raw.lowercased()
        if lower.contains("6") { return "6GHz" }
        if lower.contains("5") { return "5GHz" }
        if lower.contains("2.4") || lower.contains("2,4") || lower.contains("24") { return "2.4GHz" }
        return raw
    }

    private func orderedUniqueBands(_ bands: [String]) -> [String] {
        let preferredOrder = ["2.4GHz", "5GHz", "6GHz"]
        let unique = Array(Set(bands.compactMap { normalizedBandLabel($0) }))
        return unique.sorted { left, right in
            let leftIndex = preferredOrder.firstIndex(of: left) ?? Int.max
            let rightIndex = preferredOrder.firstIndex(of: right) ?? Int.max
            if leftIndex == rightIndex {
                return left < right
            }
            return leftIndex < rightIndex
        }
    }

    // MARK: - Custom Target Management

    func addCustomTarget(name: String, host: String) {
        guard HostValidator.isValid(host) else { return }
        customTargets.append(CustomTarget(name: name, host: host))
        CustomTargetStore.save(customTargets)
    }

    func removeCustomTarget(_ target: CustomTarget) {
        customTargets.removeAll { $0.id == target.id }
        customResults.removeValue(forKey: target.id)
        customLatencyHistory.removeValue(forKey: target.id)
        CustomTargetStore.save(customTargets)
    }

    func toggleCustomTarget(_ target: CustomTarget) {
        if let index = customTargets.firstIndex(where: { $0.id == target.id }) {
            customTargets[index].isEnabled.toggle()
            CustomTargetStore.save(customTargets)
        }
    }

    // MARK: - Local Network Device Management
    
    func saveLocalDevices(_ devices: [LocalNetworkDevice]) {
        self.localDevices = devices
        let validMACs = Set(devices.map { normalizeMACKey($0.macAddress) })
        localWANBlockedByMAC = localWANBlockedByMAC.filter { validMACs.contains($0.key) }
        saveLocalWANBlockedByMAC()
        LocalDeviceSpeedStorage.shared.syncSelectedDevices(devices)
        let validIDs = Set(devices.map(\.id))
        localResults = localResults.filter { validIDs.contains($0.key) }
        localSpeeds = localSpeeds.filter { validIDs.contains($0.key) }
        localSignalStrengths = localSignalStrengths.filter { validIDs.contains($0.key) }
        localBands = localBands.filter { validIDs.contains($0.key) }
        LocalNetworkDeviceStore.save(devices)
        Task { await refreshLocalDeviceSpeeds() }
    }

    func isLocalDeviceWANBlocked(_ device: LocalNetworkDevice) -> Bool {
        localWANBlockedByMAC[normalizeMACKey(device.macAddress)] ?? false
    }

    func setLocalDeviceWANAccess(_ device: LocalNetworkDevice, blocked: Bool) async {
        let account = UserDefaults.standard.string(forKey: "local.username")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = UserDefaults.standard.string(forKey: "local.password")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !account.isEmpty, !password.isEmpty else {
            print("Set WAN access skipped: missing FRITZ!Box credentials")
            return
        }

        let ip = (localResults[device.id]?.detail ?? device.ipAddress).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !ip.isEmpty else {
            print("Set WAN access skipped: missing IP for device \(device.displayName)")
            return
        }

        let routerIPGuess = guessedRouterIP(from: gatewayIP)
        do {
            try await FritzBoxTR064Service.shared.setWANAccessByIP(
                routerIP: routerIPGuess,
                username: account,
                password: password,
                ipAddress: ip,
                disallow: blocked
            )
            localWANBlockedByMAC[normalizeMACKey(device.macAddress)] = blocked
            saveLocalWANBlockedByMAC()
            print("Set WAN access for \(device.displayName) (\(ip)) -> \(blocked ? "blocked" : "allowed")")
        } catch {
            print("Set WAN access failed for \(device.displayName) (\(ip)): \(error.localizedDescription)")
        }
    }

    func ringDECTDevice(
        _ device: DECTDevice,
        onLog: (@MainActor (String) -> Void)? = nil
    ) async throws {
        let (routerIPGuess, primaryAccount, primaryPassword) = try dectCredentials()

        let targetNumber = device.internalNumber ?? FritzBoxDECTService.defaultInternalNumber(forDeviceID: device.id)
        guard let targetNumber, !targetNumber.isEmpty else {
            throw NSError(domain: "PingPongBar.DECT", code: 2, userInfo: [NSLocalizedDescriptionKey: "No internal DECT number available for this phone"])
        }

        if let onLog {
            onLog("Using router \(routerIPGuess)")
            onLog("Target handset: \(device.name) (\(targetNumber))")
            onLog("Pausing background DECT/local-device polling during ring process...")
        }

        isDECTRingOperationInProgress = true
        defer {
            isDECTRingOperationInProgress = false
        }

        do {
            onLog?("Using DECT credentials: \(primaryAccount)")
            try await FritzBoxDECTService.ringPhone(
                routerIP: routerIPGuess,
                username: primaryAccount,
                password: primaryPassword,
                internalNumber: targetNumber,
                preferredHandsetName: device.name,
                onLog: { line in
                    Task { @MainActor in
                        onLog?(line)
                    }
                }
            )
        } catch {
            guard shouldRetryWithFallbackCredentials(error),
                  let (fallbackAccount, fallbackPassword) = dectFallbackCredentials()
            else {
                throw error
            }

            onLog?("Primary DECT credentials rejected (401). Retrying with local FRITZ!Box credentials...")
            onLog?("Using fallback DECT credentials: \(fallbackAccount)")
            try await FritzBoxDECTService.ringPhone(
                routerIP: routerIPGuess,
                username: fallbackAccount,
                password: fallbackPassword,
                internalNumber: targetNumber,
                preferredHandsetName: device.name,
                onLog: { line in
                    Task { @MainActor in
                        onLog?(line)
                    }
                }
            )
        }
    }

    func hangupDECTCall(onLog: (@MainActor (String) -> Void)? = nil) async {
        do {
            let (routerIPGuess, account, password) = try dectCredentials()
            isDECTRingOperationInProgress = true
            defer { isDECTRingOperationInProgress = false }
            if let onLog {
                onLog("Sending manual hangup...")
            }
            try await FritzBoxDECTService.hangupCall(
                routerIP: routerIPGuess,
                username: account,
                password: password
            )
            if let onLog {
                onLog("Manual hangup sent.")
            }
        } catch {
            if shouldRetryWithFallbackCredentials(error),
               let (fallbackAccount, fallbackPassword) = dectFallbackCredentials() {
                do {
                    if let onLog {
                        onLog("Primary DECT credentials rejected (401). Retrying manual hangup with fallback credentials...")
                    }
                    let routerIPGuess = guessedRouterIP(from: gatewayIP)
                    try await FritzBoxDECTService.hangupCall(
                        routerIP: routerIPGuess,
                        username: fallbackAccount,
                        password: fallbackPassword
                    )
                    if let onLog {
                        onLog("Manual hangup sent (fallback credentials).")
                    }
                } catch {
                    if let onLog {
                        onLog("Manual hangup failed: \(error.localizedDescription)")
                    }
                }
            } else if let onLog {
                onLog("Manual hangup failed: \(error.localizedDescription)")
            }
        }
    }

    private func dectCredentials() throws -> (routerIP: String, username: String, password: String) {
        // Dedicated telephony credentials (calling use case only).
        let account = Config.fritzAppUsername
        let password = Config.fritzAppPassword
        let routerIPGuess = guessedRouterIP(from: gatewayIP)
        return (routerIPGuess, account, password)
    }

    private func dectRefreshCredentials() -> (username: String, password: String) {
        let appAccount = Config.fritzAppUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        let appPassword = Config.fritzAppPassword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !appAccount.isEmpty, !appPassword.isEmpty {
            return (appAccount, appPassword)
        }

        return dectFallbackCredentials() ?? ("", "")
    }

    private func dectFallbackCredentials() -> (username: String, password: String)? {
        let account = UserDefaults.standard.string(forKey: "local.username")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let password = UserDefaults.standard.string(forKey: "local.password")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !account.isEmpty, !password.isEmpty else { return nil }
        return (account, password)
    }

    private func shouldRetryWithFallbackCredentials(_ error: Error) -> Bool {
        let text = error.localizedDescription.lowercased()
        return text.contains("http 401") || text.contains("401 unauthorized")
    }

    func clearHistory() {
        incidentManager.clearHistory()
    }
}
