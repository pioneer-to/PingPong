//
//  TracerouteService.swift
//  PongBar
//
//  On-demand traceroute using the system traceroute command.
//  Uses terminationHandler to avoid blocking cooperative threads.
//

import Foundation
import os.log

/// A single hop in a traceroute result.
nonisolated struct TracerouteHop: Identifiable {
    var id: Int { hopNumber }
    let hopNumber: Int
    let host: String
    /// The raw IP address (extracted from parentheses in traceroute output).
    let ip: String?
    let latency: String
    let isTimeout: Bool
}

/// Runs a traceroute and returns parsed hop results.
enum TracerouteService {
    /// Run traceroute to a host and return parsed hops.
    static func trace(to host: String, maxHops: Int? = nil, timeout: Int? = nil) async -> [TracerouteHop] {
        let effectiveMaxHops = maxHops ?? Config.tracerouteMaxHops
        let effectiveTimeout = timeout ?? Config.tracerouteTimeout
        guard HostValidator.isValid(host) else { return [] }
        return await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/sbin/traceroute")
            process.arguments = ["-m", "\(effectiveMaxHops)", "-q", "1", "-w", "\(effectiveTimeout)", host]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            let readGroup = DispatchGroup()
            let output = OutputBox()
            readGroup.enter()

            process.terminationHandler = { _ in
                readGroup.wait()
                let text = String(data: output.data, encoding: .utf8) ?? ""
                continuation.resume(returning: parseTraceroute(text))
            }

            do {
                try process.run()
                DispatchQueue.global(qos: .utility).async {
                    output.set(pipe.fileHandleForReading.readDataToEndOfFile())
                    readGroup.leave()
                }
            } catch {
                Logger(subsystem: "PongBar", category: "Traceroute").error("Failed to start traceroute: \(error.localizedDescription, privacy: .public)")
                readGroup.leave()
                continuation.resume(returning: [])
            }
        }
    }

    /// Parse traceroute output into hop structs.
    /// macOS traceroute format: " 1  host (ip)  1.234 ms"
    private nonisolated static func parseTraceroute(_ output: String) -> [TracerouteHop] {
        var hops: [TracerouteHop] = []
        let lines = output.components(separatedBy: "\n")

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            guard let firstChar = trimmed.first, firstChar.isNumber else { continue }

            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2, let hopNum = Int(parts.first ?? "") else { continue }

            if trimmed.contains("*") && !trimmed.contains("ms") {
                hops.append(TracerouteHop(
                    hopNumber: hopNum,
                    host: "* * *",
                    ip: nil,
                    latency: "timeout",
                    isTimeout: true
                ))
            } else {
                let host = String(parts[1])
                // Extract IP from parentheses: "hostname (1.2.3.4)" -> "1.2.3.4"
                var ip: String? = nil
                if let openParen = trimmed.firstIndex(of: "("),
                   let closeParen = trimmed.firstIndex(of: ")") {
                    ip = String(trimmed[trimmed.index(after: openParen)..<closeParen])
                } else if host.first?.isNumber == true {
                    // Host is already an IP (no hostname resolved)
                    ip = host
                }
                // Find the number right before "ms" token
                var latencyStr = "---"
                for i in 0..<parts.count {
                    if parts[i] == "ms" && i > 0 {
                        latencyStr = "\(parts[i-1]) ms"
                        break
                    }
                }
                hops.append(TracerouteHop(
                    hopNumber: hopNum,
                    host: host,
                    ip: ip,
                    latency: latencyStr,
                    isTimeout: false
                ))
            }
        }

        return hops
    }
}
