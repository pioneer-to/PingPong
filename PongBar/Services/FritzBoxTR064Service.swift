//
//  FritzBoxTR064Service.swift
//  PongBar
//
//  Handles native TR-064 communication with a FritzBox router to retrieve LAN network devices.
//

import Foundation

enum FritzBoxError: Error {
    case invalidURL
    case authenticationFailed
    case networkError(Error)
    case xmlParsingError
    case missingCredentials
}

/// A lightweight, Native Swift implementation of TR-064 for fetching local hosts.
final class FritzBoxTR064Service: NSObject, URLSessionTaskDelegate {
    static let shared = FritzBoxTR064Service()
    
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 5.0
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()
    
    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let username = Config.fritzUsername
        let password = Config.fritzPassword
        
        guard !username.isEmpty, !password.isEmpty else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
           challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest {
            let credential = URLCredential(user: username, password: password, persistence: .forSession)
            completionHandler(.useCredential, credential)
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
    
    /// Fetches all active connected devices to the router
    func fetchConnectedDevices(routerIP: String) async throws -> [LocalNetworkDevice] {
        guard !Config.fritzUsername.isEmpty, !Config.fritzPassword.isEmpty else {
            throw FritzBoxError.missingCredentials
        }
        
        // 1. Get number of hosts
        let totalHosts = try await getHostNumberOfEntries(routerIP: routerIP)
        
        // 2. Fetch all hosts concurrently or sequentially (sequential is safer for TR-064)
        var activeDevices: [LocalNetworkDevice] = []
        for i in 0..<totalHosts {
            if let hostInfo = try? await getGenericHostEntry(routerIP: routerIP, index: i) {
                if hostInfo.active {
                    let newDevice = LocalNetworkDevice(
                        macAddress: hostInfo.mac,
                        ipAddress: hostInfo.ip,
                        originalName: hostInfo.name,
                        customName: "",
                        symbolName: "desktopcomputer",
                        notifyConnectivityDown: false
                    )
                    activeDevices.append(newDevice)
                }
            }
        }
        return activeDevices
    }
    
    // MARK: - SOAP Requests
    
    private func getHostNumberOfEntries(routerIP: String) async throws -> Int {
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:GetHostNumberOfEntries xmlns:u="urn:dslforum-org:service:Hosts:1"></u:GetHostNumberOfEntries>
          </s:Body>
        </s:Envelope>
        """
        
        let xmlData = try await sendRequest(routerIP: routerIP, action: "GetHostNumberOfEntries", body: soapBody)
        if let match = extractXMLTag(xmlData, tag: "NewHostNumberOfEntries"), let count = Int(match) {
            return count
        }
        throw FritzBoxError.xmlParsingError
    }
    
    private func getGenericHostEntry(routerIP: String, index: Int) async throws -> (mac: String, ip: String, active: Bool, name: String) {
        let soapBody = """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/" xmlns:s="http://schemas.xmlsoap.org/soap/envelope/">
          <s:Body>
            <u:GetGenericHostEntry xmlns:u="urn:dslforum-org:service:Hosts:1">
              <NewIndex>\(index)</NewIndex>
            </u:GetGenericHostEntry>
          </s:Body>
        </s:Envelope>
        """
        
        let xmlData = try await sendRequest(routerIP: routerIP, action: "GetGenericHostEntry", body: soapBody)
        
        let mac = extractXMLTag(xmlData, tag: "NewMACAddress") ?? ""
        let ip = extractXMLTag(xmlData, tag: "NewIPAddress") ?? ""
        let activeStr = extractXMLTag(xmlData, tag: "NewActive") ?? "0"
        let name = extractXMLTag(xmlData, tag: "NewHostName") ?? "Unknown"
        
        return (mac: mac, ip: ip, active: activeStr == "1", name: name)
    }
    
    private func sendRequest(routerIP: String, action: String, body: String) async throws -> String {
        let urlString = "http://\(routerIP):49000/upnp/control/hosts"
        guard let url = URL(string: urlString) else {
            throw FritzBoxError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("text/xml; charset=\"utf-8\"", forHTTPHeaderField: "Content-Type")
        request.setValue("urn:dslforum-org:service:Hosts:1#\(action)", forHTTPHeaderField: "SOAPAction")
        request.httpBody = body.data(using: .utf8)
        
        do {
            let (data, response) = try await session.data(for: request)
            if let httpResp = response as? HTTPURLResponse {
                if httpResp.statusCode == 401 {
                    throw FritzBoxError.authenticationFailed
                }
                guard httpResp.statusCode == 200 else {
                    let errStr = String(data: data, encoding: .utf8) ?? ""
                    throw FritzBoxError.networkError(NSError(domain: "FritzBox", code: httpResp.statusCode, userInfo: [NSLocalizedDescriptionKey: errStr]))
                }
            }
            return String(data: data, encoding: .utf8) ?? ""
        } catch let error as FritzBoxError {
            throw error
        } catch {
            throw FritzBoxError.networkError(error)
        }
    }
    
    // Fallback simple regex extraction instead of overhead of full XMLParser for small responses
    private func extractXMLTag(_ xml: String, tag: String) -> String? {
        let pattern = "<\(tag)[^>]*>(.*?)</\(tag)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators) else { return nil }
        let nsRange = NSRange(xml.startIndex..<xml.endIndex, in: xml)
        
        if let match = regex.firstMatch(in: xml, options: [], range: nsRange) {
            if let range = Range(match.range(at: 1), in: xml) {
                return String(xml[range])
            }
        }
        return nil
    }
}
