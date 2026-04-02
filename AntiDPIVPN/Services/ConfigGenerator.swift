import Foundation

struct ConfigGenerator {
    static func generateXrayConfig(from profile: VPNProfile) -> String? {
        // Determine encryption field based on anti-DPI settings
        let encryptionField: String
        if profile.antiDPISettings.enabled {
            encryptionField = "mlkem768x25519plus.native.1rtt.dummy_public_key"
        } else {
            encryptionField = ""
        }

        let config: [String: Any] = [
            "log": [
                "loglevel": "warning"
            ],
            "inbounds": [
                [
                    "listen": "127.0.0.1",
                    "port": 3080,
                    "protocol": "socks",
                    "settings": [
                        "udp": true
                    ]
                ]
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
                                    ]
                                ]
                            ]
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
                        ]
                    ]
                ] as [String: Any]
            ]
        ]

        // Add anti-DPI settings to encryption field if enabled
        if profile.antiDPISettings.enabled {
            var enhancedConfig = config
            var outbounds = enhancedConfig["outbounds"] as? [[String: Any]] ?? []

            if var outbound = outbounds.first {
                var settings = outbound["settings"] as? [String: Any] ?? [:]
                var vnext = settings["vnext"] as? [[String: Any]] ?? []

                if var user = vnext.first?["users"] as? [[String: Any]], var userData = user.first {
                    // Build encryption string with anti-DPI parameters
                    var encParams = ""

                    if profile.antiDPISettings.scatterEnabled {
                        encParams += ".scatter-\(profile.antiDPISettings.scatterMinBytes)-\(profile.antiDPISettings.scatterMaxBytes)"
                    }

                    if profile.antiDPISettings.heartbeatEnabled {
                        encParams += ".heartbeat-\(profile.antiDPISettings.heartbeatMinInterval)-\(profile.antiDPISettings.heartbeatMaxInterval)"
                    }

                    if profile.antiDPISettings.randomRecordSizes {
                        encParams += ".randomrecord"
                    }

                    if profile.antiDPISettings.headerPaddingEnabled {
                        encParams += ".padding-\(profile.antiDPISettings.headerPaddingMinBytes)-\(profile.antiDPISettings.headerPaddingMaxBytes)"
                    }

                    userData["encryption"] = "mlkem768x25519plus.native.1rtt" + encParams
                    user[0] = userData
                    vnext[0]["users"] = user
                    settings["vnext"] = vnext
                    outbound["settings"] = settings
                    outbounds[0] = outbound
                    enhancedConfig["outbounds"] = outbounds
                }
            }

            guard let jsonData = try? JSONSerialization.data(withJSONObject: enhancedConfig),
                  let jsonString = String(data: jsonData, encoding: .utf8) else {
                return nil
            }
            return jsonString
        }

        guard let jsonData = try? JSONSerialization.data(withJSONObject: config),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return nil
        }

        return jsonString
    }

    static func convertShareLink(base64Link: String) -> String? {
        let result = LibXrayConvertShareLinksToXrayJson(base64Link)

        guard let responseData = Data(base64Encoded: result),
              let responseString = String(data: responseData, encoding: .utf8) else {
            return nil
        }

        return responseString
    }
}
