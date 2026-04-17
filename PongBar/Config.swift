//
//  Config.swift
//  PongBar
//
//  Centralized configuration for all thresholds, timeouts, intervals, and defaults.
//  Values are read from UserDefaults with sensible fallbacks.
//  Change defaults here or override per-user via the Settings UI.
//

import Foundation

enum Config {
    // MARK: - Monitoring

    /// Default ping interval in seconds (user-configurable in Settings).
    static var pingInterval: TimeInterval {
        let val = UserDefaults.standard.double(forKey: Keys.pingInterval)
        return val > 0 ? val : Defaults.pingInterval
    }

    /// Ping-pong animation speed multiplier for menu bar dot.
    /// 1.0 = current/default speed, higher = faster animation.
    static var pingPongAnimationSpeed: Double {
        let val = UserDefaults.standard.double(forKey: Keys.pingPongAnimationSpeed)
        let candidate = val > 0 ? val : Defaults.pingPongAnimationSpeed
        return max(0.5, min(candidate, 1.5))
    }

    /// Local device speed refresh interval in seconds.
    static var localDeviceSpeedInterval: TimeInterval {
        let val = UserDefaults.standard.double(forKey: Keys.localDeviceSpeedInterval)
        let candidate = val > 0 ? val : Defaults.localDeviceSpeedInterval
        return max(30, candidate)
    }

    /// Ping timeout in seconds (clamped 1 to pingInterval).
    static var pingTimeout: Int {
        let val = UserDefaults.standard.integer(forKey: Keys.pingTimeout).nonZero ?? Defaults.pingTimeout
        let maxTimeout = max(1, Int(pingInterval) - 1)
        return max(1, min(val, maxTimeout))
    }

    /// DNS resolve timeout in seconds (clamped 1-30).
    static var dnsTimeout: Int {
        let val = UserDefaults.standard.integer(forKey: Keys.dnsTimeout).nonZero ?? Defaults.dnsTimeout
        return max(1, min(val, 30))
    }

    // MARK: - Default Hosts

    /// Internet connectivity test host.
    static var internetHost: String {
        UserDefaults.standard.string(forKey: Keys.internetHost)?.nilIfEmpty ?? Defaults.internetHost
    }

    /// DNS resolution test domain.
    static var dnsTestDomain: String {
        UserDefaults.standard.string(forKey: Keys.dnsTestDomain)?.nilIfEmpty ?? Defaults.dnsTestDomain
    }

    // MARK: - Latency Thresholds (ms)

    /// Latency at or below this value is considered good (shown in primary color).
    static var latencyGoodThreshold: Double {
        UserDefaults.standard.doubleOrNil(forKey: Keys.latencyGoodThreshold) ?? Defaults.latencyGoodThreshold
    }

    /// Latency at or below this value is considered fair (shown in yellow).
    static var latencyFairThreshold: Double {
        UserDefaults.standard.doubleOrNil(forKey: Keys.latencyFairThreshold) ?? Defaults.latencyFairThreshold
    }

    // MARK: - Jitter

    /// Minimum jitter value (ms) to display in the status row.
    static var jitterDisplayThreshold: Double {
        UserDefaults.standard.doubleOrNil(forKey: Keys.jitterDisplayThreshold) ?? Defaults.jitterDisplayThreshold
    }

    /// Jitter above this value (ms) is highlighted as a warning (yellow).
    static var jitterWarningThreshold: Double {
        UserDefaults.standard.doubleOrNil(forKey: Keys.jitterWarningThreshold) ?? Defaults.jitterWarningThreshold
    }

    /// Number of recent latency deltas used to compute jitter.
    static var jitterWindow: Int {
        UserDefaults.standard.integer(forKey: Keys.jitterWindow).nonZero ?? Defaults.jitterWindow
    }

    // MARK: - Packet Loss

    /// Rolling window size (number of checks) for packet loss calculation.
    /// Loss spike threshold (percentage jump per tick to trigger alert).
    static var lossSpikeThreshold: Double {
        UserDefaults.standard.doubleOrNil(forKey: Keys.lossSpikeThreshold) ?? Defaults.lossSpikeThreshold
    }

    static var lossWindow: Int {
        UserDefaults.standard.integer(forKey: Keys.lossWindow).nonZero ?? Defaults.lossWindow
    }

    // MARK: - Uptime Display

    /// Uptime percentage at or above this is shown in green.
    static var uptimeGreenThreshold: Double {
        UserDefaults.standard.doubleOrNil(forKey: Keys.uptimeGreenThreshold) ?? Defaults.uptimeGreenThreshold
    }

    /// Uptime percentage at or above this is shown in yellow (below = red).
    static var uptimeYellowThreshold: Double {
        UserDefaults.standard.doubleOrNil(forKey: Keys.uptimeYellowThreshold) ?? Defaults.uptimeYellowThreshold
    }

    // MARK: - WiFi Signal

