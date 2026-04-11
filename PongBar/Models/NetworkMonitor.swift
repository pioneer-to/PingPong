//
//  NetworkMonitor.swift
//  PongBar
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

    // MARK: - Configuration

    var pingInterval: TimeInterval

    var pauseDuringSleep: Bool {
        get { UserDefaults.standard.object(forKey: Config.Keys.pauseDuringSleep) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Config.Keys.pauseDuringSleep) }
    }

    // MARK: - Private

    private var timer: Timer?
    private var pathMonitor: NWPathMonitor?
    private let pathMonitorQueue = DispatchQueue(label: "PongBar.NWPathMonitor")
    private var isChecking = false
    private var isSuspended = false
    private var checkCycleCount = 0
    private var pathUpdateTask: Task<Void, Never>?
    private var lastInterfaceName: String?

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
        customTargets = CustomTargetStore.load()
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
        // Create timer without auto-scheduling, add only to .common mode
        // so it fires exactly once per interval even during scroll/tracking events.
        let t = Timer(timeInterval: pingInterval, repeats: true) { [weak self] _ in
            Task { [weak self] in await self?.performChecks() }
        }
        RunLoop.current.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
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

        let internetResult = PingResult(target: .internet, timestamp: now, isReachable: iNet != nil, latency: iNet, detail: Config.internetHost)
        let routerResult = PingResult(target: .router, timestamp: now, isReachable: rtr != nil, latency: rtr, detail: gatewayIP)
        let dnsResult = PingResult(target: .dns, timestamp: now, isReachable: dns != nil, latency: dns, detail: activeDNSServer ?? Config.dnsTestDomain)

        // Update metrics via engine
        currentResults[.internet] = internetResult
        currentResults[.router] = routerResult
        currentResults[.dns] = dnsResult
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

    func clearHistory() {
        incidentManager.clearHistory()
    }
}
