//
//  PublicIPService.swift
//  PingPongBar
//
//  Detects the public IP address using lightweight HTTP APIs.
//  Re-fetches when NWPathMonitor detects a network change (e.g. VPN toggle).
//

import Foundation
import os.log

/// Fetches the public-facing IP address.
@MainActor
enum PublicIPService {
    /// Cached public IP.
    private(set) static var currentIP: String?

    /// Whether a fetch is in progress.
    private static var isFetching = false

    /// Clear cached IP (e.g. on network change before re-fetching).
    static func clearCache() {
        currentIP = nil
    }

    /// Fetch public IP from a fast, lightweight API.
    /// Uses multiple endpoints for redundancy and an ephemeral session
    /// to avoid reusing stale connections after VPN/network changes.
    static func fetch() async -> String? {
        // Respect user privacy preference
        guard UserDefaults.standard.object(forKey: Config.Keys.showPublicIP) as? Bool ?? true else {
            currentIP = nil  // Clear cached IP when disabled
            return nil
        }
        guard !isFetching else { return currentIP }
        isFetching = true
        defer { isFetching = false }

        // Try multiple endpoints in order of speed
        let endpoints = [
            "https://ifconfig.co/ip",
            "https://ident.me"
        ]

        for endpoint in endpoints {
            if let ip = await fetchFrom(endpoint) {
                currentIP = ip
                return ip
            }
        }

        // All endpoints failed — keep stale IP to avoid UI flicker during transient failures.
        // IP is cleared only when user disables the feature.
        return currentIP
    }

    private static func fetchFrom(_ urlString: String) async -> String? {
        guard let url = URL(string: urlString) else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        request.cachePolicy = .reloadIgnoringLocalCacheData

        // Ephemeral session avoids reusing connections from the previous
        // network/VPN state, which would return a stale IP.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let ip = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let ip, !ip.isEmpty, ip.count < 46 else { return nil }
            // Validate IP format — only digits, dots, colons, hex letters (IPv4/IPv6)
            guard ip.range(of: #"^[\d.:a-fA-F]+$"#, options: .regularExpression) != nil else { return nil }
            return ip
        } catch {
            Logger(subsystem: "PingPongBar", category: "PublicIP").debug("Fetch failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