    /// RSSI thresholds for signal quality classification (dBm).
    /// WiFi RSSI thresholds use intOrNil instead of nonZero because
    /// defaults are negative (e.g. -50 dBm), and 0 is a valid RSSI value.
    static var wifiExcellentThreshold: Int {
        UserDefaults.standard.intOrNil(forKey: Keys.wifiExcellent) ?? Defaults.wifiExcellentThreshold
    }

    static var wifiGoodThreshold: Int {
        UserDefaults.standard.intOrNil(forKey: Keys.wifiGood) ?? Defaults.wifiGoodThreshold
    }

    static var wifiFairThreshold: Int {
        UserDefaults.standard.intOrNil(forKey: Keys.wifiFair) ?? Defaults.wifiFairThreshold
    }

    // MARK: - Notifications

    /// Cooldown between notifications for the same target (seconds).
    static var notificationCooldown: TimeInterval {
        let val = UserDefaults.standard.double(forKey: Keys.notificationCooldown)
        return val > 0 ? val : Defaults.notificationCooldown
    }

    // MARK: - Storage & History

    /// Maximum number of latency samples kept per target for sparkline.
    static var maxHistorySamples: Int {
        UserDefaults.standard.integer(forKey: Keys.maxHistorySamples).nonZero ?? Defaults.maxHistorySamples
    }

    /// Maximum number of incidents to keep in history.
    static var maxIncidents: Int {
        UserDefaults.standard.integer(forKey: Keys.maxIncidents).nonZero ?? Defaults.maxIncidents
    }

    /// Data retention period in seconds (default 7 days).
    static var retentionPeriod: TimeInterval {
        let val = UserDefaults.standard.double(forKey: Keys.retentionPeriod)
        return val > 0 ? val : Defaults.retentionPeriod
    }

    /// Number of writes between storage trim operations.
    static var storageTrimInterval: Int {
        UserDefaults.standard.integer(forKey: Keys.storageTrimInterval).nonZero ?? Defaults.storageTrimInterval
    }

    // MARK: - Network Switch Grace Period

    /// Number of consecutive failed pings before registering an incident.
    /// Prevents false incidents during network/VPN switching.
    static var networkSwitchGracePings: Int {
        let val = UserDefaults.standard.integer(forKey: Keys.networkSwitchGracePings).nonZero ?? Defaults.networkSwitchGracePings
        return max(1, min(val, 30))
    }

    // MARK: - MTR

    /// MTR per-hop ping timeout in seconds.
    static var mtrHopTimeout: Int {
        UserDefaults.standard.integer(forKey: Keys.mtrHopTimeout).nonZero ?? Defaults.mtrHopTimeout
    }

    /// MTR round interval in seconds.
    static var mtrRoundInterval: Double {
        let val = UserDefaults.standard.double(forKey: Keys.mtrRoundInterval)
        return val > 0 ? val : Defaults.mtrRoundInterval
    }

    // MARK: - Misc

    /// Delay after wake before resuming monitoring (seconds).
    static var wakeDelay: Double {
        let val = UserDefaults.standard.double(forKey: Keys.wakeDelay)
        return val > 0 ? val : Defaults.wakeDelay
    }

    /// Chart auto-refresh interval in seconds.
    static var chartRefreshInterval: Double {
        let val = UserDefaults.standard.double(forKey: Keys.chartRefreshInterval)
        return val > 0 ? val : Defaults.chartRefreshInterval
    }

    /// Number of recent incidents in diagnostic report.
    static var diagnosticRecentIncidents: Int {
        UserDefaults.standard.integer(forKey: Keys.diagnosticRecentIncidents).nonZero ?? Defaults.diagnosticRecentIncidents
    }

    // MARK: - Traceroute

    /// Maximum hops for traceroute.
    static var tracerouteMaxHops: Int {
        UserDefaults.standard.integer(forKey: Keys.tracerouteMaxHops).nonZero ?? Defaults.tracerouteMaxHops
    }

    /// Traceroute per-hop timeout in seconds.
    static var tracerouteTimeout: Int {
        UserDefaults.standard.integer(forKey: Keys.tracerouteTimeout).nonZero ?? Defaults.tracerouteTimeout
    }

    // MARK: - Local Device Speed Quality (Mbit/s)

    static var speedQualityLowThreshold: Double {
        UserDefaults.standard.doubleOrNil(forKey: Keys.speedQualityLowThreshold) ?? Defaults.speedQualityLowThreshold
    }

    static var speedQualityMediumThreshold: Double {
        UserDefaults.standard.doubleOrNil(forKey: Keys.speedQualityMediumThreshold) ?? Defaults.speedQualityMediumThreshold
    }

    static var speedQualityHighThreshold: Double {
        UserDefaults.standard.doubleOrNil(forKey: Keys.speedQualityHighThreshold) ?? Defaults.speedQualityHighThreshold
    }

    static var pingPongAudioEnabled: Bool {
        UserDefaults.standard.object(forKey: Keys.pingPongAudioEnabled) as? Bool ?? Defaults.pingPongAudioEnabled
    }
}

// MARK: - Default Values

