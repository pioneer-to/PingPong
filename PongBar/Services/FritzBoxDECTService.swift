//
//  FritzBoxDECTService.swift
//  PongBar
//
//  Service for querying DECT devices via TR-064.
//

import Foundation
import os.log

public enum FritzBoxDECTService {
    private static let logger = Logger(subsystem: "de.mice.fritzbox.tr064", category: "DECT")

    public static func fetchDECTDevices(
        routerIP: String,
        username: String,
        password: String
    ) async throws -> [DECTDevice] {
        let (countData, countResponse) = try await FritzDigestAuth.sendSOAP(
            routerHost: routerIP,
            controlPath: "/upnp/control/x_dect",
            serviceURN: "urn:dslforum-org:service:X_AVM-DE_Dect:1",
            action: "GetNumberOfDectEntries",
            bodyArgs: "",
            username: username,
            password: password,
            timeout: 5
        )

        guard countResponse.statusCode == 200 else {
            logger.error("Failed to fetch DECT count: HTTP \(countResponse.statusCode)")
            return []
        }

        let countXML = String(data: countData, encoding: .utf8) ?? ""
        guard let countStr = extractXMLTag(countXML, tag: "NewNumberOfEntries"),
              let count = Int(countStr) else {
            logger.error("Failed to parse NewNumberOfEntries")
            return []
        }

        if count == 0 {
            return []
        }

        var devices: [DECTDevice] = []

        try await withThrowingTaskGroup(of: DECTDevice?.self) { group in
            for i in 0..<count {
                group.addTask {
                    let (entryData, entryResponse) = try await FritzDigestAuth.sendSOAP(
                        routerHost: routerIP,
                        controlPath: "/upnp/control/x_dect",
                        serviceURN: "urn:dslforum-org:service:X_AVM-DE_Dect:1",
                        action: "GetGenericDectEntry",
                        bodyArgs: "<NewIndex>\(i)</NewIndex>",
                        username: username,
                        password: password,
                        timeout: 5
                    )

                    guard entryResponse.statusCode == 200 else { return nil }

                    let entryXML = String(data: entryData, encoding: .utf8) ?? ""
                    guard let id = Self.extractXMLTag(entryXML, tag: "NewID") else { return nil }
                    let activeStr = Self.extractXMLTag(entryXML, tag: "NewActive") ?? "0"
                    let name = Self.extractXMLTag(entryXML, tag: "NewName") ?? "Unknown"
                    let model = Self.extractXMLTag(entryXML, tag: "NewModel")
                    let manufacturer = Self.extractXMLTag(entryXML, tag: "NewManufacturer")
                    let firmwareVersion = Self.extractXMLTag(entryXML, tag: "NewFirmwareVersion")

                    return DECTDevice(
                        id: id,
                        name: name,
                        active: activeStr == "1" || activeStr.lowercased() == "true",
                        manufacturer: manufacturer,
                        model: model,
                        firmwareVersion: firmwareVersion
                    )
                }
            }

            for try await device in group {
                if let device {
                    devices.append(device)
                }
            }
        }

        return devices
    }

    nonisolated private static func extractXMLTag(_ xml: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: .dotMatchesLineSeparators
        ) else {
            return nil
        }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        guard let match = regex.firstMatch(in: xml, options: [], range: nsRange),
              let range = Range(match.range(at: 1), in: xml)
        else {
            return nil
        }
        return String(xml[range]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
