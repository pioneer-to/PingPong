//
//  GatewayService.swift
//  PingPongBar
//
//  Detects the default network gateway (router) IP address using native sysctl.
//  No subprocess spawning — reads directly from the kernel routing table.
//  VPN-aware: finds the gateway for the physical (en*) interface.
//

import Foundation

/// Retrieves the default gateway IP address from the kernel routing table.
@MainActor
enum GatewayService {
    /// Cached last known gateway IP in case the network is down.
    private static var lastKnownGateway: String?

    /// Flag to indicate network changed — set by NWPathMonitor, cleared after refresh.
    static var needsRefresh = true

    /// Get the current LAN gateway IP, or the last known one if unavailable.
    /// Uses cache unless needsRefresh is set by NWPathMonitor.
    static func getGatewayIP(snapshot: InterfaceSnapshot? = nil) async -> String? {
        if !needsRefresh, let cached = lastKnownGateway {
            return cached
        }

        let physicalIface = snapshot?.firstPhysicalInterface()?.name ?? findPhysicalInterface()
        if let gw = getGatewayViaSysctl(forInterface: physicalIface) {
            lastKnownGateway = gw
            needsRefresh = false
            return gw
        }

        // Fallback: try without interface filter
        if let gw = getGatewayViaSysctl(forInterface: nil) {
            lastKnownGateway = gw
            needsRefresh = false
            return gw
        }

        needsRefresh = false
        return lastKnownGateway
    }

    /// Read the default gateway from the kernel routing table via sysctl.
    /// If `forInterface` is specified, only return the gateway associated with that interface.
    private static func getGatewayViaSysctl(forInterface: String?) -> String? {
        // sysctl parameters: CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY
        var mib: [Int32] = [CTL_NET, AF_ROUTE, 0, AF_INET, NET_RT_FLAGS, RTF_GATEWAY]
        var bufferSize: Int = 0

        // First call: get buffer size
        guard sysctl(&mib, UInt32(mib.count), nil, &bufferSize, nil, 0) == 0, bufferSize > 0 else {
            return nil
        }

        // Second call: get actual data
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &bufferSize, nil, 0) == 0 else {
            return nil
        }

        // Parse routing messages — all pointer operations happen inside withUnsafeBufferPointer
        // to avoid UB from escaping pointers.
        return buffer.withUnsafeBytes { rawBuf -> String? in
            var offset = 0
            while offset < bufferSize {
                guard offset + MemoryLayout<rt_msghdr>.size <= bufferSize else { break }
                let msg = rawBuf.load(fromByteOffset: offset, as: rt_msghdr.self)
                let msgLen = Int(msg.rtm_msglen)
                guard msgLen > 0 else { break }
                defer { offset += msgLen }

                guard (msg.rtm_flags & RTF_GATEWAY) != 0 else { continue }

                let addrs = msg.rtm_addrs
                var saOffset = offset + MemoryLayout<rt_msghdr>.size

                // Skip DST sockaddr
                if addrs & RTA_DST != 0 {
                    guard saOffset + MemoryLayout<sockaddr>.size <= bufferSize else { continue }
                    let sa = rawBuf.load(fromByteOffset: saOffset, as: sockaddr.self)
                    let saLen = max(Int(sa.sa_len), MemoryLayout<sockaddr>.size)

                    if sa.sa_family == UInt8(AF_INET) {
                        let sin = rawBuf.load(fromByteOffset: saOffset, as: sockaddr_in.self)
                        if sin.sin_addr.s_addr != INADDR_ANY {
                            continue  // Not default route
                        }
                    }
                    saOffset += saLen
                }

                // Read GATEWAY sockaddr
                if addrs & RTA_GATEWAY != 0 {
                    guard saOffset + MemoryLayout<sockaddr>.size <= bufferSize else { continue }
                    let gwSa = rawBuf.load(fromByteOffset: saOffset, as: sockaddr.self)

                    if gwSa.sa_family == UInt8(AF_INET) {
                        let gwSin = rawBuf.load(fromByteOffset: saOffset, as: sockaddr_in.self)
                        guard let cStr = inet_ntoa(gwSin.sin_addr) else { continue }
                        let ip = String(cString: cStr)

                        if let targetIface = forInterface {
                            let ifName = interfaceName(forIndex: msg.rtm_index)
                            if ifName != targetIface { continue }
                        }

                        if ip != "0.0.0.0" && !ip.hasPrefix("127.") {
                            return ip
                        }
                    }
                }
            }
            return nil
        }
    }

    /// Get interface name for a given index.
    private static func interfaceName(forIndex index: UInt16) -> String? {
        var name = [CChar](repeating: 0, count: Int(IFNAMSIZ))
        guard if_indextoname(UInt32(index), &name) != nil else { return nil }
        return String(cString: name)
    }

    /// Find the first active physical interface (en*) with an IPv4 address.
    private static func findPhysicalInterface() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard (flags & (IFF_UP | IFF_RUNNING)) == (IFF_UP | IFF_RUNNING) else { continue }

            let name = String(cString: ptr.pointee.ifa_name)
            guard name.hasPrefix("en") else { continue }

            let addr = ptr.pointee.ifa_addr.pointee
            guard addr.sa_family == UInt8(AF_INET) else { continue }

            return name
        }
        return nil
    }
}
