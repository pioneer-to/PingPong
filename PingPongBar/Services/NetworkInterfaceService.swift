//
//  NetworkInterfaceService.swift
//  PingPongBar
//
//  Detects active network interface, IP address, WiFi SSID, and signal strength.
//

import Foundation
import CoreWLAN
import SystemConfiguration

/// Information about the current network interface.
struct NetworkInterfaceInfo {
    let interfaceName: String       // e.g. "en0", "en10", "utun3"
    let ipAddress: String?
    let macAddress: String?
    let type: InterfaceType
    let wifiSSID: String?           // Only for WiFi
    let wifiRSSI: Int?              // Signal strength in dBm (only for WiFi)
    let linkSpeedMbps: Double?      // Active link rate when the OS exposes it

    enum InterfaceType: String {
        case wifi = "WiFi"
        case ethernet = "Ethernet"
        case vpn = "VPN"
        case cellular = "Cellular"
        case other = "Other"
    }

    /// Compact summary string for the popover header.
    var summary: String {
        var parts: [String] = []
        parts.append(type.rawValue)
        if let ssid = wifiSSID {
            parts.append(ssid)
        }
        if let rssi = wifiRSSI {
            parts.append("\(rssi) dBm")
        }
        if let ip = ipAddress {
            parts.append(ip)
        }
        return parts.joined(separator: " · ")
    }

    /// Signal quality description for WiFi.
    var signalQuality: String? {
        guard let rssi = wifiRSSI else { return nil }
        if rssi >= Config.wifiExcellentThreshold { return "Excellent" }
        if rssi >= Config.wifiGoodThreshold { return "Good" }
        if rssi >= Config.wifiFairThreshold { return "Fair" }
        return "Weak"
    }
}

/// Detects the active network interface and its properties.
enum NetworkInterfaceService {
    /// Returns true if any VPN tunnel interface (utun/ipsec/ppp) is up with an assigned IP.
    /// Works with WireGuard, OpenVPN, IKEv2, L2TP regardless of VPN client.
    /// Detect VPN by checking SCDynamicStore for active network services
    /// with a tunnel interface (utun/ipsec/ppp). This reads the same state
    /// as System Settings → VPN — reliable for all VPN types.
    static func isVPNActive() -> Bool {
        guard let store = SCDynamicStoreCreate(nil, "PingPongBar" as CFString, nil, nil) else { return false }

        let vpnPrefixes = ["utun", "ipsec", "ppp"]

        // Get all active network service IDs
        guard let allKeys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/IPv4" as CFString) as? [String] else {
            return false
        }

        for key in allKeys {
            guard let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                  let iface = dict["InterfaceName"] as? String else { continue }

            // If any active service uses a VPN tunnel interface → VPN is connected
            if vpnPrefixes.contains(where: { iface.hasPrefix($0) }) {
                return true
            }
        }

        return false
    }

    /// Get current active network interface info.
    static func getActiveInterface(from snapshot: InterfaceSnapshot? = nil) -> NetworkInterfaceInfo? {
        // Check WiFi first
        if let wifiInfo = getWiFiInfo(from: snapshot) {
            return wifiInfo
        }

        // Use snapshot if provided, otherwise fallback to own getifaddrs call
        if let snapshot, let phys = snapshot.firstPhysicalInterface() {
            let type: NetworkInterfaceInfo.InterfaceType = phys.name.hasPrefix("en") ? .ethernet : .other
            return NetworkInterfaceInfo(
                interfaceName: phys.name, ipAddress: phys.ip, macAddress: phys.macAddress,
                type: type, wifiSSID: nil, wifiRSSI: nil, linkSpeedMbps: nil
            )
        }

        // Fallback
        return getGenericInterface()
    }

    private static func getWiFiInfo(from snapshot: InterfaceSnapshot?) -> NetworkInterfaceInfo? {
        let client = CWWiFiClient.shared()
        guard let iface = client.interface(),
              let ssid = iface.ssid(),
              iface.powerOn() else { return nil }

        let rssi = iface.rssiValue()
        let linkSpeedMbps = iface.transmitRate()
        let name = iface.interfaceName ?? "en0"
        let ip = getIPAddress(for: name)
        let macAddress = iface.hardwareAddress()?.lowercased() ?? snapshot?.macAddress(for: name) ?? getMACAddress(for: name)

        return NetworkInterfaceInfo(
            interfaceName: name,
            ipAddress: ip,
            macAddress: macAddress,
            type: .wifi,
            wifiSSID: ssid,
            wifiRSSI: rssi,
            linkSpeedMbps: linkSpeedMbps > 0 ? linkSpeedMbps : nil
        )
    }

    private static func getGenericInterface() -> NetworkInterfaceInfo? {
        // Use ifconfig to find the primary active interface
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) else { continue }

            let addr = ptr.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            // Skip loopback
            guard !name.hasPrefix("lo") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: hostname)

                let type: NetworkInterfaceInfo.InterfaceType
                if name.hasPrefix("utun") || name.hasPrefix("ipsec") {
                    type = .vpn
                } else if name.hasPrefix("en") {
                    type = .ethernet
                } else {
                    type = .other
                }

                return NetworkInterfaceInfo(
                    interfaceName: name,
                    ipAddress: ip,
                    macAddress: getMACAddress(for: name),
                    type: type,
                    wifiSSID: nil,
                    wifiRSSI: nil,
                    linkSpeedMbps: nil
                )
            }
        }
        return nil
    }

    private static func getMACAddress(for interfaceName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == interfaceName,
                  let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_LINK) else {
                continue
            }
            return parseLinkLayerAddress(addr)
        }
        return nil
    }

    private static func parseLinkLayerAddress(_ address: UnsafePointer<sockaddr>) -> String? {
        let sdl = address.withMemoryRebound(to: sockaddr_dl.self, capacity: 1) { $0.pointee }
        let addressLength = Int(sdl.sdl_alen)
        guard addressLength == 6 else { return nil }

        let nameLength = Int(sdl.sdl_nlen)
        let bytes = withUnsafePointer(to: sdl.sdl_data) { pointer in
            pointer.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout.size(ofValue: sdl.sdl_data)) { dataPointer in
                (0..<addressLength).map { dataPointer[nameLength + $0] }
            }
        }
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    private static func getIPAddress(for interfaceName: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == interfaceName else { continue }
            let addr = ptr.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len),
                           &hostname, socklen_t(hostname.count),
                           nil, 0, NI_NUMERICHOST) == 0 {
                return String(cString: hostname)
            }
        }
        return nil
    }
}
