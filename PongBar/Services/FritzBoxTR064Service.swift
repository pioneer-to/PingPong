//
//  FritzBoxTR064Service.swift
//  PongBar
//
//  Handles native TR-064 communication with a FritzBox router to retrieve LAN network devices.
//

import Foundation

enum FritzBoxError: Error {
    case invalidURL
    case authenticationFailed
    case networkError(Error)
    case xmlParsingError
    case missingCredentials
}

/// A lightweight, Native Swift implementation of TR-064 for fetching local hosts.
final class FritzBoxTR064Service {
    static let shared = FritzBoxTR064Service()
    nonisolated private static let fixedRouterHost = "192.168.178.1"
    
    /// Fetches all active connected devices to the router
    nonisolated func fetchConnectedDevices(routerIP: String) async throws -> [LocalNetworkDevice] {
        try await fetchConnectedDevices(
            routerIP: routerIP,
            username: Config.fritzUsername,
            password: Config.fritzPassword
        )
    }

    /// Fetches all active connected devices to the router using explicit credentials.
    nonisolated func fetchConnectedDevices(routerIP: String, username: String, password: String) async throws -> [LocalNetworkDevice] {
        try await fetchConnectedDevicesUnlocked(routerIP: routerIP, username: username, password: password)
    }

    /// Fetches connection speed values (Mbit/s) per host MAC using GetGenericHostEntry.
    /// Returns a dictionary keyed by normalized lowercased MAC addresses.
    nonisolated func fetchHostSpeeds(routerIP: String, username: String, password: String) async throws -> [String: Double] {
        try await fetchHostSpeedsUnlocked(routerIP: routerIP, username: username, password: password)
    }

    nonisolated private func fetchConnectedDevicesUnlocked(routerIP: String, username: String, password: String) async throws -> [LocalNetworkDevice] {
        let sanitizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedUsername.isEmpty, !sanitizedPassword.isEmpty else {
            throw FritzBoxError.missingCredentials
        }

        // Prefer the fast two-step host list path flow first.
        print("[TR064] fetchConnectedDevices: fast host-list path start (timeout: 15s)")
        if let hosts = await TR064HostService.fetchHostsFast(
            routerIP: routerIP,
            username: sanitizedUsername,
            password: sanitizedPassword,
            timeout: 15
        ) {
            let mapped = hosts.compactMap { host -> LocalNetworkDevice? in
                guard host.active else { return nil }
                return LocalNetworkDevice(
                    macAddress: host.mac,
                    ipAddress: host.ip ?? "",
                    originalName: host.name ?? "Unknown",
                    customName: "",
                    symbolName: "desktopcomputer",
                    notifyConnectivityDown: false,
                    usePing: false,
                    pingSupported: nil,
                    pingProbeLastCheckedAt: nil
                )
            }
            print("[TR064] fast path succeeded: \(hosts.count) hosts")
            return mapped
        }

        // Fallback to full enumeration when fast host-list path is unavailable.
        print("[TR064] fetchConnectedDevices: slow fallback enumeration start")
        let totalHosts = try await getHostNumberOfEntries(
            routerIP: routerIP,
            username: sanitizedUsername,
            password: sanitizedPassword
        )

        var activeDevices: [LocalNetworkDevice] = []
        try await withThrowingTaskGroup(of: LocalNetworkDevice?.self) { group in
            for i in 0..<totalHosts {
                group.addTask {
                    guard let hostInfo = try? await self.getGenericHostEntry(
                        routerIP: routerIP,
                        index: i,
                        username: sanitizedUsername,
                        password: sanitizedPassword
                    ) else { return nil }
                    guard hostInfo.active else { return nil }
                    return LocalNetworkDevice(
                        macAddress: hostInfo.mac,
                        ipAddress: hostInfo.ip,
                        originalName: hostInfo.name,
                        customName: "",
                        symbolName: "desktopcomputer",
                        notifyConnectivityDown: false,
                        usePing: false,
                        pingSupported: nil,
                        pingProbeLastCheckedAt: nil
                    )
                }
            }

            for try await maybeDevice in group {
                if let device = maybeDevice {
                    activeDevices.append(device)
                }
            }
        }
        return activeDevices
    }

