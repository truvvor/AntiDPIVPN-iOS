import Foundation

struct ConfigGenerator {
    /// Generate xray JSON config optimized for Network Extension (~50MB limit).
    ///
    /// Anti-DPI features preserved but tuned for low memory:
    /// - mimicry sensitivity 0.12 (~8× fewer fake writes vs 0.5)
    /// - fragment length 150-250 (~5× fewer fragments vs 20-40)
    /// - rotateAfter 300s (less churn vs 60s)
    /// Vision flow required by server — MUX incompatible with Vision.
    static func generateXrayConfig(from profile: VPNProfile, bandwidthKBs: Int = 0, debugLogPath: String? = nil) -> String? {
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

        // Traffic mimicry — low sensitivity for memory efficiency
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

        // MUX disabled — incompatible with xtls-rprx-vision flow.
        // Vision is required by the server for REALITY to work.
        let muxSettings: [String: Any] = [
            "enabled": false,
            "concurrency": -1
        ]

        // Connection policy: fast cleanup of idle connections.
        // Default connIdle=300s (5min!) — stale connections hog Go memory.
        // With connIdle=60s — idle connections close in 1min, freeing goroutines.
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

        let config: [String: Any] = [
            "log": logConfig,
            "policy": policy,
            "routing": routing,
            "inbounds": [
                [
                    "listen": "127.0.0.1",
                    "port": 3080,
                    "protocol": "socks",
                    "settings": ["udp": true]
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
                        "finalmask": finalmask
                    ] as [String: Any],
                    "mux": muxSettings
                ] as [String: Any],
                [
                    "protocol": "blackhole",
                    "tag": "block-quic",
                    "settings": [
                        "response": ["type": "none"] as [String: Any]
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
