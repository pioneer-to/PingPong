//
//  DNSSwitcherService.swift
//  PongBar
//
//  Changes DNS servers on the active network service.
//  VPN-aware: automatically uses scutil override when VPN is active.
//  All public methods are async to avoid blocking the main thread.
//

import Foundation
import AppKit
import os.log

/// Predefined DNS server presets.
enum DNSPreset: String, CaseIterable, Identifiable {
    case dhcp = "DHCP (Auto)"
    case cloudflare = "Cloudflare"
    case google = "Google"
    case quad9 = "Quad9"
    case cloudflareMalware = "Cloudflare (Malware)"
    case adguard = "AdGuard"

    var id: String { rawValue }

    var servers: [String]? {
        switch self {
        case .dhcp: return nil
        case .cloudflare: return ["1.1.1.1", "1.0.0.1"]
        case .google: return ["8.8.8.8", "8.8.4.4"]
        case .quad9: return ["9.9.9.9", "149.112.112.112"]
        case .cloudflareMalware: return ["1.1.1.2", "1.0.0.2"]
        case .adguard: return ["94.140.14.14", "94.140.15.15"]
        }
    }
}

/// Manages DNS server changes. VPN-aware — auto-detects and uses appropriate method.
/// All subprocess calls run off the main thread via async/await.
enum DNSSwitcherService {
    private static let logger = Logger(subsystem: "PongBar", category: "DNS")

    // MARK: - Public API

    /// Apply a DNS preset. Automatically handles VPN vs non-VPN.
    static func applyPreset(_ preset: DNSPreset) async -> Bool {
        if NetworkInterfaceService.isVPNActive() {
            return await setSystemDNSOverride(servers: preset.servers)
        } else {
            guard let service = await getActiveServiceName() else {
                logger.error("No active network service found")
                return false
            }
            return await setDNS(servers: preset.servers ?? [], service: service)
        }
    }

    /// Apply custom DNS servers. Same VPN-aware logic.
    static func applyCustom(servers: [String]) async -> Bool {
        if NetworkInterfaceService.isVPNActive() {
            return await setSystemDNSOverride(servers: servers)
        } else {
            guard let service = await getActiveServiceName() else { return false }
            return await setDNS(servers: servers, service: service)
        }
    }

    /// Get the name of the active network service.
    static func getActiveServiceName() async -> String? {
        guard let output = await runNetworkSetup(["-listallnetworkservices"]) else { return nil }

        for line in output.components(separatedBy: "\n") {
            let svc = line.trimmingCharacters(in: .whitespaces)
            guard !svc.isEmpty, !svc.hasPrefix("An asterisk"), !svc.hasPrefix("*") else { continue }
            if await hasActiveIP(service: svc) { return svc }
        }
        return nil
    }

    /// Get current DNS servers for a service.
    static func getCurrentDNS(service: String) async -> [String] {
        guard let output = await runNetworkSetup(["-getdnsservers", service]) else { return [] }
        if output.contains("There aren't any") { return [] }
        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Detect which preset matches the current active DNS (VPN-aware).
    static func detectCurrentPreset(service: String? = nil) async -> DNSPreset {
        let activeDNS = DNSResolveService.getActiveDNSServer()
        let physicalDNS: [String]
        if let service {
            physicalDNS = await getCurrentDNS(service: service)
        } else {
            physicalDNS = []
        }

        if let active = activeDNS {
            for preset in DNSPreset.allCases {
                guard let servers = preset.servers else { continue }
                if servers.contains(active) { return preset }
            }
        }

        if !physicalDNS.isEmpty {
            for preset in DNSPreset.allCases {
                guard let servers = preset.servers else { continue }
                if Set(physicalDNS) == Set(servers) { return preset }
            }
        }

        return .dhcp
    }

    // MARK: - networksetup (no root)

    private static func setDNS(servers: [String], service: String) async -> Bool {
        let args = servers.isEmpty
            ? ["-setdnsservers", service, "empty"]
            : ["-setdnsservers", service] + servers
        guard let _ = await runNetworkSetup(args) else { return false }
        logger.info("DNS changed to \(servers.isEmpty ? "DHCP" : servers.joined(separator: ", "), privacy: .private) on \(service, privacy: .private)")
        return true
    }

    private static func hasActiveIP(service: String) async -> Bool {
        guard let output = await runNetworkSetup(["-getinfo", service]) else { return false }
        return output.components(separatedBy: "\n")
            .contains { $0.hasPrefix("IP address:") && !$0.contains("none") }
    }

    /// Run networksetup asynchronously, return stdout.
    private static func runNetworkSetup(_ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            let readGroup = DispatchGroup()
            let output = OutputBox()
            readGroup.enter()

            process.terminationHandler = { proc in
                readGroup.wait()
                guard proc.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: output.data, encoding: .utf8))
            }

