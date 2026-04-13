import Foundation

/// A single routing rule: match by domain/geosite/geoip/regexp → outbound tag.
struct RouteRule: Codable, Identifiable {
    var id = UUID()
    var type: RuleType
    var values: [String]    // domains, geosite names, geoip codes, or regexp patterns
    var outboundTag: String // "direct", "proxy", or "block"

    enum RuleType: String, Codable, CaseIterable {
        case domain
        case geosite
        case geoip
        case regexp
        case port
    }
}

/// Complete routing configuration — can be imported from Streisand URLs.
struct RouteConfig: Codable, Identifiable {
    var id = UUID()
    var name: String = ""
    var enabled: Bool = true
    var domainStrategy: String = "IPIfNonMatch"
    var rules: [RouteRule] = []

    /// Quick check if this config has usable rules
    var isEmpty: Bool { rules.isEmpty }

    /// Active only when enabled and has rules
    var isActive: Bool { enabled && !rules.isEmpty }
}
