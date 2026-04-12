import Foundation
import os.log

public struct TR064Host: Codable {
    public let mac: String
    public let ip: String?
    public let active: Bool
    public let name: String?
}

public enum TR064HostService {
    private static let logger = Logger(subsystem: "de.mice.fritzbox.tr064", category: "TR064HostService")

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
        // Try HTTPS first
        if let hosts = await fetchHostsInternal(
            routerIP: routerIP,
            username: username,
            password: password,
            timeout: timeout,
            useHTTPS: true
        ) {
            return hosts
        }
        // Fallback to HTTP
        return await fetchHostsInternal(
            routerIP: routerIP,
            username: username,
            password: password,
            timeout: timeout,
            useHTTPS: false
        )
    }

    private static func fetchHostsInternal(
        routerIP: String,
        username: String,
        password: String,
        timeout: TimeInterval,
        useHTTPS: Bool
    ) async -> [TR064Host]? {
        let scheme = useHTTPS ? "https" : "http"
        let port = useHTTPS ? 49443 : 49000
        let baseURLString = "\(scheme)://\(routerIP):\(port)"
        guard let baseURL = URL(string: baseURLString) else {
            logger.error("Invalid base URL: \(baseURLString, privacy: .public)")
            return nil
        }

        // Step 1: Try to get host list path by SOAP call GetHostListPath
        let controlPath = "/upnp/control/hosts"
        let serviceURN = "urn:dslforum-org:service:Hosts:1"
        let action = "GetHostListPath"
        let soapBody = ""
        guard let soapResponse = await sendSOAP(
            baseURL: baseURL,
            controlPath: controlPath,
            serviceURN: serviceURN,
            action: action,
            bodyArgs: soapBody,
            username: username,
            password: password,
            timeout: timeout
        ) else {
            logger.debug("SOAP GetHostListPath failed, fallback to direct hosts XML")
            if let hosts = await fetchDirectHostsXML(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            ) {
                return hosts
            }
            logger.debug("Direct hosts XML failed, fallback to host enumeration")
            return await fetchHostsByEnumeration(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            )
        }

        // Step 2: Parse SOAP response XML for NewX_AVM-DE_HostListPath or NewHostListPath
        guard let hostListPath = parseHostListPath(fromSOAPResponse: soapResponse) else {
            logger.debug("No host list path found in SOAP response, fallback to direct hosts XML")
            if let hosts = await fetchDirectHostsXML(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            ) {
                return hosts
            }
            logger.debug("Direct hosts XML failed, fallback to host enumeration")
            return await fetchHostsByEnumeration(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            )
        }

        // Step 3: GET the host list XML at hostListPath
        guard let hostListURL = URL(string: hostListPath, relativeTo: baseURL) else {
            logger.error("Invalid host list URL: \(hostListPath, privacy: .public)")
            return nil
        }

        var request = URLRequest(url: hostListURL)
        request.timeoutInterval = timeout
        addBasicAuthHeader(request: &request, username: username, password: password)

        do {
            let (data, _) = try await urlSession(for: baseURL.scheme ?? "http", timeout: timeout).data(for: request)
            if let hosts = parseHostsXML(data: data) {
                return hosts
            }
            logger.debug("Failed to parse host list XML at \(hostListURL.absoluteString, privacy: .public), fallback to host enumeration")
            return await fetchHostsByEnumeration(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            )
        } catch {
            logger.error("Failed to GET host list XML at \(hostListURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return await fetchHostsByEnumeration(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            )
        }
    }

    private static func fetchDirectHostsXML(
        baseURL: URL,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async -> [TR064Host]? {
        // Common fallback path is /hosts/hosts (no session id)
        guard let hostsURL = URL(string: "/hosts/hosts", relativeTo: baseURL) else {
            logger.error("Invalid fallback hosts URL")
            return nil
        }
        var request = URLRequest(url: hostsURL)
        request.timeoutInterval = timeout
        addBasicAuthHeader(request: &request, username: username, password: password)

        do {
            let (data, _) = try await urlSession(for: baseURL.scheme ?? "http", timeout: timeout).data(for: request)
            return parseHostsXML(data: data)
        } catch {
            logger.error("Failed to GET fallback hosts XML at \(hostsURL.absoluteString, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func addBasicAuthHeader(request: inout URLRequest, username: String, password: String) {
        let authString = "\(username):\(password)"
        guard let authData = authString.data(using: .utf8) else { return }
        let authValue = "Basic " + authData.base64EncodedString()
        request.setValue(authValue, forHTTPHeaderField: "Authorization")
    }

    private static func urlSession(for scheme: String, timeout: TimeInterval) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session: URLSession
        if scheme == "https" {
            session = URLSession(configuration: config, delegate: SSLTrustDelegate(), delegateQueue: nil)
        } else {
            session = URLSession(configuration: config)
        }
        return session
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
        let soapEnvelope =
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(serviceURN)">
              \(bodyArgs)
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """

        guard let url = URL(string: controlPath, relativeTo: baseURL) else {
            logger.error("Invalid SOAP URL: \(controlPath, privacy: .public)")
            return nil
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = soapEnvelope.data(using: .utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\(serviceURN)#\(action)", forHTTPHeaderField: "SOAPAction")
        request.timeoutInterval = timeout
        addBasicAuthHeader(request: &request, username: username, password: password)

        do {
            let (data, response) = try await urlSession(for: baseURL.scheme ?? "http", timeout: timeout).data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) {
                return data
            } else {
                logger.debug("SOAP action \(action) failed with status \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
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

    private static func parseHostsXML(data: Data) -> [TR064Host]? {
        let parser = HostsXMLParser()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = parser
        if xmlParser.parse() {
            return parser.hosts
        }
        return nil
    }

    /// Returns dictionary keyed by lowercased mac addresses (colon-separated if present)
    /// with active status and optional IP address.
    public static func onlineMap(routerIP: String, username: String, password: String) async -> [String: (active: Bool, ip: String?)] {
        guard let hosts = await fetchHosts(routerIP: routerIP, username: username, password: password) else {
            return [:]
        }
        var map = [String: (active: Bool, ip: String?)]()
        for host in hosts {
            let key = normalizeMACToKey(host.mac)
            map[key] = (active: host.active, ip: host.ip)
        }
        return map
    }

    /// Same as `onlineMap`, but returns a readable error string when host retrieval fails.
    public static func onlineMapWithError(
        routerIP: String,
        username: String,
        password: String
    ) async -> (map: [String: (active: Bool, ip: String?)], error: String?) {
        let httpsResult = await fetchHostsInternalWithError(
            routerIP: routerIP,
            username: username,
            password: password,
            timeout: 5,
            useHTTPS: true
        )
        if let hosts = httpsResult.hosts {
            return (buildMap(from: hosts), nil)
        }

        let httpResult = await fetchHostsInternalWithError(
            routerIP: routerIP,
            username: username,
            password: password,
            timeout: 5,
            useHTTPS: false
        )
        if let hosts = httpResult.hosts {
            return (buildMap(from: hosts), nil)
        }

        let httpsError = httpsResult.error ?? "unknown HTTPS error"
        let httpError = httpResult.error ?? "unknown HTTP error"
        return ([:], "HTTPS: \(httpsError) | HTTP: \(httpError)")
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
        let baseURLString = "\(scheme)://\(routerIP):\(port)"
        guard let baseURL = URL(string: baseURLString) else {
            return (nil, "Invalid base URL: \(baseURLString)")
        }

        let controlPath = "/upnp/control/hosts"
        let serviceURN = "urn:dslforum-org:service:Hosts:1"
        let action = "GetHostListPath"
        let soapBody = ""
        let soapResult = await sendSOAPWithError(
            baseURL: baseURL,
            controlPath: controlPath,
            serviceURN: serviceURN,
            action: action,
            bodyArgs: soapBody,
            username: username,
            password: password,
            timeout: timeout
        )
        if let soapResponse = soapResult.data {
            if let hostListPath = parseHostListPath(fromSOAPResponse: soapResponse) {
                guard let hostListURL = URL(string: hostListPath, relativeTo: baseURL) else {
                    return (nil, "Invalid host list URL: \(hostListPath)")
                }

                var request = URLRequest(url: hostListURL)
                request.timeoutInterval = timeout
                addBasicAuthHeader(request: &request, username: username, password: password)

                do {
                    let (data, response) = try await urlSession(for: baseURL.scheme ?? "http", timeout: timeout).data(for: request)
                    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                        return (nil, "GET host list failed with HTTP \(http.statusCode)")
                    }
                    guard let hosts = parseHostsXML(data: data) else {
                        return (nil, "Failed to parse host list XML")
                    }
                    return (hosts, nil)
                } catch {
                    return (nil, "GET host list failed: \(error.localizedDescription)")
                }
            } else {
                let fallback = await fetchDirectHostsXMLWithError(
                    baseURL: baseURL,
                    username: username,
                    password: password,
                    timeout: timeout
                )
                if let hosts = fallback.hosts {
                    return (hosts, nil)
                }
                let enumeration = await fetchHostsByEnumerationWithError(
                    baseURL: baseURL,
                    username: username,
                    password: password,
                    timeout: timeout
                )
                if let hosts = enumeration.hosts {
                    return (hosts, nil)
                }
                let error = [fallback.error, enumeration.error]
                    .compactMap { $0 }
                    .joined(separator: " | fallback: ")
                return (nil, error.isEmpty ? "Failed to resolve host list path" : error)
            }
        } else {
            let fallback = await fetchDirectHostsXMLWithError(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            )
            if let hosts = fallback.hosts {
                return (hosts, nil)
            }
            let enumeration = await fetchHostsByEnumerationWithError(
                baseURL: baseURL,
                username: username,
                password: password,
                timeout: timeout
            )
            if let hosts = enumeration.hosts {
                return (hosts, nil)
            }
            let combinedError = [soapResult.error, fallback.error, enumeration.error]
                .compactMap { $0 }
                .joined(separator: " | fallback: ")
            return (nil, combinedError.isEmpty ? "Unknown SOAP/fallback failure" : combinedError)
        }
    }

    private static func fetchDirectHostsXMLWithError(
        baseURL: URL,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async -> (hosts: [TR064Host]?, error: String?) {
        guard let hostsURL = URL(string: "/hosts/hosts", relativeTo: baseURL) else {
            return (nil, "Invalid fallback hosts URL")
        }
        var request = URLRequest(url: hostsURL)
        request.timeoutInterval = timeout
        addBasicAuthHeader(request: &request, username: username, password: password)

        do {
            let (data, response) = try await urlSession(for: baseURL.scheme ?? "http", timeout: timeout).data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return (nil, "Fallback GET failed with HTTP \(http.statusCode)")
            }
            guard let hosts = parseHostsXML(data: data) else {
                return (nil, "Failed to parse fallback hosts XML")
            }
            return (hosts, nil)
        } catch {
            return (nil, "Fallback GET failed: \(error.localizedDescription)")
        }
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
        let soapEnvelope =
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(serviceURN)">
              \(bodyArgs)
            </u:\(action)>
          </s:Body>
        </s:Envelope>
        """

        guard let url = URL(string: controlPath, relativeTo: baseURL) else {
            return (nil, "Invalid SOAP URL: \(controlPath)")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = soapEnvelope.data(using: .utf8)
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("\(serviceURN)#\(action)", forHTTPHeaderField: "SOAPAction")
        request.timeoutInterval = timeout
        addBasicAuthHeader(request: &request, username: username, password: password)

        do {
            let (data, response) = try await urlSession(for: baseURL.scheme ?? "http", timeout: timeout).data(for: request)
            if let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) {
                return (data, nil)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            return (nil, "SOAP \(action) failed with HTTP \(status)")
        } catch {
            return (nil, "SOAP \(action) failed: \(error.localizedDescription)")
        }
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
                    name: hostName?.isEmpty == true ? nil : hostName
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

private class HostsXMLParser: NSObject, XMLParserDelegate {
    private(set) var hosts = [TR064Host]()
    private var currentElement: String?
    private var currentMAC: String?
    private var currentIP: String?
    private var currentActive: Bool = false
    private var currentName: String?
    private var insideItem = false
    private var foundCharacters = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        if elementName == "Item" {
            insideItem = true
            currentMAC = nil
            currentIP = nil
            currentActive = false
            currentName = nil
        }
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
            if insideItem {
                let trimmed = foundCharacters.trimmingCharacters(in: .whitespacesAndNewlines)
                switch current {
                case "MACAddress":
                    currentMAC = trimmed
                case "IPAddress":
                    currentIP = trimmed.isEmpty ? nil : trimmed
                case "Active":
                    currentActive = (trimmed == "1" || trimmed.lowercased() == "true")
                case "HostName":
                    currentName = trimmed.isEmpty ? nil : trimmed
                default:
                    break
                }
            }
            if elementName == "Item" {
                insideItem = false
                if let mac = currentMAC, !mac.isEmpty {
                    let host = TR064Host(mac: mac, ip: currentIP, active: currentActive, name: currentName)
                    hosts.append(host)
                }
            }
            currentElement = nil
            foundCharacters = ""
        }
    }
}

// MARK: - SSLTrustDelegate

/// URLSessionDelegate to allow system trust validation of TLS certificates (including self-signed if trusted)
private class SSLTrustDelegate: NSObject, URLSessionDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Use system default trust evaluation
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let serverTrust = challenge.protectionSpace.serverTrust {
            var secresult = SecTrustResultType.invalid
            let status = SecTrustEvaluate(serverTrust, &secresult)
            if status == errSecSuccess,
               (secresult == .unspecified || secresult == .proceed) {
                let credential = URLCredential(trust: serverTrust)
                completionHandler(.useCredential, credential)
                return
            }
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
