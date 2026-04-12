import Foundation

struct ConfigGenerator {
    /// Generate minimal xray JSON config optimized for Network Extension memory limits (~50MB).
    /// Removed: mimicry, finalmask/fragment, debug logging, rate limiting.
    /// These features generated hundreds of fake writes/sec and packet fragmentation
    /// that consumed 15-20MB of memory in the Go runtime.
    static func generateXrayConfig(from profile: VPNProfile) -> String? {
        let encryptionField: String
        if profile.antiDPISettings.enabled && !profile.nfsPublicKey.isEmpty {
            encryptionField = "mlkem768x25519plus.native.0rtt.\(profile.nfsPublicKey)"
        } else {
            encryptionField = "none"
        }

        let realitySettings: [String: Any] = [
            "show": false,
            "fingerprint": profile.realityFingerprint,
            "serverName": profile.realityServerName,
            "publicKey": profile.realityPublicKey,
            "shortId": profile.realityShortId
        ]

        // Routing: block UDP/443 (QUIC) — XTLS-Vision doesn't support it.
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
            "log": ["loglevel": "none"],
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
                        "realitySettings": realitySettings
                    ] as [String: Any],
                    "mux": ["enabled": false, "concurrency": -1] as [String: Any]
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
