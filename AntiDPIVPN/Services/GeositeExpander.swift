import Foundation
import os.log

/// Reads geosite.dat (protobuf format) and expands geosite categories to domain lists.
/// Runs in the MAIN APP (no memory limit). The extension gets only plain domain rules.
class GeositeExpander {
    static let shared = GeositeExpander()

    private var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.truvvor.secureconnect")
    }

    /// Expand a geosite category (e.g., "geosite:youtube") to a list of domains.
    /// Returns nil if geo data not available or category not found.
    func expandCategory(_ category: String) -> [String]? {
        let name = category.hasPrefix("geosite:") ? String(category.dropFirst("geosite:".count)) : category
        guard let url = sharedContainerURL?.appendingPathComponent("xray_dat/geosite.dat"),
              let data = try? Data(contentsOf: url) else {
            return nil
        }
        return parseGeositeList(data: data, targetCategory: name.lowercased())
    }

    /// Expand all geosite rules in a RouteConfig to domain rules.
    /// Returns a new RouteConfig with geosite rules replaced by domain rules.
    func expandRouteConfig(_ config: RouteConfig) -> RouteConfig {
        var expanded = config
        var newRules: [RouteRule] = []

        for rule in config.rules {
            if rule.type == .geosite {
                // Expand each geosite category to domains
                var allDomains: [String] = []
                for value in rule.values {
                    if let domains = expandCategory(value) {
                        allDomains.append(contentsOf: domains)
                        os_log(.info, "GeositeExpander: %{public}@ → %d domains", value, domains.count)
                    } else {
                        os_log(.error, "GeositeExpander: failed to expand %{public}@", value)
                    }
                }
                if !allDomains.isEmpty {
                    // Sort: RootDomain entries (no prefix) first, then full:, then regexp:
                    // RootDomain = primary domains like youtube.com (most useful)
                    let sorted = allDomains.sorted { a, b in
                        let aScore = a.hasPrefix("full:") ? 1 : a.hasPrefix("regexp:") ? 2 : 0
                        let bScore = b.hasPrefix("full:") ? 1 : b.hasPrefix("regexp:") ? 2 : 0
                        return aScore < bScore
                    }
                    // Limit to 10 per category — minimal memory for domain matcher
                    let limited = Array(sorted.prefix(10))
                    newRules.append(RouteRule(type: .domain, values: limited, outboundTag: rule.outboundTag))
                }
            } else {
                newRules.append(rule)
            }
        }

        expanded.rules = newRules
        return expanded
    }

    // MARK: - Minimal protobuf parser for geosite.dat

    /// Parse GeoSiteList protobuf and extract domains for a specific category.
    private func parseGeositeList(data: Data, targetCategory: String) -> [String]? {
        var offset = 0
        let bytes = [UInt8](data)

        while offset < bytes.count {
            guard let (fieldNumber, wireType, newOffset) = readTag(bytes: bytes, offset: offset) else { break }
            offset = newOffset

            if fieldNumber == 1 && wireType == 2 {
                // GeoSite entry (length-delimited)
                guard let (entryBytes, nextOffset) = readLengthDelimited(bytes: bytes, offset: offset) else { break }
                offset = nextOffset

                if let domains = parseGeoSite(bytes: entryBytes, targetCategory: targetCategory) {
                    return domains
                }
            } else {
                // Skip unknown field
                guard let nextOffset = skipField(bytes: bytes, offset: offset, wireType: wireType) else { break }
                offset = nextOffset
            }
        }
        return nil
    }

    /// Parse a single GeoSite message. Returns domains if country_code matches target.
    private func parseGeoSite(bytes: [UInt8], targetCategory: String) -> [String]? {
        var offset = 0
        var countryCode: String?
        var domains: [String] = []

        while offset < bytes.count {
            guard let (fieldNumber, wireType, newOffset) = readTag(bytes: bytes, offset: offset) else { break }
            offset = newOffset

            if fieldNumber == 1 && wireType == 2 {
                // country_code (string)
                guard let (strBytes, nextOffset) = readLengthDelimited(bytes: bytes, offset: offset) else { break }
                offset = nextOffset
                countryCode = String(bytes: strBytes, encoding: .utf8)?.lowercased()

                // Early exit if wrong category
                if let cc = countryCode, cc != targetCategory {
                    return nil
                }
            } else if fieldNumber == 2 && wireType == 2 {
                // Domain message
                guard let (domainBytes, nextOffset) = readLengthDelimited(bytes: bytes, offset: offset) else { break }
                offset = nextOffset

                if let domain = parseDomain(bytes: domainBytes) {
                    domains.append(domain)
                }
            } else {
                guard let nextOffset = skipField(bytes: bytes, offset: offset, wireType: wireType) else { break }
                offset = nextOffset
            }
        }

        if countryCode == targetCategory && !domains.isEmpty {
            return domains
        }
        return nil
    }

    /// Parse a Domain message, return the domain string with appropriate prefix.
    private func parseDomain(bytes: [UInt8]) -> String? {
        var offset = 0
        var domainType: Int = 0
        var value: String?

        while offset < bytes.count {
            guard let (fieldNumber, wireType, newOffset) = readTag(bytes: bytes, offset: offset) else { break }
            offset = newOffset

            if fieldNumber == 1 && wireType == 0 {
                // type (varint)
                guard let (v, nextOffset) = readVarint(bytes: bytes, offset: offset) else { break }
                domainType = Int(v)
                offset = nextOffset
            } else if fieldNumber == 2 && wireType == 2 {
                // value (string)
                guard let (strBytes, nextOffset) = readLengthDelimited(bytes: bytes, offset: offset) else { break }
                offset = nextOffset
                value = String(bytes: strBytes, encoding: .utf8)
            } else {
                guard let nextOffset = skipField(bytes: bytes, offset: offset, wireType: wireType) else { break }
                offset = nextOffset
            }
        }

        guard let v = value, !v.isEmpty else { return nil }

        switch domainType {
        case 0: return v                // Plain (keyword match)
        case 1: return "regexp:\(v)"    // Regex
        case 2: return v                // RootDomain (suffix match — xray handles this)
        case 3: return "full:\(v)"      // Full exact match
        default: return v
        }
    }

    // MARK: - Protobuf wire format helpers

    private func readTag(bytes: [UInt8], offset: Int) -> (fieldNumber: Int, wireType: Int, newOffset: Int)? {
        guard let (value, newOffset) = readVarint(bytes: bytes, offset: offset) else { return nil }
        let fieldNumber = Int(value >> 3)
        let wireType = Int(value & 0x07)
        return (fieldNumber, wireType, newOffset)
    }

    private func readVarint(bytes: [UInt8], offset: Int) -> (value: UInt64, newOffset: Int)? {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        var i = offset
        while i < bytes.count {
            let b = UInt64(bytes[i])
            result |= (b & 0x7F) << shift
            i += 1
            if b & 0x80 == 0 { return (result, i) }
            shift += 7
            if shift >= 64 { return nil }
        }
        return nil
    }

    private func readLengthDelimited(bytes: [UInt8], offset: Int) -> (data: [UInt8], newOffset: Int)? {
        guard let (length, dataStart) = readVarint(bytes: bytes, offset: offset) else { return nil }
        let len = Int(length)
        let end = dataStart + len
        guard end <= bytes.count else { return nil }
        return (Array(bytes[dataStart..<end]), end)
    }

    private func skipField(bytes: [UInt8], offset: Int, wireType: Int) -> Int? {
        switch wireType {
        case 0: // varint
            guard let (_, next) = readVarint(bytes: bytes, offset: offset) else { return nil }
            return next
        case 1: // 64-bit
            return offset + 8
        case 2: // length-delimited
            guard let (_, next) = readLengthDelimited(bytes: bytes, offset: offset) else { return nil }
            return next
        case 5: // 32-bit
            return offset + 4
        default:
            return nil
        }
    }
}
