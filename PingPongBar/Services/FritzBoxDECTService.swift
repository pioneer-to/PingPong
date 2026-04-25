//
//  FritzBoxDECTService.swift
//  PingPongBar
//
//  Service for querying DECT devices via TR-064.
//

import Foundation
import os.log

public enum FritzBoxDECTService {
    private static let logger = Logger(subsystem: "de.mice.fritzbox.tr064", category: "DECT")

    private static let dectControlPath = "/upnp/control/x_dect"
    private static let dectServiceURN = "urn:dslforum-org:service:X_AVM-DE_Dect:1"
    private static let onTelControlPath = "/upnp/control/x_contact"
    private static let onTelServiceURN = "urn:dslforum-org:service:X_AVM-DE_OnTel:1"
    private static let voipControlPath = "/upnp/control/x_voip"
    private static let voipServiceURN = "urn:dslforum-org:service:X_VoIP:1"

    private static let inventoryMaxAge: TimeInterval = 24 * 60 * 60
    private static let inventoryCache = DECTInventoryCache()

    public static func fetchDECTDevices(
        routerIP: String,
        username: String,
        password: String,
        forceInventoryRefresh: Bool = false
    ) async throws -> [DECTDevice] {
        let inventory = try await inventoryCache.getOrLoad(
            routerIP: routerIP,
            username: username,
            forceRefresh: forceInventoryRefresh,
            maxAge: inventoryMaxAge
        ) {
            try await loadDECTInventory(routerIP: routerIP, username: username, password: password)
        }

        let activeCallState = await fetchActiveCallState(
            routerIP: routerIP,
            username: username,
            password: password
        )

        let devices = inventory.map { item in
            let normalized = normalizedName(item.name)
            let inCallByName = activeCallState.activeNames.contains(normalized)
            let inCallByID = activeCallState.activeHandsetIDs.contains(item.id)
            return DECTDevice(
                id: item.id,
                name: item.name,
                active: item.active,
                isInCall: inCallByName || inCallByID,
                internalNumber: item.internalNumber,
                externalNumber: item.externalNumber,
                manufacturer: item.manufacturer,
                model: item.model,
                firmwareVersion: item.firmwareVersion
            )
        }

        return devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public static func ringPhone(
        routerIP: String,
        username: String,
        password: String,
        internalNumber: String,
        preferredHandsetName: String? = nil,
        ringDuration: TimeInterval = 12,
        onLog: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let sanitizedRouterIP = routerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        let sanitized = internalNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sanitized.isEmpty else { return }

        // 1. Try modern X_AVM-DE_OnTel:Ring action (preferred)
        // This uses NewAppId and usually doesn't require "Dialing Help" to be enabled on the box.
        let ontelNumber = sanitized.hasPrefix("**") ? String(sanitized.dropFirst(2)) : sanitized
        onLog?("Triggering ring for \(ontelNumber) via X_AVM-DE_OnTel (AppId: \(Config.fritzAppId))...")
        
        let ringBody = "<NewPhoneNumber>\(xmlEscaped(ontelNumber))</NewPhoneNumber><NewDuration>\(Int(ringDuration))</NewDuration><NewAppId>\(xmlEscaped(Config.fritzAppId))</NewAppId>"
        
        var ontelSucceeded = false
        do {
            let (_, response) = try await FritzDigestAuth.sendSOAP(
                routerHost: sanitizedRouterIP,
                controlPath: onTelControlPath,
                serviceURN: onTelServiceURN,
                action: "Ring",
                bodyArgs: ringBody,
                username: username,
                password: password,
                timeout: 8
            )
            if response.statusCode == 200 {
                onLog?("Ring command accepted.")
                ontelSucceeded = true
            } else {
                onLog?("X_AVM-DE_OnTel:Ring rejected (HTTP \(response.statusCode)).")
            }
        } catch {
            onLog?("X_AVM-DE_OnTel:Ring failed: \(error.localizedDescription)")
        }
        
        if ontelSucceeded {
            try? await Task.sleep(for: .seconds(ringDuration))
            return
        }

        // 2. Fallback to legacy DialNumber trick (X_VoIP)
        onLog?("Falling back to legacy DialNumber trick...")
        let basicDialBody = "<NewX_AVM-DE_PhoneNumber>\(xmlEscaped(sanitized))</NewX_AVM-DE_PhoneNumber>"
        do {
            onLog?("Dial via FritzDigestAuth (x_voip)...")
            let (_, response) = try await FritzDigestAuth.sendSOAP(
                routerHost: sanitizedRouterIP,
                controlPath: voipControlPath,
                serviceURN: voipServiceURN,
                action: "X_AVM-DE_DialNumber",
                bodyArgs: basicDialBody,
                username: username,
                password: password,
                timeout: 8
            )
            onLog?("Dial command accepted (HTTP \(response.statusCode)).")
        } catch {
            onLog?("Primary dial failed: \(error.localizedDescription)")
            onLog?("Retrying with handset-select flow (DialSetConfig + DialNumber)...")

            let selectedPhoneNames = selectedPhoneNameVariants(preferredHandsetName)
            guard !selectedPhoneNames.isEmpty else {
                throw NSError(
                    domain: "PingPongBar.DECT",
                    code: 501,
                    userInfo: [NSLocalizedDescriptionKey: "No selected handset name available for safe dialing"]
                )
            }

            onLog?("Using selected handset only: \(selectedPhoneNames.joined(separator: " | "))")

            var setConfigSucceeded = false
            var setConfigError = "unknown error"
            var secondFactorRequired = false
            for phoneName in selectedPhoneNames {
                onLog?("Attempt: DialSetConfig(phoneName=\(phoneName))")
                let setConfigBody = "<NewX_AVM-DE_PhoneName>\(xmlEscaped(phoneName))</NewX_AVM-DE_PhoneName>"
                do {
                    let (_, response) = try await FritzDigestAuth.sendSOAP(
                        routerHost: sanitizedRouterIP,
                        controlPath: voipControlPath,
                        serviceURN: voipServiceURN,
                        action: "X_AVM-DE_DialSetConfig",
                        bodyArgs: setConfigBody,
                        username: username,
                        password: password,
                        timeout: 10
                    )
                    onLog?("  -> accepted (HTTP \(response.statusCode))")
                    setConfigSucceeded = true
                    break
                } catch let digestError as FritzDigestAuthError {
                    switch digestError {
                    case .httpStatus(let code, let body):
                        let snippet = compactSOAPFault(body)
                        setConfigError = "HTTP \(code): \(snippet)"
                        onLog?("  -> rejected: \(setConfigError)")
                        if upnpErrorCode(from: body) == "866" {
                            secondFactorRequired = true
                            onLog?("  -> Router requires second-factor confirmation for DialSetConfig (UPnP 866).")
                        }
                    default:
                        setConfigError = digestError.localizedDescription
                        onLog?("  -> error: \(setConfigError)")
                    }
                } catch {
                    setConfigError = error.localizedDescription
                    onLog?("  -> error: \(setConfigError)")
                }
            }

            if !setConfigSucceeded {
                onLog?("Dial aborted for safety: selected handset could not be activated.")
                if secondFactorRequired {
                    onLog?("Hint: allow telephony control without extra confirmation for this FRITZ!Box user.")
                }
                throw NSError(
                    domain: "PingPongBar.DECT",
                    code: 500,
                    userInfo: [NSLocalizedDescriptionKey: "Dial failed: unable to select handset (\(setConfigError))"]
                )
            }

            let numberAttempts = [sanitized, sanitized + "#"]
            var succeeded = false
            var lastErrorLine = "unknown error"
            for phoneNumber in numberAttempts {
                onLog?("Attempt: DialNumber(\(phoneNumber))")
                do {
                    let (_, response) = try await FritzDigestAuth.sendSOAP(
                        routerHost: sanitizedRouterIP,
                        controlPath: voipControlPath,
                        serviceURN: voipServiceURN,
                        action: "X_AVM-DE_DialNumber",
                        bodyArgs: "<NewX_AVM-DE_PhoneNumber>\(xmlEscaped(phoneNumber))</NewX_AVM-DE_PhoneNumber>",
                        username: username,
                        password: password,
                        timeout: 10
                    )
                    onLog?("  -> accepted (HTTP \(response.statusCode))")
                    succeeded = true
                    break
                } catch let digestError as FritzDigestAuthError {
                    switch digestError {
                    case .httpStatus(let code, let body):
                        let snippet = compactSOAPFault(body)
                        lastErrorLine = "HTTP \(code): \(snippet)"
                        onLog?("  -> rejected: \(lastErrorLine)")
                    default:
                        lastErrorLine = digestError.localizedDescription
                        onLog?("  -> error: \(lastErrorLine)")
                    }
                } catch {
                    lastErrorLine = error.localizedDescription
                    onLog?("  -> error: \(lastErrorLine)")
                    continue
                }
            }

            if !succeeded {
                onLog?("Dial failed after all fallback attempts.")
                onLog?("Hint: verify FRITZ!Box user has telephony rights and handset number is callable.")
                throw NSError(domain: "PingPongBar.DECT", code: 500, userInfo: [NSLocalizedDescriptionKey: "Dial failed: \(lastErrorLine)"])
            }
        }

        var cancellationError: Error?
        do {
            onLog?("Ringing for \(Int(ringDuration))s...")
            try await Task.sleep(for: .seconds(ringDuration))
        } catch {
            cancellationError = error
            onLog?("Ring process interrupted: \(error.localizedDescription)")
        }

        do {
            onLog?("Sending hangup...")
            try await hangupCall(routerIP: sanitizedRouterIP, username: username, password: password)
            onLog?("Hangup sent.")
        } catch {
            onLog?("Hangup failed: \(error.localizedDescription)")
            throw error
        }

        if let cancellationError {
            throw cancellationError
        }
    }

    public static func hangupCall(
        routerIP: String,
        username: String,
        password: String
    ) async throws {
        let sanitizedRouterIP = routerIP.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            _ = try await FritzDigestAuth.sendSOAP(
                routerHost: sanitizedRouterIP,
                controlPath: voipControlPath,
                serviceURN: voipServiceURN,
                action: "X_AVM-DE_DialHangup",
                bodyArgs: "",
                username: username,
                password: password,
                timeout: 5
            )
        } catch {
            _ = try await sendSOAPReferenceStyle(
                routerIP: sanitizedRouterIP,
                controlPath: voipControlPath,
                serviceURN: voipServiceURN,
                action: "X_AVM-DE_DialHangup",
                bodyArgs: "",
                username: username,
                password: password,
                timeout: 5
            )
        }
    }