extension Config {
    enum Defaults {
        static let pingInterval: TimeInterval = 3.0
        static let pingPongAnimationSpeed: Double = 1.0
        static let localDeviceSpeedInterval: TimeInterval = 60.0
        static let pingTimeout: Int = 2
        static let dnsTimeout: Int = 3

        static let internetHost = "8.8.8.8"
        static let dnsTestDomain = "apple.com"

        static let latencyGoodThreshold: Double = 50
        static let latencyFairThreshold: Double = 150

        static let jitterDisplayThreshold: Double = 0.1
        static let jitterWarningThreshold: Double = 5.0
        static let jitterWindow: Int = 20

        static let lossWindow: Int = 60
        static let lossSpikeThreshold: Double = 20

        static let uptimeGreenThreshold: Double = 90
        static let uptimeYellowThreshold: Double = 50

        static let wifiExcellentThreshold: Int = -50
        static let wifiGoodThreshold: Int = -60
        static let wifiFairThreshold: Int = -70

        static let notificationCooldown: TimeInterval = 30

        static let maxHistorySamples: Int = 30
        static let maxIncidents: Int = 200
        static let retentionPeriod: TimeInterval = 7 * 24 * 3600
        static let storageTrimInterval: Int = 500

        static let tracerouteMaxHops: Int = 20
        static let tracerouteTimeout: Int = 2
        static let speedQualityLowThreshold: Double = 50
        static let speedQualityMediumThreshold: Double = 150
        static let speedQualityHighThreshold: Double = 400
        static let pingPongAudioEnabled: Bool = false

        static let networkSwitchGracePings: Int = 3

        static let mtrHopTimeout: Int = 1
        static let mtrRoundInterval: Double = 1.0

        static let wakeDelay: Double = 2.0
        static let chartRefreshInterval: Double = 3.0
        static let diagnosticRecentIncidents: Int = 20
    }
    // MARK: - Local Network Devices
    static var fritzUsername: String {
        UserDefaults.standard.string(forKey: Keys.fritzUsername) ?? ""
    }
    static var fritzPassword: String {
        UserDefaults.standard.string(forKey: Keys.fritzPassword) ?? ""
    }
}

// MARK: - UserDefaults Keys

extension Config {
    enum Keys {
        static let pingInterval = "pingInterval"
        static let pingPongAnimationSpeed = "pingPongAnimationSpeed"
        static let localDeviceSpeedInterval = "localDeviceSpeedInterval"
        static let pingTimeout = "pingTimeout"
        static let dnsTimeout = "dnsTimeout"

        static let internetHost = "internetHost"
        static let dnsTestDomain = "dnsTestDomain"

        static let latencyGoodThreshold = "latencyGoodThreshold"
        static let latencyFairThreshold = "latencyFairThreshold"

        static let jitterDisplayThreshold = "jitterDisplayThreshold"
        static let jitterWarningThreshold = "jitterWarningThreshold"
        static let jitterWindow = "jitterWindow"

        static let lossWindow = "lossWindow"
        static let lossSpikeThreshold = "lossSpikeThreshold"

        static let uptimeGreenThreshold = "uptimeGreenThreshold"
        static let uptimeYellowThreshold = "uptimeYellowThreshold"

        static let wifiExcellent = "wifiExcellent"
        static let wifiGood = "wifiGood"
        static let wifiFair = "wifiFair"

        static let notificationCooldown = "notificationCooldown"

        static let maxHistorySamples = "maxHistorySamples"
        static let maxIncidents = "maxIncidents"
        static let retentionPeriod = "retentionPeriod"
        static let storageTrimInterval = "storageTrimInterval"

        static let pauseDuringSleep = "pauseDuringSleep"
        static let showPublicIP = "showPublicIP"
        static let networkSwitchGracePings = "networkSwitchGracePings"
        static let mtrHopTimeout = "mtrHopTimeout"
        static let mtrRoundInterval = "mtrRoundInterval"
        static let wakeDelay = "wakeDelay"
        static let chartRefreshInterval = "chartRefreshInterval"
        static let diagnosticRecentIncidents = "diagnosticRecentIncidents"
        static let tracerouteMaxHops = "tracerouteMaxHops"
        static let tracerouteTimeout = "tracerouteTimeout"
        static let speedQualityLowThreshold = "speedQualityLowThreshold"
        static let speedQualityMediumThreshold = "speedQualityMediumThreshold"
        static let speedQualityHighThreshold = "speedQualityHighThreshold"
        static let pingPongAudioEnabled = "pingPongAudioEnabled"
        
        static let fritzUsername = "fritzUsername"
        static let fritzPassword = "fritzPassword"
        static let localNetworkDevices = "localNetworkDevices"
        static let localDeviceWANBlockStates = "localDeviceWANBlockStates"
    }
}

// MARK: - Helpers

private extension Int {
    var nonZero: Int? { self != 0 ? self : nil }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

extension UserDefaults {
    func doubleOrNil(forKey key: String) -> Double? {
        if object(forKey: key) != nil { return double(forKey: key) }
        return nil
    }

    func intOrNil(forKey key: String) -> Int? {
        if object(forKey: key) != nil { return integer(forKey: key) }
        return nil
    }
}
