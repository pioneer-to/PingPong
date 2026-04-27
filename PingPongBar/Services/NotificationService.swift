//
//  NotificationService.swift
//  PingPongBar
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
    static func notifyDown(target: PingTarget, host: String? = nil) {
        let displayName = host ?? target.displayName
        guard shouldNotify(target: target, host: host) else { return }

        let content = UNMutableNotificationContent()
        content.title = "PingPongBar"
        content.body = "\(displayName) is unreachable"
        content.sound = .default
        content.categoryIdentifier = "OUTAGE"

        let identifier = host != nil ? "down.\(target.rawValue).\(host!).\(Date().timeIntervalSince1970)" : "down.\(target.rawValue).\(Date().timeIntervalSince1970)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        recordNotification(target: target, host: host)
    }

    /// Send a notification when a target recovers.
    static func notifyRecovery(target: PingTarget, downtime: TimeInterval, host: String? = nil) {
        let displayName = host ?? target.displayName
        guard shouldNotify(target: target, host: host) else { return }

        let content = UNMutableNotificationContent()
        content.title = "PingPongBar"
        content.body = "\(displayName) is back online (down for \(Formatters.duration(downtime)))"
        content.sound = .default
        content.categoryIdentifier = "RECOVERY"

        let identifier = host != nil ? "up.\(target.rawValue).\(host!).\(Date().timeIntervalSince1970)" : "up.\(target.rawValue).\(Date().timeIntervalSince1970)"
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
        recordNotification(target: target, host: host)
    }

    private static func shouldNotify(target: PingTarget, host: String?) -> Bool {
        // Check user preference
        if let host = host {
            // For custom targets, we need to check the NetworkMonitor state
            // Since this is a static service, we'll check UserDefaults/CustomTargetStore directly
            let targets = CustomTargetStore.load()
            if let custom = targets.first(where: { $0.host == host }) {
                guard custom.notifyDown else { return false }
            } else {
                return false
            }
        } else {
            let key = "notify.\(target.rawValue)"
            let enabled = UserDefaults.standard.object(forKey: key) as? Bool ?? true
            guard enabled else { return false }
        }

        // Check cooldown
        let cooldownKey = host ?? target.rawValue
        if let last = lastNotificationTimes[cooldownKey],
           Date().timeIntervalSince(last) < cooldown {
            return false
        }
        return true
    }

    private static var lastNotificationTimes: [String: Date] = [:]

    private static func recordNotification(target: PingTarget, host: String?) {
        let key = host ?? target.rawValue
        lastNotificationTimes[key] = Date()
    }
}
