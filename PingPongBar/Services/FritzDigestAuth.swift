import Foundation
import CryptoKit

enum FritzDigestAuthError: Error {
    case invalidURL
    case missingDigestChallenge
    case invalidResponse
    case httpStatus(Int, String)
}

struct FritzDigestAuth {
    struct DigestHandshakeDebug {
        let probeStatus: Int
        let hasDigestChallenge: Bool
        let realm: String?
        let noncePrefix: String?
        let qop: String?
        let rawChallenge: String?

        var summary: String {
            let challengeState = hasDigestChallenge ? "present" : "missing"
            let realmText = realm ?? "n/a"
            let nonceText = noncePrefix ?? "n/a"
            let qopText = qop ?? "n/a"
            return "probeStatus=\(probeStatus), challenge=\(challengeState), realm=\(realmText), noncePrefix=\(nonceText), qop=\(qopText)"
        }
    }

    static func sendSOAP(
        routerHost: String,
        controlPath: String,
        serviceURN: String,
        action: String,
        bodyArgs: String,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        guard let url = URL(string: "http://\(routerHost):49000\(controlPath)") else {
            throw FritzDigestAuthError.invalidURL
        }

        let envelope = soapEnvelope(action: action, serviceURN: serviceURN, bodyArgs: bodyArgs)
        let payload = envelope.data(using: .utf8) ?? Data()

        var probe = URLRequest(url: url)
        probe.httpMethod = "POST"
        probe.timeoutInterval = timeout
        probe.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        probe.setValue("\(serviceURN)#\(action)", forHTTPHeaderField: "SOAPAction")
        // Fritz!Box may return a 502 SOAP fault for empty-body probes.
        // Send the real envelope unauthenticated to obtain Digest challenge reliably.
        probe.httpBody = payload

        let (probeData, probeResponse) = try await perform(probe, timeout: timeout)
        if (200..<300).contains(probeResponse.statusCode) {
            return (probeData, probeResponse)
        }
        let digestHeader = digestChallengeHeader(from: probeResponse)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        request.setValue("\(serviceURN)#\(action)", forHTTPHeaderField: "SOAPAction")
        request.httpBody = payload

        guard let digestHeader,
              let challenge = parseDigestChallenge(digestHeader)
        else {
            let body = String(data: probeData, encoding: .utf8) ?? ""
            throw FritzDigestAuthError.httpStatus(probeResponse.statusCode, body)
        }
        let authHeader = makeDigestAuthorization(
            username: username,
            password: password,
            method: "POST",
            uri: digestURI(from: url),
            challenge: challenge
        )
        request.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(request, timeout: timeout)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FritzDigestAuthError.httpStatus(response.statusCode, body)
        }
        return (data, response)
    }

    static func get(
        url: URL,
        username: String,
        password: String,
        timeout: TimeInterval
    ) async throws -> (data: Data, response: HTTPURLResponse) {
        var plain = URLRequest(url: url)
        plain.httpMethod = "GET"
        plain.timeoutInterval = timeout

        let (plainData, plainResponse) = try await perform(plain, timeout: timeout)
        if (200..<300).contains(plainResponse.statusCode) {
            return (plainData, plainResponse)
        }

        guard let digestHeader = digestChallengeHeader(from: plainResponse),
              let challenge = parseDigestChallenge(digestHeader)
        else {
            let body = String(data: plainData, encoding: .utf8) ?? ""
            throw FritzDigestAuthError.httpStatus(plainResponse.statusCode, body)
        }

        var authenticated = URLRequest(url: url)
        authenticated.httpMethod = "GET"
        authenticated.timeoutInterval = timeout
        let authHeader = makeDigestAuthorization(
            username: username,
            password: password,
            method: "GET",
            uri: digestURI(from: url),
            challenge: challenge
        )
        authenticated.setValue(authHeader, forHTTPHeaderField: "Authorization")

        let (data, response) = try await perform(authenticated, timeout: timeout)
        guard (200..<300).contains(response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FritzDigestAuthError.httpStatus(response.statusCode, body)
        }
        return (data, response)
    }

    static func debugSOAPHandshake(
        routerHost: String,
        controlPath: String,
        serviceURN: String,
        action: String,
        timeout: TimeInterval
    ) async throws -> DigestHandshakeDebug {
        guard let url = URL(string: "http://\(routerHost):49000\(controlPath)") else {
            throw FritzDigestAuthError.invalidURL
        }

        var probe = URLRequest(url: url)
        probe.httpMethod = "POST"
        probe.timeoutInterval = timeout
        probe.setValue("text/xml", forHTTPHeaderField: "Content-Type")
        probe.setValue("\(serviceURN)#\(action)", forHTTPHeaderField: "SOAPAction")
        probe.httpBody = soapEnvelope(action: action, serviceURN: serviceURN, bodyArgs: "").data(using: .utf8)

        let (_, response) = try await perform(probe, timeout: timeout)
        let raw = digestChallengeHeader(from: response)
        let parsed = raw.flatMap(parseDigestChallenge)
        let noncePrefix = parsed?.nonce.prefix(8).description
        return DigestHandshakeDebug(
            probeStatus: response.statusCode,
            hasDigestChallenge: raw != nil,
            realm: parsed?.realm,
            noncePrefix: noncePrefix,
            qop: parsed?.qop,
            rawChallenge: raw
        )
    }

    private static func soapEnvelope(action: String, serviceURN: String, bodyArgs: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
          <s:Body>
            <u:\(action) xmlns:u="\(serviceURN)">\(bodyArgs)</u:\(action)>
          </s:Body>
        </s:Envelope>
        """
    }

    private static func perform(_ request: URLRequest, timeout: TimeInterval) async throws -> (Data, HTTPURLResponse) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: config)

        var attempt = 0
        while true {
            attempt += 1
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw FritzDigestAuthError.invalidResponse
                }
                return (data, http)
            } catch {
                if attempt < 3, isTransientLocalNetworkPermissionError(error) {
                    try? await Task.sleep(for: .seconds(1))
                    continue
                }
                throw error
            }
        }
    }

    private static func digestChallengeHeader(from response: HTTPURLResponse) -> String? {
        if let value = response.value(forHTTPHeaderField: "WWW-Authenticate"),
           value.lowercased().contains("digest") {
            return value
        }
        for (keyAny, valueAny) in response.allHeaderFields {
            guard let key = keyAny as? String,
                  key.caseInsensitiveCompare("WWW-Authenticate") == .orderedSame,
                  let value = valueAny as? String,
                  value.lowercased().contains("digest")
            else {
                continue
            }
            return value
        }
        return nil
    }

    private static func digestURI(from url: URL) -> String {
        var uri = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            uri += "?\(query)"
        }
        return uri
    }

    private struct DigestChallenge {
        let realm: String
        let nonce: String
        let qop: String?
        let opaque: String?
        let algorithm: String?
    }

    private static func parseDigestChallenge(_ header: String) -> DigestChallenge? {
        let lower = header.lowercased()
        guard let digestRange = lower.range(of: "digest") else { return nil }
        let paramsString = String(header[digestRange.upperBound...]).trimmingCharacters(in: .whitespaces)

        var values: [String: String] = [:]
        let regex = try? NSRegularExpression(pattern: #"([a-zA-Z0-9_-]+)\s*=\s*(?:\"([^\"]*)\"|([^,\s]+))"#)
        let nsRange = NSRange(paramsString.startIndex..<paramsString.endIndex, in: paramsString)
        regex?.enumerateMatches(in: paramsString, options: [], range: nsRange) { match, _, _ in
            guard let match else { return }
            guard let keyRange = Range(match.range(at: 1), in: paramsString) else { return }
            let key = String(paramsString[keyRange]).lowercased()

            var value = ""
            if let quoted = Range(match.range(at: 2), in: paramsString) {
                value = String(paramsString[quoted])
            } else if let bare = Range(match.range(at: 3), in: paramsString) {
                value = String(paramsString[bare])
            }
            values[key] = value
        }

        guard let realm = values["realm"], let nonce = values["nonce"] else {
            return nil
        }

        let qopToken: String?
        if let qopRaw = values["qop"] {
            let options = qopRaw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            qopToken = options.first(where: { $0.caseInsensitiveCompare("auth") == .orderedSame }) ?? options.first
        } else {
            qopToken = nil
        }

        return DigestChallenge(
            realm: realm,
            nonce: nonce,
            qop: qopToken,
            opaque: values["opaque"],
            algorithm: values["algorithm"]
        )
    }

    private static func makeDigestAuthorization(
        username: String,
        password: String,
        method: String,
        uri: String,
        challenge: DigestChallenge
    ) -> String {
        let nc = "00000001"
        let cnonce = randomHex(length: 16)

        let ha1 = md5Hex("\(username):\(challenge.realm):\(password)")
        let ha2 = md5Hex("\(method):\(uri)")

        let response: String
        if let qop = challenge.qop {
            response = md5Hex("\(ha1):\(challenge.nonce):\(nc):\(cnonce):\(qop):\(ha2)")
        } else {
            response = md5Hex("\(ha1):\(challenge.nonce):\(ha2)")
        }

        var parts: [String] = [
            "username=\"\(username)\"",
            "realm=\"\(challenge.realm)\"",
            "nonce=\"\(challenge.nonce)\"",
            "uri=\"\(uri)\"",
            "response=\"\(response)\""
        ]

        if let algorithm = challenge.algorithm, !algorithm.isEmpty {
            parts.append("algorithm=\(algorithm)")
        } else {
            parts.append("algorithm=MD5")
        }

        if let qop = challenge.qop {
            parts.append("qop=\(qop)")
            parts.append("nc=\(nc)")
            parts.append("cnonce=\"\(cnonce)\"")
        }

        if let opaque = challenge.opaque, !opaque.isEmpty {
            parts.append("opaque=\"\(opaque)\"")
        }

        return "Digest " + parts.joined(separator: ", ")
    }

    private static func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func randomHex(length: Int) -> String {
        let chars = Array("0123456789abcdef")
        return String((0..<length).map { _ in chars.randomElement() ?? "0" })
    }

    private static func isTransientLocalNetworkPermissionError(_ error: Error) -> Bool {
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return hasCFStream2102(error)
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return hasCFStream2102(error)
        }
        return false
    }

    private static func hasCFStream2102(_ error: Error) -> Bool {
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
