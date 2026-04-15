//
//  DNSResolveService.swift
//  PongBar
//
//  DNS resolution check by sending a raw UDP DNS query directly to the active
//  DNS server. Measures actual RTT to the DNS server, bypassing system cache.
//

import Foundation
import SystemConfiguration

/// Checks DNS resolution by querying the DNS server directly via UDP.
enum DNSResolveService {
    private static let cacheLock = NSLock()
    private static var cachedServer: String?

    /// Clears the cached DNS server so the next resolution call will fetch the active DNS configuration.
    static func clearCache() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cachedServer = nil
    }

    /// Send a DNS query to the active DNS server and measure RTT.
    static func resolve(domain: String? = nil) async -> Double? {
        let effectiveDomain = domain ?? Config.dnsTestDomain
        guard let dnsServer = getActiveDNSServer() else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let result = queryDNS(server: dnsServer, domain: effectiveDomain, timeoutSeconds: Config.dnsTimeout)
                continuation.resume(returning: result)
            }
        }
    }

    /// Get the primary DNS server currently in use by the system resolver.
    static func getActiveDNSServer() -> String? {
        cacheLock.lock()
        if let cached = cachedServer {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        guard let store = SCDynamicStoreCreate(nil, "PongBar" as CFString, nil, nil) else { return nil }

        var result: String? = nil

        // 1. Global DNS
        if let dict = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any],
           let servers = dict["ServerAddresses"] as? [String],
           let first = servers.first {
            result = first
        }

        // 2. VPN service DNS
        if result == nil, let keys = SCDynamicStoreCopyKeyList(store, "State:/Network/Service/.*/DNS" as CFString) as? [String] {
            for key in keys {
                if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                   let iface = dict["InterfaceName"] as? String,
                   iface.hasPrefix("utun"),
                   let servers = dict["ServerAddresses"] as? [String],
                   let first = servers.first {
                    result = first
                    break
                }
            }
            // 3. Any service DNS
            if result == nil {
                for key in keys {
                    if let dict = SCDynamicStoreCopyValue(store, key as CFString) as? [String: Any],
                       let servers = dict["ServerAddresses"] as? [String],
                       let first = servers.first {
                        result = first
                        break
                    }
                }
            }
        }

        // 4. Setup DNS
        if result == nil, let dict = SCDynamicStoreCopyValue(store, "Setup:/Network/Global/DNS" as CFString) as? [String: Any],
           let servers = dict["ServerAddresses"] as? [String],
           let first = servers.first {
            result = first
        }

        cacheLock.lock()
        cachedServer = result
        cacheLock.unlock()

        return result
    }

    // MARK: - Raw UDP DNS Query

    /// Send a DNS A query via UDP directly to the given server and measure RTT.
    private static func queryDNS(server: String, domain: String, timeoutSeconds: Int) -> Double? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP
        var serverInfo: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(server, "53", &hints, &serverInfo) == 0, let info = serverInfo else { return nil }
        defer { freeaddrinfo(serverInfo) }

        let sock = socket(info.pointee.ai_family, SOCK_DGRAM, IPPROTO_UDP)
        guard sock >= 0 else { return nil }
        defer { close(sock) }

        var tv = timeval(tv_sec: __darwin_time_t(timeoutSeconds), tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let packet = buildDNSQuery(domain: domain)
        guard !packet.isEmpty else { return nil }

        let start = CFAbsoluteTimeGetCurrent()
        let sent = packet.withUnsafeBytes { buf in
            sendto(sock, buf.baseAddress, buf.count, 0, info.pointee.ai_addr, info.pointee.ai_addrlen)
        }
        guard sent > 0 else { return nil }

        var buffer = [UInt8](repeating: 0, count: 512)
        let received = recv(sock, &buffer, buffer.count, 0)
        let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000

        guard received > 0 else { return nil }
        guard received >= 12 else { return nil }

        return elapsed
    }

    /// Build a minimal DNS query packet for an A record lookup.
    private static func buildDNSQuery(domain: String) -> [UInt8] {
        var packet: [UInt8] = []

        let txID = UInt16.random(in: 1...UInt16.max)
        packet.append(UInt8(txID >> 8))
        packet.append(UInt8(txID & 0xFF))
        packet.append(0x01)
        packet.append(0x00)
        packet.append(contentsOf: [0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])

        for label in domain.split(separator: ".") {
            guard label.count <= 63 else { return [] }
            packet.append(UInt8(label.count))
            packet.append(contentsOf: label.utf8)
        }
        packet.append(0x00)
        packet.append(contentsOf: [0x00, 0x01, 0x00, 0x01])

        return packet
    }
}
