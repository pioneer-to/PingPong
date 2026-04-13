//
//  Formatters.swift
//  PongBar
//
//  Formatting utilities for duration and relative time display.
//  DateFormatters are cached as static properties to avoid repeated allocation.
//

import Foundation

enum Formatters {
    // MARK: - Cached DateFormatters

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static let shortDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    // MARK: - Duration

    /// Format a time interval as a compact duration string (e.g. "2m 15s", "1h 3m").
    static func duration(_ interval: TimeInterval) -> String {
        let totalSeconds = Int(interval)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return "\(hours)h \(minutes)m"
        } else if minutes > 0 {
            return "\(minutes)m \(seconds)s"
        } else {
            return "\(seconds)s"
        }
    }

    // MARK: - Relative Time

    /// Format a date as relative time (e.g. "5 min ago", "2h ago") or absolute time.
    static func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)

        if interval < 60 {
            return "Just now"
        } else if interval < 3600 {
            let mins = Int(interval / 60)
            return "\(mins) min ago"
        } else if interval < 86400 {
            let hours = Int(interval / 3600)
            return "\(hours)h ago"
        } else {
            return dateTimeFormatter.string(from: date)
        }
    }

    /// Format a date as time only (e.g. "14:32").
    static func timeOnly(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    /// Group label for incident history sections.
    static func dayGroup(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else {
            let daysAgo = calendar.dateComponents([.day], from: date, to: Date()).day ?? 0
            if daysAgo < 7 && daysAgo >= 2 {
                return "Last 7 days"
            } else {
                return shortDateFormatter.string(from: date)
            }
        }
    }

    // MARK: - Throughput

    /// Format bytes/sec into human-readable throughput string.
    /// Returns nil if below display threshold (< 1 KB/s).
    static func bytesPerSecond(_ bps: Double) -> String? {
        if bps < 1024 { return nil }

        let kb = bps / 1024.0
        if kb < 1000 {
            return String(format: "%.0f KB/s", kb)
        }

        let mb = kb / 1024.0
        if mb < 10 {
            return String(format: "%.1f MB/s", mb)
        }
        if mb < 1000 {
            return String(format: "%.0f MB/s", mb)
        }

        let gb = mb / 1024.0
        return String(format: "%.1f GB/s", gb)
    }

    // MARK: - Local Device Speed

    /// Format local link speed in Mbit/s or Gbit/s.
    static func localDeviceSpeed(_ speedMbps: Double?) -> String {
        guard let speedMbps else { return "---" }
        if speedMbps >= 1000 {
            let gbit = speedMbps / 1000
            return String(format: "%.1f Gbit/s", gbit)
        }
        return String(format: "%.0f Mbit/s", speedMbps)
    }

    /// Format local link speed as a plain numeric value in Mbit/s (without unit).
    static func localDeviceSpeedPlain(_ speedMbps: Double?) -> String {
        guard let speedMbps else { return "---" }
        return String(format: "%.0f", speedMbps)
    }
}
