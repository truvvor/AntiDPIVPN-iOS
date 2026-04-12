import Foundation

/// Parses Streisand route import URLs into RouteConfig.
///
/// Format: streisand://import/route://<base64-encoded-bplist>
/// The bplist contains:
///   name: String, uuid: String, domainStrategy: String
///   rules: Array of { domain: [String], outboundTag: String, ip: [String]?, regexp: [String]?, port: [String]? }
struct StreisandRouteParser {

    enum ParseError: LocalizedError {
        case invalidScheme
        case invalidBase64
        case invalidPlist
        case missingRules

        var errorDescription: String? {
            switch self {
            case .invalidScheme: return "URL must start with streisand://"
            case .invalidBase64: return "Invalid base64 encoding"
            case .invalidPlist: return "Invalid plist data"
            case .missingRules: return "No routing rules found"
            }
        }
    }

    /// Parse a streisand://import/route://<base64> URL.
    static func parse(_ urlString: String) throws -> RouteConfig {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)

        // Extract base64 payload
        let base64Payload: String
        if trimmed.lowercased().hasPrefix("streisand://") {
            // streisand://import/route://<base64>
            // The part after streisand:// is itself base64
            let afterScheme = String(trimmed.dropFirst("streisand://".count))
            // Decode the outer base64 to get "import/route://<inner-base64>"
            if let outerData = Data(base64Encoded: afterScheme),
               let outerString = String(data: outerData, encoding: .utf8),
               outerString.hasPrefix("import/route://") {
                base64Payload = String(outerString.dropFirst("import/route://".count))
            } else {
                // Maybe the base64 is directly the plist
                base64Payload = afterScheme
            }
        } else {
            throw ParseError.invalidScheme
        }

        // Decode the plist data
        guard let plistData = Data(base64Encoded: base64Payload) else {
            throw ParseError.invalidBase64
        }

        // Parse binary plist
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            throw ParseError.invalidPlist
        }

        return try parseFromPlist(plist)
    }

    /// Parse from a decoded plist dictionary.
    static func parseFromPlist(_ plist: [String: Any]) throws -> RouteConfig {
        var config = RouteConfig()
        config.name = plist["name"] as? String ?? "Imported Route"
        config.domainStrategy = plist["domainStrategy"] as? String ?? "IPIfNonMatch"

        guard let rulesArray = plist["rules"] as? [[String: Any]], !rulesArray.isEmpty else {
            throw ParseError.missingRules
        }

        for ruleDict in rulesArray {
            let outboundTag = ruleDict["outboundTag"] as? String ?? "proxy"

            // Domain rules (includes geosite: and plain domains)
            if let domains = ruleDict["domain"] as? [String], !domains.isEmpty {
                var geosites: [String] = []
                var regexps: [String] = []
                var plainDomains: [String] = []

                for d in domains {
                    if d.hasPrefix("geosite:") {
                        geosites.append(d)
                    } else if d.hasPrefix("regexp:") {
                        regexps.append(String(d.dropFirst("regexp:".count)))
                    } else {
                        plainDomains.append(d)
                    }
                }

                if !geosites.isEmpty {
                    config.rules.append(RouteRule(type: .geosite, values: geosites, outboundTag: outboundTag))
                }
                if !regexps.isEmpty {
                    config.rules.append(RouteRule(type: .regexp, values: regexps, outboundTag: outboundTag))
                }
                if !plainDomains.isEmpty {
                    config.rules.append(RouteRule(type: .domain, values: plainDomains, outboundTag: outboundTag))
                }
            }

            // IP rules (geoip:)
            if let ips = ruleDict["ip"] as? [String], !ips.isEmpty {
                config.rules.append(RouteRule(type: .geoip, values: ips, outboundTag: outboundTag))
            }

            // Port rules
            if let ports = ruleDict["port"] as? [String], !ports.isEmpty {
                config.rules.append(RouteRule(type: .port, values: ports, outboundTag: outboundTag))
            }
        }

        return config
    }
}