    nonisolated private func fetchHostSpeedsUnlocked(routerIP: String, username: String, password: String) async throws -> [String: Double] {
        let sanitizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitizedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitizedUsername.isEmpty, !sanitizedPassword.isEmpty else {
            throw FritzBoxError.missingCredentials
        }

        let totalHosts = try await getHostNumberOfEntries(
            routerIP: routerIP,
            username: sanitizedUsername,
            password: sanitizedPassword
        )
        var speeds: [String: Double] = [:]

        try await withThrowingTaskGroup(of: (String, Double)?.self) { group in
            for i in 0..<totalHosts {
                group.addTask {
                    let bodyArgs = "<NewIndex>\(i)</NewIndex>"
                    guard let xmlData = try? await self.sendRequest(
                        routerIP: routerIP,
                        username: sanitizedUsername,
                        password: sanitizedPassword,
                        action: "GetGenericHostEntry",
                        bodyArgs: bodyArgs
                    ) else {
                        return nil
                    }
                    let mac = self.extractXMLTag(xmlData, tag: "NewMACAddress") ?? ""
                    guard !mac.isEmpty else { return nil }
                    guard let speed = self.parseSpeedMbps(from: xmlData) else { return nil }
                    return (self.normalizeMACToKey(mac), speed)
                }
            }

            for try await pair in group {
                if let (mac, speed) = pair {
                    speeds[mac] = speed
                }
            }
        }

        return speeds
    }
    
    // MARK: - SOAP Requests
    
    nonisolated private func getHostNumberOfEntries(routerIP: String, username: String, password: String) async throws -> Int {
        let xmlData = try await sendRequest(
            routerIP: routerIP,
            username: username,
            password: password,
            action: "GetHostNumberOfEntries",
            bodyArgs: ""
        )
        if let match = extractXMLTag(xmlData, tag: "NewHostNumberOfEntries"), let count = Int(match) {
            return count
        }
        throw FritzBoxError.xmlParsingError
    }
    
    nonisolated private func getGenericHostEntry(
        routerIP: String,
        index: Int,
        username: String,
        password: String
    ) async throws -> (mac: String, ip: String, active: Bool, name: String) {
        let xmlData = try await sendRequest(
            routerIP: routerIP,
            username: username,
            password: password,
            action: "GetGenericHostEntry",
            bodyArgs: "<NewIndex>\(index)</NewIndex>"
        )
        
        let mac = extractXMLTag(xmlData, tag: "NewMACAddress") ?? ""
        let ip = extractXMLTag(xmlData, tag: "NewIPAddress") ?? ""
        let activeStr = extractXMLTag(xmlData, tag: "NewActive") ?? "0"
        let name = extractXMLTag(xmlData, tag: "NewHostName") ?? "Unknown"
        
        return (mac: mac, ip: ip, active: activeStr == "1", name: name)
    }
    
    nonisolated private func sendRequest(
        routerIP: String,
        username: String,
        password: String,
        action: String,
        bodyArgs: String
    ) async throws -> String {
        let routerHost = normalizedRouterHost(from: routerIP)
        do {
            let result = try await FritzDigestAuth.sendSOAP(
                routerHost: routerHost,
                controlPath: "/upnp/control/hosts",
                serviceURN: "urn:dslforum-org:service:Hosts:1",
                action: action,
                bodyArgs: bodyArgs,
                username: username,
                password: password,
                timeout: 5
            )
            return String(data: result.data, encoding: .utf8) ?? ""
        } catch let error as FritzBoxError {
            throw error
        } catch let error as FritzDigestAuthError {
            switch error {
            case .httpStatus(401, _), .missingDigestChallenge:
                throw FritzBoxError.authenticationFailed
            default:
                throw FritzBoxError.networkError(error)
            }
        } catch {
            throw FritzBoxError.networkError(error)
        }
    }
    
    // Fallback simple regex extraction instead of overhead of full XMLParser for small responses
    nonisolated private func extractXMLTag(_ xml: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return nil }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        
        if let match = regex.firstMatch(in: xml, options: [], range: nsRange) {
            if let range = Range(match.range(at: 1), in: xml) {
                return String(xml[range])
            }
        }
        return nil
    }

    nonisolated private func parseSpeedMbps(from xml: String) -> Double? {
        let tags = [
            "NewX_AVM-DE_Speed",
            "NewX_AVM_DE_Speed",
            "X_AVM-DE_Speed",
            "X_AVM_DE_Speed",
            "NewSpeed"
        ]
        var raw: String?
        for tag in tags {
            if let value = extractXMLTag(xml, tag: tag), !value.isEmpty {
                raw = value
                break
            }
        }
        guard let raw else { return nil }
        if let direct = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return direct
        }
        guard let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)"),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
              let range = Range(match.range(at: 1), in: raw)
        else {
            return nil
        }
        return Double(String(raw[range]))
    }

    nonisolated private func normalizeMACToKey(_ mac: String) -> String {
        let hexOnly = mac.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard hexOnly.count == 12 else { return mac.lowercased() }
        var result = ""
        for (i, ch) in hexOnly.enumerated() {
            if i > 0 && i % 2 == 0 { result.append(":") }
            result.append(ch)
        }
        return result.lowercased()
    }

    nonisolated private func normalizedRouterHost(from routerIP: String) -> String {
        let trimmed = routerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return Self.fixedRouterHost
        }
        if let url = URL(string: trimmed), let host = url.host, !host.isEmpty {
            return host
        }
        return trimmed
    }

}
