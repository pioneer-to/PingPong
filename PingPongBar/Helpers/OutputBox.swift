//
//  OutputBox.swift
//  PingPongBar
//
//  Thread-safe container for subprocess output data.
//  Eliminates shared mutable capture warnings in Sendable closures.
//

import Foundation

/// Thread-safe data box for capturing subprocess output across isolation domains.
/// Uses NSLock for synchronization — safe to access from any thread/actor context.
nonisolated final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private nonisolated(unsafe) var _data = Data()

    var data: Data {
        lock.lock()
        defer { lock.unlock() }
        return _data
    }

    func set(_ newData: Data) {
        lock.lock()
        _data = newData
        lock.unlock()
    }
}
