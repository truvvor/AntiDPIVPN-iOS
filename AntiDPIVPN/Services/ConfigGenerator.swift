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

        // Build 47: anti-DPI obfuscation layers DISABLED to isolate the
        // source of runaway memory. With mux on + UDP/53 direct, build 46
        // still grew 42→67MB in 20s under normal browsing, triggered 17
        // MEMPRESSURE critical events in 10 seconds, and FreeOSMemory
        // returned ~0MB each time. That's not connection state (mux
        // handles it) and not DNS storm (direct handles it). The
        // remaining heavy allocator is per-packet processing inside
        // mimicry.Write() and finalmask.fragmentConn.Write() — both
        // allocate transient chunk buffers on every outgoing write, at
        // ~400 pkt/sec that compounds into multi-MB/sec heap churn.
        //
        // REALITY+MLKEM+Vision alone (this baseline) gives us plain TLS
        // masquerading: server presents as www.samsung.com, content is
        // MLKEM-encrypted, Vision provides flow characteristics. ТСПУ
        // evasion still works via REALITY's fingerprint mimicry (not to
        // be confused with our "mimicry" engine). Once stable, re-enable
        // finalmask and mimicry one at a time to identify the culprit.
        let realityBaseline = true

        var realitySettings: [String: Any] = [
            "show": false,
            "fingerprint": profile.realityFingerprint,
            "serverName": profile.realityServerName,
            "publicKey": profile.realityPublicKey,
            "shortId": profile.realityShortId
        ]
        if !realityBaseline {
            realitySettings["mimicry"] = [
                "profile": "webrtc_zoom",
                "autoRotate": true,
                "rotateAfter": 300,
                "sensitivity": 0.12
            ]
        }

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

        // Connection policy: aggressive idle cleanup.
        // connIdle was 60s. Under a Telegram-style 50+ conn/burst, that held
        // ~300 xray goroutines alive for a minute (REALITY + mimicry state
        // ~50KB each → 15MB of "zombie" heap per burst). 15s drains that
        // in a quarter of the time.
        let policy: [String: Any] = [
            "levels": [
                "0": [
                    "handshake": 4,
                    "connIdle": 15,
                    "uplinkOnly": 2,
                    "downlinkOnly": 5
                ] as [String: Any]
            ]
        ]

        // Build routing rules
        let routing = buildRouting(from: routeConfig)

        // DNS handled by system (NEDNSSettings) — xray dns section causes
        // circular dependency: xray tries to resolve DNS through VPN that needs DNS.

        // Multiplex REALITY sessions. Without mux, every app-level TCP
        // connection forces a new REALITY+MLKEM handshake + mimicry
        // scheduler + finalmask state, ~80KB per connection. Under a
        // Telegram-style burst (50+ concurrent connects in a few ms),
        // this spikes RSS by ~4MB in one second and triggers iOS jetsam.
        // concurrency=8: up to 8 app-level sub-streams ride on one
        // REALITY session. Sub-stream cost ~1KB.
        //
        // xudpConcurrency=16: same treatment for UDP. Without this, iOS's
        // synchronous DNS storm at tunnel start (40+ parallel queries to
        // 8.8.8.8:53 when apps wake up) creates one REALITY session per
        // query — the remaining root cause of crashes after TCP mux.
        //
        // xtls-rprx-vision supports mux since xray 1.8.6; each sub-stream
        // still gets vision's anti-DPI flow characteristics.
        let muxSettings: [String: Any] = [
            "enabled": true,
            "concurrency": 8,
            "xudpConcurrency": 16
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
                "streamSettings": realityBaseline ? ([
                    "network": "tcp",
                    "security": "reality",
                    "realitySettings": realitySettings,
                    "sockopt": [
                        "tcpKeepAliveInterval": 15
                    ] as [String: Any]
                ] as [String: Any]) : ([
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
                ] as [String: Any]),
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