    nonisolated public static func defaultInternalNumber(forDeviceID id: String) -> String? {
        guard let numericID = Int(id), (1...6).contains(numericID) else { return nil }
        return "**61\(numericID - 1)"
    }

    private static func loadDECTInventory(
        routerIP: String,
        username: String,
        password: String
    ) async throws -> [DECTInventoryItem] {
        let knownHandsetIDs = await fetchKnownHandsetIDs(
            routerIP: routerIP,
            username: username,
            password: password
        )
        let handsetDetailsByID = await fetchHandsetDetailsByID(
            routerIP: routerIP,
            username: username,
            password: password,
            ids: knownHandsetIDs
        )

        let (countData, countResponse) = try await FritzDigestAuth.sendSOAP(
            routerHost: routerIP,
            controlPath: dectControlPath,
            serviceURN: dectServiceURN,
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
              let count = Int(countStr), count > 0 else {
            return []
        }

        var devices: [DECTInventoryItem] = []

        await withTaskGroup(of: DECTInventoryItem?.self) { group in
            for i in 0..<count {
                group.addTask {
                    guard let (entryData, entryResponse) = try? await FritzDigestAuth.sendSOAP(
                        routerHost: routerIP,
                        controlPath: dectControlPath,
                        serviceURN: dectServiceURN,
                        action: "GetGenericDectEntry",
                        bodyArgs: "<NewIndex>\(i)</NewIndex>",
                        username: username,
                        password: password,
                        timeout: 5
                    ) else { return nil }

                    guard entryResponse.statusCode == 200 else { return nil }

                    let entryXML = String(data: entryData, encoding: .utf8) ?? ""
                    guard let id = Self.extractXMLTag(entryXML, tag: "NewID") else { return nil }

                    let activeRaw = Self.extractXMLTag(entryXML, tag: "NewActive")
                    let activeFromDect = Self.isTruthy(activeRaw)
                    let active = activeFromDect || knownHandsetIDs.contains(id)

                    let details = handsetDetailsByID[id]
                    let name = (
                        Self.extractXMLTag(entryXML, tag: "NewName")
                        ?? details?.name
                        ?? "Unknown"
                    )

                    let model = Self.extractXMLTag(entryXML, tag: "NewModel")
                    let manufacturer = Self.extractXMLTag(entryXML, tag: "NewManufacturer")
                    let firmwareVersion = Self.extractXMLTag(entryXML, tag: "NewFirmwareVersion")

                    return DECTInventoryItem(
                        id: id,
                        name: name,
                        active: active,
                        internalNumber: details?.internalNumber ?? defaultInternalNumber(forDeviceID: id),
                        externalNumber: details?.externalNumber,
                        manufacturer: manufacturer,
                        model: model,
                        firmwareVersion: firmwareVersion
                    )
                }
            }

            for await device in group {
                if let device {
                    devices.append(device)
                }
            }
        }

        return devices
    }

    private static func fetchKnownHandsetIDs(
        routerIP: String,
        username: String,
        password: String
    ) async -> Set<String> {
        do {
            let (data, response) = try await FritzDigestAuth.sendSOAP(
                routerHost: routerIP,
                controlPath: onTelControlPath,
                serviceURN: onTelServiceURN,
                action: "GetDECTHandsetList",
                bodyArgs: "",
                username: username,
                password: password,
                timeout: 5
            )
            guard response.statusCode == 200 else { return [] }
            let xml = String(data: data, encoding: .utf8) ?? ""
            guard let raw = extractXMLTag(xml, tag: "NewDectIDList") else { return [] }
            let ids = raw
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            return Set(ids)
        } catch {
            return []
        }
    }

    private static func fetchHandsetDetailsByID(
        routerIP: String,
        username: String,
        password: String,
        ids: Set<String>
    ) async -> [String: DECTHandsetDetails] {
        guard !ids.isEmpty else { return [:] }
        var detailsByID: [String: DECTHandsetDetails] = [:]
        for id in ids {
            do {
                let (data, response) = try await FritzDigestAuth.sendSOAP(
                    routerHost: routerIP,
                    controlPath: onTelControlPath,
                    serviceURN: onTelServiceURN,
                    action: "GetDECTHandsetInfo",
                    bodyArgs: "<NewDectID>\(id)</NewDectID>",
                    username: username,
                    password: password,
                    timeout: 5
                )
                guard response.statusCode == 200 else { continue }
                let xml = String(data: data, encoding: .utf8) ?? ""

                let name = extractXMLTag(xml, tag: "NewHandsetName")
                let internalNumber = firstNonEmptyTag(in: xml, tags: [
                    "NewInternalNumber",
                    "NewX_AVM-DE_InternalNumber",
                    "NewX_AVM_DE_InternalNumber"
                ])
                let externalNumber = firstNonEmptyTag(in: xml, tags: [
                    "NewOutgoingNumber",
                    "NewX_AVM-DE_OutGoingNumber",
                    "NewX_AVM_DE_OutGoingNumber",
                    "NewMSN",
                    "NewPhoneNumber"
                ])

                detailsByID[id] = DECTHandsetDetails(
                    name: name,
                    internalNumber: internalNumber,
                    externalNumber: externalNumber
                )
            } catch {
                continue
            }
        }
        return detailsByID
    }

    private static func fetchActiveCallState(
        routerIP: String,
        username: String,
        password: String
    ) async -> (activeNames: Set<String>, activeHandsetIDs: Set<String>) {
        do {
            let (data, response) = try await FritzDigestAuth.sendSOAP(
                routerHost: routerIP,
                controlPath: onTelControlPath,
                serviceURN: onTelServiceURN,
                action: "GetCallList",
                bodyArgs: "",
                username: username,
                password: password,
                timeout: 5
            )
            guard response.statusCode == 200 else { return ([], []) }
            let xml = String(data: data, encoding: .utf8) ?? ""
            guard let callListURLValue = extractXMLTag(xml, tag: "NewCallListURL"),
                  let callListURL = resolveURL(callListURLValue, routerIP: routerIP) else {
                return ([], [])
            }

            let callListXML = try await fetchCallListXML(
                url: callListURL,
                username: username,
                password: password
            )
            return parseActiveCallState(callListXML)
        } catch {
            return ([], [])
        }
    }

    private static func fetchCallListXML(
        url: URL,
        username: String,
        password: String
    ) async throws -> String {
        do {
            let config = URLSessionConfiguration.ephemeral
            config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            config.urlCache = nil
            let session = URLSession(configuration: config)
            let (data, response) = try await session.data(from: url)
            if let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
               let xml = String(data: data, encoding: .utf8), !xml.isEmpty {
                return xml
            }
        } catch {
            // fall through to digest GET
        }

        let (data, _) = try await FritzDigestAuth.get(
            url: url,
            username: username,
            password: password,
            timeout: 5
        )
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parseActiveCallState(_ callListXML: String) -> (activeNames: Set<String>, activeHandsetIDs: Set<String>) {
        guard let callRegex = try? NSRegularExpression(
            pattern: "<Call>(.*?)</Call>",
            options: [.dotMatchesLineSeparators]
        ) else {
            return ([], [])
        }

        let nsRange = NSRange(callListXML.startIndex..<callListXML.endIndex, in: callListXML)
        let matches = callRegex.matches(in: callListXML, options: [], range: nsRange)

        var activeNames = Set<String>()
        var activeIDs = Set<String>()

        for match in matches {
            guard let range = Range(match.range(at: 1), in: callListXML) else { continue }
            let callXML = String(callListXML[range])
            let typeValue = extractXMLTag(callXML, tag: "Type") ?? ""
            // 9 = active incoming, 11 = active outgoing
            guard typeValue == "9" || typeValue == "11" else { continue }

            if let deviceName = extractXMLTag(callXML, tag: "Device") {
                let normalized = normalizedName(deviceName)
                if !normalized.isEmpty {
                    activeNames.insert(normalized)
                }
            }

            if let port = extractXMLTag(callXML, tag: "Port") {
                activeIDs.formUnion(possibleDectIDs(fromPort: port))
            }
        }

        return (activeNames, activeIDs)
    }

    private static func possibleDectIDs(fromPort rawPort: String) -> Set<String> {
        let port = rawPort.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !port.isEmpty else { return [] }

        var ids = Set<String>()

        if let number = Int(port), (1...6).contains(number) {
            ids.insert(String(number))
        }

        if let regex = try? NSRegularExpression(pattern: "\\*\\*61([0-5])") {
            let nsRange = NSRange(port.startIndex..<port.endIndex, in: port)
            if let match = regex.firstMatch(in: port, range: nsRange),
               let digitRange = Range(match.range(at: 1), in: port),
               let digit = Int(String(port[digitRange])) {
                ids.insert(String(digit + 1))
            }
        }

        return ids
    }

    private static func resolveURL(_ rawURL: String, routerIP: String) -> URL? {
        if let absolute = URL(string: rawURL), absolute.scheme != nil {
            return absolute
        }
        let path = rawURL.hasPrefix("/") ? rawURL : "/\(rawURL)"
        return URL(string: "http://\(routerIP)\(path)")
    }

    nonisolated private static func isTruthy(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !value.isEmpty else {
            return false
        }
        if let number = Int(value) {
            return number != 0
        }
        return ["true", "yes", "on", "active", "connected", "online"].contains(value)
    }

    nonisolated private static func normalizedName(_ raw: String) -> String {
        raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "  ", with: " ")
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

    nonisolated private static func firstNonEmptyTag(in xml: String, tags: [String]) -> String? {
        for tag in tags {
            if let value = extractXMLTag(xml, tag: tag), !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func fetchPhonePorts(
        routerIP: String,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async throws -> [FritzPhonePort] {
        var ports: [FritzPhonePort] = []

        for index in 1...16 {
            let bodyArgs = "<NewIndex>\(index)</NewIndex>"
            let result = try await sendSOAPReferenceStyleAllowError(
                routerIP: routerIP,
                controlPath: voipControlPath,
                serviceURN: voipServiceURN,
                action: "X_AVM-DE_GetPhonePort",
                bodyArgs: bodyArgs,
                username: username,
                password: password,
                timeout: timeout
            )

            guard (200..<300).contains(result.statusCode) else {
                if index <= 4 {
                    continue
                }
                break
            }

            guard let name = extractXMLTag(result.body, tag: "NewX_AVM-DE_PhoneName"), !name.isEmpty else {
                continue
            }
            ports.append(FritzPhonePort(index: index, name: name))
        }

        return ports
    }

    private static func selectedDialPhoneNames(
        ports: [FritzPhonePort],
        preferredHandsetName: String?
    ) -> [String] {
        guard !ports.isEmpty else { return [] }
        let preferred = preferredHandsetName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard !preferred.isEmpty else { return [] }

        let exactMatches = ports
            .filter { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == preferred }
            .sorted { $0.index < $1.index }
            .map(\.name)
        if !exactMatches.isEmpty {
            return exactMatches
        }

        return ports
            .filter { $0.name.lowercased().contains(preferred) }
            .sorted { $0.index < $1.index }
            .map(\.name)
    }

    private static func selectedPhoneNameVariants(_ preferredHandsetName: String?) -> [String] {
        guard let preferred = preferredHandsetName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !preferred.isEmpty else {
            return []
        }

        var names: [String] = [preferred]
        let lower = preferred.lowercased()
        if !lower.hasPrefix("dect:") {
            names.append("DECT: \(preferred)")
        }

        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func normalizedPhoneName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func sendSOAPReferenceStyleAllowError(
        routerIP: String,
        controlPath: String,
        serviceURN: String,
        action: String,
        bodyArgs: String,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async throws -> (statusCode: Int, body: String) {
        guard let url = URL(string: "http://\(routerIP):49000\(controlPath)") else {
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        request.setValue("\(serviceURN)#\(action)", forHTTPHeaderField: "SOAPAction")
        request.httpBody = soapEnvelope(action: action, serviceURN: serviceURN, bodyArgs: bodyArgs).data(using: .utf8)

        let delegate = DigestURLSessionDelegate(username: username, password: password)
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.urlCache = nil
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)

        var lastError: Error?
        for attempt in 1...5 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }
                let body = String(data: data, encoding: .utf8) ?? ""
                return (http.statusCode, body)
            } catch {
                lastError = error
                if attempt < 5, isTransientLocalNetworkPermissionError(error) {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                throw error
            }
        }

        throw lastError ?? URLError(.timedOut)
    }

    private static func sendSOAPReferenceStyle(
        routerIP: String,
        controlPath: String,
        serviceURN: String,
        action: String,
        bodyArgs: String,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async throws -> Int {
        let result = try await sendSOAPReferenceStyleAllowError(
            routerIP: routerIP,
            controlPath: controlPath,
            serviceURN: serviceURN,
            action: action,
            bodyArgs: bodyArgs,
            username: username,
            password: password,
            timeout: timeout
        )
        guard (200..<300).contains(result.statusCode) else {
            throw NSError(
                domain: "PingPongBar.DECT.SOAP",
                code: result.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "SOAP \(action) failed with HTTP \(result.statusCode): \(result.body)"]
            )
        }
        return result.statusCode
    }

    nonisolated private static func compactSOAPFault(_ body: String) -> String {
        let code = extractXMLTag(body, tag: "errorCode")
        let desc = extractXMLTag(body, tag: "errorDescription")
        if let code, let desc {
            return "UPnP \(code): \(desc)"
        }
        if let desc {
            return desc
        }
        let trimmed = body.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.prefix(220))
    }

    nonisolated private static func upnpErrorCode(from body: String) -> String? {
        extractXMLTag(body, tag: "errorCode")
    }

    nonisolated private static func soapEnvelope(action: String, serviceURN: String, bodyArgs: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(serviceURN)">\(bodyArgs)</u:\(action)>
          </s:Body>
        </s:Envelope>
        """
    }

    nonisolated private static func xmlEscaped(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    nonisolated private static func isTransientLocalNetworkPermissionError(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return hasCFStream2102(error)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return hasCFStream2102(error)
        }
        return false
    }

    nonisolated private static func hasCFStream2102(_ error: Error) -> Bool {
        var queue: [NSError] = [error as NSError]
        var visited = Set<ObjectIdentifier>()
        while let current = queue.popLast() {
            let id = ObjectIdentifier(current)
            if visited.contains(id) { continue }
            visited.insert(id)

            let code = (current.userInfo["_kCFStreamErrorCodeKey"] as? Int)
                ?? (current.userInfo["kCFStreamErrorCodeKey"] as? Int)
            let domain = (current.userInfo["_kCFStreamErrorDomainKey"] as? Int)
                ?? (current.userInfo["kCFStreamErrorDomainKey"] as? Int)
            if code == -2102, domain == 4 {
                return true
            }

            for value in current.userInfo.values {
                if let nested = value as? NSError {
                    queue.append(nested)
                }
            }
        }
        return false
    }
}

private struct FritzPhonePort: Sendable {
    let index: Int
    let name: String
}

private struct DECTInventoryItem: Codable, Sendable {
    let id: String
    let name: String
    let active: Bool
    let internalNumber: String?
    let externalNumber: String?
    let manufacturer: String?
    let model: String?
    let firmwareVersion: String?
}

private struct DECTHandsetDetails: Sendable {
    let name: String?
    let internalNumber: String?
    let externalNumber: String?
}

private final class DigestURLSessionDelegate: NSObject, URLSessionTaskDelegate {
    private let credential: URLCredential

    init(username: String, password: String) {
        self.credential = URLCredential(user: username, password: password, persistence: .forSession)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodHTTPDigest || method == NSURLAuthenticationMethodDefault {
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

private actor DECTInventoryCache {
    private struct Entry {
        let key: String
        let refreshedAt: Date
        let items: [DECTInventoryItem]
    }

    private var entry: Entry?

    func getOrLoad(
        routerIP: String,
        username: String,
        forceRefresh: Bool,
        maxAge: TimeInterval,
        loader: @escaping @Sendable () async throws -> [DECTInventoryItem]
    ) async throws -> [DECTInventoryItem] {
        let key = "\(routerIP.lowercased())|\(username.lowercased())"
        if !forceRefresh,
           let entry,
           entry.key == key,
           Date().timeIntervalSince(entry.refreshedAt) < maxAge {
            return entry.items
        }

        let loaded = try await loader()
        entry = Entry(key: key, refreshedAt: Date(), items: loaded)
        return loaded
    }
}
