//
//  LocalNetworkDevice.swift
//  PongBar
//
//  Represents a device discovered on the local network (e.g. via FritzBox TR-064 API),
//  with user-customizable display configurations.
//

import Foundation

struct LocalNetworkDevice: Identifiable, Codable, Equatable, Hashable {
    var id: UUID = UUID()

    private enum CodingKeys: String, CodingKey {
        case id
        case macAddress
        case ipAddress
        case originalName
        case customName
        case symbolName
        case notifyConnectivityDown
        case usePing
        case pingSupported
        case pingProbeLastCheckedAt
        case supportedBands
    }
    
    /// The MAC Address of the device (Primary identifier from TR-064)
    var macAddress: String
    
    /// The last known IP address of the device
    var ipAddress: String
    
    /// Original hostname given by the router
    var originalName: String
    
    /// User overriden display name
    var customName: String
    
    /// The SF Symbol name to represent this device
    var symbolName: String
    
    /// Whether this device should trigger push notifications when unreachable
    var notifyConnectivityDown: Bool

    /// Whether ping-based latency should be used for this device's UI display.
    var usePing: Bool = false

    /// Whether this host was previously verified to answer ICMP ping.
    var pingSupported: Bool? = nil

    /// Last time we checked whether this host supports ping.
    var pingProbeLastCheckedAt: Date? = nil

    /// Bands this device has been observed on at least once (e.g. 2.4GHz, 5GHz, 6GHz).
    var supportedBands: [String] = []

    init(
        id: UUID = UUID(),
        macAddress: String,
        ipAddress: String,
        originalName: String,
        customName: String,
        symbolName: String,
        notifyConnectivityDown: Bool,
        usePing: Bool = false,
        pingSupported: Bool? = nil,
        pingProbeLastCheckedAt: Date? = nil,
        supportedBands: [String] = []
    ) {
        self.id = id
        self.macAddress = macAddress
        self.ipAddress = ipAddress
        self.originalName = originalName
        self.customName = customName
        self.symbolName = symbolName
        self.notifyConnectivityDown = notifyConnectivityDown
        self.usePing = usePing
        self.pingSupported = pingSupported
        self.pingProbeLastCheckedAt = pingProbeLastCheckedAt
        self.supportedBands = supportedBands
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        macAddress = try container.decode(String.self, forKey: .macAddress)
        ipAddress = try container.decode(String.self, forKey: .ipAddress)
        originalName = try container.decode(String.self, forKey: .originalName)
        customName = try container.decode(String.self, forKey: .customName)
        symbolName = try container.decode(String.self, forKey: .symbolName)
        notifyConnectivityDown = try container.decode(Bool.self, forKey: .notifyConnectivityDown)
        usePing = try container.decodeIfPresent(Bool.self, forKey: .usePing) ?? false
        pingSupported = try container.decodeIfPresent(Bool.self, forKey: .pingSupported)
        pingProbeLastCheckedAt = try container.decodeIfPresent(Date.self, forKey: .pingProbeLastCheckedAt)
        supportedBands = try container.decodeIfPresent([String].self, forKey: .supportedBands) ?? []
    }
    
    var displayName: String {
        return customName.isEmpty ? originalName : customName
    }
}

/// Manages persistence of local network devices.
enum LocalNetworkDeviceStore {
    static func load() -> [LocalNetworkDevice] {
        guard let data = UserDefaults.standard.data(forKey: Config.Keys.localNetworkDevices),
              let devices = try? JSONDecoder().decode([LocalNetworkDevice].self, from: data) else { return [] }
        return devices
    }

    static func save(_ devices: [LocalNetworkDevice]) {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: Config.Keys.localNetworkDevices)
        }
    }
}
