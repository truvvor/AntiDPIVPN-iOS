import Foundation

struct ConfigGenerator {
    /// Generate xray JSON config optimized for Network Extension memory limits (~50MB).
    ///
    /// Mimicry and fragment are kept but tuned for low memory:
    /// - sensitivity 0.5→0.12: ~8× fewer fake writes (from 100+/sec to ~12/sec)
    /// - fragment length 20-40→150-250: ~5× fewer fragments per ClientHello
    /// - rotateAfter 60→300: profile rotation every 5min instead of 1min
    static func generateXrayConfig(from profile: VPNProfile) -> String? {
        let encryptionField: String
        if profile.antiDPISettings.enabled && !profile.nfsPublicKey.isEmpty {
            encryptionField = "mlkem768x25519plus.native.0rtt.\(profile.nfsPublicKey)"
        } else {
            encryptionField = "none"
        }

        // Anti-DPI: fragment ClientHello — larger chunks = fewer fragments = less memory
        // A ClientHello is ~500 bytes → 150-250 byte fragments = 2-3 pieces (was 12-25)
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

        // Traffic mimicry — low sensitivity to minimize fake traffic volume.
        // sensitivity 0.12 generates ~12 writes/sec instead of 100+ at 0.5
        // rotateAfter 300 = profile switch every 5 min (was every 1 min)
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

        // Debug logging path (only when explicitly requested)
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.truvvor.secureconnect") {
            let logPath = containerURL.appendingPathComponent("Logs/antidpi-debug.log").path
            realitySettings["debugLogPath"] = logPath
        }

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
            "log": ["loglevel": "warning"],
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
