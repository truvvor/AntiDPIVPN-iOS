import Foundation

/// Generates sing-box JSON config from VPNProfile and RouteConfig.
/// sing-box format: https://sing-box.sagernet.org/configuration/
struct SingBoxConfigGenerator {

    static func generateConfig(from profile: VPNProfile, routeConfig: RouteConfig = RouteConfig()) -> String? {
        let encryptionField: String
        if profile.antiDPISettings.enabled && !profile.nfsPublicKey.isEmpty {
            encryptionField = "mlkem768x25519plus.native.0rtt.\(profile.nfsPublicKey)"
        } else {
            encryptionField = "none"
        }

        // DNS with fake-ip for domain-based routing
        let dns = buildDNS(routeConfig: routeConfig, dnsServers: profile.effectiveDNS)

        // Inbounds: TUN (sing-box handles TUN natively)
        let inbounds: [[String: Any]] = [
            [
                "type": "tun",
                "tag": "tun-in",
                "inet4_address": "172.19.0.1/30",
                "inet6_address": "fdfe:dcba:9876::1/126",
                "mtu": 9000,
                "auto_route": true,
                "strict_route": true,
                "stack": "system",
                "sniff": true,
                "sniff_override_destination": false
            ] as [String: Any]
        ]

        // Outbounds
        var outbounds: [[String: Any]] = []

        // VLESS + REALITY + Vision
        let vlessOutbound: [String: Any] = [
            "type": "vless",
            "tag": "proxy",
            "server": profile.serverAddress,
            "server_port": profile.serverPort,
            "uuid": profile.uuid,
            "flow": "xtls-rprx-vision",
            "packet_encoding": "xudp",
            "tls": [
                "enabled": true,
                "reality": [
                    "enabled": true,
                    "public_key": profile.realityPublicKey,
                    "short_id": profile.realityShortId
                ] as [String: Any],
                "server_name": profile.realityServerName,
                "utls": [
                    "enabled": true,
                    "fingerprint": profile.realityFingerprint
                ] as [String: Any]
            ] as [String: Any],
            "tcp_fast_open": false,
            "tcp_multi_path": true
        ]

        if encryptionField != "none" {
            // NFS encryption — pass as transport header if supported
        }

        outbounds.append(vlessOutbound)

        // Direct outbound
        outbounds.append([
            "type": "direct",
            "tag": "direct"
        ] as [String: Any])

        // Block outbound
        outbounds.append([
            "type": "block",
            "tag": "block"
        ] as [String: Any])

        // DNS outbound (for DNS routing)
        outbounds.append([
            "type": "dns",
            "tag": "dns-out"
        ] as [String: Any])

        // Route rules
        let route = buildRoute(routeConfig: routeConfig)

        let config: [String: Any] = [
            "log": ["level": "warn"] as [String: Any],
            "dns": dns,
            "inbounds": inbounds,
            "outbounds": outbounds,
            "route": route
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }

    // MARK: - DNS

    private static func buildDNS(routeConfig: RouteConfig, dnsServers: [String]) -> [String: Any] {
        let primaryDNS = dnsServers.first ?? "8.8.8.8"

        var servers: [[String: Any]] = [
            [
                "tag": "remote",
                "address": "tls://\(primaryDNS)",
                "detour": "proxy"
            ] as [String: Any],
            [
                "tag": "local",
                "address": "local",
                "detour": "direct"
            ] as [String: Any]
        ]

        // Add fake-ip DNS server for domain routing
        if routeConfig.isActive {
            servers.append([
                "tag": "fakeip",
                "address": "fakeip"
            ] as [String: Any])
        }

        var dns: [String: Any] = [
            "servers": servers,
            "rules": [
                [
                    "outbound": ["any"],
                    "server": "local"
                ] as [String: Any]
            ]
        ]

        if routeConfig.isActive {
            dns["fakeip"] = [
                "enabled": true,
                "inet4_range": "198.18.0.0/15",
                "inet6_range": "fc00::/18"
            ] as [String: Any]

            // DNS rules for routing: direct domains use local DNS, proxy domains use remote
            var dnsRules: [[String: Any]] = [
                ["outbound": ["any"], "server": "local"] as [String: Any]
            ]

            // Direct domains → local DNS
            let directDomains = routeConfig.rules
                .filter { ($0.outboundTag == "direct") && ($0.type == .domain || $0.type == .regexp) }
                .flatMap { $0.values }
            if !directDomains.isEmpty {
                dnsRules.append([
                    "domain_keyword": directDomains.prefix(50).map { $0 },
                    "server": "local"
                ] as [String: Any])
            }

            // Everything else → fakeip (enables domain-based routing)
            dnsRules.append([
                "query_type": ["A", "AAAA"],
                "server": "fakeip"
            ] as [String: Any])

            dns["rules"] = dnsRules
        }

        return dns
    }

    // MARK: - Route

    private static func buildRoute(routeConfig: RouteConfig) -> [String: Any] {
        var rules: [[String: Any]] = []

        // DNS hijack
        rules.append([
            "protocol": "dns",
            "outbound": "dns-out"
        ] as [String: Any])

        // Block QUIC
        rules.append([
            "network": "udp",
            "port": 443,
            "outbound": "block"
        ] as [String: Any])

        if routeConfig.isActive {
            // Expand geosite rules
            let expanded = GeositeExpander.shared.expandRouteConfig(routeConfig)

            // Proxy rules first (higher priority)
            for rule in expanded.rules where rule.outboundTag == "proxy" {
                if let singRule = convertRule(rule) { rules.append(singRule) }
            }

            // Direct rules
            for rule in expanded.rules where rule.outboundTag == "direct" {
                if let singRule = convertRule(rule) { rules.append(singRule) }
            }

            // Block rules
            for rule in expanded.rules where rule.outboundTag == "block" {
                if let singRule = convertRule(rule) { rules.append(singRule) }
            }
        }

        var route: [String: Any] = [
            "rules": rules,
            "auto_detect_interface": true,
            "final": "proxy"
        ]

        if routeConfig.isActive {
            route["default_mark"] = 233
        }

        return route
    }

    private static func convertRule(_ rule: RouteRule) -> [String: Any]? {
        let cleanValues = rule.values.filter { !$0.isEmpty }
        guard !cleanValues.isEmpty else { return nil }

        var singRule: [String: Any] = [
            "outbound": rule.outboundTag
        ]

        switch rule.type {
        case .domain:
            singRule["domain_keyword"] = cleanValues
        case .geosite:
            // Already expanded by GeositeExpander, but handle remaining
            singRule["domain_keyword"] = cleanValues
        case .geoip:
            // sing-box uses geoip natively
            let codes = cleanValues.map { $0.replacingOccurrences(of: "geoip:", with: "") }
            singRule["geoip"] = codes
        case .regexp:
            singRule["domain_regex"] = cleanValues
        case .port:
            let ports = cleanValues.flatMap { $0.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
            if !ports.isEmpty { singRule["port"] = ports }
        }

        return singRule
    }
}
