//
//  NotificationService.swift
//  PongBar
//
//  macOS user notifications for network outages and recovery events.
//  Respects cooldown intervals and per-target preferences.
//

import Foundation
import UserNotifications

/// Manages macOS notifications for network status changes.
@MainActor
enum NotificationService {
    /// Cooldown: minimum seconds between notifications for the same target.
    private static var lastNotificationTime: [PingTarget: Date] = [:]
    private static var cooldown: TimeInterval { Config.notificationCooldown }

    /// Request notification permission on first use.
    static func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// Send a notification when a target goes down.
    static func notifyDown(target: PingTarget) {
        guard shouldNotify(target: target) else { return }

        let content = UNMutableNotificationContent()
        content.title = "PongBar"
        content.body = "\(target.displayName) is unreachable"
        content.sound = .default
        content.categoryIdentifier = "OUTAGE"

        let request = UNNotificationRequest(
            identifier: "down.\(target.rawValue).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        lastNotificationTime[target] = Date()
    }

    /// Send a notification when a target recovers.
    static func notifyRecovery(target: PingTarget, downtime: TimeInterval) {
        guard shouldNotify(target: target) else { return }

        let content = UNMutableNotificationContent()
        content.title = "PongBar"
        content.body = "\(target.displayName) is back online (down for \(Formatters.duration(downtime)))"
        content.sound = .default
        content.categoryIdentifier = "RECOVERY"

        let request = UNNotificationRequest(
            identifier: "up.\(target.rawValue).\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        lastNotificationTime[target] = Date()
    }

    private static func shouldNotify(target: PingTarget) -> Bool {
        // Check user preference
        let key = "notify.\(target.rawValue)"
        let enabled = UserDefaults.standard.object(forKey: key) as? Bool ?? true
        guard enabled else { return false }

        // Check cooldown
        if let last = lastNotificationTime[target],
           Date().timeIntervalSince(last) < cooldown {
            return false
        }
        return true
    }
}