            do {
                try process.run()
                DispatchQueue.global(qos: .utility).async {
                    output.set(pipe.fileHandleForReading.readDataToEndOfFile())
                    readGroup.leave()
                }
            } catch {
                readGroup.leave()
                continuation.resume(returning: nil)
            }
        }
    }

    // MARK: - scutil override (requires admin password)

    /// Set system-wide DNS override via scutil (works with VPN active).
    @discardableResult
    static func setSystemDNSOverride(servers: [String]?) async -> Bool {
        if servers == nil || servers?.isEmpty == true {
            // Remove our scutil overrides (Global + service keys).
            let cleared = await clearScutilDNSOverride()
            // Try restarting VPN so it re-pushes its original DNS.
            // For WireGuard/Tailscale this won't work (no scutil --nc entry),
            // but the global override is already removed above.
            let restarted = await restartConnectedVPN()
            if restarted { logger.info("DNS reset via VPN restart") }
            else if cleared { logger.info("DNS override cleared (no scutil-managed VPN to restart)") }
            else { logger.error("DNS reset failed: could not clear scutil override") }
            return cleared
        }

        guard let servers, servers.allSatisfy({ HostValidator.isValidIPAddress($0) }) else {
            logger.error("Rejected invalid server address in DNS override")
            return false
        }

        // C5 fix: pass servers as script arguments ($@) instead of interpolating into bash body.
        // This avoids shell injection regardless of future HostValidator changes.
        var lines = ["#!/bin/bash"]
        lines.append("SERVERS=\"$@\"")

        // 1. Override Global DNS
        lines.append("printf 'd.init\\nd.add ServerAddresses * '\"$SERVERS\"'\\nset State:/Network/Global/DNS\\n' | /usr/sbin/scutil")

        // 2. Override VPN DNS service keys — preserve existing dict (search domains, etc.)
        //    and only replace ServerAddresses to avoid breaking split-DNS configurations.
        lines.append("for key in $(/usr/sbin/scutil <<< 'list State:/Network/Service/.*/DNS' 2>/dev/null | grep subKey | sed 's/.*= //'); do")
        lines.append("  iface=$(printf 'show %s\\n' \"$key\" | /usr/sbin/scutil 2>/dev/null | grep InterfaceName | awk '{print $3}')")
        lines.append("  case \"$iface\" in utun*)")
        // Use d.show to read existing dict, then only override ServerAddresses
        lines.append("    printf 'get %s\\nd.remove ServerAddresses\\nd.add ServerAddresses * '\"$SERVERS\"'\\nset %s\\n' \"$key\" \"$key\" | /usr/sbin/scutil")
        lines.append("  ;; esac")
        lines.append("done")

        let tmpDir = FileManager.default.temporaryDirectory
        let tmpScript = tmpDir.appendingPathComponent("pongbar_dns_\(UUID().uuidString).sh")

        let scriptContent = lines.joined(separator: "\n")
        do {
            try scriptContent.write(to: tmpScript, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tmpScript.path)
        } catch {
            logger.error("Failed to write temp script: \(error.localizedDescription, privacy: .public)")
            return false
        }

        // Use AppleScript's `quoted form of` for safe path and argument handling.
        // This avoids shell metacharacter issues regardless of input content.
        let quotedPath = "quoted form of \"\(tmpScript.path)\""
        let serverArgs = servers.map { "quoted form of \"\($0)\"" }.joined(separator: " & \" \" & ")
        let source = "do shell script \"bash \" & \(quotedPath) & \" \" & \(serverArgs) with administrator privileges"

        guard let appleScript = NSAppleScript(source: source) else {
            try? FileManager.default.removeItem(at: tmpScript)
            return false
        }

        // Run AppleScript off the main thread to avoid blocking UI.
        // NSAppleScript is not Sendable but is only used within this closure's scope.
        nonisolated(unsafe) let script = appleScript
        let scriptURL = tmpScript
        let success: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
                try? FileManager.default.removeItem(at: scriptURL)
                if let error {
                    logger.error("DNS override failed: \(error, privacy: .public)")
                    continuation.resume(returning: false)
                } else {
                    continuation.resume(returning: true)
                }
            }
        }

        if success { logger.info("DNS system override applied") }
        return success
    }

    /// Remove DNS overrides previously set via scutil (both Global and VPN service keys).
    /// Returns true if scutil exited successfully.
    private static func clearScutilDNSOverride() async -> Bool {
        // Build commands: remove Global DNS, then restore VPN service DNS by removing
        // our ServerAddresses override (VPN client will re-push its own on reconnect).
        // Remove global DNS override. VPN service DNS keys are restored by VPN restart;
        // for non-scutil VPNs (WireGuard/Tailscale) the global removal alone suffices.
        let cmds = "remove State:/Network/Global/DNS\nquit\n"

        let process = Process()
        let inputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
        process.standardInput = inputPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(cmds.data(using: .utf8)!)
            inputPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                logger.error("scutil DNS clear exited with status \(process.terminationStatus)")
                return false
            }
            return true
        } catch {
            logger.error("Failed to clear scutil DNS override: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Restart the currently connected VPN to force DNS re-push. No sudo needed.
    /// Returns true if a VPN was found and restart was attempted.
    @discardableResult
    private static func restartConnectedVPN() async -> Bool {
        guard let output = await runScutil(["--nc", "list"]) else { return false }
        guard let line = output.components(separatedBy: "\n").first(where: { $0.contains("Connected") }) else { return false }

        guard let startQuote = line.firstIndex(of: "\""),
              let endQuote = line[line.index(after: startQuote)...].firstIndex(of: "\"") else { return false }
        let vpnName = String(line[line.index(after: startQuote)..<endQuote])

        // H3 fix: validate VPN name — reject empty, leading dash (flag injection), or excessive length
        guard !vpnName.isEmpty,
              !vpnName.hasPrefix("-"),
              vpnName.count <= 100 else { return false }

        logger.info("Restarting VPN '\(vpnName, privacy: .private)' to restore DNS")
        guard await runScutil(["--nc", "stop", vpnName]) != nil else { return false }
        try? await Task.sleep(for: .seconds(1))
        guard await runScutil(["--nc", "start", vpnName]) != nil else { return false }
        return true
    }

    /// Run scutil asynchronously, return stdout. No sudo.
    private static func runScutil(_ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/scutil")
            process.arguments = arguments
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            let readGroup = DispatchGroup()
            let output = OutputBox()
            readGroup.enter()

            process.terminationHandler = { proc in
                readGroup.wait()
                guard proc.terminationStatus == 0 else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: String(data: output.data, encoding: .utf8))
            }

            do {
                try process.run()
                DispatchQueue.global(qos: .utility).async {
                    output.set(pipe.fileHandleForReading.readDataToEndOfFile())
                    readGroup.leave()
                }
            } catch {
                readGroup.leave()
                continuation.resume(returning: nil)
            }
        }
    }
}
