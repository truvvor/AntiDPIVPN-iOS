import Foundation

/// Parses and generates VLESS share URLs
/// Format: vless://UUID@server:port?type=tcp&security=reality&fp=chrome&pbk=KEY&sid=ID&sni=SNI&flow=xtls-rprx-vision&encryption=ENC#Name
struct VLESSURLParser {

    enum ParseError: LocalizedError {
        case invalidScheme
        case invalidFormat
        case missingUUID
        case missingServer
        case missingPort

        var errorDescription: String? {
            switch self {
            case .invalidScheme: return "URL must start with vless://"
            case .invalidFormat: return "Invalid VLESS URL format"
            case .missingUUID: return "UUID is missing"
            case .missingServer: return "Server address is missing"
            case .missingPort: return "Port is missing"
            }
        }
    }

    /// Parse a vless:// URL into a VPNProfile
    static func parse(_ urlString: String) throws -> VPNProfile {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.lowercased().hasPrefix("vless://") else {
            throw ParseError.invalidScheme
        }

        var profile = VPNProfile()

        // Extract fragment (profile name) first
        let mainAndFragment = trimmed.dropFirst(8) // remove "vless://"
        let parts = mainAndFragment.components(separatedBy: "#")
        let mainPart = parts[0]
        if parts.count > 1 {
            profile.name = parts.dropFirst().joined(separator: "#")
                .removingPercentEncoding ?? parts[1]
        }

        // Split userinfo@host:port?query
        let userAndRest = mainPart.components(separatedBy: "@")
        guard userAndRest.count == 2 else { throw ParseError.invalidFormat }

        let uuid = userAndRest[0]
        guard !uuid.isEmpty else { throw ParseError.missingUUID }
        profile.uuid = uuid

        // Parse host:port?query
        let hostPortQuery = userAndRest[1]
        let hostPortAndQuery = hostPortQuery.components(separatedBy: "?")
        let hostPort = hostPortAndQuery[0]

        // Parse host:port
        let hostParts = hostPort.components(separatedBy: ":")
        guard hostParts.count >= 2 else { throw ParseError.missingPort }

        let host = hostParts.dropLast().joined(separator: ":")
        guard !host.isEmpty else { throw ParseError.missingServer }
        profile.serverAddress = host

        guard let port = Int(hostParts.last ?? ""), port >= 1, port <= 65535 else {
            throw ParseError.missingPort
        }
        profile.serverPort = port

        // Parse query parameters
        if hostPortAndQuery.count > 1 {
            let queryString = hostPortAndQuery[1]
            let params = parseQueryParams(queryString)

            if let fp = params["fp"] { profile.realityFingerprint = fp }
            if let pbk = params["pbk"] { profile.realityPublicKey = pbk }
            if let sid = params["sid"] { profile.realityShortId = sid }
            if let sni = params["sni"] { profile.realityServerName = sni }

            // Parse encryption field for NFS key
            if let enc = params["encryption"], enc != "none" {
                // Format: mlkem768x25519plus.native.0rtt.{nfsPublicKey}
                let encParts = enc.components(separatedBy: ".")
                if encParts.count >= 4 && encParts[0] == "mlkem768x25519plus" {
                    profile.nfsPublicKey = encParts[3...].joined(separator: ".")
                    profile.antiDPISettings.enabled = true
                }
            }
        }

        if profile.name.isEmpty {
            profile.name = "\(profile.serverAddress):\(profile.serverPort)"
        }

        return profile
    }

    /// Generate a vless:// share URL from a VPNProfile
    static func generate(from profile: VPNProfile) -> String {
        var params: [(String, String)] = []
        params.append(("type", "tcp"))
        params.append(("security", "reality"))
        params.append(("fp", profile.realityFingerprint))
        params.append(("pbk", profile.realityPublicKey))
        params.append(("sid", profile.realityShortId))
        params.append(("sni", profile.realityServerName))
        params.append(("flow", "xtls-rprx-vision"))

        if profile.antiDPISettings.enabled && !profile.nfsPublicKey.isEmpty {
            params.append(("encryption", "mlkem768x25519plus.native.0rtt.\(profile.nfsPublicKey)"))
        }

        let query = params.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
        let name = profile.name.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? profile.name

        return "vless://\(profile.uuid)@\(profile.serverAddress):\(profile.serverPort)?\(query)#\(name)"
    }

    // MARK: - Private

    private static func parseQueryParams(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            if kv.count == 2 {
                let key = kv[0].removingPercentEncoding ?? kv[0]
                let value = kv[1].removingPercentEncoding ?? kv[1]
                result[key] = value
            }
        }
        return result
    }
}