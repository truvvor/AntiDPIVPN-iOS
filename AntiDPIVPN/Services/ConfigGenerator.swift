import Foundation

struct ConfigGenerator {
    /// Generate xray JSON config.
    /// - bandwidthKBs: GLOBAL rate limit in KB/s (0 = unlimited). Shared across ALL connections.
    static func generateXrayConfig(from profile: VPNProfile, bandwidthKBs: Int = 0, debugLogPath: String? = nil) -> String? {
        // Build encryption field
        let encryptionField: String
        if profile.antiDPISettings.enabled && !profile.nfsPublicKey.isEmpty {
            encryptionField = "mlkem768x25519plus.native.0rtt.\(profile.nfsPublicKey)"
        } else {
            encryptionField = "none"
        }

        let flowField = "xtls-rprx-vision"

        // Anti-DPI: fragment settings for ClientHello splitting
        let fragmentSettings: [String: Any] = [
            "packets": "tlshello",
            "length": "20-40",
            "delay": "50-100"
        ]

        let finalmask: [String: Any] = [
            "tcp": [
                [
                    "type": "fragment",
                    "settings": fragmentSettings
                ] as [String: Any]
            ]
        ]

        // Anti-DPI: traffic mimicry (profile rotation every 60s)
        let mimicry: [String: Any] = [
            "profile": "webrtc_zoom",
            "autoRotate": true,
            "rotateAfter": 60,
            "sensitivity": 0.5
        ]

        // GLOBAL rate limiting (shared token bucket across all connections)
        let bandwidthBytes = bandwidthKBs > 0 ? bandwidthKBs * 1024 : 0

        // Build REALITY settings
        var realitySettings: [String: Any] = [
            "show": false,
            "fingerprint": profile.realityFingerprint,
            "serverName": profile.realityServerName,
            "publicKey": profile.realityPublicKey,
            "shortId": profile.realityShortId,
            "mimicry": mimicry
        ]

        if bandwidthBytes > 0 {
            realitySettings["rateLimit"] = ["maxBytesPerSec": bandwidthBytes] as [String: Any]
        }

        // Debug logging path
        if let logPath = debugLogPath {
            realitySettings["debugLogPath"] = logPath
        }

        // MUX disabled - incompatible with XTLS-Vision flow.
        // Vision has built-in XUDP for UDP multiplexing.
        let muxSettings: [String: Any] = [
            "enabled": false,
            "concurrency": -1
        ]

        // Log settings
        var logConfig: [String: Any] = ["loglevel": "warning"]
        if let logPath = debugLogPath {
            let xrayLogPath = (logPath as NSString).deletingLastPathComponent + "/xray-core.log"
            logConfig["access"] = xrayLogPath
            logConfig["error"] = xrayLogPath
        }

        // Routing: block UDP/443 (QUIC) — XTLS-Vision doesn't support it.
        // This forces apps to fall back to TCP/443 (TLS), which works perfectly.
        let routing: [String: Any] = [
            "domainStrategy": "AsIs",
            "rules": [
                [
                    "type": "field",
                    "network": "udp",
                    "port": "443",
                    "outboundTag": "block-quic"
                ] as [String: Any]
            ]
        ]

        let config: [String: Any] = [
            "log": logConfig,
            "routing": routing,
            "inbounds": [
                [
                    "listen": "127.0.0.1",
                    "port": 3080,
                    "protocol": "socks",
                    "settings": [
                        "udp": true
                    ]
                ] as [String: Any]
            ],
            "outbounds": [
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
                                        "flow": flowField,
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
                        "finalmask": finalmask
                    ] as [String: Any],
                    "mux": muxSettings
                ] as [String: Any],
                [
                    "protocol": "blackhole",
                    "tag": "block-quic",
                    "settings": [
                        "response": [
                            "type": "none"
                        ] as [String: Any]
                    ]
                ] as [String: Any]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys]),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        return jsonString
    }
}
