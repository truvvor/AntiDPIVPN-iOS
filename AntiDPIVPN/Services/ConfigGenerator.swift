import Foundation

struct ConfigGenerator {
    /// Generate xray JSON config with routing and custom DNS support.
    static func generateXrayConfig(from profile: VPNProfile, routeConfig: RouteConfig = RouteConfig(), bandwidthKBs: Int = 0, debugLogPath: String? = nil) -> String? {
        let encryptionField: String
        if profile.antiDPISettings.enabled && !profile.nfsPublicKey.isEmpty {
            encryptionField = "mlkem768x25519plus.native.0rtt.\(profile.nfsPublicKey)"
        } else {
            encryptionField = "none"
        }

        // Anti-DPI: fragment ClientHello
        let finalmask: [String: Any] = [
            "tcp": [
                [
                    "type": "fragment",
                    "settings": [
                        "packets": "tlshello",
                        "length": "150-250",
                        "delay": "50-100"
                    ] as [String: Any]
                ] as [String: Any]
            ]
        ]

        // Traffic mimicry
        let mimicry: [String: Any] = [
            "profile": "webrtc_zoom",
            "autoRotate": true,
            "rotateAfter": 300,
            "sensitivity": 0.12
        ]

        var realitySettings: [String: Any] = [
            "show": false,
            "fingerprint": profile.realityFingerprint,
            "serverName": profile.realityServerName,
            "publicKey": profile.realityPublicKey,
            "shortId": profile.realityShortId,
            "mimicry": mimicry
        ]

        let bandwidthBytes = bandwidthKBs > 0 ? bandwidthKBs * 1024 : 0
        if bandwidthBytes > 0 {
            realitySettings["rateLimit"] = ["maxBytesPerSec": bandwidthBytes]
        }

        if let logPath = debugLogPath {
            realitySettings["debugLogPath"] = logPath
        }

        var logConfig: [String: Any] = ["loglevel": "warning"]
        if let logPath = debugLogPath {
            let xrayLogPath = (logPath as NSString).deletingLastPathComponent + "/xray-core.log"
            logConfig["access"] = xrayLogPath
            logConfig["error"] = xrayLogPath
        }

        // Connection policy: fast cleanup of idle connections
        let policy: [String: Any] = [
            "levels": [
                "0": [
                    "handshake": 4,
                    "connIdle": 60,
                    "uplinkOnly": 2,
                    "downlinkOnly": 5
                ] as [String: Any]
            ]
        ]

        // Build routing rules
        let routing = buildRouting(from: routeConfig)

        // DNS handled by system (NEDNSSettings) — xray dns section causes
        // circular dependency: xray tries to resolve DNS through VPN that needs DNS.

        let muxSettings: [String: Any] = [
            "enabled": false,
            "concurrency": -1
        ]

        let outbounds: [[String: Any]] = [
            [
                "protocol": "vless",
                "tag": "proxy",
                "settings": [
                    "vnext": [
                        [
                            "address": profile.serverAddress,
                            "port": profile.serverPort,
                            "users": [
                                [
                                    "id": profile.uuid,
                                    "flow": "xtls-rprx-vision",
                                    "encryption": encryptionField
                                ] as [String: Any]
                            ]
                        ] as [String: Any]
                    ]
                ],
                "streamSettings": [
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": realitySettings,
                    "finalmask": finalmask,
                    "sockopt": [
                        "tcpKeepAliveInterval": 15
                    ] as [String: Any]
                ] as [String: Any],
                "mux": muxSettings
            ] as [String: Any],
            [
                "protocol": "freedom",
                "tag": "direct"
            ] as [String: Any],
            [
                "protocol": "blackhole",
                "tag": "block",
                "settings": [
                    "response": ["type": "none"] as [String: Any]
                ]
            ] as [String: Any]
        ]

        // Build inbound
        var inboundConfig: [String: Any] = [
            "listen": "127.0.0.1",
            "port": 3080,
            "protocol": "socks",
            "settings": ["udp": true]
        ]
        // NOTE: sniffing disabled — conflicts with XTLS-Vision even with routeOnly.
        // Domain routing works via hev-socks5-tunnel which sends domain names in SOCKS5 CONNECT.

        let config: [String: Any] = [
            "log": logConfig,
            "policy": policy,
            "routing": routing,
            "inbounds": [inboundConfig] as [[String: Any]],
            "outbounds": outbounds
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }

    // MARK: - Routing

    /// Build xray routing config from RouteConfig.
    private static func buildRouting(from routeConfig: RouteConfig) -> [String: Any] {
        var rules: [[String: Any]] = []

        // Always block QUIC (UDP/443) — XTLS-Vision doesn't support it
        rules.append([
            "type": "field",
            "network": "udp",
            "port": "443",
            "outboundTag": "block"
        ] as [String: Any])

        if routeConfig.isActive {
            // Expand geosite rules to domain lists (done in main app, no .dat in extension)
            // geoip rules are dropped (IP range data too heavy for extension)
            let expandedConfig = GeositeExpander.shared.expandRouteConfig(routeConfig)
            let activeRules = expandedConfig.rules.filter { $0.type != .geoip }

            let proxyRules = activeRules.filter { $0.outboundTag == "proxy" }
            let directRules = activeRules.filter { $0.outboundTag == "direct" }
            let blockRules = activeRules.filter { $0.outboundTag == "block" }

            for rule in proxyRules {
                if let xrayRule = convertRule(rule) {
                    rules.append(xrayRule)
                }
            }
            for rule in directRules {
                if let xrayRule = convertRule(rule) {
                    rules.append(xrayRule)
                }
            }
            for rule in blockRules {
                if let xrayRule = convertRule(rule) {
                    rules.append(xrayRule)
                }
            }
        }

        return [
            "domainStrategy": "AsIs",
            "rules": rules
        ]
    }

    /// Convert a RouteRule to xray routing rule format.
    private static func convertRule(_ rule: RouteRule) -> [String: Any]? {
        let cleanValues = rule.values.filter { !$0.isEmpty }
        guard !cleanValues.isEmpty else { return nil }

        var xrayRule: [String: Any] = [
            "type": "field",
            "outboundTag": rule.outboundTag
        ]

        switch rule.type {
        case .domain:
            xrayRule["domain"] = cleanValues
        case .geosite:
            xrayRule["domain"] = cleanValues
        case .geoip:
            xrayRule["ip"] = cleanValues
        case .regexp:
            xrayRule["domain"] = cleanValues.map { "regexp:\($0)" }
        case .port:
            xrayRule["port"] = cleanValues.joined(separator: ",")
        }

        return xrayRule
    }

}
