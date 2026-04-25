//
//  PingService.swift
//  PingPongBar
//
//  ICMP ping via /sbin/ping subprocess.
//  Uses thread-safe OutputBox to avoid shared mutable capture warnings.
//

import Foundation
import os.log

/// Performs ICMP ping to a given host using the system ping command.
enum PingService {
    /// Ping a host and return the latency in milliseconds, or nil if unreachable.
    static func ping(_ host: String, timeout: Int? = nil) async -> Double? {
        let effectiveTimeout = timeout ?? Config.pingTimeout
        guard HostValidator.isValid(host) else { return nil }
        return await withCheckedContinuation { continuation in
            let process = Process()
            let pipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = ["-c", "1", "-W", "\(effectiveTimeout * 1000)", host]
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

                let text = String(data: output.data, encoding: .utf8) ?? ""
                if let range = text.range(of: #"time=(\d+\.?\d*)"#, options: .regularExpression) {
                    let value = text[range].replacingOccurrences(of: "time=", with: "")
                    continuation.resume(returning: Double(value))
                } else {
                    continuation.resume(returning: nil)
                }
            }

            do {
                try process.run()
                DispatchQueue.global(qos: .utility).async {
                    output.set(pipe.fileHandleForReading.readDataToEndOfFile())
                    readGroup.leave()
                }
            } catch {
                Logger(subsystem: "PingPongBar", category: "Ping").error("Failed to start ping: \(error.localizedDescription, privacy: .public)")
                readGroup.leave()
                continuation.resume(returning: nil)
            }
        }
    }
}
