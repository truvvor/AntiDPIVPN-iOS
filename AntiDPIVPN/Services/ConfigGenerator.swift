import Foundation

struct ConfigGenerator {
    /// Generate xray JSON config with routing and custom DNS support.
    static func generateXrayConfig(from profile: VPNProfile, routeConfig: RouteConfig = RouteConfig(), bandwidthKBs: Int = 0, debugLogPath: String? = nil, xrayLogPath: String? = nil) -> String? {
        let encryptionField: String
        if profile.antiDPISettings.enabled && !profile.nfsPublicKey.isEmpty {
            encryptionField = "mlkem768x25519plus.native.0rtt.\(profile.nfsPublicKey)"
        } else {
            encryptionField = "none"
        }

        // Anti-DPI obfuscation layers — kept ON (server expects them).
        // Tuning to reduce allocation churn without changing the wire
        // protocol:
        //   autoRotate=false: kills the per-connection rotation timer
        //     goroutine. Phase stays fixed at webrtc_zoom, which is still
        //     full DPI masquerade. Rotation was shedding a ticker +
        //     state machine per REALITY session.
        //   rotateAfter: irrelevant with autoRotate=off, kept for clarity.
        var realitySettings: [String: Any] = [
            "show": false,
            "fingerprint": profile.realityFingerprint,
            "serverName": profile.realityServerName,
            "publicKey": profile.realityPublicKey,
            "shortId": profile.realityShortId,
            "mimicry": [
                "profile": "webrtc_zoom",
                "autoRotate": false,
                "rotateAfter": 300,
                "sensitivity": 0.12
            ]
        ]

        let bandwidthBytes = bandwidthKBs > 0 ? bandwidthKBs * 1024 : 0
        if bandwidthBytes > 0 {
            realitySettings["rateLimit"] = ["maxBytesPerSec": bandwidthBytes]
        }

        if let logPath = debugLogPath {
            realitySettings["debugLogPath"] = logPath
        }

        var logConfig: [String: Any] = ["loglevel": "warning"]
        // Prefer the explicit xrayLogPath. Fall back to deriving from
        // debugLogPath (legacy callers). Either way, xray-core.log gives
        // us post-mortem visibility after the extension is killed.
        let effectiveXrayLogPath: String?
        if let p = xrayLogPath {
            effectiveXrayLogPath = p
        } else if let p = debugLogPath {
            effectiveXrayLogPath = (p as NSString).deletingLastPathComponent + "/xray-core.log"
        } else {
            effectiveXrayLogPath = nil
        }
        if let p = effectiveXrayLogPath {
            logConfig["access"] = p
            logConfig["error"] = p
        }

        // Connection policy. Without mux, each REALITY session corresponds
        // to one app-level TCP connection, so connIdle directly controls
        // goroutine lifetime. 60s is a balance: short enough that idle
        // sessions drain before piling up in Telegram-burst scenarios,
        // long enough that short keepalives don't re-handshake constantly.
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

        // Mux DISABLED. Empirically on this server+protocol combo
        // (VLESS + xtls-rprx-vision + REALITY + MLKEM), enabling mux
        // DEGRADES stability: build 43 with mux-off held 38 minutes
        // under bursty load; builds 45-46 with mux-on crashed at 50-95
        // seconds. vision does its own pattern shaping on the TLS
        // stream; mux layers sub-streams on top, and the per-sub-stream
        // mimicry+finalmask state accumulates faster than the "one
        // REALITY session, many sub-streams" calculus suggested on
        // paper. Without a visible per-session improvement there's
        // no reason to pay the overhead.
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
                    "finalmask": [
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
                    ],
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
        // Sniffing: extracts domain from TLS SNI for domain-based routing.
        // routeOnly=true required for XTLS-Vision compatibility.
        if routeConfig.isActive {
            inboundConfig["sniffing"] = [
                "enabled": true,
                "destOverride": ["http", "tls"],
                "routeOnly": true
            ] as [String: Any]
        }

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

        // Route DNS (UDP/53) direct, bypassing REALITY entirely.
        // On tunnel startup iOS fires a synchronous storm of DNS queries
        // (40+ parallel to 8.8.8.8:53 when apps wake up). Each query
        // through proxy creates its own REALITY+mimicry state — ~80KB
        // each, ~3MB in 200ms, enough to push the NE extension past its
        // ~50MB jetsam budget. freedom outbound bypasses all of that:
        // DNS packets exit via the system socket (NE extensions are
        // already excluded from their own tunnel, no loop risk).
        // Trade-off: DNS queries visible to the ISP. Acceptable because
        // iOS already specified the DNS server publicly via NEDNSSettings.
        rules.append([
            "type": "field",
            "network": "udp",
            "port": "53",
            "outboundTag": "direct"
        ] as [String: Any])

        if routeConfig.isActive {
            // Expand geosite→domains in main app. Keep all types except geoip (dat too heavy).
            // Sniffing (routeOnly) extracts SNI for domain matching.
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
