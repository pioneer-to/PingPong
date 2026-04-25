import Foundation
import os.log

public struct TR064Host: Codable {
    public let mac: String
    public let ip: String?
    public let active: Bool
    public let name: String?
    public let speedMbps: Double?
    public let band: String?
    public let signalStrengthPercent: Int?
}

public struct TR064HostDebugAttributes {
    public let mac: String?
    public let ip: String?
    public let name: String?
    public let active: String?
    public let speed: String?
    public let signalStrength: String?
    public let mesh: String?
    public let interfaceType: String?
    public let sourceAction: String
    public let diagnostic: String
}

public struct TR064WiFiAssociationInfo {
    public let band: String?
    public let signalStrengthPercent: Int?
    public let ipAddress: String?
}

public enum TR064HostService {
    private static let logger = Logger(subsystem: "de.mice.fritzbox.tr064", category: "TR064HostService")
    private static let fixedRouterHost = "192.168.178.1"
    private static let tr064DebugLoggingEnabled = true
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }()
    private static let hostFetchCoordinator = TR064HostFetchCoordinator()

    private static func tr064DebugLog(_ message: @autoclosure () -> String) {
        guard tr064DebugLoggingEnabled else {
            return
        }
        print(message())
    }

    /// Fetch host list from Fritz!Box router using TR-064 Hosts service.
    /// - Parameters:
    ///   - routerIP: IP or hostname of the router
    ///   - username: Username for basic auth
    ///   - password: Password for basic auth
    ///   - timeout: URLSession timeout, default 5 seconds
    /// - Returns: Array of TR064Host or nil on failure
    public static func fetchHosts(
        routerIP: String,
        username: String,
        password: String,
        timeout: TimeInterval = 5
    ) async -> [TR064Host]? {
        let key = hostFetchKey(routerIP: routerIP, username: username, password: password)
        return await hostFetchCoordinator.run(key: key) {
            await fetchHostsInternal(
                routerIP: routerIP,
                username: username,
                password: password,
                timeout: timeout,
                useHTTPS: false,
                allowEnumerationFallback: true
            )
        }
    }

    public static func fetchHostsFast(
        routerIP: String,
        username: String,
        password: String,
        timeout: TimeInterval = 4
    ) async -> [TR064Host]? {
        let key = hostFetchKey(routerIP: routerIP, username: username, password: password)
        return await hostFetchCoordinator.run(key: key) {
            await fetchHostsInternal(
                routerIP: routerIP,
                username: username,
                password: password,
                timeout: timeout,
                useHTTPS: false,
                allowEnumerationFallback: false
            )
        }
    }

    private static func fetchHostsInternal(
        routerIP: String,
        username: String,
        password: String,
        timeout: TimeInterval,
        useHTTPS: Bool,
        allowEnumerationFallback: Bool
    ) async -> [TR064Host]? {
        tr064DebugLog("[TR064] fetchHostsInternal: start timeout=\(timeout) useHTTPS=\(useHTTPS) allowFallback=\(allowEnumerationFallback)")
        let scheme = useHTTPS ? "https" : "http"
        let port = useHTTPS ? 49443 : 49000
        let baseURLString = "\(scheme)://\(normalizedRouterHost(from: routerIP)):\(port)"
        guard let baseURL = URL(string: baseURLString) else {
            logger.error("Invalid base URL: \(baseURLString, privacy: .public)")
            return nil
        }

        // Step 1: Try to get host list path by SOAP call.
        // Prefer AVM-specific action first, then generic fallback.
        let controlPath = "/upnp/control/hosts"
        let serviceURN = "urn:dslforum-org:service:Hosts:1"
        let soapBody = ""
        tr064DebugLog("[TR064] step1: calling sendHostListPathSOAP")
        guard let soapResponse = await sendHostListPathSOAP(
            baseURL: baseURL,
            controlPath: controlPath,
            serviceURN: serviceURN,
            bodyArgs: soapBody,
            username: username,
            password: password,
            timeout: timeout
        ) else {
            tr064DebugLog("[TR064] step1: FAILED - soapResponse nil, entering fallback")
            logger.debug("SOAP host-list-path actions failed, fallback to host enumeration")
            guard allowEnumerationFallback else { return nil }
            return await fetchHostsByEnumeration(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            )
        }
        tr064DebugLog("[TR064] step1: SUCCESS - \(soapResponse.count) bytes")

        // Step 2: Parse SOAP response XML for NewX_AVM-DE_HostListPath or NewHostListPath
        tr064DebugLog("[TR064] step2: parsing host list path")
        guard let hostListPath = parseHostListPath(fromSOAPResponse: soapResponse) else {
            tr064DebugLog("[TR064] step2: FAILED - no path found in SOAP response")
            logger.debug("No host list path found in SOAP response, fallback to host enumeration")
            guard allowEnumerationFallback else { return nil }
            return await fetchHostsByEnumeration(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            )
        }
        tr064DebugLog("[TR064] step2: SUCCESS - path=\(hostListPath)")

        // Step 3: Extract SID from host list path and query /data.lua on port 80.
        guard let sid = extractSID(from: hostListPath) else {
            logger.error("Invalid host list SID in path: \(hostListPath, privacy: .public)")
            return nil
        }
        let routerHost = normalizedRouterHost(from: routerIP)
        guard let dataURL = URL(string: "http://\(routerHost)/data.lua") else {
            logger.error("Invalid data.lua URL for host: \(routerHost, privacy: .public)")
            return nil
        }
        tr064DebugLog("[TR064] step3: fetching \(dataURL.absoluteString)")

        do {
            var request = URLRequest(url: dataURL)
            request.httpMethod = "POST"
            request.timeoutInterval = timeout
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.httpBody = "sid=\(sid)&page=netDev&xhrId=all".data(using: .utf8)
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            let hosts = parseHostsFromDataLua(data: data)
            tr064DebugLog("[TR064] step3: SUCCESS - \(data.count) bytes, \(hosts?.count ?? 0) hosts parsed")
            if let hosts {
                return hosts
            }
            guard allowEnumerationFallback else { return nil }
            logger.debug("Failed to parse data.lua JSON at \(dataURL.absoluteString, privacy: .public), fallback to host enumeration")
            return await fetchHostsByEnumeration(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            )
        } catch {
            tr064DebugLog("[TR064] step3: FAILED - \(error)")
            logger.error("Failed to POST data.lua at \(dataURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            guard allowEnumerationFallback else { return nil }
            return await fetchHostsByEnumeration(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            )
        }
    }

    private static func sendSOAP(
        baseURL: URL,
        controlPath: String,
        serviceURN: String,
        action: String,
        bodyArgs: String,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async -> Data? {
        do {
            guard let host = baseURL.host else { return nil }
            let result = try await FritzDigestAuth.sendSOAP(
                routerHost: host,
                controlPath: controlPath,
                serviceURN: serviceURN,
                action: action,
                bodyArgs: bodyArgs,
                username: username,
                password: password,
                timeout: timeout
            )
            return result.data
        } catch {
            logger.debug("SOAP action \(action) failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func parseHostListPath(fromSOAPResponse data: Data) -> String? {
        // We try to extract either NewX_AVM-DE_HostListPath or NewHostListPath element content
        let parser = HostListPathParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        if xmlParser.parse() {
            return parser.foundPath
        }
        return nil
    }

    private static func parseHostsFromDataLua(data: Data) -> [TR064Host]? {
        do {
            let decoded = try JSONDecoder().decode(DataLuaResponse.self, from: data)
            let devices = decoded.data?.active ?? []
            tr064DebugLog("[TR064] parseHostsFromDataLua: decoded \(devices.count) active devices")
            
            return devices.compactMap { device in
                guard let mac = device.mac, !mac.isEmpty else { return nil }
                
                let props = device.properties ?? []
                let isActive = ["led_green", "globe_online"].contains(device.state?.className) || device.state?.fos_icon?.icon == "globe_online"
                
                return TR064Host(
                    mac: mac,
                    ip: device.ipv4?.ip,
                    active: isActive,
                    name: device.name ?? "Unknown",
                    speedMbps: parseDownstreamMbps(from: props),
                    band: parseBand(from: props),
                    signalStrengthPercent: nil
                )
            }
        } catch {
            tr064DebugLog("[TR064] parseHostsFromDataLua FAILED: \(error)")
            return nil
        }
    }

    private static func parseBand(from properties: [DataLuaProperty]) -> String? {
        for prop in properties {
            guard let text = prop.txt else { continue }
            if text.contains("6 GHz") { return "6GHz" }
            if text.contains("5 GHz") { return "5GHz" }
            if text.contains("2,4 GHz") || text.contains("2.4 GHz") { return "2.4GHz" }
        }
        return nil
    }

    /// Returns dictionary keyed by lowercased mac addresses (colon-separated if present)
    /// with full TR064Host instances.
    public static func onlineMap(routerIP: String, username: String, password: String) async -> [String: TR064Host] {
        // Prefer the same TR-064 client flow used by the device picker because it
        // handles Fritz!Box auth challenges more robustly.
        if let pickerMap = await onlineMapViaFritzService(routerIP: routerIP, username: username, password: password) {
            return pickerMap
        }

        guard let hosts = await fetchHosts(routerIP: routerIP, username: username, password: password) else {
            return [:]
        }
        var map = [String: TR064Host]()
        for host in hosts {
            let key = normalizeMACToKey(host.mac)
            map[key] = host
        }
        return map
    }

    /// Fetches per-device link speed from Fritz!Box via TR-064 (NewX_AVM-DE_Speed).
    /// Returned dictionary is keyed by normalized MAC address and contains Mbit/s values.
    public static func speedMap(
        routerIP: String,
        username: String,
        password: String,
        macAddresses: [String]
    ) async -> [String: Double] {
        let uniqueKeys = Set(macAddresses.map(normalizeMACToKey))
        guard !uniqueKeys.isEmpty else { return [:] }

        // Fast path for regular monitoring: only use host-list fetch and parsed speed tags.
        // Keep deep/fallback probing for explicit debug flow.
        guard let hosts = await fetchHosts(
            routerIP: routerIP,
            username: username,
            password: password,
            timeout: 5
        ) else {
            return [:]
        }
        var result: [String: Double] = [:]
        for host in hosts {
            let key = normalizeMACToKey(host.mac)
            guard uniqueKeys.contains(key), let speed = host.speedMbps else { continue }
            result[key] = speed
        }
        return result
    }

    /// Same as `speedMap`, but also returns per-MAC diagnostics for troubleshooting.
    public static func speedMapWithDiagnostics(
        routerIP: String,
        username: String,
        password: String,
        macAddresses: [String]
    ) async -> (speeds: [String: Double], diagnostics: [String: String]) {
        let uniqueKeys = Set(macAddresses.map(normalizeMACToKey))
        guard !uniqueKeys.isEmpty else { return ([:], [:]) }

        var hostListBaseDiagnostics: [String: String] = [:]
        if let hosts = await fetchHosts(routerIP: routerIP, username: username, password: password, timeout: 8) {
            var hostListSpeeds: [String: Double] = [:]
            for host in hosts {
                let key = normalizeMACToKey(host.mac)
                guard uniqueKeys.contains(key), let speed = host.speedMbps else { continue }
                hostListSpeeds[key] = speed
            }
            if !hostListSpeeds.isEmpty {
                var diagnostics: [String: String] = [:]
                for key in uniqueKeys {
                    diagnostics[key] = hostListSpeeds[key] == nil
                        ? "HostList XML: no speed tag for this MAC"
                        : "HostList XML: speed ok"
                }
                return (hostListSpeeds, diagnostics)
            }
            for key in uniqueKeys {
                hostListBaseDiagnostics[key] = "HostList XML: no speed tag for this MAC"
            }
        }

        do {
            // Use a dedicated TR-064 client instance per speed query to avoid
            // races with other concurrent calls mutating shared auth/session state.
            let fritzService = FritzBoxTR064Service()
            let allSpeeds = try await fritzService.fetchHostSpeeds(
                routerIP: routerIP,
                username: username,
                password: password
            )
            var filtered: [String: Double] = [:]
            for key in uniqueKeys {
                if let speed = allSpeeds[key] {
                    filtered[key] = speed
                }
            }
            if !filtered.isEmpty {
                var diagnostics: [String: String] = [:]
                for key in uniqueKeys {
                    diagnostics[key] = filtered[key] == nil
                        ? "FritzService GetGenericHostEntry: no speed tag"
                        : "FritzService GetGenericHostEntry: speed ok"
                }
                return (filtered, diagnostics)
            }
        } catch {
            var diagnostics: [String: String] = [:]
            for key in uniqueKeys {
                diagnostics[key] = "FritzService speed query failed: \(error.localizedDescription)"
            }
            // Continue with HTTP-only SOAP fallback strategies below and merge diagnostics.
            let httpResult = await fetchSpeedMapInternalWithDiagnostics(
                routerIP: routerIP,
                username: username,
                password: password,
                useHTTPS: false,
                normalizedKeys: uniqueKeys
            )
            if !httpResult.speeds.isEmpty {
                var merged = hostListBaseDiagnostics
                for (key, info) in diagnostics {
                    merged[key] = "\(merged[key] ?? "") | \(info)"
                }
                for (key, info) in httpResult.diagnostics {
                    merged[key] = "\(merged[key] ?? "") | HTTP: \(info)"
                }
                return (httpResult.speeds, merged)
            }

            let fallback = await fetchSpeedMapByEnumerationWithError(
                routerIP: routerIP,
                username: username,
                password: password,
                useHTTPS: false,
                normalizedKeys: uniqueKeys
            )
            if !fallback.speeds.isEmpty {
                var merged = hostListBaseDiagnostics
                for (key, info) in diagnostics {
                    merged[key] = "\(merged[key] ?? "") | \(info)"
                }
                for (key, info) in fallback.diagnostics {
                    merged[key] = "\(merged[key] ?? "") | enum: \(info)"
                }
                return (fallback.speeds, merged)
            }

            var merged = hostListBaseDiagnostics
            for (key, info) in diagnostics {
                merged[key] = "\(merged[key] ?? "") | \(info)"
            }
            for key in uniqueKeys {
                let base = merged[key] ?? ""
                let httpInfo = httpResult.diagnostics[key] ?? "HTTP specific: no data"
                let enumInfo = fallback.error ?? "enum: no data"
                merged[key] = "\(base) | HTTP: \(httpInfo) | \(enumInfo)"
            }
            return ([:], merged)
        }

        let httpResult = await fetchSpeedMapInternalWithDiagnostics(
            routerIP: routerIP,
            username: username,
            password: password,
            useHTTPS: false,
            normalizedKeys: uniqueKeys
        )
        if !httpResult.speeds.isEmpty {
            return httpResult
        }

        let fallback = await fetchSpeedMapByEnumerationWithError(
            routerIP: routerIP,
            username: username,
            password: password,
            useHTTPS: false,
            normalizedKeys: uniqueKeys
        )
        if !fallback.speeds.isEmpty {
            var merged = httpResult.diagnostics
            for (key, info) in fallback.diagnostics {
                merged[key] = "\(httpResult.diagnostics[key] ?? "HTTP specific: no data") | enum: \(info)"
            }
            return (fallback.speeds, merged)
        }

        var mergedDiagnostics = httpResult.diagnostics
        if let error = fallback.error {
            for key in uniqueKeys {
                let previous = mergedDiagnostics[key] ?? "http: no speed"
                mergedDiagnostics[key] = "\(previous) | enum error: \(error)"
            }
        }
        return ([:], mergedDiagnostics)
    }

    /// Same as `onlineMap`, but returns a readable error string when host retrieval fails.
    public static func onlineMapWithError(
        routerIP: String,
        username: String,
        password: String
    ) async -> (map: [String: TR064Host], error: String?) {
        do {
            let service = FritzBoxTR064Service()
            let hosts = try await service.fetchConnectedTR064Hosts(
                routerIP: routerIP,
                username: username,
                password: password
            )
            var map = [String: TR064Host]()
            for host in hosts {
                map[normalizeMACToKey(host.mac)] = host
            }
            return (map, nil)
        } catch {
            let pickerError = "PickerFlow: \(error.localizedDescription)"

            let httpResult = await fetchHostsInternalWithError(
                routerIP: routerIP,
                username: username,
                password: password,
                timeout: 5,
                useHTTPS: false
            )
            if let hosts = httpResult.hosts {
                var map = [String: TR064Host]()
                for host in hosts {
                    map[normalizeMACToKey(host.mac)] = host
                }
                return (map, nil)
            }

            let httpError = httpResult.error ?? "unknown HTTP error"
            return ([:], "\(pickerError) | HTTP: \(httpError)")
        }
    }

    private static func onlineMapViaFritzService(
        routerIP: String,
        username: String,
        password: String
    ) async -> [String: TR064Host]? {
        do {
            let service = FritzBoxTR064Service()
            let hosts = try await service.fetchConnectedTR064Hosts(
                routerIP: routerIP,
                username: username,
                password: password
            )
            var map = [String: TR064Host]()
            for host in hosts {
                map[normalizeMACToKey(host.mac)] = host
            }
            return map
        } catch {
            return nil
        }
    }

    private static func fetchHostsInternalWithError(
        routerIP: String,
        username: String,
        password: String,
        timeout: TimeInterval,
        useHTTPS: Bool
    ) async -> (hosts: [TR064Host]?, error: String?) {
        let scheme = useHTTPS ? "https" : "http"
        let port = useHTTPS ? 49443 : 49000
        let baseURLString = "\(scheme)://\(normalizedRouterHost(from: routerIP)):\(port)"
        guard let baseURL = URL(string: baseURLString) else {
            return (nil, "Invalid base URL: \(baseURLString)")
        }

        let controlPath = "/upnp/control/hosts"
        let serviceURN = "urn:dslforum-org:service:Hosts:1"
        let soapBody = ""
        let soapResult = await sendHostListPathSOAPWithError(
            baseURL: baseURL,
            controlPath: controlPath,
            serviceURN: serviceURN,
            bodyArgs: soapBody,
            username: username,
            password: password,
            timeout: timeout
        )
        if let soapResponse = soapResult.data {
            if let hostListPath = parseHostListPath(fromSOAPResponse: soapResponse) {
                guard let sid = extractSID(from: hostListPath) else {
                    return (nil, "Invalid host list SID in path: \(hostListPath)")
                }
                let routerHost = normalizedRouterHost(from: routerIP)
                guard let dataURL = URL(string: "http://\(routerHost)/data.lua") else {
                    return (nil, "Invalid data.lua URL for host: \(routerHost)")
                }

                do {
                    var request = URLRequest(url: dataURL)
                    request.httpMethod = "POST"
                    request.timeoutInterval = timeout
                    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
                    request.httpBody = "sid=\(sid)&page=netDev&xhrId=all".data(using: .utf8)
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
                        return (nil, "POST data.lua failed with HTTP \(status)")
                    }
                    guard let hosts = parseHostsFromDataLua(data: data) else {
                        return (nil, "Failed to parse data.lua JSON")
                    }
                    return (hosts, nil)
                } catch {
                    return (nil, "POST data.lua failed: \(error.localizedDescription)")
                }
            } else {
                let enumeration = await fetchHostsByEnumerationWithError(
                    baseURL: baseURL,
                    username: username,
                    password: password,
                    timeout: timeout
                )
                if let hosts = enumeration.hosts {
                    return (hosts, nil)
                }
                let error = enumeration.error ?? "Failed to resolve host list path"
                return (nil, error)
            }
        } else {
            let enumeration = await fetchHostsByEnumerationWithError(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            )
            if let hosts = enumeration.hosts {
                return (hosts, nil)
            }
            let combinedError = [soapResult.error, enumeration.error]
                .compactMap { $0 }
                .joined(separator: " | fallback: ")
            return (nil, combinedError.isEmpty ? "Unknown SOAP/fallback failure" : combinedError)
        }
    }

    private static func fetchSpeedMapInternalWithDiagnostics(
        routerIP: String,
        username: String,
        password: String,
        useHTTPS: Bool,
        normalizedKeys: Set<String>
    ) async -> (speeds: [String: Double], diagnostics: [String: String]) {
        let scheme = useHTTPS ? "https" : "http"
        let port = useHTTPS ? 49443 : 49000
        let baseURLString = "\(scheme)://\(normalizedRouterHost(from: routerIP)):\(port)"
        guard let baseURL = URL(string: baseURLString) else { return ([:], [:]) }

        let serviceURN = "urn:dslforum-org:service:Hosts:1"
        var speeds: [String: Double] = [:]
        var diagnostics: [String: String] = [:]
        var ipByKey: [String: String] = [:]

        let hostsResult = await fetchHostsInternalWithError(
            routerIP: routerIP,
            username: username,
            password: password,
            timeout: 5,
            useHTTPS: useHTTPS
        )
        if let hosts = hostsResult.hosts {
            for host in hosts {
                let key = normalizeMACToKey(host.mac)
                if let ip = host.ip, !ip.isEmpty {
                    ipByKey[key] = ip
                }
            }
        }

        for key in normalizedKeys {
            let specificBodyArgs: String
            if let ip = ipByKey[key] {
                specificBodyArgs = "<NewIPAddress>\(ip)</NewIPAddress>"
            } else {
                // Fallback for firmwares that support MAC directly.
                specificBodyArgs = "<NewMACAddress>\(normalizedKeyToColonMAC(key))</NewMACAddress>"
            }
            let response = await sendSOAPWithError(
                baseURL: baseURL,
                controlPath: "/upnp/control/hosts",
                serviceURN: serviceURN,
                action: "GetSpecificHostEntry",
                bodyArgs: specificBodyArgs,
                username: username,
                password: password,
                timeout: 5
            )
            guard let payload = response.data else {
                diagnostics[key] = "GetSpecificHostEntry failed: \(response.error ?? "unknown")"
                continue
            }

            let xml = String(data: payload, encoding: .utf8) ?? ""
            if let speed = parseSpeedMbps(from: xml) {
                speeds[key] = speed
                let queryKind = ipByKey[key] == nil ? "mac-fallback" : "ip"
                diagnostics[key] = "GetSpecificHostEntry ok (\(scheme), \(queryKind))"
            } else {
                let avmByMac = await sendSOAPWithError(
                    baseURL: baseURL,
                    controlPath: "/upnp/control/hosts",
                    serviceURN: serviceURN,
                    action: "X_AVM-DE_GetSpecificHostEntryByMACAddress",
                    bodyArgs: "<NewMACAddress>\(normalizedKeyToColonMAC(key))</NewMACAddress>",
                    username: username,
                    password: password,
                    timeout: 5
                )
                if let avmData = avmByMac.data {
                    let avmXML = String(data: avmData, encoding: .utf8) ?? ""
                    if let avmSpeed = parseSpeedMbps(from: avmXML) {
                        speeds[key] = avmSpeed
                        diagnostics[key] = "X_AVM-DE_GetSpecificHostEntryByMACAddress ok (\(scheme))"
                        continue
                    }
                }

                let speedTag = extractXMLTag(xml, tag: "NewX_AVM-DE_Speed")
                    ?? extractXMLTag(xml, tag: "NewX_AVM_DE_Speed")
                    ?? "missing"
                let hostActive = extractXMLTag(xml, tag: "NewActive") ?? "missing"
                let candidates = speedCandidateTags(in: xml).joined(separator: ",")
                let avmDiag = avmByMac.error ?? "no speed in AVM action"
                diagnostics[key] = "GetSpecificHostEntry no speed (\(scheme)); speedTag=\(speedTag), active=\(hostActive), candidates=[\(candidates)], avmAction=\(avmDiag)"
            }
        }

        return (speeds, diagnostics)
    }

    private static func fetchSpeedMapByEnumerationWithError(
        routerIP: String,
        username: String,
        password: String,
        useHTTPS: Bool,
        normalizedKeys: Set<String>
    ) async -> (speeds: [String: Double], diagnostics: [String: String], error: String?) {
        let scheme = useHTTPS ? "https" : "http"
        let port = useHTTPS ? 49443 : 49000
        let baseURLString = "\(scheme)://\(normalizedRouterHost(from: routerIP)):\(port)"
        guard let baseURL = URL(string: baseURLString) else {
            return ([:], [:], "Invalid base URL: \(baseURLString)")
        }

        let serviceURN = "urn:dslforum-org:service:Hosts:1"
        let countResponse = await sendSOAPWithError(
            baseURL: baseURL,
            controlPath: "/upnp/control/hosts",
            serviceURN: serviceURN,
            action: "GetHostNumberOfEntries",
            bodyArgs: "",
            username: username,
            password: password,
            timeout: 5
        )
        guard let countData = countResponse.data else {
            return ([:], [:], "GetHostNumberOfEntries failed: \(countResponse.error ?? "unknown")")
        }
        let countXML = String(data: countData, encoding: .utf8) ?? ""
        guard let countStr = extractXMLTag(countXML, tag: "NewHostNumberOfEntries"),
              let count = Int(countStr),
              count > 0 else {
            return ([:], [:], "No host entries")
        }

        var speeds: [String: Double] = [:]
        var diagnostics: [String: String] = [:]
        var seenKeys: Set<String> = []

        for index in 0..<count {
            let entryResponse = await sendSOAPWithError(
                baseURL: baseURL,
                controlPath: "/upnp/control/hosts",
                serviceURN: serviceURN,
                action: "GetGenericHostEntry",
                bodyArgs: "<NewIndex>\(index)</NewIndex>",
                username: username,
                password: password,
                timeout: 5
            )
            guard let entryData = entryResponse.data else { continue }
            let entryXML = String(data: entryData, encoding: .utf8) ?? ""
            guard let mac = extractXMLTag(entryXML, tag: "NewMACAddress") else { continue }
            let key = normalizeMACToKey(mac)
            guard normalizedKeys.contains(key) else { continue }

            seenKeys.insert(key)
            if let speed = parseSpeedMbps(from: entryXML) {
                speeds[key] = speed
                diagnostics[key] = "GetGenericHostEntry speed=\(speed) (\(scheme))"
            } else {
                let raw = extractXMLTag(entryXML, tag: "NewX_AVM-DE_Speed")
                    ?? extractXMLTag(entryXML, tag: "NewX_AVM_DE_Speed")
                    ?? "missing"
                diagnostics[key] = "GetGenericHostEntry no speed (\(scheme)); raw=\(raw)"
            }
        }

        for key in normalizedKeys where !seenKeys.contains(key) {
            diagnostics[key] = "GetGenericHostEntry: MAC not found (\(scheme))"
        }

        return (speeds, diagnostics, nil)
    }

    private static func sendSOAPWithError(
        baseURL: URL,
        controlPath: String,
        serviceURN: String,
        action: String,
        bodyArgs: String,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async -> (data: Data?, error: String?) {
        do {
            guard let host = baseURL.host else {
                return (nil, "Invalid base host")
            }
            let result = try await FritzDigestAuth.sendSOAP(
                routerHost: host,
                controlPath: controlPath,
                serviceURN: serviceURN,
                action: action,
                bodyArgs: bodyArgs,
                username: username,
                password: password,
                timeout: timeout
            )
            return (result.data, nil)
        } catch let digestError as FritzDigestAuthError {
            switch digestError {
            case let .httpStatus(status, body):
                return (nil, "SOAP \(action) failed with HTTP \(status): \(body)")
            default:
                return (nil, "SOAP \(action) failed: \(digestError)")
            }
        } catch {
            return (nil, "SOAP \(action) failed: \(error.localizedDescription)")
        }
    }

    private static func sendHostListPathSOAP(
        baseURL: URL,
        controlPath: String,
        serviceURN: String,
        bodyArgs: String,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async -> Data? {
        let actions = ["X_AVM-DE_GetHostListPath", "GetHostListPath"]
        for action in actions {
            tr064DebugLog("[TR064] sendHostListPathSOAP: trying action \(action)")
            if let response = await sendSOAP(
                baseURL: baseURL,
                controlPath: controlPath,
                serviceURN: serviceURN,
                action: action,
                bodyArgs: bodyArgs,
                username: username,
                password: password,
                timeout: timeout
            ) {
                tr064DebugLog("[TR064] sendHostListPathSOAP: action \(action) returned \(response.count) bytes")
                return response
            }
            tr064DebugLog("[TR064] sendHostListPathSOAP: action \(action) returned nil")
        }
        return nil
    }

    private static func sendHostListPathSOAPWithError(
        baseURL: URL,
        controlPath: String,
        serviceURN: String,
        bodyArgs: String,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async -> (data: Data?, error: String?) {
        let actions = ["X_AVM-DE_GetHostListPath", "GetHostListPath"]
        var errors: [String] = []
        for action in actions {
            let result = await sendSOAPWithError(
                baseURL: baseURL,
                controlPath: controlPath,
                serviceURN: serviceURN,
                action: action,
                bodyArgs: bodyArgs,
                username: username,
                password: password,
                timeout: timeout
            )
            if let data = result.data {
                return (data, nil)
            }
            errors.append(result.error ?? "\(action) failed")
        }
        return (nil, errors.joined(separator: " | "))
    }

    private static func fetchHostsByEnumeration(
        baseURL: URL,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async -> [TR064Host]? {
        let result = await fetchHostsByEnumerationWithError(
            baseURL: baseURL,
            username: username,
            password: password,
            timeout: timeout
        )
        return result.hosts
    }

    private static func fetchHostsByEnumerationWithError(
        baseURL: URL,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async -> (hosts: [TR064Host]?, error: String?) {
        tr064DebugLog("[TR064] fetchHostsByEnumeration: start")
        let serviceURN = "urn:dslforum-org:service:Hosts:1"

        let numberOfEntriesResult = await sendSOAPWithError(
            baseURL: baseURL,
            controlPath: "/upnp/control/hosts",
            serviceURN: serviceURN,
            action: "GetHostNumberOfEntries",
            bodyArgs: "",
            username: username,
            password: password,
            timeout: timeout
        )

        guard let numberOfEntriesData = numberOfEntriesResult.data else {
            return (nil, "SOAP GetHostNumberOfEntries failed: \(numberOfEntriesResult.error ?? "unknown")")
        }

        let numberOfEntriesXML = String(data: numberOfEntriesData, encoding: .utf8) ?? ""
        guard let countString = extractXMLTag(numberOfEntriesXML, tag: "NewHostNumberOfEntries"),
              let count = Int(countString)
        else {
            return (nil, "Failed to parse NewHostNumberOfEntries")
        }
        tr064DebugLog("[TR064] fetchHostsByEnumeration: \(count) hosts to enumerate")

        if count <= 0 {
            return ([], nil)
        }

        var hosts: [TR064Host] = []
        for index in 0..<count {
            let entryResult = await sendSOAPWithError(
                baseURL: baseURL,
                controlPath: "/upnp/control/hosts",
                serviceURN: serviceURN,
                action: "GetGenericHostEntry",
                bodyArgs: "<NewIndex>\(index)</NewIndex>",
                username: username,
                password: password,
                timeout: timeout
            )

            guard let entryData = entryResult.data else {
                continue
            }

            let entryXML = String(data: entryData, encoding: .utf8) ?? ""
            let mac = extractXMLTag(entryXML, tag: "NewMACAddress") ?? ""
            if mac.isEmpty {
                continue
            }

            let ip = extractXMLTag(entryXML, tag: "NewIPAddress")
            let activeRaw = extractXMLTag(entryXML, tag: "NewActive") ?? "0"
            let hostName = extractXMLTag(entryXML, tag: "NewHostName")
            let isActive = (activeRaw == "1" || activeRaw.lowercased() == "true")

            hosts.append(
                TR064Host(
                    mac: mac,
                    ip: ip?.isEmpty == true ? nil : ip,
                    active: isActive,
                    name: hostName?.isEmpty == true ? nil : hostName,
                    speedMbps: parseSpeedMbps(from: entryXML),
                    band: nil,
                    signalStrengthPercent: nil
                )
            )
        }

        return hosts.isEmpty ? (nil, "No hosts returned by GetGenericHostEntry") : (hosts, nil)
    }

    private static func extractXMLTag(_ xml: String, tag: String) -> String? {
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

    private static func buildMap(from hosts: [TR064Host]) -> [String: (active: Bool, ip: String?)] {
        var map = [String: (active: Bool, ip: String?)]()
        for host in hosts {
            let key = normalizeMACToKey(host.mac)
            map[key] = (active: host.active, ip: host.ip)
        }
        return map
    }

    private static func normalizedRouterHost(from _: String) -> String {
        fixedRouterHost
    }

    private static func extractSID(from path: String) -> String? {
        guard let components = URLComponents(string: "http://placeholder" + path),
              let sid = components.queryItems?.first(where: { $0.name == "sid" })?.value
        else {
            return nil
        }
        return sid
    }

    private static func hostFetchKey(routerIP: String, username: String, password: String) -> String {
        let host = normalizedRouterHost(from: routerIP).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let pass = password.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(host)|\(user)|\(pass)"
    }

    private static func normalizeMACToKey(_ mac: String) -> String {
        // Normalize mac:
        // - uppercase, remove all non hex digits
        // - then lowercase and insert colon every two chars if original had separators
        let hexOnly = mac.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard hexOnly.count == 12 else {
            // fallback: lowercase original trimmed mac
            return mac.lowercased()
        }
        // Check if original mac had separators (colon or dash), prefer colon separated lowercase
        let hasSeparator = mac.contains(":") || mac.contains("-")
        if hasSeparator {
            var result = ""
            for (i, ch) in hexOnly.enumerated() {
                if i > 0 && i % 2 == 0 {
                    result.append(":")
                }
                result.append(ch)
            }
            return result.lowercased()
        } else {
            return hexOnly.lowercased()
        }
    }

    private static func normalizedKeyToColonMAC(_ key: String) -> String {
        let hexOnly = key.uppercased().filter { "0123456789ABCDEF".contains($0) }
        guard hexOnly.count == 12 else { return key }
        var parts: [String] = []
        parts.reserveCapacity(6)
        for i in stride(from: 0, to: 12, by: 2) {
            let start = hexOnly.index(hexOnly.startIndex, offsetBy: i)
            let end = hexOnly.index(start, offsetBy: 2)
            parts.append(String(hexOnly[start..<end]))
        }
        return parts.joined(separator: ":")
    }

    private static func parseSpeedMbps(from xml: String) -> Double? {
        let raw = extractXMLTag(xml, tag: "NewX_AVM-DE_Speed")
            ?? extractXMLTag(xml, tag: "NewX_AVM_DE_Speed")
            ?? extractXMLTag(xml, tag: "X_AVM-DE_Speed")
            ?? extractXMLTag(xml, tag: "X_AVM_DE_Speed")
            ?? extractXMLTag(xml, tag: "NewSpeed")
        guard let raw else { return nil }
        if let direct = Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return direct
        }
        guard let regex = try? NSRegularExpression(pattern: "([0-9]+(?:\\.[0-9]+)?)"),
              let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
              let range = Range(match.range(at: 1), in: raw)
        else {
            return nil
        }
        return Double(String(raw[range]))
    }

    private static func parseDownstreamMbps(from properties: [DataLuaProperty]) -> Double? {
        guard let regex = try? NSRegularExpression(pattern: "([0-9]+(?:[\\.,][0-9]+)?)\\s*/\\s*([0-9]+(?:[\\.,][0-9]+)?)\\s*Mbit/s") else {
            return nil
        }
        var best: Double?
        for prop in properties {
            guard let text = prop.txt else { continue }
            let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
                  let rxRange = Range(match.range(at: 2), in: text)
            else { continue }
            let normalized = String(text[rxRange]).replacingOccurrences(of: ",", with: ".")
            guard let value = Double(normalized) else { continue }
            best = max(best ?? value, value)
        }
        return best
    }

    private static func speedCandidateTags(in xml: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "<([A-Za-z0-9:_\\-]*Speed[A-Za-z0-9:_\\-]*)>") else {
            return []
        }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        let matches = regex.matches(in: xml, range: nsRange)
        var tags: [String] = []
        for match in matches {
            guard let range = Range(match.range(at: 1), in: xml) else { continue }
            let tag = String(xml[range])
            if !tags.contains(tag) {
                tags.append(tag)
            }
            if tags.count >= 6 { break }
        }
        return tags
    }

    public static func wifiAssociationMap(
        routerIP: String,
        username: String,
        password: String,
        macAddresses: [String]
    ) async -> [String: TR064WiFiAssociationInfo] {
        let targetKeys = Set(macAddresses.map(normalizeMACToKey))
        guard !targetKeys.isEmpty else { return [:] }
        let routerHost = normalizedRouterHost(from: routerIP)
        guard let baseURL = URL(string: "http://\(routerHost):49000") else { return [:] }

        let bandByIndex: [Int: String] = [
            1: "2.4GHz",
            2: "5GHz",
            3: "6GHz"
        ]
        var map: [String: TR064WiFiAssociationInfo] = [:]

        for wlanIndex in [1, 2, 3] {
            let controlPath = "/upnp/control/wlanconfig\(wlanIndex)"
            var selectedVersion: Int?
            var totalAssociations = 0

            for version in [1, 2, 3] {
                let serviceURN = "urn:dslforum-org:service:WLANConfiguration:\(version)"
                let response = await sendSOAPWithError(
                    baseURL: baseURL,
                    controlPath: controlPath,
                    serviceURN: serviceURN,
                    action: "GetTotalAssociations",
                    bodyArgs: "",
                    username: username,
                    password: password,
                    timeout: 5
                )
                guard let data = response.data else { continue }
                let xml = String(data: data, encoding: .utf8) ?? ""
                guard
                    let totalRaw = extractXMLTag(xml, tag: "NewTotalAssociations"),
                    let total = Int(totalRaw),
                    total >= 0
                else {
                    continue
                }
                selectedVersion = version
                totalAssociations = total
                break
            }

            guard let version = selectedVersion, totalAssociations > 0 else { continue }
            let serviceURN = "urn:dslforum-org:service:WLANConfiguration:\(version)"
            let band = bandByIndex[wlanIndex]

            for deviceIndex in 0..<totalAssociations {
                let bodyArgs = "<NewAssociatedDeviceIndex>\(deviceIndex)</NewAssociatedDeviceIndex>"
                let response = await sendSOAPWithError(
                    baseURL: baseURL,
                    controlPath: controlPath,
                    serviceURN: serviceURN,
                    action: "GetGenericAssociatedDeviceInfo",
                    bodyArgs: bodyArgs,
                    username: username,
                    password: password,
                    timeout: 5
                )
                guard let data = response.data else { continue }
                let xml = String(data: data, encoding: .utf8) ?? ""
                guard let mac = extractXMLTag(xml, tag: "NewAssociatedDeviceMACAddress") else { continue }
                let key = normalizeMACToKey(mac)
                guard targetKeys.contains(key) else { continue }

                let signalRaw = extractXMLTag(xml, tag: "NewX_AVM-DE_SignalStrength")
                    ?? extractXMLTag(xml, tag: "NewX_AVM_DE_SignalStrength")
                    ?? extractXMLTag(xml, tag: "X_AVM-DE_SignalStrength")
                    ?? extractXMLTag(xml, tag: "X_AVM_DE_SignalStrength")
                let signal = parseSignalPercent(from: signalRaw)
                let ip = extractXMLTag(xml, tag: "NewAssociatedDeviceIPAddress")

                if let existing = map[key] {
                    let preferredSignal = max(existing.signalStrengthPercent ?? Int.min, signal ?? Int.min)
                    map[key] = TR064WiFiAssociationInfo(
                        band: existing.band ?? band,
                        signalStrengthPercent: preferredSignal == Int.min ? nil : preferredSignal,
                        ipAddress: existing.ipAddress ?? ip
                    )
                } else {
                    map[key] = TR064WiFiAssociationInfo(
                        band: band,
                        signalStrengthPercent: signal,
                        ipAddress: ip
                    )
                }
            }
        }

        return map
    }

    private static func parseSignalPercent(from raw: String?) -> Int? {
        guard let raw else { return nil }
        if let direct = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return max(0, min(100, direct))
        }
        guard
            let regex = try? NSRegularExpression(pattern: "([0-9]{1,3})"),
            let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..<raw.endIndex, in: raw)),
            let range = Range(match.range(at: 1), in: raw),
            let value = Int(String(raw[range]))
        else {
            return nil
        }
        return max(0, min(100, value))
    }

    public static func fetchHostDebugAttributes(
        routerIP: String,
        username: String,
        password: String,
        macAddress: String,
        ipAddress: String?
    ) async -> TR064HostDebugAttributes {
        let routerHost = normalizedRouterHost(from: routerIP)
        guard let baseURL = URL(string: "http://\(routerHost):49000") else {
            return TR064HostDebugAttributes(
                mac: nil, ip: nil, name: nil, active: nil,
                speed: nil, signalStrength: nil, mesh: nil, interfaceType: nil,
                sourceAction: "none",
                diagnostic: "invalid base URL"
            )
        }
        let serviceURN = "urn:dslforum-org:service:Hosts:1"
        let normalizedMac = normalizedKeyToColonMAC(normalizeMACToKey(macAddress))

        func attributesFromXML(_ xml: String, sourceAction: String, diagnostic: String) -> TR064HostDebugAttributes {
            let speed = extractXMLTag(xml, tag: "NewX_AVM-DE_Speed")
                ?? extractXMLTag(xml, tag: "NewX_AVM_DE_Speed")
                ?? extractXMLTag(xml, tag: "X_AVM-DE_Speed")
                ?? extractXMLTag(xml, tag: "X_AVM_DE_Speed")
                ?? extractXMLTag(xml, tag: "NewSpeed")
            let signal = extractXMLTag(xml, tag: "NewX_AVM-DE_SignalStrength")
                ?? extractXMLTag(xml, tag: "NewX_AVM_DE_SignalStrength")
                ?? extractXMLTag(xml, tag: "X_AVM-DE_SignalStrength")
                ?? extractXMLTag(xml, tag: "X_AVM_DE_SignalStrength")
            let mesh = extractXMLTag(xml, tag: "NewX_AVM-DE_Mesh")
                ?? extractXMLTag(xml, tag: "NewX_AVM_DE_Mesh")
                ?? extractXMLTag(xml, tag: "X_AVM-DE_Mesh")
                ?? extractXMLTag(xml, tag: "X_AVM_DE_Mesh")

            return TR064HostDebugAttributes(
                mac: extractXMLTag(xml, tag: "NewMACAddress"),
                ip: extractXMLTag(xml, tag: "NewIPAddress"),
                name: extractXMLTag(xml, tag: "NewHostName"),
                active: extractXMLTag(xml, tag: "NewActive"),
                speed: speed,
                signalStrength: signal,
                mesh: mesh,
                interfaceType: extractXMLTag(xml, tag: "NewInterfaceType"),
                sourceAction: sourceAction,
                diagnostic: diagnostic
            )
        }

        let attempts: [(action: String, bodyArgs: String)] = {
            var list: [(String, String)] = []
            // Prefer AVM-specific action first because it is most likely to expose
            // NewX_AVM-DE_* fields on Fritz!Box firmwares.
            list.append(("X_AVM-DE_GetSpecificHostEntryByMACAddress", "<NewMACAddress>\(normalizedMac)</NewMACAddress>"))
            if let ipAddress, !ipAddress.isEmpty {
                list.append(("GetSpecificHostEntry", "<NewIPAddress>\(ipAddress)</NewIPAddress>"))
            }
            list.append(("GetSpecificHostEntry", "<NewMACAddress>\(normalizedMac)</NewMACAddress>"))
            return list
        }()

        var lastError = "no response"
        var bestCandidate: TR064HostDebugAttributes?
        for attempt in attempts {
            let response = await sendSOAPWithError(
                baseURL: baseURL,
                controlPath: "/upnp/control/hosts",
                serviceURN: serviceURN,
                action: attempt.action,
                bodyArgs: attempt.bodyArgs,
                username: username,
                password: password,
                timeout: 5
            )
            if let data = response.data, let xml = String(data: data, encoding: .utf8), !xml.isEmpty {
                let candidate = attributesFromXML(
                    xml,
                    sourceAction: attempt.action,
                    diagnostic: response.error ?? "ok"
                )
                let hasDesiredField = candidate.speed != nil || candidate.signalStrength != nil || candidate.mesh != nil
                if hasDesiredField {
                    return candidate
                }
                // Keep the richest fallback candidate if no desired fields were found.
                if bestCandidate == nil {
                    bestCandidate = candidate
                }
                continue
            }
            if let error = response.error, !error.isEmpty {
                lastError = error
            }
        }

        if let bestCandidate {
            return TR064HostDebugAttributes(
                mac: bestCandidate.mac,
                ip: bestCandidate.ip,
                name: bestCandidate.name,
                active: bestCandidate.active,
                speed: bestCandidate.speed,
                signalStrength: bestCandidate.signalStrength,
                mesh: bestCandidate.mesh,
                interfaceType: bestCandidate.interfaceType,
                sourceAction: bestCandidate.sourceAction,
                diagnostic: bestCandidate.diagnostic.isEmpty ? lastError : bestCandidate.diagnostic
            )
        }

        return TR064HostDebugAttributes(
            mac: nil, ip: nil, name: nil, active: nil,
            speed: nil, signalStrength: nil, mesh: nil, interfaceType: nil,
            sourceAction: "none",
            diagnostic: lastError
        )
    }

    public static func debugSpeedProbeLines(
        routerIP: String,
        username: String,
        password: String,
        macAddress: String
    ) async -> [String] {
        let key = normalizeMACToKey(macAddress)
        var lines: [String] = []
        let schemes: [(name: String, useHTTPS: Bool)] = [("http", false)]
        let routerHost = normalizedRouterHost(from: routerIP)

        for scheme in schemes {
            let port = scheme.useHTTPS ? 49443 : 49000
            guard let baseURL = URL(string: "\(scheme.name)://\(routerHost):\(port)") else {
                lines.append("[\(scheme.name)] invalid base URL")
                continue
            }

            let hosts = await fetchHostsInternalWithError(
                routerIP: routerIP,
                username: username,
                password: password,
                timeout: 5,
                useHTTPS: scheme.useHTTPS
            )
            let ipForKey = hosts.hosts?.first(where: { normalizeMACToKey($0.mac) == key })?.ip
            lines.append("[\(scheme.name)] host list: \(hosts.hosts?.count ?? 0) entries, ipForMac=\(ipForKey ?? "n/a"), err=\(hosts.error ?? "none")")

            let serviceURN = "urn:dslforum-org:service:Hosts:1"
            let macBody = "<NewMACAddress>\(normalizedKeyToColonMAC(key))</NewMACAddress>"

            if let ipForKey, !ipForKey.isEmpty {
                if let handshake = try? await FritzDigestAuth.debugSOAPHandshake(
                    routerHost: normalizedRouterHost(from: routerIP),
                    controlPath: "/upnp/control/hosts",
                    serviceURN: serviceURN,
                    action: "GetSpecificHostEntry",
                    timeout: 4
                ) {
                    lines.append("[\(scheme.name)] digest GetSpecificHostEntry -> \(handshake.summary)")
                }
                let byIP = await sendSOAPWithError(
                    baseURL: baseURL,
                    controlPath: "/upnp/control/hosts",
                    serviceURN: serviceURN,
                    action: "GetSpecificHostEntry",
                    bodyArgs: "<NewIPAddress>\(ipForKey)</NewIPAddress>",
                    username: username,
                    password: password,
                    timeout: 5
                )
                lines.append(probeSummaryLine(scheme: scheme.name, action: "GetSpecificHostEntry", mode: "ip", data: byIP.data, error: byIP.error))
            }

            if let handshake = try? await FritzDigestAuth.debugSOAPHandshake(
                routerHost: normalizedRouterHost(from: routerIP),
                controlPath: "/upnp/control/hosts",
                serviceURN: serviceURN,
                action: "GetSpecificHostEntry",
                timeout: 4
            ) {
                lines.append("[\(scheme.name)] digest GetSpecificHostEntry(mac) -> \(handshake.summary)")
            }
            let byMac = await sendSOAPWithError(
                baseURL: baseURL,
                controlPath: "/upnp/control/hosts",
                serviceURN: serviceURN,
                action: "GetSpecificHostEntry",
                bodyArgs: macBody,
                username: username,
                password: password,
                timeout: 5
            )
            lines.append(probeSummaryLine(scheme: scheme.name, action: "GetSpecificHostEntry", mode: "mac", data: byMac.data, error: byMac.error))

            if let handshake = try? await FritzDigestAuth.debugSOAPHandshake(
                routerHost: normalizedRouterHost(from: routerIP),
                controlPath: "/upnp/control/hosts",
                serviceURN: serviceURN,
                action: "X_AVM-DE_GetSpecificHostEntryByMACAddress",
                timeout: 4
            ) {
                lines.append("[\(scheme.name)] digest X_AVM-DE_GetSpecificHostEntryByMACAddress -> \(handshake.summary)")
            }
            let avm = await sendSOAPWithError(
                baseURL: baseURL,
                controlPath: "/upnp/control/hosts",
                serviceURN: serviceURN,
                action: "X_AVM-DE_GetSpecificHostEntryByMACAddress",
                bodyArgs: macBody,
                username: username,
                password: password,
                timeout: 5
            )
            lines.append(probeSummaryLine(scheme: scheme.name, action: "X_AVM-DE_GetSpecificHostEntryByMACAddress", mode: "mac", data: avm.data, error: avm.error))
        }
        return lines
    }

    private static func probeSummaryLine(
        scheme: String,
        action: String,
        mode: String,
        data: Data?,
        error: String?
    ) -> String {
        if let error {
            return "[\(scheme)] \(action) (\(mode)) -> error: \(error)"
        }
        guard let data else {
            return "[\(scheme)] \(action) (\(mode)) -> no data"
        }
        let xml = String(data: data, encoding: .utf8) ?? ""
        let speedTagValue = extractXMLTag(xml, tag: "NewX_AVM-DE_Speed")
            ?? extractXMLTag(xml, tag: "NewX_AVM_DE_Speed")
            ?? extractXMLTag(xml, tag: "X_AVM-DE_Speed")
            ?? extractXMLTag(xml, tag: "X_AVM_DE_Speed")
            ?? extractXMLTag(xml, tag: "NewSpeed")
            ?? "missing"
        let activeValue = extractXMLTag(xml, tag: "NewActive") ?? "missing"
        let candidates = speedCandidateTags(in: xml).joined(separator: ",")
        let snippet = xml
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shortSnippet = String(snippet.prefix(260))
        return "[\(scheme)] \(action) (\(mode)) -> speedTag=\(speedTagValue), active=\(activeValue), candidates=[\(candidates)], xml=\"\(shortSnippet)\""
    }
}

private actor TR064HostFetchCoordinator {
    private struct CacheEntry {
        let result: [TR064Host]?
        let fetchedAt: Date
    }

    private let minimumRefreshInterval: TimeInterval = 30
    private var inFlight: [String: Task<[TR064Host]?, Never>] = [:]
    private var cache: [String: CacheEntry] = [:]

    func run(key: String, operation: @escaping @Sendable () async -> [TR064Host]?) async -> [TR064Host]? {
        if let cached = cache[key], Date().timeIntervalSince(cached.fetchedAt) < minimumRefreshInterval {
            return cached.result
        }
        if let existing = inFlight[key] {
            return await existing.value
        }
        let task = Task { await operation() }
        inFlight[key] = task
        let result = await task.value
        inFlight[key] = nil
        cache[key] = CacheEntry(result: result, fetchedAt: Date())
        return result
    }
}

private struct DataLuaResponse: Codable {
    let data: DataLuaPayload?
}

private struct DataLuaPayload: Codable {
    let active: [DataLuaDevice]?
    let fbox: [DataLuaDevice]?
    let fboxOther: [DataLuaDevice]?

    enum CodingKeys: String, CodingKey {
        case active
        case fbox
        case fboxOther = "fbox_other"
    }
}

private struct DataLuaDevice: Codable {
    let mac: String?
    let name: String?
    let type: String?
    let port: String?
    let uid: String?
    let state: DataLuaState?
    let ipv4: DataLuaIPv4?
    let properties: [DataLuaProperty]?
    let ownClientDevice: Bool?

    enum CodingKeys: String, CodingKey {
        case mac
        case name
        case type
        case port
        case uid = "UID"
        case state
        case ipv4
        case properties
        case ownClientDevice = "own_client_device"
    }
}

private struct DataLuaState: Codable {
    let className: String?
    let fos_icon: DataLuaFosIcon?

    enum CodingKeys: String, CodingKey {
        case className = "class"
        case fos_icon
    }
}

private struct DataLuaFosIcon: Codable {
    let icon: String?
}

private struct DataLuaIPv4: Codable {
    let ip: String?
    let addrtype: String?
    let dhcp: String?
    let lastused: String?
    let node: String?

    enum CodingKeys: String, CodingKey {
        case ip
        case addrtype
        case dhcp
        case lastused
        case node = "_node"
    }
}

private struct DataLuaProperty: Codable {
    let txt: String?
    let onclick: String?
    let icon: String?
    let link: String?
}

// MARK: - XML Parsers

private class HostListPathParser: NSObject, XMLParserDelegate {
    private(set) var foundPath: String?
    private var currentElement: String?
    private var foundCharacters = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        foundCharacters = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard currentElement != nil else { return }
        foundCharacters += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?) {
        guard let current = currentElement else { return }
        if current == elementName {
            // We check for common element names from Fritz!Box SOAP GetHostListPath response
            if current == "NewX_AVM-DE_HostListPath" || current == "NewHostListPath" {
                let trimmed = foundCharacters.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    foundPath = trimmed
                }
            }
            currentElement = nil
            foundCharacters = ""
        }
    }
}
