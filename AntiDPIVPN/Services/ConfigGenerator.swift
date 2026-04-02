import Foundation

struct ConfigGenerator {
    static func generateXrayConfig(from profile: VPNProfile) -> String? {
        // Build encryption field
        // When anti-DPI is enabled, use NFS encryption key (NOT the REALITY key)
        // When disabled, VLESS requires "none"
        let encryptionField: String
        if profile.antiDPISettings.enabled && !profile.nfsPublicKey.isEmpty {
            encryptionField = "mlkem768x25519plus.native.1rtt.\(profile.nfsPublicKey)"
        } else {
            encryptionField = "none"
        }

        let config: [String: Any] = [
            "log": [
                "loglevel": "debug"
            ],
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
                    "settings": [
                        "vnext": [
                            [
                                "address": profile.serverAddress,
                                "port": profile.serverPort,
                                "users": [
                                    [
                                        "id": profile.uuid,
                                        "flow": "",
                                        "encryption": encryptionField
                                    ] as [String: Any]
                                ]
                            ] as [String: Any]
                        ]
                    ],
                    "streamSettings": [
                        "network": "tcp",
                        "security": "reality",
                        "realitySettings": [
                            "show": false,
                            "fingerprint": profile.realityFingerprint,
                            "serverName": profile.realityServerName,
                            "publicKey": profile.realityPublicKey,
                            "shortId": profile.realityShortId
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
