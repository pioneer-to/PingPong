//
//  InterfaceSnapshot.swift
//  PongBar
//
//  Single getifaddrs() call per tick. All services read from this snapshot
//  instead of calling getifaddrs() independently.
//

import Foundation

/// Parsed data for one network interface entry from getifaddrs().
struct InterfaceEntry {
    let name: String
    let flags: Int32
    let family: UInt8
    let address: String?
    /// AF_LINK entries carry traffic counters.
    let bytesIn: UInt64?
    let bytesOut: UInt64?

    var isUp: Bool { (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) }
    var isIPv4: Bool { family == UInt8(AF_INET) }
    var isLink: Bool { family == UInt8(AF_LINK) }
}

/// One-shot snapshot of all network interfaces. Call once per monitoring tick.
struct InterfaceSnapshot {
    let entries: [InterfaceEntry]
    let timestamp: Date

    /// Take a snapshot by calling getifaddrs() once.
    static func capture() -> InterfaceSnapshot {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return InterfaceSnapshot(entries: [], timestamp: Date())
        }
        defer { freeifaddrs(ifaddr) }

        let now = Date()
        var entries: [InterfaceEntry] = []

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let name = String(cString: ptr.pointee.ifa_name)
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addrPtr = ptr.pointee.ifa_addr else { continue }
            let family = addrPtr.pointee.sa_family

            var address: String? = nil
            if family == UInt8(AF_INET) || family == UInt8(AF_INET6) {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let sa = ptr.pointee.ifa_addr
                let saLen = family == UInt8(AF_INET)
                    ? socklen_t(MemoryLayout<sockaddr_in>.size)
                    : socklen_t(MemoryLayout<sockaddr_in6>.size)
                if getnameinfo(sa, saLen, &hostname, socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                    address = String(cString: hostname)
                }
            }

            // Traffic counters from AF_LINK entries
            var bytesIn: UInt64? = nil
            var bytesOut: UInt64? = nil
            if family == UInt8(AF_LINK), let dataPtr = ptr.pointee.ifa_data {
                let ifData = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                bytesIn = UInt64(ifData.ifi_ibytes)
                bytesOut = UInt64(ifData.ifi_obytes)
            }

            entries.append(InterfaceEntry(
                name: name, flags: flags, family: family,
                address: address, bytesIn: bytesIn, bytesOut: bytesOut
            ))
        }

        return InterfaceSnapshot(entries: entries, timestamp: now)
    }

    // MARK: - Convenience queries

    /// First active physical interface (en*) with IPv4 address.
    func firstPhysicalInterface() -> (name: String, ip: String)? {
        for entry in entries where entry.isUp && entry.isIPv4 && entry.name.hasPrefix("en") {
            if let ip = entry.address {
                return (entry.name, ip)
            }
        }
        return nil
    }

    /// Traffic counters keyed by interface name (from AF_LINK entries).
    func trafficCounters() -> [String: InterfaceCounters] {
        let now = timestamp
        var result: [String: InterfaceCounters] = [:]
        for entry in entries where entry.isLink && entry.isUp && !entry.name.hasPrefix("lo") {
            if let bytesIn = entry.bytesIn, let bytesOut = entry.bytesOut {
                result[entry.name] = InterfaceCounters(
                    interfaceName: entry.name,
                    bytesIn: bytesIn, bytesOut: bytesOut,
                    timestamp: now
                )
            }
        }
        return result
    }
}
