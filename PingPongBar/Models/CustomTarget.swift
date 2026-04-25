//
//  CustomTarget.swift
//  PingPongBar
//
//  User-defined custom ping targets stored in UserDefaults.
//

import Foundation

/// A user-defined host to monitor alongside the built-in targets.
struct CustomTarget: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var host: String
    var isEnabled: Bool

    init(name: String, host: String, isEnabled: Bool = true) {
        self.id = UUID()
        self.name = name
        self.host = host
        self.isEnabled = isEnabled
    }
}

/// Manages persistence of custom targets.
enum CustomTargetStore {
    private static let key = "PingPongBar.customTargets"

    static func load() -> [CustomTarget] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let targets = try? JSONDecoder().decode([CustomTarget].self, from: data) else { return [] }
        return targets
    }

    static func save(_ targets: [CustomTarget]) {
        if let data = try? JSONEncoder().encode(targets) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
