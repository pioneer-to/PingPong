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
