import Foundation

struct ConfigGenerator {
    // Ports: app-side xray uses 3080, extension fallback uses 3081
    static let appXrayPort = 3080
    static let fallbackXrayPort = 3081

    /// Full xray config — all anti-DPI features at maximum strength.
    /// Runs in the main app process which has no memory limit.
    static func generateFullXrayConfig(from profile: VPNProfile, bandwidthKBs: Int = 0, debugLogPath: String? = nil) -> String? {
        return buildConfig(
            from: profile,
            socksPort: appXrayPort,
            mimicry: [
                "profile": "webrtc_zoom",
                "autoRotate": true,
                "rotateAfter": 60,
                "sensitivity": 0.5
            ],
            fragment: [
                "packets": "tlshello",
                "length": "20-40",
                "delay": "50-100"
            ],
            logLevel: "warning",
            debugLogPath: debugLogPath,
            bandwidthKBs: bandwidthKBs
        )
    }

    /// Lite xray config — functional anti-DPI with reduced memory footprint.
    /// Used as fallback when extension must run its own xray (~50MB limit).
    static func generateLiteXrayConfig(from profile: VPNProfile) -> String? {
        return buildConfig(
            from: profile,
            socksPort: fallbackXrayPort,
            mimicry: [
                "profile": "webrtc_zoom",
                "autoRotate": true,
                "rotateAfter": 300,
                "sensitivity": 0.12
            ],
            fragment: [
                "packets": "tlshello",
                "length": "150-250",
                "delay": "50-100"
            ],
            logLevel: "error",
            debugLogPath: nil,
            bandwidthKBs: 0
        )
    }

    // MARK: - Private

    private static func buildConfig(
        from profile: VPNProfile,
        socksPort: Int,
        mimicry: [String: Any],
        fragment: [String: Any],
        logLevel: String,
        debugLogPath: String?,
        bandwidthKBs: Int
    ) -> String? {
        let encryptionField: String
        if profile.antiDPISettings.enabled && !profile.nfsPublicKey.isEmpty {
            encryptionField = "mlkem768x25519plus.native.0rtt.\(profile.nfsPublicKey)"
        } else {
            encryptionField = "none"
        }

        let finalmask: [String: Any] = [
            "tcp": [
                [
                    "type": "fragment",
                    "settings": fragment
                ] as [String: Any]
            ]
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

        var logConfig: [String: Any] = ["loglevel": logLevel]
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

        let config: [String: Any] = [
            "log": logConfig,
            "routing": routing,
            "inbounds": [
                [
                    "listen": "127.0.0.1",
                    "port": socksPort,
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
