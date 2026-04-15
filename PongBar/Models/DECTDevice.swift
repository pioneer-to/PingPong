//
//  DECTDevice.swift
//  PongBar
//
//  Represents a DECT device connected to the Fritz!Box.
//

import Foundation

public struct DECTDevice: Identifiable, Codable, Equatable, Hashable {
    public var id: String
    public var name: String
    public var active: Bool
    public var manufacturer: String?
    public var model: String?
    public var firmwareVersion: String?
}
