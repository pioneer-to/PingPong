//
//  HostValidator.swift
//  PongBar
//
//  Validates that a host string is a safe hostname or IP address
//  before passing it to Process() or network calls.
//

import Foundation

enum HostValidator {
    /// Validate that a string is a safe hostname or IP address.
    /// Rejects strings that could be interpreted as flags or contain shell metacharacters.
    static func isValid(_ host: String) -> Bool {
        let trimmed = host.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }
        // Reject anything starting with a dash (would be treated as a flag by ping/traceroute)
        guard !trimmed.hasPrefix("-") else { return false }
        // Only allow alphanumerics, dots, hyphens, colons (IPv6), brackets (IPv6)
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: ".-:[]"))
        return trimmed.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// Validate that a string is an IP address literal (IPv4 or IPv6).
    /// Rejects hostnames — for use when only an IP is acceptable (e.g. DNS server address).
    static func isValidIPAddress(_ address: String) -> Bool {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        // Try parsing as IPv4 or IPv6 using POSIX inet_pton
        var sin = sockaddr_in()
        var sin6 = sockaddr_in6()
        if inet_pton(AF_INET, trimmed, &sin.sin_addr) == 1 { return true }
        if inet_pton(AF_INET6, trimmed, &sin6.sin6_addr) == 1 { return true }
        return false
    }

    /// Validate a DNS domain name (e.g. "apple.com").
    /// Must contain at least one dot, labels max 63 chars, total max 253.
    static func isValidDomain(_ domain: String) -> Bool {
        let trimmed = domain.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }
        guard trimmed.contains(".") else { return false }
        guard !trimmed.hasPrefix("."), !trimmed.hasSuffix(".") else { return false }

        let labels = trimmed.split(separator: ".")
        guard labels.count >= 2 else { return false }

        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: "-"))
        for label in labels {
            guard !label.isEmpty, label.count <= 63 else { return false }
            guard label.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return false }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
        }
        return true
    }
}
